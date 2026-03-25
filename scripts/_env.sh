#!/usr/bin/env bash
# Shared env loader — sourced by all scripts

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Load .env if present (skip if already loaded)
if [[ -z "${_ENV_LOADED:-}" && -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  export _ENV_LOADED=1
fi

# Defaults
export WIN_ISO_URL="${WIN_ISO_URL:?WIN_ISO_URL is required — set it in .env or environment}"
export WIN_ISO_SHA256="${WIN_ISO_SHA256:-}"
export WIN_PRODUCT_KEY="${WIN_PRODUCT_KEY:-}"
export WIN_ADMIN_PASSWORD="${WIN_ADMIN_PASSWORD:-P@ssw0rd!}"
export WIN_HOSTNAME="${WIN_HOSTNAME:-WINCORE}"
export WIN_TIMEZONE="${WIN_TIMEZONE:-UTC}"
export DISK_SIZE="${DISK_SIZE:-60G}"
export RAM_MB="${RAM_MB:-4096}"
export CPU_CORES="${CPU_CORES:-2}"
export VNC_DISPLAY="${VNC_DISPLAY:-:0}"
export HOST_RDP_PORT="${HOST_RDP_PORT:-13389}"
export HOST_SSH_PORT="${HOST_SSH_PORT:-2222}"
export HOST_NOVNC_PORT="${HOST_NOVNC_PORT:-16080}"
export SSH_PUBKEY="${SSH_PUBKEY:-}"

PIDFILE="/tmp/qemu-wincore.pid"

mkdir -p images

# --- Colored logging helpers ---
_NO_COLOR="${NO_COLOR:-}"
if [[ -n "$_NO_COLOR" ]] || [[ ! -t 1 ]]; then
  _C_RESET="" _C_BOLD="" _C_DIM=""
  _C_RED="" _C_GREEN="" _C_YELLOW="" _C_BLUE="" _C_CYAN=""
else
  _C_RESET=$'\033[0m' _C_BOLD=$'\033[1m' _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m' _C_GREEN=$'\033[32m' _C_YELLOW=$'\033[33m' _C_BLUE=$'\033[34m' _C_CYAN=$'\033[36m'
fi

log_step()  { echo "${_C_BOLD}${_C_BLUE}::${_C_RESET} ${_C_BOLD}$*${_C_RESET}"; }
log_info()  { echo "${_C_CYAN}   $*${_C_RESET}"; }
log_ok()    { echo "${_C_GREEN} ✓ $*${_C_RESET}"; }
log_warn()  { echo "${_C_YELLOW} ⚠ $*${_C_RESET}"; }
log_error() { echo "${_C_RED} ✗ $*${_C_RESET}" >&2; }
log_dim()   { echo "${_C_DIM}   $*${_C_RESET}"; }

# Check for a required command, print install hint if missing
require_cmd() {
  local cmd="$1"
  command -v "$cmd" &>/dev/null && return 0

  local hint=""
  case "$cmd" in
    genisoimage)
      case "$(uname -s)" in
        Darwin) hint="Install with: brew install cdrtools" ;;
        Linux)  hint="Install with: sudo apt install genisoimage  (or: sudo dnf install genisoimage)" ;;
      esac
      ;;
    qemu-system-x86_64)
      case "$(uname -s)" in
        Darwin) hint="Install with: brew install qemu" ;;
        Linux)  hint="Install with: sudo apt install qemu-system-x86  (or: sudo dnf install qemu-system-x86-core)" ;;
      esac
      ;;
    curl)
      case "$(uname -s)" in
        Darwin) hint="Install with: brew install curl" ;;
        Linux)  hint="Install with: sudo apt install curl  (or: sudo dnf install curl)" ;;
      esac
      ;;
  esac

  log_error "Required command not found: $cmd"
  [[ -n "$hint" ]] && log_error "$hint"
  exit 1
}

# Kill any running QEMU instance from a previous build
kill_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid=$(cat "$PIDFILE")
    if kill -0 "$pid" 2>/dev/null; then
      log_warn "Killing previous QEMU (PID $pid)..."
      kill "$pid"
      # Wait for it to actually exit
      for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      # Force kill if still alive
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PIDFILE"
  fi
}

# Wait for a PID to exit, with a timeout in seconds. Returns 1 if timed out.
wait_timeout() {
  local pid="$1" timeout="$2" elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    (( elapsed >= timeout )) && return 1
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid" 2>/dev/null || true
  return 0
}

# Detect if running inside a container (Docker, LXC, etc.)
is_container() {
  [[ -f /.dockerenv ]] || grep -q '/docker\|/lxc' /proc/1/cgroup 2>/dev/null
}

# Stamp file records the config state at last successful disk creation
BUILD_STAMP="images/.build-stamp"

# Check if config changed since last build — returns 0 if rebuild needed
needs_rebuild() {
  local disk="images/windows.qcow2"
  [[ ! -f "$disk" ]] && return 1  # no disk = nothing to invalidate

  # No stamp = disk exists from before stamp tracking, rebuild to be safe
  if [[ ! -f "$BUILD_STAMP" ]]; then
    log_warn "No build stamp found — wiping disk for fresh install."
    rm -f images/windows-overlay.qcow2
    return 0
  fi

  # Check if any config source is newer than the stamp
  for src in config/Autounattend.xml.tpl .env; do
    if [[ -f "$src" && "$src" -nt "$BUILD_STAMP" ]]; then
      log_warn "$src changed since last build — wiping disk for fresh install."
      rm -f images/windows-overlay.qcow2
      return 0
    fi
  done

  return 1
}

# Call after successful disk creation to record config state
stamp_build() {
  touch "$BUILD_STAMP"
}
