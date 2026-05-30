<#
.SYNOPSIS
  Build and install the WhatsApp Translator extension on Firefox (Windows).

.DESCRIPTION
  Windows counterpart of install-firefox.sh. Firefox cannot permanently install
  an unsigned Manifest V3 extension on the release channel — it must be signed by
  Mozilla (AMO) or loaded temporarily. This script supports every practical path.

  Modes:
    run     Launch Firefox with the extension loaded (temporary; best for testing). [default]
    build   Build an unsigned .xpi/.zip into .\dist
    sign    Build a Mozilla-SIGNED .xpi for permanent install (needs AMO API credentials)
    lint    Validate the extension with web-ext
    help    Show this help

  Requirements: Node.js + npm on PATH (web-ext is fetched on demand via npx).
                Firefox installed for the `run` mode.

  AMO credentials for `sign` (https://addons.mozilla.org/developers/addon/api/key/):
    $env:WEB_EXT_API_KEY    = "user:xxxxx:123"
    $env:WEB_EXT_API_SECRET = "xxxxxxxx"

.EXAMPLE
  .\install-firefox.ps1
  .\install-firefox.ps1 build
  .\install-firefox.ps1 sign
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('run', 'build', 'xpi', 'zip', 'sign', 'lint', 'help')]
  [string]$Mode = 'run'
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir
$DistDir = Join-Path $ScriptDir 'dist'

function Write-Info { param($m) Write-Host "==> $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "!! $m"  -ForegroundColor Yellow }
function Die       { param($m) Write-Host "error: $m" -ForegroundColor Red; exit 1 }

# --- Prerequisites ---------------------------------------------------------
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Die "Node.js is required (https://nodejs.org). 'node' not found on PATH."
}
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
  Die "npm/npx is required. 'npx' not found on PATH."
}

# Run web-ext through npx so no global install is needed.
function Invoke-WebExt {
  param([Parameter(ValueFromRemainingArguments = $true)]$WebExtArgs)
  & npx --yes web-ext@latest @WebExtArgs
  if ($LASTEXITCODE -ne 0) { Die "web-ext exited with code $LASTEXITCODE" }
}

# --- Firefox detection -----------------------------------------------------
# web-ext's own auto-detection only reads HKLM and misses per-user (HKCU)
# installs, so we resolve the path ourselves and pass it explicitly.
function Find-Firefox {
  # 1) Common filesystem locations (all channels, both bitnesses).
  $candidates = @(
    "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
    "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe",
    "$env:ProgramFiles\Firefox Developer Edition\firefox.exe",
    "${env:ProgramFiles(x86)}\Firefox Developer Edition\firefox.exe",
    "$env:ProgramFiles\Firefox Nightly\firefox.exe",
    "${env:ProgramFiles(x86)}\Firefox Nightly\firefox.exe",
    "$env:LOCALAPPDATA\Mozilla Firefox\firefox.exe"
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return $c }
  }

  # 2) "App Paths" (not WOW-redirected; covers HKLM and per-user HKCU).
  foreach ($root in 'HKLM:', 'HKCU:') {
    $key = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe"
    try {
      $val = (Get-Item $key -ErrorAction Stop).GetValue('')
      if ($val -and (Test-Path $val)) { return $val }
    } catch { }
  }

  # 3) Versioned Mozilla product keys (HKLM/HKCU + 32-bit WOW6432Node view).
  $mozRoots = @(
    'HKLM:\SOFTWARE\Mozilla',
    'HKLM:\SOFTWARE\WOW6432Node\Mozilla',
    'HKCU:\SOFTWARE\Mozilla'
  )
  foreach ($mr in $mozRoots) {
    if (-not (Test-Path $mr)) { continue }
    foreach ($product in (Get-ChildItem $mr -ErrorAction SilentlyContinue)) {
      try {
        $cur = (Get-ItemProperty $product.PSPath -ErrorAction Stop).CurrentVersion
        if (-not $cur) { continue }
        $main = Join-Path $product.PSPath "$cur\Main"
        $exe  = (Get-ItemProperty $main -ErrorAction Stop).PathToExe
        if ($exe -and (Test-Path $exe)) { return $exe }
      } catch { }
    }
  }
  return $null
}

# --- Modes -----------------------------------------------------------------
switch ($Mode) {

  { $_ -in 'run' } {
    Write-Info "Launching Firefox with the WhatsApp Translator extension loaded (temporary install)..."
    $ff = Find-Firefox
    $extra = @()
    if ($ff) {
      Write-Info "Using Firefox at: $ff"
      $extra = @('--firefox', $ff)
    } else {
      Write-Warn "Could not auto-detect Firefox; web-ext will try its own default."
      Write-Warn "If it fails, install Firefox or pass the path with --firefox manually."
    }
    Write-Host ""
    Write-Host "  * A fresh Firefox profile opens with the extension installed."
    Write-Host "  * Click the toolbar puzzle icon -> WhatsApp Translator -> enter your"
    Write-Host "    Anthropic API key, pick the source language, toggle Translation ON."
    Write-Host "  * The extension stays installed until you close this Firefox window."
    Write-Host ""
    Invoke-WebExt run --source-dir="$ScriptDir" --start-url="https://web.whatsapp.com/" @extra
  }

  { $_ -in 'build', 'xpi', 'zip' } {
    Write-Info "Building unsigned package into .\dist ..."
    Invoke-WebExt build --source-dir="$ScriptDir" --artifacts-dir="$DistDir" --overwrite-dest
    Write-Host ""
    Write-Info "Done. Artifact is in .\dist\"
    Write-Host ""
    Write-Host "To install the unsigned build in Firefox:" -ForegroundColor White
    Write-Host "  1. Open  about:debugging#/runtime/this-firefox"
    Write-Host "  2. Click 'Load Temporary Add-on...' and pick the .zip in .\dist"
    Write-Host "     (Temporary load works on ALL Firefox builds; removed on restart.)"
    Write-Host ""
    Write-Host "  For a PERMANENT unsigned install you need Firefox"
    Write-Host "  Developer Edition / Nightly / ESR, then in about:config set:"
    Write-Host "     xpinstall.signatures.required = false"
    Write-Host "  and open the .zip via about:addons -> gear -> 'Install Add-on From File...'."
    Write-Host ""
    Write-Host "  For a permanent install on release Firefox, run: .\install-firefox.ps1 sign"
  }

  { $_ -in 'sign' } {
    if (-not $env:WEB_EXT_API_KEY)    { Die "WEB_EXT_API_KEY is not set (AMO JWT issuer). See the script header." }
    if (-not $env:WEB_EXT_API_SECRET) { Die "WEB_EXT_API_SECRET is not set (AMO JWT secret). See the script header." }
    Write-Info "Submitting to Mozilla (AMO) for signing - unlisted channel ..."
    Invoke-WebExt sign --source-dir="$ScriptDir" --artifacts-dir="$DistDir" `
      --channel=unlisted --api-key="$env:WEB_EXT_API_KEY" --api-secret="$env:WEB_EXT_API_SECRET"
    Write-Host ""
    Write-Info "Signed .xpi written to .\dist\"
    Write-Host "Install it permanently: open the .xpi in Firefox, or drag it onto a Firefox window."
  }

  { $_ -in 'lint' } {
    Write-Info "Linting the extension with web-ext ..."
    Invoke-WebExt lint --source-dir="$ScriptDir"
  }

  default {
    # help / -h / --help
    Get-Help $MyInvocation.MyCommand.Path -Detailed
  }
}
