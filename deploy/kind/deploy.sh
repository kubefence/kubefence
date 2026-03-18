#!/usr/bin/env bash
# deploy.sh — create a Kind cluster and deploy nono-nri
#
# Usage:
#   RUNTIME=containerd bash deploy/kind/deploy.sh   # default
#   RUNTIME=crio      bash deploy/kind/deploy.sh
#
# Environment variables:
#   RUNTIME       containerd (default) | crio
#   CLUSTER_NAME  cluster name (default: nono-<runtime>)
#   IMAGE         plugin image tag (default: nono-nri:latest)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RUNTIME="${RUNTIME:-containerd}"
CLUSTER_NAME="${CLUSTER_NAME:-nono-${RUNTIME}}"
IMAGE="${IMAGE:-nono-nri:latest}"

# ── Validate runtime ──────────────────────────────────────────────────────────
if [[ "$RUNTIME" != "containerd" && "$RUNTIME" != "crio" ]]; then
  echo "Error: RUNTIME must be 'containerd' or 'crio' (got: $RUNTIME)"
  exit 1
fi

echo "==> Runtime:      $RUNTIME"
echo "==> Cluster name: $CLUSTER_NAME"
echo "==> Image:        $IMAGE"

# ── Select cluster config ─────────────────────────────────────────────────────
if [[ "$RUNTIME" == "containerd" ]]; then
  CLUSTER_CONFIG="$SCRIPT_DIR/cluster-containerd.yaml"
else
  CLUSTER_CONFIG="$SCRIPT_DIR/cluster-crio.yaml"
fi

# ── Create Kind cluster ───────────────────────────────────────────────────────
echo ""
echo "==> Creating Kind cluster '$CLUSTER_NAME' ($RUNTIME)..."
kind create cluster --name "$CLUSTER_NAME" --config "$CLUSTER_CONFIG"
NODE="${CLUSTER_NAME}-control-plane"

# ── Build plugin image ────────────────────────────────────────────────────────
echo ""
echo "==> Building nono-nri image..."
cd "$REPO_ROOT"
make docker-build IMAGE="$IMAGE"

# ── Load image into cluster ───────────────────────────────────────────────────
echo ""
echo "==> Loading image into Kind ($RUNTIME)..."

if [[ "$RUNTIME" == "containerd" ]]; then
  # kind load docker-image is broken with containerd v2.x (snapshotter detection).
  # Import directly via ctr instead.
  docker save "$IMAGE" | docker exec -i "$NODE" ctr -n k8s.io images import -

elif [[ "$RUNTIME" == "crio" ]]; then
  # CRI-O does not share Docker's image store. Use a local registry.
  REGISTRY_NAME="nono-nri-registry"
  REGISTRY_PORT="5100"
  KIND_NET=$(docker inspect "$NODE" --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' | head -1)

  # Start registry if not already running
  if ! docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
    echo "==> Starting local Docker registry ($REGISTRY_NAME)..."
    docker run -d --name "$REGISTRY_NAME" \
      -p "127.0.0.1:${REGISTRY_PORT}:5000" \
      --network "$KIND_NET" \
      registry:2
    sleep 2
  fi

  REGISTRY_IP=$(docker inspect "$REGISTRY_NAME" \
    --format "{{(index .NetworkSettings.Networks \"${KIND_NET}\").IPAddress}}" 2>/dev/null || \
    docker inspect "$REGISTRY_NAME" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{break}}{{end}}')

  # Configure CRI-O to allow insecure pulls from the local registry
  docker exec "$NODE" sh -c "
    mkdir -p /etc/containers/registries.conf.d
    cat > /etc/containers/registries.conf.d/nono-local.conf <<EOF
[[registry]]
location = \"${REGISTRY_IP}:5000\"
insecure = true
EOF
    systemctl restart crio
    sleep 3
  "

  # Push and pull
  LOCAL_IMAGE="${REGISTRY_IP}:5000/nono-nri:latest"
  docker tag "$IMAGE" "localhost:${REGISTRY_PORT}/nono-nri:latest"
  docker push "localhost:${REGISTRY_PORT}/nono-nri:latest"
  docker exec "$NODE" crictl pull "$LOCAL_IMAGE"

  # Store registry info for later use
  export REGISTRY_IP REGISTRY_PORT REGISTRY_NAME KIND_NET LOCAL_IMAGE
fi

# ── Runtime-specific node configuration ──────────────────────────────────────
echo ""
echo "==> Configuring node for $RUNTIME..."

docker exec "$NODE" sh -c "mkdir -p /etc/nri/conf.d /opt/nono-nri /opt/nri/plugins /var/run/nri"

if [[ "$RUNTIME" == "crio" ]]; then
  # Register a dedicated nono-runc runtime handler in CRI-O
  docker exec "$NODE" sh -c "
    cat > /etc/crio/crio.conf.d/99-nono-runc.conf <<'EOF'
[crio.runtime.runtimes.nono-runc]
runtime_path = \"/usr/libexec/crio/runc\"
runtime_root = \"/run/runc\"
monitor_path = \"/usr/libexec/crio/conmon\"
EOF
    systemctl restart crio
    sleep 3
  "
fi

# ── Install TOML config ───────────────────────────────────────────────────────
# runtime_classes must match the RuntimeClass handler (nono-runc), not the name
TOML=$(cat <<'EOF'
runtime_classes = ["nono-runc"]
default_profile = "default"
nono_bin_path = "/opt/nono-nri/nono"
socket_path = ""
EOF
)
docker exec "$NODE" sh -c "cat > /etc/nri/conf.d/10-nono-nri.toml <<'TOMLEOF'
${TOML}
TOMLEOF"

# ── Apply Kubernetes manifests ────────────────────────────────────────────────
echo ""
echo "==> Applying RuntimeClass (handler: nono-runc)..."
kubectl apply -f "$REPO_ROOT/deploy/runtimeclass.yaml"

echo "==> Applying DaemonSet..."
if [[ "$RUNTIME" == "crio" ]]; then
  # Rewrite image reference to point at the local registry
  sed "s|image: nono-nri:latest|image: ${LOCAL_IMAGE}|g" \
    "$REPO_ROOT/deploy/daemonset.yaml" | kubectl apply -f -
else
  kubectl apply -f "$REPO_ROOT/deploy/daemonset.yaml"
fi

echo ""
echo "==> Waiting for DaemonSet rollout..."
kubectl rollout status daemonset/nono-nri -n kube-system --timeout=120s

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> Deployment complete! ($RUNTIME / $CLUSTER_NAME)"
echo ""
echo "Run e2e tests:"
echo "  RUNTIME=$RUNTIME CLUSTER_NAME=$CLUSTER_NAME bash $SCRIPT_DIR/e2e.sh"
echo ""
echo "Tear down:"
echo "  kind delete cluster --name $CLUSTER_NAME"
