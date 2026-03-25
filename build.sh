#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

# --- Minimal logging (before _env.sh is loaded) ---
_log_info()  { echo ":: $*"; }
_log_error() { echo "✗ $*" >&2; }

# --- Detect build mode ---
# Explicit override via BUILD_MODE env var or --docker / --host flags
BUILD_MODE="${BUILD_MODE:-auto}"
PASSTHROUGH_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --docker) BUILD_MODE="docker" ;;
    --host)   BUILD_MODE="host" ;;
    *)        PASSTHROUGH_ARGS+=("$arg") ;;
  esac
done

if [[ "$BUILD_MODE" == "auto" ]]; then
  if command -v qemu-system-x86_64 &>/dev/null; then
    BUILD_MODE="host"
  elif command -v docker &>/dev/null; then
    BUILD_MODE="docker"
  else
    _log_error "Neither qemu-system-x86_64 nor docker found."
    _log_error "Install QEMU for host builds or Docker for containerized builds."
    exit 1
  fi
fi

# --- Host build: delegate to scripts/build.sh ---
if [[ "$BUILD_MODE" == "host" ]]; then
  _log_info "Building on host (QEMU)"
  exec bash scripts/build.sh "${PASSTHROUGH_ARGS[@]}"
fi

# --- Docker build ---
_log_info "Building via Docker"

IMAGE_NAME="${DOCKER_IMAGE:-wincore-builder}"

# Build the Docker image
docker build -t "$IMAGE_NAME" .

# Assemble docker run flags
DOCKER_ARGS=(
  --rm -it
  --name wincore
  -v "$PROJECT_ROOT/images:/opt/winvm/images"
  -p "${HOST_RDP_PORT:-3389}:3389"
  -p "${HOST_WINRM_PORT:-5985}:5985"
  -p "${HOST_SSH_PORT:-2222}:22"
  -p "${NOVNC_PORT:-6080}:6080"
)

# Pass through KVM if available
if [[ -e /dev/kvm ]]; then
  DOCKER_ARGS+=(--device /dev/kvm)
fi

# Pass .env file if it exists
if [[ -f .env ]]; then
  DOCKER_ARGS+=(--env-file .env)
fi

# Pass shared dir mount if configured
SHARED_DIR="${SHARED_DIR:-./shared}"
if [[ -d "$SHARED_DIR" ]]; then
  DOCKER_ARGS+=(-v "$(realpath "$SHARED_DIR"):/opt/winvm/shared")
fi

exec docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${PASSTHROUGH_ARGS[@]}"
