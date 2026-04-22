# Troubleshooting

## Plugin not starting

**Symptom:** The `kubefence` DaemonSet pods are not running, or the plugin
container is crash-looping.

**Step 1 — Check kernel version**

```bash
uname -r
```

The kernel must be 5.13 or later. If the kernel is older, kubefence refuses to
start with:

```
nono-nri: kernel X.Y is too old: nono-nri requires Linux 5.13+ for Landlock LSM support
```

Upgrade the node kernel or use a node image with a compatible kernel.

**Step 2 — Check NRI socket**

```bash
# On the node (or via kubectl exec into a privileged pod)
ls -la /var/run/nri/nri.sock
```

The NRI socket must exist. If it is missing, NRI is not enabled in containerd.
The `kubefence-node-setup` DaemonSet should enable it automatically; check
whether node-setup has completed successfully:

```bash
kubectl rollout status daemonset/kubefence-node-setup -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/component=node-setup --tail=50
```

**Step 3 — Check plugin logs**

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=kubefence --tail=100
```

Look for startup errors. Common messages:

- `"reading config: ..."` — config file not found or not mounted
- `"runtime_classes must not be empty"` — `config.runtimeClasses` is empty in Helm values
- `"nono_bin_path must not be empty"` — `config.nonoBinPath` not set
- `"stat /opt/nono-nri/nono: no such file or directory"` — nono binary not copied by node-setup

!!! tip
    Check node-setup logs first. If node-setup has not completed, the nono
    binary will not be present at the expected host path.

---

## Containers not sandboxed

**Symptom:** Pods are running but nono is not injecting — `/proc/1/cmdline`
shows the original command without the nono prefix.

**Step 1 — Verify RuntimeClass is set**

```bash
kubectl get pod <pod-name> -o jsonpath='{.spec.runtimeClassName}'
```

If this is empty, the pod is using the default runtime and will not be
intercepted by kubefence. Add `runtimeClassName: kata-nono-sandbox` (Kata) or
`runtimeClassName: nono-runc` (runc) to the pod spec.

**Step 2 — Check plugin logs for the pod**

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=kubefence | grep <pod-name>
```

If you see a log entry with `"decision":"skip"`, the plugin received the event
but chose not to inject. The `"reason"` field explains why:

- `"runtime class not in config"` — the pod's RuntimeClass handler is not in `config.runtimeClasses`

Verify that the RuntimeClass handler exactly matches one of the entries in
`config.runtimeClasses`. The match is case-sensitive.

**Step 3 — Verify nono binary on host**

```bash
# On the node (or via kubectl exec into a privileged pod)
ls -la /opt/nono-nri/nono
```

If the binary is absent, node-setup has not completed. Check node-setup status
and logs as described in the previous section.

---

## Kata VM issues

**Symptom:** Kata pods fail to start, or nono fails inside the VM with
`"Landlock is not supported by the current kernel"`.

**Step 1 — Check KVM availability**

```bash
# On the node
ls -la /dev/kvm
```

If `/dev/kvm` does not exist, the node does not have KVM hardware acceleration
or it is not enabled. Kata requires KVM.

**Step 2 — Check /dev/shm size**

Kata uses `/dev/shm` as a memory backend for NUMA configuration. The default
64 MB is too small for typical Kata VM sizes.

```bash
df -h /dev/shm
```

If `/dev/shm` is smaller than the VM memory size, Kata pods will fail to
start. On Kind nodes, remount with a larger size:

```bash
mount -o remount,size=16g /dev/shm
```

!!! warning
    This change is not persistent across node restarts on Kind clusters.

**Step 3 — Check kata-deploy rollout**

```bash
kubectl rollout status daemonset/kata-deploy -n kube-system --timeout=5m
```

The kubefence kata-setup DaemonSet waits for kata-deploy to complete before
proceeding. If kata-deploy is not rolled out, the Landlock kernel will not be
installed.

**Step 4 — Check kata-setup logs**

```bash
kubectl logs -n kube-system -l app.kubernetes.io/component=kata-setup --tail=100
```

Look for errors in kernel or rootfs installation.

**Step 5 — Nested KVM (Kind clusters)**

If running Kata inside a Kind cluster (nested KVM), also set:

```yaml
kata:
  qemu:
    machineAccelerators: "kernel_irqchip=split"
```

This is required for nested-KVM stability. Without it, Kata VMs may crash or
hang intermittently.

---

## Log interpretation

The kubefence plugin emits structured JSON logs for every container event.

**Key fields:**

| Field | Description |
|-------|-------------|
| `msg` | Event type: `"injected"`, `"skip"`, `"container-stopping"`, `"container-removed"` |
| `decision` | Either `"inject"` or `"skip"` |
| `container_id` | The container ID (truncated) |
| `pod` | Pod name |
| `namespace` | Pod namespace |
| `profile` | nono profile applied (or would have been applied) |
| `runtime_handler` | RuntimeClass handler name from the pod spec |
| `reason` | For `"skip"` decisions, the reason the container was not sandboxed |
| `level` | `INFO` for normal decisions; `WARN` for non-critical errors |

**Example — injection:**

```json
{
  "time": "2025-01-15T10:23:45Z",
  "level": "INFO",
  "msg": "injected",
  "decision": "inject",
  "container_id": "abc123def456",
  "pod": "my-agent",
  "namespace": "default",
  "profile": "claude-code",
  "runtime_handler": "kata-nono-qemu"
}
```

**Example — skip:**

```json
{
  "time": "2025-01-15T10:23:46Z",
  "level": "INFO",
  "msg": "skip",
  "decision": "skip",
  "container_id": "xyz789",
  "pod": "nginx-pod",
  "namespace": "default",
  "profile": "",
  "runtime_handler": "runc",
  "reason": "runtime class not in config"
}
```

**Example — non-critical warning:**

```json
{
  "time": "2025-01-15T10:24:00Z",
  "level": "WARN",
  "msg": "failed to write state metadata",
  "container_id": "abc123",
  "error": "mkdir /var/run/nono-nri/...: permission denied"
}
```

!!! note
    `WARN` level entries indicate non-critical errors. The container is still
    sandboxed when a state write fails — the failure only affects audit metadata
    and cleanup, not the nono injection itself.

    NRI SDK internals emit their own logs in logrus format
    (`time="..." level=info msg="..."`). These are from the SDK, not the
    kubefence plugin.
