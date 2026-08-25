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
    # git pull
    Write-Log "Running git pull in $zapretPath"
    $pullOutput = & git -C $zapretPath pull --ff-only 2>&1
    $pullText = $pullOutput -join "`n"
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
    $recentCommits = & git -C $zapretPath log --oneline -5 2>&1
    Write-Log "Recent commits after update:`n$($recentCommits -join "`n")"
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
    # Enable TCP timestamps
    & netsh interface tcp set global timestamps=enabled 2>&1 | Out-Null
    # Stop service
    Write-Log "Stopping zapret service..."
    & net stop $serviceName 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    # Kill leftover winws.exe
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    # Delete service
    Write-Log "Deleting zapret service..."
    & sc delete $serviceName 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    # Create service
    $binPath = Join-Path $zapretPath "bin\winws.exe"
    $scArgs = "`"$binPath`" $parsedArgs"
    Write-Log "Creating service with binPath: $scArgs"
    $createOutput = & sc create $serviceName binPath= $scArgs DisplayName= "zapret" start= auto 2>&1
    Write-Log "sc create output: $createOutput"
    # Set description
    & sc description $serviceName "Zapret DPI bypass software" 2>&1 | Out-Null
    # Save strategy name to registry
    & reg add "HKLM\System\CurrentControlSet\Services\$serviceName" /v $regValueName /t REG_SZ /d $strategyName /f 2>&1 | Out-Null
    # Start service
    Write-Log "Starting zapret service..."
    $startOutput = & sc start $serviceName 2>&1
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