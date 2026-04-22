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

The `exec()` means nono does not remain in the process tree — `/proc/1/cmdline`
shows the original application command, not nono.

The `/nono` prefix on `PATH` enables nono wrapper scripts to intercept child
process execs (e.g. `sh`, `bash`, `python3`) that are spawned without a full
path. This covers `kubectl exec` sessions and subprocesses.

## Verification

After deploying a sandboxed pod, verify injection is working:

```bash
# Apply a test pod
kubectl apply -f deploy/test-pod.yaml
kubectl wait --for=condition=ready pod/nono-test --timeout=60s

# nono exec()s into sleep — /proc/1/cmdline shows the original command
kubectl exec nono-test -- cat /proc/1/cmdline | tr '\0' ' '
# Expected: sleep infinity

# nono binary is bind-mounted into the container
kubectl exec nono-test -- ls -la /nono/nono
# Expected: -rwxr-xr-x 1 root root ... /nono/nono

# Check plugin decision logs for this pod
kubectl logs -n kube-system -l app.kubernetes.io/name=kubefence | grep nono-test
# Expected: {"msg":"injected","decision":"inject","pod":"nono-test","profile":"default",...}

# Cleanup
kubectl delete pod nono-test
```

!!! tip
    For Kata pods, `kubectl exec` is blocked by the kata-agent OPA policy.
    The verification commands above will fail with a permission error — this
    is the expected, correct behavior for Kata-sandboxed pods.
