<#
.SYNOPSIS
    Auto-updater for zapret-discord-youtube.
    Runs git pull and recreates the zapret service if updates were pulled.
#>

# --- Admin check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  Requesting administrator privileges..." -ForegroundColor Yellow
    $scriptPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { Join-Path $PSScriptRoot "zapret-auto-update.ps1" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`""
    exit
}

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
    $mergeargs = 0  # 0=default, 1=collecting comma-args, 2=just saw --param, 3=expecting value for named arg
    $argsWithValue = @("sni", "host", "altorder")
    $firstLine = $true

    foreach ($line in $lines) {
        $line = $line.Trim()

        if ($line -match "winws\.exe") {
            $capture = $true
            # Extract everything after winws.exe" (the closing quote)
            if ($line -match 'winws\.exe"?\s*(.*)') {
                $line = $Matches[1]
            } else {
                continue
            }
        }

        if (-not $capture) { continue }

        # Handle line continuation (^)
        $line = $line -replace '\^$', ''

        # Tokenize respecting quotes
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

            # Skip bare ^ artifacts
            if ($arg -eq "^" -or $arg -eq "^^") { continue }

            # New --param resets merge state
            if ($arg.StartsWith("--") -and $mergeargs -ne 0) {
                $mergeargs = 0
            }

            # Handle quoted values: strip outer quotes, resolve relative paths
            if ($arg.StartsWith('"') -and $arg.EndsWith('"') -and $arg.Length -gt 2) {
                $inner = $arg.Substring(1, $arg.Length - 2)
                if ($inner -match ':') {
                    # Absolute path — keep as-is with quotes
                    $arg = "`"$inner`""
                } elseif ($inner.StartsWith('@')) {
                    $arg = "`"@$RootPath$($inner.Substring(1))`""
                } else {
                    $arg = "`"$RootPath$inner`""
                }
            }

            # Merge logic
            if ($mergeargs -eq 1) {
                $args += ",$arg"
            } elseif ($mergeargs -eq 3) {
                $args += "=$arg"
                $mergeargs = 1
            } else {
                $args += " $arg"
            }

            # Update merge state
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

    # Check zapret service exists
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Service '$serviceName' not found. Skipping update." "WARN"
        exit 0
    }

    # Check git
    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
        Write-Log "git not found in PATH. Cannot update." "ERROR"
        exit 1
    }

    # Check it's a git repo
    $gitDir = Join-Path $zapretPath ".git"
    if (-not (Test-Path $gitDir)) {
        Write-Log "Zapret directory is not a git repo: $zapretPath" "ERROR"
        exit 1
    }

    # git pull (--quiet suppresses stderr progress noise that triggers ErrorActionPreference)
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

    # Show what changed
    $ErrorActionPreference = "Continue"
    $recentCommits = & git -C $zapretPath log --oneline -5 2>&1
    $ErrorActionPreference = $prevEAP
    Write-Log "Recent commits after update:`n$(($recentCommits | ForEach-Object { $_.ToString() }) -join "`n")"

    # --- Recreate service ---
    Write-Log "Updates detected. Recreating zapret service..."

    # Read current strategy name from registry
    $strategyName = $null
    try {
        $regKey = Get-ItemProperty -Path $regPath -Name $regValueName -ErrorAction Stop
        $strategyName = $regKey.$regValueName
    } catch {
        Write-Log "Could not read strategy name from registry. Using 'general'." "WARN"
        $strategyName = "general"
    }
    Write-Log "Current strategy: $strategyName"

    # Find matching .bat file
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

    # Enable TCP timestamps
    & netsh interface tcp set global timestamps=enabled 2>&1 | Out-Null

    # Stop service
    Write-Log "Stopping zapret service..."
    $svcState = (Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
    if ($svcState -eq "Running") {
        & net stop $serviceName 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    } else {
        Write-Log "Service was not running (state: $svcState). Skipping stop."
    }

    # Kill leftover winws.exe
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    # Delete service
    Write-Log "Deleting zapret service..."
    $prevEAP2 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & sc.exe delete $serviceName 2>&1 | Out-Null
    $ErrorActionPreference = $prevEAP2
    Start-Sleep -Seconds 2

    # Create service
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

    # Set description
    & sc.exe description $serviceName "Zapret DPI bypass software" 2>&1 | Out-Null

    # Save strategy name to registry
    & reg add "HKLM\System\CurrentControlSet\Services\$serviceName" /v $regValueName /t REG_SZ /d $strategyName /f 2>&1 | Out-Null

    # Start service
    Write-Log "Starting zapret service..."
    $startOutput = & sc.exe start $serviceName 2>&1
    Write-Log "sc start output: $startOutput"

    # Verify
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
