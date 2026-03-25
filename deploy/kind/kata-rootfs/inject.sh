#!/usr/bin/env bash
# inject.sh — injects nono and shell wrappers into kata-ubuntu-noble.image
#
# Operates entirely on files (no root, no loop mount) using dd to extract
# the ext4 partition from the MBR disk image and debugfs -w to write files.
#
# Usage: inject.sh <image-path> <nono-binary-path>
set -euo pipefail

IMAGE="$1"
NONO="$2"

# Partition geometry from `file kata-ubuntu-noble.image`:
#   partition 1: start-sector 6144, 518144 sectors (512 bytes each)
PART_START_SECTOR=6144
PART_SECTORS=518144

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PART_IMG="$WORKDIR/partition.ext4"

echo "==> Extracting ext4 partition (offset $((PART_START_SECTOR * 512)) bytes)..."
dd if="$IMAGE" bs=512 skip="$PART_START_SECTOR" count="$PART_SECTORS" \
   of="$PART_IMG" status=none

echo "==> Injecting /nono/nono ..."
debugfs -w "$PART_IMG" 2>/dev/null << DEBUGFS_EOF
mkdir /nono
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
