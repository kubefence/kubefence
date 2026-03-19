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

## Interactive pods (manual exec)

`pod-baseline.yaml` and `pod-sandbox.yaml` run `sleep infinity` so you can exec in
and try commands by hand.

```bash
# Build and load image first (see Manual apply below), then:
kubectl apply -f contrib/python-dev/pod-baseline.yaml
kubectl apply -f contrib/python-dev/pod-sandbox.yaml
kubectl wait --for=condition=ready pod/python-dev-baseline pod/python-dev-sandbox --timeout=60s
```

**Baseline** — exec directly, no sandbox:
```bash
kubectl exec -it python-dev-baseline -- bash
# All of the following succeed:
echo "1.2.3.4 evil" >> /etc/hosts
cat /etc/shadow
echo "x" > /usr/local/bin/exploit
python3 --version
```

**Sandbox** — the demo image replaces `/bin/bash` with a nono wrapper (see
`Dockerfile`). When `/nono/nono` is bind-mounted by NRI the wrapper automatically
invokes `nono wrap` before handing off to real bash, so plain exec just works:

```bash
kubectl exec -it python-dev-sandbox -- bash   # sandboxed automatically
# Inside:
echo "1.2.3.4 evil" >> /etc/hosts   # Permission denied (BLOCKED)
cat /etc/shadow                      # Permission denied (BLOCKED)
python3 --version                    # ALLOWED
echo "ok" > /tmp/workfile            # ALLOWED
```

> **Why this works:** `kubectl exec` spawns processes with `ppid=0` via the
> container runtime, bypassing the sandboxed PID 1. Simply wrapping `/bin/bash`
> in the image re-applies Landlock for every exec'd shell automatically.
>
> **Production guidance:** for real workloads prefer a distroless / no-shell
> image — NRI wraps the app binary and there is no shell to exec into at all.
> Use Kubernetes ephemeral debug containers (`kubectl debug`) when you need
> temporary shell access.

Cleanup:
```bash
kubectl delete pod python-dev-baseline python-dev-sandbox
```

## Manual apply (automated Jobs)

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
