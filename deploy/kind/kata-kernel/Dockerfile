# syntax=docker/dockerfile:1
#
# Builds the kata-containers guest kernel with CONFIG_SECURITY_LANDLOCK=y.
#
# The kata-bundled kernel ships with Landlock disabled.  This image rebuilds
# from kata's own source + patches using kata's fragment system, adding our
# Landlock fragment (configs/fragments/x86_64/landlock.conf) before the
# merge so it is assembled alongside all other kata config fragments.
#
# The kata-shipped initrd works unchanged alongside this kernel: virtiofs
# and vsock are built-in (=y) in the kata kernel config.
#
# Usage:
#   docker build \
#     --build-arg KATA_VERSION=3.14.0 \
#     -t ghcr.io/yourorg/kata-kernel-landlock:3.14.0 \
#     deploy/kind/kata-kernel/
#
# The resulting image (FROM scratch) contains a single file: /vmlinux
# Extract with:
#   id=$(docker create <image>); docker cp $id:/vmlinux ./vmlinux; docker rm $id

ARG KATA_VERSION
FROM ubuntu:24.04 AS builder

ARG KATA_VERSION
RUN test -n "$KATA_VERSION" || { echo "KATA_VERSION build-arg is required"; exit 1; }

# ── Build prerequisites ───────────────────────────────────────────────────────
# yq is pinned to a specific version and SHA256-verified to prevent a mutable
# "latest" URL from delivering a compromised binary into the kernel build.
ENV YQ_VERSION=v4.44.3 \
    YQ_SHA256=a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential flex bison libssl-dev libelf-dev bc dwarves \
        libncurses-dev rsync cpio curl git wget ca-certificates \
    && wget -qO /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    && echo "${YQ_SHA256}  /usr/local/bin/yq" | sha256sum -c - \
    && chmod +x /usr/local/bin/yq \
    && rm -rf /var/lib/apt/lists/*

# ── Sparse-clone kata packaging tools at the requested release tag ────────────
RUN git clone --depth 1 --filter=blob:none --sparse \
        -b "${KATA_VERSION}" \
        https://github.com/kata-containers/kata-containers \
        /build/kata-src \
    && cd /build/kata-src \
    && git sparse-checkout set \
        tools/packaging/kernel \
        tools/packaging/scripts \
    && git show HEAD:versions.yaml > versions.yaml \
    && git show HEAD:VERSION > VERSION

# ── Inject our Landlock config fragment ──────────────────────────────────────
# Copying before build-kernel.sh setup means merge_config.sh picks it up
# automatically alongside all other x86_64 fragments.
COPY configs/fragments/x86_64/landlock.conf \
     /build/kata-src/tools/packaging/kernel/configs/fragments/x86_64/landlock.conf

WORKDIR /build/kata-src/tools/packaging/kernel

# ── Set up kernel source: download tarball, apply patches, merge all fragments ─
# build-kernel.sh reads the Linux version from versions.yaml via yq and merges
# every *.conf in configs/fragments/x86_64/ (including our landlock.conf) via
# the kernel's scripts/kconfig/merge_config.sh.
RUN ARCH=x86_64 ./build-kernel.sh setup

# ── Prepend 'landlock' to CONFIG_LSM ─────────────────────────────────────────
# CONFIG_SECURITY_LANDLOCK=y (from the fragment) compiles Landlock in, but the
# LSM must also appear in CONFIG_LSM to be initialised at boot.  CONFIG_LSM is
# a string option; merge_config.sh last-value-wins semantics make it unsafe to
# set it in a fragment without knowing kata's full LSM list, so we patch it
# here after the merge and re-run olddefconfig to resolve any new dependencies.
RUN set -e; \
    KERN_SRC=$(ls -d kata-linux-* | head -1); \
    cd "$KERN_SRC"; \
    CURRENT_LSM=$(./scripts/config --state LSM 2>/dev/null | tr -d '"'); \
    if [ -z "$CURRENT_LSM" ]; then \
        ./scripts/config --set-str LSM "landlock"; \
    elif ! echo "$CURRENT_LSM" | grep -q "landlock"; then \
        ./scripts/config --set-str LSM "landlock,$CURRENT_LSM"; \
    fi; \
    make ARCH=x86_64 olddefconfig

# ── Build vmlinux ─────────────────────────────────────────────────────────────
# QEMU uses direct kernel boot with an ELF vmlinux — bzImage is not needed.
RUN set -e; \
    KERN_SRC=$(ls -d kata-linux-* | head -1); \
    cd "$KERN_SRC"; \
    make ARCH=x86_64 -j"$(nproc)" vmlinux; \
    cp vmlinux /build/vmlinux

# ── Minimal final image ───────────────────────────────────────────────────────
# A statically-linked cp from busybox-uclibc is included so this image can
# be used directly as a Kubernetes init container:
#
#   initContainers:
#     - name: install-kata-kernel
#       image: ghcr.io/<org>/kata-kernel-landlock:<version>
#       args: ["/mnt/kata-share/vmlinux-landlock.container"]
#       volumeMounts:
#         - name: kata-share
#           mountPath: /mnt/kata-share
#
# The ENTRYPOINT is "cp /vmlinux"; args supplies the destination.
# For dev extraction with docker: docker create + docker cp still works.
FROM busybox:1.37.0-uclibc AS busybox-static
FROM scratch
COPY --from=busybox-static /bin/cp /bin/cp
COPY --from=builder /build/vmlinux /vmlinux
ENTRYPOINT ["/bin/cp", "/vmlinux"]
CMD [""]
