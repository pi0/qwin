#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

require_cmd qemu-system-x86_64

OVERLAY_DISK="images/windows-overlay.qcow2"
BASE_DISK="images/windows.qcow2"

# Use overlay disk if available (allows instant revert to post-install state)
if [[ -f "$OVERLAY_DISK" ]]; then
  DISK="$OVERLAY_DISK"
  log_info "Booting from overlay disk (changes are reversible)."
else
  DISK="$BASE_DISK"
fi
WIN_ISO="images/windows.iso"
ANSWER_ISO="images/answer.iso"
VIRTIO_ISO="images/virtio-win.iso"

# Detect if this is a fresh install or running a prebuilt disk
# FRESH_INSTALL can be set by build.sh; fallback: check if ISOs exist
FRESH_INSTALL="${FRESH_INSTALL:-true}"
if [[ "$FRESH_INSTALL" != true ]]; then
  log_info "Prebuilt disk mode — skipping ISO mounts (boot from disk only)."
elif [[ ! -f "$WIN_ISO" || ! -f "$ANSWER_ISO" || ! -f "$VIRTIO_ISO" ]]; then
  FRESH_INSTALL=false
  log_info "ISOs missing — assuming prebuilt disk, boot from disk only."
fi

# Host ports (configurable to avoid conflicts)
# Inside a container, QEMU binds to standard ports (Docker handles the host mapping)
if is_container; then
  HOST_RDP_PORT=3389
  HOST_SSH_PORT=22
else
  HOST_RDP_PORT="${HOST_RDP_PORT:-13389}"
  HOST_SSH_PORT="${HOST_SSH_PORT:-2222}"
fi

# Shared directory for virtio-fs (host → guest Z:\)
SHARED_DIR="${SHARED_DIR:-$PROJECT_ROOT/shared}"
VIRTIOFSD_SOCK="/tmp/virtiofsd-wincore.sock"
USE_VIRTIOFS=false

# Kill previous QEMU if running
kill_qemu

# Kill previous virtiofsd if running
if [[ -S "$VIRTIOFSD_SOCK" ]]; then
  rm -f "$VIRTIOFSD_SOCK"
fi
pkill -f "virtiofsd.*$VIRTIOFSD_SOCK" 2>/dev/null || true

# Detect KVM
ACCEL="tcg"
CPU_MODEL="max"
if [[ -e /dev/kvm ]]; then
  log_ok "KVM detected — using hardware acceleration."
  ACCEL="kvm"
  CPU_MODEL="host"
else
  log_warn "KVM not available — falling back to TCG (software emulation)."
  log_warn "Install will be significantly slower."
fi

# Find virtiofsd binary (Linux-only: Arch /usr/lib, Debian /usr/libexec, or PATH)
VIRTIOFSD=""
for candidate in /usr/lib/virtiofsd /usr/libexec/virtiofsd; do
  [[ -x "$candidate" ]] && VIRTIOFSD="$candidate" && break
done
if [[ -z "$VIRTIOFSD" ]]; then
  VIRTIOFSD=$(command -v virtiofsd 2>/dev/null || true)
fi

if [[ -n "$VIRTIOFSD" ]]; then
  USE_VIRTIOFS=true
  mkdir -p "$SHARED_DIR"

  # Start virtiofsd daemon for host→guest filesystem sharing
  log_info "Starting virtiofsd (sharing $SHARED_DIR)..."
  VIRTIOFSD_ARGS=(
    --socket-path="$VIRTIOFSD_SOCK"
    --shared-dir="$SHARED_DIR"
    --log-level=error
    --cache=always
  )
  # Inside containers, unshare is not permitted — disable sandboxing
  if is_container; then
    VIRTIOFSD_ARGS+=(--sandbox none)
    log_warn "Running inside container — virtiofsd sandbox disabled."
  fi
  "$VIRTIOFSD" "${VIRTIOFSD_ARGS[@]}" &
  VIRTIOFSD_PID=$!

  # Wait for socket to appear
  for _ in $(seq 1 20); do
    [[ -S "$VIRTIOFSD_SOCK" ]] && break
    sleep 0.25
  done
  if [[ ! -S "$VIRTIOFSD_SOCK" ]]; then
    log_error "virtiofsd failed to start."
    exit 1
  fi
  log_dim "virtiofsd PID: $VIRTIOFSD_PID"
else
  log_warn "virtiofsd not found — shared directory (virtio-fs) disabled."
  case "$(uname -s)" in
    Darwin) log_warn "virtiofsd is Linux-only; shared directories are not supported on macOS hosts." ;;
    Linux)  log_warn "Install with: sudo apt install virtiofsd  (or: sudo dnf install virtiofsd / sudo pacman -S virtiofsd)" ;;
  esac
fi

# Disk I/O backend: io_uring on Linux (host only), threads elsewhere/containers
AIO_BACKEND="threads"
if [[ "$(uname -s)" == "Linux" ]] && ! is_container; then
  AIO_BACKEND="io_uring"
fi

QEMU_ARGS=(
  -cpu "$CPU_MODEL"
  -m "$RAM_MB"
  -smp "$CPU_CORES"
  -device isa-debugcon,iobase=0x402,chardev=debugout
  -chardev file,id=debugout,path=/dev/stderr
)

# virtio-fs requires memory-backend-memfd with share=on
if [[ "$USE_VIRTIOFS" == true ]]; then
  QEMU_ARGS+=(-machine "q35,accel=${ACCEL},memory-backend=mem0")
  QEMU_ARGS+=(-object "memory-backend-memfd,id=mem0,size=${RAM_MB}M,share=on")
else
  QEMU_ARGS+=(-machine "q35,accel=${ACCEL}")
fi

QEMU_ARGS+=(
  # Disk (VirtIO — fast I/O, drivers loaded from VirtIO ISO during windowsPE)
  -drive "file=${DISK},if=virtio,format=qcow2,cache=unsafe,aio=${AIO_BACKEND}"
)

# Mount ISOs and set boot order only for fresh installs
if [[ "$FRESH_INSTALL" == true ]]; then
  QEMU_ARGS+=(
    # Windows ISO (primary CD-ROM)
    -drive "file=${WIN_ISO},media=cdrom,index=1"
    # Answer ISO (secondary CD-ROM)
    -drive "file=${ANSWER_ISO},media=cdrom,index=2"
    # VirtIO drivers ISO (tertiary CD-ROM)
    -drive "file=${VIRTIO_ISO},media=cdrom,index=3"
    # Boot from CD first, then disk
    -boot order=dc
  )
else
  QEMU_ARGS+=(
    # Boot from disk only
    -boot order=c
  )
fi

QEMU_ARGS+=(

  # VirtIO balloon for memory management
  -device virtio-balloon-pci

  # VirtIO serial (guest-host communication channel)
  -device virtio-serial-pci
  -chardev socket,path=/tmp/virtio-serial-wincore.sock,server=on,wait=off,id=vserial0
  -device virtserialport,chardev=vserial0,name=org.qemu.guest_agent.0

  # Network — virtio-net is faster than e1000; Windows Server 2022 has the driver
  -nic "user,model=virtio-net-pci,hostfwd=tcp::${HOST_RDP_PORT}-:3389,hostfwd=tcp::${HOST_SSH_PORT}-:22"

  # Display — VGA at 1280x800, VNC for remote access
  -vga none
  -device VGA,xres=1280,yres=800
  -display none
  -vnc "$VNC_DISPLAY"
  -serial stdio

  # Write PID for other scripts
  -pidfile "$PIDFILE"
)

# VirtIO-FS (host shared directory → guest Z:\) — requires virtiofsd
if [[ "$USE_VIRTIOFS" == true ]]; then
  QEMU_ARGS+=(
    -chardev "socket,id=vfs0,path=$VIRTIOFSD_SOCK"
    -device "vhost-user-fs-pci,chardev=vfs0,tag=hostshare"
  )
fi

# Compute VNC port from display number
VNC_PORT=$(( 5900 + ${VNC_DISPLAY#:} ))

log_step "Starting QEMU..."
log_info "RAM: ${RAM_MB}MB | CPUs: ${CPU_CORES} | Accel: ${ACCEL}"
log_info "VNC: localhost:${VNC_PORT} (display ${VNC_DISPLAY})"
log_info "RDP: localhost:${HOST_RDP_PORT} | SSH: localhost:${HOST_SSH_PORT}"
if [[ "$USE_VIRTIOFS" == true ]]; then
  log_info "Shared: $SHARED_DIR → Z:\\"
fi

# Run QEMU as a background child (not daemonized — dies with us)
qemu-system-x86_64 "${QEMU_ARGS[@]}" &
QEMU_PID=$!
log_dim "PID: ${QEMU_PID}"

# Ensure QEMU is killed when this script exits
cleanup() {
  echo ""
  log_warn "Shutting down QEMU (PID $QEMU_PID)..."
  kill "$QEMU_PID" 2>/dev/null
  wait "$QEMU_PID" 2>/dev/null
  if [[ -n "${NOVNC_PID:-}" ]]; then
    log_warn "Stopping noVNC (PID $NOVNC_PID)..."
    kill "$NOVNC_PID" 2>/dev/null
    wait "$NOVNC_PID" 2>/dev/null
  fi
  if [[ -n "${VIRTIOFSD_PID:-}" ]]; then
    log_warn "Stopping virtiofsd (PID $VIRTIOFSD_PID)..."
    kill "$VIRTIOFSD_PID" 2>/dev/null
    wait "$VIRTIOFSD_PID" 2>/dev/null
  fi
  rm -f "$PIDFILE" "$VIRTIOFSD_SOCK" /tmp/virtio-serial-wincore.sock
}
trap cleanup EXIT INT TERM

# Launch noVNC web interface if available
# Inside a container, bind to 6080 (Docker maps HOST_NOVNC_PORT → 6080)
if is_container; then
  _NOVNC_BIND=6080
else
  _NOVNC_BIND="${HOST_NOVNC_PORT:-16080}"
fi
NOVNC_WEB="${NOVNC_WEB:-/usr/share/novnc}"
if [[ -d "$NOVNC_WEB" ]] && command -v websockify &>/dev/null; then
  log_info "Starting noVNC on port ${_NOVNC_BIND}..."
  websockify --web="$NOVNC_WEB" "$_NOVNC_BIND" "localhost:${VNC_PORT}" &>/dev/null &
  NOVNC_PID=$!
  log_dim "noVNC PID: $NOVNC_PID"
fi

# Launch VNC viewer
if command -v vncviewer &>/dev/null; then
  log_info "Opening VNC viewer..."
  vncviewer "localhost:${VNC_PORT}" &>/dev/null &
elif [[ "$(uname -s)" == "Darwin" ]]; then
  # macOS: prefer a dedicated VNC app over Screen Sharing (which prompts for password on no-auth servers)
  log_info "Connect via VNC: localhost:${VNC_PORT} (install a VNC viewer like TigerVNC: brew install tiger-vnc)"
fi

# Wait for SSH to become available
echo ""
if [[ "$FRESH_INSTALL" == true ]]; then
  log_step "Waiting for Windows installation to complete (SSH port ${HOST_SSH_PORT})..."
  TIMEOUT=14400  # 4 hours max
else
  log_step "Waiting for Windows to boot (SSH port ${HOST_SSH_PORT})..."
  TIMEOUT=300  # 5 min for a prebuilt disk
fi
ELAPSED=0
INTERVAL=30

while true; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    log_error "QEMU process exited unexpectedly."
    exit 1
  fi
  # Check for SSH banner — a real sshd sends "SSH-" on connect; QEMU port forward does not
  # Uses bash /dev/tcp with read timeout (works on Linux + macOS without external deps)
  if _banner=$(bash -c 'exec 3<>/dev/tcp/127.0.0.1/'"$HOST_SSH_PORT"' 2>/dev/null && read -t 2 -r line <&3 && echo "$line"' 2>/dev/null) && \
     echo "$_banner" | grep -q "^SSH-"; then
    break
  fi
  if (( ELAPSED >= TIMEOUT )); then
    log_error "Timed out waiting for SSH after ${TIMEOUT}s."
    exit 1
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
  log_dim "Still waiting... (${ELAPSED}s elapsed)"
done

if [[ "$FRESH_INSTALL" == true ]]; then
  echo ""
  log_ok "Windows installation complete!"

  # Shut down the VM, create an overlay on top of the base, and reboot from overlay
  log_step "Creating overlay snapshot..."
  log_info "Shutting down VM to snapshot the base disk..."
  kill "$QEMU_PID" 2>/dev/null
  wait "$QEMU_PID" 2>/dev/null || true
  # Remove trap temporarily — we handle cleanup manually here
  trap - EXIT INT TERM

  # Clean up virtiofsd/noVNC/pidfile from the initial run
  if [[ -n "${NOVNC_PID:-}" ]]; then
    kill "$NOVNC_PID" 2>/dev/null; wait "$NOVNC_PID" 2>/dev/null || true
    unset NOVNC_PID
  fi
  if [[ -n "${VIRTIOFSD_PID:-}" ]]; then
    kill "$VIRTIOFSD_PID" 2>/dev/null; wait "$VIRTIOFSD_PID" 2>/dev/null || true
    unset VIRTIOFSD_PID
  fi
  rm -f "$PIDFILE" "$VIRTIOFSD_SOCK" /tmp/virtio-serial-wincore.sock

  bash scripts/06-create-overlay.sh

  log_info "Rebooting from overlay..."
  FRESH_INSTALL=false
  exec bash scripts/05-start-qemu.sh
  stamp_build
else
  echo ""
  log_ok "Windows is ready!"
fi
log_info "RDP:   localhost:${HOST_RDP_PORT}"
log_info "SSH:   ssh administrator@localhost -p ${HOST_SSH_PORT}"
log_info "VNC:   localhost:${VNC_PORT}"
if [[ -n "${NOVNC_PID:-}" ]]; then
  log_info "Web:   http://localhost:${HOST_NOVNC_PORT}/vnc.html?autoconnect=true"
fi
echo ""
log_info "Press Ctrl+C to stop the VM."

# Keep running — QEMU exits when we do
wait "$QEMU_PID"
