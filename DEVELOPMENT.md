# Development

See [README.md](README.md) for project overview, threat model, and deployment instructions.

## Build

```bash
# Fetch the pinned upstream nono release binary
make nono-fetch      # outputs ./nono (glibc 2.34+, no libdbus/libsystemd)

# Build the plugin binary
make build           # outputs ./10-nono-nri

# Build the Docker image (bundles plugin + nono binary)
make docker-build    # outputs nono-nri:latest
```

## Requirements

| Component | Minimum version |
|-----------|----------------|
| Go | 1.24+ |
| curl | for `make nono-fetch` |
| Docker | for `make docker-build` |

## The nono binary

`scripts/fetch-nono.sh` downloads the pinned upstream release
(`nolabs-ai/nono`, `NONO_VERSION`, currently **v0.71.0**) and verifies it against
a checksum pinned in the script — bump both together. Nothing is built from
source: upstream's glibc binary needs only libc, libgcc_s and libm, which is what
the old source build produced after patching the keyring feature out, so the
Rust toolchain bought nothing.

Consequences worth knowing:

- **glibc 2.34+** is required in any image the binary is bind-mounted into
  (Ubuntu 22.04, Debian 12, RHEL 9 and newer). Older images cannot run it.
- **No musl build exists upstream**, so alpine workloads are unsupported. The
  removed source build could produce one; see git history for the patch set if
  you need to revive it.

## Quick Start with Kind

Requires a host with KVM support. `KATA=true` and `KATA_EXTENSION=true` are the
defaults — the deploy script installs Kata via helm, cold-plugs the nono guest
extension into the VM, and registers the `kata-nono-sandbox` RuntimeClass
automatically. Neither the guest kernel nor the guest image is patched: kata >= 4.0
enables Landlock by default and carries the extension as a separate block device.

```bash
git clone https://github.com/kubefence/kubefence
cd kubefence

# Default: Kata Containers + nono guest extension (recommended)
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
(`deploy/kata-extension/policy.rego`).

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
make kind-e2e                    # Kata + guest extension by default: 29 checks
make kind-e2e KATA=false         # runc only; Kata tests (5-7) skipped
make kind-e2e RUNTIME=crio       # Kata tests skipped (see note below)

# Test against an existing cluster
make kind-test
```

The suite skips the Kata tests when the `kata-nono-sandbox` RuntimeClass is
absent, so the total reported depends on what was deployed.

> **CRI-O + Kata in kind:** the Kata tests do not pass when `RUNTIME=crio`. The
> `quay.io/confidential-containers/kind-crio` image uses fuse-overlayfs as
> CRI-O's storage driver inside Docker. CRI-O calls `Unmount()` on the container
> overlay immediately after `StartContainer` while the kata shim's virtiofsd
> bind-mount still holds a reference, causing the sandbox to be torn down. This
> was a CRI-O 1.35 + kata 3.28 storage lifecycle incompatibility that does not
> affect bare-metal CRI-O deployments; it has not been re-tested against the
> current kata 4.0.0 pin.

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
  helm/kubefence/      # the chart: plugin + node-setup + kata-setup DaemonSets
  daemonset.yaml       # Kubernetes DaemonSet (plugin + init container)
  runtimeclass-kata.yaml  # kata-nono-sandbox → handler kata-qemu-runtime-rs (NRI only)
  runtimeclass-kata-nono-sandbox.yaml  # same name → handler kata-nono-qemu (+ extension)
  test-pod.yaml        # Sample sandboxed pod for verification (glibc image)
  crio-nri.conf        # CRI-O NRI config snippet
  containerd-config.toml  # containerd NRI config snippet
  kata-extension/      # guest extension image: policy.rego + agent-config.toml
  kind/                # Kind cluster configs, deploy.sh, e2e.sh
  kubeadm/             # stock-containerd harness — the schema kind cannot cover
```

`deploy/kubeadm/` is the second test harness: kind's node image ships a
`version = 2` containerd config, so the kind suite cannot catch a drop-in written
under the wrong CRI plugin name for the `version = 3` schema a real node runs.
Run it before releasing changes to how containerd config is written — see
[`deploy/kubeadm/README.md`](deploy/kubeadm/README.md).

## CI

| Workflow | Trigger | Publishes |
|----------|---------|-----------|
| `lint` | push / PR to main | — (gofmt, go vet, mod tidy, unit tests) |
| `release` | GitHub release published | `ghcr.io/kubefence/nono-nri-plugin:<version>` |
| `kata-extension` | release + push (Dockerfile/policy.rego/agent-config.toml) | `ghcr.io/kubefence/kata-nono-extension:<ref>` |
| `helm-publish` | release + push (chart files) | `oci://ghcr.io/kubefence/charts/kubefence:<version>` |

The pinned `NONO_VERSION` in
[`.github/workflows/release.yaml`](.github/workflows/release.yaml)
controls which nono release is baked into the image. Bump it together with the
checksum in [`scripts/fetch-nono.sh`](scripts/fetch-nono.sh) — a mismatch fails
the release build loudly, which is the point of the pin.
