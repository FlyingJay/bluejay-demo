<#
.SYNOPSIS
  Adds this Windows computer to bluejay's dispatch worker pool.

.DESCRIPTION
  The Windows counterpart of setup.sh (see scripts/dev_worker/README.md).
  Workers run inside WSL2, because the jobs they run (Claude Code, the
  repo's bash build and check scripts) need a Linux shell. Windows Task
  Scheduler starts them every minute, so no WSL window has to stay open.

  install (the default):
    1. Installs WSL2 and the distro (Ubuntu) if they're missing. That step
       needs administrator rights and usually a restart; run this script
       again afterwards.
    2. In WSL (wsl_bootstrap.sh): installs git, gh, Node and Claude Code,
       signs in to GitHub (reusing this computer's GitHub CLI sign-in when
       there is one) and to Claude Code, and clones the repo into ~/bluejay.
    3. Runs setup.sh install there with the worker token from Dev Workers
       → Add a computer.
    4. Offers to stop Windows sleeping while plugged in: a computer that
       sleeps mid-job loses the job's lease and uses up an attempt.

  doctor, status, pause, resume and uninstall run the same setup.sh
  command in WSL.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\dev_worker\setup.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\dev_worker\setup.ps1 install -Workers 2
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\dev_worker\setup.ps1 status
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('install', 'doctor', 'status', 'pause', 'resume', 'uninstall')]
  [string]$Command = 'install',
  [ValidateRange(1, 16)]
  [int]$Workers = 1,
  [string]$Distro = 'Ubuntu',
  [switch]$Now
)

# Continue: every native call's exit code is checked explicitly, and with 'Stop'
# Windows PowerShell 5.1 turns any stderr output from wsl.exe or gh.exe into an error.
$ErrorActionPreference = 'Continue'
# wsl.exe's own messages (--install, --set-version) print as UTF-8 with this set.
$env:WSL_UTF8 = '1'
# Windows PowerShell 5.1 (and PowerShell 7 before 7.3, or in Legacy mode) passes double quotes
# inside an argument to native programs unescaped, so wsl.exe splits the argument there.
$LegacyArgPassing = $PSVersionTable.PSVersion -lt [version]'7.3' -or $PSNativeCommandArgumentPassing -eq 'Legacy'
$Bootstrap = Join-Path $PSScriptRoot 'wsl_bootstrap.sh'

function Write-Step([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Stop-Setup([string]$Text) { Write-Host $Text -ForegroundColor Red; exit 1 }

function Test-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The distro's registration (DistributionName, Version, DefaultUid), read from the registry
# so nothing runs wsl.exe before WSL is installed: on a computer without WSL, `wsl -l` sits
# for about a minute offering to install it, with no output, before it fails.
function Get-DistroRegistration {
  $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  if (-not (Test-Path $lxss)) { return $null }
  foreach ($key in Get-ChildItem $lxss) {
    $props = Get-ItemProperty $key.PSPath
    if ($props.DistributionName -eq $Distro) { return $props }
  }
  return $null
}

function Test-Distro { return $null -ne (Get-DistroRegistration) }

# The distro's WSL version (1 or 2), or 0 if it isn't registered.
function Get-DistroVersion {
  $registration = Get-DistroRegistration
  if ($registration) { return [int]$registration.Version }
  return 0
}

# Escapes each argument's double quotes (and the backslashes before them, and trailing
# backslashes in an argument PowerShell wraps in quotes) the way wsl.exe parses its command
# line, and keeps empty arguments, which legacy passing drops. Only needed where PowerShell
# doesn't do it itself.
function ConvertTo-NativeArgs([string[]]$NativeArgs) {
  if (-not $LegacyArgPassing) { return $NativeArgs }
  return @($NativeArgs | ForEach-Object {
    if ($_ -eq '') { return '""' }
    $arg = $_ -replace '(\\*)"', '$1$1\"'
    if ($arg -match '\s') { $arg = $arg -replace '(\\+)$', '$1$1' }
    $arg
  })
}

# Runs a Linux command in the distro, attached to this console when its output isn't
# captured (so sudo and the sign-ins can prompt); read $LASTEXITCODE afterwards. --exec hands
# the arguments straight to the command. With `--`, wsl.exe runs them through the distro's
# shell, which strips the backslashes from Windows paths and re-expands the quotes and $
# in a bash -c script. Every command this script runs in WSL goes through here.
function Invoke-InDistro([string[]]$CommandArgs) {
  & wsl.exe -d $Distro --exec @(ConvertTo-NativeArgs $CommandArgs)
}

# Runs setup.sh <command> from the WSL clone.
function Invoke-Setup([string[]]$SetupArgs) {
  Invoke-InDistro (@('bash', '-lc', 'bash "$HOME/bluejay/scripts/dev_worker/setup.sh" "$@"', 'setup.sh') + $SetupArgs)
  exit $LASTEXITCODE
}

# --no-launch: otherwise wsl --install opens the distro in the administrator window to create
# the Linux user and leaves a shell open there, and this script waits until it's closed.
function Install-Wsl {
  Write-Step "Installing WSL2 and $Distro"
  $installArgs = @('--install', '-d', $Distro, '--no-launch')
  if (-not (Test-Admin)) {
    Write-Host 'This step needs administrator rights; approve the prompt that opens.'
    $proc = Start-Process -FilePath 'wsl.exe' -ArgumentList $installArgs -Verb RunAs -Wait -PassThru
    if ($proc.ExitCode -ne 0) { Stop-Setup "wsl --install exited $($proc.ExitCode)." }
  } else {
    & wsl.exe @installArgs
    if ($LASTEXITCODE -ne 0) { Stop-Setup "wsl --install exited $LASTEXITCODE." }
  }
  Write-Host ''
  Write-Host "Next: if Windows asks to restart, restart. Then open $Distro from the Start menu once to create"
  Write-Host 'your Linux user, and run this script again.'
  exit 0
}

# The GitHub CLI's token on the Windows side, if it's signed in: WSL's gh reuses it.
function Get-WindowsGhToken {
  if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) { return '' }
  $token = & gh.exe auth token 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $token) { return '' }
  return ([string]$token).Trim()
}

function Read-WorkerToken {
  Invoke-InDistro @('bash', '-c', 'test -s "$HOME/.config/bluejay/dev-worker-token" || test -f "$HOME/bluejay_keys/bluejay-firebase-adminsdk.json"') | Out-Null
  if ($LASTEXITCODE -eq 0) { return '' }
  Write-Host ''
  Write-Host 'Create a worker token in the Dev Workers app (Add a computer) and paste it here.'
  $secure = Read-Host 'Worker token' -AsSecureString
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
  $token = $token.Trim()
  if (-not $token.StartsWith('bjw_')) { Stop-Setup "That doesn't look like a worker token (they start with bjw_)." }
  return $token
}

# The current power plan's sleep timeout on AC power, in seconds (0 = never), or -1 if unknown.
function Get-AcSleepSeconds {
  $out = & powercfg.exe /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null
  foreach ($line in $out) {
    if ($line -match 'AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { return [Convert]::ToInt32($Matches[1], 16) }
  }
  return -1
}

function Set-NoSleepOnAc {
  $seconds = Get-AcSleepSeconds
  if ($seconds -eq 0) { Write-Host 'Sleep while plugged in: never. ok'; return }
  $current = if ($seconds -gt 0) { "after $([math]::Round($seconds / 60)) minutes" } else { 'at an unknown time' }
  $answer = Read-Host "Windows sleeps $current while plugged in. Set it to never, so jobs aren't cut off? [Y/n]"
  if ($answer -eq '' -or $answer -match '^[Yy]') {
    & powercfg.exe /change standby-timeout-ac 0
    Write-Host 'Sleep while plugged in: never.'
  } else {
    Write-Host 'Left as is. A job running when the computer sleeps is retried later.'
  }
}

if ($Command -ne 'install') {
  if (-not (Test-Distro)) { Stop-Setup "$Distro isn't installed in WSL: run setup.ps1 install first." }
  $passArgs = @($Command)
  if ($Command -eq 'uninstall' -and $Now) { $passArgs += '--now' }
  Invoke-Setup $passArgs
}

Write-Step 'WSL'
if (-not (Test-Distro)) { Install-Wsl }
$version = Get-DistroVersion
if ($version -eq 1) {
  Write-Host "$Distro runs on WSL 1; converting it to WSL 2..."
  & wsl.exe --set-version $Distro 2
  if ($LASTEXITCODE -ne 0) { Stop-Setup "wsl --set-version $Distro 2 failed." }
}
Write-Host "$Distro on WSL 2. ok"

$workerToken = Read-WorkerToken
$ghToken = Get-WindowsGhToken
if ($ghToken) { Write-Host 'Reusing this computer''s GitHub CLI sign-in inside WSL.' }

# Secrets reach WSL as environment variables shared through WSLENV, never on a command line.
$env:BJ_GH_TOKEN = $ghToken
$env:BJ_WORKER_TOKEN = $workerToken
$env:WSLENV = (@('BJ_GH_TOKEN/u', 'BJ_WORKER_TOKEN/u') + @($env:WSLENV -split ':' | Where-Object { $_ })) -join ':'
try {
  $bootstrapPath = (Invoke-InDistro @('wslpath', '-a', $Bootstrap) 2>$null | Select-Object -First 1)
  if (-not $bootstrapPath) { Stop-Setup "Couldn't find $Bootstrap from inside WSL." }
  # The script is read with CRs stripped, in case git checked it out with Windows line endings;
  # stdin stays the console, for sudo and the sign-ins.
  Invoke-InDistro @('bash', '-c', 'bash <(tr -d "\r" < "$0") "$@"', $bootstrapPath, '--workers', "$Workers")
  $code = $LASTEXITCODE
} finally {
  Remove-Item Env:BJ_GH_TOKEN, Env:BJ_WORKER_TOKEN -ErrorAction SilentlyContinue
}
if ($code -ne 0) { Stop-Setup 'Setup inside WSL stopped (see above). Fix what it names and run setup.ps1 again.' }

Write-Step 'Power'
Set-NoSleepOnAc

Write-Host ''
Write-Host 'Done. The workers run whenever you''re signed in to Windows (a locked screen is fine).' -ForegroundColor Green
Write-Host 'Task Scheduler lists them as BluejayDevWorker<n>; setup.ps1 status shows what they''re doing.'
