#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

require_cmd qemu-img

BASE_DISK="images/windows.qcow2"
OVERLAY_DISK="images/windows-overlay.qcow2"

if [[ ! -f "$BASE_DISK" ]]; then
  log_error "Base disk not found: $BASE_DISK"
  log_error "Run a full build first to create the base image."
  exit 1
fi

if [[ -f "$OVERLAY_DISK" ]]; then
  log_ok "Overlay already exists at $OVERLAY_DISK, skipping."
  log_info "Use --reset to recreate the overlay from base."
  exit 0
fi

log_info "Creating overlay disk on top of $BASE_DISK..."
qemu-img create -f qcow2 -b "windows.qcow2" -F qcow2 "$OVERLAY_DISK"
log_ok "Overlay ready: $OVERLAY_DISK (backed by $BASE_DISK)"
