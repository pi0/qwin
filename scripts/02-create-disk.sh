#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

DISK_PATH="images/windows.qcow2"

if [[ -f "$DISK_PATH" ]]; then
  log_ok "Disk already exists at $DISK_PATH, skipping."
  exit 0
fi

log_info "Creating ${DISK_SIZE} qcow2 disk..."
qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
stamp_build
log_ok "Disk ready: $DISK_PATH"
