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
#   KATA_VERSION    kata-containers release to install (default: 4.0.0)
#   KATA_EXTENSION  true to deploy the nono guest extension image, which carries the
#                   hardened kata-agent policy (requires KATA=true)
#   KATA_EXTENSION_IMAGE  pull this published extension image instead of building
#                   deploy/kata-extension/ from the working tree
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# containerd renamed the CRI runtime plugin in the version 3 config schema:
# handlers live under io.containerd.cri.v1.runtime there and under
# io.containerd.grpc.v1.cri in a version 2 document. Getting it wrong is quiet —
# containerd logs "Ignoring unknown key in TOML for plugin", registers nothing,
# and pods fail with `no runtime for "<handler>" is configured`. kind's node image
# ships a version 2 config while a stock containerd 2.x config is version 3, so
# the name is read off the config rather than pinned.
# Interpolated into the docker exec blocks below; keep it POSIX sh.
CRI_PLUGIN_NAME='
    if grep -q "^version[[:space:]]*=[[:space:]]*3" /etc/containerd/config.toml; then
      CRI_PLUGIN="io.containerd.cri.v1.runtime"
    else
      CRI_PLUGIN="io.containerd.grpc.v1.cri"
    fi'

# containerd only reads a drop-in directory if the glob is listed in the imports
# array. conf.d is containerd's own: a stock 2.x config already imports it and
# kata-deploy writes its handler there, so this is a no-op on a stock node.
# kind's config has no imports key at all, and TOML bare keys must precede the
# first [table], so the key is prepended rather than appended when created.
ENSURE_IMPORTS_GLOB='
    if ! grep -qF "/etc/containerd/conf.d/*.toml" /etc/containerd/config.toml; then
      if grep -q "^imports" /etc/containerd/config.toml; then
        sed -i "s|^imports[[:space:]]*=[[:space:]]*\[|imports = [\"/etc/containerd/conf.d/*.toml\", |" /etc/containerd/config.toml
      else
        { printf "imports = [\"/etc/containerd/conf.d/*.toml\"]\n"; cat /etc/containerd/config.toml; } > /tmp/ctr-cfg.toml
        cat /tmp/ctr-cfg.toml > /etc/containerd/config.toml
        rm -f /tmp/ctr-cfg.toml
      fi
      grep -qF "/etc/containerd/conf.d/*.toml" /etc/containerd/config.toml || {
        echo "ERROR: could not add the conf.d glob to the imports array in /etc/containerd/config.toml" >&2
        exit 1
      }
    fi'

RUNTIME="${RUNTIME:-containerd}"
CLUSTER_NAME="${CLUSTER_NAME:-nono-${RUNTIME}}"
IMAGE="${IMAGE:-nono-nri:latest}"
KATA="${KATA:-true}"             # set KATA=false to skip Kata Containers
# Pinned kata-containers version.
# 4.0.0+ is required: earlier kata kernels are built without Landlock and have
# no composable-VM-images (guest_extension_images) support.
KATA_VERSION="${KATA_VERSION:-4.0.0}"
# nono guest extension image carrying the hardened kata-agent OPA policy
# (published by the kata-nono-extension GHA workflow). Requires KATA=true.
# Cold-plugged into the VM via guest_extension_images; the stock kata guest
# image is used unmodified.
KATA_EXTENSION="${KATA_EXTENSION:-true}"
KATA_EXTENSION_IMAGE="${KATA_EXTENSION_IMAGE:-}"
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
  # Register the nono-runc handler as a conf.d drop-in. Idempotent by
  # construction — the file is rewritten rather than appended to, so re-running
  # cannot duplicate the stanza and deleting the file removes the handler.
  #
  # 30-, not the chart's 40-nono-runc.toml: this runs before the chart is
  # installed and its node-setup DaemonSet writes a superset of this file (NRI
  # as well). Sharing the name would let a deploy.sh re-run clobber the chart's
  # NRI config. Two files declaring the same handler is fine — containerd
  # merges imports in glob order and the values are identical.
  docker exec "$NODE" sh -c "
    ${CRI_PLUGIN_NAME}
    mkdir -p /etc/containerd/conf.d
    cat > /etc/containerd/conf.d/30-nono-runc.toml << CONTAINERD_EOF
[plugins.\"\${CRI_PLUGIN}\".containerd.runtimes.nono-runc]
  runtime_type = \"io.containerd.runc.v2\"
CONTAINERD_EOF
    ${ENSURE_IMPORTS_GLOB}
    systemctl restart containerd
    sleep 3
    echo \"    containerd restarted with the nono-runc drop-in (\${CRI_PLUGIN}).\"
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

  # 1b. Install dbus in the node — required by runtime-rs (the kata 4.0 default
  #     shim). It picks its cgroup manager from the shape of the cgroup path
  #     containerd hands it (resource/src/cgroups/resource_inner.rs:
  #     is_systemd_cgroup), and kind's kubelet uses cgroupDriver: systemd, so the
  #     path is a systemd slice and runtime-rs talks to systemd over dbus. kind
  #     node images run systemd but ship no dbus at all, so sandbox creation dies
  #     with:
  #       add runtime to sandbox cgroup
  #       systemd dbus error: I/O error: No such file or directory (os error 2)
  #     Real nodes have dbus, so this is a kind-fidelity gap, not a kata bug —
  #     which is why it is fixed here and not in the Helm chart.
  echo "==> Installing dbus in the node (required by runtime-rs cgroup setup)..."
  docker exec "$NODE" sh -c '
    if [ -S /run/dbus/system_bus_socket ]; then
      echo "    dbus already running."
    else
      apt-get update -qq >/dev/null 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dbus >/dev/null 2>&1
      systemctl start dbus
      for _i in $(seq 1 30); do
        [ -S /run/dbus/system_bus_socket ] && break
        sleep 1
      done
      if [ -S /run/dbus/system_bus_socket ]; then
        echo "    dbus started."
      else
        echo "ERROR: dbus socket never appeared; runtime-rs sandboxes will fail" >&2
        exit 1
      fi
    fi
  '

  # 2. The kata-bundled guest kernel already has CONFIG_SECURITY_LANDLOCK=y from
  #    kata 4.0 onward (tools/packaging/kernel/configs/fragments/common/landlock.conf
  #    is applied to every kata kernel build), so the stock kernel and initrd are
  #    used unchanged — no custom kernel to build, pull or patch in.

  KATA_SHARE="/opt/kata/share/kata-containers"
  # runtime-rs configs live under a runtime-rs/ prefix, unlike the Go runtime's.
  KATA_CFG="/opt/kata/share/defaults/kata-containers/runtime-rs/runtimes/qemu-runtime-rs/configuration-qemu-runtime-rs.toml"

  # Wait for the QEMU config file to appear. kata-deploy writes it asynchronously:
  # `kubectl rollout status` returns once the pod is Ready, but the pod re-execs
  # into a post-install waiter and its readiness does not mean the node files are
  # complete. On kata 4.0 the install takes ~3.5 min (it also sets up the erofs /
  # nydus snapshotter and waits for the node label to stabilise), so poll well past
  # that — the whole deploy fails if we give up early.
  _CFG_WAIT=420
  echo "==> Waiting for kata QEMU config file (up to ${_CFG_WAIT}s)..."
  for _i in $(seq 1 "${_CFG_WAIT}"); do
    docker exec "$NODE" test -f "${KATA_CFG}" 2>/dev/null && break
    [[ $((_i % 30)) -eq 0 ]] && echo "    Still waiting for ${KATA_CFG}... (${_i}s)"
    sleep 1
  done
  if ! docker exec "$NODE" test -f "${KATA_CFG}" 2>/dev/null; then
    echo "ERROR: kata QEMU config not found at ${KATA_CFG} after ${_CFG_WAIT} s"
    echo "  kata-deploy pod status:"
    kubectl get pods -n kube-system -l name=kata-deploy -o wide 2>/dev/null || true
    echo "  kata-deploy logs (tail):"
    kubectl logs -n kube-system -l name=kata-deploy --tail=30 2>/dev/null || true
    echo "  configs present on node:"
    docker exec "$NODE" find /opt/kata/share/defaults -name '*.toml' 2>/dev/null || true
    exit 1
  fi

  # Patch kata QEMU config for nested KVM; kernel and initrd stay as shipped.
  docker exec "$NODE" sh -c "
    sed -i 's|^machine_accelerators = .*|machine_accelerators = \"kernel_irqchip=split\"|' '${KATA_CFG}'
  "
  echo "    Kata QEMU config patched (kernel_irqchip=split)."

  # ── kata-nono-qemu: hardened agent policy via a guest extension image ────────
  if [[ "$KATA_EXTENSION" == "true" ]]; then
    echo ""
    echo "==> Deploying kata-nono-sandbox (nono guest extension, kata-nono-qemu handler)..."

    KATA_EXT_IMG="/tmp/kata-nono-extension.img"

    # Build from the working tree by default: this is the dev and test path, so
    # e2e must exercise the policy.rego in this checkout, never whatever :latest
    # happens to carry — otherwise a policy change under test is not the thing
    # tested. Cost is ~0.1 s warm, ~18 s cold, against a deploy of minutes. Set
    # KATA_EXTENSION_IMAGE to check a published image on purpose.
    if [ -n "${KATA_EXTENSION_IMAGE}" ]; then
      echo "    Pulling extension image: ${KATA_EXTENSION_IMAGE}"
      docker pull -q "${KATA_EXTENSION_IMAGE}" >/dev/null || {
        echo "ERROR: could not pull ${KATA_EXTENSION_IMAGE}"
        echo "       Unset KATA_EXTENSION_IMAGE to build from deploy/kata-extension/ instead."
        exit 1
      }
      _EXT_IMG="${KATA_EXTENSION_IMAGE}"
    else
      echo "    Building extension image from deploy/kata-extension/..."
      docker build -q -t kata-nono-extension:local "${REPO_ROOT}/deploy/kata-extension" >/dev/null
      _EXT_IMG="kata-nono-extension:local"
    fi

    _CTR=$(docker create "${_EXT_IMG}")
    docker cp "${_CTR}:/kata-nono-extension.img" "${KATA_EXT_IMG}"
    docker rm "${_CTR}" >/dev/null

    # Deploy the extension image onto the node.
    KATA_NONO_EXT="${KATA_SHARE}/kata-nono-extension.img"
    docker cp "${KATA_EXT_IMG}" "${NODE}:${KATA_NONO_EXT}"
    docker exec "$NODE" chmod 644 "${KATA_NONO_EXT}"
    echo "    Deployed: ${KATA_NONO_EXT}"

    # Create a dedicated kata config for the kata-nono-qemu handler. It inherits
    # everything from configuration-qemu.toml — including the stock guest image,
    # which is no longer modified — and only adds the nono extension.
    #
    # verity_params is empty: the extension carries no dm-verity hash partition,
    # so kata-extension-mount.sh raw-mounts it. The parameter is still emitted on
    # the kernel command line, and that is what activates the guest-side mount
    # unit, so the entry must be present even though the value is empty.
    #
    # agent.config_file points the kata-agent at the policy shipped in the
    # extension. It must be appended to kernel_params rather than replacing it,
    # and note that the agent stops parsing the command line at this parameter —
    # any other agent.* setting has to go inside agent-config.toml instead.
    #
    # disable_guest_seccomp must be false or the kata-agent ignores the OCI
    # seccomp profile that nono-nri injects, and the container runs inside the VM
    # with no filter at all (Seccomp: 0). kata ships it as true, so it has to be
    # flipped explicitly — the Helm chart does the same thing.
    #
    # seccomp_sandbox confines the QEMU process on the host, so a guest that has
    # already escaped the VM is contained too. Note the underscore: runtime-rs
    # parses the Go runtime's seccompsandbox to "" and confines nothing at all,
    # silently. Keep the value identical to kata.qemu.seccompSandbox in
    # values.yaml so e2e exercises what a chart install actually runs.
    KATA_CFG_NONO="$(dirname ${KATA_CFG})/configuration-kata-nono-qemu.toml"
    KATA_QEMU_SECCOMP="on,obsolete=deny,spawn=deny,resourcecontrol=deny"
    docker exec "$NODE" sh -c "
      cp '${KATA_CFG}' '${KATA_CFG_NONO}'
      sed -i 's|^kernel_params = \"\(.*\)\"|kernel_params = \"\1 agent.config_file=/run/kata-extensions/nono/agent-config.toml\"|' '${KATA_CFG_NONO}'
      sed -i 's|^disable_guest_seccomp = .*|disable_guest_seccomp = false|' '${KATA_CFG_NONO}'
      sed -i 's|^seccomp_sandbox = .*|seccomp_sandbox = \"${KATA_QEMU_SECCOMP}\"|' '${KATA_CFG_NONO}'
      cat >> '${KATA_CFG_NONO}' <<EOF

[[hypervisor.qemu.guest_extension_images]]
name = \"nono\"
path = \"${KATA_NONO_EXT}\"
verity_params = \"\"
EOF
    "
    docker exec "$NODE" grep -q 'agent.config_file=/run/kata-extensions/nono' "${KATA_CFG_NONO}" || {
      echo "ERROR: failed to add agent.config_file to ${KATA_CFG_NONO}"
      docker exec "$NODE" grep -n 'kernel_params' "${KATA_CFG_NONO}" || true
      exit 1
    }
    docker exec "$NODE" grep -q '^disable_guest_seccomp = false' "${KATA_CFG_NONO}" || {
      echo "ERROR: guest seccomp still disabled in ${KATA_CFG_NONO} — the injected seccomp profile would be ignored inside the VM"
      exit 1
    }
    docker exec "$NODE" grep -q "^seccomp_sandbox = \"${KATA_QEMU_SECCOMP}\"" "${KATA_CFG_NONO}" || {
      echo "ERROR: failed to set seccomp_sandbox in ${KATA_CFG_NONO} — QEMU would run unconfined on the host"
      exit 1
    }
    echo "    Created ${KATA_CFG_NONO} with the nono guest extension."

    # Register kata-nono-qemu as a runtime handler in the active CRI.
    if [[ "$RUNTIME" == "crio" ]]; then
      docker exec "$NODE" sh -c "
        cat > /etc/crio/crio.conf.d/98-kata-nono-qemu.conf <<'EOF'
[crio.runtime.runtimes.kata-nono-qemu]
runtime_path = \"/opt/kata/runtime-rs/bin/containerd-shim-kata-v2\"
runtime_type = \"vm\"
runtime_root = \"/run/vc\"
runtime_config_path = \"${KATA_CFG_NONO}\"
EOF
        systemctl restart crio
      "
      sleep 3
      echo "    CRI-O restarted with kata-nono-qemu handler."
    else
      # containerd: a drop-in in conf.d, the same directory and plugin name
      # kata-deploy uses for its own handler, and the CRI-O branch above already
      # works this way. Appending to config.toml made the edit non-idempotent
      # (hence the grep guard it needed) and left the handler unremovable.
      docker exec "$NODE" sh -c "
        ${CRI_PLUGIN_NAME}
        mkdir -p /etc/containerd/conf.d
        cat > /etc/containerd/conf.d/50-nono-kata.toml << CONTAINERD_EOF
[plugins.\"\${CRI_PLUGIN}\".containerd.runtimes.kata-nono-qemu]
  runtime_type = \"io.containerd.kata-qemu-runtime-rs.v2\"
  runtime_path = \"/opt/kata/runtime-rs/bin/containerd-shim-kata-v2\"
  privileged_without_host_devices = true
  pod_annotations = [\"io.katacontainers.*\"]
  [plugins.\"\${CRI_PLUGIN}\".containerd.runtimes.kata-nono-qemu.options]
    ConfigPath = \"${KATA_CFG_NONO}\"
CONTAINERD_EOF
        ${ENSURE_IMPORTS_GLOB}
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

if [[ "$KATA" == "true" && "$KATA_EXTENSION" == "true" ]]; then
  HELM_SET_ARGS+=(
    --set "config.runtimeClasses={nono-runc,kata-qemu-runtime-rs,kata-nono-qemu}"
    --set "runtimeClasses.kataNono.handler=kata-nono-qemu"
  )
elif [[ "$KATA" == "true" ]]; then
  HELM_SET_ARGS+=(
    --set "config.runtimeClasses={nono-runc,kata-qemu-runtime-rs}"
    --set "runtimeClasses.kataNono.handler=kata-qemu-runtime-rs"
  )
fi

helm upgrade --install kubefence "$REPO_ROOT/deploy/helm/kubefence" \
  --namespace kube-system \
  --wait --timeout 120s \
  "${HELM_SET_ARGS[@]}"

echo "==> kubefence deployed."

# Belt-and-suspenders: Helm 3 --wait has known DaemonSet readiness gaps.
# Verify DaemonSet rollout explicitly, then emit pod diagnostics on failure
# so the root cause is visible without a separate kubectl session.
echo ""
echo "==> Waiting for DaemonSet rollout..."
kubectl rollout status daemonset/kubefence -n kube-system --timeout=120s || {
  echo ""
  echo "ERROR: DaemonSet rollout timed out. Pod diagnostics:"
  kubectl get pods -n kube-system -l app.kubernetes.io/name=kubefence -o wide 2>/dev/null || true
  _POD=$(kubectl get pod -n kube-system -l app.kubernetes.io/name=kubefence \
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
