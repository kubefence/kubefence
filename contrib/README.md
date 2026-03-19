# contrib — nono sandbox profile examples

Examples demonstrating nono sandboxing with development profiles using `nono wrap` (direct mode).
Each example runs a Kubernetes Job that tries dangerous shell commands and language-specific
package managers — showing them **blocked** inside the sandbox while the language runtime itself
still works.

## Profiles covered

| Directory    | Profile     | Extra blocked     | Runtime allowed |
|--------------|-------------|-------------------|-----------------|
| `python-dev` | python-dev  | `pip`             | `python3`       |
| `node-dev`   | node-dev    | `npm`             | `node`          |
| `go-dev`     | go-dev      | —                 | `go`            |

All three profiles include the `dangerous_commands` group, which blocks:
`rm`, `dd`, `chmod`, `sudo`, `mkfs`, `kill`, `apt-get`, `apt`, `yum`, `dnf`, `pacman`

## Prerequisites

- Kind cluster(s) deployed via `deploy/kind/deploy.sh`
- `kubectl` context pointing at the target cluster
- `docker` and `kind` in PATH
- nono-nri DaemonSet running: `kubectl rollout status daemonset/nono-nri -n kube-system`

> **Image requirement:** The demo images are Debian-based and include `libdbus-1-3`, which the
> nono binary requires. Alpine / musl-based images cannot run the nono binary.

## Quick start

```bash
# containerd cluster (default)
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash contrib/python-dev/demo.sh
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash contrib/node-dev/demo.sh
RUNTIME=containerd CLUSTER_NAME=nono-containerd bash contrib/go-dev/demo.sh

# CRI-O cluster
RUNTIME=crio CLUSTER_NAME=nono-crio bash contrib/python-dev/demo.sh
RUNTIME=crio CLUSTER_NAME=nono-crio bash contrib/node-dev/demo.sh
RUNTIME=crio CLUSTER_NAME=nono-crio bash contrib/go-dev/demo.sh
```

## What to expect

**Baseline job** (no runtimeClassName): all commands succeed — dangerous ones included.

**Sandbox job** (runtimeClassName: nono-sandbox + dev profile): dangerous commands return
a non-zero exit (blocked by Landlock), while the language runtime executes normally.

```
--- dangerous_commands (expected: BLOCKED) ---
  rm -f /tmp/nono-demo-file                    BLOCKED
  dd if=/dev/zero of=/tmp/dd-out               BLOCKED
  chmod 777 /etc/hostname                      BLOCKED
  pip --version                                BLOCKED
  apt-get install curl                         BLOCKED

--- python-dev runtime (expected: ALLOWED) ---
  python3 --version                            ALLOWED
  python3 -c print                             ALLOWED
```

## Manual apply

Apply the jobs directly without the demo script:

```bash
# Build and load the image first (containerd example)
docker build -t nono-demo-python:latest contrib/python-dev/
docker save nono-demo-python:latest | \
  docker exec -i nono-containerd-control-plane ctr -n k8s.io images import -

# Run both jobs
kubectl apply -f contrib/python-dev/job-baseline.yaml
kubectl apply -f contrib/python-dev/job-sandbox.yaml

# Wait and compare
kubectl wait --for=condition=complete job/python-dev-baseline --timeout=120s
kubectl wait --for=condition=complete job/python-dev-sandbox  --timeout=120s
kubectl logs job/python-dev-baseline
kubectl logs job/python-dev-sandbox

# Cleanup
kubectl delete job python-dev-baseline python-dev-sandbox
```
