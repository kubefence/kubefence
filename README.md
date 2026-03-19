# nono-nri

An [NRI (Node Resource Interface)](https://github.com/containerd/nri) plugin for Kubernetes that
transparently sandboxes container commands using [nono](https://nono.sh), a kernel-enforced
sandbox CLI built on Linux Landlock.

The plugin intercepts container creation, prepends `nono wrap` to the container's `process.args`
via `ContainerAdjustment.SetArgs()`, and bind-mounts the nono binary into the container — working
uniformly for both runc and Kata Containers runtimes with no changes required to container images.

## Demo

**python-dev** — automated Job showing Landlock filesystem isolation (non-interactive):

![python-dev sandbox demo](contrib/python-dev/python-demo.gif)

**node-dev** — manual exec into baseline vs sandboxed pod (interactive):

![node-dev sandbox demo](contrib/node-dev/node-demo.gif)

**kata-sandbox** — nono inside a Kata Containers QEMU/KVM micro-VM; nono binary delivered via virtiofs bind-mount, no initrd embed:

![kata-sandbox demo](contrib/kata-sandbox/kata-demo.gif)

See [`contrib/`](contrib/) for manifests, Dockerfiles, and full demo scripts.

## How It Works

1. A pod is created with `runtimeClassName: nono-sandbox`
2. The NRI plugin receives the `CreateContainer` event from CRI-O or containerd
3. The plugin prepends `/nono/nono wrap --profile <profile> --` to the container's `process.args`
4. The plugin bind-mounts the nono binary from the host into the container at `/nono`
5. The container starts — nono applies the Landlock sandbox and `exec()`s into the original command
6. The container process runs kernel-enforced sandboxed; nono has replaced itself

```
Pod spec: command: ["myapp", "--flag"]
                    ↓ NRI plugin
OCI spec: args:   ["/nono/nono", "wrap", "--profile", "default", "--", "myapp", "--flag"]
                    ↓ container start
PID 1:    /usr/bin/myapp --flag   (nono exec'd in and vanished)
```

## Requirements

| Component | Minimum version |
|-----------|----------------|
| Linux kernel | 5.13+ (Landlock LSM) |
| CRI-O | 1.35+ (NRI with `AdjustArgs` support) |
| containerd | 2.2.0+ (NRI with `AdjustArgs` support) |
| Go | 1.23+ |
| nono binary | [nono releases](https://nono.sh) — place at `./nono` before building |

> **Note:** The nono binary is dynamically linked against glibc (`libdbus-1`). Workload containers
> must have glibc available (ubuntu/debian-based images). Alpine and musl-based images cannot run
> the nono binary.

## Build

```bash
# Place the nono binary at the repo root first
ls ./nono

# Build the plugin binary
make build           # outputs ./10-nono-nri

# Build the Docker image (bundles plugin + nono binary)
make docker-build    # outputs nono-nri:latest
```

## Deploy

### Quick start with Kind

```bash
# CRI-O (full SetArgs support)
RUNTIME=crio bash deploy/kind/deploy.sh

# containerd 2.2+
RUNTIME=containerd bash deploy/kind/deploy.sh
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
kubectl apply -f deploy/runtimeclass.yaml

# Deploy the plugin DaemonSet (copies nono to host via init container)
kubectl apply -f deploy/daemonset.yaml

kubectl rollout status daemonset/nono-nri -n kube-system
```

**4. Apply the RuntimeClass to workloads**

Add `runtimeClassName: nono-sandbox` to any pod spec:

```yaml
spec:
  runtimeClassName: nono-sandbox
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

## E2E Tests

```bash
RUNTIME=crio       CLUSTER_NAME=nono-crio       bash deploy/kind/e2e.sh
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash deploy/kind/e2e.sh
```

## Project Layout

```
cmd/nono-nri/          # plugin entrypoint (main.go)
internal/nri/
  plugin.go            # CreateContainer / RemoveContainer handlers
  adjustments.go       # BuildAdjustment: SetArgs + AddMount
  filter.go            # ShouldSandbox: RuntimeClass matching
  profile.go           # ResolveProfile: annotation → profile name
  config.go            # TOML config loader
  kernel.go            # Landlock kernel version check (≥5.13)
  state.go             # Per-container metadata dir lifecycle
internal/log/          # slog JSON handler factory
deploy/
  daemonset.yaml       # Kubernetes DaemonSet (plugin + init container)
  runtimeclass.yaml    # RuntimeClass: nono-sandbox / handler: nono-runc
  test-pod.yaml        # Sample sandboxed pod for verification
  crio-nri.conf        # CRI-O NRI config snippet
  containerd-config.toml  # containerd NRI config snippet
  kind/                # Kind cluster configs and scripts
```

## License

Apache 2.0
