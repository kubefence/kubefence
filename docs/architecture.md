# Architecture

## Overview

kubefence is a Kubernetes NRI (Node Resource Interface) plugin. NRI is the
standard extension point for container runtimes (containerd, CRI-O) that allows
external plugins to inspect and modify containers at well-defined lifecycle
points — before creation, on stop, on removal.

When a container creation event arrives, kubefence:

1. Checks whether the pod's RuntimeClass handler matches the configured list (opt-in check)
2. Resolves the nono profile from the pod annotation or falls back to the configured default
3. Prepends `/nono/nono wrap --profile <profile> --` to the container's `process.args` using `ContainerAdjustment.SetArgs()`
4. Bind-mounts the nono binary from the host into the container at `/nono/nono`
5. Prepends `/nono` to the container's `PATH` so wrapper scripts intercept child process execs
6. Writes a metadata record for audit and cleanup

The nono binary takes over as PID 1, applies Landlock filesystem restrictions,
then `exec()`s into the original container command. From that point forward the
container process runs normally but under kernel-enforced filesystem confinement
that it cannot remove.

## Threat Model

Goal: Protecting the **worker node** from the workloads.

**Trusted** — the worker node and everything it provides to the workload:

- The node OS, its kernel, and all binaries running on it
- The nono-nri plugin itself and the nono binary
- Everything the node injects into the container at creation time: the
  `/nono` bind-mount, the `SetArgs` override that installs nono as PID 1,
  and the `NONO_PROFILE` / `PATH` environment variables

**Untrusted** — anything inside the container after it starts:

- The container workload and all processes it spawns
- Any code or data arriving from the network inside the container

**What is enforced:**

Landlock LSM restrictions are applied by nono before the container's own code
runs. Because Landlock is a kernel mechanism, a compromised process inside the
container cannot remove or weaken its own restrictions. Restrictions are also
inherited across `exec`, so child processes remain confined.

**What is not enforced:**

nono-nri constrains filesystem access. It does not restrict network access,
syscalls (beyond what seccomp provides separately), or inter-process
communication. A workload that bypasses the filesystem entirely (e.g. via
`mmap`/JIT) is not constrained by Landlock.

## Kata vs runc

Kata Containers is the preferred runtime for kubefence. It adds a second
enforcement layer on top of nono: each pod runs inside a QEMU/KVM micro-VM,
so a container escape still requires breaking out of the VM. `kubectl exec`
is also blocked at the hypervisor level by the kata-agent OPA policy.

| Feature | Kata path | runc path |
|---------|-----------|-----------|
| VM isolation | Yes — each pod runs in a QEMU/KVM micro-VM | No — shared kernel with node |
| `kubectl exec` blocking | Yes — blocked by kata-agent OPA policy | No — must be blocked by admission policy (e.g. Kyverno) |
| Landlock enforcement | Yes — nono applies Landlock inside the VM | Yes — nono applies Landlock on the node kernel |
| Custom kernel | Yes — kubefence deploys a custom kernel with `CONFIG_SECURITY_LANDLOCK=y` | No — requires node kernel 5.13+ with Landlock already enabled |
| Deployment complexity | Higher — requires KVM, kata-deploy, three DaemonSets | Lower — requires containerd 2.2.0+, two DaemonSets |
| Performance overhead | Higher — VM startup latency per pod | Lower — container startup latency only |

For running AI agents or other untrusted code, Kata is strongly recommended
because the combination of VM isolation, Landlock filesystem confinement, and
`kubectl exec` blocking closes most lateral-movement paths.

## Delivery modes

The nono binary must be available inside the container. kubefence supports two
delivery mechanisms:

**Bind-mount (default)**

The nono binary is copied from the container image to the host by a DaemonSet
init container. When a sandboxed container starts, kubefence bind-mounts the
host directory (`/opt/nono-nri`) into the container at `/nono`. For Kata pods,
virtiofsd exposes the host directory to the QEMU VM guest transparently — the
same bind-mount mechanism works without modification.

**Embedded rootfs (Kata only)**

For the `kata-nono-qemu` handler, nono is baked into the Kata guest rootfs
image (`ghcr.io/kubefence/kata-rootfs-nono`). The rootfs image is installed
on each node by the kata-setup DaemonSet. In this mode the bind-mount is
skipped — nono is already present in the guest at `/nono/nono`.

Which mode is active depends on whether the RuntimeClass handler is listed in
`config.vmRootfsClasses` in the Helm values. Handlers in that list use the
embedded rootfs; all others use the bind-mount.

## DaemonSet architecture

kubefence deploys up to three DaemonSets depending on configuration:

**kubefence-node-setup** — privileged DaemonSet that runs once per node to:

- Enable NRI in containerd (patches `/etc/containerd/config.toml`)
- Register the `nono-runc` runtime handler in containerd
- Copy the nono binary from the plugin image to `/opt/nono-nri/nono` on the host

**kubefence-kata-setup** — privileged DaemonSet (only when `kata.enabled=true`) that:

- Pulls and installs the custom Landlock-enabled vmlinux from `ghcr.io/kubefence/kata-kernel-landlock`
- Pulls and installs the nono-embedded Kata rootfs from `ghcr.io/kubefence/kata-rootfs-nono`
- Patches the kata QEMU configuration to use the Landlock kernel
- Creates the `kata-nono-qemu` containerd runtime handler

**kubefence** — the NRI plugin DaemonSet that runs on every node and connects
to the containerd NRI socket. This is the main plugin process that intercepts
container creation events and applies nono injection.

All DaemonSets run with `automountServiceAccountToken: false` and dropped
capabilities for minimal host privilege.
