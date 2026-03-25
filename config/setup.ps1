# Post-install setup script - runs at first logon
# Bundled into the answer ISO and called from Autounattend.xml
$ErrorActionPreference = 'Continue'
$log = 'C:\setup.log'

# Disable Defender real-time monitoring upfront to avoid scanning every file written
Set-MpPreference -DisableRealtimeMonitoring $true 2>$null

# TLS 1.2 for all downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Log($msg) {
  $line = "[$(Get-Date -Format o)] $msg"
  $line | Tee-Object -FilePath $log -Append
}

function Step($n, $total, $name) {
  $host.UI.RawUI.WindowTitle = "[$($n)/$($total)] $name"
  Write-Host "=== [$($n)/$($total)] $name ===" -ForegroundColor Green
  Log "$name"
}

function Download($url, $out) {
  $maxRetries = 3
  for ($i = 1; $i -le $maxRetries; $i++) {
    try {
      (New-Object System.Net.WebClient).DownloadFile($url, $out)
      if (Test-Path $out) { return $true }
      Log "Download attempt $($i) of $($maxRetries): file not created for $($url)"
    }
    catch {
      Log "Download attempt $($i) of $($maxRetries) failed for $($url) - $_"
    }
    if ($i -lt $maxRetries) { Start-Sleep -Seconds 5 }
  }
  Log "ERROR: Failed to download $url after $maxRetries attempts"
  return $false
}

function RefreshPath {
  $machine = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
  $user = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
  $env:PATH = "$machine;$user"
}

$total = 12

# --- 1. VirtIO guest tools (installs NetKVM network driver — must come before any downloads) ---
Step 1 $total 'Installing VirtIO guest tools'
$found = $false
foreach ($d in 68..90) {
  $msi = [char]$d + ':\virtio-win-gt-x64.msi'
  if (Test-Path $msi) {
    Log "Found VirtIO MSI at $msi"
    Start-Process msiexec -ArgumentList '/i', $msi, '/qn', '/norestart', '/l*v', 'C:\virtio-install.log' -Wait
    Log "VirtIO install finished (exit: $LASTEXITCODE)"
    $found = $true
    break
  }
}
if (-not $found) { Log 'VirtIO MSI not found on any drive' }

# --- 2. WinRM (needs network) ---
Step 2 $total 'Enabling WinRM'
winrm quickconfig -quiet -force 2>&1 | Out-File $log -Append
winrm set winrm/config/service '@{AllowUnencrypted="true"}' 2>&1 | Out-File $log -Append
winrm set winrm/config/service/auth '@{Basic="true"}' 2>&1 | Out-File $log -Append

# --- 3. OpenSSH Server (GitHub release — capability/DISM unavailable on Server Core) ---
Step 3 $total 'Installing OpenSSH Server'
if (-not (Get-Service sshd -EA SilentlyContinue)) {
  $sshZip = "$env:TEMP\openssh.zip"
  $sshUrl = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip'
  # WebClient doesn't always follow GitHub redirects; use Invoke-WebRequest instead
  $maxRetries = 3
  $dlOk = $false
  for ($i = 1; $i -le $maxRetries; $i++) {
    try {
      Invoke-WebRequest -Uri $sshUrl -OutFile $sshZip -UseBasicParsing
      if ((Test-Path $sshZip) -and (Get-Item $sshZip).Length -gt 1MB) {
        $dlOk = $true
        break
      }
      Log "OpenSSH download attempt $i : file too small or missing"
    }
    catch {
      Log "OpenSSH download attempt $i failed: $_"
    }
    if ($i -lt $maxRetries) { Start-Sleep -Seconds 5 }
  }
  if ($dlOk) {
    Expand-Archive -Path $sshZip -DestinationPath 'C:\Program Files' -Force
    $installScript = 'C:\Program Files\OpenSSH-Win64\install-sshd.ps1'
    if (Test-Path $installScript) {
      & $installScript 2>&1 | Out-File $log -Append
      Log 'OpenSSH installed from GitHub zip'
    }
    else {
      Log "ERROR: install-sshd.ps1 not found after extraction"
    }
  }
  else {
    Log "ERROR: Failed to download OpenSSH after $maxRetries attempts"
  }
}
else {
  Log 'OpenSSH already installed'
}
# --- 3b. Deploy pre-generated SSH host keys (persistent fingerprints) ---
$sshHostKeySrc = $null
foreach ($d in 68..90) {
  $candidate = [char]$d + ':\ssh-hostkeys'
  if (Test-Path $candidate) {
    $sshHostKeySrc = $candidate
    break
  }
}
if ($sshHostKeySrc) {
  $sshDir = "$env:ProgramData\ssh"
  if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
  Get-ChildItem $sshHostKeySrc -File | ForEach-Object {
    Copy-Item $_.FullName "$sshDir\$($_.Name)" -Force
  }
  # Fix permissions on private keys — SYSTEM and Administrators only
  Get-ChildItem "$sshDir\ssh_host_*" -Exclude '*.pub' | ForEach-Object {
    icacls $_.FullName /inheritance:r /grant 'SYSTEM:F' /grant 'Administrators:F' 2>&1 | Out-Null
  }
  Log "SSH host keys deployed from answer ISO to $sshDir"
}
else {
  Log 'No pre-generated SSH host keys found, sshd will generate its own'
}

if (Get-Service sshd -EA SilentlyContinue) {
  Set-Service sshd -StartupType Automatic
  Start-Service sshd
  Log 'sshd started'
}
else {
  Log 'sshd not found after all install attempts'
}

# --- 3c. Deploy host SSH public key (if bundled in answer ISO) ---
$authKeySrc = $null
foreach ($d in 68..90) {
  $candidate = [char]$d + ':\authorized_keys'
  if (Test-Path $candidate) {
    $authKeySrc = $candidate
    break
  }
}
if (-not $authKeySrc) {
  # Also check the answer ISO label mount
  $candidate = 'A:\authorized_keys'
  if (Test-Path $candidate) { $authKeySrc = $candidate }
}
if ($authKeySrc) {
  $sshDir = "$env:ProgramData\ssh"
  if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
  $dest = "$sshDir\administrators_authorized_keys"
  Copy-Item $authKeySrc $dest -Force
  # Fix permissions: only Administrators and SYSTEM should have access
  icacls $dest /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' 2>&1 | Out-File $log -Append
  Log "SSH public key deployed to $dest"
}
else {
  Log 'No authorized_keys found on answer ISO, skipping SSH key deploy'
}

# --- 4. Install Chocolatey ---
Step 4 $total 'Installing Chocolatey'
try {
  Set-ExecutionPolicy Bypass -Scope Process -Force
  Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  RefreshPath
  Log "Chocolatey installed: $(choco --version 2>&1)"
}
catch {
  Log "ERROR: Chocolatey install failed: $_"
}

# --- 5. Install Git + Node.js via Chocolatey ---
Step 5 $total 'Installing Git + Node.js'
if (Get-Command choco -EA SilentlyContinue) {
  choco install git nodejs-lts winfsp TotalCommander -y --no-progress 2>&1 | Out-File $log -Append
  RefreshPath
  corepack enable 2>&1 | Out-File $log -Append
  Log "git: $(git --version 2>&1)"
  Log "node: $(node --version 2>&1)"
  Log "corepack enabled"
}
else {
  Log 'Chocolatey not available, skipping Git + Node.js'
}

# --- 6. Install VirtIO-FS driver and create mount service ---
Step 6 $total 'Installing VirtIO-FS driver and creating mount service'

# Step 6a: Install viofs driver if needed
$viofsInf = $null
foreach ($candidate in @(
  'C:\Program Files\Virtio-Win\VioFS\viofs.inf',
  'F:\viofs\2k22\amd64\viofs.inf',
  'E:\viofs\2k22\amd64\viofs.inf',
  'D:\viofs\2k22\amd64\viofs.inf'
)) {
  if (Test-Path $candidate) {
    $viofsInf = $candidate
    break
  }
}
if ($viofsInf) {
  Log "Installing viofs driver from $viofsInf"
  pnputil /add-driver $viofsInf /install 2>&1 | Out-File $log -Append
  pnputil /scan-devices 2>&1 | Out-File $log -Append
  Log "viofs driver installed, device rescan done"
}
else {
  Log 'viofs.inf not found on any drive'
}

# Step 6b: Register virtiofs with WinFsp Launcher and mount Z:\
$virtiofsBin = $null
foreach ($candidate in @(
  'C:\Program Files\Virtio-Win\VioFS\virtiofs.exe',
  'F:\viofs\2k22\amd64\virtiofs.exe'
)) {
  if (Test-Path $candidate) {
    $virtiofsBin = $candidate
    break
  }
}
$fsreg = 'C:\Program Files (x86)\WinFsp\bin\fsreg.bat'
$launchctl = 'C:\Program Files (x86)\WinFsp\bin\launchctl-x64.exe'
if ($virtiofsBin -and (Test-Path $fsreg)) {
  # Register virtiofs as a WinFsp service (%1=tag, %2=mountpoint)
  & $fsreg virtiofs $virtiofsBin '-d %2 -m %1' 2>&1 | Out-File $log -Append
  Log "virtiofs registered with WinFsp Launcher"
  # Mount immediately via launchctl
  if (Test-Path $launchctl) {
    & $launchctl start virtiofs hostshare Z: 2>&1 | Out-File $log -Append
    Start-Sleep -Seconds 3
    if (Test-Path 'Z:\') {
      Log "Z:\ mounted successfully via WinFsp Launcher"
    }
    else {
      Log "WARNING: Z:\ not available after launchctl start"
    }
    # Create scheduled task to auto-mount on every boot
    $action = New-ScheduledTaskAction -Execute $launchctl -Argument 'start virtiofs hostshare Z:'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    Register-ScheduledTask -TaskName 'VirtioFS-Mount' -Action $action -Trigger $trigger -Principal $principal -Force 2>&1 | Out-File $log -Append
    Log 'VirtioFS-Mount scheduled task created (auto-mount Z:\ at boot)'
  }
}
elseif ($virtiofsBin) {
  Log 'WinFsp not installed — cannot register virtiofs (install winfsp via Chocolatey)'
}
else {
  Log 'virtiofs.exe not found'
}

# --- 7. Configure Task Manager at logon (expanded mode) ---
Step 7 $total 'Configuring Task Manager startup'
reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' /v TaskManager /t REG_SZ /d 'taskmgr.exe' /f 2>&1 | Out-File $log -Append
# Default to expanded/details view instead of compact summary
$tmKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\TaskManager'
reg add $tmKey /v UseStatusSetting /t REG_DWORD /d 1 /f 2>&1 | Out-File $log -Append
# Total Commander as default file manager at logon
$tcExe = 'C:\Program Files\totalcmd\TOTALCMD64.EXE'
if (Test-Path $tcExe) {
  reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' /v TotalCommander /t REG_SZ /d "`"$tcExe`"" /f 2>&1 | Out-File $log -Append
  Log 'Total Commander set to launch at logon'
}
Log 'Task Manager set to launch at logon (expanded mode)'

# --- 8. Disable unnecessary services ---
Step 8 $total 'Disabling unnecessary services'
$disableServices = @(
  'DiagTrack',            # Telemetry
  'UsoSvc',               # Update Orchestrator
  'WaaSMedicSvc',         # Update Medic (re-enables Windows Update)
  'MSDTC',                # Distributed Transaction Coordinator
  'IKEEXT',               # IPsec Keying
  'iphlpsvc',             # IPv6 Helper
  'RemoteRegistry',       # Remote registry editing
  'gpsvc',                # Group Policy (no domain)
  'WinHttpAutoProxySvc',  # Proxy auto-discovery
  'mpssvc'                # Windows Firewall
)
foreach ($svc in $disableServices) {
  try {
    Stop-Service $svc -Force -EA SilentlyContinue
    Set-Service $svc -StartupType Disabled -EA SilentlyContinue
    Log "Disabled $svc"
  }
  catch {
    Log "Could not disable $($svc): $_"
  }
}

# --- 9. Disk cleanup (must run BEFORE Defender removal — that triggers pending reboot which blocks DISM) ---
Step 9 $total 'Cleaning up disk'
# WinSxS component store (~1.3 GB)
Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-File $log -Append
Log "WinSxS cleanup done"

# Clear temp files
Remove-Item "$env:TEMP\*" -Recurse -Force -EA SilentlyContinue
Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -EA SilentlyContinue
Log "Temp files cleared"

# Clear Chocolatey cache
if (Test-Path 'C:\ProgramData\chocolatey\cache') {
  Remove-Item 'C:\ProgramData\chocolatey\cache\*' -Recurse -Force -EA SilentlyContinue
  Log "Chocolatey cache cleared"
}

# Remove IME dictionaries (Japanese/Chinese input — not needed headless)
if (Test-Path 'C:\Windows\IME') {
  Remove-Item 'C:\Windows\IME\IMEJP' -Recurse -Force -EA SilentlyContinue
  Remove-Item 'C:\Windows\IME\IMETC' -Recurse -Force -EA SilentlyContinue
  Log "IME dictionaries removed"
}

# Remove Speech engines (~160 MB — not needed headless)
Remove-Item 'C:\Windows\Speech' -Recurse -Force -EA SilentlyContinue
Remove-Item 'C:\Windows\Speech_OneCore' -Recurse -Force -EA SilentlyContinue
Log "Speech engines removed"

# Remove Defender ATP leftover (~46 MB)
Remove-Item 'C:\Program Files\Windows Defender Advanced Threat Protection' -Recurse -Force -EA SilentlyContinue
Log "Defender ATP removed"

# --- 10. Uninstall Windows Defender (~137 MB RAM, ~90 MB disk; requires reboot to fully remove) ---
Step 10 $total 'Removing Windows Defender'
try {
  Uninstall-WindowsFeature Windows-Defender 2>&1 | Out-File $log -Append
  Log 'Windows Defender uninstalled (takes effect after reboot)'
}
catch {
  Log "Defender removal failed: $_"
}

# --- 11. Zero free space (allows qcow2 compaction on host) ---
Step 11 $total 'Zeroing free space for disk compaction'
$zeroFile = 'C:\zero.tmp'
try {
  # Write zeros to fill free space, then delete — makes qcow2 sparse regions detectable
  $stream = [System.IO.File]::Create($zeroFile)
  $buf = New-Object byte[] (1MB)
  while ($true) {
    $stream.Write($buf, 0, $buf.Length)
  }
}
catch {
  # Expected: disk full error stops the loop
}
finally {
  if ($stream) { $stream.Close() }
}
Remove-Item $zeroFile -Force -EA SilentlyContinue
Log 'Free space zeroed'

# --- 12. Done ---
Step 12 $total 'Setup complete'
Log 'All setup steps finished'
# Write completion marker — host waits for this via WinRM before declaring "complete"
Set-Content -Path 'C:\setup-complete.flag' -Value 'done'
