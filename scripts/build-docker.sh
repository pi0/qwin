#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="wincore-builder"

# Build the Docker image
echo ":: Building Docker image..."
docker build -t "$IMAGE_NAME" "$PROJECT_ROOT"

# KVM passthrough if available
DEVICE_ARGS=()
if [[ -e /dev/kvm ]]; then
  echo " ✓ KVM available — enabling hardware acceleration"
  DEVICE_ARGS+=(--device /dev/kvm)
else
  echo " ⚠ KVM not available — falling back to software emulation (slow)"
fi

# Load .env into current shell (for port mappings etc.) and forward to container
ENV_ARGS=()
if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.env"
  set +a
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    ENV_ARGS+=(-e "$key=$value")
  done < "$PROJECT_ROOT/.env"
fi

# Shared directory mount
SHARED_ARGS=()
SHARED_DIR="${SHARED_DIR:-}"
if [[ -f "$PROJECT_ROOT/.env" ]]; then
  SHARED_DIR="${SHARED_DIR:-$(grep -oP '^SHARED_DIR=\K.*' "$PROJECT_ROOT/.env" 2>/dev/null || true)}"
fi
if [[ -n "$SHARED_DIR" && -d "$SHARED_DIR" ]]; then
  SHARED_ARGS+=(-v "$SHARED_DIR:/opt/winvm/shared")
fi

# Mount SSH public key into container if set
SSH_ARGS=()
SSH_PUBKEY="${SSH_PUBKEY:-}"
if [[ -n "$SSH_PUBKEY" ]]; then
  PUBKEY_PATH="${SSH_PUBKEY/#\~/$HOME}"
  if [[ -f "$PUBKEY_PATH" ]]; then
    SSH_ARGS+=(-v "$PUBKEY_PATH:$PUBKEY_PATH:ro")
  fi
fi

# Compute VNC port from display number (must match QEMU's -vnc setting)
VNC_DISPLAY="${VNC_DISPLAY:-:0}"
VNC_PORT=$(( 5900 + ${VNC_DISPLAY#:} ))

HOST_VNC_PORT="${HOST_VNC_PORT:-$VNC_PORT}"
HOST_NOVNC_PORT="${HOST_NOVNC_PORT:-6080}"

echo ":: Starting container..."
CONTAINER_NAME="wincore-$$"
docker run --rm -d --name "$CONTAINER_NAME" \
  --privileged \
  ${DEVICE_ARGS[@]+"${DEVICE_ARGS[@]}"} \
  ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  ${SHARED_ARGS[@]+"${SHARED_ARGS[@]}"} \
  ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} \
  -v "$PROJECT_ROOT/images:/opt/winvm/images" \
  -p "127.0.0.1:${HOST_RDP_PORT:-3389}:${HOST_RDP_PORT:-3389}" \
  -p "127.0.0.1:${HOST_WINRM_PORT:-5985}:${HOST_WINRM_PORT:-5985}" \
  -p "127.0.0.1:${HOST_SSH_PORT:-2222}:${HOST_SSH_PORT:-2222}" \
  -p "127.0.0.1:${HOST_VNC_PORT}:${VNC_PORT}" \
  -p "127.0.0.1:${HOST_NOVNC_PORT}:6080" \
  "$IMAGE_NAME" "$@" >/dev/null

# Cleanup container on exit
trap 'docker rm -f "$CONTAINER_NAME" 2>/dev/null' EXIT

# Open noVNC in browser once QEMU reports VNC is ready
(
  while ! docker logs "$CONTAINER_NAME" 2>&1 | grep -q "VNC:.*localhost"; do
    sleep 1
  done
  NOVNC_URL="http://127.0.0.1:${HOST_NOVNC_PORT}/vnc.html?autoconnect=true"
  echo " ✓ Opening noVNC: $NOVNC_URL"
  if [[ "$(uname)" == "Darwin" ]]; then
    # Prefer Chromium-based browsers, fall back to Safari, then default
    if open -Ra "Google Chrome" 2>/dev/null; then
      open -na "Google Chrome" --args --new-window "$NOVNC_URL"
    elif open -Ra "Chromium" 2>/dev/null; then
      open -na "Chromium" --args --new-window "$NOVNC_URL"
    elif open -Ra "Safari" 2>/dev/null; then
      open -na "Safari" "$NOVNC_URL"
    else
      open "$NOVNC_URL"
    fi
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$NOVNC_URL"
  fi
) &

# Stream container logs (replaces exec — Ctrl-C triggers trap cleanup)
docker logs -f "$CONTAINER_NAME"
