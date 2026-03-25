#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

DISK="images/windows.qcow2"
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
HOST_RDP_PORT="${HOST_RDP_PORT:-3389}"
HOST_WINRM_PORT="${HOST_WINRM_PORT:-5985}"
HOST_SSH_PORT="${HOST_SSH_PORT:-2222}"

# Shared directory for virtio-fs (host → guest Z:\)
SHARED_DIR="${SHARED_DIR:-$PROJECT_ROOT/shared}"
VIRTIOFSD_SOCK="/tmp/virtiofsd-wincore.sock"

# Kill previous QEMU if running
kill_qemu

# Kill previous virtiofsd if running
if [[ -S "$VIRTIOFSD_SOCK" ]]; then
  rm -f "$VIRTIOFSD_SOCK"
fi
pkill -f "virtiofsd.*$VIRTIOFSD_SOCK" 2>/dev/null || true

# Detect KVM
ACCEL="tcg"
CPU_MODEL="qemu64"
if [[ -e /dev/kvm ]]; then
  log_ok "KVM detected — using hardware acceleration."
  ACCEL="kvm"
  CPU_MODEL="host"
else
  log_warn "KVM not available — falling back to TCG (software emulation)."
  log_warn "Install will be significantly slower."
fi

# Create shared directory if it doesn't exist
mkdir -p "$SHARED_DIR"

# Find virtiofsd binary (Arch: /usr/lib/virtiofsd, Ubuntu/Debian: /usr/libexec/virtiofsd or PATH)
VIRTIOFSD=""
for candidate in /usr/lib/virtiofsd /usr/libexec/virtiofsd; do
  [[ -x "$candidate" ]] && VIRTIOFSD="$candidate" && break
done
if [[ -z "$VIRTIOFSD" ]]; then
  VIRTIOFSD=$(command -v virtiofsd 2>/dev/null || true)
fi
if [[ -z "$VIRTIOFSD" ]]; then
  log_error "virtiofsd not found. Install it: pacman -S virtiofsd (Arch) / apt install virtiofsd (Debian)"
  exit 1
fi

# Start virtiofsd daemon for host→guest filesystem sharing
log_info "Starting virtiofsd (sharing $SHARED_DIR)..."
"$VIRTIOFSD" \
  --socket-path="$VIRTIOFSD_SOCK" \
  --shared-dir="$SHARED_DIR" \
  --log-level=error \
  --cache=always &
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

QEMU_ARGS=(
  -machine "q35,accel=${ACCEL},memory-backend=mem0"
  -object "memory-backend-memfd,id=mem0,size=${RAM_MB}M,share=on"
  -device isa-debugcon,iobase=0x402,chardev=debugout
  -chardev file,id=debugout,path=/dev/stderr
  -cpu "$CPU_MODEL"
  -m "$RAM_MB"
  -smp "$CPU_CORES"

  # Disk (VirtIO — fast I/O, drivers loaded from VirtIO ISO during windowsPE)
  -drive "file=${DISK},if=virtio,format=qcow2,cache=unsafe,aio=io_uring"
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

  # VirtIO-FS (host shared directory → guest Z:\)
  -chardev "socket,id=vfs0,path=$VIRTIOFSD_SOCK"
  -device "vhost-user-fs-pci,chardev=vfs0,tag=hostshare"

  # Network — virtio-net is faster than e1000; Windows Server 2022 has the driver
  -nic "user,model=virtio-net-pci,hostfwd=tcp::${HOST_RDP_PORT}-:3389,hostfwd=tcp::${HOST_WINRM_PORT}-:5985,hostfwd=tcp::${HOST_SSH_PORT}-:22"

  # Display — VNC for graphical, serial for TTY output
  -display none
  -vnc "$VNC_DISPLAY"
  -serial stdio

  # Write PID for other scripts
  -pidfile "$PIDFILE"
)

# Compute VNC port from display number
VNC_PORT=$(( 5900 + ${VNC_DISPLAY#:} ))

log_step "Starting QEMU..."
log_info "RAM: ${RAM_MB}MB | CPUs: ${CPU_CORES} | Accel: ${ACCEL}"
log_info "VNC: localhost:${VNC_PORT} (display ${VNC_DISPLAY})"
log_info "RDP: localhost:${HOST_RDP_PORT} | WinRM: localhost:${HOST_WINRM_PORT} | SSH: localhost:${HOST_SSH_PORT}"
log_info "Shared: $SHARED_DIR → Z:\\"

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
  log_warn "Stopping virtiofsd (PID $VIRTIOFSD_PID)..."
  kill "$VIRTIOFSD_PID" 2>/dev/null
  wait "$VIRTIOFSD_PID" 2>/dev/null
  rm -f "$PIDFILE" "$VIRTIOFSD_SOCK" /tmp/virtio-serial-wincore.sock
}
trap cleanup EXIT INT TERM

# Launch noVNC web interface if available
NOVNC_PORT="${NOVNC_PORT:-6080}"
NOVNC_WEB="${NOVNC_WEB:-/usr/share/novnc}"
if [[ -d "$NOVNC_WEB" ]] && command -v websockify &>/dev/null; then
  log_info "Starting noVNC on port ${NOVNC_PORT}..."
  websockify --web="$NOVNC_WEB" "$NOVNC_PORT" "localhost:${VNC_PORT}" &>/dev/null &
  NOVNC_PID=$!
  log_dim "noVNC PID: $NOVNC_PID"
fi

# Launch VNC viewer if available
if command -v vncviewer &>/dev/null; then
  log_info "Opening VNC viewer..."
  vncviewer "localhost:${VNC_PORT}" &>/dev/null &
fi

# Wait for WinRM to become available
echo ""
if [[ "$FRESH_INSTALL" == true ]]; then
  log_step "Waiting for Windows installation to complete (WinRM port ${HOST_WINRM_PORT})..."
  TIMEOUT=14400  # 4 hours max
else
  log_step "Waiting for Windows to boot (WinRM port ${HOST_WINRM_PORT})..."
  TIMEOUT=300  # 5 min for a prebuilt disk
fi
ELAPSED=0
INTERVAL=30

while ! (echo > /dev/tcp/127.0.0.1/"$HOST_WINRM_PORT") 2>/dev/null; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    log_error "QEMU process exited unexpectedly."
    exit 1
  fi
  if (( ELAPSED >= TIMEOUT )); then
    log_error "Timed out waiting for WinRM after ${TIMEOUT}s."
    exit 1
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
  log_dim "Still waiting... (${ELAPSED}s elapsed)"
done

if [[ "$FRESH_INSTALL" == true ]]; then
  # WinRM opens early (step 2 of setup.ps1) — wait for SSH port as a better completion signal
  log_step "WinRM is up — waiting for post-install to finish (SSH port ${HOST_SSH_PORT})..."
  SSH_TIMEOUT=7200  # 2 hours for downloads/cleanup
  SSH_ELAPSED=0
  while ! (echo > /dev/tcp/127.0.0.1/"$HOST_SSH_PORT") 2>/dev/null; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      log_error "QEMU process exited unexpectedly."
      exit 1
    fi
    if (( SSH_ELAPSED >= SSH_TIMEOUT )); then
      log_warn "Timed out waiting for SSH after ${SSH_TIMEOUT}s — setup may still be running."
      break
    fi
    sleep "$INTERVAL"
    SSH_ELAPSED=$((SSH_ELAPSED + INTERVAL))
    log_dim "Post-install in progress... (${SSH_ELAPSED}s since WinRM came up)"
  done
  echo ""
  log_ok "Windows installation complete!"
else
  echo ""
  log_ok "Windows is ready!"
fi
log_info "RDP:   localhost:${HOST_RDP_PORT}"
log_info "SSH:   ssh administrator@localhost -p ${HOST_SSH_PORT}"
log_info "WinRM: localhost:${HOST_WINRM_PORT}"
log_info "VNC:   localhost:${VNC_PORT}"
if [[ -n "${NOVNC_PID:-}" ]]; then
  log_info "Web:   http://localhost:${NOVNC_PORT}/vnc.html?autoconnect=true"
fi
echo ""
log_info "Press Ctrl+C to stop the VM."

# Keep running — QEMU exits when we do
wait "$QEMU_PID"
