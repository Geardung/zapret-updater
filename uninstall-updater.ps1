<#
.SYNOPSIS
    Uninstaller for zapret auto-updater.
    Usage: irm https://geardung.github.io/zapret-updater/uninstall-updater.ps1 | iex
#>

# --- Admin check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  Requesting administrator privileges..." -ForegroundColor Yellow
    $scriptUrl = "https://geardung.github.io/zapret-updater/uninstall-updater.ps1"
    $tempFile = Join-Path $env:TEMP "zapret-uninstall-updater.ps1"
    Invoke-WebRequest -Uri $scriptUrl -OutFile $tempFile -UseBasicParsing
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$tempFile`""
    exit
}

$ErrorActionPreference = "Stop"

function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Err  { param([string]$Msg) Write-Host "  [ERR] $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "  [..] $Msg" -ForegroundColor Cyan }

Write-Host ""
Write-Host "  Zapret Auto-Updater Uninstaller" -ForegroundColor Cyan
Write-Host "  ================================" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: Remove Scheduled Task ---
$taskName = "ZapretAutoUpdate"
Write-Info "Removing scheduled task '$taskName'..."
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Ok "Scheduled task removed"
} else {
    Write-Info "Task '$taskName' not found (already removed?)"
}

# --- Step 2: Detect zapret path ---
Write-Info "Detecting zapret installation..."
$regPath = "HKLM:\System\CurrentControlSet\Services\zapret"
$zapretPath = $null

try {
    $imagePath = (Get-ItemProperty -Path $regPath -Name "ImagePath" -ErrorAction Stop).ImagePath
    if ($imagePath -match '^"([^"]+)"') {
        $binExe = $Matches[1]
        $zapretPath = Split-Path (Split-Path $binExe -Parent) -Parent
    }
} catch {}

if (-not $zapretPath -or -not (Test-Path $zapretPath)) {
    Write-Info "Zapret path not found from registry. Skipping file cleanup."
    Write-Host ""
    Write-Host "  Done." -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Ok "Found zapret at: $zapretPath"

# --- Step 3: Remove updater script ---
$updaterPath = Join-Path $zapretPath "utils\zapret-auto-update.ps1"
Write-Info "Removing updater script..."
if (Test-Path $updaterPath) {
    Remove-Item $updaterPath -Force
    Write-Ok "Removed: $updaterPath"
} else {
    Write-Info "Updater script not found (already removed?)"
}

# --- Step 4: Remove log files ---
$logDir = Join-Path $zapretPath "utils\logs"
$logFile = Join-Path $logDir "auto-update.log"
Write-Info "Removing log files..."
$removed = 0
foreach ($f in @($logFile, "$logFile.bak")) {
    if (Test-Path $f) {
        Remove-Item $f -Force
        $removed++
    }
}
if ($removed -gt 0) {
    Write-Ok "Removed $removed log file(s)"
} else {
    Write-Info "No log files found"
}

# --- Step 5: Remove temp bat if leftover ---
$tempBat = Join-Path $zapretPath "utils\_sc_create.bat"
if (Test-Path $tempBat) {
    Remove-Item $tempBat -Force
    Write-Ok "Removed temp file: _sc_create.bat"
}

# --- Done ---
Write-Host ""
Write-Host "  ================================" -ForegroundColor Green
Write-Host "  Auto-updater removed!" -ForegroundColor Green
Write-Host "  ================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Removed:"
Write-Host "    - Scheduled task: $taskName"
Write-Host "    - Script: $updaterPath"
Write-Host "    - Logs: $logDir\auto-update.log*"
Write-Host ""
Write-Host "  Zapret service itself was NOT touched." -ForegroundColor Yellow
Write-Host "  It will continue running as before." -ForegroundColor Yellow
Write-Host ""
