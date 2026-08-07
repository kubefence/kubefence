# /nono/nono Replacement Attack — Live Cluster Test Results

Two runs, newest first, both driving the six manifests in this directory against
a live cluster. Every defence layer reproduced across a three-minor k8s jump and
48 nono releases; the pod *phases* differ, for a reason worth reading (run 2,
"Why the phases changed").

For the static counterpart — the same policy replayed over recorded genpolicy
output, with no cluster — see `genpolicy-output/` and `make policy-test`. The two
answer different questions; see "Static vs live" below.

---

# Run 2 — 2026-08-07

**Cluster:** `kubefence` kcli VM, kubeadm single-node, k8s v1.33.13,
containerd 2.2.6, Ubuntu 24.04.4, kernel 6.8.0-136-generic
**Runtime class:** `kata-nono-sandbox` → handler `kata-nono-qemu`
**Policy:** hardened `policy.rego`, delivered as the erofs guest extension image
(cold-plugged read-only virtio-blk), stock kata guest kernel and image
**kata-deploy:** 4.0.0
**nono-nri:** built from `d16b991`
**nono binary:** v0.71.0
**seccomp_profile:** `restricted`

The deployed build is `d16b991`, five commits behind the HEAD this was written
against, but the tested surface is identical: `policy.rego`, `agent-config.toml`
and the extension `Dockerfile` are byte-for-byte the same, and `internal/nri/`
(where `BuildAdjustment` builds the mount) is untouched. The only intervening Go
change is an unindent in `main.go`.

## Preflight — is the hardened policy actually live?

Kata's default is `allow-all.rego`, under which every attack below would pass for
the wrong reason. The discriminator is that the project's policy denies a bare
exec but allows a wrapped one — `allow-all` permits both, and
`allow-all-except-exec-process` denies both:

```console
$ kubectl exec policy-control -- true
... rpc status: Status { code: PERMISSION_DENIED,
    message: "\"ExecProcessRequest is blocked by policy: \"" }

$ kubectl exec policy-control -- /nono/nono wrap --profile default -- ls -l /nono/nono
-rwxr-xr-x 1 0 0 29848160 Aug  6 16:27 /nono/nono
```

29848160 bytes is the v0.71.0 release binary exactly, so the mount is the trusted
one. Only then are the attack results meaningful.

## Results

| Manifest | Pod status | Exit | Defence layer | Mechanism |
|---|---|---|---|---|
| `attack-hostpath-nono-dir.yaml` | `Failed` ✓ | 1 | Layer 1 | NRI mount replacement |
| `attack-hostpath-nono-binary.yaml` | `Failed`/`StartError` ✓ | 128 | Layer 2 | kata-agent OPA policy |
| `attack-emptydir-initcontainer.yaml` | `Failed`/`PodInitializing` ✓ | init 1 | Layer 0 | Landlock blocks staging write |
| `attack-configmap-binary.yaml` | `Failed` ✓ | 1 | Layer 1 | NRI mount replacement |
| `attack-projected-secret.yaml` | `Failed` ✓ | 1 | Layer 1 | NRI mount replacement |
| `attack-symlink-via-copy.yaml` | `Running` | — | N/A | `CopyFileRequest` not reachable via `kubectl` |

All six neutralised, at the same layers as run 1.

Only `attack-hostpath-nono-binary` was stopped by the policy, and the kata-agent
said so on the pod's events:

```
Error: failed to create containerd task: failed to create shim task:
Others("failed to handle message create container
 Caused by:
   0: agent create container
   1: rpc status: Status { code: PERMISSION_DENIED, ...
```

## Why the phases changed since run 1

Run 1 recorded the three Layer 1 attacks as `Running`; they are now `Failed`
with exit 1. The defence did not change — the attacker's own command does.

Each Layer 1 pod runs `sh -c '... /nono/nono --version ...'`. After injection PID 1
is `nono wrap`, which succeeds ("Applying sandbox..."), but the inner `sh` now
resolves through the `/nono` PATH entry to the `/nono/sh` wrapper, and re-entering
nono from inside an active sandbox is denied:

```
  nono v0.71.0
  Applying sandbox...
nono: Command execution failed: Permission denied (os error 13)
```

Those wrapper scripts postdate run 1's nono v0.23.0. The load-bearing evidence is
unchanged and visible in the same log: the attacker sees `nono v0.71.0`, the
trusted binary, not the payload it mounted. A `Failed` phase here is the PATH
wrapper doing its job, not an attack getting further than before.

## Static vs live — they disagree, and both are right

`make policy-test` replays `policy.rego` over the recorded genpolicy dumps and
reports `attack-hostpath-nono-dir` **denied**. Live, the policy allowed that pod
and Layer 1 handled it. Not a contradiction:

- genpolicy's dump is the **pre-NRI** OCI spec, so it still contains the
  attacker's `rbind` mount at `/nono` → the rule fires.
- At runtime NRI appends its own `/nono` mount. Same destination, so containerd
  merges the two and keeps NRI's, which uses `bind`, not `rbind`. No `rbind`
  mount ever reaches the agent, so the policy allows a container whose `/nono` is
  already trusted.
- `attack-hostpath-nono-binary` targets `/nono/nono`, a *different* destination.
  No merge, both mounts reach the agent, policy denies. Static and live agree.

So the static check exercises the **NRI-absent or NRI-bypassed** path — exactly
what `policy.rego`'s `rbind` rule was written for ("if the NRI plugin is
misconfigured or absent, no `/nono` bind-mount is injected at all"). The live run
exercises the NRI-present path. Neither subsumes the other; a regression that
removed the `rbind` rule would stay green live and go red static.

## Not verified in this run

The Landlock ABI version. `nono wrap -- true` prints no Landlock line at default
verbosity. The `Permission denied (os error 13)` above is behavioural evidence
that Landlock is enforcing, but the version was not read.

---

# Run 1 — 2026-05-05

**Cluster:** `ai-pg` (k8s v1.31.14, single-node)
**Runtime class:** `kata-nono-sandbox` → handler `kata-nono-qemu`
**Policy:** hardened `policy.rego` (now `deploy/kata-extension/policy.rego`),
at the time injected into the guest rootfs image via the since-removed `inject.sh`.
The policy text is unchanged; only its delivery mechanism has since moved to the
nono guest extension image.
**nono-nri version:** `ghcr.io/kubefence/nono-nri-plugin:latest` (v0.6.0)
**nono binary:** v0.23.0

---

## Setup note

All attack manifests use `ubuntu:24.04` as the container image (already pulled
in the cluster).

Three of the manifests (`attack-hostpath-nono-dir.yaml`,
`attack-hostpath-nono-binary.yaml`, `attack-emptydir-initcontainer.yaml`) were
modified by `genpolicy` to include an
`io.katacontainers.config.hypervisor.cc_init_data` annotation containing a
pod-level OPA policy that would override the image-embedded hardened policy.
Strip that annotation before applying so the tests exercise the image-embedded
policy:

```bash
apply_clean() {
  grep -v "cc_init_data" "$1" | kubectl apply -f -
}
```

---

## Results

| Manifest | Pod status | Defence layer | Mechanism |
|---|---|---|---|
| `attack-hostpath-nono-dir.yaml` | `Running` ✓ | Layer 1 | NRI mount replacement |
| `attack-hostpath-nono-binary.yaml` | Blocked ✓ | Layer 2 | kata-agent OPA policy |
| `attack-emptydir-initcontainer.yaml` | `Init:Error` ✓ | Layer 0 | Landlock blocks staging write |
| `attack-configmap-binary.yaml` | `Running` ✓ | Layer 1 | NRI mount replacement |
| `attack-projected-secret.yaml` | `Running` ✓ | Layer 1 | NRI mount replacement |
| `attack-symlink-via-copy.yaml` | N/A | Layer 2 | `CopyFileRequest` policy (not exercisable via `kubectl`) |

All attacks were neutralised. The `Running` results for Layer 1 are expected and
correct — the pods start, but `/nono/nono` inside the kata VM is the trusted NRI
binary, not the attacker's payload.

---

## Per-attack analysis

### 1. `attack-hostpath-nono-dir.yaml` — hostPath directory at `/nono`

**Attack intent:** Mount an attacker-controlled directory over `/nono`, replacing
the entire directory including the `nono` binary and wrapper scripts.

**What happened:** Pod reached `Running`.

**Why it was neutralised (Layer 1 — NRI mount replacement):**
The NRI plugin (`BuildAdjustment`) always appends a read-only bind-mount at `/nono`
from the trusted host directory (`/opt/nono-nri`). Both the user-specified hostPath
and the NRI mount have the same OCI destination (`/nono`). containerd merges
same-destination OCI mounts by keeping the last one applied; since the NRI mount
is appended after the user spec, the NRI mount wins. The kata-agent therefore sees
only **one** `/nono` mount in the container spec, and that mount points to the
trusted binary. The attacker's `/tmp/evil-nono` directory is never visible inside
the kata VM.

---

### 2. `attack-hostpath-nono-binary.yaml` — hostPath file at `/nono/nono`

**Attack intent:** Mount a single malicious file directly at `/nono/nono`,
replacing only the binary while leaving the rest of the `/nono` directory intact.

**What happened:** Pod never reached `Running`. Event:

```
Error: failed to create containerd task: failed to create shim task:
"CreateContainerRequest is blocked by policy: "
```

**Why it was blocked (Layer 2 — kata-agent OPA policy):**
This attack targets `/nono/nono` (the binary file), which is a **different** OCI
destination from the NRI `/nono` directory mount. containerd's same-destination
merge does not apply, so both mounts survive: the user's `/nono/nono` file mount
and the NRI `/nono` dir mount. The kata-agent receives an OCI spec with two
entries whose destination begins with `/nono` (count == 2). The hardened policy
rule denies this:

```rego
default CreateContainerRequest := false

CreateContainerRequest if {
    not container_has_extra_nono_mounts
}

container_has_extra_nono_mounts if {
    nono_mounts := [m | some m in input.OCI.Mounts; nono_prefix_destination(m.destination)]
    count(nono_mounts) > 1
}
```

The kata-agent emits `CreateContainerRequest is blocked by policy` and the
container is never created.

> **Superseded.** That `count > 1` rule is not the current one — `policy.rego`
> now keys on `rbind` in the mount options, which marks a mount as user-supplied
> and so also catches the single-mount case where NRI is absent. The verdict for
> this attack is unchanged (run 2 reproduced the same Layer 2 denial); only the
> rule that produces it differs. The snippet is left as the historical record of
> what was tested on 2026-05-05.

---

### 3. `attack-emptydir-initcontainer.yaml` — emptyDir via initContainer

**Attack intent:** Use an initContainer to copy a malicious binary into an emptyDir
volume, then mount that emptyDir over `/nono` in the main container so the
attacker's binary is at `/nono/nono` when the main container starts.

**What happened:** Pod stuck at `Init:Error`. Init container exited with code 1
in under one second.

**Why it was neutralised (Layer 0 — Landlock):**
The initContainer's command after NRI injection becomes:

```
/nono/nono wrap --profile default -- sh -c \
  "cp /bin/sh /mnt/nono-dir/nono && chmod 755 /mnt/nono-dir/nono"
```

nono applies the Landlock sandbox **before** exec'ing into `sh`. The default
profile restricts write access to specific system paths; `/mnt/nono-dir/` is not
in the allow-list. The `cp` call receives `Permission denied` from the kernel and
exits with code 1 — the initContainer fails and the main container never starts.
The emptyDir remains empty; even if the main container had started, Layer 1 would
have applied (the NRI `/nono` mount would have overridden the emptyDir at `/nono`).

This result was not anticipated during design — it demonstrates that nono's Landlock
sandbox provides a deeper layer of protection than the two layers the policy rule
was designed for.

---

### 4. `attack-configmap-binary.yaml` — ConfigMap directory at `/nono`

**Attack intent:** Mount a ConfigMap (containing a fake `nono` shell script as the
key `nono`) as a directory at `/nono`. The key becomes `/nono/nono` inside the
container, a POSIX shell script that exec's its arguments directly, bypassing the
Landlock sandbox.

**What happened:** Pod reached `Running`.

**Why it was neutralised (Layer 1 — NRI mount replacement):**
Same mechanism as the hostPath directory attack. The ConfigMap volume is mounted at
`/nono` (same destination as the NRI mount). containerd's merge keeps the NRI
mount; the ConfigMap content is never visible inside the kata VM.

Note: `subPath` ConfigMap mounts (targeting `/nono/nono` directly) are unsupported
by Kata Containers — `genpolicy` panics on them — so the ConfigMap must be mounted
as a directory, which is handled by Layer 1.

---

### 5. `attack-projected-secret.yaml` — Secret directory at `/nono`

**Attack intent:** Same as the ConfigMap attack but using a Kubernetes Secret
containing a base64-encoded binary or script as the `nono` key.

**What happened:** Pod reached `Running`.

**Why it was neutralised (Layer 1 — NRI mount replacement):**
Identical mechanism to the ConfigMap case. Secret volumes mounted at `/nono` have
the same OCI destination as the NRI bind-mount and are overridden by Layer 1.
The Secret's `nono` key is never accessible at `/nono/nono` inside the kata VM.

---

### 6. `attack-symlink-via-copy.yaml` — kubectl cp / CopyFileRequest

**Attack intent:** Copy a symlink or malicious binary to `/nono/nono` inside the
running container using `kubectl cp` (or equivalently the kata-agent's
`CopyFileRequest` gRPC method).

**What happened:** Not exercised on the cluster. `kubectl cp` internally uses
`kubectl exec -- tar`, which goes through `ExecProcessRequest` (already denied by
policy for any non-nono-wrap command). The kata-agent `CopyFileRequest` gRPC
method is not exposed through standard `kubectl`; it would require `kata-ctl` or
a direct gRPC call.

**Why it would be blocked (Layer 2 — `CopyFileRequest` policy):**
The hardened policy denies `CopyFileRequest` for any path under `/nono`:

```rego
default CopyFileRequest := false

CopyFileRequest if {
    not copies_to_nono_path
}

copies_to_nono_path if { input.path == "/nono" }
copies_to_nono_path if { startswith(input.path, "/nono/") }
```

This is verified by the OPA unit test `test_copy_blocked_nono_binary` in
`policy_test.rego`.

---

## Defence-in-depth summary

```
Attack surface           Layer 0        Layer 1           Layer 2
                         Landlock       NRI replacement   kata-agent policy
─────────────────────────────────────────────────────────────────────────────
hostPath dir at /nono    —              ✓ NRI wins        —
hostPath file at /nono/nono —           —                 ✓ count>1 denied
emptyDir + initContainer ✓ write denied —                 —
ConfigMap dir at /nono   —              ✓ NRI wins        —
Secret dir at /nono      —              ✓ NRI wins        —
CopyFileRequest to /nono —              —                 ✓ path rule denied
kubectl exec (non-wrap)  —              —                 ✓ ExecProcess denied
```

No attack vector successfully replaced `/nono/nono` with attacker-controlled
content inside the kata VM.
