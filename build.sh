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
  exec bash scripts/build.sh "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
fi

# --- Docker build ---
_log_info "Building via Docker"

# Pre-check: ensure required ports are free
_check_port() {
  local port="$1" label="$2"
  local pid_info=""
  if [[ "$(uname -s)" == "Darwin" ]]; then
    pid_info=$(lsof -iTCP:"$port" -sTCP:LISTEN -nP 2>/dev/null | awk 'NR>1{print $1 " (PID " $2 ")"}' | head -1)
  else
    pid_info=$(ss -tlnpH "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*,fd=.*/\1/p' | head -1)
    if [[ -n "$pid_info" ]]; then
      local pname
      pname=$(ps -p "$pid_info" -o comm= 2>/dev/null || echo "unknown")
      pid_info="$pname (PID $pid_info)"
    fi
  fi
  if [[ -n "$pid_info" ]]; then
    _log_error "Port $port ($label) is already in use by $pid_info"
    _log_error "Free it or override with ${label}_PORT env var."
    return 1
  elif ss -tlnH "sport = :$port" 2>/dev/null | grep -q . || \
       lsof -iTCP:"$port" -sTCP:LISTEN -nP &>/dev/null; then
    _log_error "Port $port ($label) is already in use."
    _log_error "Free it or override with ${label}_PORT env var."
    return 1
  fi
}

_ports_ok=true
_check_port "${HOST_RDP_PORT:-13389}"   "HOST_RDP"   || _ports_ok=false
_check_port "${HOST_WINRM_PORT:-15985}" "HOST_WINRM" || _ports_ok=false
_check_port "${HOST_SSH_PORT:-2222}"    "HOST_SSH"    || _ports_ok=false
_check_port "${HOST_NOVNC_PORT:-16080}"      "NOVNC"      || _ports_ok=false

if [[ "$_ports_ok" != true ]]; then
  # List running QEMU/KVM/docker instances to help identify the culprit
  _instances=$(ps -eo pid,user,args 2>/dev/null | grep -E 'qemu-system|kvm|docker run' | grep -v grep || true)
  if [[ -n "$_instances" ]]; then
    echo ""
    _log_error "Running QEMU/KVM/Docker instances:"
    echo "$_instances" | while read -r line; do
      _log_error "  $line"
    done
  fi
  exit 1
fi

IMAGE_NAME="${DOCKER_IMAGE:-wincore-builder}"

# Build the Docker image
docker build -t "$IMAGE_NAME" .

# Assemble docker run flags
DOCKER_ARGS=(
  --rm -it
  --name wincore
  -v "$PROJECT_ROOT/images:/opt/winvm/images"
  -p "${HOST_RDP_PORT:-13389}:3389"
  -p "${HOST_WINRM_PORT:-15985}:5985"
  -p "${HOST_SSH_PORT:-2222}:22"
  -p "${HOST_NOVNC_PORT:-16080}:6080"
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

exec docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
