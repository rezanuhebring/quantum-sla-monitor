<#
.SYNOPSIS
    Uninstalls the Windows PowerShell SLA Monitoring Agent.
.DESCRIPTION
    This script safely removes all components created by the setup_agent_windows.ps1 script.
    It will:
    - Stop and unregister the scheduled task.
    - Prompt the user before deleting the agent's installation directory.
    - Prompt the user before removing the agent's directory from the system PATH.
#>
param()

# --- Pre-flight Checks and Configuration ---
Write-Host "Starting Windows SLA Monitor Agent Uninstaller..." -ForegroundColor Yellow

# Ensure the script is running as Administrator
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator to remove system components. Please right-click and 'Run as Administrator'."
    # Pause to allow the user to read the error before the window closes.
    Read-Host "Press Enter to exit"
    exit 1
}

# Define all paths and names to be removed (must match the setup script)
$TaskName = "InternetSLAMonitorAgent"
$AgentInstallDir = "C:\SLA_Monitor_Agent"
$SpeedtestInstallDir = Join-Path $AgentInstallDir "speedtest"

# --- 1. Stop and Remove the Scheduled Task ---
Write-Host "Checking for scheduled task '$TaskName'..."
try {
    $ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($ExistingTask) {
        Write-Host "- Found task. Stopping and unregistering..." -ForegroundColor Cyan
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "Scheduled task '$TaskName' has been removed." -ForegroundColor Green
    } else {
        Write-Host "Scheduled task not found, nothing to do."
    }
} catch {
    Write-Error "An error occurred while trying to remove the scheduled task: $($_.Exception.Message)"
}

# --- 2. Remove the Agent Installation Directory ---
Write-Host "`n" # Add a newline for readability
if (Test-Path $AgentInstallDir) {
    Write-Warning "The next step will PERMANENTLY DELETE all agent files from '$AgentInstallDir'."
    $ConfirmDelete = Read-Host "Are you sure you want to proceed? [y/N]"
    
    if ($ConfirmDelete -match '^y') {
        Write-Host "Deleting directory '$AgentInstallDir'..." -ForegroundColor Cyan
        try {
            Remove-Item -Path $AgentInstallDir -Recurse -Force -ErrorAction Stop
            Write-Host "Agent directory successfully removed." -ForegroundColor Green
        } catch {
            Write-Error "Failed to delete directory: $($_.Exception.Message)"
        }
    } else {
        Write-Host "Skipping deletion of agent directory."
    }
} else {
    Write-Host "Agent directory '$AgentInstallDir' not found."
}

# --- 3. Clean up the System PATH Environment Variable ---
Write-Host "`n"
$CurrentSystemPath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($CurrentSystemPath -like "*$SpeedtestInstallDir*") {
    Write-Warning "The agent's Speedtest directory is in the system PATH."
    $ConfirmPathClean = Read-Host "Do you want to remove it from the system PATH? (This is generally safe) [y/N]"
    
    if ($ConfirmPathClean -match '^y') {
        Write-Host "Removing '$SpeedtestInstallDir' from the system PATH..." -ForegroundColor Cyan
        try {
            $PathEntries = $CurrentSystemPath -split ';' | Where-Object { $_ -ne "" -and $_ -ne $SpeedtestInstallDir }
            $NewSystemPath = $PathEntries -join ';'
            [System.Environment]::SetEnvironmentVariable('Path', $NewSystemPath, 'Machine')
            Write-Host "System PATH has been updated. A restart may be required for the change to take full effect." -ForegroundColor Green
        } catch {
            Write-Error "Failed to update system PATH: $($_.Exception.Message)"
        }
    } else {
        Write-Host "Skipping system PATH modification."
    }
}

Write-Host "`nUninstallation complete." -ForegroundColor Green