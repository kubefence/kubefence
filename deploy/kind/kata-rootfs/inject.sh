#!/usr/bin/env bash
# inject.sh — injects nono and shell wrappers into a kata MBR+ext4 disk image
#
# Operates entirely on files (no root, no loop mount) using dd to extract
# the ext4 partition from the MBR disk image and debugfs -w to write files.
#
# Usage: inject.sh <image-path> <nono-binary-path>
set -euo pipefail

IMAGE="$1"
NONO="$2"

# Detect partition geometry dynamically — works for any MBR/GPT disk image
# without root or loop mounts. sfdisk is in the `fdisk` apt package.
echo "==> Detecting partition geometry..."
read PART_START_SECTOR PART_SECTORS < <(
  sfdisk --json "$IMAGE" | awk '
    /"start"/ { gsub(/[^0-9]/,"",$2); start=$2 }
    /"size"/  { gsub(/[^0-9]/,"",$2); size=$2; print start, size; exit }
  '
)
if [[ -z "$PART_START_SECTOR" || -z "$PART_SECTORS" || \
      "$PART_START_SECTOR" -eq 0 ]]; then
  echo "ERROR: Failed to detect partition geometry from $(basename "$IMAGE")" >&2
  echo "       sfdisk output: $(sfdisk --json "$IMAGE" 2>&1 | head -5)" >&2
  exit 1
fi
echo "==> Partition geometry: start=${PART_START_SECTOR} sectors, size=${PART_SECTORS} sectors"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PART_IMG="$WORKDIR/partition.ext4"

echo "==> Extracting ext4 partition (offset $((PART_START_SECTOR * 512)) bytes)..."
dd if="$IMAGE" bs=512 skip="$PART_START_SECTOR" count="$PART_SECTORS" \
   of="$PART_IMG" status=none

echo "==> Creating /nono directory..."
# Separated from the subsequent large-file write: combining mkdir and a large
# write in a single debugfs session corrupts the ext4 partition in some
# debugfs versions (inode allocation ordering bug).
debugfs -w "$PART_IMG" 2>/dev/null << DEBUGFS_EOF
mkdir /nono
DEBUGFS_EOF

echo "==> Injecting /nono/nono ..."
debugfs -w "$PART_IMG" 2>/dev/null << DEBUGFS_EOF
write $NONO /nono/nono
DEBUGFS_EOF

echo "==> Injecting /usr/local/bin/nono symlink ..."
debugfs -w "$PART_IMG" 2>/dev/null << DEBUGFS_EOF
symlink /usr/local/bin/nono /nono/nono
DEBUGFS_EOF

# Shell wrappers: each calls nono wrap with the real binary path.
# /usr/local/bin already precedes /bin in /etc/environment PATH so these
# are found first by name-only exec (kubectl exec pod -- bash).
for PAIR in \
    "sh:/bin/sh" \
    "bash:/bin/bash" \
    "ash:/bin/ash" \
    "dash:/bin/dash" \
    "python3:/usr/bin/python3" \
    "python:/usr/bin/python" \
    "node:/usr/bin/node" \
    "ruby:/usr/bin/ruby" \
    "perl:/usr/bin/perl"; do
    NAME="${PAIR%%:*}"
    REAL="${PAIR##*:}"
    WRAPPER="$WORKDIR/${NAME}.wrapper"
    printf '#!/bin/sh\nexec /nono/nono wrap --profile "${NONO_PROFILE:-default}" -- %s "$@"\n' "$REAL" > "$WRAPPER"
    chmod 0755 "$WRAPPER"
    debugfs -w "$PART_IMG" 2>/dev/null << DEBUGFS_EOF
write $WRAPPER /usr/local/bin/$NAME
DEBUGFS_EOF
done
echo "==> Wrappers written for: sh bash ash dash python3 python node ruby perl"

echo "==> Writing modified partition back into image..."
dd if="$PART_IMG" bs=512 seek="$PART_START_SECTOR" of="$IMAGE" \
   conv=notrunc status=none

echo "==> Done."
