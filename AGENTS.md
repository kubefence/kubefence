# Agent Reference — nono-nri

Authoritative technical reference for AI agents working on this codebase.
Read this before reading any source file. See CLAUDE.md for commit conventions.

---

## What this project is

`nono-nri` is a Kubernetes NRI (Node Resource Interface) plugin that intercepts
container creation and wraps the container process with the `nono` Landlock
sandbox binary. Opt-in is via RuntimeClass: only pods whose RuntimeClass handler
matches the configured list are wrapped; all others are skipped with zero overhead.

The `nono` binary (built from source by `scripts/build-nono.sh`, glibc by default)
is copied from the container image to the host by a DaemonSet init container,
then bind-mounted read-only into each sandboxed container at `/nono/nono`.

---

## File map

```
cmd/nono-nri/main.go              entrypoint: flags (-log-level, -json, -config), kernel check, config, stub.Run
internal/nri/plugin.go            Plugin struct; CreateContainer, StopContainer, RemoveContainer
internal/nri/filter.go            ShouldSandbox, SkipReason — pure, no I/O
internal/nri/profile.go           ResolveProfile — annotation → validated profile name
internal/nri/adjustments.go       BuildAdjustment — args wrapping + bind mount
internal/nri/state.go             WriteMetadata, RemoveMetadata — /var/run/nono-nri/…
internal/nri/config.go            Config struct, LoadConfig (TOML)
internal/nri/kernel.go            CheckKernel — Linux 5.13+ required for Landlock
internal/nri/export_test.go       test-only helpers (SetStateBaseDir, SetKernelVersionFunc, …)
internal/log/log.go               slog JSON (prod) / text (dev) logger factory; accepts slog.Level

deploy/kind/deploy.sh             Kind cluster + plugin deploy automation
deploy/kind/e2e.sh                E2E test suite (17 checks)
deploy/kind/cluster-containerd.yaml   Kind cluster config with NRI enabled
deploy/daemonset.yaml             DaemonSet manifest (init + main containers)
deploy/runtimeclass-kata.yaml     kata-nono-sandbox RuntimeClass (handler: kata-qemu)
deploy/10-nono-nri.toml.example   Annotated TOML config reference
Dockerfile                        Multi-stage: golang:1.24-alpine builder → alpine:3.20
.github/workflows/release.yaml    CI: builds static nono from source, builds + pushes to ghcr.io
scripts/build-nono.sh             builds nono from always-further/nono source; glibc by default
                                  (BUILD_TARGET=musl for fully static); patches keyring to drop
                                  libdbus (sync-secret-service disabled)
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
       ├─ BuildAdjustment(ctr, profile, cfg.NonoBinPath)
       │    SetArgs: [/nono/nono, wrap, --profile, <profile>, --, <original args...>]
       │    AddMount: host dir of NonoBinPath → /nono  (bind, ro, rprivate)
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

---

## Config

TOML file at `/etc/nri/conf.d/10-nono-nri.toml`:

```toml
runtime_classes = ["nono-runc"]   # list of RuntimeClass handler names
default_profile = "default"        # used when pod lacks nono.sh/profile annotation
nono_bin_path   = "/opt/nono-nri/nono"  # absolute host path; must exist at startup
socket_path     = ""               # empty → NRI default /var/run/nri/nri.sock
```

`runtime_classes` and `nono_bin_path` are required; startup fails without them.
Unknown TOML keys are silently ignored (go-toml/v2 default, intentional).

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

# build static nono from source (requires rustup + musl-tools)
make nono-build

# docker image (requires ./nono binary in repo root)
make docker-build IMAGE=nono-nri:latest

# local Kind e2e — full cycle (deploy + test + teardown)
make kind-e2e

# external image quick-start (no source build)
IMAGE=ghcr.io/bpradipt/kubefence:latest SKIP_BUILD=true KATA=false \
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

- RuntimeClass `kata-nono-sandbox` → handler `kata-qemu` → nono injected via
  virtiofs bind-mount (same bind-mount mechanism, virtiofsd makes host path
  visible inside the QEMU VM).
- Kata with nested KVM in kind requires:
  - `/dev/shm` remounted to ≥16 GB (NUMA memory backend)
  - `machine_accelerators = "kernel_irqchip=split"` in QEMU config
  - Custom kata guest kernel with `CONFIG_SECURITY_LANDLOCK=y` — built by
    `.github/workflows/kata-kernel.yaml` and published to GHCR as
    `ghcr.io/<owner>/kata-kernel-landlock:<kata-version>`; deploy.sh pulls
    and deploys it automatically (uses cached `/tmp/kata-vmlinux-landlock-*.elf`)
  - Kata's original initrd is used unchanged (virtiofs and vsock are `=y` in
    the kata kernel config, so no custom initrd or insmod wrapper is needed)

---

## Published image

`ghcr.io/bpradipt/kubefence` is built by `.github/workflows/release.yaml`:
- Builds `nono` from source (`always-further/nono` at `NONO_VERSION`) as a glibc
  binary (no libdbus/libsystemd) via `scripts/build-nono.sh`
- Compiles `10-nono-nri` from repo source with `CGO_ENABLED=0`
- Platform: `linux/amd64` only
- Logging from NRI SDK internals appears in logrus format
  (`time="..." level=info msg="..."`) — this is the SDK's own logger, not the
  plugin's slog output

To use the published image without a local build:

```bash
IMAGE=ghcr.io/bpradipt/kubefence:latest SKIP_BUILD=true KATA=false \
  bash deploy/kind/deploy.sh
```
