<#
.SYNOPSIS
    Automated setup for the Windows PowerShell SLA Monitoring Agent. FINAL PRODUCTION VERSION.
.DESCRIPTION
    This script includes a robust and reliable method for adding the Speedtest path
    to the agent's configuration file, fixing the "path not found" error.
#>
param()

# --- Self-Elevation to Administrator ---
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-ExecutionPolicy Bypass -File `"$($myInvocation.mycommand.definition)`""
    Start-Process powershell -Verb runAs -ArgumentList $arguments
    exit
}

# --- Pre-flight Checks and Configuration ---
Write-Host "Starting Windows SLA Monitor Agent Setup (Running as Administrator)..." -ForegroundColor Yellow

$AgentSourcePath = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentInstallDir = "C:\SLA_Monitor_Agent"
$SpeedtestInstallDir = Join-Path $AgentInstallDir "speedtest"
$SpeedtestExePath = Join-Path $SpeedtestInstallDir "speedtest.exe"
$MonitorScriptName = "Monitor-InternetAgent.ps1"
$ConfigTemplateName = "agent_config.ps1" # Using .ps1 for simplicity
$DestinationConfigPath = Join-Path $AgentInstallDir $ConfigTemplateName

# --- 1. Install Dependencies (Ookla Speedtest) ---
if (-not (Test-Path $SpeedtestExePath)) {
    Write-Host "Ookla Speedtest not found. Starting automatic installation..." -ForegroundColor Cyan
    $SpeedtestZipUrl = "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip"
    $TempZipPath = Join-Path $env:TEMP "speedtest.zip"
    try {
        Write-Host "- Downloading from $SpeedtestZipUrl..."; Invoke-WebRequest -Uri $SpeedtestZipUrl -OutFile $TempZipPath -UseBasicParsing -ErrorAction Stop
        Write-Host "- Unzipping to $SpeedtestInstallDir..."; New-Item -Path $SpeedtestInstallDir -ItemType Directory -Force | Out-Null; Expand-Archive -Path $TempZipPath -DestinationPath $SpeedtestInstallDir -Force -ErrorAction Stop
        Write-Host "- Cleaning up temporary files..."; Remove-Item $TempZipPath -Force
        Write-Host "Speedtest installation successful." -ForegroundColor Green
    } catch { Write-Error "Failed to download or install Speedtest: $($_.Exception.Message)"; Read-Host "Press Enter to exit"; exit 1 }
} else { Write-Host "Ookla Speedtest is already installed." }

# --- 2. Deploy Agent Scripts ---
if (-not (Test-Path $AgentInstallDir)) { New-Item -Path $AgentInstallDir -ItemType Directory -Force | Out-Null }
Write-Host "Copying agent scripts..."
try {
    Copy-Item -Path (Join-Path $AgentSourcePath $MonitorScriptName) -Destination (Join-Path $AgentInstallDir $MonitorScriptName) -Force -ErrorAction Stop
    Write-Host "- Copied $MonitorScriptName"
    if (-not (Test-Path $DestinationConfigPath)) {
        Copy-Item -Path (Join-Path $AgentSourcePath $ConfigTemplateName) -Destination $DestinationConfigPath -Force -ErrorAction Stop
        Write-Host "- Copied $ConfigTemplateName as initial configuration." -ForegroundColor Magenta
    } else { Write-Host "- Config file $DestinationConfigPath already exists. Skipping copy." -ForegroundColor Yellow }
} catch { Write-Error "Failed to copy agent files: $($_.Exception.Message)"; Read-Host "Press Enter to exit"; exit 1 }

# --- 3. Add Speedtest Path to Agent Config ---
Write-Host "Verifying Speedtest path in agent configuration..."
try {
    # *** FIX: Use robust Select-String to check if the line already exists ***
    $LineExists = Select-String -Path $DestinationConfigPath -Pattern '^\$SPEEDTEST_EXE_PATH' -Quiet
    if (-not $LineExists) {
        $ConfigLine = "`n`$SPEEDTEST_EXE_PATH = `"$SpeedtestExePath`""
        Add-Content -Path $DestinationConfigPath -Value $ConfigLine
        Write-Host "Speedtest path configured successfully in '$DestinationConfigPath'." -ForegroundColor Green
    } else {
        Write-Host "Speedtest path is already correctly configured in the file."
    }
} catch {
    Write-Error "Failed to update config file with Speedtest path. Error: $($_.Exception.Message)"
}

# --- 4. Accept License Terms Silently ---
Write-Host "Attempting to accept Speedtest license terms..."
try { & $SpeedtestExePath --accept-license --accept-gdpr | Out-Null }
catch { Write-Warning "Could not run speedtest.exe to accept license. This may be a temporary network issue. Error: $($_.Exception.Message)" }

# --- 5. Create/Update Scheduled Task ---
$TaskName = "InternetSLAMonitorAgent"
$TaskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$AgentInstallDir\$MonitorScriptName`""
$TaskTrigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 15) -Once -At (Get-Date)
$TaskPrincipal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$TaskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
Write-Host "Registering scheduled task '$TaskName'..."
try {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    Register-ScheduledTask -TaskName $TaskName -Action $TaskAction -Trigger $TaskTrigger -Principal $TaskPrincipal -Settings $TaskSettings -ErrorAction Stop
    Write-Host "Scheduled task '$TaskName' created/updated successfully."
} catch { Write-Error "Failed to register task '$TaskName': $($_.Exception.Message)"; Write-Warning "You may need to create the task manually." }

# --- Final Instructions ---
Write-Host "`nWindows SLA Monitor Agent Setup Complete." -ForegroundColor Green
Write-Host "--------------------------------------------------------------------"
Write-Host "NEXT STEPS:"
Write-Host "1. CRITICAL: Review/edit the configuration file with this agent's unique details:"
Write-Host "   notepad `"$DestinationConfigPath`""
Write-Host "2. Test the script by running it directly from an Administrator PowerShell:"
Write-Host "   & `"$AgentInstallDir\$MonitorScriptName`""
Write-Host "3. Check the agent's log file for output:"
Write-Host "   Get-Content `"$AgentInstallDir\internet_monitor_agent_windows.log`" -Tail 10 -Wait"
Write-Host "--------------------------------------------------------------------"
Read-Host "Press Enter to exit"