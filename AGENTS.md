# Agent Reference — nono-nri

Authoritative technical reference for AI agents working on this codebase.
Read this before reading any source file. See CLAUDE.md for commit conventions.

---

## What this project is

`nono-nri` is a Kubernetes NRI (Node Resource Interface) plugin that intercepts
container creation and wraps the container process with the `nono` Landlock
sandbox binary. Opt-in is via RuntimeClass: only pods whose RuntimeClass handler
matches the configured list are wrapped; all others are skipped with zero overhead.

The `nono` binary (fetched from the upstream release by `scripts/fetch-nono.sh`, glibc 2.34+)
is copied from the container image to the host by a DaemonSet init container,
then bind-mounted read-only into each sandboxed container at `/nono/nono`.

---

## File map

```
cmd/nono-nri/main.go              entrypoint: flags (-log-level, -json, -config), kernel check, config, stub.Run
internal/nri/plugin.go            Plugin struct; CreateContainer, StopContainer, RemoveContainer
internal/nri/filter.go            ShouldSandbox, SkipReason — pure, no I/O
internal/nri/profile.go           ResolveProfile — annotation → validated profile name
internal/nri/adjustments.go       BuildAdjustment — args wrapping + bind mount + seccomp policy
internal/nri/seccomp.go           BuildSeccompPolicy — RuntimeDefault and restricted allowlists
internal/nri/state.go             WriteMetadata, RemoveMetadata — /var/run/nono-nri/…
internal/nri/config.go            Config struct, LoadConfig (TOML)
internal/nri/kernel.go            CheckKernel — Linux 5.13+ required for Landlock
internal/nri/export_test.go       test-only helpers (SetStateBaseDir, SetKernelVersionFunc, …)
internal/log/log.go               slog JSON (prod) / text (dev) logger factory; accepts slog.Level

deploy/kind/deploy.sh             Kind cluster + plugin deploy automation
deploy/kind/e2e.sh                E2E test suite (17 checks)
deploy/kind/cluster-containerd.yaml   Kind cluster config with NRI enabled
deploy/kata-extension/policy.rego     Hardened kata-agent OPA policy — guest-side enforcement
deploy/kata-extension/agent-config.toml   Agent config selecting that policy (agent.config_file)
deploy/kata-extension/Dockerfile  erofs extension image carrying both; published, not kind-only
deploy/daemonset.yaml             DaemonSet manifest (init + main containers)
deploy/runtimeclass-kata.yaml     kata-nono-sandbox RuntimeClass (handler: kata-qemu-runtime-rs)
deploy/10-nono-nri.toml.example   Annotated TOML config reference
Dockerfile                        Multi-stage: golang:1.24-alpine builder → alpine:3.20
.github/workflows/release.yaml    CI: fetches the pinned nono release, builds + pushes to ghcr.io
.github/workflows/kata-extension.yaml   CI: builds + pushes the guest extension image
scripts/fetch-nono.sh             downloads the nolabs-ai/nono release binary at NONO_VERSION and
                                  verifies it against a pinned SHA256; glibc 2.34+, no musl build
                                  exists upstream
```

---

## Data flow: CreateContainer

```
NRI event
  └─ Plugin.CreateContainer(ctx, pod, ctr)
       ├─ ShouldSandbox(pod, cfg)          check pod.RuntimeHandler ∈ cfg.RuntimeClasses
       │    false → Log "skip" + return nil, nil, nil   (no adjustment, no state)
       │    true  ↓
       ├─ ResolveProfile(pod, cfg)         pod annotation "nono.sh/profile" or cfg.DefaultProfile
       ├─ BuildSeccompPolicy(cfg.SeccompProfile) → *LinuxSeccomp (nil when disabled)
       ├─ BuildAdjustment(ctr, profile, cfg.NonoBinPath, seccomp)
       │    SetArgs: [/nono/nono, wrap, --profile, <profile>, --, <original args...>]
       │    AddMount: host dir of NonoBinPath → /nono  (bind, ro, rprivate)
       │    SetLinuxSeccompPolicy: applied when seccomp != nil
       │    NOTE: the bind-mount is unconditional — for Kata it is served
       │    over virtiofs, so one code path covers both runtimes
       ├─ WriteMetadata(pod.UID, ctr.ID, …)
       │    creates /var/run/nono-nri/<podUID>/<ctrID>/metadata.json
       └─ Log "injected" + return adjustment
```

## Data flow: state cleanup

```
Container stops (kubelet → containerd CRI StopContainer)
  └─ Plugin.StopContainer(ctx, pod, ctr)       ← RELIABLE (direct gRPC RPC)
       └─ RemoveMetadata(pod.UID, ctr.ID)
            os.RemoveAll /var/run/nono-nri/<podUID>/<ctrID>/
            os.Remove    /var/run/nono-nri/<podUID>/        (if now empty)

Container removed (containerd NRI StateChange REMOVE_CONTAINER)
  └─ Plugin.RemoveContainer(ctx, pod, ctr)     ← belt-and-suspenders only
       └─ RemoveMetadata(pod.UID, ctr.ID)
```

---

## Critical NRI event delivery constraint

In containerd 2.x, **StateChange notifications are not delivered to external
(socket-connected) NRI plugins**. This affects:

| Event | Delivery mechanism | External plugin receives it? |
|---|---|---|
| `CreateContainer` | direct gRPC RPC | yes |
| `StopContainer` | direct gRPC RPC | yes |
| `RemoveContainer` | StateChange notification | **NO** |
| `RemovePodSandbox` | StateChange notification | **NO** |
| `StopPodSandbox` | StateChange notification | **NO** |

**Consequence:** `StopContainer` is the primary cleanup hook. `RemoveContainer`
is kept as a fallback for runtimes that do deliver StateChange events, but must
never be the only cleanup path.

When adding new lifecycle hooks, check whether the event is a direct RPC or a
StateChange. Only direct RPCs are reliable for external plugins.

---

## Key invariants

- **Opt-in only.** `ShouldSandbox` matches `pod.GetRuntimeHandler()` (the
  RuntimeClass handler field) against `cfg.RuntimeClasses`. Namespace denylists
  or any other automatic opt-in must not be added.
- **Pause containers are never injected.** NRI separates PodSandbox events
  (pause container) from Container events. The plugin only handles Container
  events; pause containers receive no adjustment.
- **Args shape is fixed.**
  `[/nono/nono, wrap, --profile, <profile>, --, <original args...>]`
  Changing this breaks the nono binary's CLI contract.
- **Mount point is `/nono`, binary is `/nono/nono`.** `containerNonoDirPath`
  and `ContainerNonoPath` in adjustments.go must stay in sync with the nono
  binary's expected location.
- **State dir layout: `/var/run/nono-nri/<podUID>/<containerID>/metadata.json`.**
  Both podUID and containerID are validated by `validPathComponent` before use
  as path segments (must be non-empty, not `.` or `..`, no `/` or `\`).
- **Profile annotation is validated.** `nono.sh/profile` must match
  `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`. Invalid values fall back to
  `cfg.DefaultProfile` silently.
- **`go.mod` replace directive must not be removed.**
  `replace github.com/opencontainers/runtime-spec => github.com/opencontainers/runtime-spec v1.1.0`
  is required for NRI SDK compatibility.
- **Kernel check runs first.** `CheckKernel()` is the very first call in
  `run()`. Do not move it after config load or logger init.
- **Plugin scope: nono wrapping + seccomp hardening.** The plugin injects
  the nono sandbox process wrapper and, when `seccomp_profile` is set, a
  seccomp policy via `SetLinuxSeccompPolicy`. These are both part of the
  nono sandboxing mechanism. The plugin must not enforce UID/GID constraints,
  `runAsNonRoot`, capability drops, or other pod security context properties —
  those belong at the admission layer (mutating webhook or Pod Security Standards).
  The plugin wraps the process regardless of which user the container runs as.
- **seccomp_profile and kata-agent.** For Kata handlers, the seccomp policy
  is applied inside the guest VM by the kata-agent, which reads the OCI spec
  seccomp field written by NRI. This requires `disable_guest_seccomp = false`
  in the kata QEMU config — set automatically by the kata-setup DaemonSet.

---

## Config

TOML file at `/etc/nri/conf.d/10-nono-nri.toml`:

```toml
runtime_classes  = ["nono-runc"]        # list of RuntimeClass handler names
default_profile  = "default"            # used when pod lacks nono.sh/profile annotation
nono_bin_path    = "/opt/nono-nri/nono" # absolute host path; must exist at startup
socket_path      = ""                   # empty → NRI default /var/run/nri/nri.sock
seccomp_profile  = "restricted"         # "restricted" | "runtime-default" | ""
```

`runtime_classes` and `nono_bin_path` are required; startup fails without them.
`seccomp_profile` is optional; empty string disables NRI seccomp injection.
Unknown TOML keys cause a parse error (`DisallowUnknownFields` is set).

---

## nono profile compatibility

nono-nri injects `nono wrap --profile <name> --` via `SetArgs`. This means only
profiles that are compatible with `nono wrap` will work. What that excludes has
changed with nono versions; see the tables below.

**Verified working** (tested against `nono-runc` and `kata-nono-sandbox`, nono v0.71.0):

| Profile | Notes |
|---|---|
| `default` | Base system profile; suitable as `default_profile`. The only profile that works as shipped |

**Broken as shipped** — the profile name is valid, so the plugin injects it and
nono then exits before the workload runs, i.e. the container fails to start:

| Profile | Failure | Cause |
|---|---|---|
| `claude-code`, `codex`, `opencode` | `install required but no TTY available` (exit 1) | nono v0.71 moved these into installable packs (`nono pull nolabs-ai/<name>`). Not in the binary. **Fix (verified in-cluster):** bake the pack into the *workload* image — `mkdir -p /opt/nono-config && XDG_CONFIG_HOME=/opt/nono-config nono pull ...` at build, `ENV XDG_CONFIG_HOME=/opt/nono-config`. The plugin image is irrelevant: nono resolves profiles inside the container rootfs. XDG dir must exist and sit outside `$HOME` (volumes shadow `$HOME`); nono silently falls back to `$HOME/.config` otherwise |
| `swival`, `python-dev`, other CWD-wanting profiles | `CWD access requires --allow-cwd in non-interactive mode` (exit 1) | nono no longer grants CWD implicitly without a TTY; the plugin injects no `--allow-cwd`. **Fix (verified):** grant the cwd via pod env `NONO_ALLOW=<cwd>` (comma-separated `--allow` dirs) — nono skips the CWD gate when the cwd is already covered by an explicit grant |

Proxy-mode profiles are no longer rejected outright by `wrap` — `python-dev` gets
as far as `net proxy` + `Applying sandbox` — so the old "requires `nono run`"
constraint is gone; the CWD gate is what stops them now.

Verified invariants for agent workloads (nono v0.71.0, Claude Code 2.1.223,
both RuntimeClasses — see docs/usage.md "Agent workloads" for the pod recipe):

- The `default` profile's `/proc/self` grant is **PID-scoped**: resolved to the
  wrap target's PID at setup. `exec` preserves it; a forked child gets an
  ungranted `/proc/self`. Bun-based CLIs (Claude Code 2.x reads
  `/proc/self/maps`) then SIGABRT with exit 134 and empty stderr — only
  strace shows why. Container commands must end with `exec <agent>`.
  Beware: `bash -c "cmd"` exec-without-fork masks this; `bash -c "cmd && echo"`
  forks and dies.
- nono refuses any grant overlapping its state root under `$HOME` — `$HOME`
  must not itself be a granted dir; grant a sibling/subdir instead.
- `NONO_ALLOW` is comma-separated; colon silently fails to parse.
- Pod commands must use absolute `/bin/bash` — bare `bash` hits the
  `/nono/bash` PATH wrapper and sandbox re-entry is denied.
- `kubectl attach` works on Kata pods where `kubectl exec` is policy-denied:
  attach is `ReadStream`/`WriteStream`/`TtyWinResize` on the pod's own PID 1
  (all allowed); exec is `ExecProcessRequest` (denied).

Profile availability and behaviour vary by nono version — v0.23.0 shipped these
profiles in the binary, v0.71.0 does not. Re-run profile verification after
upgrading the nono binary.

---

## Build and test

```bash
# compile
go build ./...

# unit + integration tests
go test ./internal/... -count=1

# format check
gofmt -l .

# vet
go vet ./...

# fetch the pinned upstream nono release binary
make nono-fetch

# docker image (requires ./nono binary in repo root)
make docker-build IMAGE=nono-nri:latest

# local Kind e2e — full cycle (deploy + test + teardown)
make kind-e2e

# external image quick-start (no source build)
IMAGE=ghcr.io/kubefence/nono-nri-plugin:latest SKIP_BUILD=true KATA=false \
  bash deploy/kind/deploy.sh
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash deploy/kind/e2e.sh
```

---

## Testing patterns

Tests live in `internal/nri/` alongside the code. Framework: Ginkgo v2 + Gomega.

**State dir isolation** — every test that exercises state must redirect the
base dir to a temp directory and restore it:

```go
BeforeEach(func() {
    tmpDir, _ = os.MkdirTemp("", "nono-state-*")
    nri.SetStateBaseDir(tmpDir)
})
AfterEach(func() {
    nri.ResetStateBaseDir()
    os.RemoveAll(tmpDir)
})
```

**Log capture** — use `newTestPlugin(buf)` for the standard test config, or
`newBufLogger(buf)` with a custom `nri.NewPlugin` call. Both are defined in
`helpers_test.go`. Parse slog JSON output into `logEntry`:

```go
buf := &bytes.Buffer{}
p := newTestPlugin(buf)   // standard config: nono-runc, default profile, /host/nono
// ... call plugin method ...
var entry logEntry   // fields: Msg, Decision, ContainerID, Namespace, Pod,
                     //         Profile, RuntimeHandler, Reason, Time, Level
json.Unmarshal(buf.Bytes(), &entry)
```

**Kernel version injection** — override and restore for tests that need a
specific kernel version without being on that kernel:

```go
nri.SetKernelVersionFunc(func() (int, int) { return 4, 18 })
defer nri.ResetKernelVersionFunc()
```

`SetKernelVersionFunc`, `ResetKernelVersionFunc`, `SetStateBaseDir`, and
`ResetStateBaseDir` are defined in `export_test.go` (package `nri`, compiled
only during `go test`) — they are invisible to non-test callers.

**`kernel.go` has `//go:build linux`** — kernel tests only run on Linux.
Add the same build tag to any new file that calls `syscall.Uname`.

---

## E2E test structure

`deploy/kind/e2e.sh` runs 17 checks in 5 tests (20 with `KATA=true`):

| Test | Checks |
|------|--------|
| 1. Plugin connectivity | DaemonSet pod Running; plugin connected to runtime |
| 2. Sandboxed pod injection | `/proc/1/cmdline` shows sleep (nono exec'd); `/nono/nono` accessible; OCI bundle args + mount; `metadata.json` written with `profile=default` |
| 3. Non-sandboxed isolation | plain pod cmdline unmodified; no `/nono` mount; plugin logged "skip" |
| 4. State dir cleanup | after pod deletion, poll ≤30 s for state dir removal; on failure dumps remaining paths + plugin stop/remove log lines |
| 5. Kata + nono | skipped when `KATA=false`; validates nono inside QEMU VM via virtiofs |

Test 4 relies on `StopContainer` firing (reliable). If it still fails, the
diagnostic section will show either "remaining metadata.json files" (cleanup
didn't happen) or no matching stop/remove log lines (event not delivered).

---

## DaemonSet architecture

```
Pod: nono-nri (kube-system)
  automountServiceAccountToken: false
  initContainer: install-nono
    image: nono-nri:latest
    command: cp /usr/local/bin/nono /opt/nono-nri/nono
    securityContext: allowPrivilegeEscalation=false, readOnlyRootFilesystem=true, drop ALL caps
    mount: hostPath /opt/nono-nri → /opt/nono-nri
  container: nono-nri
    image: nono-nri:latest
    command: /usr/local/bin/10-nono-nri --config /etc/nri/conf.d/10-nono-nri.toml
    securityContext: allowPrivilegeEscalation=false, readOnlyRootFilesystem=true, drop ALL caps
    mounts:
      hostPath /var/run/nri    → /var/run/nri    (NRI socket, readOnly)
      hostPath /opt/nono-nri   → /opt/nono-nri   (nono binary, readOnly)
      hostPath /etc/nri/conf.d → /etc/nri/conf.d (TOML config, readOnly)
      emptyDir                 → /var/run/nono-nri (state dir, writable)
    tolerations: all nodes
```

The NRI socket mount is read-only because the plugin connects *to* containerd
(client), not the other way around. The state dir (`/var/run/nono-nri`) is an
`emptyDir` volume — ephemeral to the pod lifetime, not persisted on the host.

---

## Kata Containers specifics

- RuntimeClass `kata-nono-sandbox` → handler `kata-qemu-runtime-rs` → nono injected via
  virtiofs bind-mount (same bind-mount mechanism, virtiofsd makes host path
  visible inside the QEMU VM).
- The `kata-nono-qemu` handler adds the hardened kata-agent OPA policy on top,
  delivered as a composable-VM-images extension (`deploy/kata-extension/`):
  an unmeasured erofs image declared via `[[hypervisor.qemu.guest_extension_images]]`
  with `verity_params = ""`, cold-plugged as read-only virtio-blk and mounted by
  the guest at `/run/kata-extensions/nono` before `kata-agent.service` starts.
  `kernel_params` carries
  `agent.config_file=/run/kata-extensions/nono/agent-config.toml`, whose
  `policy_file` selects the policy. Two constraints are easy to trip over:
  `verity_params` must be present even when empty (the runtime emits it as the
  guest-side activation signal for the mount unit), and `agent.config_file`
  short-circuits the rest of the kernel command line, so every other agent
  setting must go inside `agent-config.toml`.
- The guest image itself is never modified.
- Kata with nested KVM in kind requires:
  - `/dev/shm` remounted to ≥16 GB (NUMA memory backend)
  - `machine_accelerators = "kernel_irqchip=split"` in QEMU config
  - Stock kata guest kernel and initrd — kata >= 4.0 builds every guest kernel
    with `CONFIG_SECURITY_LANDLOCK=y` via
    `tools/packaging/kernel/configs/fragments/common/landlock.conf`, which
    `build-kernel.sh` applies to all builds. Nothing in this repo builds,
    pulls or patches a guest kernel.

---

## Published image

`ghcr.io/kubefence/nono-nri-plugin` is built by `.github/workflows/release.yaml`:
- Fetches the `nolabs-ai/nono` release binary at `NONO_VERSION` (glibc 2.34+, no
  libdbus/libsystemd) via `scripts/fetch-nono.sh`
- Compiles `10-nono-nri` from repo source with `CGO_ENABLED=0`
- Platform: `linux/amd64` only
- Logging from NRI SDK internals appears in logrus format
  (`time="..." level=info msg="..."`) — this is the SDK's own logger, not the
  plugin's slog output

To use the published image without a local build:

```bash
IMAGE=ghcr.io/kubefence/nono-nri-plugin:latest SKIP_BUILD=true KATA=false \
  bash deploy/kind/deploy.sh
```
