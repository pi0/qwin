#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

# --- Minimal logging (before _env.sh is loaded) ---
_log_info()  { echo ":: $*"; }
_log_error() { echo "✗ $*" >&2; }

# --- Detect run mode ---
RUN_MODE="${RUN_MODE:-auto}"
PASSTHROUGH_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --docker) RUN_MODE="docker" ;;
    --host)   RUN_MODE="host" ;;
    *)        PASSTHROUGH_ARGS+=("$arg") ;;
  esac
done

if [[ "$RUN_MODE" == "auto" ]]; then
  if command -v qemu-system-x86_64 &>/dev/null; then
    RUN_MODE="host"
  elif command -v docker &>/dev/null; then
    RUN_MODE="docker"
  else
    _log_error "Neither qemu-system-x86_64 nor docker found."
    _log_error "Install QEMU for host mode or Docker for containerized mode."
    exit 1
  fi
fi

# --- Host mode ---
if [[ "$RUN_MODE" == "host" ]]; then
  source scripts/_env.sh

  OVERLAY_DISK="images/windows-overlay.qcow2"
  BASE_DISK="images/windows.qcow2"

  usage() {
    echo "Usage: $0 [--reset] [--host|--docker]"
    echo ""
    echo "Boot Windows from the overlay disk (changes are reversible)."
    echo ""
    echo "Options:"
    echo "  --reset    Discard all changes and recreate overlay from base"
    echo "  --host     Force host (QEMU) mode"
    echo "  --docker   Force Docker mode"
    echo ""
    echo "The base disk must exist (run build.sh first)."
  }

  RESET=false
  for arg in "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"; do
    case "$arg" in
      --reset) RESET=true ;;
      --help|-h) usage; exit 0 ;;
      *) log_error "Unknown option: $arg"; usage; exit 1 ;;
    esac
  done

  # Ensure base disk exists
  if [[ ! -f "$BASE_DISK" ]]; then
    log_error "No completed base image found."
    log_error "Run ./build.sh first to create the base image."
    exit 1
  fi

  # Reset: delete overlay and recreate
  if [[ "$RESET" == true ]]; then
    log_warn "Resetting overlay — discarding all changes..."
    rm -f "$OVERLAY_DISK"
  fi

  # Create overlay if missing
  if [[ ! -f "$OVERLAY_DISK" ]]; then
    bash scripts/06-create-overlay.sh
  fi

  # Boot from overlay
  export FRESH_INSTALL=false
  exec bash scripts/05-start-qemu.sh
fi

# --- Docker mode ---
_log_info "Running via Docker"

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
_check_port "${HOST_SSH_PORT:-2222}"    "HOST_SSH"    || _ports_ok=false
_check_port "${HOST_NOVNC_PORT:-16080}" "NOVNC"       || _ports_ok=false

if [[ "$_ports_ok" != true ]]; then
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

# Build the Docker image (reuses cache if unchanged)
docker build -t "$IMAGE_NAME" .

# Assemble docker run flags
DOCKER_ARGS=(
  --rm -it
  --name wincore-run
  -v "$PROJECT_ROOT/images:/opt/winvm/images"
  -p "${HOST_RDP_PORT:-13389}:3389"
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

# Override entrypoint to run.sh inside container (host mode, since QEMU is in the container)
exec docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" bash -c \
  'cd /opt/winvm && ./run.sh --host '"$(printf '%q ' "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}")"
