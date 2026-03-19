#!/usr/bin/env bash
# record-demo.sh — asciinema recording script for nono node-dev manual exec demo
#
# Shows: apply pods → exec baseline (all ALLOWED) → exec sandbox (attacks BLOCKED)
# /bin/bash is the nono wrapper, so plain `kubectl exec -- bash` auto-sandboxes.
#
# Record with:
#   asciinema rec \
#     --cols 120 --rows 36 \
#     --title "nono-nri: node-dev sandbox demo (manual exec)" \
#     --command "bash contrib/node-dev/record-demo.sh" \
#     contrib/node-dev/demo.cast
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODE="nono-containerd-control-plane"

# ── ANSI helpers ───────────────────────────────────────────────────────────────
RST='\033[0m'; BOLD='\033[1m'
GRN='\033[1;32m'; CYN='\033[1;36m'; YLW='\033[1;33m'
RED='\033[1;31m'; WHT='\033[1;37m'; DIM='\033[2m'

typewriter() {
  local s="$1" delay="${2:-0.04}"
  for ((i = 0; i < ${#s}; i++)); do
    printf '%s' "${s:$i:1}"
    sleep "$delay"
  done
  echo ""
}

# host-level kubectl commands (with $ prompt)
run() {
  echo ""
  printf "${GRN}\$${RST} "
  typewriter "$1"
  sleep 0.2
  eval "$1" || true
  sleep 0.9
}

# exec a command inside a pod, simulating an interactive shell session
in_pod() {
  local pod="$1" cmd="$2"
  echo ""
  printf "${YLW}(%s)${RST} ${GRN}\$${RST} "
  typewriter "$cmd" 0.04
  sleep 0.2
  kubectl --context kind-nono-containerd exec "$pod" -- \
    bash -c "$cmd" 2>&1 | \
    grep -Ev "^\s*nono v|^\s*Capabilities|^\s*─+|^\s*\+\s+[0-9]+|^\s*net\s+|^\s*kernel\s+|^\s*degraded|Applying sandbox|Skipping CWD|command terminated" | \
    sed 's|/bin/bash\.real: line [0-9]*: ||g' || true
  sleep 0.8
}

comment() { printf "${DIM}  # %s${RST}\n" "$1"; sleep 0.5; }

section() {
  echo ""; echo ""
  printf "${BOLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"
  printf "${BOLD}${CYN}  %s${RST}\n" "$1"
  printf "${BOLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"
  echo ""; sleep 0.5
}

hr() { printf "${DIM}%s${RST}\n" "$(printf '─%.0s' {1..80})"; }

# ── Pre-flight: clean, build, load ────────────────────────────────────────────
kubectl --context kind-nono-containerd delete pod node-dev-baseline node-dev-sandbox \
  --ignore-not-found=true --wait=true >/dev/null 2>&1 || true

docker build -q -t nono-demo-node:latest "$SCRIPT_DIR" >/dev/null
docker save nono-demo-node:latest \
  | docker exec -i "$NODE" ctr -n k8s.io images import - >/dev/null 2>&1 || true

# ── Intro ──────────────────────────────────────────────────────────────────────
clear
printf "${BOLD}${WHT}\n"
printf "   ┌──────────────────────────────────────────────────────────────────────────┐\n"
printf "   │                                                                          │\n"
printf "   │   nono-nri · node-dev sandbox demo — manual exec                        │\n"
printf "   │                                                                          │\n"
printf "   │   Runtime  : containerd 2.2.1 + NRI                                     │\n"
printf "   │   Sandbox  : nono wrap — Landlock filesystem isolation                  │\n"
printf "   │   Key      : /bin/bash is the nono wrapper — exec auto-sandboxes        │\n"
printf "   │                                                                          │\n"
printf "   └──────────────────────────────────────────────────────────────────────────┘\n"
printf "${RST}\n"
sleep 3

# ══════════════════════════════════════════════════════════════════════════════
section "1 · Apply pods"
# ══════════════════════════════════════════════════════════════════════════════

comment "baseline: no runtimeClassName — plain node container"
run "kubectl apply -f $REPO_ROOT/contrib/node-dev/pod-baseline.yaml"

comment "sandbox: runtimeClassName nono-sandbox — NRI injects nono wrap at start"
run "kubectl apply -f $REPO_ROOT/contrib/node-dev/pod-sandbox.yaml"

run "kubectl wait --for=condition=ready pod/node-dev-baseline pod/node-dev-sandbox --timeout=60s"

run "kubectl get pods -l app=nono-demo -o wide"

comment "sandbox PID 1: nono exec'd into sleep (nono itself vanished)"
run "kubectl exec node-dev-sandbox -- cat /proc/1/cmdline | tr '\\0' ' '"

# ══════════════════════════════════════════════════════════════════════════════
section "2 · Baseline — kubectl exec -it node-dev-baseline -- bash"
# ══════════════════════════════════════════════════════════════════════════════

comment "no /nono mount → wrapper falls back to bash.real, no sandbox"
in_pod node-dev-baseline "cat /bin/bash"

comment "host file poisoning"
in_pod node-dev-baseline 'echo "1.2.3.4 evil.com" >> /etc/hosts && echo "injected!"'

comment "credential theft"
in_pod node-dev-baseline "cat /etc/shadow | head -4"

comment "backdoor binary in /usr/local/bin"
in_pod node-dev-baseline 'echo "#!/bin/sh" > /usr/local/bin/exploit && echo "backdoor planted"'

comment "node runtime — fully accessible"
in_pod node-dev-baseline "node --version"
in_pod node-dev-baseline "node -e 'console.log(\"hello from baseline\")'"

sleep 2

# ══════════════════════════════════════════════════════════════════════════════
section "3 · Sandbox — kubectl exec -it node-dev-sandbox -- bash"
# ══════════════════════════════════════════════════════════════════════════════

comment "/bin/bash is the nono wrapper — /nono/nono mounted by NRI → auto-sandboxes"
in_pod node-dev-sandbox "cat /bin/bash"

comment "host file poisoning — Landlock blocks writes to /etc"
in_pod node-dev-sandbox 'echo "1.2.3.4 evil.com" >> /etc/hosts'

comment "credential theft — /etc/shadow unreadable"
in_pod node-dev-sandbox "cat /etc/shadow"

comment "backdoor binary — write to /usr/local/bin blocked"
in_pod node-dev-sandbox 'echo "#!/bin/sh" > /usr/local/bin/exploit'

comment "node runtime — Landlock restricts paths, not the runtime itself"
in_pod node-dev-sandbox "node --version"
in_pod node-dev-sandbox "node -e 'console.log(\"hello from nono sandbox\")'"

comment "scratch space /tmp — writable"
in_pod node-dev-sandbox 'echo "workspace" > /tmp/work && cat /tmp/work'

sleep 2

# ══════════════════════════════════════════════════════════════════════════════
section "Summary"
# ══════════════════════════════════════════════════════════════════════════════

echo ""
printf "  ${BOLD}${WHT}%-44s  %-14s  %-16s${RST}\n" "Operation" "Baseline" "nono sandbox"
printf "  ${DIM}%s${RST}\n" "$(printf '─%.0s' {1..76})"

pr() {
  local op="$1" base="$2" box="$3"
  local bc="$GRN" sc="$RED"
  [[ "$base" != "ALLOWED" ]] && bc="$RED"
  [[ "$box"  == "ALLOWED" ]] && sc="$GRN"
  printf "  ${DIM}%-44s${RST}  ${bc}%-14s${RST}  ${sc}%-16s${RST}\n" "$op" "$base" "$box"
}

pr 'echo "..." >> /etc/hosts'         "ALLOWED" "BLOCKED"
pr "cat /etc/shadow"                  "ALLOWED" "BLOCKED"
pr 'echo > /usr/local/bin/exploit'    "ALLOWED" "BLOCKED"
printf "  ${DIM}%s${RST}\n" "$(printf '─%.0s' {1..76})"
pr "node --version"                   "ALLOWED" "ALLOWED"
pr "node -e 'console.log(...)'"       "ALLOWED" "ALLOWED"
pr 'echo "ok" > /tmp/work'            "ALLOWED" "ALLOWED"

echo ""
printf "  ${DIM}Plain \`kubectl exec -- bash\` auto-sandboxes because /bin/bash is the nono wrapper${RST}\n"
echo ""
hr
sleep 4
