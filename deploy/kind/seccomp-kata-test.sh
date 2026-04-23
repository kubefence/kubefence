#!/usr/bin/env bash
# seccomp-kata-test.sh — verify seccomp enforcement across two kata runtimeclasses
#
# Deploys two pods:
#   kata-actor-generic  — kata-qemu RuntimeClass (plain kata, no nono injection)
#                         Expected: dangerous syscalls ALLOWED (no seccomp filter)
#   kata-actor-nono     — kata-nono-sandbox RuntimeClass (kata-nono-qemu handler)
#                         Expected: dangerous syscalls BLOCKED (restricted seccomp)
#
# Both pods run the seccomp-actor binary as the container CMD so the seccomp
# filter (if any) applies from the first instruction — kubectl exec is not used.
# Results appear in kubectl logs.
#
# Usage:
#   CLUSTER_NAME=nono-containerd bash deploy/kind/seccomp-kata-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-nono-containerd}"
CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="${NAMESPACE:-default}"
ACTOR_IMAGE="nono-seccomp-actor:kata-test"

bold()  { printf '\033[1m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
red()   { printf '\033[31m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }

kc() { kubectl --context "$CONTEXT" "$@"; }

# ── Preflight checks ──────────────────────────────────────────────────────────
echo "==> Checking runtimeclasses..."
for rc in kata-qemu kata-nono-sandbox; do
    if ! kc get runtimeclass "$rc" &>/dev/null; then
        echo "ERROR: RuntimeClass '$rc' not found — run deploy.sh first"
        exit 1
    fi
    echo "    $rc OK"
done

echo "==> Checking nono-nri config..."
RUNTIME_CLASSES=$(kc get configmap kubefence-config -n kube-system \
    -o jsonpath='{.data.10-nono-nri\.toml}' 2>/dev/null \
    | grep '^runtime_classes' || echo "")
echo "    ${RUNTIME_CLASSES}"
if ! echo "$RUNTIME_CLASSES" | grep -q 'kata-nono-qemu'; then
    echo "ERROR: nono-nri is not watching kata-nono-qemu — run helm upgrade first"
    exit 1
fi

# ── Build seccomp-actor binary and image ──────────────────────────────────────
echo ""
echo "==> Building seccomp-actor binary (static, CGO_ENABLED=0)..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o /tmp/seccomp-actor-kata "${REPO_ROOT}/tools/seccomp-actor/"
echo "    $(du -sh /tmp/seccomp-actor-kata | cut -f1) — OK"

echo "==> Building actor container image..."
CTX=$(mktemp -d)
cp /tmp/seccomp-actor-kata "$CTX/seccomp-actor"
docker build -q -t "$ACTOR_IMAGE" "$CTX" -f - <<'DOCKERFILE'
FROM ubuntu:22.04
COPY seccomp-actor /usr/local/bin/seccomp-actor
CMD ["/usr/local/bin/seccomp-actor"]
DOCKERFILE
rm -rf "$CTX"
echo "    image built OK"

echo "==> Loading actor image into kind cluster (via ctr import)..."
docker save "$ACTOR_IMAGE" | docker exec -i "${CLUSTER_NAME}-control-plane" \
    ctr -n k8s.io images import - &>/dev/null
echo "    loaded OK"

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    rm -f /tmp/seccomp-actor-kata
    kc delete pod kata-actor-generic kata-actor-nono \
        --ignore-not-found=true --wait=false &>/dev/null || true
}
trap cleanup EXIT

kc delete pod kata-actor-generic kata-actor-nono \
    --ignore-not-found=true --wait=true &>/dev/null || true

# ── Deploy pods ───────────────────────────────────────────────────────────────
echo ""
echo "==> Deploying kata-actor-generic (kata-qemu — no nono injection, no seccomp)..."
kc apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kata-actor-generic
  namespace: ${NAMESPACE}
spec:
  runtimeClassName: kata-qemu
  restartPolicy: Never
  containers:
    - name: actor
      image: ${ACTOR_IMAGE}
      imagePullPolicy: IfNotPresent
      env:
        - name: SECCOMP_PROFILE
          value: "none (generic kata-qemu, no nono injection)"
EOF

echo "==> Deploying kata-actor-nono (kata-nono-sandbox — restricted seccomp via nono-nri)..."
kc apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kata-actor-nono
  namespace: ${NAMESPACE}
spec:
  runtimeClassName: kata-nono-sandbox
  restartPolicy: Never
  containers:
    - name: actor
      image: ${ACTOR_IMAGE}
      imagePullPolicy: IfNotPresent
      env:
        - name: SECCOMP_PROFILE
          value: "restricted (injected by nono-nri, kata-nono-qemu handler)"
EOF

# ── Wait for pods to complete ─────────────────────────────────────────────────
wait_completed() {
    local pod="$1"
    local i=0
    echo -n "    waiting for $pod "
    while [[ $i -lt 72 ]]; do  # up to 6 min (kata VM boot ~30s + actor runtime)
        phase=$(kc get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && {
            echo " done (${phase})"
            return 0
        }
        echo -n "."
        sleep 5
        i=$((i+1))
    done
    echo " TIMEOUT"
    kc describe pod "$pod" 2>/dev/null | tail -20 || true
    return 1
}

echo ""
echo "==> Waiting for pods to complete (kata VMs take ~30 s to boot)..."
wait_completed kata-actor-generic
wait_completed kata-actor-nono

# ── Show results ──────────────────────────────────────────────────────────────
echo ""
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bold " Kata seccomp comparison  [cluster: ${CLUSTER_NAME}]"
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
bold "══ [1/2] kata-actor-generic  (kata-qemu — no seccomp, all syscalls ALLOWED) ══"
echo ""
kc logs kata-actor-generic

echo ""
bold "══ [2/2] kata-actor-nono  (kata-nono-sandbox — restricted seccomp, dangerous syscalls BLOCKED) ══"
echo ""
kc logs kata-actor-nono

echo ""
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Expected result:"
echo "  kata-actor-generic : io_uring / ptrace / bpf → $(green ALLOWED) (no filter)"
echo "  kata-actor-nono    : io_uring / ptrace / bpf → $(red BLOCKED) (restricted seccomp)"
echo ""
echo "If kata-actor-nono shows BLOCKED for dangerous syscalls, seccomp is working."
