#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

require_cmd curl

ISO_PATH="images/windows.iso"

# If WIN_ISO_URL is a local file path, symlink it
if [[ -f "$WIN_ISO_URL" ]]; then
  if [[ -f "$ISO_PATH" ]]; then
    log_ok "ISO already present at $ISO_PATH, skipping."
    exit 0
  fi
  log_info "Using local ISO: $WIN_ISO_URL"
  ln -sf "$(realpath "$WIN_ISO_URL")" "$ISO_PATH"
  exit 0
fi

# Download if not already present
if [[ -f "$ISO_PATH" ]]; then
  log_ok "ISO already present at $ISO_PATH, skipping download."
else
  log_info "Downloading ISO from $WIN_ISO_URL ..."
  curl -L -C - -o "$ISO_PATH.partial" "$WIN_ISO_URL"
  mv "$ISO_PATH.partial" "$ISO_PATH"
fi

# Verify checksum if provided
if [[ -n "$WIN_ISO_SHA256" ]]; then
  log_info "Verifying SHA256 checksum..."
  echo "$WIN_ISO_SHA256  $ISO_PATH" | sha256sum -c -
  log_ok "Checksum OK."
fi

log_ok "ISO ready: $ISO_PATH"
