<#
.SYNOPSIS
    Uninstaller for the Windows PowerShell SLA Monitoring Agent.
.DESCRIPTION
    This script self-elevates to Administrator and completely removes the agent,
    including the scheduled task, installation directory, and all related files.
#>
param()

# --- Self-Elevation to Administrator ---
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-ExecutionPolicy Bypass -File `"$($myInvocation.mycommand.definition)`""
    Start-Process powershell -Verb runAs -ArgumentList $arguments
    exit
}

Write-Host "Starting Windows SLA Monitor Agent Uninstallation..." -ForegroundColor Yellow

# --- Configuration ---
$AgentInstallDir = "C:\SLA_Monitor_Agent"
$TaskName = "InternetSLAMonitorAgent"

# --- 1. Stop and Remove Scheduled Task ---
Write-Host "Removing Scheduled Task '$TaskName'..."
try {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Task) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "- Scheduled Task successfully removed." -ForegroundColor Green
    } else {
        Write-Host "- Scheduled Task not found, skipping."
    }
} catch {
    Write-Warning "Could not remove the scheduled task. You may need to remove it manually. Error: $($_.Exception.Message)"
}

# --- 2. Remove Installation Directory ---
Write-Host "Removing installation directory '$AgentInstallDir'..."
if (Test-Path $AgentInstallDir) {
    try {
        Remove-Item -Path $AgentInstallDir -Recurse -Force -ErrorAction Stop
        Write-Host "- Directory successfully removed." -ForegroundColor Green
    } catch {
        Write-Error "Failed to remove directory '$AgentInstallDir'. Error: $($_.Exception.Message)"
        Write-Warning "You may need to delete the folder manually."
    }
} else {
    Write-Host "- Directory not found, skipping."
}

# --- 3. Remove Lock File (just in case) ---
$LockFile = Join-Path -Path $env:TEMP -ChildPath "sla_monitor_agent.lock"
if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }


Write-Host "`nUninstallation Complete." -ForegroundColor Green
Read-Host "Press Enter to exit"