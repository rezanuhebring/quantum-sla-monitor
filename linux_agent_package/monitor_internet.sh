#!/bin/bash
# Agent Version: Fetches profile from central (optional), sends data to central.

# --- Agent Default Configurations (can be overridden by agent_config.env) ---
DEFAULT_AGENT_IDENTIFIER="linux_agent_$(hostname -s)_$(date +%s%N | sha256sum | head -c 8)"
DEFAULT_AGENT_TYPE="ISP"
DEFAULT_CENTRAL_API_URL="http://YOUR_CENTRAL_SERVER_IP/api/submit_metrics.php"
# (All other DEFAULT_... variables are fine)

# --- Source the local agent configuration file ---
AGENT_CONFIG_FILE="/opt/sla_monitor/agent_config.env"
LOG_FILE="/var/log/internet_sla_monitor_agent.log"

if [ -f "$AGENT_CONFIG_FILE" ]; then
    set -a; source "$AGENT_CONFIG_FILE"; set +a
fi
# (All variable initializations with :- are fine)
AGENT_IDENTIFIER="${AGENT_IDENTIFIER:-$DEFAULT_AGENT_IDENTIFIER}"
CENTRAL_API_URL="${CENTRAL_API_URL:-$DEFAULT_CENTRAL_API_URL}"
# ... etc ...

log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z'): [$AGENT_IDENTIFIER] $1" >> "$LOG_FILE"; }

log_message "Starting SLA Monitor Agent Script. Type: $AGENT_TYPE"
# (Dependency checks are fine)

# --- FIX #2: Initialize profile ID as a valid number ---
ISP_PROFILE_ID_FROM_CENTRAL=0

# --- FIX #1: Correctly construct the profile config URL ---
CENTRAL_PROFILE_CONFIG_URL="${CENTRAL_API_URL/submit_metrics.php/get_profile_config.php}?agent_id=${AGENT_IDENTIFIER}"

log_message "Attempting to fetch profile from: $CENTRAL_PROFILE_CONFIG_URL"
_profile_json_from_central=$(curl -s -G "$CENTRAL_PROFILE_CONFIG_URL")

if [ -n "$_profile_json_from_central" ] && echo "$_profile_json_from_central" | jq -e . > /dev/null 2>&1; then
    log_message "Successfully fetched profile config from central server."
    # The logic for overriding local thresholds with fetched ones is fine.
    ISP_PROFILE_ID_FROM_CENTRAL=$(echo "$_profile_json_from_central" | jq -r '.id // 0')
    # ... etc for other thresholds ...
else
    log_message "WARN: Failed to fetch/parse profile config from central. Using local/default thresholds. Response: $_profile_json_from_central"
fi

LOG_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
AGENT_SOURCE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null || hostname -I | awk '{print $1}')
AGENT_HOSTNAME_LOCAL=$(hostname -s)

# --- The rest of your monitoring logic (Ping, DNS, HTTP, Speedtest) is very complex but looks okay. ---
# The key is how the results are stored. We'll store them in shell variables
# instead of trying to build a JSON string manually.

# --- (Example: Ping Test section - modified to store in variables) ---
# ... after your ping loop ...
ping_status="$overall_connectivity_status"
ping_rtt="$avg_overall_rtt"
ping_loss="$avg_overall_loss"
ping_jitter="$avg_overall_jitter"

# --- (Example: DNS Test section - modified) ---
# ... after your DNS check ...
dns_status_result="$dns_status"
dns_time_result="$dns_resolve_time_ms"

# --- (Do this for all your tests: http, speedtest, health_summary) ---
# ...

# --- BEST PRACTICE FIX: Construct Final JSON with jq ---
# This replaces the entire manual "final_json_parts" loop.
# It's much safer and easier to read.

# Step 1: Gather all results into jq --arg or --argjson calls.
# Use --arg for strings, --argjson for numbers, booleans, or null.
payload_to_send=$(jq -n \
    --arg     timestamp                  "$LOG_DATE" \
    --arg     agent_identifier           "$AGENT_IDENTIFIER" \
    --arg     agent_type                 "$AGENT_TYPE" \
    --arg     agent_hostname             "$AGENT_HOSTNAME_LOCAL" \
    --arg     agent_source_ip            "${AGENT_SOURCE_IP:-unknown}" \
    --argjson isp_profile_id             "${ISP_PROFILE_ID_FROM_CENTRAL:-0}" \
    \
    --argjson ping_summary               "$(jq -cn --arg status "$ping_status" --arg rtt "$ping_rtt" --arg loss "$ping_loss" --arg jitter "$ping_jitter" '{status: $status, average_rtt_ms: ($rtt | tonumber? // null), average_packet_loss_percent: ($loss | tonumber? // null), average_jitter_ms: ($jitter | tonumber? // null)}')" \
    \
    --argjson dns_resolution             "$(jq -cn --arg host "$DNS_CHECK_HOST" --arg status "$dns_status_result" --arg time "$dns_time_result" '{host_tested: $host, status: $status, resolve_time_ms: ($time | tonumber? // null)}')" \
    \
    --argjson http_check                 "$(jq -cn --arg url "$HTTP_CHECK_URL" --arg status "$http_status" --arg code "$http_response_code" --arg time "$http_total_time_s" '{url_tested: $url, status: $status, response_code: ($code | tonumber? // null), total_time_s: ($time | tonumber? // null)}')" \
    \
    --argjson speed_test                 "$speedtest_data_json" \
    \
    --arg     detailed_health_summary    "$health_summary" \
    --arg     current_sla_met_status     "$(if [ "$health_summary" == "GOOD_PERFORMANCE" ]; then echo "MET"; else echo "NOT_MET"; fi)" \
    \
    '$ARGS.named'
)

# Validate the final JSON before sending
if ! echo "$payload_to_send" | jq . > /dev/null; then
    log_message "FATAL: Agent failed to generate valid final JSON. Aborting submission."
    exit 1
fi

log_message "Submitting data to central API: $CENTRAL_API_URL"
# The submission part of your script is solid and can remain the same.
api_response_file=$(mktemp)
# ... rest of your curl submission logic ...