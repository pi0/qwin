#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

VIRTIO_ISO="images/virtio-win.iso"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

if [[ -f "$VIRTIO_ISO" ]]; then
  log_ok "VirtIO drivers ISO already exists: $VIRTIO_ISO"
  exit 0
fi

log_info "Downloading VirtIO drivers ISO..."
curl -fSL -o "$VIRTIO_ISO" "$VIRTIO_URL"
log_ok "VirtIO ISO ready: $VIRTIO_ISO"
