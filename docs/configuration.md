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
| `config.vmRootfsClasses` | `[]` | RuntimeClass handlers that have nono embedded in the Kata guest rootfs. Bind-mount is skipped for these handlers |

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

The plugin validates `runtime_classes` and `nono_bin_path` at startup. Missing
or empty values cause an immediate exit with an error message.
