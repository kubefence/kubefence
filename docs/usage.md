# Usage

## Opting pods in

Sandboxing is opt-in via Kubernetes RuntimeClass. Set `runtimeClassName` on
the pod spec to activate kubefence for that pod.

**Kata Containers (recommended):**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-agent
spec:
  runtimeClassName: kata-nono-sandbox
  containers:
    - name: agent
      image: myimage:latest
      command: ["myapp", "--flag"]
```

**runc:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-agent
spec:
  runtimeClassName: nono-runc
  containers:
    - name: agent
      image: myimage:latest
      command: ["myapp", "--flag"]
```

Pods without `runtimeClassName`, or pods whose RuntimeClass handler does not
match the plugin's configured `runtime_classes`, are completely unaffected.
The plugin logs a `"skip"` decision for them and returns immediately with no
adjustment.

## nono profiles

nono profiles define the Landlock filesystem policy applied to the container
process. Specify a profile via the `nono.sh/profile` annotation:

```yaml
metadata:
  annotations:
    nono.sh/profile: "claude-code"
```

The annotation value is validated against the regex `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`.
Invalid values are silently ignored and the pod falls back to the `default_profile`
configured in the Helm values or TOML config.

### Verified profiles

The following profiles are verified to work with kubefence's `nono wrap`
injection (tested against nono v0.23.0):

| Profile | Notes |
|---------|-------|
| `default` | Base system profile. Safe default for most workloads |
| `claude-code` | Claude Code agent profile |
| `codex` | OpenAI Codex agent profile |
| `opencode` | Open-source code agent profile |
| `swival` | Python/Node.js development agent profile |

### Incompatible profiles

Some nono profiles enable proxy network mode and require `nono run` instead of
`nono wrap`. These **cannot** be used with kubefence:

| Profile | Failure reason | Workaround |
|---------|---------------|------------|
| `python-dev` | `nono wrap does not support proxy mode` | Requires `nono run` |
| `node-dev` | Same | Requires `nono run` |
| `go-dev` | Same | Requires `nono run` |
| `rust-dev` | Same | Requires `nono run` |

Profile availability varies by nono version. Re-verify profiles after upgrading
the nono binary.

## What happens at runtime

From the operator's perspective, the injection is transparent. The pod starts
normally and its original command runs as expected.

Internally:

1. The NRI plugin intercepts the `CreateContainer` event before the container starts
2. It prepends `/nono/nono wrap --profile <profile> --` to the container's args
3. It bind-mounts the nono binary directory from the host at `/nono` inside the container
4. It sets `NONO_PROFILE=<profile>` and prepends `/nono` to the container's `PATH`
5. The container starts; nono is PID 1
6. nono applies the Landlock filesystem policy, then `exec()`s into the original command
7. The original command becomes PID 1; Landlock restrictions are inherited by all child processes

The `exec()` means nono does not remain in the process tree — on runc,
`/proc/1/cmdline` shows the original application command, not nono. Inside a Kata
pod the sandbox denies that read; see the note under
[Verification](#verification).

The `/nono` prefix on `PATH` enables nono wrapper scripts to intercept child
process execs (e.g. `sh`, `bash`, `python3`) that are spawned without a full
path. This covers `kubectl exec` sessions and subprocesses.

## Verification

After deploying a sandboxed pod, verify injection is working:

`deploy/test-pod.yaml` runs on `kata-nono-sandbox`, where the kata-agent policy
permits exec only through `nono wrap` — so route the checks that way:

```bash
# Apply a test pod
kubectl apply -f deploy/test-pod.yaml
kubectl wait --for=condition=ready pod/nono-test --timeout=120s

# nono binary is bind-mounted into the container (via virtiofs, for Kata)
kubectl exec nono-test -- /nono/nono wrap --profile default -- ls -la /nono/nono
# Expected: -rwxr-xr-x 1 0 0 14352424 ... /nono/nono

# The injected seccomp profile is applied
kubectl exec nono-test -- /nono/nono wrap --profile default -- \
  grep ^Seccomp: /proc/self/status
# Expected: Seccomp:	2   (filter mode)

# Check plugin decision logs for this pod
kubectl logs -n kube-system -l app.kubernetes.io/component=plugin | grep nono-test
# Expected: {"msg":"injected","decision":"inject","pod":"nono-test","profile":"default",...}

# Cleanup
kubectl delete pod nono-test
```

A **bare** exec into a Kata pod is refused, and that denial is itself the proof
the hardened policy is mounted (kata's own default policy is allow-all):

```bash
kubectl exec nono-test -- ls -la /nono/nono
# error: ... PERMISSION_DENIED ... "ExecProcessRequest is blocked by policy"
```

On `nono-runc` there is no policy gate, so a bare exec works and `/proc/1/cmdline`
shows the original command — nono `exec()`d into it:

```bash
kubectl exec <runc-pod> -- cat /proc/1/cmdline | tr '\0' ' '
# Expected: /usr/bin/sleep infinity
```

!!! note
    Inside a Kata pod, reading `/proc/1/cmdline` is denied by the sandbox
    (`Permission denied`), so confirm `SetArgs` there from the plugin logs or the
    host-side OCI bundle rather than from PID 1.
