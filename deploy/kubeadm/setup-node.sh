#!/usr/bin/env bash
# setup-node.sh — provision a single-node kubeadm cluster on a throwaway VM, to
#                 test kubefence against a *stock* containerd instead of kind.
#
# Why this exists, and why the kind suite is not enough:
#
#   kind's node image ships `version = 2` in /etc/containerd/config.toml (it says
#   so in a comment) and containerd migrates that schema at load time. A stock
#   containerd 2.x config — what `containerd config default` writes, and what a
#   kubeadm node therefore runs — is `version = 3`, where the CRI runtime plugin
#   is named io.containerd.cri.v1.runtime rather than io.containerd.grpc.v1.cri.
#   A drop-in using the wrong name is parsed, logged as "Ignoring unknown key in
#   TOML for plugin", and silently registers nothing; pods then fail with
#   `no runtime for "<handler>" is configured`.
#
#   The kind e2e cannot see that: it only ever exercises the schema where the old
#   name works. This harness is the only way to catch the whole class, so run it
#   before a release that touches how containerd config is written.
#
# Scope: node provisioning only — containerd, kubeadm, a CNI, and a local
# registry to push locally-built images into. Installing kata-deploy and the
# kubefence chart on top is in README.md, along with the checks worth making.
#
# Tested on Ubuntu 24.04 (amd64) with nested virtualisation available. It rewrites
# /etc/containerd/config.toml and installs packages system-wide, so point it at a
# VM you are willing to lose — never a workstation or a real node.
#
# Usage:
#   bash deploy/kubeadm/setup-node.sh
#   K8S_MINOR=v1.34 bash deploy/kubeadm/setup-node.sh
#   FORCE=1 bash deploy/kubeadm/setup-node.sh    # re-run over an existing cluster
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-v1.33}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
FORCE="${FORCE:-0}"

export DEBIAN_FRONTEND=noninteractive

if [[ -f /etc/kubernetes/admin.conf && "$FORCE" != "1" ]]; then
  echo "ERROR: /etc/kubernetes/admin.conf exists — this host already runs a cluster." >&2
  echo "       This script rewrites /etc/containerd/config.toml. Re-run with FORCE=1" >&2
  echo "       only if this is a throwaway VM." >&2
  exit 1
fi

NODE_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
REGISTRY="${NODE_IP}:${REGISTRY_PORT}"
echo "==> node ${NODE_NAME} (${NODE_IP}), kubernetes ${K8S_MINOR}, registry ${REGISTRY}"

# ── Kernel prerequisites ──────────────────────────────────────────────────────
printf 'overlay\nbr_netfilter\n' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-kubernetes.conf >/dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# A few kata shims exhaust the default 128 inotify instances; pods then hang in
# ContainerCreating with "Creating watcher returned error too many open files".
# Written to sysctl.d rather than applied with `sysctl -w`, which does not survive
# a reboot.
sudo tee /etc/sysctl.d/99-kata-inotify.conf >/dev/null <<EOF
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 1048576
EOF
sudo sysctl --system >/dev/null
sudo swapoff -a

# ── Packages ──────────────────────────────────────────────────────────────────
# docker is here only to build images and host the registry; it and kubelet share
# the one containerd.io daemon, so `docker save` output can be imported straight
# into the k8s.io namespace.
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg apt-transport-https make jq
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update -qq
sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl >/dev/null
sudo usermod -aG docker "$USER"

# ── containerd: the stock default config, CRI enabled ─────────────────────────
# The generated default is what makes this harness worth running: version = 3,
# with an imports glob for /etc/containerd/conf.d already present. Only the cgroup
# driver is changed, to match kubelet's default.
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Let both daemons use a plain-HTTP local registry: docker to push, containerd to
# pull. containerd reads per-registry hosts.toml only if config_path names the
# directory, and in the version 3 schema that key lives under the images plugin.
sudo mkdir -p /etc/docker "/etc/containerd/certs.d/${REGISTRY}"
echo "{\"insecure-registries\":[\"${REGISTRY}\"]}" | sudo tee /etc/docker/daemon.json >/dev/null
sudo tee "/etc/containerd/certs.d/${REGISTRY}/hosts.toml" >/dev/null <<EOF
server = "http://${REGISTRY}"
[host."http://${REGISTRY}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
sudo sed -i "s|^\(\s*\)config_path = ''|\1config_path = '/etc/containerd/certs.d'|" \
  /etc/containerd/config.toml
grep -q "certs.d" /etc/containerd/config.toml || {
  echo "ERROR: could not set registry config_path in /etc/containerd/config.toml" >&2
  exit 1
}

sudo systemctl restart containerd
sudo systemctl enable --now containerd docker >/dev/null 2>&1

command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash

# ── Cluster ───────────────────────────────────────────────────────────────────
sudo kubeadm init \
  --pod-network-cidr="${POD_CIDR}" \
  --cri-socket=unix:///run/containerd/containerd.sock \
  --node-name="${NODE_NAME}"

mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# Single node, so it has to run workloads as well as the control plane.
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=300s
kubectl wait --for=condition=Ready "node/${NODE_NAME}" --timeout=300s

# ── Local registry ────────────────────────────────────────────────────────────
if ! docker ps --format '{{.Names}}' | grep -qx registry; then
  sudo docker run -d --restart=always --name registry -p "${REGISTRY_PORT}:5000" registry:2 >/dev/null
fi

echo
echo "==> node ready"
kubectl get nodes -o wide
echo
echo "    containerd config schema: $(grep -m1 '^version' /etc/containerd/config.toml)"
echo "    imports:                  $(grep -m1 '^imports' /etc/containerd/config.toml)"
echo "    registry:                 ${REGISTRY}"
echo
echo "    Next: install kata-deploy and the chart — see deploy/kubeadm/README.md"
