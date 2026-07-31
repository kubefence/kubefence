# Installation

## Prerequisites

| Component | Minimum version | Notes |
|-----------|----------------|-------|
| Linux kernel | 5.13+ | Landlock LSM required |
| containerd | 2.2.0+ | NRI with `AdjustArgs` support required |
| CRI-O | 1.35+ | NRI with `AdjustArgs` support required |
| Helm | 3.x | For chart installation |
| Kata Containers | 4.0.0+ | Kata path only. Earlier guest kernels have Landlock compiled out and have no composable-image support |
| KVM | — | Required for Kata path only; `/dev/kvm` must be available on nodes |

Only one of containerd or CRI-O is required. containerd 2.2.0+ is the tested
and recommended path.

---

## Kata Containers path

!!! tip "Default and preferred for untrusted workloads"
    Kata Containers is the recommended deployment model for kubefence. It
    combines VM-level pod isolation with Landlock filesystem confinement and
    hypervisor-enforced `kubectl exec` blocking — closing most lateral-movement
    paths. Use the runc path only when KVM is not available.

Kata adds a second enforcement layer: each pod runs inside a QEMU/KVM
micro-VM, and `kubectl exec` is blocked at the hypervisor by the kata-agent
OPA policy. The nono Landlock sandbox runs inside the VM.

### Step 1 — Install kata-deploy

!!! note
    kata-deploy must be fully rolled out before installing kubefence. The
    kubefence kata-setup DaemonSet waits for kata-deploy's configuration files
    to appear before proceeding.

Enable the `qemu-runtime-rs` shim — the kata 4.0 default, and the only one that
supports the `guest_extension_images` mechanism kubefence delivers the hardened
kata-agent policy through. `defaultShim` must name a shim enabled above or
kata-deploy refuses to start.

```bash
helm upgrade --install kata-deploy \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version 4.0.0 \
  --namespace kube-system \
  --set k8sDistribution=k8s \
  --set shims.disableAll=true \
  --set 'shims.qemu-runtime-rs.enabled=true' \
  --set defaultShim.amd64=qemu-runtime-rs \
  --wait --timeout 10m

kubectl rollout status daemonset/kata-deploy -n kube-system --timeout=5m
```

!!! warning
    The Go-runtime shim (`shims.qemu.enabled`) registers the handler
    `kata-qemu`, not `kata-qemu-runtime-rs`, and has no
    `guest_extension_images` support. The chart's kata defaults —
    `runtimeClasses.kataNono.handler` and `kata.qemuConfigPath` — assume
    runtime-rs, so kata-setup would wait indefinitely for a config file that
    never appears.

### Step 2 — Install kubefence with Kata support

```bash
helm upgrade --install kubefence \
  oci://ghcr.io/kubefence/charts/kubefence \
  --version 1.0.0 \
  --namespace kube-system \
  --set kata.enabled=true \
  --set runtimeClasses.kataNono.enabled=true \
  --set runtimeClasses.kataNono.handler=kata-nono-qemu \
  --set "config.runtimeClasses={nono-runc,kata-qemu-runtime-rs,kata-nono-qemu}" \
  --wait
```

The `kata-setup` DaemonSet will:

- Pull `ghcr.io/kubefence/kata-nono-extension:latest` and install the nono
  guest extension image onto each node
- Create `configuration-kata-nono-qemu.toml` — a copy of the kata QEMU config
  that cold-plugs the extension image and points `agent.config_file` at the
  policy inside it
- Register the `kata-nono-qemu` runtime handler in containerd

### Step 3 — Verify

```bash
kubectl rollout status daemonset/kubefence-node-setup  -n kube-system
kubectl rollout status daemonset/kubefence-kata-setup  -n kube-system
kubectl rollout status daemonset/kubefence              -n kube-system

# Two RuntimeClasses should exist
kubectl get runtimeclass nono-runc kata-nono-sandbox
```

!!! note
    The plugin DaemonSet gates on the setup DaemonSets finishing, so it stays in
    `Init:0/2` until both have published their markers under `/run/kubefence`.
    Rolling out the setup DaemonSets first is expected, not a hang — see
    [Architecture](architecture.md#daemonset-architecture).

---

## runc path

Deploy on any containerd cluster. The Helm chart enables NRI and registers the
`nono-runc` handler on every node via a privileged DaemonSet — no manual
containerd configuration changes are required.

!!! warning
    With runc, `kubectl exec` is **not** blocked at the runtime level. You must
    block it via admission policy (e.g.
    [Kyverno](https://kyverno.io/policies/other/block-pod-exec-by-pod-name/block-pod-exec-by-pod-name/))
    to prevent workloads from escaping the sandbox via exec.

```bash
helm upgrade --install kubefence \
  oci://ghcr.io/kubefence/charts/kubefence \
  --version 1.0.0 \
  --namespace kube-system \
  --wait

# Verify both DaemonSets are ready
kubectl rollout status daemonset/kubefence-node-setup -n kube-system
kubectl rollout status daemonset/kubefence            -n kube-system
```

---

## Upgrade

Upgrade kubefence (updates all three images atomically):

```bash
helm upgrade kubefence \
  oci://ghcr.io/kubefence/charts/kubefence \
  --version 1.1.0 \
  --namespace kube-system \
  --reuse-values
```

---

## Uninstall

```bash
# Remove kubefence
helm uninstall kubefence -n kube-system

# Optionally remove kata-deploy (Kata path only)
helm uninstall kata-deploy -n kube-system
```

!!! note
    Uninstalling kubefence does not remove the nono binary from host paths
    (`/opt/nono-nri/nono`) or the containerd drop-ins written by the setup
    DaemonSets. Those are files of their own, so undoing them is a delete:

    ```bash
    # On each node
    sudo rm -f /etc/containerd/conf.d/40-nono-runc.toml \
               /etc/containerd/conf.d/50-nono-kata.toml
    sudo rm -rf /opt/nono-nri /run/kubefence
    sudo systemctl restart containerd
    ```

    `/etc/containerd/config.toml` itself is normally untouched — the only edit
    the DaemonSets make there is adding `/etc/containerd/conf.d/*.toml` to the
    `imports` array, and a stock containerd 2.x config already lists it.
