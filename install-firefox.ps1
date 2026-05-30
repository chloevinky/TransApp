<#
.SYNOPSIS
  Install/update the WhatsApp Translator extension in Firefox (Windows).

.DESCRIPTION
  Default mode `install` performs a PERMANENT install into your real (default)
  Firefox profile by sideloading the packaged extension. The add-on then loads
  automatically every time you start Firefox, and because it lives in your real
  profile your WhatsApp Web login persists (no re-login on every launch).

  Permanent install of an UNSIGNED extension only works on Firefox Developer
  Edition, Nightly, ESR, or Unbranded builds (release/beta enforce Mozilla
  signing and cannot be overridden). The script sets
  xpinstall.signatures.required=false and auto-enables the sideloaded add-on.

  Modes:
    install     Install/update into your default profile. [default]
    uninstall   Remove the extension from your default profile.
    run         Launch a throwaway profile with the extension (testing).
    build       Build an unsigned .xpi/.zip into .\dist.
    sign        Build a Mozilla-SIGNED .xpi (needs AMO credentials).
    lint        Validate the extension with web-ext.

  Options (install/uninstall):
    -Yes            Don't prompt; close Firefox automatically if it is running.
    -NoLaunch       Don't relaunch Firefox after installing.
    -ProfilePath    Use this profile directory instead of auto-detecting.

  Env overrides:
    $env:FIREFOX_BIN                          Path to firefox.exe to launch.
    $env:WEB_EXT_API_KEY / WEB_EXT_API_SECRET AMO credentials for `sign`.

  Requirements: Node.js + npm (web-ext via npx); a Firefox Dev/ESR/Nightly build.

.EXAMPLE
  .\install-firefox.ps1
  .\install-firefox.ps1 install -Yes
  .\install-firefox.ps1 uninstall
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('install', 'uninstall', 'run', 'build', 'xpi', 'zip', 'sign', 'lint', 'help')]
  [string]$Mode = 'install',
  [switch]$Yes,
  [switch]$NoLaunch,
  [string]$ProfilePath
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir
$DistDir = Join-Path $ScriptDir 'dist'
$AddonId = 'whatsapp-translator@transapp'

$UserJsBegin = '// >>> WhatsApp Translator (managed) - do not edit this block >>>'
$UserJsEnd   = '// <<< WhatsApp Translator (managed) <<<'

function Write-Info { param($m) Write-Host "==> $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "!! $m"  -ForegroundColor Yellow }
function Die       { param($m) Write-Host "error: $m" -ForegroundColor Red; exit 1 }

function Test-Tooling {
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Die "Node.js is required (https://nodejs.org). 'node' not found on PATH." }
  if (-not (Get-Command npx  -ErrorAction SilentlyContinue)) { Die "npm/npx is required. 'npx' not found on PATH." }
}

function Invoke-WebExt {
  param([Parameter(ValueFromRemainingArguments = $true)]$WebExtArgs)
  & npx --yes web-ext@latest @WebExtArgs
  if ($LASTEXITCODE -ne 0) { Die "web-ext exited with code $LASTEXITCODE" }
}

# --- Firefox discovery (prefer channels that allow unsigned add-ons) --------
function Find-Firefox {
  if ($env:FIREFOX_BIN -and (Test-Path $env:FIREFOX_BIN)) { return $env:FIREFOX_BIN }
  $candidates = @(
    "$env:ProgramFiles\Firefox Developer Edition\firefox.exe",
    "${env:ProgramFiles(x86)}\Firefox Developer Edition\firefox.exe",
    "$env:ProgramFiles\Firefox Nightly\firefox.exe",
    "${env:ProgramFiles(x86)}\Firefox Nightly\firefox.exe",
    "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
    "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe",
    "$env:LOCALAPPDATA\Mozilla Firefox\firefox.exe"
  )
  foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
  foreach ($root in 'HKLM:', 'HKCU:') {
    try {
      $val = (Get-Item "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe" -ErrorAction Stop).GetValue('')
      if ($val -and (Test-Path $val)) { return $val }
    } catch { }
  }
  foreach ($mr in 'HKLM:\SOFTWARE\Mozilla', 'HKLM:\SOFTWARE\WOW6432Node\Mozilla', 'HKCU:\SOFTWARE\Mozilla') {
    if (-not (Test-Path $mr)) { continue }
    foreach ($product in (Get-ChildItem $mr -ErrorAction SilentlyContinue)) {
      try {
        $cur = (Get-ItemProperty $product.PSPath -ErrorAction Stop).CurrentVersion
        if (-not $cur) { continue }
        $exe = (Get-ItemProperty (Join-Path $product.PSPath "$cur\Main") -ErrorAction Stop).PathToExe
        if ($exe -and (Test-Path $exe)) { return $exe }
      } catch { }
    }
  }
  return $null
}

# --- Default profile discovery from profiles.ini ----------------------------
function Get-DefaultProfile {
  param([string]$IniPath)
  $dir = Split-Path -Parent $IniPath
  $section = ''
  $cur = $null
  $installDefaults = New-Object System.Collections.Generic.List[string]
  $profiles = New-Object System.Collections.Generic.List[object]
  foreach ($raw in (Get-Content -LiteralPath $IniPath)) {
    $line = $raw.Trim()
    if ($line -match '^\[(.+)\]$') {
      $section = $matches[1]
      if ($section -like 'Profile*') { $cur = [pscustomobject]@{ Path = $null; Default = $false }; $profiles.Add($cur) }
      else { $cur = $null }
      continue
    }
    if ($line -match '^Default=(.+)$') {
      $val = $matches[1]
      if ($section -like 'Install*') { $installDefaults.Add($val) }
      elseif ($cur -and $val -eq '1') { $cur.Default = $true }
    }
    elseif ($line -match '^Path=(.+)$' -and $cur) { $cur.Path = $matches[1] }
  }
  $candidates = New-Object System.Collections.Generic.List[string]
  $installDefaults | ForEach-Object { $candidates.Add($_) }
  $profiles | Where-Object { $_.Default -and $_.Path } | ForEach-Object { $candidates.Add($_.Path) }
  if ($candidates.Count -eq 0) { return $null }

  $chosen = $candidates | Where-Object { $_ -match 'dev-edition|esr|nightly|unbranded' } | Select-Object -First 1
  if (-not $chosen) { $chosen = $candidates[0] }
  $chosen = $chosen -replace '/', '\'
  if ([System.IO.Path]::IsPathRooted($chosen)) { return $chosen }
  return (Join-Path $dir $chosen)
}

function Resolve-Profile {
  if ($ProfilePath) {
    if (-not (Test-Path $ProfilePath)) { Die "Profile dir not found: $ProfilePath" }
    return $ProfilePath
  }
  $ini = Join-Path $env:APPDATA 'Mozilla\Firefox\profiles.ini'
  if (-not (Test-Path $ini)) { Die "Could not find profiles.ini ($ini). Start Firefox once first." }
  $prof = Get-DefaultProfile $ini
  if (-not $prof) { Die "No default profile found in $ini" }
  return $prof
}

# --- Running-instance handling ----------------------------------------------
function Test-FirefoxRunning { [bool](Get-Process firefox -ErrorAction SilentlyContinue) }

function Confirm-Close {
  if ($Yes) { return $true }
  $ans = Read-Host "Firefox is running and must be closed to install. Close it now? [Y/n]"
  return ($ans -notmatch '^(n|no)$')
}

function Close-Firefox {
  Write-Info "Closing Firefox..."
  Get-Process firefox -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
  for ($i = 0; $i -lt 30; $i++) {
    if (-not (Test-FirefoxRunning)) { return }
    Start-Sleep -Milliseconds 500
  }
  Write-Warn "Firefox did not exit gracefully; forcing."
  Get-Process firefox -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 1
}

function Wait-ProfileUnlocked {
  param([string]$Prof)
  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Test-Path (Join-Path $Prof 'parent.lock'))) { return }
    Start-Sleep -Milliseconds 500
  }
}

# --- Managed user.js block --------------------------------------------------
function Remove-UserJsBlock {
  param([string]$UserJs)
  if (-not (Test-Path $UserJs)) { return }
  $out = New-Object System.Collections.Generic.List[string]
  $skip = $false
  foreach ($line in (Get-Content -LiteralPath $UserJs)) {
    if ($line -eq $UserJsBegin) { $skip = $true }
    if (-not $skip) { $out.Add($line) }
    if ($line -eq $UserJsEnd) { $skip = $false }
  }
  Set-Content -LiteralPath $UserJs -Value $out -Encoding ASCII
}

function Write-UserJs {
  param([string]$Prof)
  $userjs = Join-Path $Prof 'user.js'
  Remove-UserJsBlock $userjs
  $block = @(
    $UserJsBegin,
    'user_pref("xpinstall.signatures.required", false);',
    'user_pref("extensions.autoDisableScopes", 0);',
    'user_pref("extensions.startupScanScopes", 1);',
    $UserJsEnd
  )
  Add-Content -LiteralPath $userjs -Value $block -Encoding ASCII
}

# --- Build ------------------------------------------------------------------
function Build-Xpi {
  Test-Tooling
  Write-Info "Building extension package..."
  if (Test-Path $DistDir) { Remove-Item $DistDir -Recurse -Force }
  # Pipe to Out-Host so web-ext's stdout is shown but does NOT pollute this
  # function's return value (PowerShell returns all uncaptured pipeline output).
  Invoke-WebExt build --source-dir="$ScriptDir" --artifacts-dir="$DistDir" --overwrite-dest | Out-Host
  $xpi = Get-ChildItem -LiteralPath $DistDir -Filter *.zip -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $xpi) { Die "Build failed: no package produced in $DistDir" }
  return $xpi.FullName
}

function Start-FirefoxProfile {
  param([string]$Prof)
  $ff = Find-Firefox
  if (-not $ff) { Write-Warn "Firefox binary not found; start Firefox yourself."; return }
  Write-Info "Launching Firefox on WhatsApp Web..."
  Start-Process -FilePath $ff -ArgumentList @('--profile', $Prof, 'https://web.whatsapp.com/')
}

# --- Modes ------------------------------------------------------------------
switch ($Mode) {

  'install' {
    $prof = Resolve-Profile
    if (-not (Test-Path $prof)) { Die "Resolved profile does not exist: $prof" }
    Write-Info "Target Firefox profile: $prof"
    Write-Host "  (override with: .\install-firefox.ps1 install -ProfilePath 'C:\path\to\profile')"
    Write-Host ""

    $xpi = Build-Xpi

    if (Test-FirefoxRunning) {
      if (-not (Confirm-Close)) { Die "Firefox must be closed to install. Re-run with -Yes to auto-close." }
      Close-Firefox
    }
    Wait-ProfileUnlocked $prof

    Write-UserJs $prof
    $extdir = Join-Path $prof 'extensions'
    New-Item -ItemType Directory -Force -Path $extdir | Out-Null
    Copy-Item -LiteralPath $xpi -Destination (Join-Path $extdir "$AddonId.xpi") -Force

    Write-Host ""
    Write-Info "Installed/updated into your profile."
    Write-Host "  * $AddonId.xpi sideloaded into the profile's extensions\ folder."
    Write-Host "  * user.js: signature enforcement off + sideloaded add-on auto-enabled."
    Write-Host "  * Re-run this command any time to update after code changes."
    Write-Host ""
    Write-Warn "Unsigned add-ons only load on Firefox Developer Edition / Nightly / ESR /"
    Write-Warn "Unbranded. On release/beta Firefox this will NOT load - use '.\install-firefox.ps1 sign'."
    Write-Host ""

    if (-not $NoLaunch) {
      Start-FirefoxProfile $prof
      Write-Host "  * Firefox is starting. Open the toolbar puzzle icon -> WhatsApp Translator,"
      Write-Host "    enter your Anthropic API key, pick the language, toggle Translation ON."
    } else {
      Write-Host "  * Start Firefox to load the extension (relaunch skipped: -NoLaunch)."
    }
  }

  'uninstall' {
    $prof = Resolve-Profile
    Write-Info "Target Firefox profile: $prof"
    if (Test-FirefoxRunning) {
      if (-not (Confirm-Close)) { Die "Firefox must be closed to uninstall. Re-run with -Yes to auto-close." }
      Close-Firefox
    }
    Wait-ProfileUnlocked $prof
    Remove-Item -LiteralPath (Join-Path $prof "extensions\$AddonId.xpi") -Force -ErrorAction SilentlyContinue
    Remove-UserJsBlock (Join-Path $prof 'user.js')
    Write-Info "Removed $AddonId and cleared managed prefs from $prof."
    Write-Host "  (Only the managed user.js block was removed; your other settings are untouched.)"
  }

  { $_ -in 'run' } {
    Test-Tooling
    Write-Info "Launching a throwaway Firefox profile with the extension (testing)..."
    $ff = Find-Firefox
    $extra = @()
    if ($ff) { Write-Info "Using Firefox at: $ff"; $extra = @('--firefox', $ff) }
    else { Write-Warn "Could not auto-detect Firefox; web-ext will try its own default." }
    Write-Host "  * A fresh profile opens (you'll need to log into WhatsApp here)."
    Write-Host "  * For a persistent install into your real profile, use: .\install-firefox.ps1 install"
    Write-Host ""
    Invoke-WebExt run --source-dir="$ScriptDir" --start-url="https://web.whatsapp.com/" @extra
  }

  { $_ -in 'build', 'xpi', 'zip' } {
    $xpi = Build-Xpi
    Write-Info "Done. Artifact: $xpi"
    Write-Host ""
    Write-Host "To install it permanently in your main profile: .\install-firefox.ps1 install"
    Write-Host "To load temporarily: about:debugging#/runtime/this-firefox -> 'Load Temporary Add-on...'"
  }

  { $_ -in 'sign' } {
    Test-Tooling
    if (-not $env:WEB_EXT_API_KEY)    { Die "WEB_EXT_API_KEY is not set (AMO JWT issuer)." }
    if (-not $env:WEB_EXT_API_SECRET) { Die "WEB_EXT_API_SECRET is not set (AMO JWT secret)." }
    Write-Info "Submitting to Mozilla (AMO) for signing - unlisted channel ..."
    Invoke-WebExt sign --source-dir="$ScriptDir" --artifacts-dir="$DistDir" `
      --channel=unlisted --api-key="$env:WEB_EXT_API_KEY" --api-secret="$env:WEB_EXT_API_SECRET"
    Write-Info "Signed .xpi written to .\dist\. Open it in Firefox to install permanently (works on release too)."
  }

  { $_ -in 'lint' } {
    Test-Tooling
    Write-Info "Linting the extension with web-ext ..."
    Invoke-WebExt lint --source-dir="$ScriptDir"
  }

  default {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
  }
}
