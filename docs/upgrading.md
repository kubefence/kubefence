# Upgrading

kubefence is a proof of concept, and until 1.0 a release may change the node
contract — RuntimeClass handlers, containerd config layout, guest artefacts. This
page records what changed per release and what it costs to move.

## Versioning contract

| Artefact | Version |
|----------|---------|
| Helm chart | The release tag, `v` stripped (`v0.8.0` → chart `0.8.0`) |
| Plugin image | `ghcr.io/kubefence/nono-nri-plugin:<same>` |
| Guest extension image | `ghcr.io/kubefence/kata-nono-extension:<same>` (also published `v`-prefixed) |

The chart's `appVersion` is stamped with that version, and both image references
default to it. So `--version 0.8.0` pins the chart, the plugin image, and the
extension image together, and there is exactly one number to move:

```bash
helm upgrade kubefence oci://ghcr.io/kubefence/charts/kubefence \
  --version 0.8.0 --namespace kube-system --reuse-values
```

Override `image.tag` or `kata.extensionImage` only for local builds or to pin a
digest. `--reuse-values` then carries that override forward, which is what you
want for a private registry and not what you want for a stale tag.

## 0.7.x — breaking

Not upgradeable in place from 0.6.x. Uninstall and reinstall.

**What changed on the node:**

| | 0.6.x | 0.7.x |
|---|---|---|
| Kata shim | Go runtime (`kata-qemu`) | runtime-rs (`kata-qemu-runtime-rs`) — the kata 4.0 default |
| kubefence Kata handler | `kata-nono-qemu` on a custom guest | `kata-nono-qemu` on the **stock** guest + extension image |
| Guest kernel | custom build with `CONFIG_SECURITY_LANDLOCK=y` | stock kata guest kernel, unmodified |
| kata-agent policy delivery | injected into a rebuilt rootfs | erofs extension image, cold-plugged as read-only virtio-blk |
| containerd handler registration | appended to `/etc/containerd/config.toml` | drop-ins at `/etc/containerd/conf.d/{40-nono-runc,50-nono-kata}.toml` |
| Minimum Kata version | 3.x | **4.0.0** |

Two consequences worth calling out:

- **The handler your RuntimeClass points at changed.** kata-deploy must now be
  installed with the `qemu-runtime-rs` shim, which registers
  `kata-qemu-runtime-rs` instead of `kata-qemu`. Any RuntimeClass, admission
  policy, or `config.runtimeClasses` entry naming `kata-qemu` no longer matches
  anything, and pods using it fail with
  `no runtime for "kata-qemu" is configured`.
- **Nothing rebuilds guest artefacts any more.** The custom kernel and rootfs
  build paths are gone (along with their CI workflows). Kata 4.0 ships Landlock in
  every guest kernel and supports composable images, so the stock artefacts are
  used as they arrive.

### Recipe

```bash
# 1. Remove the old install
helm uninstall kubefence -n kube-system

# 2. Clean the node — the setup DaemonSets do not undo themselves
#    (on each node)
sudo rm -f /etc/containerd/conf.d/40-nono-runc.toml \
           /etc/containerd/conf.d/50-nono-kata.toml
sudo rm -rf /opt/nono-nri /run/kubefence
sudo systemctl restart containerd

# 3. Reinstall kata-deploy on the runtime-rs shim
helm upgrade --install kata-deploy \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version 4.0.0 --namespace kube-system \
  --set k8sDistribution=k8s \
  --set shims.disableAll=true \
  --set 'shims.qemu-runtime-rs.enabled=true' \
  --set defaultShim.amd64=qemu-runtime-rs \
  --wait --timeout 10m

# 4. Install kubefence — see Installation for the full flag set
```

If 0.6.x left an appended stanza inside `/etc/containerd/config.toml`, remove it
by hand: only drop-ins are managed now, so nothing will clean it up, and a stale
`kata-qemu` handler block there is a live footgun.

Then repoint workloads. The RuntimeClass names (`nono-runc`,
`kata-nono-sandbox`) are unchanged, so pods usually need no edit — but anything
that names a *handler* does.

## Why an upgrade can require a reinstall

Two classes of change cannot be rolled forward, and both fail loudly:

- **Immutable Kubernetes fields.** A DaemonSet's `spec.selector` cannot be
  changed. `helm upgrade` across such a change fails with
  `field is immutable` and leaves the old objects in place.
- **Node-level state the chart wrote earlier.** Drop-ins, the nono binary, kata
  config copies and the extension image live on the host, outside Helm's release
  state. Helm neither removes nor rewrites what an older version left behind.

Anything in the second class is a `rm` on the node; the first needs
`helm uninstall` first. Both are listed per release above when they apply.

## Groundwork already in place

Steps taken so that future releases are ordinary `helm upgrade`s:

- **One version to bump.** Chart, plugin image, and extension image versions are
  derived from `appVersion` rather than tracking `latest` independently.
- **Stable selectors.** The plugin DaemonSet carries
  `app.kubernetes.io/component: plugin`, so `kubectl logs -l
  app.kubernetes.io/component=plugin` and every script that selects the plugin
  keep working. Before this label existed the plugin's selector was a subset of
  the setup DaemonSets' labels, and `kubectl logs ds/kubefence` resolved to a
  setup pod. Adding it to the selector was itself an uninstall/reinstall — done
  once, inside a release that already required one.
- **Drop-ins instead of appends.** Each writer owns a file under
  `/etc/containerd/conf.d/`, rewritten rather than appended, so re-running is
  idempotent and undoing is a delete. Config appends could neither be updated nor
  removed safely.
- **A startup gate instead of a race.** The plugin waits for the setup
  DaemonSets' markers, so a containerd restart during an upgrade no longer leaves
  a window where pods start un-sandboxed. See
  [Startup ordering](architecture.md#startup-ordering).

## Rehearsing an upgrade

`deploy/kubeadm/` brings up a throwaway single-node cluster with a **stock**
containerd config, which is the one thing the kind harness cannot check (kind
ships a `version = 2` config; a real node is `version = 3`, and the CRI plugin is
named differently in each). Rehearse there before rolling a release out.
