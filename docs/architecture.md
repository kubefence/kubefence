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

nono-nri constrains filesystem access, and narrows the syscall surface with the
seccomp profile it injects (`config.seccompProfile`, `restricted` by default). It
does not restrict network access or inter-process communication. A workload that
bypasses the filesystem entirely (e.g. via `mmap`/JIT) is not constrained by
Landlock.

## Kata vs runc

Kata Containers is the preferred runtime for kubefence. It adds a second
enforcement layer on top of nono: each pod runs inside a QEMU/KVM micro-VM,
so a container escape still requires breaking out of the VM. `kubectl exec`
is gated at the hypervisor level by the kata-agent OPA policy: only invocations
routed through `nono wrap` are permitted, ensuring Landlock confinement applies
to exec'd processes as well.

| Feature | Kata path | runc path |
|---------|-----------|-----------|
| VM isolation | Yes — each pod runs in a QEMU/KVM micro-VM | No — shared kernel with node |
| `kubectl exec` via nono | Yes — kata-agent OPA policy permits exec only through `nono wrap` | No — PATH wrappers cover name-only execs; full-path execs bypass |
| Landlock enforcement | Yes — nono applies Landlock inside the VM | Yes — nono applies Landlock on the node kernel |
| Kernel requirement | Met by the stock kata guest kernel — kata >= 4.0 builds every one with `CONFIG_SECURITY_LANDLOCK=y`, and kubefence installs no kernel of its own | Node kernel 5.13+ with Landlock already enabled |
| Deployment complexity | Higher — requires KVM, kata-deploy, three DaemonSets | Lower — requires containerd 2.2.0+, two DaemonSets |
| Performance overhead | Higher — VM startup latency per pod | Lower — container startup latency only |

For running AI agents or other untrusted code, Kata is strongly recommended
because the combination of VM isolation, Landlock filesystem confinement, and
nono-gated `kubectl exec` closes most lateral-movement paths.

## Delivery mode

The nono binary must be available inside the container. kubefence uses
bind-mount delivery: the nono binary is copied from the plugin container image
to the host by a DaemonSet init container. When a sandboxed container starts,
kubefence bind-mounts the host directory (`/opt/nono-nri`) into the container
at `/nono`. For Kata pods, virtiofsd exposes the host directory to the QEMU VM
guest transparently — the same bind-mount mechanism works without modification.

## DaemonSet architecture

kubefence deploys up to three DaemonSets depending on configuration:

**kubefence-node-setup** — privileged DaemonSet that runs once per node to:

- Enable NRI in containerd and register the `nono-runc` runtime handler, by
  writing a drop-in at `/etc/containerd/conf.d/40-nono-runc.toml`
- Copy the nono binary from the plugin image to `/opt/nono-nri/nono` on the host

Each writer owns a file rather than appending to the shared config:
node-setup writes `40-nono-runc.toml`, kata-setup writes `50-nono-kata.toml`.
`/etc/containerd/config.toml` is normally untouched — the only edit made there is
adding `/etc/containerd/conf.d/*.toml` to the `imports` array, which a stock
containerd 2.x config already lists. The handlers are declared under the CRI
plugin name matching the config's schema version (`io.containerd.cri.v1.runtime`
for version 3, `io.containerd.grpc.v1.cri` for version 2); the wrong name is
parsed and silently discarded.

**kubefence-kata-setup** — privileged DaemonSet (only when `kata.enabled=true`) that:

- Pulls and installs the nono guest extension image from `ghcr.io/kubefence/kata-nono-extension`
- Leaves the guest kernel and guest image as kata-deploy shipped them (kata >= 4.0
  enables Landlock by default and cold-plugs the extension as a separate device)
- Creates the `kata-nono-qemu` containerd runtime handler

**kubefence** — the NRI plugin DaemonSet that runs on every node and connects
to the containerd NRI socket. This is the main plugin process that intercepts
container creation events and applies nono injection.

All DaemonSets run with `automountServiceAccountToken: false` and dropped
capabilities for minimal host privilege.

### Startup ordering

The setup DaemonSets restart containerd to load their drop-ins, which drops the
NRI connection of an already-running plugin. Pods created in that window start
with no nono wrapper and no seccomp profile, and come up looking healthy — the
failure is silent from the workload's side.

Kubernetes has no cross-DaemonSet ordering, so each setup DaemonSet writes a
marker under `hostPaths.readyDir` (`/run/kubefence/{node,kata}-setup.done`) once
it is done restarting anything, and the plugin's `wait-for-node-setup` init
container blocks on the markers of the enabled DaemonSets plus the NRI socket.
Expect the plugin pod to sit in `Init:0/2` during a fresh install. The wait times
out after 300s and starts anyway, logging a warning: a plugin that starts late
still converges, one that never starts protects nothing.

The markers live on tmpfs by design — after a reboot they are gone and the setup
DaemonSets must re-assert them before the plugin is allowed to start again.

!!! warning
    The same window opens if you restart containerd by hand. Pods created before
    the plugin reconnects are not sandboxed.
