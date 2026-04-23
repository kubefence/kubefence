#!/usr/bin/env bash
# seccomp-actor.sh — compare seccomp protection via kubectl logs
#
# Builds a static actor binary, bakes it into a container image as CMD,
# then deploys two pods:
#   actor-restricted  — nono-runc RuntimeClass, seccomp_profile=restricted
#   actor-unconfined  — no RuntimeClass, seccompProfile: Unconfined
#
# The actor binary runs as the container's main process so the seccomp
# filter applies from the very first instruction.  kubectl exec is not
# used — there is no injection bypass.  Results appear in kubectl logs.
#
# Usage:
#   CLUSTER_NAME=nono-containerd bash deploy/kind/seccomp-actor.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-nono-containerd}"
CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="${NAMESPACE:-default}"
RELEASE="${RELEASE:-kubefence}"
CHART="${REPO_ROOT}/deploy/helm/kubefence"
IMAGE_REPO="${IMAGE_REPO:-nono-nri}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
ACTOR_IMAGE="nono-seccomp-actor:latest"

bold()  { printf '\033[1m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
red()   { printf '\033[31m%s\033[0m' "$*"; }

kc() { kubectl --context "$CONTEXT" "$@"; }

# ── Build ──────────────────────────────────────────────────────────────────────
echo "==> Building seccomp-actor binary (static, CGO_ENABLED=0)..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o /tmp/seccomp-actor "${REPO_ROOT}/tools/seccomp-actor/"
echo "    $(du -sh /tmp/seccomp-actor | cut -f1) — OK"

echo "==> Building actor container image..."
CTX=$(mktemp -d)
cp /tmp/seccomp-actor "$CTX/seccomp-actor"
docker build -q -t "$ACTOR_IMAGE" "$CTX" -f - <<'DOCKERFILE'
FROM ubuntu:22.04
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends libdbus-1-3 \
 && rm -rf /var/lib/apt/lists/*
COPY seccomp-actor /usr/local/bin/seccomp-actor
CMD ["/usr/local/bin/seccomp-actor"]
DOCKERFILE
rm -rf "$CTX"

echo "==> Loading actor image into kind cluster..."
kind load docker-image "$ACTOR_IMAGE" --name "$CLUSTER_NAME" &>/dev/null

# ── Cleanup ────────────────────────────────────────────────────────────────────
ORIGINAL_PROFILE=""
cleanup() {
    rm -f /tmp/seccomp-actor
    kc delete pod actor-restricted actor-unconfined \
        --ignore-not-found=true --wait=false &>/dev/null || true
    if [[ -n "$ORIGINAL_PROFILE" ]]; then
        echo ""
        echo "==> Restoring plugin seccomp_profile=${ORIGINAL_PROFILE}..."
        helm upgrade "$RELEASE" "$CHART" \
            --kube-context "$CONTEXT" -n kube-system \
            --set image.repository="$IMAGE_REPO" \
            --set image.tag="$IMAGE_TAG" \
            --set image.pullPolicy=Never \
            --set "config.seccompProfile=${ORIGINAL_PROFILE}" \
            --wait --timeout 60s &>/dev/null
        echo "    done."
    fi
}
trap cleanup EXIT

ORIGINAL_PROFILE=$(kc get configmap kubefence-config -n kube-system \
    -o jsonpath='{.data.10-nono-nri\.toml}' 2>/dev/null \
    | grep '^seccomp_profile' | cut -d'"' -f2 || echo "restricted")

# Always restart the plugin pod so it reads the current ConfigMap — a
# previous script may have changed the profile without restarting the pod.
echo "==> Ensuring plugin is running with seccomp_profile=restricted..."
helm upgrade "$RELEASE" "$CHART" \
    --kube-context "$CONTEXT" -n kube-system \
    --set image.repository="$IMAGE_REPO" \
    --set image.tag="$IMAGE_TAG" \
    --set image.pullPolicy=Never \
    --set "config.seccompProfile=restricted" \
    --wait --timeout 60s &>/dev/null
kc rollout restart daemonset/kubefence -n kube-system &>/dev/null
kc rollout status  daemonset/kubefence -n kube-system --timeout=60s &>/dev/null
sleep 3

# ── Deploy pods ────────────────────────────────────────────────────────────────
# Pod 1: nono-runc RuntimeClass → seccomp_profile=restricted applied by plugin
kc apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: actor-restricted
  namespace: ${NAMESPACE}
spec:
  runtimeClassName: nono-runc
  restartPolicy: Never
  containers:
    - name: actor
      image: ${ACTOR_IMAGE}
      imagePullPolicy: IfNotPresent
      env:
        - name: SECCOMP_PROFILE
          value: "restricted (injected by nono-nri)"
EOF

# Pod 2: plain pod, seccomp explicitly disabled — no NRI injection, no filter
kc apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: actor-unconfined
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: actor
      image: ${ACTOR_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        seccompProfile:
          type: Unconfined
      env:
        - name: SECCOMP_PROFILE
          value: "unconfined (no seccomp)"
EOF

# ── Wait and show logs ─────────────────────────────────────────────────────────
echo ""
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bold " seccomp-actor comparison  [cluster: ${CLUSTER_NAME}]"
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

wait_completed() {
    local pod="$1"
    local i=0
    while [[ $i -lt 30 ]]; do
        phase=$(kc get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && return 0
        sleep 2; i=$((i+1))
    done
    echo "  (timed out waiting for $pod to complete)" >&2
    return 1
}

echo ""
bold "══ [1/2] actor-restricted  (nono-runc → seccomp_profile=restricted) ══"
echo ""
wait_completed actor-restricted
kc logs actor-restricted

echo ""
bold "══ [2/2] actor-unconfined  (no RuntimeClass → seccomp: Unconfined) ══"
echo ""
wait_completed actor-unconfined
kc logs actor-unconfined
