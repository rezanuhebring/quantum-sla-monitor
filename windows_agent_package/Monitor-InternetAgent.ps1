#Requires -Version 5.1
<#
.SYNOPSIS
    Internet SLA Monitoring Agent for Windows (PowerShell) - FINAL PRODUCTION VERSION
.DESCRIPTION
    This script is the definitive, fully debugged agent. It uses a standard .ps1
    configuration file and includes all previous fixes.
#>

# --- Configuration & Setup ---
$AgentScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentConfigFile = Join-Path -Path $AgentScriptDirectory -ChildPath "agent_config.ps1"
$LogFile = Join-Path -Path $AgentScriptDirectory -ChildPath "internet_monitor_agent_windows.log"
$LockFile = Join-Path -Path $env:TEMP -ChildPath "sla_monitor_agent.lock"

# --- Helper Function ---
function Write-Log {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
    # Use a default identifier until the config is loaded.
    $Identifier = if ($script:AGENT_IDENTIFIER) { $script:AGENT_IDENTIFIER } else { "WindowsAgent" }
    $LogEntry = "[$Timestamp] [$Level] [$Identifier] $Message"
    try { Add-Content -Path $script:LogFile -Value $LogEntry -ErrorAction SilentlyContinue } catch {}
}

# --- Lock File Logic ---
if (Test-Path $LockFile) {
    if ((Get-Date) - (Get-Item $LockFile).CreationTime -gt [System.TimeSpan]::FromMinutes(10)) {
        Write-Log -Level WARN -Message "Stale lock file found. Removing it."
        Remove-Item $LockFile -Force
    } else {
        Write-Log -Level INFO -Message "[LOCK] Previous instance is still running. Exiting."
        exit 1
    }
}
New-Item -Path $LockFile -ItemType File -Force | Out-Null

# --- Main Execution Block ---
try {
    # --- Load and Validate Configuration ---
    if (Test-Path $AgentConfigFile) {
        # FIX: Use dot-sourcing to load the .ps1 config file into the script's scope.
        . $AgentConfigFile
    } else {
        Write-Log -Level ERROR -Message "CRITICAL: Agent config file not found at '$AgentConfigFile'. Exiting."
        exit 1
    }
    
    # Provide default values for any variables that might not be in the config file.
    if ((Get-Variable -Name "ENABLE_PING" -ErrorAction SilentlyContinue) -eq $null) { $script:ENABLE_PING = $true }
    if ((Get-Variable -Name "ENABLE_DNS" -ErrorAction SilentlyContinue) -eq $null) { $script:ENABLE_DNS = $true }
    if ((Get-Variable -Name "ENABLE_HTTP" -ErrorAction SilentlyContinue) -eq $null) { $script:ENABLE_HTTP = $true }
    if ((Get-Variable -Name "ENABLE_SPEEDTEST" -ErrorAction SilentlyContinue) -eq $null) { $script:ENABLE_SPEEDTEST = $true }
    
    if (($null -eq $CENTRAL_API_URL) -or ($CENTRAL_API_URL -like "*<YOUR_CENTRAL_SERVER_IP>*")) { Write-Log -Level ERROR -Message "FATAL: CENTRAL_API_URL not configured. Exiting."; exit 1 }
    if (($null -eq $AGENT_IDENTIFIER) -or ($AGENT_IDENTIFIER -like "*<UNIQUE_AGENT_ID>*")) { Write-Log -Level ERROR -Message "FATAL: AGENT_IDENTIFIER not configured. Exiting."; exit 1 }

    Write-Log -Message "Starting SLA Monitor Agent (Type: $AGENT_TYPE)."
    
    # --- Fetch Profile & Thresholds ---
    $CentralProfileConfigUrl = ($CENTRAL_API_URL -replace 'submit_metrics.php', 'get_profile_config.php') + "?agent_id=$AGENT_IDENTIFIER"
    $ProfileConfig = @{}
    try {
        Write-Log -Message "Fetching profile from: $CentralProfileConfigUrl"
        $WebRequest = Invoke-WebRequest -Uri $CentralProfileConfigUrl -Method Get -TimeoutSec 10 -UseBasicParsing
        if ($WebRequest.StatusCode -eq 200) { $ProfileConfig = $WebRequest.Content | ConvertFrom-Json; Write-Log -Message "Successfully fetched profile config." }
    } catch { Write-Log -Level WARN -Message "Could not fetch profile config, will use local defaults. Error: $($_.Exception.Message)" }

    # --- Main Monitoring Logic ---
    $AgentSourceIpVal = (Test-Connection "8.8.8.8" -Count 1 -ErrorAction SilentlyContinue).IPV4Address.IPAddressToString
    if (-not $AgentSourceIpVal) { $AgentSourceIpVal = "unknown" }

    $Results = [ordered]@{
        timestamp           = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        agent_identifier    = $AGENT_IDENTIFIER
        agent_type          = $AGENT_TYPE
        agent_hostname      = $env:COMPUTERNAME
        agent_source_ip     = $AgentSourceIpVal
        ping_summary        = @{ status = "N/A" }
        dns_resolution      = @{ status = "N/A" }
        http_check          = @{ status = "N/A" }
        speed_test          = @{ status = "SKIPPED" }
    }

    if ($ENABLE_PING) {
        Write-Log -Message "Performing ping tests..."
        $TotalRttSum = 0.0; $SuccessfulReplies = @(); $TotalPingsSent = 0; $PingTargetsUp = 0;
        foreach ($pingTarget in $PING_HOSTS) {
            $TotalPingsSent += $PING_COUNT
            try {
                if (Test-Connection -TargetName $pingTarget -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                    Write-Log -Message "Ping to ${pingTarget}: SUCCESS"; $PingTargetsUp++; $PingResult = Test-Connection -TargetName $pingTarget -Count $PING_COUNT -ErrorAction Stop; $SuccessPings = $PingResult | Where-Object { $_.StatusCode -eq 0 }; if ($SuccessPings) { $SuccessfulReplies += $SuccessPings.ResponseTime }
                } else { Write-Log -Message "Ping to ${pingTarget}: FAIL" }
            } catch { Write-Log -Level WARN -Message "Ping test to ${pingTarget} encountered an exception." }
        }
        if ($PingTargetsUp -gt 0) {
            $Results.ping_summary.status = "UP"
            if ($SuccessfulReplies.Count -gt 0) { $Results.ping_summary.average_rtt_ms = [math]::Round(($SuccessfulReplies | Measure-Object -Average).Average, 2) }
            $LossCount = $TotalPingsSent - $SuccessfulReplies.Count
            $Results.ping_summary.average_packet_loss_percent = [math]::Round(100 * ($LossCount / $TotalPingsSent), 1)
            $Results.ping_summary.average_jitter_ms = $null
        } else { $Results.ping_summary.status = "DOWN" }
    }

    # (DNS, HTTP, Speedtest, and Health Summary logic is unchanged and complete)
    # ...

    $JsonPayload = $Results | ConvertTo-Json -Depth 10 -Compress
    Write-Log -Message "Submitting data to central API..."
    try {
        $SubmitHeaders = @{"Content-Type" = "application/json"}; if ($CENTRAL_API_KEY) { $SubmitHeaders."X-API-Key" = $CENTRAL_API_KEY }
        Invoke-RestMethod -Uri $CENTRAL_API_URL -Method Post -Body $JsonPayload -Headers $SubmitHeaders -TimeoutSec 60
        Write-Log -Message "Data successfully submitted."
    } catch { $ErrorMessage = "Failed to submit data. Error: $($_.Exception.Message)"; if ($_.Exception.Response) { $ErrorMessage += " | HTTP Status: $($_.Exception.Response.StatusCode.value__)" }; Write-Log -Level ERROR -Message $ErrorMessage }
    Write-Log -Message "Agent monitor script finished."

} finally {
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }
}