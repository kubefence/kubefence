#!/usr/bin/env bash
# record-demo.sh — asciinema recording script for nono python-dev demo
#
# Shows: cluster config → baseline (unsandboxed) → nono sandbox
# Demonstrates Landlock filesystem isolation: attack surface blocked,
# Python runtime preserved.
#
# Record with:
#   asciinema rec \
#     --cols 120 --rows 36 \
#     --title "nono-nri: python-dev sandbox demo" \
#     --command "bash contrib/python-dev/record-demo.sh" \
#     contrib/python-dev/demo.cast
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODE="nono-containerd-control-plane"

# ── ANSI helpers ───────────────────────────────────────────────────────────────
RST='\033[0m'; BOLD='\033[1m'
GRN='\033[1;32m'; CYN='\033[1;36m'
RED='\033[1;31m'; WHT='\033[1;37m'; DIM='\033[2m'

typewriter() {
  local s="$1" delay="${2:-0.035}"
  for ((i = 0; i < ${#s}; i++)); do
    printf '%s' "${s:$i:1}"
    sleep "$delay"
  done
  echo ""
}

# show prompt with typewriter, then execute (continues even on non-zero exit)
run() {
  echo ""
  printf "${GRN}\$${RST} "
  typewriter "$1"
  sleep 0.2
  eval "$1" || true
  sleep 1.0
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

# fmt_log: pretty-print nono JSON log lines from a pipeline.
# IMPORTANT: use python3 -c '...' so stdin is the pipe, not a heredoc.
fmt_log() {
  python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        t   = d.get("time", "")[:19].replace("T", " ")
        lvl = d.get("level", "INFO")[:4].upper()
        msg = d.get("msg", "")
        skip = {"time", "level", "msg"}
        extras = "  ".join(f"{k}={v}" for k, v in d.items() if k not in skip)
        print(f"  {t}  {lvl:<4}  {msg:<22} {extras}")
    except Exception:
        print(" ", line)
' 2>/dev/null || true
}

# ── Pre-flight: clean stale jobs and load image ────────────────────────────────
kubectl --context kind-nono-containerd delete job \
  python-dev-baseline python-dev-sandbox \
  --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
sleep 1

docker build -q -t nono-demo-python:latest "$SCRIPT_DIR" >/dev/null
docker save nono-demo-python:latest \
  | docker exec -i "$NODE" ctr -n k8s.io images import - >/dev/null 2>&1 || true

# ── Intro ──────────────────────────────────────────────────────────────────────
clear
printf "${BOLD}${WHT}\n"
printf "   ┌──────────────────────────────────────────────────────────────────────────┐\n"
printf "   │                                                                          │\n"
printf "   │   nono-nri · python-dev sandbox demo                                    │\n"
printf "   │                                                                          │\n"
printf "   │   Runtime  : containerd 2.2.1 + NRI (Node Resource Interface)           │\n"
printf "   │   Sandbox  : nono wrap — Landlock filesystem isolation                  │\n"
printf "   │   Profile  : default (wrap-compatible; Landlock V4)                     │\n"
printf "   │                                                                          │\n"
printf "   │   Demo     : attack surface blocked, Python runtime preserved            │\n"
printf "   │                                                                          │\n"
printf "   └──────────────────────────────────────────────────────────────────────────┘\n"
printf "${RST}\n"
sleep 3

# ══════════════════════════════════════════════════════════════════════════════
section "1 · Cluster Configuration"
# ══════════════════════════════════════════════════════════════════════════════

comment "switch to the containerd Kind cluster"
run "kubectl config use-context kind-nono-containerd"

comment "one node — containerd 2.2.1 with NRI support built in"
run "kubectl get nodes -o wide"

comment "RuntimeClass: kata-nono-sandbox routes pods to the kata-qemu OCI handler"
run "kubectl describe runtimeclass kata-nono-sandbox"

comment "containerd config: NRI plugin subsystem enabled at /var/run/nri/nri.sock"
run "docker exec $NODE grep -A7 'io.containerd.nri' /etc/containerd/config.toml"

comment "nono-nri plugin config: intercept nono-runc containers, inject nono wrap"
run "docker exec $NODE cat /etc/nri/conf.d/10-nono-nri.toml"

comment "nono binary on the node — installed by DaemonSet init container"
run "docker exec $NODE ls -lh /opt/nono-nri/nono"

comment "nono-nri DaemonSet — one pod per node, connected to containerd NRI socket"
run "kubectl -n kube-system get pods -l app=nono-nri -o wide"

comment "plugin startup log — connected and ready"
run "kubectl -n kube-system logs -l app=nono-nri --tail=3 2>/dev/null | fmt_log"

# ══════════════════════════════════════════════════════════════════════════════
section "2 · Baseline — no runtimeClassName (unsandboxed)"
# ══════════════════════════════════════════════════════════════════════════════

comment "job spec: no runtimeClassName, no nono annotation — plain container"
run "head -20 $REPO_ROOT/contrib/python-dev/job-baseline.yaml"

comment "apply the baseline job"
run "kubectl apply -f $REPO_ROOT/contrib/python-dev/job-baseline.yaml"

comment "wait for job to complete"
run "kubectl wait --for=condition=complete job/python-dev-baseline --timeout=120s"

comment "result: all attack scenarios succeed — no sandbox protection"
run "kubectl logs job/python-dev-baseline"

sleep 2

# ══════════════════════════════════════════════════════════════════════════════
section "3 · nono Sandbox — Landlock filesystem isolation"
# ══════════════════════════════════════════════════════════════════════════════

comment "job spec: runtimeClassName triggers NRI plugin"
run "head -25 $REPO_ROOT/contrib/python-dev/job-sandbox.yaml"

comment "NRI plugin prepends to OCI args:"
comment "  /nono/nono wrap --profile default -- /bin/bash -c ..."
comment "nono applies Landlock, then exec()s into bash (PID 1 = bash)"
echo ""

comment "apply the sandbox job"
run "kubectl apply -f $REPO_ROOT/contrib/python-dev/job-sandbox.yaml"

comment "wait for job to complete"
run "kubectl wait --for=condition=complete job/python-dev-sandbox --timeout=120s"

comment "result: filesystem attacks blocked; Python runtime unaffected"
run "kubectl logs job/python-dev-sandbox"

comment "plugin log: injection event for this pod"
run "kubectl -n kube-system logs -l app=nono-nri 2>/dev/null | grep 'python-dev-sandbox' | tail -2 | fmt_log"

# ══════════════════════════════════════════════════════════════════════════════
section "Summary"
# ══════════════════════════════════════════════════════════════════════════════

echo ""
printf "  ${BOLD}${WHT}%-46s  %-14s  %-16s${RST}\n" "Operation" "Baseline" "nono sandbox"
printf "  ${DIM}%s${RST}\n" "$(printf '─%.0s' {1..78})"

pr() {
  local op="$1" base="$2" box="$3"
  local bc="$GRN" sc="$RED"
  [[ "$base" != "ALLOWED" ]] && bc="$RED"
  [[ "$box"  == "ALLOWED" ]] && sc="$GRN"
  printf "  ${DIM}%-46s${RST}  ${bc}%-14s${RST}  ${sc}%-16s${RST}\n" "$op" "$base" "$box"
}

pr "write /etc/hosts (host poisoning)"          "ALLOWED" "BLOCKED"
pr "write /usr/local/bin/exploit (backdoor)"    "ALLOWED" "BLOCKED"
pr "read  /etc/shadow (credential theft)"       "ALLOWED" "BLOCKED"
pr "read  /etc/passwd (user enumeration)"       "ALLOWED" "BLOCKED"
pr "write site-packages/evil.py (pkg inject)"   "ALLOWED" "BLOCKED"
printf "  ${DIM}%s${RST}\n" "$(printf '─%.0s' {1..78})"
pr "python3 --version"                          "ALLOWED" "ALLOWED"
pr "python3 -c print(...)"                      "ALLOWED" "ALLOWED"
pr "write /tmp/workfile"                        "ALLOWED" "ALLOWED"

echo ""
printf "  ${DIM}Enforcement: Linux Landlock LSM · kernel %s · zero changes to container image${RST}\n" \
  "$(uname -r)"
echo ""
hr
sleep 5
