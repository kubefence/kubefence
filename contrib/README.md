# contrib — nono sandbox profile examples

Examples demonstrating nono sandboxing on Kubernetes using `nono wrap` (direct mode).
Each example shows a clear before/after comparison: an unsandboxed baseline pod vs the
same workload running inside a nono Landlock sandbox.

## What nono wrap enforces

`nono wrap` applies a **Linux Landlock filesystem sandbox** to the container process.
The `default` profile (wrap-compatible) restricts:

| Access type                        | Baseline | nono sandbox |
|------------------------------------|----------|--------------|
| Write to `/etc/*` (host poisoning) | ALLOWED  | **BLOCKED**  |
| Write to `/usr/local/bin` (backdoor) | ALLOWED | **BLOCKED** |
| Read `/etc/shadow` (credential theft) | ALLOWED | **BLOCKED** |
| Read `/etc/passwd` (user enumeration) | ALLOWED | **BLOCKED** |
| Write to Python site-packages (pkg inject) | ALLOWED | **BLOCKED** |
| Python / Node / Go runtime         | ALLOWED  | **ALLOWED**  |
| Write to `/tmp` (scratch space)    | ALLOWED  | **ALLOWED**  |

> **Note on dev profiles:** The `python-dev`, `node-dev`, and `go-dev` built-in profiles
> enable network proxy filtering, which requires `nono run` (supervisor mode).
> They are **not compatible with `nono wrap`** (direct mode). Use the `default` profile
> (or a custom TOML profile without network proxy) with `nono wrap`.

## Profiles covered

| Directory    | Profile  | Sandbox mode     | Container image     |
|--------------|----------|------------------|---------------------|
| `python-dev` | default  | nono wrap        | python:3.12-slim    |
| `node-dev`   | default  | nono wrap        | node:20-slim        |
| `go-dev`     | default  | nono wrap        | golang:1.23-bookworm|

## Prerequisites

- Kind cluster(s) deployed via `deploy/kind/deploy.sh`
- `kubectl` context pointing at the target cluster
- `docker` and `kind` in PATH
- nono-nri DaemonSet running: `kubectl rollout status daemonset/nono-nri -n kube-system`

> **Image requirement:** Demo images are Debian-based with `libdbus-1-3`, which the
> nono binary requires at runtime. Alpine / musl images cannot run the nono binary.

## Quick start

```bash
# containerd cluster (default)
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash contrib/python-dev/demo.sh
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash contrib/node-dev/demo.sh
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash contrib/go-dev/demo.sh

# CRI-O cluster
RUNTIME=crio CLUSTER_NAME=nono-crio bash contrib/python-dev/demo.sh
```

## Recorded demo

An asciinema recording of the python-dev example (containerd cluster) is included:

```bash
asciinema play contrib/python-dev/demo.cast
```

## Manual apply

```bash
# Build and load the image (containerd example)
docker build -t nono-demo-python:latest contrib/python-dev/
docker save nono-demo-python:latest | \
  docker exec -i nono-containerd-control-plane ctr -n k8s.io images import -

# Run both jobs and compare
kubectl apply -f contrib/python-dev/job-baseline.yaml
kubectl apply -f contrib/python-dev/job-sandbox.yaml

kubectl wait --for=condition=complete job/python-dev-baseline --timeout=120s
kubectl wait --for=condition=complete job/python-dev-sandbox  --timeout=120s

kubectl logs job/python-dev-baseline
kubectl logs job/python-dev-sandbox

# Cleanup
kubectl delete job python-dev-baseline python-dev-sandbox
```
