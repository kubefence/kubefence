# Installation

## Prerequisites

| Component | Minimum version | Notes |
|-----------|----------------|-------|
| Linux kernel | 5.13+ | Landlock LSM required |
| containerd | 2.2.0+ | NRI with `AdjustArgs` support required |
| CRI-O | 1.35+ | NRI with `AdjustArgs` support required |
| Helm | 3.x | For chart installation |
| KVM | — | Required for Kata path only; `/dev/kvm` must be available on nodes |

Only one of containerd or CRI-O is required. containerd 2.2.0+ is the tested
and recommended path.

---

## Kata Containers path

Kata adds a second enforcement layer: each pod runs inside a QEMU/KVM
micro-VM, and `kubectl exec` is blocked at the hypervisor by the kata-agent
OPA policy. The nono Landlock sandbox runs inside the VM.

### Step 1 — Install kata-deploy

!!! note
    kata-deploy must be fully rolled out before installing kubefence. The
    kubefence kata-setup DaemonSet waits for kata-deploy's configuration files
    to appear before proceeding.

```bash
helm upgrade --install kata-deploy \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version 3.28.0 \
  --namespace kube-system \
  --set k8sDistribution=k8s \
  --set shims.disableAll=true \
  --set shims.qemu.enabled=true \
  --wait --timeout 10m

kubectl rollout status daemonset/kata-deploy -n kube-system --timeout=5m
```

### Step 2 — Install kubefence with Kata support

```bash
helm upgrade --install kubefence \
  oci://ghcr.io/kubefence/charts/kubefence \
  --version 1.0.0 \
  --namespace kube-system \
  --set kata.enabled=true \
  --set runtimeClasses.kataNono.enabled=true \
  --set runtimeClasses.kataNono.handler=kata-nono-qemu \
  --set "config.runtimeClasses={nono-runc,kata-qemu,kata-nono-qemu}" \
  --set "config.vmRootfsClasses={kata-nono-qemu}" \
  --wait
```

The `kata-setup` DaemonSet will:

- Pull `ghcr.io/kubefence/kata-kernel-landlock:latest` and install the
  Landlock-enabled `vmlinux` onto each node
- Pull `ghcr.io/kubefence/kata-rootfs-nono:latest` and install the Kata rootfs
  (with `nono` pre-installed) onto each node
- Patch the kata QEMU config to use the Landlock kernel
- Create `configuration-kata-nono-qemu.toml` referencing the nono rootfs
- Register the `kata-nono-qemu` runtime handler in containerd

### Step 3 — Verify

```bash
kubectl rollout status daemonset/kubefence-node-setup  -n kube-system
kubectl rollout status daemonset/kubefence-kata-setup  -n kube-system
kubectl rollout status daemonset/kubefence              -n kube-system

# Two RuntimeClasses should exist
kubectl get runtimeclass nono-runc kata-nono-sandbox
```

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
    (`/opt/nono-nri/nono`) or undo containerd config changes applied by the
    node-setup DaemonSet. Restart containerd after uninstall if you need to
    fully restore the original configuration.
