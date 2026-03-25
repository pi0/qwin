#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

# Find ISO creation tool (genisoimage on Linux, mkisofs from cdrtools on macOS)
if command -v genisoimage &>/dev/null; then
  MKISO=genisoimage
elif command -v mkisofs &>/dev/null; then
  MKISO=mkisofs
else
  log_error "Required command not found: genisoimage (or mkisofs)"
  case "$(uname -s)" in
    Darwin) log_error "Install with: brew install cdrtools" ;;
    Linux)  log_error "Install with: sudo apt install genisoimage  (or: sudo dnf install genisoimage)" ;;
  esac
  exit 1
fi

ANSWER_ISO="images/answer.iso"
ANSWER_XML="images/Autounattend.xml"
ANSWER_DIR="images/answer-staging"

if [[ ! -f "$ANSWER_XML" ]]; then
  log_error "Autounattend.xml not found. Run 03-gen-autounattend.sh first."
  exit 1
fi

# Stage files for the answer ISO
rm -rf "$ANSWER_DIR"
mkdir -p "$ANSWER_DIR"
cp "$ANSWER_XML" "$ANSWER_DIR/Autounattend.xml"
cp config/setup.ps1 "$ANSWER_DIR/setup.ps1"

# Include host SSH public key if configured
if [[ -n "${SSH_PUBKEY:-}" ]]; then
  PUBKEY_PATH="${SSH_PUBKEY/#\~/$HOME}"
  if [[ -f "$PUBKEY_PATH" ]]; then
    cp "$PUBKEY_PATH" "$ANSWER_DIR/authorized_keys"
    log_ok "SSH public key bundled: $PUBKEY_PATH"
  else
    log_warn "SSH_PUBKEY set but file not found: $PUBKEY_PATH"
  fi
fi

# Include pre-generated SSH host keys for persistent fingerprints
SSH_KEYS_DIR="images/ssh-hostkeys"
if [[ -d "$SSH_KEYS_DIR" ]]; then
  mkdir -p "$ANSWER_DIR/ssh-hostkeys"
  cp "$SSH_KEYS_DIR"/ssh_host_* "$ANSWER_DIR/ssh-hostkeys/"
  log_ok "SSH host keys bundled into answer ISO"
else
  log_warn "No SSH host keys found — guest will generate ephemeral keys"
fi

log_info "Creating answer ISO..."
"$MKISO" \
  -o "$ANSWER_ISO" \
  -J -r \
  -V "ANSWER" \
  "$ANSWER_DIR"

rm -rf "$ANSWER_DIR"
log_ok "Answer ISO ready: $ANSWER_ISO"
