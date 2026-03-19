#!/usr/bin/env bash
# demo.sh — go-dev profile nono sandbox demonstration
#
# Usage:
#   RUNTIME=containerd CLUSTER_NAME=nono-containerd bash contrib/go-dev/demo.sh
#   RUNTIME=crio       CLUSTER_NAME=nono-crio       bash contrib/go-dev/demo.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME="${RUNTIME:-containerd}"
CLUSTER_NAME="${CLUSTER_NAME:-nono-${RUNTIME}}"
NODE="${CLUSTER_NAME}-control-plane"

LOCAL_IMAGE="nono-demo-go:latest"
JOB_IMAGE="$LOCAL_IMAGE"

# ── Build image ────────────────────────────────────────────────────────────────
echo "==> Building demo image: $LOCAL_IMAGE"
docker build -q -t "$LOCAL_IMAGE" "$SCRIPT_DIR"

# ── Load image into cluster ───────────────────────────────────────────────────
echo "==> Loading image into Kind cluster ($RUNTIME / $CLUSTER_NAME)..."

if [[ "$RUNTIME" == "containerd" ]]; then
  docker save "$LOCAL_IMAGE" | docker exec -i "$NODE" ctr -n k8s.io images import -

elif [[ "$RUNTIME" == "crio" ]]; then
  REGISTRY_NAME="${REGISTRY_NAME:-nono-nri-registry}"
  REGISTRY_PORT="${REGISTRY_PORT:-5100}"

  KIND_NET=$(docker inspect "$NODE" \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{break}}{{end}}' 2>/dev/null || echo "kind")
  REGISTRY_IP=$(docker inspect "$REGISTRY_NAME" \
    --format "{{(index .NetworkSettings.Networks \"${KIND_NET}\").IPAddress}}" 2>/dev/null || echo "")

  if [[ -z "$REGISTRY_IP" ]]; then
    echo "Error: registry '$REGISTRY_NAME' not found on Kind network '$KIND_NET'." >&2
    echo "Deploy with RUNTIME=crio first (deploy.sh starts the registry)." >&2
    exit 1
  fi

  docker tag "$LOCAL_IMAGE" "localhost:${REGISTRY_PORT}/nono-demo-go:latest"
  docker push "localhost:${REGISTRY_PORT}/nono-demo-go:latest" >/dev/null
  docker exec "$NODE" crictl pull "${REGISTRY_IP}:5000/nono-demo-go:latest" >/dev/null
  JOB_IMAGE="${REGISTRY_IP}:5000/nono-demo-go:latest"

else
  echo "Error: RUNTIME must be 'containerd' or 'crio' (got: $RUNTIME)" >&2
  exit 1
fi

# ── Cleanup helper ─────────────────────────────────────────────────────────────
cleanup() {
  kubectl delete job go-dev-baseline go-dev-sandbox \
    --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
sleep 1

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " nono go-dev profile demo"
echo " runtime: $RUNTIME / cluster: $CLUSTER_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Run jobs ──────────────────────────────────────────────────────────────────
for variant in baseline sandbox; do
  echo ""
  echo "==> Applying go-dev-${variant} job..."

  if [[ "$JOB_IMAGE" != "$LOCAL_IMAGE" ]]; then
    sed "s|image: ${LOCAL_IMAGE}|image: ${JOB_IMAGE}|g" \
      "$SCRIPT_DIR/job-${variant}.yaml" | kubectl apply -f -
  else
    kubectl apply -f "$SCRIPT_DIR/job-${variant}.yaml"
  fi

  kubectl wait --for=condition=complete \
    job/go-dev-${variant} --timeout=120s >/dev/null

  echo ""
  echo "──── go-dev-${variant} output ────────────────────────────"
  kubectl logs "job/go-dev-${variant}"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Demo complete."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
