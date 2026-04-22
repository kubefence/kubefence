#!/usr/bin/env bash
# build-nono.sh — build a nono binary from source for embedding in the
#                 nono-nri container image.
#
# Default: glibc build (x86_64-unknown-linux-gnu).
#   Built inside rust:1.85-slim-bullseye (Debian Bullseye, glibc 2.31) so the
#   binary runs on any glibc 2.31+ container — ubuntu:20.04+, go, python, node,
#   kata initrd, etc.  Requires Docker.
#   Runtime deps: libc.so.6, libgcc_s.so.1, libm.so.6 only (no libdbus).
#
# Optional: fully static musl build (BUILD_TARGET=musl).
#   No runtime library dependencies, works in scratch/Alpine/distroless.
#   Requires musl-tools (apt-get install -y musl-tools). Does NOT need Docker.
#
# Usage:
#   bash scripts/build-nono.sh                    # glibc (default, needs Docker)
#   BUILD_TARGET=musl bash scripts/build-nono.sh  # static musl
#   NONO_VERSION=v0.23.0 bash scripts/build-nono.sh
#   OUT=/path/to/nono bash scripts/build-nono.sh
set -euo pipefail

NONO_VERSION="${NONO_VERSION:-v0.23.0}"
# Expected commit SHA for NONO_VERSION — prevents mutable tag substitution.
# Update this when bumping NONO_VERSION.  Leave empty only for local dev.
NONO_COMMIT="${NONO_COMMIT:-}"
NONO_REPO="${NONO_REPO:-https://github.com/always-further/nono.git}"
BUILD_TARGET="${BUILD_TARGET:-glibc}"   # "glibc" | "musl"
OUT="${OUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nono}"
BUILD_DIR=$(mktemp -d /tmp/nono-build-XXXXXX)

cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

echo "==> Cloning nono @ ${NONO_VERSION}..."
git clone --depth 1 --branch "${NONO_VERSION}" "$NONO_REPO" "$BUILD_DIR/src"

if [[ -n "$NONO_COMMIT" ]]; then
  ACTUAL_COMMIT=$(git -C "$BUILD_DIR/src" rev-parse HEAD)
  if [[ "$ACTUAL_COMMIT" != "$NONO_COMMIT" ]]; then
    echo "ERROR: nono commit mismatch: tag ${NONO_VERSION} resolves to ${ACTUAL_COMMIT} but expected ${NONO_COMMIT}" >&2
    echo "       The tag may have been force-pushed. Verify the repository and update NONO_COMMIT." >&2
    exit 1
  fi
  echo "==> Commit verified: ${ACTUAL_COMMIT}"
fi

echo "==> Patching: disable dbus (sync-secret-service) → no-op keyring backend..."
# The sync-secret-service feature requires libdbus-1 at runtime, which breaks
# inside minimal containers. We disable it; credential operations are never
# used by nono-nri (only `nono wrap --profile` is invoked).
for toml in nono nono-cli; do
  sed -i \
    's/keyring = { version = "3", features = \["sync-secret-service"\] }/keyring = { version = "3", default-features = false }/' \
    "$BUILD_DIR/src/crates/${toml}/Cargo.toml"
done

if [[ "$BUILD_TARGET" == "musl" ]]; then
  echo "==> Patching: fix ioctl types for musl (libc::Ioctl vs c_ulong)..."
  # musl's ioctl takes c_int; glibc takes c_ulong. Use the platform-neutral
  # libc::Ioctl alias with explicit u32 truncation for the ioctl request codes.
  LINUX_RS="$BUILD_DIR/src/crates/nono/src/sandbox/linux.rs"
  for const in SECCOMP_IOCTL_NOTIF_RECV SECCOMP_IOCTL_NOTIF_SEND \
               SECCOMP_IOCTL_NOTIF_ID_VALID SECCOMP_IOCTL_NOTIF_ADDFD; do
    sed -i "s/const ${const}: libc::c_ulong = \(0x[0-9a-f]*\);/const ${const}: libc::Ioctl = \1u32 as libc::Ioctl;/" \
      "$LINUX_RS"
  done
  PTY_MUX="$BUILD_DIR/src/crates/nono-cli/src/exec_strategy/pty_mux.rs"
  sed -i \
    's/libc::TIOCSCTTY as libc::c_ulong/libc::TIOCSCTTY as libc::Ioctl/' \
    "$PTY_MUX"

  echo "==> Patching: fix O_PATH stripping in landlock PathFd::new on musl..."
  # On musl, O_ACCMODE = 0o10000003 (includes O_PATH bits 0o10000000), so
  # OpenOptions::custom_flags() silently strips O_PATH via !O_ACCMODE masking.
  # Without O_PATH, open("/dev/tty") fails ENXIO inside containers (no TTY).
  # Fix: patch landlock's PathFd::new to call libc::open() directly.
  cd "$BUILD_DIR/src"
  cargo fetch --quiet 2>/dev/null || true
  LANDLOCK_VER=$(grep -A3 'name = "landlock"' Cargo.lock | grep '^version' | head -1 | sed 's/version = "\(.*\)"/\1/')
  LANDLOCK_SRC=$(find "${CARGO_HOME:-$HOME/.cargo}/registry/src" \
    -maxdepth 2 -type d -name "landlock-${LANDLOCK_VER}" 2>/dev/null | head -1)
  if [ -z "$LANDLOCK_SRC" ]; then
    echo "ERROR: landlock-${LANDLOCK_VER} not found in cargo registry" >&2; exit 1
  fi
  mkdir -p "$BUILD_DIR/landlock-patch"
  cp -r "$LANDLOCK_SRC/." "$BUILD_DIR/landlock-patch/"

  python3 - "$BUILD_DIR/landlock-patch/src/fs.rs" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
old = (
    "Ok(PathFd {\n"
    "            fd: OpenOptions::new()\n"
    "                .read(true)\n"
    "                // If the O_PATH is not supported, it is automatically ignored (Linux < 2.6.39).\n"
    "                .custom_flags(libc::O_PATH | libc::O_CLOEXEC)\n"
    "                .open(path.as_ref())\n"
    "                .map_err(|e| PathFdError::OpenCall {\n"
    "                    source: e,\n"
    "                    path: path.as_ref().into(),\n"
    "                })?\n"
    "                .into(),\n"
    "        })"
)
new = (
    "// Use raw libc::open so O_PATH is preserved on musl targets.\n"
    "        // On musl, O_ACCMODE = 0o10000003 (includes O_PATH bits), so\n"
    "        // OpenOptions::custom_flags() silently strips O_PATH via !O_ACCMODE.\n"
    "        use std::ffi::CString;\n"
    "        use std::os::unix::ffi::OsStrExt;\n"
    "        use std::os::unix::io::FromRawFd;\n"
    "        let c_path = CString::new(path.as_ref().as_os_str().as_bytes())\n"
    "            .map_err(|_| PathFdError::OpenCall {\n"
    "                source: std::io::Error::from_raw_os_error(libc::EINVAL),\n"
    "                path: path.as_ref().into(),\n"
    "            })?;\n"
    "        let raw_fd = unsafe { libc::open(c_path.as_ptr(), libc::O_PATH | libc::O_CLOEXEC) };\n"
    "        if raw_fd < 0 {\n"
    "            return Err(PathFdError::OpenCall {\n"
    "                source: std::io::Error::last_os_error(),\n"
    "                path: path.as_ref().into(),\n"
    "            });\n"
    "        }\n"
    "        Ok(PathFd { fd: unsafe { OwnedFd::from_raw_fd(raw_fd) } })"
)
if old not in src:
    print(f"WARNING: PathFd::new pattern not found in {path} — skipping patch")
    sys.exit(0)
src = src.replace(old, new)
if "use std::os::fd::OwnedFd;" not in src and "OwnedFd" not in src.split("impl PathFd")[0]:
    src = src.replace("use std::fs::OpenOptions;", "use std::fs::OpenOptions;\nuse std::os::fd::OwnedFd;", 1)
with open(path, "w") as f:
    f.write(src)
print(f"Patched {path}")
PYEOF

  cat >> "$BUILD_DIR/src/Cargo.toml" << TOMLEOF

[patch.crates-io]
landlock = { path = "$BUILD_DIR/landlock-patch" }
TOMLEOF
fi

if [[ "$BUILD_TARGET" == "musl" ]]; then
  echo "==> Installing musl Rust target..."
  rustup target add x86_64-unknown-linux-musl

  echo "==> Building nono (musl)..."
  cd "$BUILD_DIR/src"
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc \
  AWS_LC_SYS_STATIC=1 \
    cargo build --release --target x86_64-unknown-linux-musl -p nono-cli
  BINARY="$BUILD_DIR/src/target/x86_64-unknown-linux-musl/release/nono"
else
  # Build inside a Debian Bullseye container (glibc 2.31) so the binary runs on
  # any glibc 2.31+ workload image regardless of the host's glibc version.
  BUILD_IMAGE="rust:1.85-slim-bullseye"
  echo "==> Building nono (glibc) inside ${BUILD_IMAGE}..."
  CARGO_REGISTRY="${CARGO_HOME:-$HOME/.cargo}/registry"
  mkdir -p "$CARGO_REGISTRY"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$BUILD_DIR/src:/src" \
    -v "$CARGO_REGISTRY:/usr/local/cargo/registry" \
    -e CARGO_HOME=/usr/local/cargo \
    "$BUILD_IMAGE" \
    bash -c "set -euo pipefail && cd /src && cargo build --release -p nono-cli"
  BINARY="$BUILD_DIR/src/target/release/nono"
fi

if [[ "$BUILD_TARGET" == "musl" ]]; then
  ldd "$BINARY" | grep -q "statically linked" \
    || { echo "ERROR: binary is not statically linked"; ldd "$BINARY"; exit 1; }
else
  if ldd "$BINARY" | grep -q "libdbus\|libsystemd"; then
    echo "ERROR: glibc binary still links against libdbus or libsystemd" >&2
    ldd "$BINARY" >&2; exit 1
  fi
fi

cp "$BINARY" "$OUT"
echo "==> Done: $OUT ($(du -sh "$OUT" | cut -f1), ${BUILD_TARGET})"
