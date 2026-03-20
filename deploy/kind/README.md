# Kind Local Test Clusters

Two cluster configurations are provided — one for each supported container runtime.

## Quick start (pre-built image — no source required)

Prerequisites: Docker, [Kind](https://kind.sigs.k8s.io/) v0.20+, kubectl, helm.

```bash
git clone https://github.com/bpradipt/kubefence
cd kubefence

IMAGE=ghcr.io/bpradipt/kubefence:latest \
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

`deploy.sh` can install Kata Containers alongside nono-nri by setting `KATA=true`.
It installs Kata via the official helm chart, replaces the bundled guest kernel with
a Landlock-enabled build, patches the QEMU config, and registers the
`kata-nono-sandbox` RuntimeClass — all in one step.

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
IMAGE=ghcr.io/bpradipt/kubefence:latest \
KATA_KERNEL_IMAGE=ghcr.io/bpradipt/kata-kernel-landlock:3.28.0 \
bash deploy/kind/deploy.sh
```

`KATA_KERNEL_IMAGE` points to a pre-built guest kernel with
`CONFIG_SECURITY_LANDLOCK=y` published by the `kata-kernel` CI workflow. If you
omit this variable the script derives the image from the git remote owner; if
the image isn't available it falls back to a local build (~20-40 min).

### How it works

The deploy script performs these extra steps when `KATA=true`:

1. **Installs Kata** via `helm install kata-deploy` (pinned to `KATA_VERSION=3.28.0`).
2. **Expands `/dev/shm`** on the kind node to 16 GB (kata uses memory-backend-file for NUMA).
3. **Pulls the Landlock kernel** from `KATA_KERNEL_IMAGE`, extracts `/vmlinux`, and
   caches it at `/tmp/kata-vmlinux-landlock-<linux-ver>.elf` on the host.
4. **Copies the kernel** into the node at `/opt/kata/share/kata-containers/vmlinux-landlock.container`.
5. **Patches the QEMU config** (`configuration-qemu.toml`):
   - Sets `kernel` to the Landlock-enabled vmlinux.
   - Sets `machine_accelerators = "kernel_irqchip=split"` (required for nested-KVM with Kind).
6. **Applies `deploy/runtimeclass-kata.yaml`** — registers the `kata-nono-sandbox`
   RuntimeClass (handler: `kata-qemu`).

The nono binary is delivered to the Kata VM via a virtiofs bind-mount, exactly
as for runc containers.

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
- Go 1.24+ (for building the plugin)
- `nono` binary at repo root (`./nono`) — dynamically linked against glibc + libdbus-1

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
| `IMAGE` | `nono-nri:latest` | Plugin image tag (set to `ghcr.io/bpradipt/kubefence:latest` to use the published image) |
| `SKIP_BUILD` | `false` | Skip `make docker-build`; pull `IMAGE` from a registry instead |
| `KATA` | `false` | Install Kata Containers with a Landlock-enabled kernel (`true`/`false`). |
| `KATA_VERSION` | `3.28.0` | kata-containers release to install. Keep in sync with `KATA_VERSION` in `.github/workflows/kata-kernel.yaml`. |
| `KATA_KERNEL_IMAGE` | auto | Pre-built kernel image (e.g. `ghcr.io/yourorg/kata-kernel-landlock:3.28.0`). Derived from the git remote owner when unset. Falls back to a local source build if the image is unavailable. Cached in `/tmp/kata-vmlinux-landlock-<ver>.elf`. |
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
# Apply the test pod (uses nono-sandbox RuntimeClass)
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
