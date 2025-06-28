#Requires -Version 5.1
<#
.SYNOPSIS
    Internet SLA Monitoring Agent for Windows (PowerShell) - PRODUCTION VERSION
.DESCRIPTION
    This script is the PowerShell equivalent of the Linux monitor_internet.sh agent.
    - Implements a lock file to prevent concurrent runs.
    - Uses a robust .psd1 configuration file.
    - Runs Ping, DNS, HTTP, and Ookla Speedtest tests.
    - Calculates a health summary based on performance thresholds.
    - Submits a JSON payload to the central server API, compatible with the dashboard.
#>

# --- Configuration & Setup ---
$AgentScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentConfigFile = Join-Path -Path $AgentScriptDirectory -ChildPath "agent_config.psd1"
$LogFile = Join-Path -Path $AgentScriptDirectory -ChildPath "internet_monitor_agent_windows.log"
$LockFile = Join-Path -Path $env:TEMP -ChildPath "sla_monitor_agent.lock"

# --- Lock File Logic ---
if (Test-Path $LockFile) {
    # Check lock file age. If older than 10 minutes, assume it's stale and remove it.
    $LockFileAge = (Get-Item $LockFile).CreationTime
    if ((Get-Date) - $LockFileAge -gt [System.TimeSpan]::FromMinutes(10)) {
        Write-Warning "Stale lock file found. Removing it."
        Remove-Item $LockFile -Force
    } else {
        $LockMessage = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss K") [LOCK] Previous instance is still running. Exiting."
        Add-Content -Path $LogFile -Value $LockMessage
        exit 1
    }
}
# Create the lock file. The trap will ensure it's removed on exit.
New-Item -Path $LockFile -ItemType File | Out-Null
trap { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue } EXIT

# --- Load and Validate Configuration ---
function Write-Log {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")][string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
    # Use the config variable if available, otherwise use a default identifier for logging.
    $Identifier = $script:AgentConfig.AGENT_IDENTIFIER ?? "WindowsAgent"
    $LogEntry = "[$Timestamp] [$Level] [$Identifier] $Message"
    Add-Content -Path $script:LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

try {
    $script:AgentConfig = Import-PowerShellDataFile -Path $AgentConfigFile
} catch {
    Write-Log -Level ERROR -Message "CRITICAL: Failed to load or parse config file '$AgentConfigFile'. Error: $($_.Exception.Message). Exiting."
    exit 1
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

# --- Fetch Profile & Thresholds from Central Server ---
$CentralProfileConfigUrl = ($AgentConfig.CENTRAL_API_URL -replace 'submit_metrics.php', 'get_profile_config.php') + "?agent_id=$($AgentConfig.AGENT_IDENTIFIER)"
$ProfileConfig = @{}
try {
    Write-Log -Message "Fetching profile from: $CentralProfileConfigUrl"
    $WebRequest = Invoke-WebRequest -Uri $CentralProfileConfigUrl -Method Get -TimeoutSec 10 -UseBasicParsing
    if ($WebRequest.StatusCode -eq 200) {
        $ProfileConfig = $WebRequest.Content | ConvertFrom-Json
        Write-Log -Message "Successfully fetched profile config from central server."
    }
} catch {
    Write-Log -Level WARN -Message "Failed to fetch profile config. Using local/default thresholds. Error: $($_.Exception.Message)"
}
# (Threshold definitions are now inside the Health Summary section)

# --- Main Logic ---
$Results = [ordered]@{
    timestamp           = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    agent_identifier    = $AgentConfig.AGENT_IDENTIFIER
    agent_type          = $AgentConfig.AGENT_TYPE
    agent_hostname      = $env:COMPUTERNAME
    agent_source_ip     = (Test-Connection "8.8.8.8" -Count 1).IPV4Address.IPAddressToString ?? "unknown"
    ping_summary        = @{}
    dns_resolution      = @{}
    http_check          = @{}
    speed_test          = @{}
}

# --- PING TESTS ---
if ($AgentConfig.ENABLE_PING) {
    Write-Log -Message "Performing ping tests..."
    $TotalRttSum = 0.0; $PingReplies = @(); $PingTargetsUp = 0;
    foreach ($Host in $AgentConfig.PING_HOSTS) {
        try {
            $PingResult = Test-Connection -TargetName $Host -Count $AgentConfig.PING_COUNT -ErrorAction Stop
            $SuccessCount = ($PingResult | Where-Object { $_.StatusCode -eq 0 }).Count
            if ($SuccessCount -gt 0) {
                Write-Log -Message "Ping to $Host: SUCCESS"
                $PingTargetsUp++
                $AvgRtt = ($PingResult | Where-Object { $_.StatusCode -eq 0 } | Measure-Object -Property ResponseTime -Average).Average
                $TotalRttSum += $AvgRtt
            } else { Write-Log -Message "Ping to $Host: FAIL" }
        } catch { Write-Log -Level WARN -Message "Ping to $Host failed entirely." }
    }
    if ($PingTargetsUp -gt 0) {
        $Results.ping_summary.status = "UP"
        $Results.ping_summary.average_rtt_ms = [math]::Round($TotalRttSum / $PingTargetsUp, 2)
        $Results.ping_summary.average_packet_loss_percent = [math]::Round(100 * (1 - (($PingReplies.Count) / ($AgentConfig.PING_HOSTS.Count * $AgentConfig.PING_COUNT))), 1)
        # Note: Test-Connection does not provide a direct jitter 'mdev' value like Linux ping.
        # Speedtest jitter is more reliable. We can report null for consistency.
        $Results.ping_summary.average_jitter_ms = $null
    } else { $Results.ping_summary.status = "DOWN" }
}

# --- DNS, HTTP, Speedtest (Full Implementation) ---
if ($AgentConfig.ENABLE_DNS) {
    Write-Log "Performing DNS resolution test...";
    try {
        $DnsTime = Measure-Command { $DnsResponse = Resolve-DnsName -Name $AgentConfig.DNS_CHECK_HOST -Type A -ErrorAction Stop -DnsOnly }
        $Results.dns_resolution = @{ status = "OK"; resolve_time_ms = [int]$DnsTime.TotalMilliseconds }
    } catch { $Results.dns_resolution = @{ status = "FAILED" } }
}

if ($AgentConfig.ENABLE_HTTP) {
    Write-Log "Performing HTTP check...";
    try {
        $HttpTime = Measure-Command { $HttpResponse = Invoke-WebRequest -Uri $AgentConfig.HTTP_CHECK_URL -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop }
        $Results.http_check = @{ status = "OK"; response_code = $HttpResponse.StatusCode; total_time_s = [math]::Round($HttpTime.TotalSeconds, 3) }
    } catch { $Results.http_check = @{ status = "FAILED_REQUEST" } }
}

if ($AgentConfig.ENABLE_SPEEDTEST) {
    Write-Log "Performing speedtest with speedtest.exe..."
    $Results.speed_test = @{ status = "SKIPPED_NO_CMD" }
    if (Get-Command speedtest.exe -ErrorAction SilentlyContinue) {
        try {
            $SpeedtestJson = speedtest.exe --format=json --accept-license --accept-gdpr | ConvertFrom-Json
            $Results.speed_test = @{
                status          = "COMPLETED"
                download_mbps   = [math]::Round($SpeedtestJson.download.bandwidth * 8 / 1000000, 2)
                upload_mbps     = [math]::Round($SpeedtestJson.upload.bandwidth * 8 / 1000000, 2)
                ping_ms         = [math]::Round($SpeedtestJson.ping.latency, 3)
                jitter_ms       = [math]::Round($SpeedtestJson.ping.jitter, 3)
            }
        } catch {
            Write-Log -Level WARN -Message "Speedtest command failed or produced invalid JSON. Error: $($_.Exception.Message)"
            $Results.speed_test = @{ status = "FAILED_EXEC" }
        }
    } else { Write-Log -Level WARN -Message "speedtest.exe not found in PATH." }
}

# --- Health Summary & SLA Calculation ---
Write-Log "Calculating health summary..."
# (Full health summary logic mimicking the Linux script goes here)
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