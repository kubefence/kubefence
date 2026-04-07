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
#   KATA_ROOTFS     true to deploy the custom confidential guest rootfs with nono pre-installed
#                   (requires KATA=true; enables vm_rootfs_classes in plugin config)
#   KATA_ROOTFS_IMAGE  pre-built rootfs image; derived from git remote if unset
#   NONO_VERSION    nono version for local rootfs fallback build (default: v0.23.0)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RUNTIME="${RUNTIME:-containerd}"
CLUSTER_NAME="${CLUSTER_NAME:-nono-${RUNTIME}}"
IMAGE="${IMAGE:-nono-nri:latest}"
KATA="${KATA:-true}"             # set KATA=false to skip Kata Containers
# Pinned kata-containers version. Keep in sync with KATA_VERSION in
# .github/workflows/kata-kernel.yaml when upgrading kata.
KATA_VERSION="${KATA_VERSION:-3.28.0}"
# Pre-built kata kernel image (published by the kata-kernel-landlock GHA workflow).
# Derived from the git remote owner at runtime; override to use a custom build.
#   KATA_KERNEL_IMAGE=ghcr.io/yourorg/kata-kernel-landlock:3.28.0
KATA_KERNEL_IMAGE="${KATA_KERNEL_IMAGE:-}"
# Custom confidential guest rootfs with nono pre-installed (published by kata-rootfs-nono GHA workflow).
# Requires KATA=true. Enables vm_rootfs_classes for the kata-nono-qemu handler.
KATA_ROOTFS="${KATA_ROOTFS:-true}"
KATA_ROOTFS_IMAGE="${KATA_ROOTFS_IMAGE:-}"
NONO_VERSION="${NONO_VERSION:-v0.23.0}"  # used when building the rootfs locally
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
    REGISTRY_IP=$(printf '%s' "$REGISTRY_IP" | tr -d '\n')

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

if [[ "$RUNTIME" == "crio" ]]; then
  # Register a dedicated nono-runc runtime handler in CRI-O
  docker exec "$NODE" sh -c "
    cat > /etc/crio/crio.conf.d/99-nono-runc.conf <<'EOF'
[crio.runtime.runtimes.nono-runc]
runtime_path = \"/usr/libexec/crio/runc\"
runtime_root = \"/run/runc\"
monitor_path = \"/usr/libexec/crio/conmon\"
EOF
  "

  # Disable containerd's NRI so CRI-O can own /var/run/nri/nri.sock.
  # The kind CRI-O node image ships with containerd still running alongside
  # CRI-O. Containerd has NRI enabled by default and starts after CRI-O,
  # replacing the NRI socket — nono-nri would connect to containerd instead.
  docker exec "$NODE" sh -c "
    if ! grep -q 'io.containerd.nri.v1.nri' /etc/containerd/config.toml 2>/dev/null; then
      cat >> /etc/containerd/config.toml << 'CONTAINERD_EOF'
[plugins.\"io.containerd.nri.v1.nri\"]
  disable = true
CONTAINERD_EOF
    fi
    systemctl restart containerd
    sleep 3
    echo '    containerd NRI disabled.'
  "

  # Restart CRI-O after containerd has released the NRI socket so CRI-O
  # reclaims /var/run/nri/nri.sock as the sole owner.
  docker exec "$NODE" sh -c "
    systemctl restart crio
    sleep 3
    echo '    CRI-O restarted — owns NRI socket.'
  "
fi

if [[ "$RUNTIME" == "containerd" ]]; then
  # Register nono-runc handler if not already present (idempotent — cluster-containerd.yaml
  # adds it at creation time, but cluster.yaml and manual clusters may not have it).
  docker exec "$NODE" sh -c "
    if ! grep -q 'runtimes.nono-runc' /etc/containerd/config.toml 2>/dev/null; then
      cat >> /etc/containerd/config.toml << 'CONTAINERD_EOF'
[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nono-runc]
  runtime_type = \"io.containerd.runc.v2\"
CONTAINERD_EOF
      systemctl restart containerd
      sleep 3
      echo \"    containerd restarted with nono-runc handler.\"
    else
      echo \"    nono-runc handler already registered — skipping restart.\"
    fi
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
      _GH_OWNER=$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || true \
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

  # ── kata-nono-qemu: custom rootfs with nono pre-installed ────────────────────
  if [[ "$KATA_ROOTFS" == "true" ]]; then
    echo ""
    echo "==> Deploying kata-nono-sandbox (embedded nono rootfs, kata-nono-qemu handler)..."

    KATA_ROOTFS_CACHE="/tmp/kata-rootfs-confidential-${KATA_VERSION}-${NONO_VERSION}.image"

    if [ -f "${KATA_ROOTFS_CACHE}" ]; then
      echo "    Using cached rootfs: ${KATA_ROOTFS_CACHE}"
    else
      # Resolve image name from git remote owner if not overridden.
      if [ -z "${KATA_ROOTFS_IMAGE}" ]; then
        _GH_OWNER=$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || true \
          | sed -n 's|.*github\.com[:/]\([^/]*\)/.*|\1|p')
        KATA_ROOTFS_IMAGE="ghcr.io/${_GH_OWNER:-k8s-nono}/kata-rootfs-nono:${KATA_VERSION}-${NONO_VERSION}"
      fi
      echo "    Kata rootfs image: ${KATA_ROOTFS_IMAGE}"

      if docker pull "${KATA_ROOTFS_IMAGE}" 2>/dev/null; then
        _CTR=$(docker create "${KATA_ROOTFS_IMAGE}")
        docker cp "${_CTR}:/kata-containers-confidential.image" "${KATA_ROOTFS_CACHE}"
        docker rm "${_CTR}" >/dev/null
        echo "    Rootfs extracted from image."
      else
        # Fallback: build locally using inject.sh.
        echo "    Pre-built image not available — building locally..."
        apt-get install -qq -y e2tools 2>/dev/null || true

        NONO_TARBALL="nono-${NONO_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
        _NONO_TMP=$(mktemp -d)
        curl -fsSL "https://github.com/always-further/nono/releases/download/${NONO_VERSION}/${NONO_TARBALL}" \
          | tar xzf - -C "$_NONO_TMP"
        _NONO_BIN=$(find "$_NONO_TMP" -maxdepth 3 -name nono -type f | head -1)

        curl -fsSL \
          "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.zst" \
          | zstd -d \
          | tar --to-stdout -x "./opt/kata/share/kata-containers/kata-ubuntu-noble-confidential.image" \
          > "${KATA_ROOTFS_CACHE}.tmp"

        bash "${SCRIPT_DIR}/kata-rootfs/inject.sh" \
          "${KATA_ROOTFS_CACHE}.tmp" "$_NONO_BIN" "${SCRIPT_DIR}/kata-rootfs/policy.rego"
        mv "${KATA_ROOTFS_CACHE}.tmp" "${KATA_ROOTFS_CACHE}"
        rm -rf "$_NONO_TMP"
        echo "    Local build complete."
      fi
    fi

    # Deploy the custom rootfs onto the node.
    KATA_CUSTOM_ROOTFS="${KATA_SHARE}/kata-confidential-nono.image"
    docker cp "${KATA_ROOTFS_CACHE}" "${NODE}:${KATA_CUSTOM_ROOTFS}"
    docker exec "$NODE" chmod 644 "${KATA_CUSTOM_ROOTFS}"
    echo "    Deployed: ${KATA_CUSTOM_ROOTFS}"

    # Create a dedicated kata config for the kata-nono-qemu handler.
    # Inherits all settings from configuration-qemu.toml (Landlock kernel,
    # machine_accelerators) but points image = at the custom nono rootfs.
    # kata-nono-sandbox continues using the standard kata-ubuntu-noble-confidential.image.
    KATA_CFG_NONO="$(dirname ${KATA_CFG})/configuration-kata-nono-qemu.toml"
    docker exec "$NODE" sh -c "
      cp '${KATA_CFG}' '${KATA_CFG_NONO}'
      sed -i 's|^image = .*|image = \"${KATA_CUSTOM_ROOTFS}\"|' '${KATA_CFG_NONO}'
    "
    echo "    Created ${KATA_CFG_NONO} with custom rootfs."

    # Register kata-nono-qemu as a runtime handler in the active CRI.
    if [[ "$RUNTIME" == "crio" ]]; then
      docker exec "$NODE" sh -c "
        cat > /etc/crio/crio.conf.d/98-kata-nono-qemu.conf <<'EOF'
[crio.runtime.runtimes.kata-nono-qemu]
runtime_path = \"/opt/kata/bin/containerd-shim-kata-v2\"
runtime_type = \"vm\"
runtime_root = \"/run/vc\"
runtime_config_path = \"${KATA_CFG_NONO}\"
EOF
        systemctl restart crio
      "
      sleep 3
      echo "    CRI-O restarted with kata-nono-qemu handler."
    else
      # containerd: append stanza and restart.
      docker exec "$NODE" sh -c "
        cat >> /etc/containerd/config.toml << 'CONTAINERD_EOF'

[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.kata-nono-qemu]
  runtime_type = \"io.containerd.kata-qemu.v2\"
  runtime_path = \"/opt/kata/bin/containerd-shim-kata-v2\"
  privileged_without_host_devices = true
  pod_annotations = [\"io.katacontainers.*\"]
  [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.kata-nono-qemu.options]
    ConfigPath = \"${KATA_CFG_NONO}\"
CONTAINERD_EOF
        systemctl restart containerd
      "
      sleep 3
      echo "    containerd restarted with kata-nono-qemu handler."
    fi
  fi
fi

# ── Wait for NRI socket before deploying ─────────────────────────────────────
# The nono-nri plugin connects to containerd's NRI socket on startup.
# Poll until the socket file exists so the DaemonSet pod never starts
# before containerd has fully initialised its NRI subsystem.
echo ""
echo "==> Waiting for NRI socket (/var/run/nri/nri.sock)..."
_NRI_WAIT=0
until docker exec "$NODE" test -S /var/run/nri/nri.sock 2>/dev/null; do
  if [[ $_NRI_WAIT -ge 60 ]]; then
    echo "ERROR: NRI socket not created after 60 s"
    docker exec "$NODE" ls /var/run/nri/ 2>/dev/null || echo "  (directory missing)"
    exit 1
  fi
  sleep 1
  ((_NRI_WAIT++))
done
echo "    NRI socket ready (waited ${_NRI_WAIT}s)."

# ── Install nono-nri via Helm ─────────────────────────────────────────────────
echo ""
echo "==> Installing nono-nri (Helm chart)..."

# Determine the image to deploy.
DEPLOY_IMAGE="$IMAGE"
if [[ "$RUNTIME" == "crio" && "$SKIP_BUILD" != "true" ]]; then
  # For locally-built CRI-O images the image was pushed to a local registry.
  DEPLOY_IMAGE="$LOCAL_IMAGE"
fi

HELM_SET_ARGS=(
  --set "image.repository=${DEPLOY_IMAGE%%:*}"
  --set "image.tag=${DEPLOY_IMAGE##*:}"
  --set "runtimeClasses.kataNono.enabled=${KATA}"
)

if [[ "$KATA" == "true" && "$KATA_ROOTFS" == "true" ]]; then
  HELM_SET_ARGS+=(
    --set "config.runtimeClasses={nono-runc,kata-qemu,kata-nono-qemu}"
    --set "config.vmRootfsClasses={kata-nono-qemu}"
    --set "runtimeClasses.kataNono.handler=kata-nono-qemu"
  )
elif [[ "$KATA" == "true" ]]; then
  HELM_SET_ARGS+=(
    --set "config.runtimeClasses={nono-runc,kata-qemu}"
    --set "runtimeClasses.kataNono.handler=kata-qemu"
  )
fi

helm upgrade --install nono-nri "$REPO_ROOT/deploy/helm/nono-nri" \
  --namespace kube-system \
  --wait --timeout 120s \
  "${HELM_SET_ARGS[@]}"

echo "==> nono-nri deployed."

# Belt-and-suspenders: Helm 3 --wait has known DaemonSet readiness gaps.
# Verify DaemonSet rollout explicitly, then emit pod diagnostics on failure
# so the root cause is visible without a separate kubectl session.
echo ""
echo "==> Waiting for DaemonSet rollout..."
kubectl rollout status daemonset/nono-nri -n kube-system --timeout=120s || {
  echo ""
  echo "ERROR: DaemonSet rollout timed out. Pod diagnostics:"
  kubectl get pods -n kube-system -l app.kubernetes.io/name=nono-nri -o wide 2>/dev/null || true
  _POD=$(kubectl get pod -n kube-system -l app.kubernetes.io/name=nono-nri \
           -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$_POD" ]]; then
    echo ""
    kubectl describe pod -n kube-system "$_POD" 2>/dev/null | tail -40 || true
    echo ""
    echo "==> Init container logs (install-nono):"
    kubectl logs -n kube-system "$_POD" -c install-nono 2>/dev/null || true
    echo ""
    echo "==> Main container logs (nono-nri):"
    kubectl logs -n kube-system "$_POD" -c nono-nri 2>/dev/null || true
  fi
  exit 1
}

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> Deployment complete! ($RUNTIME / $CLUSTER_NAME)"
echo ""
echo "Run e2e tests:"
echo "  RUNTIME=$RUNTIME CLUSTER_NAME=$CLUSTER_NAME bash $SCRIPT_DIR/e2e.sh"
echo ""
echo "Tear down:"
echo "  kind delete cluster --name $CLUSTER_NAME"
