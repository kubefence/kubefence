# syntax=docker/dockerfile:1
#
# Builds a customised Kata Containers Ubuntu Noble guest rootfs image that
# includes the nono Landlock sandbox binary and shell wrapper scripts.
#
# The kata-ubuntu-noble.image (256 MiB MBR+ext4 disk image) is extracted
# from the kata-static release tarball.  The ext4 partition is modified
# using dd + debugfs — no loop mount or root privileges required.
#
# Shell wrappers are installed at /usr/local/bin/{sh,bash,ash,dash,
# python3,python,node,ruby,perl}.  The Ubuntu rootfs /etc/environment
# already lists /usr/local/bin before /bin, so `kubectl exec pod -- bash`
# finds the wrapper first and nono is applied without image changes.
#
# The nono binary is installed at /nono/nono (matching the path used by the
# NRI plugin's SetArgs) with a symlink from /usr/local/bin/nono.
#
# Usage:
#   docker build \
#     --build-arg KATA_VERSION=3.28.0 \
#     --build-arg NONO_VERSION=v0.23.0 \
#     -t ghcr.io/yourorg/kata-rootfs-nono:3.28.0-v0.23.0 \
#     deploy/kind/kata-rootfs/
#
# The resulting image (FROM scratch) contains a single file:
#   /kata-ubuntu-noble.image
# Extract with:
#   id=$(docker create <image>); docker cp $id:/kata-ubuntu-noble.image .; docker rm $id

ARG KATA_VERSION
ARG NONO_VERSION

FROM ubuntu:24.04 AS builder

ARG KATA_VERSION
ARG NONO_VERSION

RUN test -n "$KATA_VERSION" || { echo "KATA_VERSION build-arg is required"; exit 1; }
RUN test -n "$NONO_VERSION" || { echo "NONO_VERSION build-arg is required"; exit 1; }

# ── Build prerequisites ───────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates zstd tar e2tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# ── Download nono binary from release ────────────────────────────────────────
# glibc build matches the Ubuntu Noble rootfs (musl not required).
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

# ── Download and extract kata-ubuntu-noble.image ──────────────────────────────
# Stream-extract just the image file from the large kata-static tarball to
# avoid downloading and storing the full ~1 GB archive.
RUN echo "Downloading kata-static-${KATA_VERSION}-amd64.tar.zst (streaming)..." && \
    curl -fsSL \
      "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.zst" \
    | zstd -d \
    | tar --to-stdout -x \
        "./opt/kata/share/kata-containers/kata-ubuntu-noble.image" \
    > /build/kata-ubuntu-noble.image && \
    ls -lh /build/kata-ubuntu-noble.image

# ── Inject nono and wrapper scripts ──────────────────────────────────────────
COPY inject.sh /build/inject.sh
RUN chmod +x /build/inject.sh && \
    /build/inject.sh /build/kata-ubuntu-noble.image /build/nono

# ── Minimal final image ───────────────────────────────────────────────────────
FROM scratch
COPY --from=builder /build/kata-ubuntu-noble.image /kata-ubuntu-noble.image
CMD [""]
