#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installer for zapret auto-updater.
    Usage: irm https://<your-url>/install-updater.ps1 | iex
#>

$ErrorActionPreference = "Stop"

function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Err  { param([string]$Msg) Write-Host "  [ERR] $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "  [..] $Msg" -ForegroundColor Cyan }

Write-Host ""
Write-Host "  Zapret Auto-Updater Installer" -ForegroundColor Cyan
Write-Host "  =============================" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: Detect zapret path from service registry ---
Write-Info "Detecting zapret installation..."
$regPath = "HKLM:\System\CurrentControlSet\Services\zapret"
$zapretPath = $null

try {
    $imagePath = (Get-ItemProperty -Path $regPath -Name "ImagePath" -ErrorAction Stop).ImagePath
    # ImagePath looks like: "D:\programs\zapret-discord-youtube\bin\winws.exe" --args...
    if ($imagePath -match '^"([^"]+)"') {
        $binExe = $Matches[1]
        $zapretPath = Split-Path (Split-Path $binExe -Parent) -Parent
    }
} catch {
    # Service not found via registry
}

if (-not $zapretPath -or -not (Test-Path $zapretPath)) {
    Write-Err "Zapret service not found or path is invalid."
    Write-Err "Make sure zapret is installed via service.bat first."
    exit 1
}

Write-Ok "Found zapret at: $zapretPath"

# --- Step 2: Validate ---
Write-Info "Validating installation..."
$serviceBat = Join-Path $zapretPath "service.bat"
$winwsExe = Join-Path $zapretPath "bin\winws.exe"

if (-not (Test-Path $serviceBat)) {
    Write-Err "service.bat not found in $zapretPath"
    exit 1
}
if (-not (Test-Path $winwsExe)) {
    Write-Err "bin\winws.exe not found in $zapretPath"
    exit 1
}
Write-Ok "Installation validated"

# --- Step 3: Check git ---
Write-Info "Checking git..."
if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
    Write-Err "git is not installed or not in PATH."
    Write-Err "Install git first: winget install Git.Git"
    exit 1
}
$gitVersion = & git --version 2>&1
Write-Ok "Git found: $gitVersion"

# --- Step 4: Ensure git repo ---
Write-Info "Checking git repository..."
$gitDir = Join-Path $zapretPath ".git"
if (-not (Test-Path $gitDir)) {
    Write-Info "Not a git repo. Initializing..."
    & git -C $zapretPath init 2>&1 | Out-Null
    & git -C $zapretPath remote add origin "https://github.com/Flowseal/zapret-discord-youtube.git" 2>&1 | Out-Null
    & git -C $zapretPath fetch origin 2>&1 | Out-Null
    & git -C $zapretPath reset --hard origin/main 2>&1 | Out-Null
    Write-Ok "Git repo initialized and synced with upstream"
} else {
    $remote = & git -C $zapretPath remote get-url origin 2>&1
    Write-Ok "Git repo exists (remote: $remote)"
}

# --- Step 5: Write updater script ---
Write-Info "Installing updater script..."
$utilsDir = Join-Path $zapretPath "utils"
if (-not (Test-Path $utilsDir)) {
    New-Item -ItemType Directory -Path $utilsDir -Force | Out-Null
}
$updaterPath = Join-Path $utilsDir "zapret-auto-update.ps1"

# Updater script content
$updaterContent = @'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Auto-updater for zapret-discord-youtube.
    Runs git pull and recreates the zapret service if updates were pulled.
#>

$ErrorActionPreference = "Stop"

# --- Config ---
$zapretPath = $PSScriptRoot | Split-Path -Parent
$logDir = Join-Path $PSScriptRoot "logs"
$logFile = Join-Path $logDir "auto-update.log"
$maxLogSize = 1MB
$serviceName = "zapret"
$regPath = "HKLM:\System\CurrentControlSet\Services\$serviceName"
$regValueName = "zapret-discord-youtube"

# --- Logging ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt $maxLogSize)) {
        $backup = "$logFile.bak"
        if (Test-Path $backup) { Remove-Item $backup -Force }
        Move-Item $logFile $backup -Force
    }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    if ($Level -eq "ERROR") { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq "WARN") { Write-Host $line -ForegroundColor Yellow }
    else { Write-Host $line }
}

# --- Parse bat file arguments (ported from service.bat) ---
function Get-BatArguments {
    param([string]$BatFilePath, [string]$RootPath)

    $lines = Get-Content -Path $BatFilePath -Encoding UTF8
    $capture = $false
    $args = ""
    $mergeargs = 0
    $argsWithValue = @("sni", "host", "altorder")

    foreach ($line in $lines) {
        $line = $line.Trim()

        if ($line -match "winws\.exe") {
            $capture = $true
            if ($line -match 'winws\.exe"?\s*(.*)') {
                $line = $Matches[1]
            } else {
                continue
            }
        }

        if (-not $capture) { continue }

        $line = $line -replace '\^$', ''

        $tokens = @()
        $current = ""
        $inQuote = $false
        for ($i = 0; $i -lt $line.Length; $i++) {
            $ch = $line[$i]
            if ($ch -eq '"') {
                $inQuote = -not $inQuote
                $current += $ch
            } elseif ($ch -eq ' ' -and -not $inQuote) {
                if ($current -ne "") {
                    $tokens += $current
                    $current = ""
                }
            } else {
                $current += $ch
            }
        }
        if ($current -ne "") { $tokens += $current }

        foreach ($token in $tokens) {
            $arg = $token
            if ($arg -eq "^" -or $arg -eq "^^") { continue }

            if ($arg.StartsWith("--") -and $mergeargs -ne 0) {
                $mergeargs = 0
            }

            if ($arg.StartsWith('"') -and $arg.EndsWith('"') -and $arg.Length -gt 2) {
                $inner = $arg.Substring(1, $arg.Length - 2)
                if ($inner -match ':') {
                    $arg = "`"$inner`""
                } elseif ($inner.StartsWith('@')) {
                    $arg = "`"@$RootPath$($inner.Substring(1))`""
                } else {
                    $arg = "`"$RootPath$inner`""
                }
            }

            if ($mergeargs -eq 1) {
                $args += ",$arg"
            } elseif ($mergeargs -eq 3) {
                $args += "=$arg"
                $mergeargs = 1
            } else {
                $args += " $arg"
            }

            if ($arg.StartsWith("--")) {
                $mergeargs = 2
            } elseif ($mergeargs -ge 1) {
                if ($mergeargs -eq 2) { $mergeargs = 1 }
                if ($arg -in $argsWithValue) {
                    $mergeargs = 3
                }
            }
        }
    }

    return $args.Trim()
}

# --- Main ---
try {
    Write-Log "=== Auto-update started ==="

    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Service '$serviceName' not found. Skipping update." "WARN"
        exit 0
    }

    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
        Write-Log "git not found in PATH. Cannot update." "ERROR"
        exit 1
    }

    $gitDir = Join-Path $zapretPath ".git"
    if (-not (Test-Path $gitDir)) {
        Write-Log "Zapret directory is not a git repo: $zapretPath" "ERROR"
        exit 1
    }

    Write-Log "Running git pull in $zapretPath"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $pullOutput = & git -C $zapretPath pull --ff-only --quiet 2>&1
    $ErrorActionPreference = $prevEAP
    $pullText = ($pullOutput | ForEach-Object { $_.ToString() }) -join "`n"
    Write-Log "git pull output: $pullText"

    if ($pullText -match "Already up to date") {
        Write-Log "No updates available. Done."
        exit 0
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Log "git pull failed (exit code $LASTEXITCODE)" "ERROR"
        exit 1
    }

    $ErrorActionPreference = "Continue"
    $recentCommits = & git -C $zapretPath log --oneline -5 2>&1
    $ErrorActionPreference = $prevEAP
    Write-Log "Recent commits after update:`n$(($recentCommits | ForEach-Object { $_.ToString() }) -join "`n")"

    Write-Log "Updates detected. Recreating zapret service..."

    $strategyName = $null
    try {
        $regKey = Get-ItemProperty -Path $regPath -Name $regValueName -ErrorAction Stop
        $strategyName = $regKey.$regValueName
    } catch {
        Write-Log "Could not read strategy name from registry. Using 'general'." "WARN"
        $strategyName = "general"
    }
    Write-Log "Current strategy: $strategyName"

    $batFile = Get-ChildItem -Path $zapretPath -Filter "*.bat" |
        Where-Object { $_.Name -notlike "service*" -and $_.BaseName -eq $strategyName } |
        Select-Object -First 1

    if (-not $batFile) {
        Write-Log "Strategy bat file not found for '$strategyName'. Trying 'general.bat'." "WARN"
        $batFile = Get-ChildItem -Path $zapretPath -Filter "general.bat" | Select-Object -First 1
    }

    if (-not $batFile) {
        Write-Log "No suitable bat file found. Cannot recreate service." "ERROR"
        exit 1
    }

    Write-Log "Parsing bat file: $($batFile.Name)"
    $parsedArgs = Get-BatArguments -BatFilePath $batFile.FullName -RootPath "$zapretPath\"
    Write-Log "Parsed args: $parsedArgs"
    # Resolve %VAR% references to actual paths (service.bat sets these as env vars)
    $listsPath = Join-Path $zapretPath "lists\"
    $binDir = Join-Path $zapretPath "bin\"
    $gameFilterTCP = "12"
    $gameFilterUDP = "12"
    $gfFile = Join-Path $zapretPath "utils\game_filter.enabled"
    if (Test-Path $gfFile) {
        $gfMode = (Get-Content $gfFile -First 1).Trim()
        if ($gfMode -eq "all") { $gameFilterTCP = "1024-65535"; $gameFilterUDP = "1024-65535" }
        elseif ($gfMode -eq "tcp") { $gameFilterTCP = "1024-65535" }
        elseif ($gfMode -eq "udp") { $gameFilterUDP = "1024-65535" }
    }
    $parsedArgs = $parsedArgs -replace '%LISTS%', $listsPath
    $parsedArgs = $parsedArgs -replace '%BIN%', $binDir
    $parsedArgs = $parsedArgs -replace '%GameFilterTCP%', $gameFilterTCP
    $parsedArgs = $parsedArgs -replace '%GameFilterUDP%', $gameFilterUDP
    Write-Log "Resolved args: $parsedArgs"

    & netsh interface tcp set global timestamps=enabled 2>&1 | Out-Null

    Write-Log "Stopping zapret service..."
    $svcState = (Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
    if ($svcState -eq "Running") {
        & net stop $serviceName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    } else {
        Write-Log "Service was not running (state: $svcState). Skipping stop."
    }

    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    Write-Log "Deleting zapret service..."
    $prevEAP2 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & sc.exe delete $serviceName 2>&1 | Out-Null
    $ErrorActionPreference = $prevEAP2
    Start-Sleep -Seconds 2

    $binPath = Join-Path $zapretPath "bin\winws.exe"
    Write-Log "Creating service..."
    # sc.exe requires binPath= <value> syntax that PowerShell cannot pass correctly.
    # Write a temp .bat file and execute it via cmd.exe (matching service.bat format).
    # Escape % as %% so cmd.exe doesn't expand %LISTS%, %BIN% etc.
    $escapedArgs = $parsedArgs -replace '%', '%%'
    # Build bat line matching service.bat: sc create NAME binPath= "\"PATH\" ARGS" DisplayName= "zapret" start= auto
    $batLine = 'sc create ' + $serviceName + ' binPath= "\"' + $binPath + '\" ' + $escapedArgs + '" DisplayName= "zapret" start= auto'
    $batContent = "@echo off`r`n$batLine`r`n"
    $batPath = "$zapretPath\utils\_sc_create.bat"
    [System.IO.File]::WriteAllText($batPath, $batContent, [System.Text.Encoding]::ASCII)
    $createOutput = & cmd /c $batPath 2>&1
    Remove-Item $batPath -Force -ErrorAction SilentlyContinue
    Write-Log "sc create output: $createOutput"

    & sc.exe description $serviceName "Zapret DPI bypass software" 2>&1 | Out-Null

    & reg add "HKLM\System\CurrentControlSet\Services\$serviceName" /v $regValueName /t REG_SZ /d $strategyName /f 2>&1 | Out-Null

    Write-Log "Starting zapret service..."
    $startOutput = & sc.exe start $serviceName 2>&1
    Write-Log "sc start output: $startOutput"

    Start-Sleep -Seconds 3
    $newSvc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($newSvc -and $newSvc.Status -eq "Running") {
        Write-Log "Service recreated and running successfully."
    } else {
        Write-Log "Service created but may not be running. Status: $($newSvc.Status)" "WARN"
    }

    Write-Log "=== Auto-update finished ==="
    exit 0

} catch {
    Write-Log "Unexpected error: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
}
'@

Set-Content -Path $updaterPath -Value $updaterContent -Encoding UTF8
Write-Ok "Updater script written to: $updaterPath"

# --- Step 6: Create Scheduled Task ---
Write-Info "Creating scheduled task..."

$taskName = "ZapretAutoUpdate"
$taskDescription = "Auto-update zapret-discord-youtube via git pull on system startup"

# Remove existing task if present
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Ok "Removed existing task"
}

# Trigger: at startup with 60s delay
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = "PT60S"

# Action: run updater script hidden
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$updaterPath`""

# Settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -RestartCount 1 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# Principal: SYSTEM
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Register
Register-ScheduledTask -TaskName $taskName `
    -Description $taskDescription `
    -Trigger $trigger `
    -Action $action `
    -Settings $settings `
    -Principal $principal `
    -Force | Out-Null

Write-Ok "Scheduled task '$taskName' created"

# --- Done ---
Write-Host ""
Write-Host "  =============================" -ForegroundColor Green
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host "  =============================" -ForegroundColor Green
Write-Host ""
Write-Host "  Zapret path:    $zapretPath"
Write-Host "  Updater script: $updaterPath"
Write-Host "  Task name:      $taskName"
Write-Host "  Trigger:        System startup (60s delay)"
Write-Host "  Log file:       $zapretPath\utils\logs\auto-update.log"
Write-Host ""
Write-Host "  To test manually:" -ForegroundColor Yellow
Write-Host "    powershell -ExecutionPolicy Bypass -File `"$updaterPath`""
Write-Host ""
Write-Host "  To uninstall:" -ForegroundColor Yellow
Write-Host "    irm https://geardung.github.io/zapret-updater/uninstall-updater.ps1 | iex"
Write-Host ""
