#!/bin/bash

# --- Configuration FOR CENTRAL SERVER ---
SLA_CONFIG_NAME="sla_config.env" 
PHP_API_SUBMIT_NAME="submit_metrics.php"
PHP_API_GET_PROFILE_CONFIG_NAME="get_profile_config.php"
PHP_SLA_STATS_NAME="get_sla_stats.php"
INDEX_HTML_NAME="index.html"
MONITOR_SCRIPT_DIR="/opt/sla_monitor"; CONFIG_FILE_PATH="${MONITOR_SCRIPT_DIR}/${SLA_CONFIG_NAME}"; CENTRAL_DB_FILE="${MONITOR_SCRIPT_DIR}/central_sla_data.sqlite"; SQLITE_DB_OWNER="root"; SQLITE_DB_GROUP_PHP_READ="www-data"; API_LOG_FILE="/var/log/sla_api.log"
WEB_DIR_NAME="sla_status"; WEB_ROOT_DIR="/var/www/html"; WEB_APP_DIR="${WEB_ROOT_DIR}/${WEB_DIR_NAME}"; WEB_API_DIR="${WEB_APP_DIR}/api"

print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

SOURCE_FILES_CENTRAL=("./${SLA_CONFIG_NAME}" "./api/${PHP_API_SUBMIT_NAME}" "./api/${PHP_API_GET_PROFILE_CONFIG_NAME}" "./${PHP_SLA_STATS_NAME}" "./${INDEX_HTML_NAME}")
for file in "${SOURCE_FILES_CENTRAL[@]}"; do if [ ! -f "$file" ]; then print_error "Source file '$file' for central server not found."; exit 1; fi; done
print_info "Starting CENTRAL Internet SLA Monitor Setup..."; if [ "$(id -u)" -ne 0 ]; then print_error "Please run with sudo: sudo $0"; exit 1; fi
print_info "Updating package list..."; sudo apt update -y || { print_error "Apt update failed."; exit 1; }
print_info "Installing Apache2, sqlite3, PHP components, curl, jq, bc..."; sudo apt install -y apache2 sqlite3 php libapache2-mod-php php-sqlite3 curl jq bc || { print_error "Dependency installation failed."; exit 1; }
if command -v a2enmod &> /dev/null; then PHP_VERSION_MODULE="php$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"; if sudo a2enmod "$PHP_VERSION_MODULE"; then print_info "Enabled PHP module $PHP_VERSION_MODULE."; else print_warn "Failed PHP module $PHP_VERSION_MODULE. Trying generic."; if sudo a2enmod php; then print_info "Enabled generic PHP."; else print_warn "Failed generic PHP."; fi; fi; sudo systemctl restart apache2 || print_error "Apache restart failed."; else print_warn "a2enmod not found."; fi
sudo systemctl enable apache2; sudo systemctl start apache2
sudo mkdir -p "${MONITOR_SCRIPT_DIR}" "${WEB_APP_DIR}" "${WEB_API_DIR}"; sudo touch "${API_LOG_FILE}"; sudo chown www-data:adm "${API_LOG_FILE}"; sudo chmod 664 "${API_LOG_FILE}"
print_info "Copying general config file to ${CONFIG_FILE_PATH}"; if [ -f "${CONFIG_FILE_PATH}" ]; then print_warn "${CONFIG_FILE_PATH} exists. Overwriting."; fi; sudo cp "./${SLA_CONFIG_NAME}" "${CONFIG_FILE_PATH}"; sudo chown root:${SQLITE_DB_GROUP_PHP_READ} "${CONFIG_FILE_PATH}"; sudo chmod 640 "${CONFIG_FILE_PATH}"

print_info "Creating/Updating CENTRAL SQLite database: ${CENTRAL_DB_FILE}"
sudo touch "${CENTRAL_DB_FILE}"; sudo chown "${SQLITE_DB_OWNER}:${SQLITE_DB_GROUP_PHP_READ}" "${MONITOR_SCRIPT_DIR}"; sudo chmod 770 "${MONITOR_SCRIPT_DIR}"; sudo chown "${SQLITE_DB_OWNER}:${SQLITE_DB_GROUP_PHP_READ}" "${CENTRAL_DB_FILE}"; sudo chmod 660 "${CENTRAL_DB_FILE}"     
sudo sqlite3 "${CENTRAL_DB_FILE}" <<EOF
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS isp_profiles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_name TEXT NOT NULL, -- Will be auto-populated by agent_hostname initially
    agent_identifier TEXT UNIQUE NOT NULL,
    agent_type TEXT NOT NULL CHECK(agent_type IN ('ISP', 'Client')) DEFAULT 'Client',
    network_interface_to_monitor TEXT,
    last_reported_hostname TEXT,
    last_reported_source_ip TEXT,
    is_active INTEGER DEFAULT 1, 
    sla_target_percentage REAL DEFAULT 99.5,
    rtt_degraded INTEGER DEFAULT 100, rtt_poor INTEGER DEFAULT 250,
    loss_degraded INTEGER DEFAULT 2, loss_poor INTEGER DEFAULT 10,
    ping_jitter_degraded INTEGER DEFAULT 30, ping_jitter_poor INTEGER DEFAULT 50,
    dns_time_degraded INTEGER DEFAULT 300, dns_time_poor INTEGER DEFAULT 800,
    http_time_degraded REAL DEFAULT 1.0, http_time_poor REAL DEFAULT 2.5,
    speedtest_dl_degraded REAL DEFAULT 60, speedtest_dl_poor REAL DEFAULT 30,
    speedtest_ul_degraded REAL DEFAULT 20, speedtest_ul_poor REAL DEFAULT 5,
    teams_webhook_url TEXT DEFAULT '',
    alert_hostname_override TEXT,
    notes TEXT,
    last_heard_from TEXT,
    UNIQUE(agent_identifier) -- Ensure agent_identifier is unique
);
CREATE TABLE IF NOT EXISTS sla_metrics (id INTEGER PRIMARY KEY AUTOINCREMENT, isp_profile_id INTEGER NOT NULL, timestamp TEXT NOT NULL, overall_connectivity TEXT, avg_rtt_ms REAL, avg_loss_percent REAL, avg_jitter_ms REAL, dns_status TEXT, dns_resolve_time_ms INTEGER, http_status TEXT, http_response_code INTEGER, http_total_time_s REAL, speedtest_status TEXT, speedtest_download_mbps REAL, speedtest_upload_mbps REAL, speedtest_ping_ms REAL, speedtest_jitter_ms REAL, detailed_health_summary TEXT, sla_met_interval INTEGER DEFAULT 0, FOREIGN KEY (isp_profile_id) REFERENCES isp_profiles(id), UNIQUE(isp_profile_id, timestamp));
CREATE INDEX IF NOT EXISTS idx_central_sla_metrics_isp_timestamp ON sla_metrics (isp_profile_id, timestamp); CREATE INDEX IF NOT EXISTS idx_isp_profiles_agent_identifier ON isp_profiles (agent_identifier);
VACUUM;
EOF
# Add new columns to isp_profiles if they don't exist (for upgrades)
print_info "Ensuring isp_profiles table schema is up-to-date..."
if ! sudo sqlite3 "$CENTRAL_DB_FILE" "PRAGMA table_info(isp_profiles);" | grep -qw "agent_type"; then sudo sqlite3 "$CENTRAL_DB_FILE" "ALTER TABLE isp_profiles ADD COLUMN agent_type TEXT NOT NULL CHECK(agent_type IN ('ISP', 'Client')) DEFAULT 'Client';" || print_warn "Failed: agent_type"; fi
if ! sudo sqlite3 "$CENTRAL_DB_FILE" "PRAGMA table_info(isp_profiles);" | grep -qw "last_reported_hostname"; then sudo sqlite3 "$CENTRAL_DB_FILE" "ALTER TABLE isp_profiles ADD COLUMN last_reported_hostname TEXT;" || print_warn "Failed: last_reported_hostname"; fi
if ! sudo sqlite3 "$CENTRAL_DB_FILE" "PRAGMA table_info(isp_profiles);" | grep -qw "last_reported_source_ip"; then sudo sqlite3 "$CENTRAL_DB_FILE" "ALTER TABLE isp_profiles ADD COLUMN last_reported_source_ip TEXT;" || print_warn "Failed: last_reported_source_ip"; fi
if ! sudo sqlite3 "$CENTRAL_DB_FILE" "PRAGMA table_info(isp_profiles);" | grep -qw "ping_jitter_degraded"; then sudo sqlite3 "$CENTRAL_DB_FILE" "ALTER TABLE isp_profiles ADD COLUMN ping_jitter_degraded INTEGER DEFAULT 30; ALTER TABLE isp_profiles ADD COLUMN ping_jitter_poor INTEGER DEFAULT 50;" || print_warn "Failed: jitter thresholds."; fi
if ! sudo sqlite3 "$CENTRAL_DB_FILE" "PRAGMA table_info(isp_profiles);" | grep -qw "alert_hostname_override"; then sudo sqlite3 "$CENTRAL_DB_FILE" "ALTER TABLE isp_profiles ADD COLUMN alert_hostname_override TEXT;" || print_warn "Failed: alert_hostname_override."; fi
if ! sudo sqlite3 "$CENTRAL_DB_FILE" "PRAGMA table_info(isp_profiles);" | grep -qw "notes"; then sudo sqlite3 "$CENTRAL_DB_FILE" "ALTER TABLE isp_profiles ADD COLUMN notes TEXT;" || print_warn "Failed: notes."; fi
if ! sudo sqlite3 "$CENTRAL_DB_FILE" "PRAGMA table_info(isp_profiles);" | grep -qw "last_heard_from"; then sudo sqlite3 "$CENTRAL_DB_FILE" "ALTER TABLE isp_profiles ADD COLUMN last_heard_from TEXT;" || print_warn "Failed: last_heard_from."; fi
# Ensure new columns in sla_metrics
if ! sudo sqlite3 "$CENTRAL_DB_FILE" "PRAGMA table_info(sla_metrics);" | grep -qw "avg_jitter_ms"; then sudo sqlite3 "$CENTRAL_DB_FILE" "ALTER TABLE sla_metrics ADD COLUMN avg_jitter_ms REAL;" || print_warn "Failed: sla_metrics.avg_jitter_ms"; fi
if ! sudo sqlite3 "$CENTRAL_DB_FILE" "PRAGMA table_info(sla_metrics);" | grep -qw "speedtest_jitter_ms"; then sudo sqlite3 "$CENTRAL_DB_FILE" "ALTER TABLE sla_metrics ADD COLUMN speedtest_jitter_ms REAL;" || print_warn "Failed: sla_metrics.speedtest_jitter_ms"; fi
sudo chown "${SQLITE_DB_OWNER}:${SQLITE_DB_GROUP_PHP_READ}" "${CENTRAL_DB_FILE}"; sudo chmod 660 "${CENTRAL_DB_FILE}"

print_info "Copying PHP API submit script to ${WEB_API_DIR}/${PHP_API_SUBMIT_NAME}"; sudo cp "./api/${PHP_API_SUBMIT_NAME}" "${WEB_API_DIR}/${PHP_API_SUBMIT_NAME}"
print_info "Copying PHP API get profile config script to ${WEB_API_DIR}/${PHP_API_GET_PROFILE_CONFIG_NAME}"; sudo cp "./api/${PHP_API_GET_PROFILE_CONFIG_NAME}" "${WEB_API_DIR}/${PHP_API_GET_PROFILE_CONFIG_NAME}"
print_info "Copying PHP SLA statistics script to ${WEB_APP_DIR}/${PHP_SLA_STATS_NAME}"; sudo cp "./${PHP_SLA_STATS_NAME}" "${WEB_APP_DIR}/${PHP_SLA_STATS_NAME}"
print_info "Copying dashboard HTML to ${WEB_INDEX_FILE_PATH}"; sudo cp "./${INDEX_HTML_NAME}" "${WEB_INDEX_FILE_PATH}"
sudo chown -R www-data:www-data "${WEB_APP_DIR}"; sudo find "${WEB_APP_DIR}" -type d -exec chmod 755 {} \; sudo find "${WEB_APP_DIR}" -type f -exec chmod 644 {} \;
print_info "--------------------------------------------------------------------"; SERVER_IP=$(hostname -I | awk '{print $1}'); print_info "CENTRAL Dashboard: http://${SERVER_IP:-<your_server_ip>}/${WEB_DIR_NAME}/"; print_info "API Submit Endpoint: http://${SERVER_IP:-<your_server_ip>}/${WEB_DIR_NAME}/api/${PHP_API_SUBMIT_NAME}"; print_info "API Get Profile Config: http://${SERVER_IP:-<your_server_ip>}/${WEB_DIR_NAME}/api/${PHP_API_GET_PROFILE_CONFIG_NAME}?agent_id=<AGENT_ID>"; print_info "--------------------------------------------------------------------"; print_info "CENTRAL Server Setup finished. General config: ${CONFIG_FILE_PATH}."; print_info "Agents will auto-register on first data submission with default thresholds."; print_info "Customize auto-created profiles via SQLite: sudo sqlite3 ${CENTRAL_DB_FILE}"; print_info "Firewall: Ensure port 80 is open (e.g., sudo ufw allow 'Apache')"