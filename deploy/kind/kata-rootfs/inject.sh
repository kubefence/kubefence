#!/usr/bin/env bash
# inject.sh — injects nono into a kata MBR+ext4 disk image
#
# Operates entirely on files (no root, no loop mount) using dd to extract
# the ext4 partition from the MBR disk image and debugfs -w to write files.
#
# Usage: inject.sh <image-path> <nono-binary-path> [policy-rego-path]
set -euo pipefail

IMAGE="$1"
NONO="$2"
POLICY="${3:-}"

# Validate that paths contain no whitespace. debugfs reads its command
# arguments as unquoted tokens in a heredoc; a path with spaces would
# silently split into multiple arguments, injecting the wrong file and
# leaving the rootfs with a corrupt or missing /nono/nono.
for _var in "$IMAGE" "$NONO" ${POLICY:+"$POLICY"}; do
  if [[ "$_var" =~ [[:space:]] ]]; then
    echo "ERROR: path must not contain whitespace: ${_var}" >&2
    exit 1
  fi
done

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

if [[ -n "$POLICY" ]]; then
  # /etc/kata-opa/default-policy.rego is a symlink → allow-all.rego in the
  # stock image.  debugfs write cannot overwrite an existing path, so remove
  # allow-all.rego first then write our policy in its place.  The symlink
  # (default-policy.rego → allow-all.rego) stays and now resolves to our file.
  echo "==> Replacing /etc/kata-opa/allow-all.rego with enforcement policy ..."
  debugfs -w "$PART_IMG" 2>/dev/null << DEBUGFS_EOF
rm /etc/kata-opa/allow-all.rego
DEBUGFS_EOF
  debugfs -w "$PART_IMG" 2>/dev/null << DEBUGFS_EOF
write $POLICY /etc/kata-opa/allow-all.rego
DEBUGFS_EOF
fi

echo "==> Writing modified partition back into image..."
dd if="$PART_IMG" bs=512 seek="$PART_START_SECTOR" of="$IMAGE" \
   conv=notrunc status=none

echo "==> Done."
