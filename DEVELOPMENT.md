# Development

See [README.md](README.md) for project overview, threat model, and deployment instructions.

## Build

```bash
# Build the nono binary from source (requires rustup)
make nono-build      # outputs ./nono (glibc, no libdbus/libsystemd)

# Build the plugin binary
make build           # outputs ./10-nono-nri

# Build the Docker image (bundles plugin + nono binary)
make docker-build    # outputs nono-nri:latest
```

## Requirements

| Component | Minimum version |
|-----------|----------------|
| Go | 1.24+ |
| rustup | for nono source builds via `make nono-build` |
| musl-tools | optional, for static musl builds: `BUILD_TARGET=musl make nono-build` |
| Docker | for `make docker-build` |

## Quick Start with Kind

Requires a host with KVM support. `KATA=true` and `KATA_EXTENSION=true` are the
defaults — the deploy script installs Kata via helm, cold-plugs the nono guest
extension into the VM, and registers the `kata-nono-sandbox` RuntimeClass
automatically. Neither the guest kernel nor the guest image is patched: kata >= 4.0
enables Landlock by default and carries the extension as a separate block device.

```bash
git clone https://github.com/kubefence/kubefence
cd kubefence

# Default: Kata Containers + embedded nono rootfs (recommended)
SKIP_BUILD=true \
IMAGE=ghcr.io/kubefence/nono-nri-plugin:latest \
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
(`deploy/kind/kata-extension/policy.rego`).

**runc opt-in** (no KVM required, no exec blocking):

```bash
KATA=false \
SKIP_BUILD=true \
IMAGE=ghcr.io/kubefence/nono-nri-plugin:latest \
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

## CI

| Workflow | Trigger | Publishes |
|----------|---------|-----------|
| `lint` | push / PR to main | — (gofmt, go vet, mod tidy, unit tests) |
| `release` | GitHub release published | `ghcr.io/kubefence/nono-nri-plugin:<version>` |
| `kata-extension` | release + push (Dockerfile/policy.rego/agent-config.toml) | `ghcr.io/kubefence/kata-nono-extension:<ref>` |
| `helm-publish` | release + push (chart files) | `oci://ghcr.io/kubefence/charts/kubefence:<version>` |

The pinned `NONO_VERSION` in
[`.github/workflows/release.yaml`](.github/workflows/release.yaml)
controls which nono release is baked into the image. Update it when bumping nono.
