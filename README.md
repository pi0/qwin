# qwin

Windows Server Core in a container — zero-touch install, KVM-accelerated, ready to SSH in minutes.

## What's included

Out of the box, the VM comes pre-configured with:

- **OpenSSH Server** — SSH into the VM from your terminal or attach a VS Code remote session
- **Dev-ready** — Git, Node.js LTS, and Corepack pre-installed so you can `git clone` and start coding inside it
- **Lean image** — Defender removed, firewall disabled, WinSxS cleaned, free space zeroed for qcow2 compaction
- **VirtIO guest tools** — optimized storage/network drivers and memory balooning
- **VirtIO-FS** — shared host directory mounted as `Z:\` in the guest
- **Serial console (EMS)** — for headless debugging
- **noVNC web console** — browser-based VNC viewer, auto-opens during build

## Prerequisites

### Linux

- **QEMU** (for host builds) or **Docker** (for containerized builds) — `build.sh` auto-detects which is available
- **KVM** strongly recommended — install runs in ~20-30 min with KVM vs 2-4 hours without
- `genisoimage` — for generating the answer ISO
- `virtiofsd` — for shared directory support (VirtIO-FS)

```bash
# Debian/Ubuntu
sudo apt install qemu-system-x86 genisoimage virtiofsd

# Fedora
sudo dnf install qemu-system-x86-core genisoimage virtiofsd

# Arch
sudo pacman -S qemu-system-x86 cdrtools virtiofsd
```

### macOS

- **QEMU** and **cdrtools** (provides `mkisofs` for ISO generation)
- No KVM — macOS uses software emulation (TCG), so expect slower installs
- VirtIO-FS shared directories are not available (`virtiofsd` is Linux-only)

```bash
brew install qemu cdrtools
```

## Quick Start

1. **Create `.env` with your Windows ISO URL:**

```bash
cp .env.example .env
# Edit .env — set WIN_ISO_URL to a Windows Server ISO (URL or local path)
# Get a free evaluation ISO from https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server
```

2. **Build and run:**

```bash
./build.sh
```

This auto-detects the best build method: if QEMU is installed locally, it runs directly on the host; otherwise it builds and runs a Docker container. KVM is used when available (`/dev/kvm`), otherwise falls back to software emulation.

You can force a specific mode:

```bash
./build.sh --host    # Force host QEMU build
./build.sh --docker  # Force Docker build
```

3. **Connect once installation completes:**
   - **VNC:** `localhost:5900` (macOS opens Screen Sharing automatically; Linux uses `vncviewer`)
   - **Web console:** `http://localhost:6080` (Linux with noVNC installed)
   - **SSH:** `ssh administrator@localhost -p 2222`
   - **RDP:** `localhost:3389`
   - **WinRM:** `localhost:5985`

All ports are bound to `127.0.0.1` (localhost only).

## Configuration

All settings are in `.env` (see `.env.example`):

| Variable | Default | Description |
|---|---|---|
| `WIN_ISO_URL` | *(required)* | Windows ISO URL or local file path |
| `WIN_ISO_SHA256` | *(empty)* | SHA256 checksum for ISO verification |
| `WIN_PRODUCT_KEY` | *(empty)* | Product key (eval key used if empty) |
| `WIN_ADMIN_PASSWORD` | `P@ssw0rd!` | Administrator password |
| `WIN_HOSTNAME` | `WINCORE` | VM hostname |
| `WIN_TIMEZONE` | `UTC` | Windows timezone |
| `DISK_SIZE` | `60G` | Virtual disk size |
| `RAM_MB` | `4096` | VM RAM in MB |
| `CPU_CORES` | `2` | VM CPU cores |
| `VNC_DISPLAY` | `:0` | VNC display number |
| `HOST_RDP_PORT` | `3389` | Host port for RDP |
| `HOST_WINRM_PORT` | `5985` | Host port for WinRM |
| `HOST_SSH_PORT` | `2222` | Host port for SSH |
| `HOST_NOVNC_PORT` | `6080` | Host port for noVNC web console |
| `SHARED_DIR` | `./shared` | Host directory shared into guest as `Z:\` |
| `SSH_PUBKEY` | *(empty)* | Path to SSH public key for passwordless login |

## Shared Directory (Linux only)

The `shared/` directory on the host is mounted as `Z:\` inside the guest via VirtIO-FS — no network or SCP needed to pass files in and out. Just drop files into `./shared/` and they appear instantly at `Z:\` in the VM.

```bash
echo "hello from host" > shared/test.txt
ssh administrator@localhost -p 2222 "type Z:\test.txt"
```

Set `SHARED_DIR` in `.env` to change the host path.

> **Note:** VirtIO-FS requires `virtiofsd`, which is Linux-only. On macOS, shared directories are not available — use SCP or RDP file transfer instead.

## Persistence

The `images/` directory holds the virtual disk and downloaded ISOs. In Docker mode, it's automatically volume-mounted so artifacts persist across container restarts. On subsequent runs, the VM boots from disk instead of reinstalling.

## Rebuilding

To force a clean reinstall:

```bash
./build.sh --clean
```

This wipes the virtual disk and regenerated config, but preserves downloaded ISOs. Can be combined with `--host`/`--docker`.

## Performance Optimizations

The build is tuned for fast installation:

- **VirtIO disk** with `cache=unsafe` and `aio=io_uring` (Linux) / `aio=threads` (macOS) — dramatically faster I/O than IDE during Windows file extraction
- **VirtIO storage drivers** loaded during windowsPE pass via the VirtIO ISO
- **Windows Recovery disabled** — `reagentc /disable` during specialize skips RE partition
- **Unnecessary services disabled** — Windows Search, SysMain, Windows Update, telemetry, MSDTC, IPsec
- **Windows Defender fully removed** — saves ~137 MB RAM and ~90 MB disk (realtime disabled during install for speed)
- **WinSxS component store cleaned** with `/ResetBase` — reclaims ~1.3 GB
- **IME dictionaries removed** — Japanese/Chinese input not needed headless
- **VirtIO-FS** with `virtiofsd` (Linux only) — near-native shared filesystem via `vhost-user-fs-pci` and shared memory (`memfd`)
- **VirtIO serial** — fast guest-host communication channel
- **Chocolatey package manager** — reliable on Server Core (winget requires App Installer/Store framework which is unavailable)

## Monitoring

During installation you can watch progress via the noVNC web console (opens automatically) or any VNC client on port 5900. The post-install steps show status in the PowerShell window title (e.g. `[3/9] Installing VirtIO guest tools`). Detailed logs are written to `C:\setup.log` inside the VM.
