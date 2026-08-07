#!/usr/bin/env bash
# genpolicy-verify.sh — run the hardened policy against real genpolicy output.
#
# policy_test.rego asserts against mount fixtures transcribed by hand from
# genpolicy analysis. This asserts against the genpolicy output itself, so a
# hand-transcription that drifts from what kata actually emits gets caught.
#
# For each pod in attack-manifests/genpolicy-output/, every container's OCI
# spec is fed to CreateContainerRequest in policy.rego:
#
#   attack-*.rego      at least one container must be DENIED
#   legitimate-*.rego  every container must be ALLOWED
#
# The expectation comes from the filename, so dropping a new genpolicy dump in
# that directory is enough to cover it — there is no table to update.
#
# Note on inputs: genpolicy's policy_data is a matcher template, and its
# `source` fields carry regex markers like $(sfprefix). CreateContainerRequest
# only reads .destination and .options, which are literal, so the spec is
# usable as request input unmodified. A rule that keyed on `source` would not
# be testable this way.
#
# Requires: opa (same dependency as `make policy-test`).
#
# Usage:
#   bash deploy/kata-extension/genpolicy-verify.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$DIR/policy.rego"
OUTDIR="$DIR/attack-manifests/genpolicy-output"

command -v opa >/dev/null || {
    echo "ERROR: opa not found — https://openpolicyagent.org/docs/latest/#running-opa" >&2
    exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
shopt -s nullglob
files=("$OUTDIR"/*.rego)
[ ${#files[@]} -gt 0 ] || { echo "ERROR: no .rego files in $OUTDIR" >&2; exit 1; }

for f in "${files[@]}"; do
    name=$(basename "$f" .rego)
    total=$(opa eval -d "$f" -f raw 'count(data.agent_policy.policy_data.containers)')

    denied=0
    verdicts=""
    for ((i = 0; i < total; i++)); do
        opa eval -d "$f" -f raw \
            "json.marshal({\"OCI\": data.agent_policy.policy_data.containers[$i].OCI})" \
            > "$WORK/input.json"
        allowed=$(opa eval -d "$POLICY" -i "$WORK/input.json" -f raw \
            'data.agent_policy.CreateContainerRequest')
        if [ "$allowed" = "true" ]; then
            verdicts+=" c${i}:allow"
        else
            verdicts+=" c${i}:DENY"
            denied=$((denied + 1))
        fi
    done

    case "$name" in
        attack-*)
            if [ "$denied" -ge 1 ]; then
                printf 'PASS  %-38s %d/%d denied  |%s\n' "$name" "$denied" "$total" "$verdicts"
            else
                printf 'FAIL  %-38s attack allowed by policy  |%s\n' "$name" "$verdicts"
                fail=1
            fi
            ;;
        legitimate-*)
            if [ "$denied" -eq 0 ]; then
                printf 'PASS  %-38s %d/%d allowed |%s\n' "$name" "$total" "$total" "$verdicts"
            else
                printf 'FAIL  %-38s legitimate pod denied     |%s\n' "$name" "$verdicts"
                fail=1
            fi
            ;;
        *)
            printf 'FAIL  %-38s name must start with attack- or legitimate-\n' "$name"
            fail=1
            ;;
    esac
done

[ "$fail" -eq 0 ] && echo "" && echo "All genpolicy fixtures behave as expected."
exit "$fail"
