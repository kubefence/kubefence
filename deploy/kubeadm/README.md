# Testing kubefence on a stock containerd node

`deploy/kind/` is the everyday test harness. This directory covers the one thing
kind structurally cannot check: behaviour against a **stock containerd
configuration**.

## Why a second harness

kind's node image ships `version = 2` in `/etc/containerd/config.toml`, and
containerd migrates that schema when it loads it (`Configuration migrated from
version 2, use 'containerd config migrate' to avoid migration`). A stock
containerd 2.x config — what `containerd config default` writes, and therefore
what a kubeadm node runs — is `version = 3`. The two schemas name the CRI runtime
plugin differently:

| config schema | CRI runtime plugin |
| --- | --- |
| `version = 2` | `io.containerd.grpc.v1.cri` |
| `version = 3` | `io.containerd.cri.v1.runtime` |

A drop-in written under the wrong name is parsed and then discarded. containerd
logs `Ignoring unknown key in TOML for plugin`, registers no handler, and pods
fail with `no runtime for "<handler>" is configured`. The kind suite passes
29/29 regardless, because it only ever exercises the schema where the old name
works.

That is not hypothetical: it shipped, and was found only by deploying to a
kubeadm node. Run this harness before releasing a change to how containerd
config is written. `kubefence.criPluginName` in the chart and `CRI_PLUGIN_NAME`
in `deploy/kind/deploy.sh` pick the name from the config being patched, so both
schemas need exercising — kind covers version 2, this covers version 3.

## Requirements

- A throwaway VM — the script rewrites `/etc/containerd/config.toml` and installs
  packages system-wide. It refuses to run where `/etc/kubernetes/admin.conf`
  already exists unless `FORCE=1`.
- Ubuntu 24.04, amd64, 4 vCPU / 8 GB / 40 GB or better.
- Nested virtualisation for the Kata paths: `/dev/kvm` present and `vmx`/`svm` in
  `/proc/cpuinfo`.

## 1. Provision the node

```bash
bash deploy/kubeadm/setup-node.sh          # K8S_MINOR=v1.34 to pin another minor
```

Installs containerd (stock default config), kubeadm, a single-node cluster with
flannel, and a plain-HTTP registry on `<node-ip>:5000` for locally built images.
It prints the config schema and registry address when it finishes.

## 2. Build and push the images

Nothing is published to a public registry yet, so build both locally. The nono
binary must be glibc-based and so must any workload image you test with.

```bash
REG=<node-ip>:5000
make nono-build
make docker-build IMAGE=$REG/nono-nri:latest
docker build -t $REG/kata-nono-extension:latest deploy/kata-extension
docker push $REG/nono-nri:latest
docker push $REG/kata-nono-extension:latest
```

## 3. Install kata-deploy, then the chart

kata-deploy must be fully rolled out first — the chart's `kata-setup` DaemonSet
waits for the QEMU config file to appear.

```bash
helm install kata-deploy -n kube-system --wait --timeout 15m \
  -f deploy/kind/kata-values.yaml \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy --version 4.0.0
kubectl rollout status ds/kata-deploy -n kube-system --timeout=600s

helm upgrade --install kubefence deploy/helm/kubefence -n kube-system \
  --set image.repository=$REG/nono-nri --set image.tag=latest \
  --set kata.enabled=true \
  --set kata.extensionImage=$REG/kata-nono-extension:latest \
  --set runtimeClasses.kataNono.enabled=true \
  --set runtimeClasses.kataNono.handler=kata-nono-qemu \
  --set 'config.runtimeClasses={nono-runc,kata-qemu-runtime-rs,kata-nono-qemu}'
```

Add `--set kata.qemu.machineAccelerators=kernel_irqchip=split` when the node is
itself a VM, as it is under nested KVM.

## 4. Checks that matter

These are the assertions the kind suite cannot make.

```bash
# Handlers declared under the name this config schema actually reads
grep -h 'runtimes\.' /etc/containerd/conf.d/40-nono-runc.toml \
                     /etc/containerd/conf.d/50-nono-kata.toml

# Nothing silently discarded
sudo journalctl -u containerd --since -1h | grep -c "Ignoring unknown key"   # want 0

# The shared file was left alone (a stock config already imports conf.d)
kubectl logs -n kube-system -l app.kubernetes.io/component=node-setup \
  -c configure-containerd     # names the schema version and the plugin chosen

# Both RuntimeClasses actually schedule
kubectl apply -f deploy/kubeadm/verify-pods.yaml
kubectl wait --for=condition=ready pod/v-runc pod/v-kata --timeout=300s
kubectl exec v-runc -- grep ^Seccomp: /proc/self/status                   # want 2
kubectl exec v-kata -- true                                              # want: blocked by policy
kubectl exec v-kata -- /nono/nono wrap --profile default -- ls -l /nono/nono
```

The `v-kata` pair is the discriminator for the guest extension: kata's default
policy is allow-all, so a bare `exec` that is *denied* proves the hardened policy
mounted, and the same command must succeed on the plain `kata-qemu-runtime-rs`
handler.

Re-running the setup DaemonSets should report `already up to date`, leave
`config.toml` untouched, and not restart containerd:

```bash
systemctl show -p MainPID --value containerd
kubectl delete pod -n kube-system -l app.kubernetes.io/component=node-setup
kubectl rollout status ds/kubefence-node-setup -n kube-system
systemctl show -p MainPID --value containerd     # unchanged
```

## Gotchas

- **Use a glibc workload image.** The shipped nono is glibc; an alpine or
  busybox-uclibc image crash-loops with exit 2 and an empty `kubectl logs`.
- **Do not restart containerd by hand while judging injection.** The plugin drops
  its NRI connection and reconnects, but pods created in that window start
  un-injected — visibly `Seccomp: 0` with no `/nono/nono`, while still Running.
- `/proc/1/cmdline` reads back `Permission denied` through the sandbox and a bare `sh -c` fails with
  EACCES (`/nono` is first on PATH). Assert on the host-side OCI bundle, and use
  `printenv`.

## Teardown

```bash
sudo kubeadm reset -f
sudo rm -f /etc/containerd/conf.d/*.toml /etc/cni/net.d/*
sudo systemctl restart containerd
```
