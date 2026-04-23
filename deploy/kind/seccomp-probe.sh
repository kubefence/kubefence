#!/usr/bin/env bash
# seccomp-probe.sh — run the seccomp-probe binary inside Kubernetes pods
#
# Two modes:
#
#   Pod mode — probe a single existing pod:
#     bash deploy/kind/seccomp-probe.sh --pod <name> [--namespace <ns>] [--context <ctx>]
#
#   Compare mode (default) — deploy three pods and compare profiles:
#     CLUSTER_NAME=nono-containerd bash deploy/kind/seccomp-probe.sh
#
# The probe binary (tools/seccomp-probe/main.go) is compiled as a static
# Linux/amd64 binary and injected into the target container via kubectl exec
# stdin — no tar, no python3, no runtime dependencies in the target image.
#
# Requirements:
#   - Go toolchain (for building the binary)
#   - kubectl, helm, kind in PATH
#   - kind-nono-containerd cluster with kubefence deployed (compare mode only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-nono-containerd}"
CONTEXT="${CONTEXT:-kind-${CLUSTER_NAME}}"
NAMESPACE="${NAMESPACE:-default}"
RELEASE="${RELEASE:-kubefence}"
CHART="${REPO_ROOT}/deploy/helm/kubefence"
IMAGE_REPO="${IMAGE_REPO:-nono-nri}"
IMAGE_TAG="${IMAGE_TAG:-dev}"

# Parsed from flags
POD_MODE=false
TARGET_POD=""
TARGET_NS="$NAMESPACE"

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pod|-p)      POD_MODE=true; TARGET_POD="$2"; shift 2 ;;
        --namespace|-n) TARGET_NS="$2"; shift 2 ;;
        --context|-c)  CONTEXT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Colours ───────────────────────────────────────────────────────────────────
bold()   { printf '\033[1m%s\033[0m' "$*"; }
dim()    { printf '\033[2m%s\033[0m' "$*"; }

kc() { kubectl --context "$CONTEXT" "$@"; }

# ── Build the probe binary ────────────────────────────────────────────────────
PROBE_BIN="${TMPDIR:-/tmp}/seccomp-probe-$$"
build_probe() {
    echo "==> Building seccomp-probe (static, CGO_ENABLED=0)..."
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
        go build -o "$PROBE_BIN" "${REPO_ROOT}/tools/seccomp-probe/" 2>&1
    echo "    $(du -sh "$PROBE_BIN" | cut -f1) — OK"
}

# ── Inject and run ────────────────────────────────────────────────────────────
# Works in any container: pipes the binary over kubectl exec stdin via cat,
# so tar is not required in the target image.
# run_embedded — run the probe binary already baked into the image.
# Used for compare mode where we control the image.
run_embedded() {
    local pod="$1" ns="$2"
    kc exec "$pod" -n "$ns" -- /usr/local/bin/seccomp-probe
}

# inject_and_run — copy the probe binary into an arbitrary existing pod and run it.
# Uses /bin/sh explicitly (not sh) to bypass the nono PATH wrapper.
# The nono Landlock sandbox may restrict writes; tries /dev/shm then /tmp.
inject_and_run() {
    local pod="$1" ns="$2"
    local dest="/dev/shm/seccomp-probe"
    # Probe whether /dev/shm is writable; fall back to /tmp.
    if ! kc exec "$pod" -n "$ns" -- /bin/sh -c \
            'test -w /dev/shm 2>/dev/null' &>/dev/null; then
        dest="/tmp/seccomp-probe"
    fi
    kc exec -i "$pod" -n "$ns" -- \
        /bin/sh -c "cat > ${dest} && chmod +x ${dest}" < "$PROBE_BIN"
    kc exec "$pod" -n "$ns" -- "${dest}"
    kc exec "$pod" -n "$ns" -- /bin/sh -c "rm -f ${dest}" 2>/dev/null || true
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────
ORIGINAL_PROFILE=""
cleanup() {
    rm -f "$PROBE_BIN"
    if [[ "$POD_MODE" == false && -n "$ORIGINAL_PROFILE" ]]; then
        echo ""
        echo "==> Restoring plugin seccomp_profile=${ORIGINAL_PROFILE}..."
        helm upgrade "$RELEASE" "$CHART" \
            --kube-context "$CONTEXT" -n kube-system \
            --set image.repository="$IMAGE_REPO" \
            --set image.tag="$IMAGE_TAG" \
            --set image.pullPolicy=Never \
            --set "config.seccompProfile=${ORIGINAL_PROFILE}" \
            --wait --timeout 60s &>/dev/null
        kc delete pod probe-restricted probe-runtime-default probe-unconfined \
            --ignore-not-found=true --wait=false &>/dev/null || true
        echo "    done."
    fi
}
trap cleanup EXIT

# ════════════════════════════════════════════════════════════════════════════════
# POD MODE — inject into an existing pod and show results
# ════════════════════════════════════════════════════════════════════════════════
if [[ "$POD_MODE" == true ]]; then
    build_probe
    echo ""
    bold "==> Probing pod ${TARGET_POD} (namespace: ${TARGET_NS}, context: ${CONTEXT})"
    echo ""
    inject_and_run "$TARGET_POD" "$TARGET_NS"
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════════════
# COMPARE MODE — deploy three pods and run sequentially
# ════════════════════════════════════════════════════════════════════════════════

# Build a minimal probe image — only needs to keep the container alive long
# enough for inject_and_run; it does NOT need python3 or any special tools.
PROBE_IMAGE="nono-seccomp-probe:latest"
build_probe_image() {
    echo "==> Building probe container image (binary embedded)..."
    # The binary is embedded so kubectl exec can run it directly without
    # writing to the container filesystem — which matters because nono's
    # Landlock sandbox may restrict writes even to /tmp and /dev/shm.
    CTX=$(mktemp -d)
    cp "$PROBE_BIN" "$CTX/seccomp-probe"
    docker build -q -t "$PROBE_IMAGE" "$CTX" -f - <<'DOCKERFILE'
FROM ubuntu:22.04
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends libdbus-1-3 \
 && rm -rf /var/lib/apt/lists/*
COPY seccomp-probe /usr/local/bin/seccomp-probe
CMD ["sleep", "infinity"]
DOCKERFILE
    rm -rf "$CTX"
    echo "==> Loading probe image into kind cluster..."
    kind load docker-image "$PROBE_IMAGE" --name "$CLUSTER_NAME" &>/dev/null
}

deploy_plugin() {
    local profile="$1"
    helm upgrade "$RELEASE" "$CHART" \
        --kube-context "$CONTEXT" -n kube-system \
        --set image.repository="$IMAGE_REPO" \
        --set image.tag="$IMAGE_TAG" \
        --set image.pullPolicy=Never \
        --set "config.seccompProfile=${profile}" \
        --wait --timeout 60s &>/dev/null
    # Force pod restart so the new config is picked up, then wait for reconnect.
    kc rollout restart daemonset/kubefence -n kube-system &>/dev/null
    kc rollout status  daemonset/kubefence -n kube-system --timeout=60s &>/dev/null
    sleep 3
}

create_nono_pod() {
    local name="$1"
    kc apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
spec:
  runtimeClassName: nono-runc
  restartPolicy: Never
  containers:
    - name: probe
      image: ${PROBE_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
EOF
    kc wait --for=condition=ready "pod/${name}" --timeout=60s &>/dev/null
}

create_unconfined_pod() {
    kc apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: probe-unconfined
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: ${PROBE_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      securityContext:
        seccompProfile:
          type: Unconfined
EOF
    kc wait --for=condition=ready pod/probe-unconfined --timeout=60s &>/dev/null
}

build_probe
build_probe_image

ORIGINAL_PROFILE=$(kc get configmap kubefence-config -n kube-system \
    -o jsonpath='{.data.10-nono-nri\.toml}' 2>/dev/null \
    | grep '^seccomp_profile' | cut -d'"' -f2 || echo "restricted")

echo ""
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
bold " nono-nri seccomp profile comparison  [cluster: ${CLUSTER_NAME}]"
echo ""
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. restricted ─────────────────────────────────────────────────────────────
echo ""
bold "══ [1/3] Profile: restricted ══"
echo ""
if [[ "$ORIGINAL_PROFILE" != "restricted" ]]; then
    deploy_plugin restricted
fi
create_nono_pod probe-restricted
run_embedded probe-restricted "$NAMESPACE"

# ── 2. runtime-default ────────────────────────────────────────────────────────
echo ""
bold "══ [2/3] Profile: runtime-default ══"
echo ""
deploy_plugin runtime-default
create_nono_pod probe-runtime-default
run_embedded probe-runtime-default "$NAMESPACE"

# ── 3. unconfined baseline ────────────────────────────────────────────────────
echo ""
bold "══ [3/3] Profile: unconfined (no seccomp) ══"
echo ""
create_unconfined_pod
run_embedded probe-unconfined "$NAMESPACE"
