# Configuration

## Helm Values

kubefence is configured via Helm values. The chart renders the TOML plugin
configuration automatically into a ConfigMap — you do not edit the TOML file
directly when using Helm.

### Core settings

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `ghcr.io/kubefence/nono-nri-plugin` | Plugin container image repository |
| `image.tag` | `latest` | Plugin container image tag. Pin to a release tag in production |
| `image.pullPolicy` | `IfNotPresent` | Kubernetes image pull policy |
| `namespace` | `kube-system` | Namespace for all kubefence resources |

### NRI plugin configuration

These values are rendered into the TOML config file loaded by the plugin.

| Value | Default | Description |
|-------|---------|-------------|
| `config.runtimeClasses` | `[nono-runc]` | List of RuntimeClass handler names to intercept. Pods whose RuntimeClass handler matches are sandboxed; all others are skipped |
| `config.defaultProfile` | `"default"` | nono profile used when a pod has no `nono.sh/profile` annotation |
| `config.nonoBinPath` | `"/opt/nono-nri/nono"` | Absolute host path to the nono binary. Copied there by the node-setup DaemonSet init container |
| `config.socketPath` | `""` | NRI socket path. Empty string uses the runtime default (`/var/run/nri/nri.sock`) |
| `config.seccompProfile` | `"restricted"` | Seccomp policy injected into every sandboxed container. `"restricted"` blocks io_uring, ptrace, the seccomp syscall, and pidfd_getfd on top of RuntimeDefault. `"runtime-default"` applies the Docker RuntimeDefault allowlist. `""` disables injection |

### RuntimeClass creation

| Value | Default | Description |
|-------|---------|-------------|
| `runtimeClasses.nonoRunc.enabled` | `true` | Create the `nono-runc` RuntimeClass (handler: `nono-runc`) |
| `runtimeClasses.kataNono.enabled` | `false` | Create the `kata-nono-sandbox` RuntimeClass |
| `runtimeClasses.kataNono.handler` | `"kata-qemu"` | Handler name for the Kata RuntimeClass. Must match a handler registered by kata-deploy |

### Kata Containers provisioning

| Value | Default | Description |
|-------|---------|-------------|
| `kata.enabled` | `false` | Enable the kata-setup DaemonSet. Requires kata-deploy to be installed first |
| `kata.kernelImage` | `ghcr.io/kubefence/kata-kernel-landlock:3.28.0` | OCI image carrying the Landlock-enabled vmlinux kernel. Pin to an immutable digest in production |
| `kata.rootfsImage` | `ghcr.io/kubefence/kata-rootfs-nono:3.28.0-v0.23.0` | OCI image carrying the Kata guest rootfs with nono pre-installed. Pin to an immutable digest in production |
| `kata.shareDir` | `/opt/kata/share/kata-containers` | Directory where kata-deploy installs kata share files on each node |
| `kata.qemuConfigPath` | `/opt/kata/share/defaults/kata-containers/runtimes/qemu/configuration-qemu.toml` | Path to the kata QEMU configuration file written by kata-deploy |
| `kata.qemu.machineAccelerators` | `""` | Additional QEMU machine accelerators. Set to `"kernel_irqchip=split"` for nested-KVM environments (e.g. Kind clusters) |
| `kata.qemu.seccompSandbox` | `"on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny"` | QEMU process-level seccomp sandbox (host kernel). Restricts syscalls available to the QEMU hypervisor process. `spawn=deny` prevents QEMU from exec'ing host binaries after a VM escape. Set to `""` to disable |
| `kata.qemu.disableGuestSeccomp` | `false` | Maps to `disable_guest_seccomp` in the kata QEMU config. `false` enables the kata-agent to apply the container's OCI seccomp profile (written by the NRI plugin) inside the guest VM |

### Node setup

| Value | Default | Description |
|-------|---------|-------------|
| `nodeSetup.enabled` | `true` | Enable the node-setup DaemonSet that patches containerd to enable NRI and register runtime handlers |
| `nodeSetup.nri.socketPath` | `/var/run/nri/nri.sock` | NRI socket path to configure in containerd |
| `nodeSetup.nri.pluginPath` | `/opt/nri/plugins` | NRI plugin path to configure in containerd |
| `nodeSetup.nri.configPath` | `/etc/nri/conf.d` | NRI config directory to configure in containerd |

### Resources

| Value | Default | Description |
|-------|---------|-------------|
| `resources.requests.cpu` | `50m` | CPU request for the plugin container |
| `resources.requests.memory` | `32Mi` | Memory request for the plugin container |
| `resources.limits.cpu` | `200m` | CPU limit for the plugin container. Prevents burst container-creation events from exhausting node memory |
| `resources.limits.memory` | `128Mi` | Memory limit for the plugin container |

### Helper images

| Value | Default | Description |
|-------|---------|-------------|
| `helperImages.alpine` | `alpine:3.20` | Alpine image used in privileged init containers. Pin to an immutable digest in production |
| `helperImages.busybox` | `busybox:1.37.0-uclibc` | Busybox image used in privileged init containers. Pin to an immutable digest in production |

---

## TOML Configuration

When using Helm, the chart renders the TOML configuration automatically into a
ConfigMap and mounts it at `/etc/nri/conf.d/10-nono-nri.toml` inside the
plugin container. You configure the plugin through Helm values — not by editing
the TOML file directly.

If you deploy kubefence without Helm, create the TOML file manually:

```toml
# RuntimeClass handler names to intercept (matches pod.GetRuntimeHandler())
runtime_classes = ["nono-runc"]

# nono profile when pod has no nono.sh/profile annotation
default_profile = "default"

# Host path to the nono binary (copied there by the DaemonSet init container)
nono_bin_path = "/opt/nono-nri/nono"

# NRI socket (empty = use runtime default: /var/run/nri/nri.sock)
socket_path = ""
```

### Field reference

| Field | Required | Description |
|-------|----------|-------------|
| `runtime_classes` | Yes | List of RuntimeClass handler names. The plugin sandboxes pods whose handler matches this list; all others are skipped with zero overhead |
| `default_profile` | Yes | nono profile used when a pod has no `nono.sh/profile` annotation |
| `nono_bin_path` | Yes | Absolute path to the nono binary on the host. The plugin checks this path at startup and refuses to start if the file is absent |
| `socket_path` | No | NRI socket path. Defaults to `/var/run/nri/nri.sock` when empty |
| `seccomp_profile` | No | Seccomp policy injected into every sandboxed container. See below |

The plugin validates `runtime_classes` and `nono_bin_path` at startup. Missing
or empty values cause an immediate exit with an error message.

### `seccomp_profile` values

| Value | Description |
|-------|-------------|
| `"restricted"` | Docker RuntimeDefault allowlist minus `io_uring_setup`, `io_uring_enter`, `io_uring_register`, `ptrace`, `seccomp`, and `pidfd_getfd`. Default for AI workloads. Blocks io_uring (CVE-2022-2639, CVE-2023-2598), cross-process inspection, and self-filter removal |
| `"runtime-default"` | Docker/moby RuntimeDefault allowlist verbatim. Equivalent to `seccompProfile.type: RuntimeDefault` in the pod security context |
| `""` (empty) | Disabled. The plugin injects no seccomp policy. Pods may still set their own policy via `securityContext.seccompProfile` |

Both profiles use `SCMP_ACT_ERRNO` as the default action (deny-by-default) and declare only `SCMP_ARCH_X86_64`. Syscalls already blocked by RuntimeDefault — including `bpf`, `mount`, `kexec_load`, `init_module`, `setns`, `unshare`, `process_vm_readv`, and `userfaultfd` — remain blocked in both profiles.

For Kata Containers, the NRI-injected policy takes effect inside the guest VM only when `disable_guest_seccomp = false` in the kata QEMU config. The kubefence kata-setup DaemonSet sets this automatically when `kata.qemu.disableGuestSeccomp: false` (the default).
