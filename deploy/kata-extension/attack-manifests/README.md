# /nono/nono Replacement Attack Manifests

These manifests demonstrate Kubernetes-level attack vectors that attempt to
replace or shadow the `/nono/nono` sandbox binary inside a Kata VM.  They
were run through `genpolicy` to produce the OCI mount structures visible to
the kata-agent, and the resulting `input.OCI.Mounts` patterns informed the
hardened rules in `../policy.rego`.

The genpolicy output is kept in `genpolicy-output/` and is executable, not just
recorded: `make policy-test` replays `../policy.rego` over every container in
every dump and requires each `attack-*` pod to have at least one container
denied and every `legitimate-*` container allowed. Adding a new dump to that
directory is enough to cover it — the expectation comes from the filename.

Note that `RESULTS.md` predates the current rule. It records
`attack-hostpath-nono-dir.yaml` reaching `Running`, because the policy then
counted `/nono` mounts and containerd had merged the two into one. The rule now
keys on `rbind`, which marks the mount as user-supplied, so genpolicy-verify
shows that pod denied outright.

## Attack Manifests

| Manifest | Attack vector | /nono mount options |
|---|---|---|
| `attack-hostpath-nono-dir.yaml` | hostPath at `/nono` (directory) | `["rbind","rprivate","rw"]` |
| `attack-hostpath-nono-binary.yaml` | hostPath at `/nono/nono` (file) | `["rbind","rprivate","rw"]` |
| `attack-emptydir-initcontainer.yaml` | emptyDir + initContainer copies evil binary | `["rbind","rprivate","rw"]` |
| `attack-configmap-binary.yaml` | ConfigMap dir at `/nono` (key `nono` → `/nono/nono`) | `["rbind","rprivate","ro"]` |
| `attack-projected-secret.yaml` | Secret dir at `/nono` (key `nono` → `/nono/nono`) | `["rbind","rprivate","ro"]` |
| `attack-symlink-via-copy.yaml` | kubectl cp to `/nono/nono` (CopyFileRequest) | n/a — policy blocks by path |

### Key observation

ConfigMap and Secret mounts are **read-only** yet still replace `/nono/nono`
with attacker content.  Blocking only writable (`rw`) mounts is insufficient;
all mounts with `destination` starting with `/nono` must be denied.

### Kata limitation noted

`subPath` volume mounts are unsupported by Kata Containers — `genpolicy`
panics with `kata-containers/runtime#2812`.  The ConfigMap/Secret attacks
therefore mount the entire `/nono` directory (not the file via subPath).

## Two-layer defence model

Attack neutralisation depends on which OCI destination the attack targets:

**Layer 1 — NRI mount replacement** (attacks with destination `/nono`):
`BuildAdjustment` always injects a read-only `/nono` bind-mount, for every
handler.  When the user spec declares a volume at the same destination
(`/nono`), containerd merges OCI mounts by destination and the NRI mount wins.
The kata-agent therefore sees only **one** `/nono` entry; the policy count rule
allows the container and the trusted nono binary is used.  Attacks neutralised:
hostPath dir, emptyDir, ConfigMap dir, Secret dir at `/nono`.

**Layer 2 — kata-agent OPA policy** (attacks with destination `/nono/nono`):
A hostPath file mount at `/nono/nono` has a *different* OCI destination from the
NRI `/nono` dir mount, so both entries survive the merge.  The count reaches 2
and the policy denies with `"CreateContainerRequest is blocked by policy"`.
Attack caught: hostPath file at `/nono/nono`.

```
CopyFileRequest:        blocked when input.path is "/nono" or starts with "/nono/"
CreateContainerRequest: blocked when more than one OCI mount destination is
                        "/nono" or starts with "/nono/" (count > 1)
ExecProcessRequest:     blocked unless command is /nono/nono wrap --profile … --
```

## Reproducing genpolicy analysis

```bash
KATA=4.0.0
curl -fsSL -o kata-tools.tar.zst \
  https://github.com/kata-containers/kata-containers/releases/download/${KATA}/kata-tools-static-${KATA}-amd64.tar.zst
tar --use-compress-program=unzstd -xf kata-tools.tar.zst

GENPOLICY=./opt/kata/bin/genpolicy
SETTINGS=./opt/kata/share/defaults/kata-containers/genpolicy-settings.json
RULES=./opt/kata/share/defaults/kata-containers/rules.rego

$GENPOLICY -y attack-hostpath-nono-dir.yaml \
  -j $SETTINGS -p $RULES --raw-out --silent-unsupported-fields
```
