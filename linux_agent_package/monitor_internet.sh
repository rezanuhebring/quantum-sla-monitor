#!/bin/bash
# Agent Version: Fetches profile from central (optional), sends data to central.

# --- Agent Default Configurations (can be overridden by agent_config.env) ---
DEFAULT_AGENT_IDENTIFIER="linux_agent_$(hostname -s)_$(date +%s%N | sha256sum | head -c 8)"
DEFAULT_AGENT_TYPE="ISP" # Default type if not set in config
DEFAULT_CENTRAL_API_URL="http://YOUR_CENTRAL_SERVER_IP/sla_status/api/submit_metrics.php" 
DEFAULT_NETWORK_INTERFACE_TO_MONITOR=""
DEFAULT_SLA_TARGET_PERCENTAGE=99.5; DEFAULT_RTT_THRESHOLD_DEGRADED=100; DEFAULT_RTT_THRESHOLD_POOR=250; DEFAULT_LOSS_THRESHOLD_DEGRADED=2; DEFAULT_LOSS_THRESHOLD_POOR=10; DEFAULT_PING_JITTER_THRESHOLD_DEGRADED=30; DEFAULT_PING_JITTER_THRESHOLD_POOR=50; DEFAULT_DNS_TIME_THRESHOLD_DEGRADED=300; DEFAULT_DNS_TIME_THRESHOLD_POOR=800; DEFAULT_HTTP_TIME_THRESHOLD_DEGRADED=1.0; DEFAULT_HTTP_TIME_THRESHOLD_POOR=2.5; DEFAULT_SPEEDTEST_DL_THRESHOLD_POOR=30; DEFAULT_SPEEDTEST_DL_THRESHOLD_DEGRADED=60; DEFAULT_SPEEDTEST_UL_THRESHOLD_POOR=10; DEFAULT_SPEEDTEST_UL_THRESHOLD_DEGRADED=20;
DEFAULT_ALERT_HOSTNAME=$(hostname -s)

# --- Source the local agent configuration file ---
AGENT_CONFIG_FILE="/opt/sla_monitor/agent_config.env"
LOG_FILE="/var/log/internet_sla_monitor_agent.log" # Agent-specific log

if [ -f "$AGENT_CONFIG_FILE" ]; then
    set -a; source "$AGENT_CONFIG_FILE"; set +a
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z'): Loaded agent configuration from $AGENT_CONFIG_FILE" >> "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z'): WARNING: Agent configuration $AGENT_CONFIG_FILE not found. Using script defaults." >> "$LOG_FILE"
fi

AGENT_IDENTIFIER="${AGENT_IDENTIFIER:-$DEFAULT_AGENT_IDENTIFIER}"
AGENT_TYPE="${AGENT_TYPE:-$DEFAULT_AGENT_TYPE}"
CENTRAL_API_URL="${CENTRAL_API_URL:-$DEFAULT_CENTRAL_API_URL}"
NETWORK_INTERFACE_TO_MONITOR="${NETWORK_INTERFACE_TO_MONITOR:-$DEFAULT_NETWORK_INTERFACE_TO_MONITOR}"
CENTRAL_API_KEY="${CENTRAL_API_KEY:-}" 

SLA_TARGET_PERCENTAGE=${SLA_TARGET_PERCENTAGE:-$DEFAULT_SLA_TARGET_PERCENTAGE}
RTT_THRESHOLD_DEGRADED=${RTT_THRESHOLD_DEGRADED:-$DEFAULT_RTT_THRESHOLD_DEGRADED}; RTT_THRESHOLD_POOR=${RTT_THRESHOLD_POOR:-$DEFAULT_RTT_THRESHOLD_POOR}
LOSS_THRESHOLD_DEGRADED=${LOSS_THRESHOLD_DEGRADED:-$DEFAULT_LOSS_THRESHOLD_DEGRADED}; LOSS_THRESHOLD_POOR=${LOSS_THRESHOLD_POOR:-$DEFAULT_LOSS_THRESHOLD_POOR}
PING_JITTER_THRESHOLD_DEGRADED=${PING_JITTER_THRESHOLD_DEGRADED:-$DEFAULT_PING_JITTER_THRESHOLD_DEGRADED}; PING_JITTER_THRESHOLD_POOR=${PING_JITTER_THRESHOLD_POOR:-$DEFAULT_PING_JITTER_THRESHOLD_POOR}
DNS_TIME_THRESHOLD_DEGRADED=${DNS_TIME_THRESHOLD_DEGRADED:-$DEFAULT_DNS_TIME_THRESHOLD_DEGRADED}; DNS_TIME_THRESHOLD_POOR=${DNS_TIME_THRESHOLD_POOR:-$DEFAULT_DNS_TIME_THRESHOLD_POOR}
HTTP_TIME_THRESHOLD_DEGRADED=${HTTP_TIME_THRESHOLD_DEGRADED:-$DEFAULT_HTTP_TIME_THRESHOLD_DEGRADED}; HTTP_TIME_THRESHOLD_POOR=${HTTP_TIME_THRESHOLD_POOR:-$DEFAULT_HTTP_TIME_THRESHOLD_POOR}
SPEEDTEST_DL_THRESHOLD_POOR=${SPEEDTEST_DL_THRESHOLD_POOR:-$DEFAULT_SPEEDTEST_DL_THRESHOLD_POOR}; SPEEDTEST_DL_THRESHOLD_DEGRADED=${SPEEDTEST_DL_THRESHOLD_DEGRADED:-$DEFAULT_SPEEDTEST_DL_THRESHOLD_DEGRADED}
SPEEDTEST_UL_THRESHOLD_POOR=${SPEEDTEST_UL_THRESHOLD_POOR:-$DEFAULT_SPEEDTEST_UL_THRESHOLD_POOR}; SPEEDTEST_UL_THRESHOLD_DEGRADED=${SPEEDTEST_UL_THRESHOLD_DEGRADED:-$DEFAULT_SPEEDTEST_UL_THRESHOLD_DEGRADED}
# TEAMS_WEBHOOK_URL and ALERT_HOSTNAME will be effectively managed by the central server profile for this agent.
# This agent just needs to send its own hostname.
ALERT_HOSTNAME_LOCAL=$(hostname -s)


log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z'): [$AGENT_IDENTIFIER] $1" >> "$LOG_FILE"; }

log_message "Starting SLA Monitor Agent Script. Type: $AGENT_TYPE"
err_msg=""; if ! command -v jq &> /dev/null; then err_msg="jq command not found. "; fi; if ! command -v sqlite3 &> /dev/null; then err_msg+="sqlite3 command not found (for potential local logging only). "; fi
if [ -n "$err_msg" ]; then log_message "ERROR: $err_msg Exiting."; exit 1; fi # No JSON output if basic commands missing

# --- Attempt to fetch specific profile from central server (optional, agent can also run on local defaults) ---
# This step allows central management of thresholds if get_profile_config.php is implemented and working.
# If it fails, the agent uses its own (potentially less up-to-date) thresholds from agent_config.env or script defaults.
ISP_PROFILE_ID_FROM_CENTRAL="unknown_profile_id" # Will be updated if central fetch is successful
CENTRAL_PROFILE_CONFIG_URL="${CENTRAL_API_URL%/*}/../get_profile_config.php?agent_id=${AGENT_IDENTIFIER}" # Assumes api dir is sibling
log_message "Attempting to fetch profile from: $CENTRAL_PROFILE_CONFIG_URL"
_curl_headers_fetch_profile=()
if [ -n "$CENTRAL_API_KEY" ]; then _curl_headers_fetch_profile+=(-H "X-API-Key: $CENTRAL_API_KEY"); fi
_profile_json_from_central=$(curl -s -G "${_curl_headers_fetch_profile[@]}" "$CENTRAL_PROFILE_CONFIG_URL")

if [ -n "$_profile_json_from_central" ] && echo "$_profile_json_from_central" | jq -e . > /dev/null 2>&1; then
    log_message "Successfully fetched profile config from central server for $AGENT_IDENTIFIER."
    ISP_PROFILE_ID_FROM_CENTRAL=$(echo "$_profile_json_from_central" | jq -r '.id // "unknown_profile_id"')
    # Override local thresholds IF they are provided by the central profile
    SLA_TARGET_PERCENTAGE=$(echo "$_profile_json_from_central" | jq -r ".sla_target_percentage // \"$SLA_TARGET_PERCENTAGE\"")
    RTT_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".rtt_degraded // \"$RTT_THRESHOLD_DEGRADED\"")
    # ... (Repeat for ALL threshold variables, using jq's // operator for fallback to current value) ...
    RTT_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".rtt_poor // \"$RTT_THRESHOLD_POOR\"")
    LOSS_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".loss_degraded // \"$LOSS_THRESHOLD_DEGRADED\"")
    LOSS_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".loss_poor // \"$LOSS_THRESHOLD_POOR\"")
    PING_JITTER_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".ping_jitter_degraded // \"$PING_JITTER_THRESHOLD_DEGRADED\"")
    PING_JITTER_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".ping_jitter_poor // \"$PING_JITTER_THRESHOLD_POOR\"")
    DNS_TIME_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".dns_time_degraded // \"$DNS_TIME_THRESHOLD_DEGRADED\"")
    DNS_TIME_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".dns_time_poor // \"$DNS_TIME_THRESHOLD_POOR\"")
    HTTP_TIME_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".http_time_degraded // \"$HTTP_TIME_THRESHOLD_DEGRADED\"")
    HTTP_TIME_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".http_time_poor // \"$HTTP_TIME_THRESHOLD_POOR\"")
    SPEEDTEST_DL_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".speedtest_dl_degraded // \"$SPEEDTEST_DL_THRESHOLD_DEGRADED\"")
    SPEEDTEST_DL_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".speedtest_dl_poor // \"$SPEEDTEST_DL_THRESHOLD_POOR\"")
    SPEEDTEST_UL_THRESHOLD_DEGRADED=$(echo "$_profile_json_from_central" | jq -r ".speedtest_ul_degraded // \"$SPEEDTEST_UL_THRESHOLD_DEGRADED\"")
    SPEEDTEST_UL_THRESHOLD_POOR=$(echo "$_profile_json_from_central" | jq -r ".speedtest_ul_poor // \"$SPEEDTEST_UL_THRESHOLD_POOR\"")
    # Note: TEAMS_WEBHOOK_URL is not used by agent; central server handles notifications based on its DB.
    # ALERT_HOSTNAME is determined locally, but central profile could have an override it uses.
else
    log_message "WARN: Failed to fetch/parse profile config from central for $AGENT_IDENTIFIER. Using local/default thresholds. Response: $_profile_json_from_central"
fi
log_message "Effective monitoring thresholds - RTT Degraded: $RTT_THRESHOLD_DEGRADED, RTT Poor: $RTT_THRESHOLD_POOR, Loss Degraded: $LOSS_THRESHOLD_DEGRADED, etc."


LOG_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ"); declare -A results
AGENT_SOURCE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null || hostname -I | awk '{print $1}')

INTERFACE_ARG=""; SOURCE_IP_ARG_FOR_DIG=""; PING_INTERFACE_ARG=""; SPEEDTEST_INTERFACE_ARG=""
if [ -n "$NETWORK_INTERFACE_TO_MONITOR" ] && [ "$NETWORK_INTERFACE_TO_MONITOR" != "NULL" ]; then _SOURCE_IP_AGENT=$(ip -4 addr show "$NETWORK_INTERFACE_TO_MONITOR" | grep -oP 'inet \K[\d.]+' | head -n 1); if [ -n "$_SOURCE_IP_AGENT" ]; then INTERFACE_ARG="--interface $NETWORK_INTERFACE_TO_MONITOR"; PING_INTERFACE_ARG="-I $NETWORK_INTERFACE_TO_MONITOR"; SOURCE_IP_ARG_FOR_DIG="+source=$_SOURCE_IP_AGENT"; if [[ "$SPEEDTEST_COMMAND_PATH" == *"speedtest-cli"* ]]; then SPEEDTEST_INTERFACE_ARG="--source $_SOURCE_IP_AGENT"; else SPEEDTEST_INTERFACE_ARG="--interface $NETWORK_INTERFACE_TO_MONITOR"; fi; log_message "Agent using NIC: $NETWORK_INTERFACE_TO_MONITOR (IP: $_SOURCE_IP_AGENT)"; else log_message "WARN: Agent could not get IP for NIC '$NETWORK_INTERFACE_TO_MONITOR'."; INTERFACE_ARG=""; fi; fi
SPEEDTEST_FULL_ARGS="$SPEEDTEST_ARGS $SPEEDTEST_INTERFACE_ARG" # SPEEDTEST_ARGS is from detection logic (e.g. --format=json)
if [ "$ENABLE_SPEEDTEST" = true ] && [ -n "$SPEEDTEST_COMMAND_PATH" ]; then log_message "Speedtest command: $SPEEDTEST_COMMAND_PATH $SPEEDTEST_FULL_ARGS"; elif [ "$ENABLE_SPEEDTEST" = true ]; then log_message "ENABLE_SPEEDTEST is true, but no speedtest command path."; ENABLE_SPEEDTEST=false; fi

# --- PING TESTS ---
ping_targets_results=(); total_successful_pings=0; total_rtt_sum=0.0; total_loss_sum=0; total_jitter_sum=0.0; ping_targets_up=0; log_message "Performing ping tests (Interface: ${NETWORK_INTERFACE_TO_MONITOR:-default})..."
for host in "${PING_HOSTS[@]}"; do ping_output=$(ping ${PING_INTERFACE_ARG} -c "$PING_COUNT" -W "$PING_TIMEOUT" -q "$host" 2>&1); exit_code=$?; avg_jitter="N/A"; if [ $exit_code -eq 0 ]; then packet_loss=$(echo "$ping_output" | grep -oP '\d+(?=% packet loss)'); rtt_line=$(echo "$ping_output" | grep 'rtt min/avg/max/mdev'); avg_rtt=$(echo "$rtt_line" | cut -d'=' -f2 | cut -d'/' -f2); avg_jitter=$(echo "$rtt_line" | cut -d'=' -f2 | cut -d'/' -f4 | sed 's/\s*ms//'); if [[ -z "$avg_rtt" ]]; then avg_rtt="0"; fi; if [[ -z "$avg_jitter" ]]; then avg_jitter="N/A"; fi; target_status="UP"; ((ping_targets_up++)); total_rtt_sum=$(awk "BEGIN {print $total_rtt_sum + $avg_rtt}"); if [[ "$avg_jitter" != "N/A" ]]; then total_jitter_sum=$(awk "BEGIN {print $total_jitter_sum + $avg_jitter}"); fi; total_loss_sum=$((total_loss_sum + packet_loss)); else packet_loss="100"; avg_rtt="N/A"; avg_jitter="N/A"; target_status="DOWN"; log_message "Ping to $host FAILED."; fi; ping_targets_results+=("$(jq -cn --arg host "$host" --arg status "$target_status" --arg rtt "$avg_rtt" --arg loss "$packet_loss" --arg jitter "$avg_jitter" '{host: $host, status: $status, avg_rtt_ms: $rtt, packet_loss_percent: $loss, avg_jitter_ms: $jitter}')"); done
results[ping_targets]="$(IFS=,; echo "[${ping_targets_results[*]}]")"; overall_connectivity_status="DOWN"; avg_overall_rtt="N/A"; avg_overall_loss="N/A"; avg_overall_jitter="N/A"; if [ "$ping_targets_up" -gt 0 ]; then overall_connectivity_status="UP"; avg_overall_rtt=$(awk "BEGIN {printf \"%.2f\", $total_rtt_sum / $ping_targets_up}"); avg_overall_jitter=$(awk "BEGIN {printf \"%.2f\", $total_jitter_sum / $ping_targets_up}"); avg_overall_loss=$(awk "BEGIN {printf \"%.1f\", $total_loss_sum / ${#PING_HOSTS[@]}}"); fi; results[ping_summary]="$(jq -cn --arg status "$overall_connectivity_status" --arg rtt "$avg_overall_rtt" --arg loss "$avg_overall_loss" --arg jitter "$avg_overall_jitter" '{status: $status, average_rtt_ms: $rtt, average_packet_loss_percent: $loss, average_jitter_ms: $jitter}')"; log_message "Ping tests complete."

# --- DNS RESOLUTION TEST ---
log_message "Performing DNS resolution test (Source IP: ${SOURCE_IP_ARG_FOR_DIG:-system_default})..."; dns_status="FAILED"; dns_resolve_time_ms="N/A"; if command -v dig &> /dev/null; then dig_target_host="$DNS_CHECK_HOST"; dig_actual_args="+short +time=2 +tries=1 ${SOURCE_IP_ARG_FOR_DIG}"; if [ -n "$DNS_SERVER_TO_QUERY" ]; then dig_actual_args="$dig_actual_args @${DNS_SERVER_TO_QUERY}"; fi; start_time_dns=$(date +%s.%N); dns_output=$(dig $dig_actual_args "$dig_target_host" 2>&1); dig_exit_code=$?; end_time_dns=$(date +%s.%N); if [ $dig_exit_code -eq 0 ] && [ -n "$dns_output" ] && ! [[ "$dns_output" == *";; connection timed out"* || "$dns_output" == *"couldn't get address"* || "$dns_output" == *"communications error"* ]]; then dns_status="OK"; dns_resolve_time_ms=$(awk "BEGIN {printf \"%.0f\", ($end_time_dns - $start_time_dns) * 1000}"); else dns_status="FAILED"; log_message "DNS resolution FAILED. dig exit: $dig_exit_code. Output: $(echo "$dns_output" | tr -d '\n')"; fi; else dns_status="SKIPPED_NO_DIG"; fi; results[dns_resolution]="$(jq -cn --arg host "$DNS_CHECK_HOST" --arg status "$dns_status" --arg time "$dns_resolve_time_ms" '{host_tested: $host, status: $status, resolve_time_ms: $time}')"; log_message "DNS test complete."

# --- HTTP CHECK ---
log_message "Performing HTTP check (Interface: ${NETWORK_INTERFACE_TO_MONITOR:-default})..."; http_status="FAILED"; http_response_code="N/A"; http_total_time_s="N/A"; if command -v curl &> /dev/null; then curl_output_stats=$(curl ${INTERFACE_ARG} -L -s -o /dev/null -w "http_code=%{http_code}\ntime_total=%{time_total}\nerrormsg=%{errormsg}" --max-time "$HTTP_TIMEOUT" --connect-timeout 5 "$HTTP_CHECK_URL" 2>&1); curl_exit_code=$?; http_response_code=$(echo "$curl_output_stats" | grep "http_code=" | cut -d'=' -f2); http_total_time_s=$(echo "$curl_output_stats" | grep "time_total=" | cut -d'=' -f2 | sed 's/,/./'); curl_errormsg=$(echo "$curl_output_stats" | grep "errormsg=" | cut -d'=' -f2-); if [ "$curl_exit_code" -eq 0 ] && [[ "$http_response_code" -ge 200 && "$http_response_code" -lt 400 ]]; then http_status="OK"; elif [ "$curl_exit_code" -eq 0 ]; then http_status="ERROR_CODE"; log_message "HTTP check got status $http_response_code."; else http_status="FAILED_REQUEST"; log_message "HTTP check FAILED. Curl exit: $curl_exit_code. Error: $curl_errormsg"; fi; else http_status="SKIPPED_NO_CURL"; fi; results[http_check]="$(jq -cn --arg url "$HTTP_CHECK_URL" --arg status "$http_status" --arg code "$http_response_code" --arg time "$http_total_time_s" '{url_tested: $url, status: $status, response_code: $code, total_time_s: $time}')"; log_message "HTTP check complete."

# --- SPEEDTEST ---
st_dl="N/A"; st_ul="N/A"; st_ping="N/A"; st_jitter="N/A"; st_server_name="N/A"; st_status="SKIPPED_INTERNAL"; st_error_msg=""; speedtest_data_json='{"status":"SKIPPED_INTERNAL", "download_mbps":"N/A", "upload_mbps":"N/A", "ping_ms":"N/A", "jitter_ms":"N/A", "server_name":"N/A", "error_message":""}'; if [ "$ENABLE_SPEEDTEST" = true ]; then if [ -n "$SPEEDTEST_COMMAND_PATH" ]; then log_message "Performing speedtest with '$SPEEDTEST_COMMAND_PATH $SPEEDTEST_FULL_ARGS'..."; SPEEDTEST_TEMP_FILE=$(mktemp); SPEEDTEST_ERR_FILE="${SPEEDTEST_TEMP_FILE}.err"; timeout_duration="120s"; if timeout "$timeout_duration" $SPEEDTEST_COMMAND_PATH $SPEEDTEST_FULL_ARGS > "$SPEEDTEST_TEMP_FILE" 2> "$SPEEDTEST_ERR_FILE"; then speedtest_json_output_raw=$(cat "$SPEEDTEST_TEMP_FILE"); if echo "$speedtest_json_output_raw" | jq -e . > /dev/null 2>&1; then if echo "$speedtest_json_output_raw" | jq -e '.download.bandwidth and .upload.bandwidth and .ping.latency' > /dev/null 2>&1; then log_message "Parsing speedtest output as Ookla JSON format."; dl_bytes_per_sec=$(echo "$speedtest_json_output_raw" | jq -r '.download.bandwidth // 0'); ul_bytes_per_sec=$(echo "$speedtest_json_output_raw" | jq -r '.upload.bandwidth // 0'); st_dl=$(awk "BEGIN {printf \"%.2f\", $dl_bytes_per_sec * 0.000008}" 2>/dev/null || echo "N/A"); st_ul=$(awk "BEGIN {printf \"%.2f\", $ul_bytes_per_sec * 0.000008}" 2>/dev/null || echo "N/A"); st_ping_raw=$(echo "$speedtest_json_output_raw" | jq -r '.ping.latency // "N/A"'); st_ping=$(awk "BEGIN {printf \"%.2f\", $st_ping_raw}" 2>/dev/null || echo "N/A"); st_jitter_raw=$(echo "$speedtest_json_output_raw" | jq -r '.ping.jitter // "N/A"'); st_jitter=$(awk "BEGIN {printf \"%.2f\", $st_jitter_raw}" 2>/dev/null || echo "N/A"); st_server_name=$(echo "$speedtest_json_output_raw" | jq -r '.server.name // .server.host // "N/A"'); st_status="COMPLETED"; st_error_msg=""; elif echo "$speedtest_json_output_raw" | jq -e '.download and .upload and .ping' > /dev/null 2>&1; then log_message "Parsing speedtest output as community speedtest-cli JSON format."; st_dl_bps=$(echo "$speedtest_json_output_raw" | jq -r '.download // 0'); st_ul_bps=$(echo "$speedtest_json_output_raw" | jq -r '.upload // 0'); st_dl=$(awk "BEGIN {printf \"%.2f\", $st_dl_bps / 1000000}" 2>/dev/null || echo "N/A"); st_ul=$(awk "BEGIN {printf \"%.2f\", $st_ul_bps / 1000000}" 2>/dev/null || echo "N/A"); st_ping_raw=$(echo "$speedtest_json_output_raw" | jq -r '.ping // "N/A"'); st_ping=$(awk "BEGIN {printf \"%.2f\", $st_ping_raw}" 2>/dev/null || echo "N/A"); st_jitter="N/A"; st_server_name=$(echo "$speedtest_json_output_raw" | jq -r '.server.name // .server.host // "N/A"'); st_status="COMPLETED"; st_error_msg=""; else st_status="FAILED_PARSE_ATTEMPT"; st_error_msg="Speedtest JSON structure not recognized. Output: $(echo "$speedtest_json_output_raw" | tr -dc '[:print:]\t\n\r' | head -c 100)"; log_message "$st_error_msg"; st_dl="N/A"; st_ul="N/A"; st_ping="N/A"; st_jitter="N/A";fi; speedtest_data_json=$(jq -cn --arg status "$st_status" --arg dl "$st_dl" --arg ul "$st_ul" --arg png "$st_ping" --arg jit "$st_jitter" --arg server "$st_server_name" --arg error "$st_error_msg" '{status: $status, download_mbps: $dl, upload_mbps: $ul, ping_ms: $png, jitter_ms: $jit, server_name: $server, error_message: $error}'); if [ "$st_status" == "COMPLETED" ]; then log_message "Speedtest complete. DL: $st_dl Mbps, UL: $st_ul Mbps, Ping: $st_ping ms, Jitter: $st_jitter ms."; fi; else st_error_msg="Speedtest produced non-JSON output: $(cat "$SPEEDTEST_TEMP_FILE" | tr -dc '[:print:]\t\n\r' | head -c 200)... Error stream: $(cat "$SPEEDTEST_ERR_FILE" | tr -dc '[:print:]\t\n\r' | head -c 100)"; st_status="FAILED_JSON_VALIDATION"; log_message "Speedtest FAILED (invalid JSON): $st_error_msg"; speedtest_data_json=$(jq -cn --arg status "$st_status" --arg error "$st_error_msg" '{status: $status, download_mbps:"N/A", upload_mbps:"N/A", ping_ms:"N/A", jitter_ms:"N/A", server_name:"N/A", error_message: $error}'); fi; else st_exit_code=$?; st_error_msg="Speedtest cmd failed (exit $st_exit_code) or timed out. Stderr: $(cat "$SPEEDTEST_ERR_FILE" | tr -dc '[:print:]\t\n\r' | head -c 200)"; st_status="FAILED_EXEC"; log_message "Speedtest FAILED (exec): $st_error_msg"; speedtest_data_json=$(jq -cn --arg status "$st_status" --arg error "$st_error_msg" '{status: $status, download_mbps:"N/A", upload_mbps:"N/A", ping_ms:"N/A", jitter_ms:"N/A", server_name:"N/A", error_message: $error}'); fi; rm -f "$SPEEDTEST_TEMP_FILE" "$SPEEDTEST_ERR_FILE"; else log_message "Speedtest command path not set."; st_status="SKIPPED_NO_CMD"; st_error_msg="No speedtest command configured/found."; speedtest_data_json=$(jq -cn --arg status "$st_status" --arg error "$st_error_msg" '{status: $status, download_mbps:"N/A", upload_mbps:"N/A", ping_ms:"N/A", jitter_ms:"N/A", server_name:"N/A", error_message: $error}'); fi; else log_message "Speedtest disabled."; st_status="DISABLED"; speedtest_data_json=$(jq -cn --arg status "$st_status" --arg jit "N/A" '{status: $status, download_mbps:"N/A", upload_mbps:"N/A", ping_ms:"N/A", jitter_ms: $jit, server_name:"N/A", error_message:""}'); fi
results[speed_test]="$speedtest_data_json"; st_dl=$(echo "$speedtest_data_json" | jq -r .download_mbps); st_ul=$(echo "$speedtest_data_json" | jq -r .upload_mbps); st_ping=$(echo "$speedtest_data_json" | jq -r .ping_ms); st_jitter=$(echo "$speedtest_data_json" | jq -r .jitter_ms); st_server_name=$(echo "$speedtest_data_json" | jq -r .server_name); st_status=$(echo "$speedtest_data_json" | jq -r .status)

# --- DETAILED HEALTH SUMMARY ---
health_summary="UNKNOWN"; if [ "$overall_connectivity_status" == "DOWN" ]; then health_summary="CONNECTIVITY_DOWN"; elif { [ "$dns_status" != "OK" ] && [ "$dns_status" != "SKIPPED_NO_DIG" ]; } || { [ "$http_status" != "OK" ] && [ "$http_status" != "ERROR_CODE" ] && [ "$http_status" != "SKIPPED_NO_CURL" ]; }; then health_summary="CRITICAL_SERVICE_FAILURE"; else rtt_val=$(echo "$avg_overall_rtt" | awk '{if ($1 ~ /^[0-9.]+$/ && $1 != "N/A") print $1; else print 9999}'); loss_val=$(echo "$avg_overall_loss" | awk '{if ($1 ~ /^[0-9.]+$/ && $1 != "N/A") print $1; else print 100}'); ping_jitter_val=$(echo "$avg_overall_jitter" | awk '{if ($1 ~ /^[0-9.]+$/ && $1 != "N/A") print $1; else print 999}'); dns_time_val=$(echo "$dns_resolve_time_ms" | awk '{if ($1 ~ /^[0-9.]+$/ && $1 != "N/A") print $1; else print 99999}'); http_time_val=$(echo "$http_total_time_s" | awk '{if ($1 ~ /^[0-9.]+$/ && $1 != "N/A") print $1; else print 999}'); st_dl_val_num=$(echo "$st_dl" | awk '{if ($1 ~ /^[0-9.]+$/ && $1 != "N/A") print $1; else print 0}'); st_ul_val_num=$(echo "$st_ul" | awk '{if ($1 ~ /^[0-9.]+$/ && $1 != "N/A") print $1; else print 0}'); is_poor=false; is_degraded=false; if (( $(echo "$rtt_val > $RTT_THRESHOLD_POOR" | bc -l) )) || (( $(echo "$loss_val > $LOSS_THRESHOLD_POOR" | bc -l) )) || (( $(echo "$ping_jitter_val > $PING_JITTER_THRESHOLD_POOR" | bc -l) )) || (( $(echo "$dns_time_val > $DNS_TIME_THRESHOLD_POOR" | bc -l) )) || (( $(echo "$http_time_val > $HTTP_TIME_THRESHOLD_POOR" | bc -l) )); then is_poor=true; fi; if [ "$ENABLE_SPEEDTEST" = true ] && [ "$st_status" == "COMPLETED" ]; then if (( $(echo "$st_dl_val_num < $SPEEDTEST_DL_THRESHOLD_POOR" | bc -l) )) || (( $(echo "$st_ul_val_num < $SPEEDTEST_UL_THRESHOLD_POOR" | bc -l) )); then is_poor=true; fi; fi; if [ "$is_poor" = false ]; then if (( $(echo "$rtt_val > $RTT_THRESHOLD_DEGRADED" | bc -l) )) || (( $(echo "$loss_val > $LOSS_THRESHOLD_DEGRADED" | bc -l) )) || (( $(echo "$ping_jitter_val > $PING_JITTER_THRESHOLD_DEGRADED" | bc -l) )) || (( $(echo "$dns_time_val > $DNS_TIME_THRESHOLD_DEGRADED" | bc -l) )) || (( $(echo "$http_time_val > $HTTP_TIME_THRESHOLD_DEGRADED" | bc -l) )); then is_degraded=true; fi; if [ "$ENABLE_SPEEDTEST" = true ] && [ "$st_status" == "COMPLETED" ]; then if (( $(echo "$st_dl_val_num < $SPEEDTEST_DL_THRESHOLD_DEGRADED" | bc -l) )) || (( $(echo "$st_ul_val_num < $SPEEDTEST_UL_THRESHOLD_DEGRADED" | bc -l) )); then is_degraded=true; fi; fi; fi; if [ "$is_poor" = true ]; then health_summary="POOR_PERFORMANCE"; elif [ "$is_degraded" = true ]; then health_summary="DEGRADED_PERFORMANCE"; else health_summary="GOOD_PERFORMANCE"; fi; fi
results[detailed_health_summary]="\"$health_summary\""; log_message "Health Summary: $health_summary"; current_sla_met_interval=0; if [ "$health_summary" == "GOOD_PERFORMANCE" ]; then current_sla_met_interval=1; fi; results[current_sla_met_status]="\"$(if [ $current_sla_met_interval -eq 1 ]; then echo "MET"; else echo "NOT_MET"; fi)\""

# --- Construct Final JSON to be sent ---
final_json_parts=(); final_json_parts+=("\"timestamp\":\"$LOG_DATE\""); final_json_parts+=("\"overall_connectivity_status\":\"$overall_connectivity_status\"")
results[agent_hostname]="\"$AGENT_HOSTNAME_LOCAL\""; results[agent_source_ip]="\"${AGENT_SOURCE_IP:-unknown}\""; results[agent_type]="\"${AGENT_TYPE}\""
# isp_profile_name is more relevant for display on central, not sent by agent unless it's just its own agent_identifier
# results[isp_profile_name]="\"${ISP_NAME:-$AGENT_IDENTIFIER}\"" # This ISP_NAME was from central fetch, might not be available

for key in "${!results[@]}"; do final_json_parts+=("\"$key\":${results[$key]}"); done
final_json="{$(IFS=,; echo "${final_json_parts[*]}")}"
if ! echo "$final_json" | jq . > /dev/null; then log_message "Error: Generated JSON for API is invalid."; final_json="{\"timestamp\":\"$LOG_DATE\", \"agent_identifier\":\"$AGENT_IDENTIFIER\", \"error\":\"Agent failed to generate valid JSON.\"}" ; fi

payload_to_send=$(echo "$final_json" | jq --arg agent_id_val "$AGENT_IDENTIFIER" --argjson isp_id_val "${ISP_PROFILE_ID_FROM_CENTRAL:-0}" '. + {agent_identifier: $agent_id_val, isp_profile_id: $isp_id_val }')


log_message "Submitting data to central API: $CENTRAL_API_URL for agent $AGENT_IDENTIFIER"
curl_headers_submit=("-H" "Content-Type: application/json")
if [ -n "$CENTRAL_API_KEY" ]; then curl_headers_submit+=("-H" "X-API-Key: $CENTRAL_API_KEY"); fi
api_response_file=$(mktemp); api_http_code=$(curl --silent --show-error --fail "${curl_headers_submit[@]}" -X POST -d "$payload_to_send" "$CENTRAL_API_URL" --output "$api_response_file" --write-out "%{http_code}"); api_curl_exit_code=$?; api_response_body=$(cat "$api_response_file"); rm -f "$api_response_file"
if [ "$api_curl_exit_code" -eq 0 ] && [ "$api_http_code" -eq 200 ]; then log_message "Data successfully submitted. Response: $api_response_body"; else log_message "ERROR: Failed to submit data to central API. Curl exit: $api_curl_exit_code, HTTP code: $api_http_code. Response: $api_response_body"; fi

log_message "Agent monitor script finished."
exit 0