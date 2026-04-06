# Project Guidelines

## Commit Convention

**Every commit must:**
- Use `git commit -s` (adds `Signed-off-by` trailer automatically)
- Include `Assisted-by: AI` as a footer line in the commit message body
- NOT include `Co-authored-by: Claude ...` or any Anthropic attribution footer

**Format:**
```
<type>: <description>

Assisted-by: AI
```

The `Signed-off-by` trailer is added automatically by `git commit -s`.

## Stack

- Go 1.24+, module: `github.com/k8s-nono/nono-nri`
- NRI SDK: `github.com/containerd/nri` v0.10.0
- Tests: Ginkgo v2 + Gomega
- Config: TOML via `github.com/pelletier/go-toml/v2` v2.2.4
- Logging: `log/slog` with `NewJSONHandler`
- go.mod must keep: `replace github.com/opencontainers/runtime-spec => github.com/opencontainers/runtime-spec v1.1.0`

## Project Layout

```
cmd/nono-nri/        # main entrypoint
internal/nri/        # plugin, filter, profile, config, kernel
internal/log/        # slog setup
```

## Key Decisions

- Container opt-in: RuntimeClass filter only (no namespace denylist)
- Pause containers excluded naturally via NRI PodSandbox event separation
- `ContainerAdjustment.SetArgs()` to wrap process.args — no OCI hooks
- nono binary built from source (glibc by default, BUILD_TARGET=musl for static) — no libdbus/libsystemd
- nono binary bind-mounted from host into container (works for Kata via virtiofs)
- `scripts/build-nono.sh` builds nono from source; `make nono-build` is the entry point
- Kernel check (5.13+ for Landlock) runs before anything else in main()
- State dir cleanup uses `StopContainer` (direct gRPC RPC, reliable) not
  `RemoveContainer` (StateChange notification, not delivered by containerd 2.x
  to external socket-connected plugins)

## Agent Reference

See `AGENTS.md` for the full technical reference: file map, data flows,
NRI event delivery constraints, testing patterns, and invariants.

<!-- GSD:project-start source:PROJECT.md -->
## Project

**nono-nri: Kata-first confidential rootfs**

nono-nri is a Kubernetes NRI plugin that transparently wraps container processes
with the nono Landlock sandbox. It injects nono into opted-in pods via RuntimeClass
and supports two delivery modes: host bind-mount (runc or Kata via virtiofs) and
embedded rootfs (nono baked into the Kata guest image). This milestone makes Kata
Containers the default runtime and switches the embedded rootfs base from
`kata-ubuntu-noble.image` to `kata-containers-confidential.img`.

**Core Value:** Kata Containers is the default, production-grade sandboxing path — runc access
is opt-in, not the other way around.

### Constraints

- **No root / no loop mount**: `inject.sh` must stay root-free; use `dd` + `debugfs -w`
  for ext4 injection. Dynamic geometry detection must also be root-free (`sfdisk --json`
  works on regular files).
- **Streaming extraction**: Dockerfile streams the kata-static tarball to avoid
  storing the full ~1 GB archive; `tar --to-stdout -x <path>` pattern must be kept.
- **e2tools must be available**: `debugfs` is from `e2fsprogs`; already in builder apt list.
- **`sfdisk` availability**: `sfdisk` is in `fdisk` package on Ubuntu 24.04 — add to
  builder `apt-get install` list.
- **Kata version pin**: `KATA_VERSION=3.28.0` is pinned across deploy.sh, kata-kernel.yaml,
  kata-rootfs.yaml — keep in sync.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Go 1.24.3 - NRI plugin implementation (`cmd/nono-nri`, `internal/nri`, `internal/log`)
- Rust - nono binary (wrapped via `scripts/build-nono.sh`)
- Bash - Deployment and build automation scripts
## Runtime
- Linux 5.13+ (kernel requirement for Landlock LSM support)
- NRI (Node Resource Interface) plugin framework via containerd
- Go Modules (go.mod/go.sum)
- Rust Cargo (for nono dependency)
## Frameworks
- `github.com/containerd/nri` v0.10.0 - NRI SDK for container runtime plugin interface
- `github.com/containerd/ttrpc` v1.2.7 - Transport mechanism for NRI communication
- `github.com/onsi/ginkgo/v2` v2.28.1 - BDD testing framework
- `github.com/onsi/gomega` v1.39.1 - Assertion/matcher library
- Docker/containerd - For image building and cluster testing
- Kind - Kubernetes-in-Docker for local cluster testing
- Kata Containers 3.28.0+ - VM-based container runtime (optional)
## Key Dependencies
- `github.com/containerd/nri` v0.10.0 - Why it matters: Provides NRI plugin interface stub, API types, and gRPC/ttrpc protocol bindings for container lifecycle events (CreateContainer, RemoveContainer, StopContainer)
- `github.com/pelletier/go-toml/v2` v2.2.4 - Configuration file parsing (see `internal/nri/config.go`)
- `google.golang.org/grpc` v1.57.1 - gRPC protocol implementation (transitive via containerd/nri)
- `google.golang.org/protobuf` v1.36.7 - Protocol buffer serialization (transitive)
- `github.com/containerd/log` v0.1.0 - Logging framework (transitive)
- `github.com/google/go-cmp` v0.7.0 - Comparison utilities for assertions
- `github.com/Masterminds/semver/v3` v3.4.0 - Version parsing for kata-containers
- `github.com/joshdk/go-junit` v1.0.0 - JUnit XML test reporting
## Configuration
- TOML configuration file at `/etc/nri/conf.d/10-nono-nri.toml`
- Flags at runtime:
- `Dockerfile` - Multi-stage Alpine-based container build (1.24-alpine → alpine:3.20)
- `Makefile` - Build targets: `build`, `test`, `docker-build`, `docker-load-kind`, `kind-*`
- `.github/workflows/` - CI/CD via GitHub Actions (lint, release, kata-kernel, kata-rootfs)
## Platform Requirements
- Go 1.24+ toolchain
- Docker (for `make docker-build`, `make nono-build` with glibc)
- rustup (for nono source builds)
- Optional: musl-tools (for static musl builds: `BUILD_TARGET=musl make nono-build`)
- Kubernetes 1.24+ with containerd 1.7.x+ or CRI-O runtime
- NRI enabled on the node's container runtime
- Linux kernel 5.13+ with Landlock LSM support
- Read access to NRI socket (`/var/run/nri/nri.sock`)
- Writable state directory (`/var/run/nono-nri` in DaemonSet)
- Kata Containers 3.28.0+ with custom kernel including `CONFIG_SECURITY_LANDLOCK=y`
- Pre-built kernel image from `ghcr.io/<owner>/kata-kernel-landlock:3.28.0`
- Custom Ubuntu rootfs image (KATA_ROOTFS mode)
## Standard Library Usage
- `log/slog` - Structured logging with JSON or text output handlers
- `flag` - Command-line flag parsing
- `os`, `os/signal` - Process lifecycle and signal handling
- `syscall` - Kernel version detection via uname
- `context` - Graceful shutdown via context cancellation
## Nono Binary Integration
- Default: glibc binary via Docker (Rust 1.85-slim-bullseye → x86_64-unknown-linux-gnu)
- Alternative: Fully static musl build (no runtime deps, works in scratch/Alpine)
- Binary path: configurable via `nono_bin_path` in config
- Embedded in container image at `/usr/local/bin/nono`
- Bind-mounted into containers at `/nono/nono` (host → container mount)
- Invoked by NRI plugin via `ContainerAdjustment.SetArgs()` to wrap process.args
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Naming Patterns
- Lowercase with underscores: `nri_suite_test.go`, `config_test.go`
- Test files follow pattern: `{module}_test.go` (e.g., `config_test.go`, `plugin_test.go`)
- Export files for testing: `export_test.go` (contains setter functions for injecting test values)
- Main entrypoint: `cmd/nono-nri/main.go`
- Lowercase single words or simple abbreviations: `nri`, `log`
- Test packages use `_test` suffix to avoid circular imports: `package nri_test`
- `CamelCase` for exported functions: `CheckKernel()`, `LoadConfig()`, `ResolveProfile()`, `BuildAdjustment()`
- `camelCase` for unexported functions: `defaultKernelVersion()`, `validPathComponent()`, `newBufLogger()`
- Verb-first pattern for actions: `WriteMetadata()`, `RemoveMetadata()`, `ShouldSandbox()`, `SkipReason()`
- Test helper functions use `camelCase`: `writeTempConfig()`, `newTestPlugin()`, `newBufLogger()`
- `camelCase` for local and package-level variables: `stateBaseDir`, `kernelVersionFn`, `tmpDir`
- ALL_CAPS for constants: `StateBaseDir`, `ContainerNonoPath`, `ProfileAnnotationKey`, `MinKernelMajor`, `MinKernelMinor`
- Prefix package-level variables with descriptive name: `stateBaseDir`, `kernelVersionFn`
- `CamelCase` for exported types: `Config`, `Plugin`, `ContainerMetadata`
- Structs use TOML tags for config loading: `toml:"runtime_classes"`, `toml:"default_profile"`
- JSON tags for metadata serialization: `json:"container_id"`, `json:"pod"`, `json:"namespace"`, `json:"profile"`
- Regex patterns: `validProfileRe = regexp.MustCompile(...)` (camelCase variable, regex pattern explicit in name)
- Directory paths: `StateBaseDir`, `ContainerNonoPath` (SCREAMING_SNAKE_CASE for paths)
- Default values: `defaultContainerPATH`, `MinKernelMajor`, `MinKernelMinor`
## Code Style
- Tool: `gofmt` (Go standard formatter)
- Entry point: `make fmt` validates code is properly formatted
- All code must pass `gofmt -l` check before commit
- Tool: `go vet ./...`
- Entry point: `make lint` checks for common Go mistakes
- Full check: `make check` runs fmt + vet + mod tidy validation
- No custom linter config (uses Go defaults)
- No explicit line length limit, but observed style avoids excessive wrapping
- Functions typically 10-40 lines
- Long functions (like `BuildAdjustment`) documented with detailed comments
- Complex conditional logic broken into separate pure functions (`ShouldSandbox()`, `SkipReason()`, `ResolveProfile()`)
## Import Organization
- Used to avoid name collisions: `applog` for internal/log package (avoid conflict with standard `log`)
- Used to shorten test imports: `nri "github.com/k8s-nono/nono-nri/internal/nri"` in `nri_test` package
- No alias for standard library or single-word packages (`context`, `os`, `fmt`)
- Ginkgo test packages: `_ = Describe(...)` to register test suites without executing them at parse time
- Gomega matchers: `. "github.com/onsi/gomega"` (dot import for test matchers only)
## Error Handling
- Explicit error wrapping using `fmt.Errorf()` with `%w` for context:
- Nested wrapping adds context at each layer: `"creating state dir %s: %w"`
- Never silent failures; all I/O errors are wrapped and returned up the stack
- Config validation errors include actionable messages: `"runtime_classes must not be empty"`, `"nono_bin_path must not be empty when bind-mount delivery is used"`
- Lower case, no period at end
- Include what failed and why: `"reading config: %w"`, `"parsing config: %w"`
- Validation errors explain the requirement: `"kernel X.Y is too old: nono-nri requires Linux 5.13+ for Landlock LSM support"`
- Path validation errors are specific: `"invalid path component %q: must not be empty, a dot-component, or contain path separators"`
- `RemoveMetadata()` best-effort removes pod directory: `_ = os.Remove(podDir)` (ignores error if non-empty)
- Commented: `// Best-effort: remove pod parent dir if it is now empty`
## Logging
- JSON mode (production): `slog.NewJSONHandler(os.Stdout, opts)`
- Text mode (development): `slog.NewTextHandler(os.Stderr, opts)`
- Structured logging with key-value pairs: `p.Log.Info("skip", "decision", "skip", "reason", SkipReason(pod), "container_id", ctrID, ...)`
- Plugin decisions always logged with all CORE-04 fields: `"container_id"`, `"namespace"`, `"pod"`, `"profile"`, `"runtime_handler"`, `"decision"`, `"reason"`
- Decision indicator: `"decision"` field set to `"skip"` or `"inject"`
- Message field `"msg"` contains action: `"skip"`, `"injected"`, `"container-removed"`, `"container-stopping"`
- Warnings for non-critical errors: `p.Log.Warn("failed to write state metadata", "container_id", ctrID, "error", err)`
- Startup info log includes config summary: `logger.Info("nono-nri starting", "config", configPath, "runtime_classes", cfg.RuntimeClasses, ...)`
- Never use `fmt.Printf()` for logs; use structured slog exclusively
- All log output goes through logger, never directly to stdout/stderr except via slog
## Comments
- Explain the "why" not the "what": code should be self-documenting
- Security or safety constraints: `// Invariant: no container image ...`, `// SAFE-01: verify Landlock LSM support ...`
- Non-obvious design decisions: `// Mounting the directory (not the file) ensures the destination path is created...`
- Algorithm complexity: parsing kernel version string with sign-extension handling via unsafe.Slice
- Interface contracts: `// Signature matches stub.RemoveContainerInterface: returns error only`
- Start with capital letter: `// CheckKernel returns an error...`
- Full sentences explaining intent, not implementation details
- Every exported function has a doc comment starting with the function name
- Format: `// FunctionName does X. It returns Y. Additional constraints: Z.`
- Example: `// CheckKernel returns an error if the running kernel is older than 5.13.`
- Mark critical paths: `// SAFE-01:` comment prefix for safety-critical checks
- Invariants documented: `// Invariant: no container image used with nono-nri should define its own /nono directory...`
- Non-obvious behavior flagged: `// go:build linux` tags in platform-specific files
## Function Design
- Accept interfaces for flexibility: `pod *api.PodSandbox`, `ctr *api.Container`, `cfg *Config`
- Group related parameters: config and logger together in plugin methods
- Use pointer receivers for methods that access plugin state: `(p *Plugin)`
- Early returns for error cases and non-matching conditions
- Plugin.CreateContainer returns triple: `(*api.ContainerAdjustment, []*api.ContainerUpdate, error)`
- Pure functions return single values: `bool` for `ShouldSandbox()`, `string` for `SkipReason()` and `ResolveProfile()`
- No boolean blind spots; validate before returning decisions
- Prefer pure functions for decision logic: `ShouldSandbox()`, `SkipReason()`, `ResolveProfile()`, `BuildAdjustment()` all have no side effects
- Makes testing trivial and enables easy refactoring
## Module Design
- Getter/Setter functions for internal state (tests only): `SetStateBaseDir()`, `ResetStateBaseDir()`, `SetKernelVersionFunc()`, `ResetKernelVersionFunc()`
- These live in `export_test.go` and are only visible during test compilation
- Config struct exported for test setup: `type Config struct`
- Constants exported for reference: `ContainerNonoPath`, `ProfileAnnotationKey`, `StateBaseDir`
- `internal/nri/` contains all plugin logic and state management
- `internal/log/` contains logger factory (minimal, single file)
- `cmd/nono-nri/` contains entrypoint: argument parsing, config loading, startup checks, plugin creation
- No utility packages; logic stays close to where it's used
## Slice & Map Patterns
- Check `len()` for slices: `if len(cfg.RuntimeClasses) == 0`
- Check `nil` for maps: `if annotations != nil`
- Handle missing keys safely: `if profile, ok := annotations[key]; ok && validProfileRe.MatchString(profile)`
- Pre-allocate slices with known capacity: `newArgs := make([]string, 0, len(prefix)+len(orig))`
- Append in order: `newArgs = append(newArgs, prefix...)` then `newArgs = append(newArgs, orig...)`
- Simple iteration: `for _, rc := range cfg.RuntimeClasses { ... }`
- String searching: `for _, entry := range ctr.GetEnv() { if strings.HasPrefix(entry, "PATH=") ... }`
- No destructuring; use explicit `_` for unused values
## Type Assertions & Conversions
- Always use comma-ok for map access: `if profile, ok := annotations[key]; ok { ... }`
- Path component validation on inputs: `validPathComponent()` prevents path traversal
- Profile regex validation: `validProfileRe.MatchString(profile)` before using annotation value
- String parsing with safe fallback: if version parse fails, return `(0, 0)` sentinel which causes kernel check to fail safely
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- Opt-in sandboxing via RuntimeClass matching — zero overhead for non-opted pods
- Pure, testable decision layer (no I/O side effects)
- Process argument wrapping via NRI API (no OCI hooks required)
- Persistent state directory with validation against path traversal
- Kernel version check at startup (5.13+ Landlock requirement)
## Layers
- Purpose: Implements the `github.com/containerd/nri` plugin interface for interception points
- Location: `internal/nri/plugin.go`
- Contains: `Plugin` struct with `CreateContainer`, `StopContainer`, `RemoveContainer` methods
- Depends on: NRI SDK, Config, Filter, Adjustments, State management
- Used by: NRI runtime (containerd via stub)
- Purpose: Pure functions that evaluate whether a container should be sandboxed (no I/O)
- Location: `internal/nri/filter.go`, `internal/nri/profile.go`
- Contains: `ShouldSandbox()` and `SkipReason()` for RuntimeClass matching; `ResolveProfile()` for annotation parsing
- Depends on: Config, API models only (no filesystem or external I/O)
- Used by: Plugin.CreateContainer to determine injection flow
- Purpose: Constructs container modifications (args wrapping, mounts, environment variables)
- Location: `internal/nri/adjustments.go`
- Contains: `BuildAdjustment()` which prepends `/nono/nono wrap --profile <profile> --` to args, adds bind-mount, injects NONO_PROFILE env var, prepends /nono to PATH
- Depends on: NRI API ContainerAdjustment, filepath utilities
- Used by: Plugin.CreateContainer to build the adjustment returned to NRI runtime
- Purpose: Persistent metadata storage for auditing and cleanup
- Location: `internal/nri/state.go`
- Contains: `WriteMetadata()` creates `/var/run/nono-nri/<podUID>/<containerID>/metadata.json`; `RemoveMetadata()` cleans up after container stops
- Depends on: filepath, os, json, time
- Used by: Plugin lifecycle methods; validates path components to prevent directory traversal
- Purpose: TOML config loading and validation
- Location: `internal/nri/config.go`
- Contains: `Config` struct (RuntimeClasses, DefaultProfile, NonoBinPath, SocketPath, VMRootfsClasses); `LoadConfig()` validates required fields
- Depends on: `github.com/pelletier/go-toml/v2`
- Used by: main() and Plugin constructor
- Purpose: Verify Linux 5.13+ for Landlock LSM support before any other setup
- Location: `internal/nri/kernel.go` (Linux only, build tag `//go:build linux`)
- Contains: `CheckKernel()` uses syscall.Uname to extract version, validates major.minor >= 5.13
- Depends on: syscall, unsafe (for Utsname parsing)
- Used by: main() as first operation before config loading or logger init
- Purpose: Structured logging (slog) with JSON (production) or text (development) output
- Location: `internal/log/log.go`
- Contains: `New()` returns *slog.Logger configured with HandlerOptions, writes to stdout (JSON) or stderr (text)
- Depends on: `log/slog` (stdlib)
- Used by: main() and Plugin constructor
- Purpose: Bootstrap plugin with flags, validation, and NRI stub registration
- Location: `cmd/nono-nri/main.go`
- Contains: Flag parsing (-config, -json, -log-level); kernel check; config loading; nono binary existence check; logger creation; NRI stub.New and s.Run()
- Depends on: All internal packages, NRI stub
- Used by: Container runtime as main executable
## Data Flow
```
```
```
```
```
```
- StopContainer is the primary reliable cleanup hook (direct gRPC RPC)
- RemoveContainer exists only for runtimes that deliver StateChange to external plugins
- Never rely on RemoveContainer as the only cleanup path
- For containerd 2.x with external socket plugins, StateChange notifications (RemoveContainer, StopPodSandbox, RemovePodSandbox) are NOT delivered
## Key Abstractions
- Purpose: Implement opt-in via RuntimeClass handler name comparison
- Examples: `internal/nri/filter.go` ShouldSandbox()
- Pattern: Simple linear search over cfg.RuntimeClasses; pod.RuntimeHandler must exactly match one entry
- No namespace denylists, no implicit opt-in — only explicit RuntimeClass handler inclusion
- Purpose: Extract nono profile from pod annotation or use default
- Examples: `internal/nri/profile.go` ResolveProfile()
- Pattern: Read pod.Annotations["nono.sh/profile"]; validate against `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$` regex; silently fall back to cfg.DefaultProfile on mismatch or absence
- Protection: Regex prevents CLI flag injection (leading digit/hyphen checks)
- Purpose: Inject nono wrapper before container process without OCI hooks
- Examples: `internal/nri/adjustments.go` BuildAdjustment()
- Pattern: Use ContainerAdjustment.SetArgs() to prepend `[/nono/nono, wrap, --profile, <profile>, --]` to ctr.Args
- Invariant: Exact order and spacing required by nono binary CLI contract
- Purpose: Make host nono binary accessible inside container
- Examples: `internal/nri/adjustments.go` AddMount
- Pattern: Mount directory (not file) via ContainerAdjustment.AddMount with type=bind, options=[bind, ro, rprivate]
- Rationale: Mounting directory ensures OCI runtime creates destination even if not in rootfs
- Path invariant: /nono directory (containerNonoDirPath); binary at /nono/nono (ContainerNonoPath)
- Purpose: Intercept common interpreter execs (sh, bash, python3, etc.) after PID 1
- Examples: `internal/nri/adjustments.go` PATH prepending
- Pattern: Build PATH with /nono first so wrapper scripts shadow real binaries; NONO_PROFILE env var enables profile lookup in wrappers without additional config
- Coverage: kubectl exec, child process spawning, any exec without full path
- Purpose: Persistent metadata for auditing and cleanup
- Examples: `internal/nri/state.go` WriteMetadata(), RemoveMetadata()
- Pattern: Hierarchical: `/var/run/nono-nri/<podUID>/<containerID>/metadata.json` with 0700 dir perms, 0600 file perms
- Validation: validPathComponent() rejects empty, ".", "..", and path separators on podUID and containerID before path construction
- JSON schema: ContainerMetadata with container_id, pod, namespace, profile, timestamp
- Purpose: Skip bind-mount for Kata VMs with embedded nono in guest rootfs
- Examples: `internal/nri/config.go` VMRootfsClasses, `internal/nri/adjustments.go` vmRootfs param
- Pattern: cfg.IsVMRootfsClass(handler) returns true for handlers in VMRootfsClasses; skip bind-mount, inject NONO_PROFILE env var instead
- Rationale: Kata guest rootfs already has /nono/nono; virtiofs bind-mount would be redundant
## Entry Points
- Location: `cmd/nono-nri/main.go` main()
- Triggers: Container runtime invokes the nono-nri executable
- Responsibilities:
- Location: `internal/nri/plugin.go`
- Triggers: NRI runtime before container creation
- Responsibilities:
- Location: `internal/nri/plugin.go`
- Triggers: NRI runtime (direct gRPC RPC) when container stops
- Responsibilities:
- Location: `internal/nri/plugin.go`
- Triggers: NRI StateChange REMOVE_CONTAINER (unreliable for containerd 2.x external plugins)
- Responsibilities:
## Error Handling
- Kernel check fails → early exit before config load (non-negotiable, prevents unsafe execution)
- Config load fails → exit with error message (startup failure)
- Nono binary not found → exit with error (cannot inject, fail loudly)
- Profile resolution fails → silently use DefaultProfile (safe fallback)
- State write fails → log warning and continue (injection still occurs; state loss is acceptable)
- State removal fails → log warning and continue (no impact on container behavior; cleanup deferred to next try or manual)
- Invalid path components (podUID, containerID) → reject the operation with validPathComponent() error (directory traversal protection)
- "skip" decision logged for non-sandboxed containers
- "injected" decision logged for sandboxed containers
- All logs include CORE-04 required fields: decision, container_id, namespace, pod, profile, runtime_handler
- Failures logged at Warn level; normal decisions at Info level
## Cross-Cutting Concerns
- Framework: `log/slog` with JSON (production) or text (development) handlers
- Level: Configurable via -log-level flag (debug, info, warn, error)
- All decision points log structured entries with consistent fields
- Location: `internal/log/log.go` New() factory
- Path component validation in `internal/nri/state.go` validPathComponent() prevents directory traversal
- Profile regex in `internal/nri/profile.go` prevents CLI flag injection
- Kernel version check in `internal/nri/kernel.go` runs first
- Config validation in `internal/nri/config.go` requires runtime_classes and nono_bin_path (unless all classes are in vm_rootfs_classes)
- Binary executable check in main.go verifies nono_bin_path exists and is runnable
- None (NRI socket connection is trusted; only local runtime can invoke the plugin)
- `/var/run/nono-nri/` directory on the host (DaemonSet creates via emptyDir volume)
- Hierarchical metadata.json files per pod and container
- StopContainer cleanup is synchronous and reliable (direct RPC)
- RemoveContainer cleanup is asynchronous fallback (StateChange unreliable in containerd 2.x)
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
