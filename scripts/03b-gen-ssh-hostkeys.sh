#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

SSH_KEYS_DIR="images/ssh-hostkeys"

# Only generate once — reuse across rebuilds for stable fingerprints
if [[ -f "$SSH_KEYS_DIR/ssh_host_ed25519_key" ]]; then
  log_ok "SSH host keys already exist, reusing"
  exit 0
fi

mkdir -p "$SSH_KEYS_DIR"

log_info "Generating persistent SSH host keys..."
for type in ed25519 rsa ecdsa; do
  ssh-keygen -t "$type" -f "$SSH_KEYS_DIR/ssh_host_${type}_key" -N "" -q
done

log_ok "SSH host keys generated in $SSH_KEYS_DIR"
log_info "Fingerprints:"
for pub in "$SSH_KEYS_DIR"/*.pub; do
  ssh-keygen -l -f "$pub" | sed 's/^/   /'
done
