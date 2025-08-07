#Requires -Version 5.1
<#
.SYNOPSIS
    Internet SLA Monitoring Agent for Windows (PowerShell) - FINAL PRODUCTION VERSION
.DESCRIPTION
    This is the definitive, complete, and fully debugged agent script. It uses dot-sourcing 
    for the .ps1 config file and includes all logic for testing, health summary calculation,
    and data submission.
#>

# --- Configuration & Setup ---
$AgentScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentConfigFile = Join-Path -Path $AgentScriptDirectory -ChildPath "agent_config.ps1"
$LogFile = Join-Path -Path $AgentScriptDirectory -ChildPath "internet_monitor_agent_windows.log"
$LockFile = Join-Path -Path $env:TEMP -ChildPath "sla_monitor_agent.lock"

# --- Helper Functions ---
function Write-Log {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
    $Identifier = if ($script:AGENT_IDENTIFIER) { $script:AGENT_IDENTIFIER } else { "WindowsAgent" }
    $LogEntry = "[$Timestamp] [$Level] [$Identifier] $Message"
    try { Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue } catch {}
}

function Get-EffectiveThreshold {
    Param(
        [Parameter(Mandatory=$true)]$ProfileConfig,
        [Parameter(Mandatory=$true)]$LocalConfigVarName,
        [Parameter(Mandatory=$true)]$ProfileConfigKey,
        [Parameter(Mandatory=$true)]$DefaultValue
    )
    if ($ProfileConfig -and $ProfileConfig.PSObject.Properties[$ProfileConfigKey]) {
        return [double]$ProfileConfig.$ProfileConfigKey
    }
    $LocalValue = Get-Variable -Name $LocalConfigVarName -Scope "Script" -ErrorAction SilentlyContinue
    if ($LocalValue -ne $null) {
        return [double]$LocalValue.Value
    }
    return [double]$DefaultValue
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
        # Use dot-sourcing to load the script's variables into the current scope
        . $AgentConfigFile
    } else {
        Write-Log -Level ERROR -Message "CRITICAL: Agent config file not found at '$AgentConfigFile'. Exiting."
        exit 1
    }
    
    # Provide default values for any variables that might not be in the config file
    if ((Get-Variable -Name "ENABLE_PING" -ErrorAction SilentlyContinue) -eq $null) { $script:ENABLE_PING = $true }
    if ((Get-Variable -Name "ENABLE_DNS" -ErrorAction SilentlyContinue) -eq $null) { $script:ENABLE_DNS = $true }
    if ((Get-Variable -Name "ENABLE_HTTP" -ErrorAction SilentlyContinue) -eq $null) { $script:ENABLE_HTTP = $true }
    if ((Get-Variable -Name "ENABLE_SPEEDTEST" -ErrorAction SilentlyContinue) -eq $null) { $script:ENABLE_SPEEDTEST = $true }
    
    if (($null -eq $CENTRAL_API_URL) -or ($CENTRAL_API_URL -like "*<YOUR_CENTRAL_SERVER_IP>*")) { Write-Log -Level ERROR -Message "FATAL: CENTRAL_API_URL not configured. Exiting."; exit 1 }
    if (($null -eq $AGENT_IDENTIFIER) -or ($AGENT_IDENTIFIER -like "*<UNIQUE_AGENT_ID>*")) { Write-Log -Level ERROR -Message "FATAL: AGENT_IDENTIFIER not configured. Exiting."; exit 1 }

    Write-Log -Message "Starting SLA Monitor Agent (Type: $AGENT_TYPE)."
    
    # --- Fetch Profile from Central Server ---
    $CentralProfileConfigUrl = ($CENTRAL_API_URL -replace 'submit_metrics.php', 'get_profile_config.php') + "?agent_id=$AGENT_IDENTIFIER"
    $ProfileConfig = @{}
    try {
        Write-Log -Message "Fetching profile from: $CentralProfileConfigUrl"
        $WebRequest = Invoke-WebRequest -Uri $CentralProfileConfigUrl -Method Get -TimeoutSec 10 -UseBasicParsing
        if ($WebRequest.StatusCode -eq 200) { $ProfileConfig = $WebRequest.Content | ConvertFrom-Json; Write-Log -Message "Successfully fetched profile config." }
    } catch { Write-Log -Level WARN -Message "Could not fetch profile config, will use local settings. Error: $($_.Exception.Message)" }

    # --- Main Monitoring Logic ---
    $AgentSourceIpVal = (Invoke-RestMethod -Uri "https://api.ipify.org" -UseBasicParsing -ErrorAction SilentlyContinue); if (-not $AgentSourceIpVal) { $AgentSourceIpVal = "unknown" }
    $Results = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); agent_identifier = $AGENT_IDENTIFIER; agent_type = $AGENT_TYPE; agent_hostname = $env:COMPUTERNAME; agent_source_ip = $AgentSourceIpVal
        ping_summary = @{}; dns_resolution = @{}; http_check = @{}; speed_test = @{}
    }

    # PING TESTS
    if ($ENABLE_PING) {
        Write-Log -Message "Performing ping tests using Test-Connection..."
        $TotalRttSum = 0.0; $TotalLossCount = 0; $PingTargetsUp = 0; $JitterMeasurements = @();
        foreach ($pingTarget in $PING_HOSTS) {
            try {
                # Use PowerShell's native Test-Connection which is more robust
                $pingResult = Test-Connection -ComputerName $pingTarget -Count $PING_COUNT -ErrorAction Stop
                $PingTargetsUp++
                # Sum the round-trip times for averaging later
                $TotalRttSum += ($pingResult | Measure-Object -Property ResponseTime -Average).Average
                # Calculate jitter for this target
                $rtt_values = $pingResult.ResponseTime
                if ($rtt_values.Count -gt 1) {
                    for ($i = 0; $i -lt ($rtt_values.Count - 1); $i++) {
                        $JitterMeasurements += [math]::Abs($rtt_values[$i+1] - $rtt_values[$i])
                    }
                }
                Write-Log -Message "Ping to ${pingTarget}: SUCCESS"
            } catch {
                # If Test-Connection fails completely, it's 100% loss for this target
                $TotalLossCount += $PING_COUNT
                Write-Log -Level WARN -Message "Ping test to ${pingTarget} failed. Exception: $($_.Exception.Message)"
            }
        }
        if ($PingTargetsUp -gt 0) {
            $Results.ping_summary.status = "UP"
            $Results.ping_summary.average_rtt_ms = [math]::Round($TotalRttSum / $PingTargetsUp, 2)
            # Loss is total failed pings / total attempted pings
            $TotalPings = $PING_HOSTS.Count * $PING_COUNT
            $Results.ping_summary.average_packet_loss_percent = [math]::Round( ($TotalLossCount / $TotalPings) * 100, 1 )
            # Calculate average jitter across all successful pings
            if ($JitterMeasurements.Count -gt 0) {
                $Results.ping_summary.average_jitter_ms = [math]::Round(($JitterMeasurements | Measure-Object -Average).Average, 2)
            } else {
                $Results.ping_summary.average_jitter_ms = $null
            }
        }
        else { $Results.ping_summary.status = "DOWN" }
    }

    # DNS TEST
    if ($ENABLE_DNS) { Write-Log "Performing DNS resolution test..."; try { $DnsTime = Measure-Command { Resolve-DnsName -Name $DNS_CHECK_HOST -Type A -ErrorAction Stop -DnsOnly }; $Results.dns_resolution = @{ status = "OK"; resolve_time_ms = [int]$DnsTime.TotalMilliseconds } } catch { $Results.dns_resolution = @{ status = "FAILED"; resolve_time_ms = $null } } }

    # HTTP TEST
    if ($ENABLE_HTTP) { Write-Log "Performing HTTP check..."; try { $HttpTime = Measure-Command { $HttpResponse = Invoke-WebRequest -Uri $HTTP_CHECK_URL -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop }; $Results.http_check = @{ status = "OK"; response_code = $HttpResponse.StatusCode; total_time_s = [math]::Round($HttpTime.TotalSeconds, 3) } } catch { $Results.http_check = @{ status = "FAILED_REQUEST"; response_code = $null; total_time_s = $null } } }

    # SPEEDTEST
    if ($ENABLE_SPEEDTEST) {
        $Results.speed_test = @{ status = "SKIPPED_NO_CMD" };
        if ($SPEEDTEST_EXE_PATH -and (Test-Path $SPEEDTEST_EXE_PATH)) {
            Write-Log "Performing speedtest with '$SPEEDTEST_EXE_PATH'...";
            try { $SpeedtestJson = & $SPEEDTEST_EXE_PATH --format=json --accept-license | ConvertFrom-Json; $Results.speed_test = @{ status = "COMPLETED"; download_mbps = [math]::Round($SpeedtestJson.download.bandwidth * 8 / 1000000, 2); upload_mbps = [math]::Round($SpeedtestJson.upload.bandwidth * 8 / 1000000, 2); ping_ms = [math]::Round($SpeedtestJson.ping.latency, 3); jitter_ms = [math]::Round($SpeedtestJson.ping.jitter, 3) } }
            catch { Write-Log -Level WARN -Message "Speedtest command failed. Error: $($_.Exception.Message)"; $Results.speed_test = @{ status = "FAILED_EXEC" } }
        } else { Write-Log -Level WARN -Message "speedtest.exe path not configured or not found. Please re-run setup script." }
    }

    # --- HEALTH SUMMARY & SLA CALCULATION ---
    Write-Log "Calculating health summary...";
    $RttDegraded = Get-EffectiveThreshold $ProfileConfig "RTT_THRESHOLD_DEGRADED" "rtt_degraded" 100; $RttPoor = Get-EffectiveThreshold $ProfileConfig "RTT_THRESHOLD_POOR" "rtt_poor" 250
    $LossDegraded = Get-EffectiveThreshold $ProfileConfig "LOSS_THRESHOLD_DEGRADED" "loss_degraded" 2; $LossPoor = Get-EffectiveThreshold $ProfileConfig "LOSS_THRESHOLD_POOR" "loss_poor" 10
    $JitterDegraded = Get-EffectiveThreshold $ProfileConfig "PING_JITTER_THRESHOLD_DEGRADED" "ping_jitter_degraded" 30; $JitterPoor = Get-EffectiveThreshold $ProfileConfig "PING_JITTER_THRESHOLD_POOR" "ping_jitter_poor" 50
    $DnsDegraded = Get-EffectiveThreshold $ProfileConfig "DNS_TIME_THRESHOLD_DEGRADED" "dns_time_degraded" 300; $DnsPoor = Get-EffectiveThreshold $ProfileConfig "DNS_TIME_THRESHOLD_POOR" "dns_time_poor" 800
    $HttpDegraded = Get-EffectiveThreshold $ProfileConfig "HTTP_TIME_THRESHOLD_DEGRADED" "http_time_degraded" 1.0; $HttpPoor = Get-EffectiveThreshold $ProfileConfig "HTTP_TIME_THRESHOLD_POOR" "http_time_poor" 2.5
    $DlDegraded = Get-EffectiveThreshold $ProfileConfig "SPEEDTEST_DL_THRESHOLD_DEGRADED" "speedtest_dl_degraded" 60; $DlPoor = Get-EffectiveThreshold $ProfileConfig "SPEEDTEST_DL_THRESHOLD_POOR" "speedtest_dl_poor" 30
    $UlDegraded = Get-EffectiveThreshold $ProfileConfig "SPEEDTEST_UL_THRESHOLD_DEGRADED" "speedtest_ul_degraded" 20; $UlPoor = Get-EffectiveThreshold $ProfileConfig "SPEEDTEST_UL_THRESHOLD_POOR" "speedtest_ul_poor" 5
    
    $HealthSummary = "UNKNOWN"; $SlaMetInterval = 0;
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
    Write-Log -Message "Submitting data to central API...";
    try {
        $SubmitHeaders = @{"Content-Type" = "application/json"}; if ($CENTRAL_API_KEY) { $SubmitHeaders."X-API-Key" = $CENTRAL_API_KEY }
        Invoke-RestMethod -Uri $CENTRAL_API_URL -Method Post -Body $JsonPayload -Headers $SubmitHeaders -TimeoutSec 60; Write-Log -Message "Data successfully submitted."
    } catch { $ErrorMessage = "Failed to submit data. Error: $($_.Exception.Message)"; if ($_.Exception.Response) { $ErrorMessage += " | HTTP Status: $($_.Exception.Response.StatusCode.value__)" }; Write-Log -Level ERROR -Message $ErrorMessage }
    
    Write-Log -Message "Agent monitor script finished."

} finally {
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }
}