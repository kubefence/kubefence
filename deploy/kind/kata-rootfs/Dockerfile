# syntax=docker/dockerfile:1
#
# Builds a customised Kata Containers confidential guest rootfs
# image that includes the nono Landlock sandbox binary and a kata-agent
# OPA enforcement policy.
#
# The source image is kata-containers-confidential.img located at
# ./opt/kata/share/kata-containers/ in the kata-static release tarball.
# The real file (kata-ubuntu-noble-confidential.image) is extracted; the
# ext4 partition is modified using dd + debugfs — no loop mount or root
# privileges required.
#
# The nono binary is installed at /nono/nono (matching the path used by the
# NRI plugin's SetArgs).  The OPA policy at /etc/kata-opa/default-policy.rego
# controls exec access inside the Kata VM.
#
# Usage:
#   docker build \
#     --build-arg KATA_VERSION=3.28.0 \
#     --build-arg NONO_VERSION=v0.23.0 \
#     -t ghcr.io/yourorg/kata-rootfs-nono:3.28.0-v0.23.0 \
#     deploy/kind/kata-rootfs/
#
# The resulting image (FROM scratch) contains a single file:
#   /kata-containers-confidential.image
# Extract with:
#   id=$(docker create <image>); docker cp $id:/kata-containers-confidential.image .; docker rm $id

ARG KATA_VERSION
ARG NONO_VERSION

FROM ubuntu:24.04 AS builder

ARG KATA_VERSION
ARG NONO_VERSION
# SHA256 of nono-${NONO_VERSION}-x86_64-unknown-linux-gnu.tar.gz.
# Obtain with: sha256sum nono-<ver>-x86_64-unknown-linux-gnu.tar.gz
# Must be updated whenever NONO_VERSION changes.
ARG NONO_SHA256

RUN test -n "$KATA_VERSION" || { echo "KATA_VERSION build-arg is required"; exit 1; }
RUN test -n "$NONO_VERSION" || { echo "NONO_VERSION build-arg is required"; exit 1; }

# ── Build prerequisites ───────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates zstd tar e2tools fdisk \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# ── Download nono binary from release ────────────────────────────────────────
# glibc build matches the confidential guest rootfs (musl not required).
# NONO_SHA256 must be supplied at build time to verify the tarball integrity.
RUN test -n "$NONO_SHA256" || { echo "NONO_SHA256 build-arg is required"; exit 1; }
RUN TARBALL="nono-${NONO_VERSION}-x86_64-unknown-linux-gnu.tar.gz" && \
    curl -fsSL \
      "https://github.com/always-further/nono/releases/download/${NONO_VERSION}/${TARBALL}" \
      -o /tmp/nono.tar.gz && \
    echo "${NONO_SHA256}  /tmp/nono.tar.gz" | sha256sum -c - && \
    tar xzf /tmp/nono.tar.gz -C /tmp/ && \
    NONO_BIN=$(find /tmp -maxdepth 3 -name nono -type f | head -1) && \
    test -n "$NONO_BIN" || { echo "nono binary not found in tarball"; exit 1; } && \
    cp "$NONO_BIN" /build/nono && \
    chmod 0755 /build/nono && \
    rm /tmp/nono.tar.gz

# ── Download and extract confidential rootfs image ───────────────────────────
# Stream-extract just the image file from the large kata-static tarball to
# avoid downloading and storing the full ~1 GB archive.
# Extract the real file (kata-ubuntu-noble-confidential.image) by its tarball path,
# not the symlink (kata-containers-confidential.img) — tar --to-stdout on a symlink
# returns 0 bytes silently.
RUN echo "Downloading kata-static-${KATA_VERSION}-amd64.tar.zst (streaming)..." && \
    curl -fsSL \
      "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.zst" \
    | zstd -d \
    | tar --to-stdout -x \
        "./opt/kata/share/kata-containers/kata-ubuntu-noble-confidential.image" \
    > /build/kata-ubuntu-noble-confidential.image && \
    ls -lh /build/kata-ubuntu-noble-confidential.image

# ── Inject nono binary and OPA policy ────────────────────────────────────────
COPY inject.sh /build/inject.sh
COPY policy.rego /build/policy.rego
RUN chmod +x /build/inject.sh && \
    /build/inject.sh /build/kata-ubuntu-noble-confidential.image /build/nono /build/policy.rego

# ── Minimal final image ───────────────────────────────────────────────────────
# A statically-linked cp from busybox-uclibc is included so this image can
# be used directly as a Kubernetes init container:
#
#   initContainers:
#     - name: install-kata-rootfs
#       image: ghcr.io/<org>/kata-rootfs-nono:<version>
#       args: ["/mnt/kata-share/kata-confidential-nono.image"]
#       volumeMounts:
#         - name: kata-share
#           mountPath: /mnt/kata-share
#
# The ENTRYPOINT is "cp /kata-containers-confidential.image"; args supplies
# the destination. For dev extraction with docker: docker create + docker cp
# still works unchanged.
FROM busybox:1.37.0-uclibc AS busybox-static
FROM scratch
COPY --from=busybox-static /bin/cp /bin/cp
COPY --from=builder /build/kata-ubuntu-noble-confidential.image /kata-containers-confidential.image
ENTRYPOINT ["/bin/cp", "/kata-containers-confidential.image"]
CMD [""]
