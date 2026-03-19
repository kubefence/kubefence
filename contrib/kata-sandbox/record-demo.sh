#!/usr/bin/env bash
# record-demo.sh — asciinema recording script for nono + Kata Containers demo
#
# Shows:
#   - kata-nono-sandbox RuntimeClass (handler: kata-qemu)
#   - Pod runs inside a real QEMU/KVM micro-VM (/proc/cmdline proves it)
#   - /bin/bash is the nono wrapper → exec auto-sandboxes inside the VM
#   - Landlock blocks attacks; plain pod has full access
#
# Record with:
#   asciinema rec \
#     --cols 120 --rows 36 \
#     --title "nono-nri: Kata Containers sandbox demo" \
#     --command "bash contrib/kata-sandbox/record-demo.sh" \
#     contrib/kata-sandbox/demo.cast
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODE="nono-containerd-control-plane"
CTX="kind-nono-containerd"

# ── ANSI helpers ───────────────────────────────────────────────────────────────
RST='\033[0m'; BOLD='\033[1m'
GRN='\033[1;32m'; CYN='\033[1;36m'; YLW='\033[1;33m'
RED='\033[1;31m'; WHT='\033[1;37m'; DIM='\033[2m'; MGN='\033[1;35m'

typewriter() {
  local s="$1" delay="${2:-0.04}"
  for ((i = 0; i < ${#s}; i++)); do
    printf '%s' "${s:$i:1}"
    sleep "$delay"
  done
  echo ""
}

run() {
  echo ""
  printf "${GRN}\$${RST} "
  typewriter "$1"
  sleep 0.2
  eval "$1" || true
  sleep 0.9
}

in_pod() {
  local pod="$1" cmd="$2"
  echo ""
  printf "${MGN}(${pod})${RST} ${GRN}\$${RST} "
  typewriter "$cmd" 0.04
  sleep 0.2
  kubectl --context "$CTX" exec "$pod" -- \
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

# ── Pre-flight ─────────────────────────────────────────────────────────────────
kubectl --context "$CTX" delete pod kata-nono-demo kata-plain-demo \
  --ignore-not-found=true --wait=true >/dev/null 2>&1 || true

docker build -q -t nono-kata-demo:latest "$SCRIPT_DIR" >/dev/null
docker save nono-kata-demo:latest \
  | docker exec -i "$NODE" ctr -n k8s.io images import - >/dev/null 2>&1 || true

# ── Intro ──────────────────────────────────────────────────────────────────────
clear
printf "${BOLD}${WHT}\n"
printf "   ┌──────────────────────────────────────────────────────────────────────────┐\n"
printf "   │                                                                          │\n"
printf "   │   nono-nri · Kata Containers sandbox demo                               │\n"
printf "   │                                                                          │\n"
printf "   │   Runtime  : containerd 2.2.1 + NRI + kata-deploy                       │\n"
printf "   │   Sandbox  : Kata QEMU/KVM micro-VM  +  nono Landlock isolation         │\n"
printf "   │   Approach : nono bind-mounted from host via virtiofs (no initrd embed) │\n"
printf "   │                                                                          │\n"
printf "   └──────────────────────────────────────────────────────────────────────────┘\n"
printf "${RST}\n"
sleep 3

# ══════════════════════════════════════════════════════════════════════════════
section "1 · RuntimeClasses"
# ══════════════════════════════════════════════════════════════════════════════

comment "kata-nono-sandbox = Kata QEMU/KVM VM  +  nono Landlock (handler: kata-qemu)"
run "kubectl get runtimeclasses"

# ══════════════════════════════════════════════════════════════════════════════
section "2 · Apply pods"
# ══════════════════════════════════════════════════════════════════════════════

comment "plain pod — no runtimeClassName, standard runc container, no sandbox"
run "kubectl apply -f $REPO_ROOT/contrib/kata-sandbox/pod-plain.yaml"

comment "kata pod — kata-nono-sandbox: QEMU/KVM micro-VM + nono Landlock inside"
run "kubectl apply -f $REPO_ROOT/contrib/kata-sandbox/pod-kata.yaml"

comment "kata pod takes a few seconds to boot the VM"
run "kubectl wait --for=condition=ready pod/kata-plain-demo pod/kata-nono-demo --timeout=120s"

run "kubectl get pods -l app=nono-kata-demo -o wide"

# ══════════════════════════════════════════════════════════════════════════════
section "3 · Prove kata-nono-demo is a real VM"
# ══════════════════════════════════════════════════════════════════════════════

comment "/proc/cmdline — kata-agent params prove this is a QEMU guest, not a container"
in_pod kata-nono-demo "cat /proc/cmdline"

comment "uptime — the VM was just booted for this pod"
in_pod kata-nono-demo "uptime"

comment "PID 1 is the original command — nono applied Landlock then exec'd into it"
in_pod kata-nono-demo "cat /proc/1/cmdline | tr '\\0' ' '"

comment "/nono/nono bind-mounted from host into the VM via virtiofs"
in_pod kata-nono-demo "ls -lh /nono/nono"

sleep 2

# ══════════════════════════════════════════════════════════════════════════════
section "4 · Plain pod — full access (no sandbox)"
# ══════════════════════════════════════════════════════════════════════════════

comment "standard runc container — /proc/cmdline is the node kernel cmdline"
in_pod kata-plain-demo "cat /proc/cmdline | cut -c1-80"

comment "no /nono mount — bash wrapper falls back to bash.real, no Landlock"
in_pod kata-plain-demo "ls /nono 2>/dev/null || echo 'no /nono mount'"

comment "host file poisoning — allowed"
in_pod kata-plain-demo 'echo "1.2.3.4 evil.com" >> /etc/hosts && echo "injected!"'

comment "credential theft"
in_pod kata-plain-demo "head -3 /etc/shadow"

comment "backdoor binary planted"
in_pod kata-plain-demo 'cp /bin/sh /usr/local/bin/backdoor && echo "planted"'

comment "python runtime — fully accessible"
in_pod kata-plain-demo "python3 -c 'print(\"hello from plain pod\")'"

sleep 2

# ══════════════════════════════════════════════════════════════════════════════
section "5 · Kata pod — exec bash → auto-sandboxed inside the VM"
# ══════════════════════════════════════════════════════════════════════════════

comment "/bin/bash is the nono wrapper — exec auto-applies Landlock inside the VM"
in_pod kata-nono-demo "cat /bin/bash"

comment "host file poisoning — Landlock blocks writes to /etc"
in_pod kata-nono-demo 'echo "1.2.3.4 evil.com" >> /etc/hosts'

comment "credential theft — /etc/shadow unreadable"
in_pod kata-nono-demo "head -3 /etc/shadow"

comment "backdoor binary — write to /usr/local/bin blocked"
in_pod kata-nono-demo 'cp /bin/sh /usr/local/bin/backdoor'

comment "python runtime — Landlock restricts paths, not the runtime itself"
in_pod kata-nono-demo "python3 -c 'print(\"hello from inside the Kata VM sandbox\")'"

comment "scratch space /tmp — writable"
in_pod kata-nono-demo 'echo "workspace" > /tmp/work && cat /tmp/work'

sleep 2

# ══════════════════════════════════════════════════════════════════════════════
section "Summary"
# ══════════════════════════════════════════════════════════════════════════════

echo ""
printf "  ${BOLD}${WHT}%-44s  %-16s  %-20s${RST}\n" "Operation" "plain pod" "kata-nono-sandbox"
printf "  ${DIM}%s${RST}\n" "$(printf '─%.0s' {1..82})"

pr() {
  local op="$1" plain="$2" kata="$3"
  local pc="$GRN" kc="$RED"
  [[ "$plain" != "ALLOWED" ]] && pc="$RED"
  [[ "$kata"  == "ALLOWED" ]] && kc="$GRN"
  printf "  ${DIM}%-44s${RST}  ${pc}%-16s${RST}  ${kc}%-20s${RST}\n" "$op" "$plain" "$kata"
}

pr 'echo "..." >> /etc/hosts'         "ALLOWED" "BLOCKED (Landlock)"
pr "head /etc/shadow"                 "ALLOWED" "BLOCKED (Landlock)"
pr "cp /bin/sh /usr/local/bin/x"     "ALLOWED" "BLOCKED (Landlock)"
printf "  ${DIM}%s${RST}\n" "$(printf '─%.0s' {1..82})"
pr "python3 -c 'print(...)'"         "ALLOWED" "ALLOWED"
pr 'echo "ok" > /tmp/work'           "ALLOWED" "ALLOWED"

echo ""
printf "  ${DIM}VM isolation (Kata QEMU/KVM)  +  Landlock filesystem sandboxing (nono)${RST}\n"
printf "  ${DIM}nono binary delivered into VM via virtiofs bind-mount — no initrd embed${RST}\n"
echo ""
hr
sleep 5
