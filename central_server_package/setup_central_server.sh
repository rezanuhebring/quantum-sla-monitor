#!/bin/bash

# Script to set up the Central Internet SLA Monitor Dashboard using Docker.

# --- Configuration Variables ---
APP_SOURCE_SUBDIR="app"
HOST_DATA_ROOT="/srv/sla_monitor/central_app_data"
HOST_OPT_SLA_MONITOR_DIR="${HOST_DATA_ROOT}/opt_sla_monitor"
HOST_API_LOGS_DIR="${HOST_DATA_ROOT}/api_logs"
HOST_APACHE_LOGS_DIR="${HOST_DATA_ROOT}/apache_logs"
SLA_CONFIG_SOURCE_NAME="sla_config.env"
SLA_CONFIG_HOST_FINAL_NAME="sla_config.env"
SQLITE_DB_FILE_NAME="central_sla_data.sqlite"
SQLITE_DB_FILE_HOST_PATH="${HOST_OPT_SLA_MONITOR_DIR}/${SQLITE_DB_FILE_NAME}"
SQLITE_DB_OWNER="root"
SQLITE_DB_GROUP_PHP_READ="www-data"
DOCKER_COMPOSE_FILE_NAME="docker-compose.yml"
DOCKERFILE_NAME="Dockerfile"
APACHE_CONFIG_DIR="docker/apache"
APACHE_CONFIG_FILE="000-default.conf"

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

# --- Main Setup Logic ---
print_info "Starting CENTRAL Internet SLA Monitor Docker Setup..."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# 0. Check if source application files exist
print_info "Checking for required application source files in ./${APP_SOURCE_SUBDIR}/ ..."
if [ ! -d "./${APP_SOURCE_SUBDIR}" ]; then print_error "Source directory './${APP_SOURCE_SUBDIR}/' not found. This script must be run from 'central_server_package/'."; exit 1; fi
# Add other file checks as needed...

# 1. Install System Dependencies (Docker, Compose, and SQLite3 client)
print_info "Checking system dependencies..."
sudo apt-get update -y || { print_error "Apt update failed."; exit 1; }

# Install Docker
if ! command -v docker &> /dev/null; then 
    print_info "Installing Docker..."; 
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common || { print_error "Docker prereqs failed"; exit 1; }
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io || { print_error "Docker CE install failed"; exit 1; }
    sudo systemctl start docker
    sudo systemctl enable docker
    print_info "Docker installed."
else 
    print_info "Docker is already installed."
fi

# Install Docker Compose
if ! command -v docker-compose &> /dev/null; then 
    print_info "Installing Docker Compose..."; 
    LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    if [ -z "$LATEST_COMPOSE_VERSION" ]; then 
        LATEST_COMPOSE_VERSION="v2.24.6"; 
        print_warn "Could not fetch latest Docker Compose version, using $LATEST_COMPOSE_VERSION"
    fi
    sudo curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || { print_error "Docker Compose download failed"; exit 1; }
    sudo chmod +x /usr/local/bin/docker-compose || { print_error "Docker Compose chmod failed"; exit 1; }
    print_info "Docker Compose ${LATEST_COMPOSE_VERSION} installed."
else 
    print_info "Docker Compose is already installed: $(docker-compose --version)"
fi

# Ensure sqlite3 command-line tool is installed on the HOST
if ! command -v sqlite3 &> /dev/null; then
    print_info "Installing host tool 'sqlite3' for database administration..."
    sudo apt-get install -y sqlite3
else
    print_info "Host tool 'sqlite3' is already installed."
fi

# 2. Create Host Directories for Docker Volumes
print_info "Creating host directories for Docker volumes under ${HOST_DATA_ROOT}..."
sudo mkdir -p "${HOST_OPT_SLA_MONITOR_DIR}" "${HOST_API_LOGS_DIR}" "${HOST_APACHE_LOGS_DIR}"
sudo touch "${HOST_API_LOGS_DIR}/sla_api.log"
# Permissions will be set later, after files are created/copied.

# 3. Create Dockerfile and supporting Apache configuration
print_info "Creating Docker build files..."
mkdir -p ./${APACHE_CONFIG_DIR}
print_info "Created directory for Apache config: ./${APACHE_CONFIG_DIR}"

# *** THIS BLOCK IS NOW FIXED ***
tee "./${APACHE_CONFIG_DIR}/${APACHE_CONFIG_FILE}" > /dev/null <<'EOF_APACHE_CONF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/sla_status
    <Directory /var/www/html/sla_status>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF_APACHE_CONF>
print_info "Created Apache config file: ./${APACHE_CONFIG_DIR}/${APACHE_CONFIG_FILE}"

tee "./${DOCKERFILE_NAME}" > /dev/null <<'EOF_DOCKERFILE_CONTENT'
# =========================================================================
# STAGE 1: Builder
# =========================================================================
FROM php:8.2-apache AS builder
LABEL stage="builder"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev libzip-dev zlib1g-dev && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN docker-php-ext-install -j$(nproc) pdo pdo_sqlite zip
# =========================================================================
# STAGE 2: Final Production Image
# =========================================================================
FROM php:8.2-apache
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends sqlite3 curl jq bc git iputils-ping dnsutils procps nano less ca-certificates gnupg && \
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash && \
    apt-get install -y --no-install-recommends speedtest && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
RUN docker-php-ext-enable pdo pdo_sqlite zip
RUN a2enmod rewrite headers ssl expires
COPY ./docker/apache/000-default.conf /etc/apache2/sites-available/000-default.conf
WORKDIR /var/www/html/sla_status
COPY ./app/ .
RUN chown -R www-data:www-data /var/www/html/sla_status && \
    find /var/www/html/sla_status -type d -exec chmod 755 {} \; && \
    find /var/www/html/sla_status -type f -exec chmod 644 {} \;
EXPOSE 80 443
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD curl -f http://localhost/index.html || exit 1
EOF_DOCKERFILE_CONTENT
print_info "Created new multi-stage Dockerfile: ./${DOCKERFILE_NAME}"

# 4. Create docker-compose.yml in current directory (using absolute paths for volumes)
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
      - "443:443"
    volumes:
      - ${HOST_OPT_SLA_MONITOR_DIR}:/opt/sla_monitor
      - ${HOST_API_LOGS_DIR}/sla_api.log:/var/log/sla_api.log
      - ${HOST_APACHE_LOGS_DIR}:/var/log/apache2
    environment:
      APACHE_LOG_DIR: /var/log/apache2
EOF_DOCKER_COMPOSE_CONTENT

# 5. Initialize sla_config.env and SQLite Database on Host Volume
HOST_VOLUME_CONFIG_FILE_PATH="${HOST_OPT_SLA_MONITOR_DIR}/${SLA_CONFIG_HOST_FINAL_NAME}"
SOURCE_CONFIG_TEMPLATE_PATH="./${APP_SOURCE_SUBDIR}/${SLA_CONFIG_SOURCE_NAME}"
print_info "Initializing ${SLA_CONFIG_HOST_FINAL_NAME} on host volume: ${HOST_VOLUME_CONFIG_FILE_PATH}"
if [ ! -f "${HOST_VOLUME_CONFIG_FILE_PATH}" ]; then
    sudo cp "${SOURCE_CONFIG_TEMPLATE_PATH}" "${HOST_VOLUME_CONFIG_FILE_PATH}"
    print_info "${SLA_CONFIG_HOST_FINAL_NAME} copied to host."
else
    print_warn "${HOST_VOLUME_CONFIG_FILE_PATH} already exists. Not overwriting."
fi

print_info "Initializing CENTRAL SQLite database on host: ${SQLITE_DB_FILE_HOST_PATH}"
sudo touch "${SQLITE_DB_FILE_HOST_PATH}"
# Set directory permissions before creating DB content
sudo chown -R root:www-data "${HOST_DATA_ROOT}"
sudo chmod -R 770 "${HOST_DATA_ROOT}"
sudo chmod 660 "${HOST_VOLUME_CONFIG_FILE_PATH}"
sudo chmod 660 "${HOST_API_LOGS_DIR}/sla_api.log"
sudo chmod 660 "${SQLITE_DB_FILE_HOST_PATH}"

# Create DB schema
sudo sqlite3 "${SQLITE_DB_FILE_HOST_PATH}" <<EOF
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS isp_profiles (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT NOT NULL UNIQUE, agent_identifier TEXT UNIQUE NOT NULL, agent_type TEXT NOT NULL CHECK(agent_type IN ('ISP', 'Client')) DEFAULT 'ISP', network_interface_to_monitor TEXT, last_reported_hostname TEXT, last_reported_source_ip TEXT, is_active INTEGER DEFAULT 1, sla_target_percentage REAL DEFAULT 99.5, rtt_degraded INTEGER DEFAULT 100, rtt_poor INTEGER DEFAULT 250, loss_degraded INTEGER DEFAULT 2, loss_poor INTEGER DEFAULT 10, ping_jitter_degraded INTEGER DEFAULT 30, ping_jitter_poor INTEGER DEFAULT 50, dns_time_degraded INTEGER DEFAULT 300, dns_time_poor INTEGER DEFAULT 800, http_time_degraded REAL DEFAULT 1.0, http_time_poor REAL DEFAULT 2.5, speedtest_dl_degraded REAL DEFAULT 60, speedtest_dl_poor REAL DEFAULT 30, speedtest_ul_degraded REAL DEFAULT 20, speedtest_ul_poor REAL DEFAULT 5, teams_webhook_url TEXT DEFAULT '', alert_hostname_override TEXT, notes TEXT, last_heard_from TEXT);
CREATE TABLE IF NOT EXISTS sla_metrics (id INTEGER PRIMARY KEY AUTOINCREMENT, isp_profile_id INTEGER NOT NULL, timestamp TEXT NOT NULL, overall_connectivity TEXT, avg_rtt_ms REAL, avg_loss_percent REAL, avg_jitter_ms REAL, dns_status TEXT, dns_resolve_time_ms INTEGER, http_status TEXT, http_response_code INTEGER, http_total_time_s REAL, speedtest_status TEXT, speedtest_download_mbps REAL, speedtest_upload_mbps REAL, speedtest_ping_ms REAL, speedtest_jitter_ms REAL, detailed_health_summary TEXT, sla_met_interval INTEGER DEFAULT 0, FOREIGN KEY (isp_profile_id) REFERENCES isp_profiles(id), UNIQUE(isp_profile_id, timestamp));
CREATE INDEX IF NOT EXISTS idx_central_sla_metrics_isp_timestamp ON sla_metrics (isp_profile_id, timestamp); CREATE INDEX IF NOT EXISTS idx_isp_profiles_agent_identifier ON isp_profiles (agent_identifier);
INSERT OR IGNORE INTO isp_profiles (agent_name, agent_identifier, agent_type, is_active, alert_hostname_override) SELECT 'Central Server Local (Example)', 'central_server_local_001', 'ISP', 0, '$(hostname -s)';
VACUUM;
EOF
print_info "Database schema created/verified."

# 6. Build and Start the Docker Container
print_info "Building and starting Docker container..."
sudo docker-compose -f "${DOCKER_COMPOSE_FILE_NAME}" up --build -d
if [ $? -eq 0 ]; then
    print_info "Docker container started successfully."
    sudo docker-compose -f "${DOCKER_COMPOSE_FILE_NAME}" ps
else
    print_error "Failed to start Docker container. Check logs using 'docker logs sla_monitor_central_app'."
    exit 1
fi

print_info "--------------------------------------------------------------------"
SERVER_IP=$(hostname -I | awk '{print $1}')
print_info "CENTRAL Dashboard available at: http://${SERVER_IP:-<your_server_ip>}/"
print_info "Setup finished."
print_info "--------------------------------------------------------------------"