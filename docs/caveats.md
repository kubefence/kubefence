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

## Kata kernel requirement

The default Kata Containers kernel (from `kata-deploy`) is built without
`CONFIG_SECURITY_LANDLOCK=y`. Attempting to run nono inside a Kata VM with
the default kernel will fail — nono cannot apply Landlock restrictions and
will exit with an error.

Kata Containers 4.0 and later build every guest kernel with
`CONFIG_SECURITY_LANDLOCK=y` (`tools/packaging/kernel/configs/fragments/common/landlock.conf`),
so the kernel kata-deploy ships is used unchanged. Kata releases before 4.0 are
not supported: their guest kernels have Landlock compiled out and nono cannot
enforce anything inside the VM.

## /nono directory must not exist in container images

The nono binary is bind-mounted by creating a directory mount at `/nono` inside
the container. If a container image already has a `/nono` directory or file in
its rootfs, the mount may behave unexpectedly.

!!! warning
    Ensure that container images used with kubefence do not define a `/nono`
    directory or file. The OCI runtime creates the mount point automatically;
    a pre-existing path with different content or permissions can cause mount
    conflicts.

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
- **Syscalls** — beyond what seccomp provides separately (kubefence does not configure seccomp)
- **Inter-process communication** — shared memory, signals, and IPC are unrestricted
- **JIT/mmap-based execution** — a workload that bypasses the filesystem entirely is not constrained by Landlock

These are fundamental limitations of Landlock, not gaps in kubefence. For
network isolation, use Kubernetes NetworkPolicy or a service mesh. For syscall
filtering, configure a seccomp profile on the pod.

## Profile compatibility: nono wrap vs nono run

kubefence injects `nono wrap --profile <name> --` before the container command.
This only works with profiles that are compatible with `nono wrap`.

Some nono profiles activate proxy network mode, which requires `nono run`
instead. These profiles (`python-dev`, `node-dev`, `go-dev`, `rust-dev`) are
**incompatible** with kubefence. Attempting to use them will cause the container
to exit immediately with:

```
nono wrap does not support proxy mode
```

Use one of the verified profiles listed in the [Usage](usage.md) section.
Profile compatibility may change between nono versions — re-verify after upgrading.
