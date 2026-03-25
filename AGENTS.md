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
- `scripts/05-start-qemu.sh` — launches QEMU (+ virtiofsd on Linux) with VirtIO devices, waits for SSH banner; after fresh install, auto-creates overlay and reboots from it
- `scripts/06-create-overlay.sh` — creates qcow2 overlay on top of base disk (all writes go to overlay, base stays pristine)
- `scripts/_env.sh` — shared env loader, defaults, helper functions, `require_cmd` for dependency checks with install hints
- `run.sh` — quick-start entry point: boots from overlay disk, supports `--reset` to discard changes
- `config/Autounattend.xml.tpl` — unattended install template (windowsPE + specialize + oobeSystem)
- `config/setup.ps1` — post-install script (runs at first logon via answer ISO)
- `Dockerfile` — Ubuntu 24.04 base with QEMU, genisoimage, curl, netcat

## Key Details

- Config via `.env` file (see `.env.example`)
- KVM auto-detected at runtime (`/dev/kvm`), falls back to TCG (always TCG on macOS)
- macOS support: `mkisofs` (cdrtools) instead of `genisoimage`, `aio=threads` instead of `io_uring`, no VirtIO-FS, Screen Sharing for VNC
- Default host ports: 13389 (RDP), 5900 (VNC), 2222 (SSH), 16080 (noVNC)
- `images/` dir holds all artifacts (ISO, qcow2 disk, overlay disk, answer ISO, virtio ISO) — gitignored
- **Overlay disk**: `images/windows-overlay.qcow2` is a thin qcow2 backed by `images/windows.qcow2`. All runtime writes go to the overlay; `./run.sh --reset` deletes and recreates it for instant revert to post-install state
- VirtIO devices: balloon (memory), serial (guest-host channel), virtio-fs (shared directory)
- VirtIO-FS (Linux only): `virtiofsd` runs on host, shares `SHARED_DIR` (default `./shared`) → guest `Z:\` via `vhost-user-fs-pci`
- On Linux with VirtIO-FS: QEMU uses `memory-backend-memfd` with `share=on` (required for vhost-user-fs); on macOS: plain memory
- VirtIO-FS guest mount: `virtiofs.exe` is a WinFsp filesystem, NOT a plain Windows service. Requires `winfsp` package (installed via Chocolatey). Registered with WinFsp Launcher via `fsreg.bat` (`-d %2 -m %1`), mounted via `launchctl-x64.exe start virtiofs hostshare Z:`. A `VirtioFS-Mount` scheduled task (SYSTEM, at startup) handles auto-mount on boot.
- OpenSSH Server: GitHub zip install (Add-WindowsCapability unavailable on Server Core)
- SSH host keys: pre-generated at build time (`images/ssh-hostkeys/`), bundled in answer ISO, deployed to `%ProgramData%\ssh\` before sshd starts — fingerprints are stable across rebuilds (use `--clean` to regenerate)
- Post-install (`setup.ps1`): VirtIO guest tools, OpenSSH, viofs driver + mount, Chocolatey + Git + Node.js + WinFsp, then cleanup (Defender removal, service disable, WinSxS cleanup, temp/IME purge)
- All setup steps log to `C:\setup.log` with timestamps and visible progress in VNC
- `setup.ps1` is copied to `C:\` during specialize pass (answer ISO may be unmounted by first logon)

## Gotchas

- **Answer ISO not available at first logon**: CD-ROMs can be ejected/unmounted after Windows install completes. The specialize pass copies `setup.ps1` to `C:\` while the ISO is still mounted, and the FirstLogonCommand runs it from `C:\setup.ps1`.
- **winget doesn't work on Server Core**: Requires App Installer/Microsoft Store framework. Use Chocolatey instead.
- **PowerShell syntax in unattend scripts**: Avoid multi-line `+` string concatenation (PS treats line 1 as complete statement), em dashes/unicode in strings (encoding issues), `} catch {` on same line (put `catch`/`else` on own line after `}`), and `$var/` or `${var}:` in strings (PS treats `/` and `:` as drive/scope modifiers — use `$($var)` subexpressions instead).
- **`Add-WindowsCapability -Online` for OpenSSH**: Fails on Server Core when CBS source is unavailable. Always have a fallback.
- **VirtIO-FS requires WinFsp**: `virtiofs.exe` depends on `winfsp-x64.dll` (WinFsp). Without it, service starts but silently fails to mount. The VirtIO guest tools MSI installs its own `VirtioFsSvc` service (demand start, no args) which doesn't work — must use WinFsp Launcher (`fsreg.bat` + `launchctl-x64.exe`) instead.
- **SSH default shell is cmd.exe**: When running PowerShell commands over SSH, wrap in `powershell -Command "..."`. Beware of `$` variable expansion by the local shell — use single quotes on the outer layer.

## Status

Testing in progress. All scripts implemented, iterating on post-install reliability.
