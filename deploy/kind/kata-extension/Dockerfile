# syntax=docker/dockerfile:1
#
# Builds the nono guest extension image: a kata composable-VM-images extension
# (https://github.com/kata-containers/kata-containers/blob/main/docs/design/composable-vm-images.md)
# carrying the hardened kata-agent OPA policy and the agent config that selects
# it.
#
# This replaces rebuilding the kata guest rootfs. The runtime cold-plugs the
# image as a read-only virtio-blk device and the guest mounts it at
# /run/kata-extensions/nono before kata-agent starts, so the stock kata-deploy
# guest image is used byte-for-byte unmodified.
#
# The image is unmeasured on purpose: it carries no dm-verity hash partition and
# the runtime config sets verity_params = "". kata-extension-mount.sh treats the
# on-disk layout as the source of truth and raw-mounts an extension that has no
# hash partition, but refuses to mount one that has a hash partition without
# matching verity params (and vice versa) — so this is a deliberate
# configuration, not a silently downgraded one. Add a verity hash partition here
# if the guest is a confidential VM whose boot must be attested.
#
# erofs is required: kata-extension-mount.sh mounts with `mount -t erofs -o ro`.
# The filesystem is written with no partition table so the mount helper falls
# through to mounting the whole device. It is left uncompressed — the payload is
# a few kB, so compression would only add a decompression dependency.
#
# Usage:
#   docker build -t ghcr.io/yourorg/kata-nono-extension:latest \
#     deploy/kind/kata-extension/
#
# The resulting image (FROM scratch) contains a single file:
#   /kata-nono-extension.img
# Extract with:
#   id=$(docker create <image>); docker cp $id:/kata-nono-extension.img .; docker rm $id

FROM ubuntu:24.04 AS builder

# erofs-utils provides mkfs.erofs, which writes an image from a directory tree
# without root or a loop mount.
RUN apt-get update && apt-get install -y --no-install-recommends \
        erofs-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Laid out relative to the extension mount point (/run/kata-extensions/nono),
# which is what agent-config.toml's policy_file path assumes.
COPY policy.rego agent-config.toml /build/extension/

RUN mkfs.erofs /build/kata-nono-extension.img /build/extension && \
    ls -lh /build/kata-nono-extension.img

# ── Minimal final image ───────────────────────────────────────────────────────
# A statically-linked cp from busybox-uclibc is included so this image can be
# used directly as a Kubernetes init container:
#
#   initContainers:
#     - name: install-kata-extension
#       image: ghcr.io/<org>/kata-nono-extension:<version>
#       args: ["/mnt/kata-share/kata-nono-extension.img"]
#       volumeMounts:
#         - name: kata-share
#           mountPath: /mnt/kata-share
#
# The ENTRYPOINT is "cp /kata-nono-extension.img"; args supplies the
# destination. For dev extraction with docker: docker create + docker cp still
# works unchanged.
FROM busybox:1.37.0-uclibc AS busybox-static
FROM scratch
COPY --from=busybox-static /bin/cp /bin/cp
COPY --from=builder /build/kata-nono-extension.img /kata-nono-extension.img
ENTRYPOINT ["/bin/cp", "/kata-nono-extension.img"]
CMD [""]
