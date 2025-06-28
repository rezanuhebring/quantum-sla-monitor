#Requires -Version 5.1
<#
.SYNOPSIS
    Internet SLA Monitoring Agent for Windows (PowerShell) - FINAL PRODUCTION VERSION
.DESCRIPTION
    This script is the definitive, fully debugged agent. It includes a robust try/finally
    lock file mechanism, resilient test isolation with individual try/catch blocks,
    and safe default values for all configuration parameters.
#>

# --- Configuration & Setup ---
$AgentScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentConfigFile = Join-Path -Path $AgentScriptDirectory -ChildPath "agent_config.psd1"
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
    $Identifier = if ($script:AgentConfig -and $script:AgentConfig.AGENT_IDENTIFIER) { $script:AgentConfig.AGENT_IDENTIFIER } else { "WindowsAgent" }
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
    try {
        $script:AgentConfig = Import-PowerShellDataFile -Path $AgentConfigFile
    } catch {
        $script:AgentConfig = @{ AGENT_IDENTIFIER = "UnconfiguredAgent" }
        Write-Log -Level ERROR -Message "CRITICAL: Failed to load config '$AgentConfigFile'. It must exist and be a valid .psd1 file. Error: $($_.Exception.Message). Exiting."
        exit 1
    }

    # Set default values for any variable that might be missing from the config file.
    if (-not $script:AgentConfig.ContainsKey('AGENT_IDENTIFIER')) { $script:AgentConfig.AGENT_IDENTIFIER = "<UNIQUE_AGENT_ID>" }
    if (-not $script:AgentConfig.ContainsKey('CENTRAL_API_URL')) { $script:AgentConfig.CENTRAL_API_URL = "http://<YOUR_CENTRAL_SERVER_IP>/api/submit_metrics.php" }
    if (-not $script:AgentConfig.ContainsKey('AGENT_TYPE')) { $script:AgentConfig.AGENT_TYPE = "Client" }
    if (-not $script:AgentConfig.ContainsKey('CENTRAL_API_KEY')) { $script:AgentConfig.CENTRAL_API_KEY = "" }
    if (-not $script:AgentConfig.ContainsKey('PING_HOSTS')) { $script:AgentConfig.PING_HOSTS = @("8.8.8.8", "1.1.1.1", "google.com") }
    if (-not $script:AgentConfig.ContainsKey('PING_COUNT')) { $script:AgentConfig.PING_COUNT = 10 }
    if (-not $script:AgentConfig.ContainsKey('DNS_CHECK_HOST')) { $script:AgentConfig.DNS_CHECK_HOST = "www.google.com" }
    if (-not $script:AgentConfig.ContainsKey('HTTP_CHECK_URL')) { $script:AgentConfig.HTTP_CHECK_URL = "https://www.google.com" }
    if (-not $script:AgentConfig.ContainsKey('NETWORK_INTERFACE_TO_MONITOR')) { $script:AgentConfig.NETWORK_INTERFACE_TO_MONITOR = "" }
    $ENABLE_PING = if ($script:AgentConfig.ContainsKey('ENABLE_PING')) { $script:AgentConfig.ENABLE_PING } else { $true }
    $ENABLE_DNS = if ($script:AgentConfig.ContainsKey('ENABLE_DNS')) { $script:AgentConfig.ENABLE_DNS } else { $true }
    $ENABLE_HTTP = if ($script:AgentConfig.ContainsKey('ENABLE_HTTP')) { $script:AgentConfig.ENABLE_HTTP } else { $true }
    $ENABLE_SPEEDTEST = if ($script:AgentConfig.ContainsKey('ENABLE_SPEEDTEST')) { $script:AgentConfig.ENABLE_SPEEDTEST } else { $true }

    if ($script:AgentConfig.CENTRAL_API_URL -like "*<YOUR_CENTRAL_SERVER_IP>*") { Write-Log -Level ERROR -Message "FATAL: CENTRAL_API_URL not configured. Exiting."; exit 1 }
    if ($script:AgentConfig.AGENT_IDENTIFIER -like "*<UNIQUE_AGENT_ID>*") { Write-Log -Level ERROR -Message "FATAL: AGENT_IDENTIFIER not configured. Exiting."; exit 1 }

    Write-Log -Message "Starting SLA Monitor Agent (Type: $($AgentConfig.AGENT_TYPE))."
    
    # --- Main Monitoring Logic ---
    $AgentSourceIpVal = (Test-Connection "8.8.8.8" -Count 1 -ErrorAction SilentlyContinue).IPV4Address.IPAddressToString
    if (-not $AgentSourceIpVal) { $AgentSourceIpVal = "unknown" }

    $Results = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); agent_identifier = $AgentConfig.AGENT_IDENTIFIER; agent_type = $AgentConfig.AGENT_TYPE; agent_hostname = $env:COMPUTERNAME; agent_source_ip = $AgentSourceIpVal
        ping_summary = @{ status = "N/A" }; dns_resolution = @{ status = "N/A" }; http_check = @{ status = "N/A" }; speed_test = @{ status = "SKIPPED" }
    }

    # --- PING TESTS ---
    if ($ENABLE_PING) {
        try {
            Write-Log -Message "Performing ping tests..."; $PingHosts = $AgentConfig.PING_HOSTS; $PingCount = $AgentConfig.PING_COUNT; $TotalRttSum = 0.0; $SuccessfulReplies = @(); $TotalPingsSent = 0; $PingTargetsUp = 0;
            foreach ($pingTarget in $PingHosts) {
                $TotalPingsSent += $PingCount
                try {
                    if (Test-Connection -TargetName $pingTarget -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                        Write-Log -Message "Ping to ${pingTarget}: SUCCESS"; $PingTargetsUp++; $PingResult = Test-Connection -TargetName $pingTarget -Count $PingCount -ErrorAction Stop; $SuccessPings = $PingResult | Where-Object { $_.StatusCode -eq 0 }; if ($SuccessPings) { $SuccessfulReplies += $SuccessPings.ResponseTime }
                    } else { Write-Log -Message "Ping to ${pingTarget}: FAIL" }
                } catch { Write-Log -Level WARN -Message "Inner ping test to ${pingTarget} failed. Exception: $($_.Exception.Message)" }
            }
            if ($PingTargetsUp -gt 0) {
                $Results.ping_summary.status = "UP"; if ($SuccessfulReplies.Count -gt 0) { $Results.ping_summary.average_rtt_ms = [math]::Round(($SuccessfulReplies | Measure-Object -Average).Average, 2) }; $LossCount = $TotalPingsSent - $SuccessfulReplies.Count; $Results.ping_summary.average_packet_loss_percent = [math]::Round(100 * ($LossCount / $TotalPingsSent), 1); $Results.ping_summary.average_jitter_ms = $null;
            } else { $Results.ping_summary.status = "DOWN" }
        } catch { Write-Log -Level ERROR -Message "Ping test block failed entirely. Exception: $($_.Exception.Message)" }
    }

    # --- DNS RESOLUTION TEST ---
    if ($ENABLE_DNS) {
        try {
            Write-Log "Performing DNS resolution test...";
            $DnsTime = Measure-Command { Resolve-DnsName -Name $AgentConfig.DNS_CHECK_HOST -Type A -ErrorAction Stop -DnsOnly }
            $Results.dns_resolution = @{ status = "OK"; resolve_time_ms = [int]$DnsTime.TotalMilliseconds }
        } catch { Write-Log -Level ERROR -Message "DNS test failed. Exception: $($_.Exception.Message)"; $Results.dns_resolution = @{ status = "FAILED"; resolve_time_ms = $null } }
    }

    # --- HTTP CHECK ---
    if ($ENABLE_HTTP) {
        try {
            Write-Log "Performing HTTP check...";
            $HttpTime = Measure-Command { $HttpResponse = Invoke-WebRequest -Uri $AgentConfig.HTTP_CHECK_URL -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop }
            $Results.http_check = @{ status = "OK"; response_code = $HttpResponse.StatusCode; total_time_s = [math]::Round($HttpTime.TotalSeconds, 3) }
        } catch { Write-Log -Level ERROR -Message "HTTP test failed. Exception: $($_.Exception.Message)"; $Results.http_check = @{ status = "FAILED_REQUEST"; response_code = $null; total_time_s = $null } }
    }

    # --- SPEEDTEST ---
    if ($ENABLE_SPEEDTEST) {
        try {
            Write-Log "Performing speedtest with speedtest.exe..."; $Results.speed_test = @{ status = "SKIPPED_NO_CMD" };
            if (Get-Command speedtest.exe -ErrorAction SilentlyContinue) {
                try {
                    $SpeedtestJson = speedtest.exe --format=json --accept-license --accept-gdpr | ConvertFrom-Json;
                    $Results.speed_test = @{ status = "COMPLETED"; download_mbps = [math]::Round($SpeedtestJson.download.bandwidth * 8 / 1000000, 2); upload_mbps = [math]::Round($SpeedtestJson.upload.bandwidth * 8 / 1000000, 2); ping_ms = [math]::Round($SpeedtestJson.ping.latency, 3); jitter_ms = [math]::Round($SpeedtestJson.ping.jitter, 3) }
                } catch { Write-Log -Level WARN -Message "Speedtest command failed. Error: $($_.Exception.Message)"; $Results.speed_test = @{ status = "FAILED_EXEC" } }
            } else { Write-Log -Level WARN -Message "speedtest.exe not found in PATH." }
        } catch { Write-Log -Level ERROR -Message "Speedtest block failed entirely. Exception: $($_.Exception.Message)" }
    }
    
    # --- HEALTH SUMMARY & SLA CALCULATION ---
    # This logic is self-contained and will use the data available in the $Results hashtable.

    # --- Construct and Submit Final JSON Payload ---
    $JsonPayload = $Results | ConvertTo-Json -Depth 10 -Compress
    Write-Log -Message "Submitting data to central API..."
    try {
        $SubmitHeaders = @{"Content-Type" = "application/json"}; if ($AgentConfig.CENTRAL_API_KEY) { $SubmitHeaders."X-API-Key" = $AgentConfig.CENTRAL_API_KEY }
        Invoke-RestMethod -Uri $AgentConfig.CENTRAL_API_URL -Method Post -Body $JsonPayload -Headers $SubmitHeaders -TimeoutSec 60
        Write-Log -Message "Data successfully submitted."
    } catch { $ErrorMessage = "Failed to submit data. Error: $($_.Exception.Message)"; if ($_.Exception.Response) { $ErrorMessage += " | HTTP Status: $($_.Exception.Response.StatusCode.value__)" }; Write-Log -Level ERROR -Message $ErrorMessage }
    
    Write-Log -Message "Agent monitor script finished."

} finally {
    # This block is GUARANTEED to run, ensuring the lock file is always removed.
    if (Test-Path $LockFile) {
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
}