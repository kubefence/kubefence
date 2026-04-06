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

RUN test -n "$KATA_VERSION" || { echo "KATA_VERSION build-arg is required"; exit 1; }
RUN test -n "$NONO_VERSION" || { echo "NONO_VERSION build-arg is required"; exit 1; }

# ── Build prerequisites ───────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates zstd tar e2tools fdisk \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# ── Download nono binary from release ────────────────────────────────────────
# glibc build matches the confidential guest rootfs (musl not required).
RUN TARBALL="nono-${NONO_VERSION}-x86_64-unknown-linux-gnu.tar.gz" && \
    curl -fsSL \
      "https://github.com/always-further/nono/releases/download/${NONO_VERSION}/${TARBALL}" \
      -o /tmp/nono.tar.gz && \
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
FROM scratch
COPY --from=builder /build/kata-ubuntu-noble-confidential.image /kata-containers-confidential.image
CMD [""]
