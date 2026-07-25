# /nono/nono Replacement Attack — Live Cluster Test Results

**Date:** 2026-05-05
**Cluster:** `ai-pg` (k8s v1.31.14, single-node)
**Runtime class:** `kata-nono-sandbox` → handler `kata-nono-qemu`
**Policy:** hardened `policy.rego` (now `deploy/kind/kata-extension/policy.rego`),
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
