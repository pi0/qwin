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

# Forward .env as env vars
ENV_ARGS=()
if [[ -f "$PROJECT_ROOT/.env" ]]; then
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

echo ":: Starting container..."
exec docker run --rm -it \
  --privileged \
  "${DEVICE_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  "${SHARED_ARGS[@]}" \
  -v "$PROJECT_ROOT/images:/opt/winvm/images" \
  -p "${HOST_RDP_PORT:-3389}:3389" \
  -p "${HOST_WINRM_PORT:-5985}:5985" \
  -p "${HOST_SSH_PORT:-2222}:22" \
  -p 5900:5900 \
  "$IMAGE_NAME" "$@"
