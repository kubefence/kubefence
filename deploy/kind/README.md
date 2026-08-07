# Kind Local Test Clusters

Two cluster configurations are provided — one for each supported container runtime.

## Quick start (pre-built image — no source required)

Prerequisites: Docker, [Kind](https://kind.sigs.k8s.io/) v0.20+, kubectl, helm.

```bash
git clone https://github.com/kubefence/kubefence
cd kubefence

IMAGE=ghcr.io/kubefence/nono-nri-plugin:latest \
SKIP_BUILD=true \
bash deploy/kind/deploy.sh
```

Then run the e2e tests:

```bash
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash deploy/kind/e2e.sh
```

Tear down when done:

```bash
kind delete cluster --name nono-containerd
```

## Kata Containers deployment

`deploy.sh` installs Kata Containers alongside nono-nri by default (`KATA=true`;
set `KATA=false` to skip it).
It installs Kata via the official helm chart, patches the QEMU config, and
registers the `kata-nono-sandbox` RuntimeClass — all in one step. The bundled
guest kernel is used as-is (kata >= 4.0 has Landlock enabled by default).

### Prerequisites

- Everything in the base quick start (Docker, Kind v0.20+, kubectl, helm)
- **KVM:** the host must expose `/dev/kvm` to Docker containers. Verify with:
  ```bash
  docker run --rm --device /dev/kvm alpine sh -c 'ls /dev/kvm && echo ok'
  ```
  On most Linux hosts this works out of the box.

### Deploy

```bash
KATA=true \
SKIP_BUILD=true \
IMAGE=ghcr.io/kubefence/nono-nri-plugin:latest \
bash deploy/kind/deploy.sh
```

### How it works

The deploy script performs these extra steps when `KATA=true`:

1. **Installs Kata** via `helm install kata-deploy` (pinned to `KATA_VERSION=4.0.0`).
2. **Expands `/dev/shm`** on the kind node to 16 GB (kata uses memory-backend-file for NUMA).
3. **Patches the QEMU config** (`configuration-qemu-runtime-rs.toml` — kata 4.0
   defaults to the Rust runtime, whose configs sit under a `runtime-rs/` prefix):
   - Sets `machine_accelerators = "kernel_irqchip=split"` (required for nested-KVM with Kind).
   - Leaves `kernel` untouched — the stock kata kernel already has Landlock.
4. **Installs the nono guest extension** (when `KATA_EXTENSION=true`, the default):
   builds or pulls the image from [`deploy/kata-extension/`](../kata-extension/) —
   it is a published artefact the Helm chart uses on any cluster, not kind tooling —
   copies `kata-nono-extension.img` onto the node, then writes
   `configuration-kata-nono-qemu.toml` — a copy of the QEMU config plus a
   `[[hypervisor.qemu.guest_extension_images]]` entry and
   `agent.config_file=/run/kata-extensions/nono/agent-config.toml` appended to
   `kernel_params` — and registers the `kata-nono-qemu` handler.
5. **Applies `deploy/runtimeclass-kata.yaml`** — registers the `kata-nono-sandbox`
   RuntimeClass (handler: `kata-qemu-runtime-rs`).

The nono binary is delivered to the Kata VM via a virtiofs bind-mount, exactly
as for runc containers. The guest image itself is never modified: the hardened
kata-agent OPA policy travels in the extension image, which the runtime
cold-plugs as a read-only virtio-blk device and the guest mounts at
`/run/kata-extensions/nono` before `kata-agent` starts. See
[composable VM images](https://github.com/kata-containers/kata-containers/blob/main/docs/design/composable-vm-images.md).

### Running workloads

Use the `kata-nono-sandbox` RuntimeClass to run a pod inside a QEMU/KVM micro-VM
with nono sandboxing applied:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-kata-pod
  annotations:
    nono.sh/profile: "default"
spec:
  runtimeClassName: kata-nono-sandbox
  containers:
    - name: app
      image: ubuntu:22.04
      command: ["sleep", "infinity"]
```

### Run e2e tests

The test suite automatically runs Test 5 (Kata + nono) when the `kata-nono-sandbox`
RuntimeClass is present:

```bash
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash deploy/kind/e2e.sh
```

### Tear down

```bash
kind delete cluster --name nono-containerd
```

## Prerequisites (building from source)

- Docker (running)
- [Kind](https://kind.sigs.k8s.io/) v0.20+
- kubectl
- Go 1.25+ (for building the plugin)
- `nono` binary at repo root (`./nono`) — fetch with `make nono-fetch` (upstream glibc release)

## Supported Configurations

| Runtime | Kind node image | containerd/CRI-O version | SetArgs support |
|---------|----------------|--------------------------|-----------------|
| containerd | `kindest/node:v1.35.1` | containerd 2.2.1 | ✓ |
| CRI-O | `quay.io/confidential-containers/kind-crio:v1.35.2` | CRI-O 1.35 | ✓ |

> **Note on SetArgs:** `ContainerAdjustment.SetArgs()` requires containerd ≥ 2.2.0 or
> CRI-O ≥ 1.35. Earlier versions had a missing `AdjustArgs()` call in their vendored
> NRI runtime-tools library and silently ignored args modifications.

## Deploy

### Using Make (recommended)

```bash
# containerd (default)
make kind-e2e

# CRI-O
make kind-e2e RUNTIME=crio

# Deploy only (keep cluster running for manual inspection)
make kind-up
make kind-up RUNTIME=crio

# Run tests against an existing cluster
make kind-test

# Verify seccomp enforcement (not covered by kind-test): runs the actor and
# probe binaries from tools/ as container main processes and compares the
# blocked syscalls across profiles. Add KATA=false to skip the kata comparison.
make seccomp-test

# One-off variants seccomp-test does not cover — notably a pod-spec
# RuntimeDefault profile under plain kata, which proves the kata-agent
# enforces seccomp independently of nono-nri injection:
#   kubectl apply -f deploy/kind/fixtures/

# Tear down
make kind-down
make kind-down RUNTIME=crio
```

### Using the script directly

```bash
# containerd
RUNTIME=containerd bash deploy/kind/deploy.sh

# CRI-O
RUNTIME=crio bash deploy/kind/deploy.sh
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RUNTIME` | `containerd` | `containerd` or `crio` |
| `CLUSTER_NAME` | `nono-<runtime>` | Kind cluster name |
| `IMAGE` | `nono-nri:latest` | Plugin image tag (set to `ghcr.io/kubefence/nono-nri-plugin:latest` to use the published image) |
| `SKIP_BUILD` | `false` | Skip `make docker-build`; pull `IMAGE` from a registry instead |
| `KATA` | `false` | Install Kata Containers (`true`/`false`). |
| `KATA_VERSION` | `4.0.0` | kata-containers release to install. 4.0.0 is the minimum: earlier guest kernels have Landlock compiled out and have no composable-image support. |
| `KATA_EXTENSION` | `true` | Deploy the nono guest extension image carrying the hardened kata-agent policy (requires `KATA=true`). |
| `KATA_EXTENSION_IMAGE` | _(unset)_ | Pull a published extension image (e.g. `ghcr.io/kubefence/kata-nono-extension:v1.2.3`) instead of building `deploy/kata-extension/`. Unset — the default — builds from the working tree, so e2e tests the `policy.rego` in this checkout. Only set it to check a published image on purpose; a failed pull is an error, not a fallback. |
| `REGISTRY_NAME` | `nono-nri-registry` | Local registry container name (crio only) |
| `REGISTRY_PORT` | `5100` | Local registry port on the host (crio only) |

## Run E2E Tests

After deploying with `deploy.sh` or `make kind-up`:

```bash
# containerd
make kind-test
# or
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash deploy/kind/e2e.sh

# CRI-O
make kind-test RUNTIME=crio
# or
RUNTIME=crio CLUSTER_NAME=nono-crio \
  REGISTRY_NAME=nono-nri-registry REGISTRY_PORT=5100 \
  bash deploy/kind/e2e.sh
```

### E2E Test Coverage

| Test | What it verifies |
|------|-----------------|
| 1. Plugin connectivity | DaemonSet running, plugin registered with runtime |
| 2. Sandboxed pod injection | `process.args` modified, `/nono/nono` accessible, OCI bundle args + mount, state dir written |
| 3. Non-sandboxed isolation | Non-sandboxed pods unaffected, no `/nono` mount |
| 4. State dir cleanup | State dir removed on pod deletion (`RemoveContainer`) |
| 5. Kata + nono | nono injection inside a QEMU/KVM micro-VM (skipped when `KATA=false`) |

### Expected Results

| Test | containerd 2.2.1 | CRI-O 1.35 |
|------|-----------------|------------|
| Plugin connectivity | ✓ | ✓ |
| process.args modified | ✓ | ✓ |
| /nono/nono accessible | ✓ | ✓ |
| OCI bundle process.args | ✓ | ✓ |
| OCI bind mount | ✓ | ✓ |
| State dir metadata | ✓ | ✓ |
| Non-sandboxed isolation | ✓ | ✓ |
| State dir cleanup | ✓ | ✓ |
| Kata + nono | skipped (KATA=false by default; set KATA=true) | skipped (KATA=false by default; set KATA=true) |

## Verify Manually

After deployment:

```bash
# Apply the test pod (uses kata-nono-sandbox RuntimeClass)
kubectl apply -f deploy/test-pod.yaml

# Wait for it to be ready
kubectl wait --for=condition=ready pod/nono-test --timeout=60s

# Check /proc/1/cmdline — shows sleep (nono exec'd and replaced itself)
kubectl exec nono-test -- cat /proc/1/cmdline | tr '\0' ' '

# Check /nono/nono is bind-mounted
kubectl exec nono-test -- ls -la /nono/nono
```

## Cleanup

```bash
# containerd
make kind-down
# or: kind delete cluster --name nono-containerd

# CRI-O
make kind-down RUNTIME=crio
# or:
kind delete cluster --name nono-crio
docker rm -f nono-nri-registry
```
