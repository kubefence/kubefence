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

Verified against nono v0.71.0, in-cluster:

| Profile | Notes |
|---------|-------|
| `default` | Base system profile. Safe default for most workloads. Works as shipped, both RuntimeClasses |
| `claude` (from the `nolabs-ai/claude` pack) | Works on `kata-nono-sandbox` when the pack is baked into the **workload image** and the working directory is granted via `NONO_ALLOW` — see [Agent workloads](#agent-workloads-claude-code) |

Other profiles fail as shipped, but both failure modes have verified fixes:

| Profile | What happens | Fix |
|---------|--------------|-----|
| `claude-code`, `codex`, `opencode` | `install required but no TTY available` — container exits 1 | These are installable *packs*, not built-ins. Bake the pack into the **workload image** (see below). The plugin image is not involved: nono resolves profiles inside the container filesystem, at `$XDG_CONFIG_HOME/nono/` |
| `swival`, `python-dev`, and other profiles wanting the working directory | `CWD access requires --allow-cwd in non-interactive mode` — container exits 1 | Grant the working directory explicitly via the `NONO_ALLOW` env var — nono skips the CWD gate when the cwd is already covered by a grant |

!!! warning
    Setting an unfixed profile makes the **container fail to start** — the
    profile name is valid, so the plugin injects it, and nono then exits before
    the workload runs. Verify a profile in a scratch pod before rolling it out,
    and re-verify after a nono bump: profile availability varies by version.

### Extra grants: `NONO_ALLOW`

kubefence injects a fixed `wrap --profile <name> --` argument vector, so a pod
cannot pass nono flags. It can pass environment variables, and nono reads
`NONO_ALLOW` — the env form of `--allow`: a comma-separated list of directories
granted read+write (comma, not colon):

```yaml
env:
  - {name: NONO_ALLOW, value: "/workspace/proj,/data"}
```

Two constraints, both enforced by nono at startup:

- A grant must not overlap nono's state root under `$HOME`
  (`Refusing to grant ... overlaps protected nono state root`) — grant a
  subdirectory of `$HOME`, never `$HOME` itself.
- `NONO_ALLOW` lets the pod *spec* widen the sandbox to any container path.
  That is consistent with the threat model — the pod author is trusted, the
  workload code is not — but it is worth knowing when reviewing manifests.

### Agent workloads (Claude Code)

A full authenticated Claude Code session works inside the sandbox on both
RuntimeClasses with no kubefence changes. The recipe (verified with Claude Code
2.1.223, nono v0.71.0):

```yaml
spec:
  runtimeClassName: kata-nono-sandbox
  containers:
    - name: claude
      image: my-claude-image        # glibc-based, e.g. node:22-bookworm + claude
      workingDir: /workspace/proj
      env:
        - {name: HOME, value: /workspace}
        - {name: NONO_ALLOW, value: "/workspace/proj"}
        - {name: CLAUDE_CONFIG_DIR, value: /workspace/proj/.cfg}
      command: ["/bin/bash", "-c"]
      args:
        - |
          mkdir -p .cfg
          cp creds/.credentials.json .cfg/.credentials.json
          echo '{"hasCompletedOnboarding": true}' > .cfg/.claude.json
          exec claude -p "your prompt"
      volumeMounts:
        - {name: ws, mountPath: /workspace}
        - {name: creds, mountPath: /workspace/proj/creds, readOnly: true}
```

The non-obvious parts, each of which fails silently or confusingly when missed:

- **End the startup script with `exec claude`.** The `default` profile grants
  `/proc/self` resolved to the PID of the wrap target at setup. `exec`
  preserves that PID; a forked child (any multi-command shell line) gets an
  ungranted `/proc/self`, and Claude Code 2.x (Bun-based) then aborts with
  exit 134 and **no output at all**.
- **Use absolute `/bin/bash`** — a bare `bash` resolves to the `/nono/bash`
  PATH wrapper, and re-entering nono from inside the sandbox is denied.
- **`HOME` must not be a granted directory** (state-root overlap above), hence
  `HOME=/workspace` with grants on `/workspace/proj`.
- Outbound network needs nothing: `api.anthropic.com` is on the default
  profile's domain allowlist.
- For an interactive session set `stdin: true, tty: true` and use
  `kubectl attach -it` — `kubectl exec` is denied by the hardened Kata policy
  by design, but attach only streams to the pod's own PID 1
  (`ReadStream`/`WriteStream`), which the policy allows.

To use the `nolabs-ai/claude` pack profile instead of `default`, bake it into
the workload image and select it with `nono.sh/profile: "claude"`:

```dockerfile
FROM node:22-bookworm
RUN npm install -g @anthropic-ai/claude-code
COPY nono /tmp/nono
RUN mkdir -p /opt/nono-config \
 && XDG_CONFIG_HOME=/opt/nono-config /tmp/nono pull nolabs-ai/claude \
 && rm /tmp/nono
ENV XDG_CONFIG_HOME=/opt/nono-config
```

`XDG_CONFIG_HOME` must point outside `$HOME` (a runtime volume mounted over
`$HOME` would shadow the pack) and the directory must exist before `nono pull`
runs — nono silently falls back to `$HOME/.config` if it does not. One gotcha:
single-file grants in a profile (e.g. the pack's `$HOME/.claude.json`) only take
effect if the file exists when the sandbox is applied — pre-create such files in
the image or an init step.

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
