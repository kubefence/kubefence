#!/usr/bin/env bash
# deploy.sh — create a Kind cluster and deploy nono-nri
#
# Usage:
#   RUNTIME=containerd bash deploy/kind/deploy.sh   # default
#   RUNTIME=crio      bash deploy/kind/deploy.sh
#
# Environment variables:
#   RUNTIME         containerd (default) | crio
#   CLUSTER_NAME    cluster name (default: nono-<runtime>)
#   IMAGE           plugin image tag (default: nono-nri:latest)
#   SKIP_BUILD      true to skip docker build and pull IMAGE from a registry instead
#   KATA_VERSION    kata-containers release to install (default: 3.28.0)
#   KATA_KERNEL_IMAGE  pre-built Landlock kernel image; derived from git remote if unset
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RUNTIME="${RUNTIME:-containerd}"
CLUSTER_NAME="${CLUSTER_NAME:-nono-${RUNTIME}}"
IMAGE="${IMAGE:-nono-nri:latest}"
KATA="${KATA:-false}"            # set KATA=true to install Kata Containers
# Pinned kata-containers version. Keep in sync with KATA_VERSION in
# .github/workflows/kata-kernel.yaml when upgrading kata.
KATA_VERSION="${KATA_VERSION:-3.28.0}"
# Pre-built kata kernel image (published by the kata-kernel-landlock GHA workflow).
# Derived from the git remote owner at runtime; override to use a custom build.
#   KATA_KERNEL_IMAGE=ghcr.io/yourorg/kata-kernel-landlock:3.28.0
KATA_KERNEL_IMAGE="${KATA_KERNEL_IMAGE:-}"
SKIP_BUILD="${SKIP_BUILD:-false}"  # set SKIP_BUILD=true to use a pre-built / remote image

# ── Validate runtime ──────────────────────────────────────────────────────────
if [[ "$RUNTIME" != "containerd" && "$RUNTIME" != "crio" ]]; then
  echo "Error: RUNTIME must be 'containerd' or 'crio' (got: $RUNTIME)"
  exit 1
fi

echo "==> Runtime:      $RUNTIME"
echo "==> Cluster name: $CLUSTER_NAME"
echo "==> Image:        $IMAGE"
echo "==> Skip build:   $SKIP_BUILD"

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
if [[ "$SKIP_BUILD" != "true" ]]; then
  echo ""
  echo "==> Building nono-nri image..."
  cd "$REPO_ROOT"
  make docker-build IMAGE="$IMAGE"
else
  echo ""
  echo "==> Skipping build — using pre-built image: $IMAGE"
fi

# ── Load image into cluster ───────────────────────────────────────────────────
echo ""
echo "==> Loading image into Kind ($RUNTIME)..."

if [[ "$RUNTIME" == "containerd" ]]; then
  if [[ "$SKIP_BUILD" == "true" ]]; then
    # Remote image: pull directly into the kind node's containerd namespace.
    docker exec "$NODE" ctr -n k8s.io images pull "$IMAGE"
  else
    # Local image: kind load docker-image is broken with containerd v2.x
    # (snapshotter detection). Import directly via ctr instead.
    docker save "$IMAGE" | docker exec -i "$NODE" ctr -n k8s.io images import -
  fi

elif [[ "$RUNTIME" == "crio" ]]; then
  if [[ "$SKIP_BUILD" == "true" ]]; then
    # Remote image: pull directly via crictl on the kind node.
    docker exec "$NODE" crictl pull "$IMAGE"
    LOCAL_IMAGE="$IMAGE"
  else
    # Local image: CRI-O does not share Docker's image store. Use a local registry.
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
  echo "    kata version: $KATA_VERSION"
  helm install kata-deploy \
    --namespace kube-system \
    --wait --timeout 10m \
    -f "$SCRIPT_DIR/kata-values.yaml" \
    oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
    --version "$KATA_VERSION"
  echo "==> Kata Containers installed."

  # kata-deploy's helm --wait only checks the helm release, not DaemonSet pod
  # readiness.  Wait explicitly so the node files are present before we query them.
  echo "==> Waiting for kata-deploy DaemonSet..."
  kubectl rollout status daemonset/kata-deploy -n kube-system --timeout=300s

  # ── Kata node tuning for kind (nested KVM) ───────────────────────────────
  echo ""
  echo "==> Tuning Kata for nested-KVM kind environment..."

  # 1. Expand /dev/shm: kata uses memory-backend-file in /dev/shm for NUMA.
  #    The Docker default is 64 MB; 2 GB+ needed for kata VM memory.
  docker exec "$NODE" mount -o remount,size=16g /dev/shm

  # 2. Build the kata kernel with Landlock LSM enabled.
  #    The kata-bundled kernel has CONFIG_SECURITY_LANDLOCK=n.  We rebuild from
  #    kata's own kernel source + patches with Landlock added.  The kata-shipped
  #    initrd works unchanged: virtiofs and vsock are built-in (=y) in the kata
  #    kernel config, so no custom initrd or insmod wrapper is needed.

  KATA_SHARE="/opt/kata/share/kata-containers"
  KATA_CFG="/opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml"

  # Detect the Linux version by finding the versioned qemu kernel file.
  # kata-deploy ships several vmlinuz variants; filter out dragonball/nvidia-gpu
  # and the unversioned .container symlinks — what remains is the qemu kernel
  # (e.g. vmlinuz-6.18.15-186).  Polling the actual file (not a symlink) avoids
  # readlink -f false-positives where it returns a dangling or missing path.
  # Poll up to 300 s: kata-deploy pod readiness and host file creation are not atomic.
  _KERN_FILE=""
  for _i in $(seq 1 300); do
    _KERN_FILE=$(docker exec "$NODE" sh -c "
      ls '${KATA_SHARE}'/vmlinuz-* 2>/dev/null \
        | grep -v dragonball | grep -v nvidia | grep -vE '\\.container$' \
        | head -1" 2>/dev/null || true)
    [[ -n "$_KERN_FILE" ]] && break
    [[ $((_i % 30)) -eq 0 ]] && echo "    Still waiting for kata kernel files... (${_i}s)"
    sleep 1
  done
  if [[ -z "$_KERN_FILE" ]]; then
    echo "ERROR: kata qemu kernel not found in ${KATA_SHARE} after 300 s"
    echo "  kata-deploy pod status:"
    kubectl get pod -n kube-system -l app=kata-deploy -o wide 2>/dev/null || true
    echo "  contents of ${KATA_SHARE}:"
    docker exec "$NODE" ls "${KATA_SHARE}" 2>/dev/null || true
    exit 1
  fi
  LINUX_VER=$(basename "${_KERN_FILE}" | sed 's/vmlinuz-//;s/-[0-9]*$//')
  echo "    Kata Linux version: ${LINUX_VER}"

  # Host-side cache: skip pull/build if the kernel was already fetched.
  KATA_KERN_CACHE="/tmp/kata-vmlinux-landlock-${LINUX_VER}.elf"

  if [ -f "${KATA_KERN_CACHE}" ]; then
    echo "    Using cached Landlock kernel: ${KATA_KERN_CACHE}"
  else
    # Resolve the image name: derive owner from git remote if not overridden.
    if [ -z "${KATA_KERNEL_IMAGE}" ]; then
      _GH_OWNER=$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null \
        | sed -n 's|.*github\.com[:/]\([^/]*\)/.*|\1|p')
      KATA_KERNEL_IMAGE="ghcr.io/${_GH_OWNER:-k8s-nono}/kata-kernel-landlock:${KATA_VERSION}"
    fi
    echo "    Kata kernel image: ${KATA_KERNEL_IMAGE}"

    # Try pulling the pre-built image published by the kata-kernel-landlock GHA.
    if docker pull "${KATA_KERNEL_IMAGE}" 2>/dev/null; then
      _CTR=$(docker create "${KATA_KERNEL_IMAGE}")
      docker cp "${_CTR}:/vmlinux" "${KATA_KERN_CACHE}"
      docker rm "${_CTR}" >/dev/null
      echo "    Kernel extracted from image."
    else
      # Fallback: build from kata source (used when the image hasn't been
      # published yet, e.g. on first run before GHA has executed).
      echo "    Pre-built image not available — building from source (~20-40 min)..."

      sudo apt-get install -qq -y \
        build-essential flex bison libssl-dev libelf-dev bc dwarves \
        libncurses-dev rsync cpio curl 2>/dev/null || true

      if ! command -v yq &>/dev/null; then
        sudo wget -qO /usr/local/bin/yq \
          "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        sudo chmod +x /usr/local/bin/yq
      fi

      KATA_BUILD_DIR=$(mktemp -d /tmp/kata-kern-XXXXXX)

      git clone --quiet --depth 1 --filter=blob:none --sparse \
        -b "${KATA_VERSION}" \
        https://github.com/kata-containers/kata-containers \
        "${KATA_BUILD_DIR}/kata-src"
      (cd "${KATA_BUILD_DIR}/kata-src" && \
        git sparse-checkout set tools/packaging/kernel tools/packaging/scripts && \
        git show HEAD:versions.yaml > versions.yaml && \
        git show HEAD:VERSION > VERSION)

      KERN_PKG="${KATA_BUILD_DIR}/kata-src/tools/packaging/kernel"
      (cd "${KERN_PKG}" && ARCH=x86_64 ./build-kernel.sh setup)

      KERN_SRC=$(ls -d "${KERN_PKG}/kata-linux-"* 2>/dev/null | head -1)
      [ -z "${KERN_SRC}" ] && { echo "ERROR: kernel source not found"; exit 1; }

      (cd "${KERN_SRC}" && ./scripts/config --enable SECURITY_LANDLOCK)
      CURRENT_LSM=$(cd "${KERN_SRC}" && ./scripts/config --state LSM 2>/dev/null | tr -d '"')
      if [ -z "${CURRENT_LSM}" ]; then
        (cd "${KERN_SRC}" && ./scripts/config --set-str LSM "landlock")
      elif ! echo "${CURRENT_LSM}" | grep -q "landlock"; then
        (cd "${KERN_SRC}" && ./scripts/config --set-str LSM "landlock,${CURRENT_LSM}")
      fi
      (cd "${KERN_SRC}" && make ARCH=x86_64 olddefconfig 2>/dev/null)
      (cd "${KERN_SRC}" && make ARCH=x86_64 -j"$(nproc)" vmlinux)

      cp "${KERN_SRC}/vmlinux" "${KATA_KERN_CACHE}"
      rm -rf "${KATA_BUILD_DIR}"
      echo "    Build complete."
    fi
  fi

  # Deploy the Landlock-enabled vmlinux into the kata share.
  KATA_LANDLOCK_KERNEL="${KATA_SHARE}/vmlinux-landlock.container"
  docker cp "${KATA_KERN_CACHE}" "${NODE}:${KATA_LANDLOCK_KERNEL}"
  docker exec "$NODE" chmod 644 "${KATA_LANDLOCK_KERNEL}"
  echo "    Deployed: ${KATA_LANDLOCK_KERNEL}"

  # Wait for the QEMU config file to appear (kata-deploy writes it asynchronously).
  echo "==> Waiting for kata QEMU config file..."
  for _i in $(seq 1 120); do
    docker exec "$NODE" test -f "${KATA_CFG}" 2>/dev/null && break
    [[ $((_i % 15)) -eq 0 ]] && echo "    Still waiting for ${KATA_CFG}... (${_i}s)"
    sleep 1
  done
  if ! docker exec "$NODE" test -f "${KATA_CFG}" 2>/dev/null; then
    echo "ERROR: kata QEMU config not found at ${KATA_CFG} after 120 s"
    docker exec "$NODE" find /opt/kata/share/defaults -name '*.toml' 2>/dev/null || true
    exit 1
  fi

  # Patch kata QEMU config: new kernel path; leave initrd unchanged.
  docker exec "$NODE" sh -c "
  sed -i \
    -e 's|^kernel = .*|kernel = \"${KATA_LANDLOCK_KERNEL}\"|' \
    -e 's|^machine_accelerators = .*|machine_accelerators = \"kernel_irqchip=split\"|' \
    ${KATA_CFG}
  "
  # Add machine_accelerators if the line was absent in the default config.
  docker exec "$NODE" sh -c "
    grep -q '^machine_accelerators' '${KATA_CFG}' || \
      sed -i 's|\(\[hypervisor.qemu\]\)|\1\nmachine_accelerators = \"kernel_irqchip=split\"|' '${KATA_CFG}'
  "
  echo "    Kata QEMU config patched (Landlock kernel, kata initrd, kernel_irqchip=split)."
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
echo "==> Applying RuntimeClass (nono-sandbox)..."
kubectl apply -f "$REPO_ROOT/deploy/runtimeclass.yaml"
if [[ "$KATA" == "true" ]]; then
  echo "==> Applying RuntimeClass (kata-nono-sandbox)..."
  kubectl apply -f "$REPO_ROOT/deploy/runtimeclass-kata.yaml"
fi

echo "==> Applying DaemonSet..."
# Always substitute the image tag so the daemonset matches whatever IMAGE was requested.
DEPLOY_IMAGE="$IMAGE"
if [[ "$RUNTIME" == "crio" && "$SKIP_BUILD" != "true" ]]; then
  # For locally-built crio images the image was pushed to a local registry.
  DEPLOY_IMAGE="$LOCAL_IMAGE"
fi
sed "s|image: nono-nri:latest|image: ${DEPLOY_IMAGE}|g" \
  "$REPO_ROOT/deploy/daemonset.yaml" | kubectl apply -f -

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
