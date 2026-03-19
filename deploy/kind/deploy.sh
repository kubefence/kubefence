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
KATA="${KATA:-true}"   # set KATA=false to skip Kata Containers installation

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

# ── Install Kata Containers via helm ──────────────────────────────────────────
if [[ "$KATA" == "true" ]]; then
  echo ""
  echo "==> Installing Kata Containers (kata-deploy helm chart)..."
  KATA_VERSION=$(curl -sSL https://api.github.com/repos/kata-containers/kata-containers/releases/latest \
    | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  echo "    kata version: $KATA_VERSION"
  helm install kata-deploy \
    --namespace kube-system \
    --wait --timeout 10m \
    -f "$SCRIPT_DIR/kata-values.yaml" \
    oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
    --version "$KATA_VERSION"
  echo "==> Kata Containers installed."

  # ── Kata node tuning for kind (nested KVM) ───────────────────────────────
  echo ""
  echo "==> Tuning Kata for nested-KVM kind environment..."

  # 1. Expand /dev/shm: kata uses memory-backend-file in /dev/shm for NUMA.
  #    The Docker default is 64 MB; 2 GB+ needed for kata VM memory.
  docker exec "$NODE" mount -o remount,size=16g /dev/shm

  # 2. Use the host kernel inside the kata VM.
  #    The kata-bundled kernel (6.18.15) lacks Landlock (CONFIG_SECURITY_LANDLOCK=n).
  #    The host kernel has Landlock built-in (=y) and works in nested KVM when
  #    kernel_irqchip=split is set.  vsock and virtiofs are modules (=m) on the
  #    host, so we build a custom initrd that insmod's them before the kata-agent.

  HOST_KERN=$(docker exec "$NODE" uname -r)
  KATA_SHARE="/opt/kata/share/kata-containers"
  KATA_CFG="/opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml"

  # 2a. Extract the uncompressed host vmlinux and copy into the kata directory.
  EXTRACT_SCRIPT=$(docker exec "$NODE" sh -c "
    find /usr/src -name extract-vmlinux 2>/dev/null | head -1
  ")
  if [ -z "$EXTRACT_SCRIPT" ]; then
    docker exec "$NODE" sh -c "apt-get install -qq -y linux-headers-\$(uname -r) 2>/dev/null || true"
    EXTRACT_SCRIPT=$(docker exec "$NODE" sh -c "find /usr/src -name extract-vmlinux 2>/dev/null | head -1")
  fi

  if [ -n "$EXTRACT_SCRIPT" ]; then
    docker exec "$NODE" sh -c "
      ${EXTRACT_SCRIPT} /boot/vmlinuz-${HOST_KERN} > ${KATA_SHARE}/vmlinux-host.container && \
      chmod 644 ${KATA_SHARE}/vmlinux-host.container
    "
    echo "    Extracted host vmlinux ($(docker exec "$NODE" sh -c "ls -lh ${KATA_SHARE}/vmlinux-host.container | awk '{print \$5}'")"
  else
    # Fallback: copy directly into a temp dir on the host then docker cp
    sudo /usr/src/linux-headers-$(uname -r)/scripts/extract-vmlinux /boot/vmlinuz-$(uname -r) > /tmp/_vmlinux-host 2>/dev/null || \
      cp /boot/vmlinuz-$(uname -r) /tmp/_vmlinux-host
    docker cp /tmp/_vmlinux-host "$NODE:${KATA_SHARE}/vmlinux-host.container"
    docker exec "$NODE" chmod 644 "${KATA_SHARE}/vmlinux-host.container"
    rm -f /tmp/_vmlinux-host
  fi

  # 2b. Build a custom initrd: kata-agent init + host kernel vsock/virtiofs modules.
  INITRD_WORK=$(mktemp -d)
  docker cp "$NODE:${KATA_SHARE}/kata-containers-initrd.img" "${INITRD_WORK}/kata-initrd.img"
  (cd "$INITRD_WORK" && gzip -d -c kata-initrd.img | cpio -idm 2>/dev/null)

  # Add host kernel modules (vsock + virtiofs).
  KERN=$(uname -r)
  MOD_DIR="${INITRD_WORK}/lib/modules/${KERN}/kernel"
  mkdir -p "${MOD_DIR}/net/vmw_vsock" "${MOD_DIR}/fs/fuse"
  for MOD_ZST in \
    /lib/modules/${KERN}/kernel/net/vmw_vsock/vsock.ko.zst \
    /lib/modules/${KERN}/kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko.zst \
    /lib/modules/${KERN}/kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko.zst \
    /lib/modules/${KERN}/kernel/fs/fuse/virtiofs.ko.zst; do
    MOD=$(basename "${MOD_ZST}" .zst)
    zstd -d "${MOD_ZST}" -o "${MOD_DIR}/$(basename $(dirname ${MOD_ZST}))/$(basename ${MOD_ZST} .zst)" -f -q
  done

  # Wrap /sbin/init: insmod modules then exec the real kata-agent.
  cp "${INITRD_WORK}/sbin/init" "${INITRD_WORK}/sbin/kata-agent-real"
  cat > "${INITRD_WORK}/sbin/init" <<INITSCRIPT
#!/bin/sh
insmod /lib/modules/${KERN}/kernel/net/vmw_vsock/vsock.ko 2>/dev/null || true
insmod /lib/modules/${KERN}/kernel/net/vmw_vsock/vmw_vsock_virtio_transport_common.ko 2>/dev/null || true
insmod /lib/modules/${KERN}/kernel/net/vmw_vsock/vmw_vsock_virtio_transport.ko 2>/dev/null || true
insmod /lib/modules/${KERN}/kernel/fs/fuse/virtiofs.ko 2>/dev/null || true
exec /sbin/kata-agent-real "\$@"
INITSCRIPT
  chmod 755 "${INITRD_WORK}/sbin/init"

  # Repack and deploy.
  (cd "$INITRD_WORK" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /tmp/_kata-initrd-host.img)
  docker cp /tmp/_kata-initrd-host.img "$NODE:${KATA_SHARE}/kata-initrd-host.img"
  docker exec "$NODE" sh -c "chown root:root ${KATA_SHARE}/kata-initrd-host.img && chmod 644 ${KATA_SHARE}/kata-initrd-host.img"
  rm -rf "$INITRD_WORK" /tmp/_kata-initrd-host.img
  echo "    Custom initrd built with host kernel modules."

  # 2c. Patch kata QEMU config.
  docker exec "$NODE" sed -i "
    s|^kernel = .*|kernel = \"${KATA_SHARE}/vmlinux-host.container\"|;
    s|^initrd = .*|initrd = \"${KATA_SHARE}/kata-initrd-host.img\"|;
    s|^machine_accelerators = .*|machine_accelerators = \"kernel_irqchip=split\"|
  " "$KATA_CFG"
  echo "    Kata QEMU config patched (host kernel, kernel_irqchip=split)."
fi

# ── Install TOML config ───────────────────────────────────────────────────────
# runtime_classes must match the RuntimeClass handler (nono-runc / kata-qemu),
# not the RuntimeClass name.  kata-qemu is added when KATA=true.
if [[ "$KATA" == "true" ]]; then
  RUNTIME_CLASSES='["nono-runc", "kata-qemu"]'
else
  RUNTIME_CLASSES='["nono-runc"]'
fi
TOML=$(cat <<EOF
runtime_classes = ${RUNTIME_CLASSES}
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
echo "==> Applying RuntimeClasses (nono-sandbox, kata-nono-sandbox)..."
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
