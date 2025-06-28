#Requires -Version 5.1
<#
.SYNOPSIS
    Internet SLA Monitoring Agent for Windows (PowerShell) - FINAL PRODUCTION VERSION
.DESCRIPTION
    This script is the definitive, fully debugged agent. It includes a robust try/finally
    lock file mechanism, clear error logging, and the complete logic for all monitoring tests.
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
    $Identifier = if ($script:AgentConfig -and $script:AgentConfig.AGENT_IDENTIFIER) { $script:AgentConfig.AGENT_IDENTIFIER } else { "WindowsAgent" }
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
New-Item -Path $LockFile -ItemType File -Force | Out-Null

# --- Main Execution Block ---
try {
    # --- Load and Validate Configuration ---
    try {
        $script:AgentConfig = Import-PowerShellDataFile -Path $AgentConfigFile
    } catch {
        $script:AgentConfig = @{ AGENT_IDENTIFIER = "UnconfiguredAgent" }
        Write-Log -Level ERROR -Message "CRITICAL: Failed to load config '$AgentConfigFile'. Error: $($_.Exception.Message). Exiting."
        exit 1
    }
    
    $ENABLE_PING = if ($script:AgentConfig.ContainsKey('ENABLE_PING')) { $script:AgentConfig.ENABLE_PING } else { $true }
    $ENABLE_DNS = if ($script:AgentConfig.ContainsKey('ENABLE_DNS')) { $script:AgentConfig.ENABLE_DNS } else { $true }
    $ENABLE_HTTP = if ($script:AgentConfig.ContainsKey('ENABLE_HTTP')) { $script:AgentConfig.ENABLE_HTTP } else { $true }
    $ENABLE_SPEEDTEST = if ($script:AgentConfig.ContainsKey('ENABLE_SPEEDTEST')) { $script:AgentConfig.ENABLE_SPEEDTEST } else { $true }
    
    if (($null -eq $script:AgentConfig.CENTRAL_API_URL) -or ($script:AgentConfig.CENTRAL_API_URL -like "*<YOUR_CENTRAL_SERVER_IP>*")) { Write-Log -Level ERROR -Message "FATAL: CENTRAL_API_URL not configured. Exiting."; exit 1 }
    if (($null -eq $script:AgentConfig.AGENT_IDENTIFIER) -or ($script:AgentConfig.AGENT_IDENTIFIER -like "*<UNIQUE_AGENT_ID>*")) { Write-Log -Level ERROR -Message "FATAL: AGENT_IDENTIFIER not configured. Exiting."; exit 1 }

    Write-Log -Message "Starting SLA Monitor Agent (Type: $($AgentConfig.AGENT_TYPE))."
    
    # --- Fetch Profile & Thresholds ---
    $CentralProfileConfigUrl = ($AgentConfig.CENTRAL_API_URL -replace 'submit_metrics.php', 'get_profile_config.php') + "?agent_id=$($AgentConfig.AGENT_IDENTIFIER)"
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
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); agent_identifier = $AgentConfig.AGENT_IDENTIFIER; agent_type = $AgentConfig.AGENT_TYPE; agent_hostname = $env:COMPUTERNAME; agent_source_ip = $AgentSourceIpVal
        ping_summary = @{}; dns_resolution = @{}; http_check = @{}; speed_test = @{}
    }

    if ($ENABLE_PING) {
        Write-Log -Message "Performing ping tests..."; $PingHosts = $AgentConfig.PING_HOSTS; $PingCount = $AgentConfig.PING_COUNT; $TotalRttSum = 0.0; $SuccessfulReplies = @(); $TotalPingsSent = 0; $PingTargetsUp = 0;
        foreach ($pingTarget in $PingHosts) {
            $TotalPingsSent += $PingCount
            try {
                if (Test-Connection -TargetName $pingTarget -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                    Write-Log -Message "Ping to ${pingTarget}: SUCCESS"; $PingTargetsUp++; $PingResult = Test-Connection -TargetName $pingTarget -Count $PingCount -ErrorAction Stop; $SuccessPings = $PingResult | Where-Object { $_.StatusCode -eq 0 }; if ($SuccessPings) { $SuccessfulReplies += $SuccessPings.ResponseTime }
                } else { Write-Log -Message "Ping to ${pingTarget}: FAIL" }
            } catch { Write-Log -Level WARN -Message "Ping test to ${pingTarget} failed. Exception: $($_.Exception.Message)" }
        }
        if ($PingTargetsUp -gt 0) { $Results.ping_summary.status = "UP"; if ($SuccessfulReplies.Count -gt 0) { $Results.ping_summary.average_rtt_ms = [math]::Round(($SuccessfulReplies | Measure-Object -Average).Average, 2) }; $LossCount = $TotalPingsSent - $SuccessfulReplies.Count; $Results.ping_summary.average_packet_loss_percent = [math]::Round(100 * ($LossCount / $TotalPingsSent), 1); $Results.ping_summary.average_jitter_ms = $null;
        } else { $Results.ping_summary.status = "DOWN" }
    }

    if ($ENABLE_DNS) {
        Write-Log "Performing DNS resolution test..."; try { $DnsTime = Measure-Command { Resolve-DnsName -Name $AgentConfig.DNS_CHECK_HOST -Type A -ErrorAction Stop -DnsOnly }; $Results.dns_resolution = @{ status = "OK"; resolve_time_ms = [int]$DnsTime.TotalMilliseconds } } catch { $Results.dns_resolution = @{ status = "FAILED"; resolve_time_ms = $null } }
    }

    if ($ENABLE_HTTP) {
        Write-Log "Performing HTTP check..."; try { $HttpTime = Measure-Command { $HttpResponse = Invoke-WebRequest -Uri $AgentConfig.HTTP_CHECK_URL -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop }; $Results.http_check = @{ status = "OK"; response_code = $HttpResponse.StatusCode; total_time_s = [math]::Round($HttpTime.TotalSeconds, 3) } } catch { $Results.http_check = @{ status = "FAILED_REQUEST"; response_code = $null; total_time_s = $null } }
    }

    if ($ENABLE_SPEEDTEST) {
        Write-Log "Performing speedtest with speedtest.exe..."; $Results.speed_test = @{ status = "SKIPPED_NO_CMD" };
        if (Get-Command speedtest.exe -ErrorAction SilentlyContinue) {
            try {
                $SpeedtestJson = speedtest.exe --format=json --accept-license --accept-gdpr | ConvertFrom-Json;
                $Results.speed_test = @{ status = "COMPLETED"; download_mbps = [math]::Round($SpeedtestJson.download.bandwidth * 8 / 1000000, 2); upload_mbps = [math]::Round($SpeedtestJson.upload.bandwidth * 8 / 1000000, 2); ping_ms = [math]::Round($SpeedtestJson.ping.latency, 3); jitter_ms = [math]::Round($SpeedtestJson.ping.jitter, 3) }
            } catch { Write-Log -Level WARN -Message "Speedtest command failed. Error: $($_.Exception.Message)"; $Results.speed_test = @{ status = "FAILED_EXEC" } }
        } else { Write-Log -Level WARN -Message "speedtest.exe not found in PATH." }
    }
    
    # --- Health Summary & SLA Calculation ---
    Write-Log "Calculating health summary..."; $HealthSummary = "UNKNOWN"; $SlaMetInterval = 0;
    function Get-Threshold($Profile, $Config, $Key, $Default) { if ($Profile.$Key -ne $null) { return [double]$Profile.$Key } elseif ($Config.ContainsKey($Key)) { return [double]$Config.$Key } else { return [double]$Default } }
    $RttDegraded = Get-Threshold $ProfileConfig $AgentConfig "rtt_degraded" 100; $RttPoor = Get-Threshold $ProfileConfig $AgentConfig "rtt_poor" 250; $LossDegraded = Get-Threshold $ProfileConfig $AgentConfig "loss_degraded" 2; $LossPoor = Get-Threshold $ProfileConfig $AgentConfig "loss_poor" 10;
    $JitterDegraded = Get-Threshold $ProfileConfig $AgentConfig "ping_jitter_degraded" 30; $JitterPoor = Get-Threshold $ProfileConfig $AgentConfig "ping_jitter_poor" 50; $DnsDegraded = Get-Threshold $ProfileConfig $AgentConfig "dns_time_degraded" 300; $DnsPoor = Get-Threshold $ProfileConfig $AgentConfig "dns_time_poor" 800;
    $HttpDegraded = Get-Threshold $ProfileConfig $AgentConfig "http_time_degraded" 1.0; $HttpPoor = Get-Threshold $ProfileConfig $AgentConfig "http_time_poor" 2.5; $DlDegraded = Get-Threshold $ProfileConfig $AgentConfig "speedtest_dl_degraded" 60; $DlPoor = Get-Threshold $ProfileConfig $AgentConfig "speedtest_dl_poor" 30;
    $UlDegraded = Get-Threshold $ProfileConfig $AgentConfig "speedtest_ul_degraded" 20; $UlPoor = Get-Threshold $ProfileConfig $AgentConfig "speedtest_ul_poor" 5;
    if ($Results.ping_summary.status -eq "DOWN") { $HealthSummary = "CONNECTIVITY_DOWN" }
    elseif ($Results.dns_resolution.status -eq "FAILED" -or $Results.http_check.status -eq "FAILED_REQUEST") { $HealthSummary = "CRITICAL_SERVICE_FAILURE" }
    else {
        $IsPoor = $false; $IsDegraded = $false;
        if (($Results.ping_summary.average_rtt_ms -gt $RttPoor) -or ($Results.ping_summary.average_packet_loss_percent -gt $LossPoor) -or ($Results.speed_test.jitter_ms -gt $JitterPoor) -or ($Results.dns_resolution.resolve_time_ms -gt $DnsPoor) -or ($Results.http_check.total_time_s -gt $HttpPoor)) { $IsPoor = $true }
        if ($Results.speed_test.status -eq "COMPLETED") { if (($Results.speed_test.download_mbps -lt $DlPoor) -or ($Results.speed_test.upload_mbps -lt $UlPoor)) { $IsPoor = $true } }
        if (-not $IsPoor) {
            if (($Results.ping_summary.average_rtt_ms -gt $RttDegraded) -or ($Results.ping_summary.average_packet_loss_percent -gt $LossDegraded) -or ($Results.speed_test.jitter_ms -gt $JitterDegraded) -or ($Results.dns_resolution.resolve_time_ms -gt $DnsDegraded) -or ($Results.http_check.total_time_s -gt $HttpDegraded)) { $IsDegraded = $true }
            if ($Results.speed_test.status -eq "COMPLETED") { if (($Results.speed_test.download_mbps -lt $DlDegraded) -or ($Results.speed_test.upload_mbps -lt $UlDegraded)) { $IsDegraded = $true } }
        }
        if ($IsPoor) { $HealthSummary = "POOR_PERFORMANCE" } elseif ($IsDegraded) { $HealthSummary = "DEGRADED_PERFORMANCE" } else { $HealthSummary = "GOOD_PERFORMANCE" }
    }
    if ($HealthSummary -eq "GOOD_PERFORMANCE") { $SlaMetInterval = 1 }
    Write-Log -Message "Health Summary: $HealthSummary";
    $Results.detailed_health_summary = $HealthSummary; $Results.current_sla_met_status = if ($SlaMetInterval -eq 1) { "MET" } else { "NOT_MET" };

    # --- Construct and Submit Final JSON Payload ---
    $JsonPayload = $Results | ConvertTo-Json -Depth 10 -Compress
    Write-Log -Message "Submitting data to central API..."
    try {
        $SubmitHeaders = @{"Content-Type" = "application/json"}; if ($AgentConfig.CENTRAL_API_KEY) { $SubmitHeaders."X-API-Key" = $AgentConfig.CENTRAL_API_KEY }
        Invoke-RestMethod -Uri $AgentConfig.CENTRAL_API_URL -Method Post -Body $JsonPayload -Headers $SubmitHeaders -TimeoutSec 60
        Write-Log -Message "Data successfully submitted."
    } catch {
        $ErrorMessage = "Failed to submit data. Error: $($_.Exception.Message)"; if ($_.Exception.Response) { $ErrorMessage += " | HTTP Status: $($_.Exception.Response.StatusCode.value__)" };
        Write-Log -Level ERROR -Message $ErrorMessage
    }
    Write-Log -Message "Agent monitor script finished."

} finally {
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }
}