# qwin

Windows Server Core in a container — zero-touch install, KVM-accelerated, ready to SSH in minutes.

## What's included

Out of the box, the VM comes pre-configured with:

- **OpenSSH Server** — SSH into the VM from your terminal or attach a VS Code remote session
- **Dev-ready** — Git, Node.js LTS, and Corepack pre-installed so you can `git clone` and start coding inside it
- **Lean image** — Defender removed, firewall disabled, WinSxS cleaned, free space zeroed for qcow2 compaction
- **VirtIO guest tools** — optimized storage/network drivers and memory balooning
- **VirtIO-FS** — shared host directory mounted as `Z:\` in the guest

## Prerequisites

- **Docker** (or a compatible runtime). On macOS, [OrbStack](https://orbstack.dev) is recommended.
- **KVM** strongly recommended — install runs in ~20-30 min with KVM vs 2-4 hours without. Note: macOS runtimes don't expose nested KVM yet, so installs will use software emulation.

## Building the Image

Windows is proprietary software — redistributing a Docker image containing a Windows installation or ISO would violate Microsoft's licensing terms. You must supply your own Windows Server ISO (evaluation copies are free from Microsoft).

1. **Create `.env` with your Windows ISO URL:**

```bash
cp .env.example .env
```

The only required setting is `WIN_ISO_URL` — point it to a Windows Server ISO (URL or local path). Get a free evaluation ISO from [Microsoft](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server). Everything else has sensible defaults (see [Configuration](#configuration)).

2. **Build the Docker image:**

```bash
docker build -t wincore .
```

3. **Run with KVM acceleration (recommended):**

```bash
docker run -it --rm \
  --device /dev/kvm \
  -v $(pwd)/images:/opt/winvm/images \
  -p 3389:3389 \
  -p 5985:5985 \
  -p 5900:5900 \
  --env-file .env \
  wincore
```

Without KVM (software emulation — much slower):

```bash
docker run -it --rm \
  -v $(pwd)/images:/opt/winvm/images \
  -p 3389:3389 \
  -p 5985:5985 \
  -p 5900:5900 \
  --env-file .env \
  wincore
```

4. **Connect once installation completes:**
   - **RDP:** `localhost:3389`
   - **SSH:** `localhost:2222`
   - **WinRM:** `localhost:5985`
   - **VNC:** `localhost:5900` (for monitoring install progress)

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
| `SHARED_DIR` | `./shared` | Host directory shared into guest as `Z:\` |

## Shared Directory

The `shared/` directory on the host is mounted as `Z:\` inside the guest via VirtIO-FS — no network or SCP needed to pass files in and out. Just drop files into `./shared/` and they appear instantly at `Z:\` in the VM.

```bash
echo "hello from host" > shared/test.txt
ssh administrator@localhost -p 2222 "type Z:\test.txt"
```

Set `SHARED_DIR` in `.env` to change the host path.

## Persistence

The `images/` directory holds the virtual disk and downloaded ISOs. Mount it as a volume to persist across container restarts:

```bash
-v $(pwd)/images:/opt/winvm/images
```

On subsequent runs, existing artifacts are reused — the VM boots from disk instead of reinstalling.

## Rebuilding

To force a clean reinstall:

```bash
./build.sh --clean
```

This wipes the virtual disk and regenerated config, but preserves downloaded ISOs.

## Performance Optimizations

The build is tuned for fast installation:

- **VirtIO disk** with `cache=unsafe` and `aio=io_uring` — dramatically faster I/O than IDE during Windows file extraction
- **VirtIO storage drivers** loaded during windowsPE pass via the VirtIO ISO
- **Windows Recovery disabled** — `reagentc /disable` during specialize skips RE partition
- **Unnecessary services disabled** — Windows Search, SysMain, Windows Update, telemetry, MSDTC, IPsec
- **Windows Defender fully removed** — saves ~137 MB RAM and ~90 MB disk (realtime disabled during install for speed)
- **WinSxS component store cleaned** with `/ResetBase` — reclaims ~1.3 GB
- **IME dictionaries removed** — Japanese/Chinese input not needed headless
- **VirtIO-FS** with `virtiofsd` — near-native shared filesystem via `vhost-user-fs-pci` and shared memory (`memfd`)
- **VirtIO serial** — fast guest-host communication channel
- **Chocolatey package manager** — reliable on Server Core (winget requires App Installer/Store framework which is unavailable)

## Monitoring

During installation you can watch progress via VNC. The post-install steps show status in the PowerShell window title (e.g. `[3/9] Installing VirtIO guest tools`). Detailed logs are written to `C:\setup.log` inside the VM.
