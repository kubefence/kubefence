# nono-nri

> **⚠️ Proof of concept — not for production use.**
> This is experimental test code. It is provided as-is with no guarantees of
> stability, security, or support.

An [NRI (Node Resource Interface)](https://github.com/containerd/nri) plugin for Kubernetes that
transparently sandboxes container commands using [nono](https://nono.sh), a kernel-enforced
sandbox CLI built on Linux Landlock. 
It should be pretty straightforward to switch from nono to an alternative.

**Kata Containers is the default and preferred runtime.** The plugin intercepts container
creation and prepends `nono wrap` to `process.args` via `ContainerAdjustment.SetArgs()`.
Runc is supported as an opt-in alternative (`KATA=false`).

There are multiple reasons for Kata containers being the preferred runtime

- Kata containers runs the pod in a separate VM, thereby prividing additional
  protection to the worker node on container escapes. With Kata the container
  must escape the VM protection as well.
- Ability to use a specific kernel config for the workloads, since pods runs in a VM
- Execs triggered via `kubectl exec` is **blocked at the kata-agent level for
  Kata pods** 


## Threat Model

nono-nri protects the **host worker node** from the workloads.

**Trusted** — the host side and everything it provides to the guest:
- The host OS, its kernel, and all binaries running on it
- The nono-nri plugin itself and the nono binary it distributes
- Everything the host injects into the container at creation time: the
  `/nono` bind-mount, the `SetArgs` override that installs nono as PID 1,
  and the `NONO_PROFILE` / `PATH` environment variables

**Untrusted** — anything inside the container after it starts:
- The container workload and all processes it spawns
- Any code or data arriving from the network inside the container

**What is enforced:**
Landlock LSM restrictions are applied by nono before the container's own code
runs. Because Landlock is a kernel mechanism, a compromised process inside the
container cannot remove or weaken its own restrictions. Restrictions are also
inherited across `exec`, so child processes remain confined.

**What is not enforced:**
nono-nri constrains filesystem access. It does not restrict network access,
syscalls (beyond what seccomp provides separately), or inter-process
communication. A workload that bypasses the filesystem entirely (e.g. via
`mmap`/JIT) is not constrained by Landlock.

---

## Demo

**python-dev** — automated Job showing Landlock filesystem isolation (non-interactive):

![python-dev sandbox demo](contrib/python-dev/python-demo.gif)

**node-dev** — manual exec into baseline vs sandboxed pod (interactive):

![node-dev sandbox demo](contrib/node-dev/node-demo.gif)

**kata-sandbox** — nono inside a Kata Containers QEMU/KVM micro-VM; nono binary delivered via virtiofs bind-mount, no initrd embed:

![kata-sandbox demo](contrib/kata-sandbox/kata-demo.gif)

See [`contrib/`](contrib/) for manifests, Dockerfiles, and full demo scripts.

## How It Works

1. A pod is created with `runtimeClassName: kata-nono-sandbox`
2. The NRI plugin receives the `CreateContainer` event from CRI-O or containerd
3. The plugin prepends `/nono/nono wrap --profile <profile> --` to the container's `process.args`
4. The container starts — nono applies the Landlock sandbox and `exec()`s into the original command
5. The container process runs kernel-enforced sandboxed; nono has replaced itself

```
Pod spec: command: ["myapp", "--flag"]
                    ↓ NRI plugin
OCI spec: args:   ["/nono/nono", "wrap", "--profile", "default", "--", "myapp", "--flag"]
                    ↓ container start (inside Kata VM)
PID 1:    /usr/bin/myapp --flag   (nono exec'd the app; kubectl exec blocked by OPA)
```

## Container image

Published image (built by CI on every release):

```
ghcr.io/bpradipt/kubefence:latest
```

The image bundles the compiled `10-nono-nri` NRI plugin and the `nono` sandbox
binary. No local build is required to try it out.

## Requirements

| Component | Minimum version |
|-----------|----------------|
| Linux kernel | 5.13+ (Landlock LSM) |
| CRI-O | 1.35+ (NRI with `AdjustArgs` support) |
| containerd | 2.2.0+ (NRI with `AdjustArgs` support) |
| Go | 1.24+ |
| nono binary | built from source via `make nono-build` (glibc, no libdbus/libsystemd) |

## Build

```bash
# Build the nono binary from source (requires rustup)
make nono-build      # outputs ./nono (glibc, no libdbus/libsystemd)

# Build the plugin binary
make build           # outputs ./10-nono-nri

# Build the Docker image (bundles plugin + nono binary)
make docker-build    # outputs nono-nri:latest
```

## Deploy

### Quick start with Kind

Requires a host with KVM support. `KATA=true` and `KATA_ROOTFS=true` are the
defaults — the deploy script installs Kata via helm, patches the QEMU config with
a Landlock-enabled kernel, embeds nono in the guest VM image, and registers the
`kata-nono-sandbox` RuntimeClass automatically.

```bash
git clone https://github.com/bpradipt/kubefence
cd kubefence

# Default: Kata Containers + embedded nono rootfs (recommended)
SKIP_BUILD=true \
IMAGE=ghcr.io/bpradipt/kubefence:latest \
KATA_KERNEL_IMAGE=ghcr.io/bpradipt/kata-kernel-landlock:3.28.0 \
bash deploy/kind/deploy.sh

# Run e2e tests (runc + Kata)
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash deploy/kind/e2e.sh

# Tear down
kind delete cluster --name nono-containerd
```

Use the `kata-nono-sandbox` RuntimeClass for all production workloads:

```yaml
spec:
  runtimeClassName: kata-nono-sandbox
  containers:
    - name: myapp
      image: myimage:latest
```

This gives you two enforcement layers: Landlock filesystem confinement inside the
VM, and `kubectl exec` blocked at the hypervisor by the kata-agent OPA policy
(`deploy/kind/kata-rootfs/policy.rego`).

**runc opt-in** (no KVM required, no exec blocking):

```bash
KATA=false \
SKIP_BUILD=true \
IMAGE=ghcr.io/bpradipt/kubefence:latest \
bash deploy/kind/deploy.sh
```

**Building from source:**

```bash
# containerd (default)
make kind-e2e

# CRI-O
make kind-e2e RUNTIME=crio

# Deploy only, keep cluster alive for manual testing
make kind-up
make kind-test   # run e2e suite against the running cluster
make kind-down   # tear down
```

See [`deploy/kind/README.md`](deploy/kind/README.md) for full Kind deployment docs.

### Production (CRI-O or containerd)

**1. Configure the runtime**

*CRI-O* — copy [`deploy/crio-nri.conf`](deploy/crio-nri.conf) to `/etc/crio/crio.conf.d/`:
```bash
cp deploy/crio-nri.conf /etc/crio/crio.conf.d/10-nono-nri.conf
systemctl restart crio
```

*containerd* — merge [`deploy/containerd-config.toml`](deploy/containerd-config.toml) into `/etc/containerd/config.toml`,
then `systemctl restart containerd`.

**2. Install the plugin config**

```bash
cp deploy/10-nono-nri.toml.example /etc/nri/conf.d/10-nono-nri.toml
# Edit: set runtime_classes, nono_bin_path, default_profile
```

**3. Apply Kubernetes manifests**

```bash
# Register the sandboxed RuntimeClass
kubectl apply -f deploy/runtimeclass-kata.yaml

# Deploy the plugin DaemonSet using the published image
IMAGE=ghcr.io/bpradipt/kubefence:latest
sed "s|image: nono-nri:latest|image: ${IMAGE}|g" deploy/daemonset.yaml \
  | kubectl apply -f -

kubectl rollout status daemonset/nono-nri -n kube-system
```

**4. Apply the RuntimeClass to workloads**

Add `runtimeClassName: kata-nono-sandbox` to any pod spec:

```yaml
spec:
  runtimeClassName: kata-nono-sandbox
  containers:
    - name: myapp
      image: myimage:latest
```

Optionally override the nono profile per pod:
```yaml
metadata:
  annotations:
    nono.sh/profile: "strict"
```

## Verify

```bash
# Apply a test pod
kubectl apply -f deploy/test-pod.yaml
kubectl wait --for=condition=ready pod/nono-test --timeout=60s

# nono exec()s into sleep — /proc/1/cmdline shows the original command
kubectl exec nono-test -- cat /proc/1/cmdline | tr '\0' ' '
# → sleep infinity

# nono binary is bind-mounted into the container
kubectl exec nono-test -- ls -la /nono/nono
# → -rwxr-xr-x 1 root root ... /nono/nono

# Check plugin decision logs
kubectl logs -n kube-system -l app=nono-nri | grep nono-test
# → {"msg":"injected","decision":"inject","pod":"nono-test","profile":"default",...}

# Cleanup
kubectl delete pod nono-test
```

## Configuration

`/etc/nri/conf.d/10-nono-nri.toml`:

```toml
# RuntimeClass handler names to intercept (matches pod.GetRuntimeHandler())
runtime_classes = ["nono-runc"]

# nono profile when pod has no nono.sh/profile annotation
default_profile = "default"

# Host path to the nono binary (copied there by the DaemonSet init container)
nono_bin_path = "/opt/nono-nri/nono"

# NRI socket (empty = use runtime default: /var/run/nri/nri.sock)
socket_path = ""
```

The `nono.sh/profile` annotation value is validated against `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`.
Invalid values are silently ignored and fall back to `default_profile`.

## CI

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `lint` | push/PR to main | `gofmt`, `go vet`, `go mod tidy`, `go test -race` |
| `release` | GitHub release published | Builds static nono from source, builds and pushes `ghcr.io/bpradipt/kubefence` to GHCR |
| `kata-kernel` | weekly + `workflow_dispatch` + release | Builds a kata guest kernel with `CONFIG_SECURITY_LANDLOCK=y` and pushes `ghcr.io/bpradipt/kata-kernel-landlock:<kata-version>` to GHCR |

The nono version built from source is controlled by `NONO_VERSION` in
[`.github/workflows/release.yaml`](.github/workflows/release.yaml).
Update this value when bumping the pinned nono release.

## E2E Tests

```bash
# Full cycle (deploy + test + teardown)
make kind-e2e                    # 17 checks (runc only)
make kind-e2e KATA=true          # 20 checks (runc + Kata Containers)
make kind-e2e RUNTIME=crio       # 16/17 pass; Kata tests skipped (see note below)

# Test against an existing cluster
make kind-test
```

> **CRI-O + Kata in kind:** Kata Containers tests (Tests 5/6) do not pass when
> `RUNTIME=crio`. The `quay.io/confidential-containers/kind-crio` image uses
> fuse-overlayfs as CRI-O's storage driver inside Docker. CRI-O calls
> `Unmount()` on the container overlay immediately after `StartContainer` while
> the kata shim's virtiofsd bind-mount still holds a reference, causing the
> sandbox to be torn down. This is a CRI-O 1.35 + kata 3.28 storage lifecycle
> incompatibility that does not affect bare-metal CRI-O deployments.

## Project Layout

```
.github/workflows/
  lint.yaml            # CI: gofmt, vet, mod tidy, unit tests
  release.yaml         # CD: build + push image to GHCR on release
cmd/nono-nri/          # plugin entrypoint (main.go)
internal/nri/
  plugin.go            # CreateContainer / StopContainer / RemoveContainer handlers
  adjustments.go       # BuildAdjustment: SetArgs + AddMount
  filter.go            # ShouldSandbox: RuntimeClass matching
  profile.go           # ResolveProfile: annotation → profile name
  config.go            # TOML config loader
  kernel.go            # Landlock kernel version check (≥5.13)
  state.go             # Per-container metadata dir lifecycle
internal/log/          # slog JSON handler factory
deploy/
  daemonset.yaml       # Kubernetes DaemonSet (plugin + init container)
  runtimeclass-kata.yaml  # RuntimeClass: kata-nono-sandbox / handler: kata-qemu
  test-pod.yaml        # Sample sandboxed pod for verification
  crio-nri.conf        # CRI-O NRI config snippet
  containerd-config.toml  # containerd NRI config snippet
  kind/                # Kind cluster configs, deploy.sh, e2e.sh
```

## License

[Apache 2.0](LICENSE)
