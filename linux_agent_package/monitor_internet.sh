#!/bin/bash
# SLA Monitor Agent Script
# Fetches profile from central server (optional), runs tests, and submits metrics.

# --- Source the local agent configuration file ---
AGENT_CONFIG_FILE="/opt/sla_monitor/agent_config.env"
LOG_FILE="/var/log/internet_sla_monitor_agent.log"

# Load default values first, then override with config file if it exists.
if [ -f "$AGENT_CONFIG_FILE" ]; then
    set -a; source "$AGENT_CONFIG_FILE"; set +a
fi

# --- Agent Default Configurations (used if not set in agent_config.env) ---
AGENT_IDENTIFIER="${AGENT_IDENTIFIER:-linux_agent_$(hostname -s)_$(date +%s%N | sha256sum | head -c 8)}"
AGENT_TYPE="${AGENT_TYPE:-ISP}"
CENTRAL_API_URL="${CENTRAL_API_URL:-}"
CENTRAL_API_KEY="${CENTRAL_API_KEY:-}"
PING_HOSTS=("${PING_HOSTS[@]:-8.8.8.8 1.1.1.1 google.com}")
PING_COUNT=${PING_COUNT:-10}
PING_TIMEOUT=${PING_TIMEOUT:-5}
DNS_CHECK_HOST="${DNS_CHECK_HOST:-www.google.com}"
DNS_SERVER_TO_QUERY="${DNS_SERVER_TO_QUERY:-}"
HTTP_CHECK_URL="${HTTP_CHECK_URL:-https://www.google.com}"
HTTP_TIMEOUT=${HTTP_TIMEOUT:-10}
ENABLE_PING=${ENABLE_PING:-true}
ENABLE_DNS=${ENABLE_DNS:-true}
ENABLE_HTTP=${ENABLE_HTTP:-true}
ENABLE_SPEEDTEST=${ENABLE_SPEEDTEST:-true}
NETWORK_INTERFACE_TO_MONITOR="${NETWORK_INTERFACE_TO_MONITOR:-}"

# --- Helper Functions ---
log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z'): [$AGENT_IDENTIFIER] $1" >> "$LOG_FILE"; }

# --- Initial Setup ---
log_message "Starting SLA Monitor Agent Script. Type: $AGENT_TYPE"

if [ -z "$CENTRAL_API_URL" ] || [[ "$CENTRAL_API_URL" == *"YOUR_CENTRAL_SERVER_IP"* ]]; then
    log_message "FATAL: CENTRAL_API_URL is not configured in ${AGENT_CONFIG_FILE}. Exiting."
    exit 1
fi
if [[ "$AGENT_IDENTIFIER" == *"UNIQUE_AGENT_ID"* ]]; then
    log_message "FATAL: AGENT_IDENTIFIER is not configured in ${AGENT_CONFIG_FILE}. Exiting."
    exit 1
fi

# Auto-detect the best available speedtest command and its arguments
SPEEDTEST_COMMAND_PATH=""; SPEEDTEST_ARGS=""
if command -v speedtest &>/dev/null; then
    SPEEDTEST_COMMAND_PATH=$(command -v speedtest)
    SPEEDTEST_ARGS="--format=json --accept-license --accept-gdpr"
elif command -v speedtest-cli &>/dev/null; then
    SPEEDTEST_COMMAND_PATH=$(command -v speedtest-cli)
    SPEEDTEST_ARGS="--json --accept-license --accept-gdpr"
fi

# --- Main Logic ---
LOG_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
AGENT_SOURCE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null || hostname -I | awk '{print $1}')
AGENT_HOSTNAME_LOCAL=$(hostname -s)
declare -A results_map

# --- PING TESTS ---
if [ "$ENABLE_PING" = true ]; then
    log_message "Performing ping tests..."
    ping_interface_arg=""; if [ -n "$NETWORK_INTERFACE_TO_MONITOR" ]; then ping_interface_arg="-I $NETWORK_INTERFACE_TO_MONITOR"; fi
    
    total_rtt_sum=0.0; total_loss_sum=0; total_jitter_sum=0.0; ping_targets_up=0
    for host in "${PING_HOSTS[@]}"; do
        ping_output=$(ping ${ping_interface_arg} -c "$PING_COUNT" -W "$PING_TIMEOUT" -q "$host" 2>&1)
        if [ $? -eq 0 ]; then
            packet_loss=$(echo "$ping_output" | grep -oP '\d+(?=% packet loss)')
            rtt_line=$(echo "$ping_output" | grep 'rtt min/avg/max/mdev')
            avg_rtt=$(echo "$rtt_line" | cut -d'=' -f2 | cut -d'/' -f2)
            avg_jitter=$(echo "$rtt_line" | cut -d'=' -f2 | cut -d'/' -f4 | sed 's/\s*ms//')
            
            ((ping_targets_up++))
            total_rtt_sum=$(awk "BEGIN {print $total_rtt_sum + $avg_rtt}")
            if [[ "$avg_jitter" =~ ^[0-9.]+$ ]]; then total_jitter_sum=$(awk "BEGIN {print $total_jitter_sum + $avg_jitter}"); fi
            total_loss_sum=$((total_loss_sum + packet_loss))
        fi
    done
    
    if [ "$ping_targets_up" -gt 0 ]; then
        results_map[ping_status]="UP"
        results_map[ping_rtt]=$(awk "BEGIN {printf \"%.2f\", $total_rtt_sum / $ping_targets_up}")
        results_map[ping_jitter]=$(awk "BEGIN {printf \"%.2f\", $total_jitter_sum / $ping_targets_up}")
        results_map[ping_loss]=$(awk "BEGIN {printf \"%.1f\", $total_loss_sum / ${#PING_HOSTS[@]}}")
    else
        results_map[ping_status]="DOWN"
    fi
fi

# --- DNS RESOLUTION TEST ---
if [ "$ENABLE_DNS" = true ]; then
    log_message "Performing DNS resolution test..."
    source_ip_arg_for_dig=""; if [ -n "$NETWORK_INTERFACE_TO_MONITOR" ]; then _source_ip_agent=$(ip -4 addr show "$NETWORK_INTERFACE_TO_MONITOR" | grep -oP 'inet \K[\d.]+'); if [ -n "$_source_ip_agent" ]; then source_ip_arg_for_dig="+source=$_source_ip_agent"; fi; fi
    dig_server_arg=""; if [ -n "$DNS_SERVER_TO_QUERY" ]; then dig_server_arg="@${DNS_SERVER_TO_QUERY}"; fi
    
    start_time_dns=$(date +%s.%N)
    dns_output=$(dig +short +time=2 +tries=1 $source_ip_arg_for_dig $dig_server_arg "$DNS_CHECK_HOST" 2>&1)
    if [ $? -eq 0 ] && [ -n "$dns_output" ]; then
        end_time_dns=$(date +%s.%N)
        results_map[dns_status]="OK"
        results_map[dns_time]=$(awk "BEGIN {printf \"%.0f\", ($end_time_dns - $start_time_dns) * 1000}")
    else
        results_map[dns_status]="FAILED"
    fi
fi

# --- HTTP CHECK ---
if [ "$ENABLE_HTTP" = true ]; then
    log_message "Performing HTTP check..."
    interface_arg=""; if [ -n "$NETWORK_INTERFACE_TO_MONITOR" ]; then interface_arg="--interface $NETWORK_INTERFACE_TO_MONITOR"; fi
    
    curl_output_stats=$(curl ${interface_arg} -L -s -o /dev/null -w "http_code=%{http_code}\ntime_total=%{time_total}" --max-time "$HTTP_TIMEOUT" "$HTTP_CHECK_URL")
    if [ $? -eq 0 ]; then
        results_map[http_code]=$(echo "$curl_output_stats" | grep "http_code" | cut -d'=' -f2)
        results_map[http_time]=$(echo "$curl_output_stats" | grep "time_total" | cut -d'=' -f2 | sed 's/,/./')
        if [[ "${results_map[http_code]}" -ge 200 && "${results_map[http_code]}" -lt 400 ]]; then
            results_map[http_status]="OK"
        else
            results_map[http_status]="ERROR_CODE"
        fi
    else
        results_map[http_status]="FAILED_REQUEST"
    fi
fi

# --- SPEEDTEST ---
if [ "$ENABLE_SPEEDTEST" = true ] && [ -n "$SPEEDTEST_COMMAND_PATH" ]; then
    log_message "Performing speedtest with '$SPEEDTEST_COMMAND_PATH'..."
    speedtest_interface_arg=""; if [ -n "$NETWORK_INTERFACE_TO_MONITOR" ]; then if [[ "$SPEEDTEST_COMMAND_PATH" == *"speedtest-cli"* ]]; then speedtest_interface_arg="--source $_source_ip_agent"; else speedtest_interface_arg="--interface $NETWORK_INTERFACE_TO_MONITOR"; fi; fi
    
    speedtest_json_output=$(timeout 120s $SPEEDTEST_COMMAND_PATH $SPEEDTEST_ARGS $speedtest_interface_arg)
    if [ $? -eq 0 ] && echo "$speedtest_json_output" | jq -e . > /dev/null 2>&1; then
        if [[ "$SPEEDTEST_COMMAND_PATH" == *"speedtest-cli"* ]]; then # Community speedtest-cli
            st_dl_bps=$(echo "$speedtest_json_output" | jq -r '.download // 0');
            st_ul_bps=$(echo "$speedtest_json_output" | jq -r '.upload // 0');
            results_map[st_dl]=$(awk "BEGIN {printf \"%.2f\", $st_dl_bps / 1000000}")
            results_map[st_ul]=$(awk "BEGIN {printf \"%.2f\", $st_ul_bps / 1000000}")
            results_map[st_ping]=$(echo "$speedtest_json_output" | jq -r '.ping // "null"')
            results_map[st_jitter]="null"
        else # Ookla speedtest
            dl_bytes_per_sec=$(echo "$speedtest_json_output" | jq -r '.download.bandwidth // 0')
            ul_bytes_per_sec=$(echo "$speedtest_json_output" | jq -r '.upload.bandwidth // 0')
            results_map[st_dl]=$(awk "BEGIN {printf \"%.2f\", $dl_bytes_per_sec * 8 / 1000000}")
            results_map[st_ul]=$(awk "BEGIN {printf \"%.2f\", $ul_bytes_per_sec * 8 / 1000000}")
            results_map[st_ping]=$(echo "$speedtest_json_output" | jq -r '.ping.latency // "null"')
            results_map[st_jitter]=$(echo "$speedtest_json_output" | jq -r '.ping.jitter // "null"')
        fi
        results_map[st_status]="COMPLETED"
    else
        results_map[st_status]="FAILED"
    fi
fi

# --- Construct Final JSON Payload ---
log_message "Constructing final JSON payload..."
payload=$(jq -n \
    --arg     timestamp             "$LOG_DATE" \
    --arg     agent_identifier      "$AGENT_IDENTIFIER" \
    --arg     agent_type            "$AGENT_TYPE" \
    --arg     agent_hostname        "$AGENT_HOSTNAME_LOCAL" \
    --arg     agent_source_ip       "$AGENT_SOURCE_IP" \
    --argjson ping_summary          "$(jq -n --arg status "${results_map[ping_status]:-N/A}" --argjson rtt "${results_map[ping_rtt]:-null}" --argjson loss "${results_map[ping_loss]:-null}" --argjson jitter "${results_map[ping_jitter]:-null}" '{status: $status, average_rtt_ms: $rtt, average_packet_loss_percent: $loss, average_jitter_ms: $jitter}')" \
    --argjson dns_resolution        "$(jq -n --arg status "${results_map[dns_status]:-N/A}" --argjson time "${results_map[dns_time]:-null}" '{status: $status, resolve_time_ms: $time}')" \
    --argjson http_check            "$(jq -n --arg status "${results_map[http_status]:-N/A}" --argjson code "${results_map[http_code]:-null}" --argjson time "${results_map[http_time]:-null}" '{status: $status, response_code: $code, total_time_s: $time}')" \
    --argjson speed_test            "$(jq -n --arg status "${results_map[st_status]:-SKIPPED}" --argjson dl "${results_map[st_dl]:-null}" --argjson ul "${results_map[st_ul]:-null}" --argjson ping "${results_map[st_ping]:-null}" --argjson jitter "${results_map[st_jitter]:-null}" '{status: $status, download_mbps: $dl, upload_mbps: $ul, ping_ms: $ping, jitter_ms: $jitter}')" \
    '$ARGS.named'
)

# Validate payload
if ! echo "$payload" | jq . > /dev/null; then
    log_message "FATAL: Agent failed to generate valid final JSON. Aborting submission."
    exit 1
fi

# --- Submit Data to Central API ---
log_message "Submitting data to central API: $CENTRAL_API_URL"
curl_headers=("-H" "Content-Type: application/json")
if [ -n "$CENTRAL_API_KEY" ]; then curl_headers+=("-H" "X-API-Key: $CENTRAL_API_KEY"); fi

api_response_file=$(mktemp)
api_http_code=$(curl --silent --show-error --fail "${curl_headers[@]}" -X POST -d "$payload" "$CENTRAL_API_URL" --output "$api_response_file" --write-out "%{http_code}")
api_curl_exit_code=$?
api_response_body=$(cat "$api_response_file")
rm -f "$api_response_file"

if [ "$api_curl_exit_code" -eq 0 ]; then
    log_message "Data successfully submitted. HTTP code: $api_http_code. Response: $api_response_body"
else
    log_message "ERROR: Failed to submit data to central API. Curl exit: $api_curl_exit_code, HTTP code: $api_http_code. Response: $api_response_body"
fi

log_message "Agent monitor script finished."
exit 0