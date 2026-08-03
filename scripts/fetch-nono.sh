#!/usr/bin/env bash
# fetch-nono.sh — fetch the upstream nono release binary for embedding in the
#                 nono-nri container image.
#
# Upstream publishes a dynamically-linked glibc binary per release that needs
# only libc, libgcc_s and libm — no libdbus, no libsystemd — which is exactly
# what building from source used to produce after patching the keyring feature
# out. So there is nothing left for a source build to buy, and this replaces it.
#
# Note the glibc floor: the release binary requires glibc 2.34+ (Ubuntu 22.04,
# Debian 12, RHEL 9). Workload images older than that — ubuntu:20.04,
# debian:11 — cannot run it. Upstream publishes no musl build, so alpine and
# other musl images are not supported either.
#
# Usage:
#   bash scripts/fetch-nono.sh
#   NONO_VERSION=v0.71.0 bash scripts/fetch-nono.sh
#   OUT=/path/to/nono bash scripts/fetch-nono.sh
set -euo pipefail

NONO_VERSION="${NONO_VERSION:-v0.71.0}"
NONO_REPO="${NONO_REPO:-nolabs-ai/nono}"
OUT="${OUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nono}"

# Expected SHA256 of the release tarball for NONO_VERSION on this arch.
# Update when bumping NONO_VERSION. The release also ships SHA256SUMS.txt, but a
# checksum fetched from the same release only detects a corrupted download — this
# pin is what detects the release itself being replaced. Leave empty to skip.
declare -A NONO_SHA256=(
  [x86_64]="9ee2966184e8afa664199c21e089eae596c8d763371a253104623e0f5b0f0a2d"
  [aarch64]="f35f979dab33d604be442304f1945f60bfd7a0e6a5df7dd8c3d43abdcdf921a1"
)

case "$(uname -m)" in
  x86_64)  ARCH=x86_64 ;;
  aarch64) ARCH=aarch64 ;;
  *) echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

TARBALL="nono-${NONO_VERSION}-${ARCH}-unknown-linux-gnu.tar.gz"
URL="https://github.com/${NONO_REPO}/releases/download/${NONO_VERSION}/${TARBALL}"
WORK=$(mktemp -d /tmp/nono-fetch-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading ${TARBALL}..."
curl -fsSL -o "$WORK/$TARBALL" "$URL"

EXPECTED="${NONO_SHA256[$ARCH]:-}"
ACTUAL=$(sha256sum "$WORK/$TARBALL" | cut -d' ' -f1)
if [[ -n "$EXPECTED" ]]; then
  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "ERROR: checksum mismatch for ${TARBALL}" >&2
    echo "       expected ${EXPECTED}" >&2
    echo "       got      ${ACTUAL}" >&2
    echo "       Either the release was replaced, or NONO_SHA256 is stale after a version bump." >&2
    exit 1
  fi
  echo "==> Checksum verified: ${ACTUAL}"
else
  echo "==> WARNING: no pinned checksum for ${ARCH}; got ${ACTUAL}" >&2
fi

tar xzf "$WORK/$TARBALL" -C "$WORK"
BINARY="$WORK/nono"
test -x "$BINARY" || { echo "ERROR: no nono binary in ${TARBALL}" >&2; exit 1; }

# The container images this lands in have no dbus or systemd, and neither does
# any workload image we bind-mount it into.
if ldd "$BINARY" | grep -q "libdbus\|libsystemd"; then
  echo "ERROR: nono links against libdbus or libsystemd" >&2
  ldd "$BINARY" >&2
  exit 1
fi

# Only runs when the host itself meets the glibc floor; skip rather than fail.
if REPORTED=$("$BINARY" --version 2>/dev/null); then
  echo "==> ${REPORTED}"
  [[ "$REPORTED" == *"${NONO_VERSION#v}"* ]] || {
    echo "ERROR: binary reports '${REPORTED}', expected ${NONO_VERSION}" >&2
    exit 1
  }
fi

cp "$BINARY" "$OUT"
chmod 0755 "$OUT"
echo "==> Done: $OUT ($(du -sh "$OUT" | cut -f1), glibc 2.34+, ${NONO_VERSION})"
