<#
.SYNOPSIS
    Automated setup for the Windows PowerShell SLA Monitoring Agent. ENHANCED PRODUCTION VERSION.
.DESCRIPTION
    This self-elevating script installs the agent, dependencies, and scheduled task.
    It now prompts for an API key and securely encrypts it for the SYSTEM user by
    dynamically creating and running a temporary one-time scheduled task.
#>
param(
    [switch]$Unattended
)

# --- Self-Elevation to Administrator ---
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = if ($Unattended) { "-Unattended" } else { "" }
    $fullArguments = "-ExecutionPolicy Bypass -File `"$($myInvocation.mycommand.definition)`" $arguments"
    Start-Process powershell -Verb runAs -ArgumentList $fullArguments
    exit
}

# --- Pre-flight Checks and Configuration ---
Write-Host "Starting Windows SLA Monitor Agent Setup (Running as Administrator)..." -ForegroundColor Yellow

$AgentSourcePath = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentInstallDir = "C:\SLA_Monitor_Agent"
$SpeedtestInstallDir = Join-Path $AgentInstallDir "speedtest"
$SpeedtestExePath = Join-Path $SpeedtestInstallDir "speedtest.exe"
$MonitorScriptName = "Monitor-InternetAgent.ps1"
$UninstallerName = "uninstall_agent_windows.ps1"
$ConfigTemplateName = "agent_config.ps1"
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
    } catch { Write-Error "Failed to download or install Speedtest: $($_.Exception.Message)"; if (-not $Unattended) { Read-Host "Press Enter to exit" }; exit 1 }
} else { Write-Host "Ookla Speedtest is already installed." }

# --- 2. Deploy Agent Scripts ---
if (-not (Test-Path $AgentInstallDir)) { New-Item -Path $AgentInstallDir -ItemType Directory -Force | Out-Null }
Write-Host "Copying agent scripts..."
try {
    # Verify all source files exist before copying
    if (-not (Test-Path (Join-Path $AgentSourcePath $MonitorScriptName))) { throw "Source file not found: $MonitorScriptName" }
    if (-not (Test-Path (Join-Path $AgentSourcePath $UninstallerName))) { throw "Source file not found: $UninstallerName" }
    if (-not (Test-Path (Join-Path $AgentSourcePath $ConfigTemplateName))) { throw "Source file not found: $ConfigTemplateName" }

    Copy-Item -Path (Join-Path $AgentSourcePath $MonitorScriptName) -Destination (Join-Path $AgentInstallDir $MonitorScriptName) -Force -ErrorAction Stop
    Write-Host "- Copied $MonitorScriptName"
    
    Copy-Item -Path (Join-Path $AgentSourcePath $UninstallerName) -Destination (Join-Path $AgentInstallDir $UninstallerName) -Force -ErrorAction Stop
    Write-Host "- Copied $UninstallerName"
    
    if (-not (Test-Path $DestinationConfigPath)) {
        Copy-Item -Path (Join-Path $AgentSourcePath $ConfigTemplateName) -Destination $DestinationConfigPath -Force -ErrorAction Stop
        Write-Host "- Copied $ConfigTemplateName as initial configuration." -ForegroundColor Magenta
    } else { Write-Host "- Config file $DestinationConfigPath already exists. Skipping copy." -ForegroundColor Yellow }
} catch { Write-Error "Failed to copy agent files: $($_.Exception.Message)"; if (-not $Unattended) { Read-Host "Press Enter to exit" }; exit 1 }

# --- 3. Add Speedtest Path to Agent Config ---
Write-Host "Verifying Speedtest path in agent configuration..."
try {
    if (-not (Select-String -Path $DestinationConfigPath -Pattern '^\$SPEEDTEST_EXE_PATH' -Quiet)) {
        Add-Content -Path $DestinationConfigPath -Value "`n# This line is added automatically by the setup script.`n`$SPEEDTEST_EXE_PATH = `"$SpeedtestExePath`""
        Write-Host "Speedtest path configured successfully in '$DestinationConfigPath'." -ForegroundColor Green
    } else { Write-Host "Speedtest path is already configured." }
} catch { Write-Error "Failed to update config file with Speedtest path. Error: $($_.Exception.Message)" }

# --- 4. Securely Create API Key File ---
Write-Host "Configuring API Key..."
$ApiKey = ""
if (-not $Unattended) {
    $ApiKey = Read-Host -Prompt "Enter the Central API Key (optional, press Enter to skip)"
}

if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Host "Encrypting API key for use by the SYSTEM account..." -ForegroundColor Cyan
    $SecureKeyPath = Join-Path $AgentInstallDir "api.key"
    $TempTaskName = "CreateSecureAgentKey-$(Get-Random)"
    
    # This command will be executed by the SYSTEM account to ensure correct encryption context
    $CommandToRun = "'$ApiKey' | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString | Out-File -FilePath '$SecureKeyPath' -Force -Encoding UTF8"
    
    $TaskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -Command `"$CommandToRun`""
    $TaskPrincipal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount
    
    try {
        # Register, run, and clean up the temporary task
        Register-ScheduledTask -TaskName $TempTaskName -Action $TaskAction -Principal $TaskPrincipal -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries) | Out-Null
        Start-ScheduledTask -TaskName $TempTaskName
        # Wait for the task to finish (state becomes 'Ready' again after a run)
        $Timeout = 30; $Waited = 0
        do { Start-Sleep -Seconds 1; $Waited++ } while ((Get-ScheduledTask -TaskName $TempTaskName).State -ne 'Ready' -and $Waited -lt $Timeout)
        
        Unregister-ScheduledTask -TaskName $TempTaskName -Confirm:$false
        
        if (Test-Path $SecureKeyPath) {
            Write-Host "API key securely stored at '$SecureKeyPath'." -ForegroundColor Green
        } else {
            Write-Error "Failed to create the secure API key file. The temporary task may have timed out."
        }
    } catch {
        Write-Error "An error occurred during secure key creation: $($_.Exception.Message)"
        if (Get-ScheduledTask -TaskName $TempTaskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TempTaskName -Confirm:$false }
    }
} else {
    Write-Host "API Key not provided, skipping creation of secure key file."
}

# --- 5. Accept License Terms Silently ---
Write-Host "Attempting to accept Speedtest license terms..."
try { & $SpeedtestExePath --accept-license --accept-gdpr | Out-Null }
catch { Write-Warning "Could not run speedtest.exe to accept license. Error: $($_.Exception.Message)" }

# --- 6. Create/Update Main Scheduled Task ---
$TaskName = "InternetSLAMonitorAgent"
$TaskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$AgentInstallDir\$MonitorScriptName`""
$TaskTrigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 15) -Once -At (Get-Date)
$TaskPrincipal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$TaskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
Write-Host "Registering main scheduled task '$TaskName'..."
try {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    Register-ScheduledTask -TaskName $TaskName -Action $TaskAction -Trigger $TaskTrigger -Principal $TaskPrincipal -Settings $TaskSettings -ErrorAction Stop
    Write-Host "Scheduled task '$TaskName' created/updated successfully."
} catch { Write-Error "Failed to register task '$TaskName': $($_.Exception.Message)"; Write-Warning "You may need to create the task manually." }

# --- Final Instructions ---
Write-Host "`nWindows SLA Monitor Agent Setup Complete." -ForegroundColor Green
Write-Host "--------------------------------------------------------------------"
Write-Host "NEXT STEPS:"
Write-Host "1. CRITICAL: Edit the configuration file with this agent's unique ID and API URL:"
Write-Host "   notepad `"$DestinationConfigPath`""
Write-Host "2. The API key has been securely stored (if provided). No further action is needed for the key."
Write-Host "3. To uninstall the agent later, run the uninstaller from an Administrator PowerShell:"
Write-Host "   & `"$AgentInstallDir\$UninstallerName`""
Write-Host "--------------------------------------------------------------------"
if (-not $Unattended) {
    Read-Host "Press Enter to exit"
}