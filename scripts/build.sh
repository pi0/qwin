#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

# Kill previous QEMU if running
kill_qemu

# --clean: wipe all generated artifacts and start fresh
if [[ "${1:-}" == "--clean" ]]; then
  log_warn "Cleaning all build artifacts..."
  rm -f images/windows.qcow2 images/answer.iso images/Autounattend.xml "$BUILD_STAMP"
  # rm -rf images/ssh-hostkeys
  shift
fi

# Wipe disk if config changed (forces fresh Windows install)
if needs_rebuild; then
  rm -f images/windows.qcow2
fi

log_step "Step 1/7: Fetch ISO"
bash scripts/01-fetch-iso.sh

log_step "Step 2/7: Fetch VirtIO drivers"
bash scripts/01b-fetch-virtio.sh

log_step "Step 3/7: Create disk"
# Track whether disk already existed (= Windows already installed)
DISK_EXISTED=false
[[ -f images/windows.qcow2 ]] && DISK_EXISTED=true
bash scripts/02-create-disk.sh

log_step "Step 4/7: Generate Autounattend.xml"
bash scripts/03-gen-autounattend.sh

log_step "Step 5/7: Generate SSH host keys"
bash scripts/03b-gen-ssh-hostkeys.sh

log_step "Step 6/7: Generate answer ISO"
bash scripts/04-gen-answer-iso.sh

log_step "Step 7/7: Start QEMU"
export FRESH_INSTALL
if [[ "$DISK_EXISTED" == true ]]; then
  FRESH_INSTALL=false
else
  FRESH_INSTALL=true
fi
exec bash scripts/05-start-qemu.sh
