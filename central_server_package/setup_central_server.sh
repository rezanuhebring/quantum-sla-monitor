#!/bin/bash

# Script to set up the Central Internet SLA Monitor Dashboard using Docker.

# --- Configuration Variables ---
APP_SOURCE_SUBDIR="app" # Application files are in ./app/ relative to this script's location

HOST_DATA_ROOT="/srv/sla_monitor/central_app_data"
HOST_OPT_SLA_MONITOR_DIR="${HOST_DATA_ROOT}/opt_sla_monitor"
HOST_API_LOGS_DIR="${HOST_DATA_ROOT}/api_logs"
HOST_APACHE_LOGS_DIR="${HOST_DATA_ROOT}/apache_logs"

SLA_CONFIG_TEMPLATE_NAME="sla_config.env.template" # Source template name
SLA_CONFIG_FINAL_NAME="sla_config.env"          # Final name on host volume

PHP_API_SUBMIT_NAME="submit_metrics.php"
PHP_API_GET_PROFILE_CONFIG_NAME="get_profile_config.php"
PHP_SLA_STATS_NAME="get_sla_stats.php"
INDEX_HTML_NAME="index.html"

SQLITE_DB_FILE_NAME="central_sla_data.sqlite"
SQLITE_DB_FILE_HOST_PATH="${HOST_OPT_SLA_MONITOR_DIR}/${SQLITE_DB_FILE_NAME}"
SQLITE_DB_OWNER="root" 
SQLITE_DB_GROUP_PHP_READ="www-data" 

DOCKER_COMPOSE_FILE_NAME="docker-compose.yml" # Will be created in current dir
DOCKERFILE_NAME="Dockerfile"                   # Will be created in current dir

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

# --- Main Setup Logic ---
print_info "Starting CENTRAL Internet SLA Monitor Docker Setup..."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# 0. Check if source application files exist in ./app subdirectory
print_info "Checking for required application source files in ./${APP_SOURCE_SUBDIR}/ ..."
REQUIRED_APP_FILES=(
    "./${APP_SOURCE_SUBDIR}/${SLA_CONFIG_TEMPLATE_NAME}" # Check for the .template file
    "./${APP_SOURCE_SUBDIR}/api/${PHP_API_SUBMIT_NAME}"
    "./${APP_SOURCE_SUBDIR}/api/${PHP_API_GET_PROFILE_CONFIG_NAME}"
    "./${APP_SOURCE_SUBDIR}/${PHP_SLA_STATS_NAME}"
    "./${APP_SOURCE_SUBDIR}/${INDEX_HTML_NAME}"
)
if [ ! -d "./${APP_SOURCE_SUBDIR}" ]; then print_error "Source directory './${APP_SOURCE_SUBDIR}/' not found."; exit 1; fi
if [ ! -d "./${APP_SOURCE_SUBDIR}/api" ]; then print_error "Source directory './${APP_SOURCE_SUBDIR}/api/' not found."; exit 1; fi
for file in "${REQUIRED_APP_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        print_error "Source file '$file' not found."
        print_error "Ensure the '${APP_SOURCE_SUBDIR}' subdirectory and its contents are correct relative to setup_central_server.sh."
        exit 1
    fi
done

# 1. Install Docker and Docker Compose
print_info "Checking Docker & Docker Compose..."; if ! command -v docker &> /dev/null; then print_info "Installing Docker..."; sudo apt update -y || exit 1; sudo apt install -y apt-transport-https ca-certificates curl software-properties-common || exit 1; curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -; sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y; sudo apt update -y; sudo apt install -y docker-ce docker-ce-cli containerd.io || exit 1; sudo systemctl start docker; sudo systemctl enable docker; else print_info "Docker installed."; fi
if ! command -v docker-compose &> /dev/null; then print_info "Installing Docker Compose..."; LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name); if [ -z "$LATEST_COMPOSE_VERSION" ]; then LATEST_COMPOSE_VERSION="v2.24.6"; fi; sudo curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || exit 1; sudo chmod +x /usr/local/bin/docker-compose || exit 1; else print_info "Docker Compose installed: $(docker-compose --version)"; fi

# 2. Create Host Directories for Docker Volumes
print_info "Creating host directories for Docker volumes under ${HOST_DATA_ROOT}..."
sudo mkdir -p "${HOST_OPT_SLA_MONITOR_DIR}" "${HOST_API_LOGS_DIR}" "${HOST_APACHE_LOGS_DIR}"
sudo touch "${HOST_API_LOGS_DIR}/sla_api.log"; sudo chown www-data:adm "${HOST_API_LOGS_DIR}/sla_api.log"; sudo chmod 664 "${HOST_API_LOGS_DIR}/sla_api.log"

# 3. Create Dockerfile in current directory (which is central_server_package)
print_info "Creating Dockerfile ./${DOCKERFILE_NAME}"
tee "./${DOCKERFILE_NAME}" > /dev/null <<'EOF_DOCKERFILE_CONTENT'
FROM php:8.2-apache
RUN apt-get update && apt-get install -y sqlite3 libsqlite3-dev libzip-dev zip unzip curl jq bc git iputils-ping dnsutils \
    && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-install pdo pdo_sqlite sqlite3 zip
RUN a2enmod rewrite headers ssl expires
WORKDIR /app_build_temp
COPY ./app/ /app_build_temp/ 
RUN mkdir -p /var/www/html/sla_status && cp -R /app_build_temp/* /var/www/html/sla_status/ && \
    rm -rf /app_build_temp && \
    chown -R www-data:www-data /var/www/html/sla_status && \
    find /var/www/html/sla_status -type d -exec chmod 755 {} \; && \
    find /var/www/html/sla_status -type f -exec chmod 644 {} \;
RUN echo "<VirtualHost *:80>\n\
    ServerAdmin webmaster@localhost\n\
    DocumentRoot /var/www/html/sla_status\n\
    <Directory /var/www/html/sla_status>\n\
        Options Indexes FollowSymLinks\n\
        AllowOverride All\n\
        Require all granted\n\
    </Directory>\n\
    ErrorLog \${APACHE_LOG_DIR}/error.log\n\
    CustomLog \${APACHE_LOG_DIR}/access.log combined\n\
</VirtualHost>" > /etc/apache2/sites-available/000-default.conf
EXPOSE 80 443
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD curl -f http://localhost/index.html || exit 1
EOF_DOCKERFILE_CONTENT

# 4. Create docker-compose.yml in current directory
print_info "Creating ${DOCKER_COMPOSE_FILE_NAME}..."
tee "${DOCKER_COMPOSE_FILE_NAME}" > /dev/null <<EOF_DOCKER_COMPOSE_CONTENT
version: '3.8'
services:
  sla_monitor_central_app:
    build:
      context: . 
      dockerfile: ${DOCKERFILE_NAME}
    container_name: sla_monitor_central_app
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ${HOST_OPT_SLA_MONITOR_DIR}:/opt/sla_monitor 
      - ${HOST_API_LOGS_DIR}/sla_api.log:/var/log/sla_api.log 
      - ${HOST_APACHE_LOGS_DIR}:/var/log/apache2
    environment:
      APACHE_LOG_DIR: /var/log/apache2
EOF_DOCKER_COMPOSE_CONTENT

# 5. Initialize sla_config.env on Host Volume
HOST_VOLUME_CONFIG_FILE_PATH="${HOST_OPT_SLA_MONITOR_DIR}/${SLA_CONFIG_FINAL_NAME}"
SOURCE_CONFIG_TEMPLATE_PATH="./${APP_SOURCE_SUBDIR}/${SLA_CONFIG_TEMPLATE_NAME}"

print_info "Initializing ${SLA_CONFIG_FINAL_NAME} on host volume: ${HOST_VOLUME_CONFIG_FILE_PATH}"
if [ ! -f "${HOST_VOLUME_CONFIG_FILE_PATH}" ]; then
    sudo cp "${SOURCE_CONFIG_TEMPLATE_PATH}" "${HOST_VOLUME_CONFIG_FILE_PATH}"
    print_info "${SLA_CONFIG_FINAL_NAME} (from template ${SLA_CONFIG_TEMPLATE_NAME}) copied to host volume."
    print_info "IMPORTANT: Please customize ${HOST_VOLUME_CONFIG_FILE_PATH} with your specific settings."
else
    print_warn "${HOST_VOLUME_CONFIG_FILE_PATH} already exists on host volume. Not overwriting current user settings."
    # Check if the packaged template is different from what's on the host, suggesting a template update
    if ! cmp -s "${SOURCE_CONFIG_TEMPLATE_PATH}" "${HOST_VOLUME_CONFIG_FILE_PATH}" &>/dev/null ; then
        # To avoid constant warnings if user customized, we check if it still looks like the template
        if grep -q "Default thresholds for NEWLY auto-created agent profiles" "${HOST_VOLUME_CONFIG_FILE_PATH}" || \
           grep -q "General Configuration for Central SLA Monitor Server" "${HOST_VOLUME_CONFIG_FILE_PATH}"; then
             # It might be an older template or one that wasn't fully customized.
             # Or it could be the same as the new template if no user changes were made.
             # A simple check here isn't perfect for detecting "user modified" vs "outdated template".
             # We'll just notify if the content differs from the *new template*.
            print_warn "The packaged template ${SOURCE_CONFIG_TEMPLATE_PATH} is different from your existing ${HOST_VOLUME_CONFIG_FILE_PATH}."
            print_warn "You may want to compare and incorporate any new settings from the template into your existing host config."
            # sudo cp "${SOURCE_CONFIG_TEMPLATE_PATH}" "${HOST_VOLUME_CONFIG_FILE_PATH}.new_template_from_setup" # Option to copy new template
        fi
    fi
fi
sudo chown root:${SQLITE_DB_GROUP_PHP_READ} "${HOST_VOLUME_CONFIG_FILE_PATH}"; sudo chmod 640 "${HOST_VOLUME_CONFIG_FILE_PATH}"


print_info "Initializing CENTRAL SQLite database on host: ${SQLITE_DB_FILE_HOST_PATH}"
sudo touch "${SQLITE_DB_FILE_HOST_PATH}"; sudo chown "${SQLITE_DB_OWNER}:${SQLITE_DB_GROUP_PHP_READ}" "${HOST_OPT_SLA_MONITOR_DIR}"; sudo chmod 770 "${HOST_OPT_SLA_MONITOR_DIR}"; sudo chown "${SQLITE_DB_OWNER}:${SQLITE_DB_GROUP_PHP_READ}" "${SQLITE_DB_FILE_HOST_PATH}"; sudo chmod 660 "${SQLITE_DB_FILE_HOST_PATH}"     
sudo sqlite3 "${SQLITE_DB_FILE_HOST_PATH}" <<EOF
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS isp_profiles (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT NOT NULL UNIQUE, agent_identifier TEXT UNIQUE NOT NULL, agent_type TEXT NOT NULL CHECK(agent_type IN ('ISP', 'Client')) DEFAULT 'ISP', network_interface_to_monitor TEXT, last_reported_hostname TEXT, last_reported_source_ip TEXT, is_active INTEGER DEFAULT 1, sla_target_percentage REAL DEFAULT 99.5, rtt_degraded INTEGER DEFAULT 100, rtt_poor INTEGER DEFAULT 250, loss_degraded INTEGER DEFAULT 2, loss_poor INTEGER DEFAULT 10, ping_jitter_degraded INTEGER DEFAULT 30, ping_jitter_poor INTEGER DEFAULT 50, dns_time_degraded INTEGER DEFAULT 300, dns_time_poor INTEGER DEFAULT 800, http_time_degraded REAL DEFAULT 1.0, http_time_poor REAL DEFAULT 2.5, speedtest_dl_degraded REAL DEFAULT 60, speedtest_dl_poor REAL DEFAULT 30, speedtest_ul_degraded REAL DEFAULT 20, speedtest_ul_poor REAL DEFAULT 5, teams_webhook_url TEXT DEFAULT '', alert_hostname_override TEXT, notes TEXT, last_heard_from TEXT);
CREATE TABLE IF NOT EXISTS sla_metrics (id INTEGER PRIMARY KEY AUTOINCREMENT, isp_profile_id INTEGER NOT NULL, timestamp TEXT NOT NULL, overall_connectivity TEXT, avg_rtt_ms REAL, avg_loss_percent REAL, avg_jitter_ms REAL, dns_status TEXT, dns_resolve_time_ms INTEGER, http_status TEXT, http_response_code INTEGER, http_total_time_s REAL, speedtest_status TEXT, speedtest_download_mbps REAL, speedtest_upload_mbps REAL, speedtest_ping_ms REAL, speedtest_jitter_ms REAL, detailed_health_summary TEXT, sla_met_interval INTEGER DEFAULT 0, FOREIGN KEY (isp_profile_id) REFERENCES isp_profiles(id), UNIQUE(isp_profile_id, timestamp));
CREATE INDEX IF NOT EXISTS idx_central_sla_metrics_isp_timestamp ON sla_metrics (isp_profile_id, timestamp); CREATE INDEX IF NOT EXISTS idx_isp_profiles_agent_identifier ON isp_profiles (agent_identifier);
INSERT OR IGNORE INTO isp_profiles (agent_name, agent_identifier, agent_type, is_active, alert_hostname_override, sla_target_percentage, rtt_degraded, rtt_poor, loss_degraded, loss_poor, ping_jitter_degraded, ping_jitter_poor, dns_time_degraded, dns_time_poor, http_time_degraded, http_time_poor, speedtest_dl_degraded, speedtest_dl_poor, speedtest_ul_degraded, speedtest_ul_poor) SELECT 'Central Server Local (Example)', 'central_server_local_001', 'ISP', 0, '$(hostname -s)', 99.5, 100, 250, 2, 10, 30, 50, 300, 800, 1.0, 2.5, 60, 30, 20, 5 WHERE NOT EXISTS (SELECT 1 FROM isp_profiles WHERE agent_identifier = 'central_server_local_001');
VACUUM;
EOF
print_info "Ensuring DB table schemas are up-to-date..."
for col_def in "agent_type TEXT NOT NULL CHECK(agent_type IN ('ISP', 'Client')) DEFAULT 'ISP'" "last_reported_hostname TEXT" "last_reported_source_ip TEXT" "ping_jitter_degraded INTEGER DEFAULT 30" "ping_jitter_poor INTEGER DEFAULT 50" "alert_hostname_override TEXT" "notes TEXT" "last_heard_from TEXT"; do col_name=$(echo "$col_def" | awk '{print $1}'); if ! sudo sqlite3 "$SQLITE_DB_FILE_HOST_PATH" "PRAGMA table_info(isp_profiles);" | grep -qw "$col_name"; then print_info "Adding '$col_name' to isp_profiles..."; sudo sqlite3 "$SQLITE_DB_FILE_HOST_PATH" "ALTER TABLE isp_profiles ADD COLUMN $col_def;" || print_warn "Failed '$col_name'"; fi; done
for col_def in "avg_jitter_ms REAL" "speedtest_jitter_ms REAL"; do col_name=$(echo "$col_def" | awk '{print $1}'); if ! sudo sqlite3 "$SQLITE_DB_FILE_HOST_PATH" "PRAGMA table_info(sla_metrics);" | grep -qw "$col_name"; then print_info "Adding '$col_name' to sla_metrics..."; sudo sqlite3 "$SQLITE_DB_FILE_HOST_PATH" "ALTER TABLE sla_metrics ADD COLUMN $col_def;" || print_warn "Failed '$col_name'"; fi; done
sudo chown "${SQLITE_DB_OWNER}:${SQLITE_DB_GROUP_PHP_READ}" "${SQLITE_DB_FILE_HOST_PATH}"; sudo chmod 660 "${SQLITE_DB_FILE_HOST_PATH}"

print_info "Building and starting Docker container(s)..."; sudo docker-compose -f "${DOCKER_COMPOSE_FILE_NAME}" up --build -d
if [ $? -eq 0 ]; then print_info "Docker container(s) started."; sudo docker-compose -f "${DOCKER_COMPOSE_FILE_NAME}" ps; else print_error "Failed to start Docker containers. Check logs."; exit 1; fi

print_info "--------------------------------------------------------------------"; SERVER_IP=$(hostname -I | awk '{print $1}'); print_info "CENTRAL Dashboard: http://${SERVER_IP:-<your_server_ip>}/"; print_info "API Submit: http://${SERVER_IP:-<your_server_ip>}/api/${PHP_API_SUBMIT_NAME}"; print_info "API Get Profile Config: http://${SERVER_IP:-<your_server_ip>}/api/${PHP_API_GET_PROFILE_CONFIG_NAME}?agent_id=<AGENT_ID>"; print_info "--------------------------------------------------------------------"; print_info "CENTRAL Server Docker Setup finished. Config on host: ${HOST_OPT_SLA_MONITOR_DIR}/${SLA_CONFIG_FINAL_NAME}."; print_info "Next: Manually add/Edit Agent profiles in DB: sudo sqlite3 ${SQLITE_DB_FILE_HOST_PATH}"; print_info "Then set up Agent Machines."; print_info "Firewall: Ensure port 80 (and 443 for HTTPS) is open."