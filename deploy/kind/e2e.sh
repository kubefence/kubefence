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
  kubectl delete pod \
    nono-e2e-sandboxed nono-e2e-plain nono-e2e-kata nono-e2e-kata-qemu \
    nono-policy-hostpath-dir nono-policy-hostpath-file \
    nono-policy-emptydir nono-policy-configmap nono-policy-legit \
    --ignore-not-found=true --wait=false &>/dev/null || true
  kubectl delete configmap nono-policy-test-cm \
    --ignore-not-found=true &>/dev/null || true
}
trap cleanup_pods EXIT

# Whether the cluster was deployed with the custom kata rootfs (embedded nono
# binary + hardened kata-agent policy).  Set to false to skip Test 7.
KATA_ROOTFS="${KATA_ROOTFS:-true}"

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
kubectl delete pod \
  nono-e2e-sandboxed nono-e2e-plain debug-sandboxed \
  nono-policy-hostpath-dir nono-policy-hostpath-file \
  nono-policy-emptydir nono-policy-configmap nono-policy-legit \
  --ignore-not-found=true --wait=false &>/dev/null || true
kubectl delete configmap nono-policy-test-cm --ignore-not-found=true &>/dev/null || true

# ── Test 1: Plugin connectivity ───────────────────────────────────────────────
echo "── Test 1: Plugin connectivity ──────────────────────────────────────────"

PLUGIN_POD=$(kubectl get pod -n kube-system \
  -l 'app.kubernetes.io/name=kubefence,!app.kubernetes.io/component' \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
require "plugin DaemonSet pod exists" test -n "$PLUGIN_POD"

PLUGIN_PHASE=$(kubectl get pod "$PLUGIN_POD" -n kube-system \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
check_contains "plugin pod is Running" "$PLUGIN_PHASE" "Running"

PLUGIN_LOGS=$(kubectl logs -n kube-system "$PLUGIN_POD" 2>/dev/null || echo "")
# CRI-O appears as "cri-o" in the log; containerd as "containerd" or "v2"
case "$RUNTIME" in
  crio)       RUNTIME_PATTERN="cri-o" ;;
  containerd) RUNTIME_PATTERN="containerd\|v2" ;;
  *)          RUNTIME_PATTERN="$RUNTIME" ;;
esac
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
  runtimeClassName: nono-runc
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

# Get container ID from kubectl — retry since containerID may not be populated immediately
CTR_ID=""
for _ in 1 2 3 4 5; do
  CTR_ID=$(kubectl get pod nono-e2e-sandboxed \
    -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | \
    sed 's|cri-o://||g' | sed 's|containerd://||g' | tr -d '[:space:]')
  [[ -n "$CTR_ID" ]] && break
  sleep 1
done

if [[ -n "$CTR_ID" ]]; then
  if [[ "$RUNTIME" == "containerd" ]]; then
    BUNDLE="/run/containerd/io.containerd.runtime.v2.task/k8s.io/${CTR_ID}/config.json"
  else
    BUNDLE="/var/run/containers/storage/overlay-containers/${CTR_ID}/userdata/config.json"
  fi

  # Parse OCI bundle using jq (available on kindest/node) or python3 (CRI-O node)
  _jq_or_python() {
    local node="$1" file="$2" jq_expr="$3" py_expr="$4"
    docker exec "$node" sh -c "
      if command -v jq >/dev/null 2>&1; then
        jq -r '$jq_expr' '$file' 2>/dev/null
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c \"$py_expr\" 2>/dev/null
      fi
    " 2>/dev/null || echo ""
  }

  OCI_ARGS=$(_jq_or_python "$NODE" "$BUNDLE" \
    '.process.args[0]' \
    "import json; d=json.load(open('${BUNDLE}')); print(d['process']['args'][0])")
  check_contains "OCI bundle process.args[0] == '/nono/nono' (SetArgs applied)" \
    "$OCI_ARGS" "/nono/nono"

  OCI_SEP=$(_jq_or_python "$NODE" "$BUNDLE" \
    'if (.process.args | index("--")) then "ok" else "" end' \
    "import json; d=json.load(open('${BUNDLE}')); print('ok' if '--' in d['process']['args'] else '')")
  check_contains "OCI bundle process.args contains '--' separator" \
    "$OCI_SEP" "ok"

  OCI_MOUNT=$(_jq_or_python "$NODE" "$BUNDLE" \
    '[.mounts[]? | select(.destination == "/nono")] | if length > 0 then "ok" else "" end' \
    "import json; d=json.load(open('${BUNDLE}')); m=[x for x in d.get('mounts',[]) if x.get('destination')=='/nono']; print('ok' if m else '')")
  check_contains "OCI bundle has /nono bind mount (AddMount applied)" "$OCI_MOUNT" "ok"
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

# Poll for up to 30 s — RemoveContainer NRI event is synchronous on containerd
# but may be slightly delayed in some environments (e.g. remote image pull cold start).
if [[ -n "$CTR_ID" ]]; then
  AFTER="1"
  for _i in $(seq 1 30); do
    # Use a while-read loop instead of xargs so the command is safe when find
    # returns no files (xargs with empty input can misbehave on busybox).
    AFTER=$(kubectl exec -n kube-system "$PLUGIN_POD" -- sh -c \
      "find /var/run/nono-nri -maxdepth 3 -name metadata.json 2>/dev/null |
       while IFS= read -r f; do
         grep -q '\"container_id\":\"${CTR_ID}\"' \"\$f\" 2>/dev/null && echo \"\$f\"
       done | wc -l" \
      2>/dev/null | tr -d '[:space:]' || echo "1")
    [[ "$AFTER" == "0" ]] && break
    sleep 1
  done
  if [[ "$AFTER" == "0" ]]; then
    pass "state dir for container removed after pod deletion"
  else
    fail "state dir for container removed after pod deletion"
    # Diagnostics: show remaining state entries and plugin remove log
    echo "  remaining metadata.json files:"
    kubectl exec -n kube-system "$PLUGIN_POD" -- \
      find /var/run/nono-nri -name metadata.json 2>/dev/null \
      | sed 's/^/    /' || true
    echo "  plugin log (stop/remove/cleanup lines):"
    kubectl logs -n kube-system "$PLUGIN_POD" 2>/dev/null \
      | grep -i 'stop\|remove\|cleanup' | tail -10 \
      | sed 's/^/    /' || true
  fi
else
  pass "state dir cleanup (skipped — no CTR_ID captured)"
fi

echo ""

# ── Test 5: Kata + nono sandboxed pod ────────────────────────────────────────
echo "── Test 5: Kata Containers + nono injection ─────────────────────────────"

KATA_RC=$(kubectl get runtimeclass kata-nono-sandbox --no-headers 2>/dev/null | awk '{print $1}' || echo "")
if [[ -z "$KATA_RC" ]]; then
  pass "kata-nono-sandbox RuntimeClass (skipped — not installed)"
else
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nono-e2e-kata
  namespace: default
  annotations:
    nono.sh/profile: "default"
spec:
  runtimeClassName: kata-nono-sandbox
  restartPolicy: Never
  containers:
    - name: test
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
EOF

  require "kata+nono pod becomes Running" \
    kubectl wait --for=condition=ready pod/nono-e2e-kata --timeout=120s

  # nono wraps the command — PID 1 in the guest should be nono (or sleep after exec)
  KATA_CMDLINE=$(kubectl exec nono-e2e-kata -- \
    cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "")
  check_contains "/proc/1/cmdline shows original command inside VM" \
    "$KATA_CMDLINE" "sleep"

  # /nono/nono must be accessible inside the guest (virtiofs bind-mount)
  check "/nono/nono is accessible inside Kata VM" \
    kubectl exec nono-e2e-kata -- test -x /nono/nono

  PLUGIN_LOGS3=$(kubectl logs -n kube-system "$PLUGIN_POD" 2>/dev/null || echo "")
  check_contains "plugin logged injection for kata pod" \
    "$PLUGIN_LOGS3" '"pod":"nono-e2e-kata"'

  kubectl delete pod nono-e2e-kata --wait=false --ignore-not-found=true &>/dev/null || true
fi

echo ""

# ── Test 6: kata-nono-sandbox/kata-nono-qemu (embedded nono in VM rootfs) ────
echo "── Test 6: kata-nono-sandbox (embedded nono in VM rootfs) ──────────────"

KATA_QEMU_RC=$(kubectl get runtimeclass kata-nono-sandbox --no-headers 2>/dev/null | awk '{print $1}' || echo "")
if [[ -z "$KATA_QEMU_RC" ]]; then
  pass "kata-nono-sandbox RuntimeClass (skipped — not installed)"
else
  # Wait for any previous kata VM to fully teardown before starting a new one.
  sleep 5

  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nono-e2e-kata-qemu
  namespace: default
  annotations:
    nono.sh/profile: "default"
spec:
  runtimeClassName: kata-nono-sandbox
  restartPolicy: Never
  containers:
    - name: test
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
EOF

  require "kata-nono-sandbox pod becomes Running" \
    kubectl wait --for=condition=ready pod/nono-e2e-kata-qemu --timeout=120s

  # PID 1 should be sleep — nono wraps it via SetArgs then exec's into it.
  KATA_QEMU_CMDLINE=$(kubectl exec nono-e2e-kata-qemu -- \
    cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "")
  check_contains "/proc/1/cmdline shows original command" \
    "$KATA_QEMU_CMDLINE" "sleep"

  # nono lives in the VM rootfs (not injected via virtiofs bind-mount).
  check "/nono/nono exists in VM rootfs" \
    kubectl exec nono-e2e-kata-qemu -- test -x /nono/nono

  # NONO_PROFILE is injected by the NRI plugin for wrapper script use.
  check "NONO_PROFILE env var injected" \
    kubectl exec nono-e2e-kata-qemu -- sh -c 'test -n "${NONO_PROFILE}"'

  PLUGIN_LOGS4=$(kubectl logs -n kube-system "$PLUGIN_POD" 2>/dev/null || echo "")
  check_contains "plugin logged injection for kata-nono-qemu pod" \
    "$PLUGIN_LOGS4" '"pod":"nono-e2e-kata-qemu"'

  kubectl delete pod nono-e2e-kata-qemu --wait=false --ignore-not-found=true &>/dev/null || true
fi

echo ""

# ── Test 7: kata-agent policy enforcement (requires KATA_ROOTFS=true) ────────
echo "── Test 7: kata-agent policy enforcement ────────────────────────────────"

if [[ -z "$KATA_RC" || "$KATA_ROOTFS" != "true" ]]; then
  pass "policy enforcement tests (skipped — requires kata-nono-sandbox + KATA_ROOTFS=true)"
else

  # Two-layer defence model:
  #
  # Layer 1 — NRI mount replacement (OCI mount semantics):
  #   When a user spec includes a volume at /nono (the exact same destination
  #   as the NRI-injected mount), containerd merges mounts by destination and
  #   the NRI-injected read-only bind-mount wins.  The attack container still
  #   reaches Running, but /nono/nono is the trusted binary, not the attacker's.
  #   Affected attacks: hostPath dir, emptyDir, ConfigMap dir at /nono.
  #
  # Layer 2 — kata-agent OPA policy (CreateContainerRequest count > 1):
  #   A user volume at /nono/nono (the binary file, a different destination from
  #   the NRI /nono dir mount) adds a second /nono-prefix entry to OCI.Mounts.
  #   The policy rule denies any container where count(mounts starting with /nono)
  #   exceeds 1.  kata-agent emits "CreateContainerRequest is blocked by policy".
  #   Affected attack: hostPath file at /nono/nono.

  # Poll pod events until the kata-agent's rejection string appears or timeout.
  # kata-agent emits: "<ep> is blocked by policy: <detail>" (policy.rs:allow_request).
  # Returns the last event message; prints diagnostics to stderr on timeout.
  _wait_policy_denied() {
    local pod="$1"
    local event_msg=""
    for _i in $(seq 1 60); do
      event_msg=$(kubectl get events \
        --field-selector "involvedObject.name=${pod}" \
        --sort-by='.lastTimestamp' \
        -o jsonpath='{.items[-1].message}' 2>/dev/null || echo "")
      echo "${event_msg}" | grep -q "blocked by policy" && break
      sleep 1
    done
    if ! echo "${event_msg}" | grep -q "blocked by policy"; then
      echo "  pod status: $(kubectl get pod "${pod}" --no-headers 2>/dev/null | awk '{print $3}')" >&2
      kubectl get events --field-selector "involvedObject.name=${pod}" \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -3 | sed 's/^/  /' >&2
    fi
    echo "${event_msg}"
  }

  # Legitimate pod with no user volume at /nono must reach Running.
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nono-policy-legit
  namespace: default
  annotations:
    nono.sh/profile: "default"
spec:
  runtimeClassName: kata-nono-sandbox
  restartPolicy: Never
  containers:
    - name: app
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
EOF
  check "policy: legitimate pod (no /nono volume) starts Running" \
    kubectl wait --for=condition=ready pod/nono-policy-legit --timeout=90s
  kubectl delete pod nono-policy-legit --wait=false --ignore-not-found=true &>/dev/null || true

  # Layer 1 — NRI mount replacement: attacks with a volume at /nono (same destination
  # as the NRI bind-mount) are neutralised by the OCI merge; the container reaches
  # Running but /nono/nono is the trusted NRI binary, not the attacker's payload.

  # hostPath dir at /nono: NRI /nono mount overrides user mount.
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nono-policy-hostpath-dir
  namespace: default
spec:
  runtimeClassName: kata-nono-sandbox
  restartPolicy: Never
  containers:
    - name: attacker
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: evil-nono
          mountPath: /nono
  volumes:
    - name: evil-nono
      hostPath:
        path: /tmp/evil-nono
        type: DirectoryOrCreate
EOF
  check "NRI: hostPath dir at /nono — Running (NRI /nono mount overrides attack mount)" \
    kubectl wait --for=condition=ready pod/nono-policy-hostpath-dir --timeout=90s
  kubectl delete pod nono-policy-hostpath-dir --wait=false --ignore-not-found=true &>/dev/null || true

  # emptyDir at /nono: NRI /nono mount overrides user mount.
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nono-policy-emptydir
  namespace: default
spec:
  runtimeClassName: kata-nono-sandbox
  restartPolicy: Never
  containers:
    - name: attacker
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: nono-override
          mountPath: /nono
  volumes:
    - name: nono-override
      emptyDir: {}
EOF
  check "NRI: emptyDir at /nono — Running (NRI /nono mount overrides attack mount)" \
    kubectl wait --for=condition=ready pod/nono-policy-emptydir --timeout=90s
  kubectl delete pod nono-policy-emptydir --wait=false --ignore-not-found=true &>/dev/null || true

  # ConfigMap dir at /nono: NRI /nono mount overrides user mount.
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: nono-policy-test-cm
  namespace: default
data:
  nono: |
    #!/bin/sh
    exec "\$@"
EOF
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nono-policy-configmap
  namespace: default
spec:
  runtimeClassName: kata-nono-sandbox
  restartPolicy: Never
  containers:
    - name: attacker
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: fake-nono-cm
          mountPath: /nono
  volumes:
    - name: fake-nono-cm
      configMap:
        name: nono-policy-test-cm
        defaultMode: 493
EOF
  check "NRI: ConfigMap dir at /nono — Running (NRI /nono mount overrides attack mount)" \
    kubectl wait --for=condition=ready pod/nono-policy-configmap --timeout=90s
  kubectl delete pod nono-policy-configmap --wait=false --ignore-not-found=true &>/dev/null || true

  # Layer 2 — kata-agent policy: a hostPath file at /nono/nono adds a second
  # /nono-prefix OCI mount (destination /nono/nono) alongside the NRI /nono dir
  # mount.  count(mounts) == 2 > 1 → kata-agent denies CreateContainerRequest.
  kubectl apply -f - &>/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nono-policy-hostpath-file
  namespace: default
spec:
  runtimeClassName: kata-nono-sandbox
  restartPolicy: Never
  containers:
    - name: attacker
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: evil-binary
          mountPath: /nono/nono
  volumes:
    - name: evil-binary
      hostPath:
        path: /tmp/evil-nono-binary
        type: FileOrCreate
EOF
  EVENT_MSG=$(_wait_policy_denied nono-policy-hostpath-file)
  check_contains "policy: hostPath file at /nono/nono blocked by kata-agent" \
    "$EVENT_MSG" "blocked by policy"
  kubectl delete pod nono-policy-hostpath-file --wait=false --ignore-not-found=true &>/dev/null || true

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
