# kubefence

!!! warning "Proof of Concept"
    This is experimental software — not for production use. It is provided as-is
    with no guarantees of stability, security, or support.

kubefence is a Kubernetes [NRI (Node Resource Interface)](https://github.com/containerd/nri)
plugin that transparently sandboxes container processes using
[nono](https://nono.sh), a kernel-enforced sandbox CLI built on Linux
[Landlock LSM](https://docs.kernel.org/userspace-api/landlock.html).

It is designed for running untrusted workloads — such as AI agent generated
code — inside a Kubernetes cluster, with strong isolation between the workload
and the worker node.

## What kubefence does

- **Intercepts container creation** via the NRI API and wraps every container
  process with the nono sandbox before it starts
- **Applies Landlock filesystem restrictions** at the kernel level — a
  compromised process inside the container cannot remove its own restrictions
- **Delivers VM-level pod isolation** through [Kata Containers](https://github.com/kata-containers/kata-containers):
  each pod runs inside a QEMU/KVM micro-VM, and `kubectl exec` is blocked at
  the hypervisor by the kata-agent OPA policy
- **Requires explicit opt-in** via Kubernetes RuntimeClass — non-opted pods are
  skipped with zero overhead

## How it works

1. A pod is created with `runtimeClassName: kata-nono-sandbox`
2. The NRI plugin receives the `CreateContainer` event from containerd or CRI-O
3. The plugin prepends `/nono/nono wrap --profile <profile> --` to the container's `process.args`
4. The container starts — nono applies the Landlock sandbox and `exec()`s into the original command
5. The container process runs sandboxed under kernel enforcement; nono has replaced itself as PID 1

```
Pod spec: command: ["myapp", "--flag"]
                    | NRI plugin
OCI spec: args:   ["/nono/nono", "wrap", "--profile", "default", "--", "myapp", "--flag"]
                    | container start (inside Kata VM)
PID 1:    /usr/bin/myapp --flag   (nono exec'd the app; kubectl exec blocked by OPA)
```

## Container images

Published images built by CI on every release:

| Image | Contents |
|-------|----------|
| `ghcr.io/kubefence/nono-nri-plugin:latest` | NRI plugin (`10-nono-nri`) + `nono` sandbox binary |
| `ghcr.io/kubefence/kata-kernel-landlock:latest` | Kata guest kernel with `CONFIG_SECURITY_LANDLOCK=y` |
| `ghcr.io/kubefence/kata-rootfs-nono:latest` | Kata rootfs with `nono` binary pre-installed |
| `ghcr.io/kubefence/charts/kubefence:latest` | Helm chart for deployment |

## Documentation

| Section | What you will find |
|---------|-------------------|
| [Architecture](architecture.md) | How kubefence and nono work together, threat model, Kata vs runc |
| [Installation](installation.md) | Helm install steps for Kata and runc paths, prerequisites |
| [Configuration](configuration.md) | All Helm values and TOML config fields explained |
| [Usage](usage.md) | Opting pods in, nono profiles, verifying sandbox injection |
| [Caveats](caveats.md) | Known limitations and PoC constraints |
| [Troubleshooting](troubleshooting.md) | Diagnostic steps for common failure modes |
