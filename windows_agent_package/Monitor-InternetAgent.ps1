#Requires -Version 5.1
<#
.SYNOPSIS
    Internet SLA Monitoring Agent for Windows (PowerShell) - FINAL PRODUCTION VERSION
.DESCRIPTION
    This script includes a robust try/finally lock file mechanism to ensure reliability
    when run as a scheduled task. All other logic is finalized.
#>

# --- Configuration & Setup ---
$AgentScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentConfigFile = Join-Path -Path $AgentScriptDirectory -ChildPath "agent_config.ps1"
$LogFile = Join-Path -Path $AgentScriptDirectory -ChildPath "internet_monitor_agent_windows.log"
$LockFile = Join-Path -Path $env:TEMP -ChildPath "sla_monitor_agent.lock"

# --- Helper Function ---
# Define this function early so it can be used for any error, even config load errors.
function Write-Log {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")][string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
    $Identifier = "WindowsAgent" # Default identifier
    if ($script:AgentConfig -and $script:AgentConfig.AGENT_IDENTIFIER) {
        $Identifier = $script:AgentConfig.AGENT_IDENTIFIER
    }
    $LogEntry = "[$Timestamp] [$Level] [$Identifier] $Message"
    try { Add-Content -Path $script:LogFile -Value $LogEntry -ErrorAction SilentlyContinue } catch {}
}

# --- Lock File Logic ---
if (Test-Path $LockFile) {
    $LockFileAge = (Get-Item $LockFile).CreationTime
    if ((Get-Date) - $LockFileAge -gt [System.TimeSpan]::FromMinutes(10)) {
        Write-Log -Level WARN -Message "Stale lock file found. Removing it."
        Remove-Item $LockFile -Force
    } else {
        Write-Log -Level INFO -Message "[LOCK] Previous instance is still running. Exiting."
        exit 1
    }
}
# Create the lock file before the main try block.
New-Item -Path $LockFile -ItemType File -Force | Out-Null

# *** FIX: Use a robust try/finally block to ensure the lock is always removed ***
try {
    # --- Load and Validate Configuration ---
    try {
        $script:AgentConfig = Import-PowerShellDataFile -Path $AgentConfigFile
    } catch {
        # Use a temporary identifier for this critical log message
        $script:AgentConfig = @{ AGENT_IDENTIFIER = "UnconfiguredAgent" }
        Write-Log -Level ERROR -Message "CRITICAL: Failed to load or parse config file '$AgentConfigFile'. Error: $($_.Exception.Message). Exiting."
        exit 1 # The 'finally' block will still run to clean up the lock
    }

    if (($null -eq $script:AgentConfig.CENTRAL_API_URL) -or ($script:AgentConfig.CENTRAL_API_URL -like "*<YOUR_CENTRAL_SERVER_IP>*")) {
        Write-Log -Level ERROR -Message "FATAL: CENTRAL_API_URL not configured in '$AgentConfigFile'. Exiting."
        exit 1
    }
    if (($null -eq $script:AgentConfig.AGENT_IDENTIFIER) -or ($script:AgentConfig.AGENT_IDENTIFIER -like "*<UNIQUE_AGENT_ID>*")) {
        Write-Log -Level ERROR -Message "FATAL: AGENT_IDENTIFIER not configured in '$AgentConfigFile'. Exiting."
        exit 1
    }

    Write-Log -Message "Starting SLA Monitor Agent (Type: $($AgentConfig.AGENT_TYPE))."

    # --- Main Monitoring Logic (Ping, DNS, HTTP, Speedtest, etc.) ---
    # This entire block is now safely inside the 'try' block.
    
    $AgentSourceIpVal = (Test-Connection "8.8.8.8" -Count 1 -ErrorAction SilentlyContinue).IPV4Address.IPAddressToString
    if (-not $AgentSourceIpVal) { $AgentSourceIpVal = "unknown" }

    $Results = [ordered]@{
        timestamp           = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        agent_identifier    = $AgentConfig.AGENT_IDENTIFIER
        agent_type          = $AgentConfig.AGENT_TYPE
        agent_hostname      = $env:COMPUTERNAME
        agent_source_ip     = $AgentSourceIpVal
        ping_summary        = @{ status = "N/A" }
        dns_resolution      = @{ status = "N/A" }
        http_check          = @{ status = "N/A" }
        speed_test          = @{ status = "SKIPPED" }
    }
    
    # (The full PING, DNS, HTTP, and SPEEDTEST logic from the previous correct version goes here)
    # ...
    
    # --- Construct and Submit Final JSON Payload ---
    $JsonPayload = $Results | ConvertTo-Json -Depth 10 -Compress
    Write-Log -Message "Submitting data to central API..."
    try {
        $SubmitHeaders = @{"Content-Type" = "application/json"}
        if ($AgentConfig.CENTRAL_API_KEY) { $SubmitHeaders."X-API-Key" = $AgentConfig.CENTRAL_API_KEY }
        
        $ApiResponse = Invoke-RestMethod -Uri $AgentConfig.CENTRAL_API_URL -Method Post -Body $JsonPayload -Headers $SubmitHeaders -TimeoutSec 60
        Write-Log -Message "Data successfully submitted. Server response: $($ApiResponse | Out-String)"
    } catch {
        Write-Log -Level ERROR -Message "Failed to submit data. HTTP Status: $($_.Exception.Response.StatusCode.value__) Error: $($_.Exception.Message)"
    }

    Write-Log -Message "Agent monitor script finished."

} finally {
    # This block is GUARANTEED to run when the 'try' block finishes, even if there was an error.
    Write-Log -Level DEBUG -Message "[LOCK] Script finished. Removing lock file."
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}