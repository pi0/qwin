#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

DISK="images/windows.qcow2"

if [[ ! -f "$DISK" ]]; then
  log_error "Disk image not found: $DISK"
  exit 1
fi

ORIGINAL_SIZE=$(du -h "$DISK" | cut -f1)
log_step "Compacting $DISK ($ORIGINAL_SIZE)..."

# Convert in-place: write to temp file, then replace
TMP_DISK="${DISK}.compact.tmp"
qemu-img convert -O qcow2 -c -p "$DISK" "$TMP_DISK"
mv "$TMP_DISK" "$DISK"

COMPACT_SIZE=$(du -h "$DISK" | cut -f1)
log_ok "Done: $ORIGINAL_SIZE → $COMPACT_SIZE"
