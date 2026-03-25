**Keep `AGENTS.md` updated with project status.**

Docker + QEMU project for running Windows Server Core with fully unattended installation.

## Project Structure

- `build.sh` — smart entry point: auto-detects host QEMU vs Docker, supports `--host`/`--docker`/`--clean`
- `scripts/build.sh` — actual build orchestrator, calls scripts 01–05 in order
- `scripts/01-fetch-iso.sh` — downloads or symlinks Windows ISO
- `scripts/01b-fetch-virtio.sh` — downloads VirtIO guest drivers ISO from Fedora
- `scripts/02-create-disk.sh` — creates qcow2 virtual disk
- `scripts/03-gen-autounattend.sh` — renders Autounattend.xml from template via sed
- `scripts/03b-gen-ssh-hostkeys.sh` — generates persistent SSH host keys (ed25519, rsa, ecdsa) in `images/ssh-hostkeys/`
- `scripts/04-gen-answer-iso.sh` — bundles Autounattend.xml + setup.ps1 + SSH host keys into answer ISO (uses `genisoimage` or `mkisofs`)
- `scripts/05-start-qemu.sh` — launches QEMU (+ virtiofsd on Linux) with VirtIO devices, waits for WinRM health check
- `scripts/_env.sh` — shared env loader, defaults, helper functions, `require_cmd` for dependency checks with install hints
- `config/Autounattend.xml.tpl` — unattended install template (windowsPE + specialize + oobeSystem)
- `config/setup.ps1` — post-install script (runs at first logon via answer ISO)
- `Dockerfile` — Ubuntu 24.04 base with QEMU, genisoimage, curl, netcat

## Key Details

- Config via `.env` file (see `.env.example`)
- KVM auto-detected at runtime (`/dev/kvm`), falls back to TCG (always TCG on macOS)
- macOS support: `mkisofs` (cdrtools) instead of `genisoimage`, `aio=threads` instead of `io_uring`, no VirtIO-FS, Screen Sharing for VNC
- Ports: 3389 (RDP), 5985 (WinRM), 5900 (VNC), 2222 (SSH)
- `images/` dir holds all artifacts (ISO, qcow2 disk, answer ISO, virtio ISO) — gitignored
- VirtIO devices: balloon (memory), serial (guest-host channel), virtio-fs (shared directory)
- VirtIO-FS (Linux only): `virtiofsd` runs on host, shares `SHARED_DIR` (default `./shared`) → guest `Z:\` via `vhost-user-fs-pci`
- On Linux with VirtIO-FS: QEMU uses `memory-backend-memfd` with `share=on` (required for vhost-user-fs); on macOS: plain memory
- Guest-side `VirtioFsSvc` Windows service runs `virtiofs.exe -d Z: -m hostshare` (auto-start)
- OpenSSH Server: GitHub zip install (Add-WindowsCapability unavailable on Server Core)
- SSH host keys: pre-generated at build time (`images/ssh-hostkeys/`), bundled in answer ISO, deployed to `%ProgramData%\ssh\` before sshd starts — fingerprints are stable across rebuilds (use `--clean` to regenerate)
- Post-install (`setup.ps1`): WinRM, EMS/serial, VirtIO guest tools, viofs driver + mount, Chocolatey + Git + Node.js, then cleanup (Defender removal, service disable, WinSxS cleanup, temp/IME purge)
- All setup steps log to `C:\setup.log` with timestamps and visible progress in VNC
- `setup.ps1` is copied to `C:\` during specialize pass (answer ISO may be unmounted by first logon)

## Gotchas

- **Answer ISO not available at first logon**: CD-ROMs can be ejected/unmounted after Windows install completes. The specialize pass copies `setup.ps1` to `C:\` while the ISO is still mounted, and the FirstLogonCommand runs it from `C:\setup.ps1`.
- **winget doesn't work on Server Core**: Requires App Installer/Microsoft Store framework. Use Chocolatey instead.
- **PowerShell syntax in unattend scripts**: Avoid multi-line `+` string concatenation (PS treats line 1 as complete statement), em dashes/unicode in strings (encoding issues), `} catch {` on same line (put `catch`/`else` on own line after `}`), and `$var/` or `${var}:` in strings (PS treats `/` and `:` as drive/scope modifiers — use `$($var)` subexpressions instead).
- **`Add-WindowsCapability -Online` for OpenSSH**: Fails on Server Core when CBS source is unavailable. Always have a fallback.

## Status

Testing in progress. All scripts implemented, iterating on post-install reliability.
