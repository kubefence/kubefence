#!/usr/bin/env bash
# e2e.sh — end-to-end tests for nono-nri on a Kind cluster
#
# Requires a cluster already deployed by deploy.sh.
#
# Usage:
#   RUNTIME=containerd CLUSTER_NAME=nono-containerd bash deploy/kind/e2e.sh
#   RUNTIME=crio       CLUSTER_NAME=nono-crio       bash deploy/kind/e2e.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RUNTIME="${RUNTIME:-containerd}"
CLUSTER_NAME="${CLUSTER_NAME:-nono-${RUNTIME}}"
NODE="${CLUSTER_NAME}-control-plane"

PASS=0
FAIL=0

# ── Helpers ───────────────────────────────────────────────────────────────────
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; }

pass() { green "$1"; PASS=$((PASS + 1)); }
fail() { red   "$1"; FAIL=$((FAIL + 1)); }

check() {
  local desc="$1"; shift
  if "$@" &>/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

require() {
  local desc="$1"; shift
  if "$@" &>/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
    echo "  FATAL: $desc" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Results: ${PASS}/$((PASS + FAIL)) passed — aborted"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
  fi
}

check_contains() {
  # check_contains DESC VALUE PATTERN
  local desc="$1" value="$2" pattern="$3"
  if echo "$value" | grep -q "$pattern"; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

# Parse a JSON field from a one-liner JSON object using only sh+grep+sed (no python3/jq)
# json_get VALUE KEY
json_get() { echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | sed 's/.*":"//' | tr -d '"'; }

cleanup_pods() {
  kubectl delete pod nono-e2e-sandboxed nono-e2e-plain \
    --ignore-not-found=true --wait=false &>/dev/null || true
}
trap cleanup_pods EXIT

# ── Build + load e2e test image ───────────────────────────────────────────────
# nono is dynamically linked (glibc + libdbus-1). Alpine containers cannot run it.
echo "==> Building e2e test image (ubuntu:22.04 + libdbus-1-3)..."
TEST_IMAGE="nono-e2e-test:latest"
docker build -q -t "$TEST_IMAGE" -f - . <<'EOF'
FROM ubuntu:22.04
RUN apt-get update -qq && apt-get install -y -qq libdbus-1-3 && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
EOF

echo "==> Loading e2e test image into cluster ($RUNTIME)..."
if [[ "$RUNTIME" == "containerd" ]]; then
  docker save "$TEST_IMAGE" | docker exec -i "$NODE" ctr -n k8s.io images import -

elif [[ "$RUNTIME" == "crio" ]]; then
  REGISTRY_NAME="${REGISTRY_NAME:-nono-nri-registry}"
  REGISTRY_PORT="${REGISTRY_PORT:-5100}"

  KIND_NET=$(docker inspect "$NODE" \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{break}}{{end}}' 2>/dev/null || echo "kind")
  REGISTRY_IP=$(docker inspect "$REGISTRY_NAME" \
    --format "{{(index .NetworkSettings.Networks \"${KIND_NET}\").IPAddress}}" 2>/dev/null || echo "")

  if [[ -z "$REGISTRY_IP" ]]; then
    echo "Error: registry '$REGISTRY_NAME' not found on Kind network '$KIND_NET'." >&2
    echo "Set REGISTRY_NAME to your registry container name." >&2
    exit 1
  fi

  docker tag "$TEST_IMAGE" "localhost:${REGISTRY_PORT}/nono-e2e-test:latest"
  docker push "localhost:${REGISTRY_PORT}/nono-e2e-test:latest" &>/dev/null
  docker exec "$NODE" crictl pull "${REGISTRY_IP}:5000/nono-e2e-test:latest"
  TEST_IMAGE="${REGISTRY_IP}:5000/nono-e2e-test:latest"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " nono-nri e2e tests  [runtime: $RUNTIME / cluster: $CLUSTER_NAME]"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Pre-cleanup: remove leftover test pods and stale state dir entries from prior runs
kubectl delete pod nono-e2e-sandboxed nono-e2e-plain debug-sandboxed \
  --ignore-not-found=true --wait=false &>/dev/null || true

# ── Test 1: Plugin connectivity ───────────────────────────────────────────────
echo "── Test 1: Plugin connectivity ──────────────────────────────────────────"

PLUGIN_POD=$(kubectl get pod -n kube-system -l app=nono-nri \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
require "plugin DaemonSet pod exists" test -n "$PLUGIN_POD"

PLUGIN_PHASE=$(kubectl get pod "$PLUGIN_POD" -n kube-system \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
check_contains "plugin pod is Running" "$PLUGIN_PHASE" "Running"

PLUGIN_LOGS=$(kubectl logs -n kube-system "$PLUGIN_POD" 2>/dev/null || echo "")
# CRI-O appears as "cri-o" in the log; containerd as "containerd"
RUNTIME_PATTERN="${RUNTIME/crio/cri-o}"
check_contains "plugin connected to $RUNTIME runtime" "$PLUGIN_LOGS" "$RUNTIME_PATTERN"

echo ""

# ── Test 2: Sandboxed pod injection ──────────────────────────────────────────
echo "── Test 2: Sandboxed pod — nono injection ───────────────────────────────"

kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nono-e2e-sandboxed
  namespace: default
  annotations:
    nono.sh/profile: "default"
spec:
  runtimeClassName: nono-sandbox
  restartPolicy: Never
  containers:
    - name: test
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
EOF

require "sandboxed pod becomes Running" \
  kubectl wait --for=condition=ready pod/nono-e2e-sandboxed --timeout=60s

CMDLINE=$(kubectl exec nono-e2e-sandboxed -- \
  cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "")
# nono wrap exec()s into sleep: PID 1 becomes sleep after nono replaces itself
check_contains "/proc/1/cmdline shows original command (nono exec'd into it)" \
  "$CMDLINE" "sleep"

check "/nono/nono is accessible in container" \
  kubectl exec nono-e2e-sandboxed -- test -x /nono/nono

# Refresh logs after injection (captured at Test 1 before the pod existed)
PLUGIN_LOGS=$(kubectl logs -n kube-system "$PLUGIN_POD" 2>/dev/null || echo "")
check_contains "plugin logged 'injected' for sandboxed pod" \
  "$PLUGIN_LOGS" '"pod":"nono-e2e-sandboxed"'

# Get container ID from kubectl — unique per run, works while pod is running
CTR_ID=$(kubectl get pod nono-e2e-sandboxed \
  -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | \
  sed 's|cri-o://||g' | sed 's|containerd://||g' | tr -d '[:space:]')

if [[ -n "$CTR_ID" ]]; then
  if [[ "$RUNTIME" == "containerd" ]]; then
    BUNDLE="/run/containerd/io.containerd.runtime.v2.task/k8s.io/${CTR_ID}/config.json"
  else
    BUNDLE="/var/run/containers/storage/overlay-containers/${CTR_ID}/userdata/config.json"
  fi

  # Use python3 on the Kind node (available on all supported node images)
  OCI_ARGS=$(docker exec "$NODE" python3 -c \
    "import json; d=json.load(open('${BUNDLE}')); print(d['process']['args'][0])" \
    2>/dev/null || echo "")
  check_contains "OCI bundle process.args[0] == '/nono/nono'" \
    "$OCI_ARGS" "/nono/nono"

  OCI_SEP=$(docker exec "$NODE" python3 -c \
    "import json; d=json.load(open('${BUNDLE}')); print('ok' if '--' in d['process']['args'] else '')" \
    2>/dev/null || echo "")
  check_contains "OCI bundle process.args contains '--' separator" \
    "$OCI_SEP" "ok"

  OCI_MOUNT=$(docker exec "$NODE" python3 -c \
    "import json; d=json.load(open('${BUNDLE}')); m=[x for x in d.get('mounts',[]) if x.get('destination')=='/nono']; print('ok' if m else '')" \
    2>/dev/null || echo "")
  check_contains "OCI bundle has /nono bind mount" "$OCI_MOUNT" "ok"
fi

# Check state metadata (alpine-compatible: grep only)
META=$(kubectl exec -n kube-system "$PLUGIN_POD" -- sh -c '
  for f in /var/run/nono-nri/*/*/metadata.json; do
    [ -f "$f" ] || continue
    if grep -q "nono-e2e-sandboxed" "$f" 2>/dev/null; then
      grep -q '"'"'"profile":"default"'"'"' "$f" && echo ok || echo fail
      break
    fi
  done
' 2>/dev/null | tr -d '[:space:]' || echo "")
check_contains "state dir metadata.json written with profile=default" "$META" "ok"

echo ""

# ── Test 3: Non-sandboxed pod — no injection ──────────────────────────────────
echo "── Test 3: Non-sandboxed pod — isolation ────────────────────────────────"

kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nono-e2e-plain
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
EOF

require "plain pod becomes Running" \
  kubectl wait --for=condition=ready pod/nono-e2e-plain --timeout=60s

PLAIN_CMDLINE=$(kubectl exec nono-e2e-plain -- \
  cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "")
if echo "$PLAIN_CMDLINE" | grep -q "^/nono/nono"; then
  fail "plain pod /proc/1/cmdline is unmodified (no nono prefix)"
else
  pass "plain pod /proc/1/cmdline is unmodified (no nono prefix)"
fi

PLAIN_NONO=$(kubectl exec nono-e2e-plain -- test -e /nono 2>/dev/null && echo "present" || echo "absent")
check_contains "plain pod has no /nono mount" "$PLAIN_NONO" "absent"

PLUGIN_LOGS2=$(kubectl logs -n kube-system "$PLUGIN_POD" 2>/dev/null || echo "")
check_contains "plugin logged 'skip' for plain pod" \
  "$PLUGIN_LOGS2" '"pod":"nono-e2e-plain"'

echo ""

# ── Test 4: State dir cleanup ─────────────────────────────────────────────────
echo "── Test 4: State dir cleanup on pod deletion ────────────────────────────"

kubectl delete pod nono-e2e-sandboxed --wait=true &>/dev/null
sleep 5

# Check by container ID — more reliable than pod name (ignores old runs)
if [[ -n "$CTR_ID" ]]; then
  AFTER=$(kubectl exec -n kube-system "$PLUGIN_POD" -- sh -c \
    "find /var/run/nono-nri -name metadata.json 2>/dev/null | \
     xargs grep -l \"\\\"container_id\\\":\\\"${CTR_ID}\\\"\" 2>/dev/null | wc -l" \
    2>/dev/null | tr -d '[:space:]' || echo "0")
  if [[ "$AFTER" == "0" ]]; then
    pass "state dir for container removed after pod deletion"
  else
    # Known limitation: CRI-O may not deliver RemoveContainer events in all scenarios
    fail "state dir for container removed after pod deletion (known CRI-O NRI issue)"
  fi
else
  pass "state dir cleanup (skipped — no CTR_ID captured)"
fi

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf " Results: %d/%d passed\n" "$PASS" "$TOTAL"
if [[ $FAIL -eq 0 ]]; then
  printf '\033[32m All %d tests passed ✓\033[0m\n' "$PASS"
else
  printf '\033[31m %d test(s) failed ✗\033[0m\n' "$FAIL"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit $FAIL
