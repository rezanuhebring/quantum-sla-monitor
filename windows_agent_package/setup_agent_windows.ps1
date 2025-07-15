#Requires -Version 5.1
<#
.SYNOPSIS
    Automated setup for the Net-Insight Monitor Agent (Windows). V3.1 FINAL PRODUCTION VERSION.
.DESCRIPTION
    This script installs the agent, dependencies, and creates a recurring scheduled task.
    *** FIX: Includes the -WorkingDirectory parameter to ensure the scheduled task runs reliably. ***
#>
param()

# --- Self-Elevation to Administrator ---
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script requires Administrator privileges. Attempting to re-launch as Admin..."
    $arguments = "-ExecutionPolicy Bypass -File `"$($myInvocation.mycommand.definition)`""
    Start-Process powershell -Verb runAs -ArgumentList $arguments
    exit
}

# --- Pre-flight Checks and Configuration ---
Write-Host "Starting Net-Insight Monitor Agent Setup (Running as Administrator)..." -ForegroundColor Yellow

$AgentSourcePath = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentInstallDir = "C:\NetInsightAgent"
$SpeedtestInstallDir = Join-Path $AgentInstallDir "speedtest"
$SpeedtestExePath = Join-Path $SpeedtestInstallDir "speedtest.exe"
$MonitorScriptName = "Monitor-InternetAgent.ps1"
$ConfigTemplateName = "agent_config.ps1.template"
$DestinationConfigPath = Join-Path $AgentInstallDir "agent_config.ps1"

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
Write-Host "Copying agent scripts to '$AgentInstallDir'..."
try {
    Copy-Item -Path (Join-Path $AgentSourcePath $MonitorScriptName) -Destination (Join-Path $AgentInstallDir $MonitorScriptName) -Force -ErrorAction Stop
    Write-Host "- Copied $MonitorScriptName"
    if (-not (Test-Path $DestinationConfigPath)) {
        Copy-Item -Path (Join-Path $AgentSourcePath $ConfigTemplateName) -Destination $DestinationConfigPath -Force -ErrorAction Stop
        Write-Host "- Copied configuration template." -ForegroundColor Magenta
    } else { Write-Host "- Config file $DestinationConfigPath already exists. Skipping copy to preserve settings." -ForegroundColor Yellow }
} catch { Write-Error "Failed to copy agent files: $($_.Exception.Message)"; Read-Host "Press Enter to exit"; exit 1 }

# --- 3. Add Speedtest Path to Agent Config ---
Write-Host "Verifying Speedtest path in agent configuration..."
try {
    $LineExists = Select-String -Path $DestinationConfigPath -Pattern '^\$script:SPEEDTEST_EXE_PATH' -Quiet
    if (-not $LineExists) {
        $ConfigLine = "`n`$script:SPEEDTEST_EXE_PATH = `"$SpeedtestExePath`""
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
$TaskName = "NetInsightMonitorAgent"
# *** FIX: Added the -WorkingDirectory parameter to ensure the script runs in the correct folder. ***
$TaskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$AgentInstallDir\$MonitorScriptName`"" -WorkingDirectory $AgentInstallDir
$TaskTrigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 15) -Once -At (Get-Date)
$TaskPrincipal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$TaskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
Write-Host "Registering scheduled task '$TaskName'..."
try {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    Register-ScheduledTask -TaskName $TaskName -Action $TaskAction -Trigger $TaskTrigger -Principal $TaskPrincipal -Settings $TaskSettings -ErrorAction Stop
    Write-Host "Scheduled task '$TaskName' created/updated successfully with the correct working directory." -ForegroundColor Green
} catch { Write-Error "Failed to register task '$TaskName': $($_.Exception.Message)"; Write-Warning "You may need to create the task manually." }

# --- Final Instructions ---
$LogFilePath = Join-Path $AgentInstallDir "net_insight_agent_windows.log"
Write-Host "`nNet-Insight Monitor Agent Setup Complete." -ForegroundColor Green
Write-Host "--------------------------------------------------------------------"
Write-Host "CRITICAL NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. You MUST edit the configuration file with this agent's unique details:"
Write-Host "   notepad `"$DestinationConfigPath`""
Write-Host "2. Inside the file, you must set these three values:"
Write-Host "   - `$script:AGENT_IDENTIFIER = `"Your-Unique-Agent-Name`""
Write-Host "   - `$script:CENTRAL_API_URL = `"https://your.server.com/api/submit_metrics.php`""
Write-Host "   - `$script:CENTRAL_API_KEY = `"Paste-The-Key-From-Server-Setup-Here`""
Write-Host ""
Write-Host "3. To test, run the script directly from an Administrator PowerShell:"
Write-Host "   & `"$AgentInstallDir\$MonitorScriptName`""
Write-Host ""
Write-Host "4. Check the agent's log file for output:"
Write-Host "   Get-Content `"$LogFilePath`" -Tail 10 -Wait"
Write-Host "--------------------------------------------------------------------"
Read-Host "Press Enter to exit"