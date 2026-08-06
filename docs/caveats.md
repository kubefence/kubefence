# Caveats

!!! danger "Proof of Concept — Not for Production"
    kubefence is experimental software. It is provided as-is with no guarantees
    of stability, security, or support. Do not use it in production clusters or
    with sensitive workloads.

## Kernel requirement

kubefence requires Linux kernel **5.13 or later** for Landlock LSM support.
The plugin checks the kernel version at startup and refuses to start on older
kernels with a clear error message.

```
nono-nri: kernel 4.18 is too old: nono-nri requires Linux 5.13+ for Landlock LSM support
```

Most modern distributions (Ubuntu 22.04+, RHEL 9+, Debian 12+) ship kernels
that satisfy this requirement. Older node images or custom kernel builds may not.

## Kata version requirement

Kata Containers 4.0 or later is required. From that release every guest kernel is
built with `CONFIG_SECURITY_LANDLOCK=y`
(`tools/packaging/kernel/configs/fragments/common/landlock.conf`), so the kernel
`kata-deploy` ships is used unchanged and kubefence installs no kernel of its own.

Earlier Kata releases are not supported: their guest kernels have Landlock
compiled out, so nono cannot apply any restriction inside the VM and exits with
an error. They also lack the composable-VM-images support that delivers the
hardened kata-agent policy.

## /nono directory must not exist in container images

The nono binary is bind-mounted by creating a directory mount at `/nono` inside
the container. If a container image already has a `/nono` directory or file in
its rootfs, the mount may behave unexpectedly.

!!! warning
    Ensure that container images used with kubefence do not define a `/nono`
    directory or file. The OCI runtime creates the mount point automatically;
    a pre-existing path with different content or permissions can cause mount
    conflicts.

## Workload images must have glibc 2.34 or newer

The nono binary shipped in the plugin image is the upstream glibc release, and it
is bind-mounted into the container rather than built against it. So the workload
image must be able to run it:

| Image | Works |
|-------|-------|
| debian:12-slim, ubuntu:22.04+, RHEL/UBI 9+ | Yes (glibc 2.34+) |
| debian:11, ubuntu:20.04 | No — glibc 2.31, too old |
| alpine, `busybox:*-uclibc` | No — musl, and upstream publishes no musl build |

When the binary cannot start, the container exits immediately with code 2 and no
logs — the pod looks like it crashed on its own command.

## exec interception is partial for runc

kubefence prepends `/nono` to the container's `PATH` so that wrapper scripts
in `/nono` can intercept common interpreter execs (`sh`, `bash`, `python3`,
etc.) that are spawned without a full path. This covers most dynamic exec
scenarios.

However, processes that exec a binary using its **full absolute path** (e.g.
`exec("/usr/bin/python3", ...)`) bypass the PATH-based wrapper.

For Kata pods, the kata-agent OPA policy permits `kubectl exec` only when the
command is routed through `nono wrap`, so Landlock confinement applies to
exec'd processes as well. Callers must invoke exec as:
`kubectl exec <pod> -- /nono/nono wrap --profile <name> -- <cmd>`

## Landlock scope: filesystem only

Landlock LSM restricts filesystem access. kubefence does not restrict:

- **Network access** — workloads can make arbitrary network connections
- **Inter-process communication** — shared memory, signals, and IPC are unrestricted
- **JIT/mmap-based execution** — a workload that bypasses the filesystem entirely is not constrained by Landlock

These are fundamental limitations of Landlock, not gaps in kubefence. For
network isolation, use Kubernetes NetworkPolicy or a service mesh.

Syscall filtering is handled separately: kubefence injects a seccomp profile
into every sandboxed container (`config.seccompProfile`, `restricted` by
default — see [Configuration](configuration.md#seccomp_profile-values)). For
Kata pods this takes effect inside the guest, which requires
`kata.qemu.disableGuestSeccomp: false` (the default).

## Only the `default` profile works as shipped

kubefence injects `nono wrap --profile <name> --` before the container command,
and with nono v0.71.0 only `default` survives that unattended:

- The agent profiles (`claude-code`, `codex`, `opencode`) are now installable
  *packs* rather than part of the binary. Selecting one makes nono ask to install
  it, find no TTY, and exit 1 — so the container never starts. Fix: bake the
  pack into the **workload image** (`nono pull` at build time under an
  `XDG_CONFIG_HOME` outside `$HOME`) — verified in-cluster with
  `nolabs-ai/claude`; see [usage](usage.md#agent-workloads-claude-code).
- Profiles that want the working directory (`swival`, `python-dev`, …) exit 1 with
  `CWD access requires --allow-cwd in non-interactive mode`, and kubefence
  injects no `--allow-cwd`. Fix: grant the cwd explicitly with the `NONO_ALLOW`
  env var — nono skips the CWD gate when the cwd is already covered.

An invalid profile *name* falls back to the default safely; a valid name that
nono then refuses to run does not. Test any non-default profile in a scratch pod
before rolling it out, and re-verify after a nono upgrade — the set has changed
between versions before.

One related trap that produces no error text at all: the `default` profile's
`/proc/self` grant is resolved to the wrap target's PID at sandbox setup, so it
covers only the process nono `exec`s into. A *forked* child that needs its own
`/proc/self` (Bun-based CLIs such as Claude Code 2.x read `/proc/self/maps`)
aborts with exit 134 and empty output. Make such a program the final `exec` of
the container command and it inherits the granted PID.
