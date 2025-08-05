#!/bin/bash
# setup.sh - UNIFIED FINAL PRODUCTION SCRIPT
# Handles both fresh installs and seamless, data-preserving migration
# to a secure Nginx + App container architecture.

# --- Configuration Variables ---
APP_SOURCE_SUBDIR="app"
PROJECT_DIR=$(pwd) # Assumes script is run from the project root

# Service Names (to avoid hardcoding)
APP_SERVICE_NAME="sla_monitor_central_app"
NGINX_SERVICE_NAME="nginx"

# Host Data Paths (for data persistence)
HOST_DATA_ROOT="/srv/sla_monitor/central_app_data"
HOST_OPT_SLA_MONITOR_DIR="${HOST_DATA_ROOT}/opt_sla_monitor"
HOST_API_LOGS_DIR="${HOST_DATA_ROOT}/api_logs"
HOST_APACHE_LOGS_DIR="${HOST_DATA_ROOT}/apache_logs"
HOST_CERTBOT_WEBROOT_DIR="${HOST_DATA_ROOT}/certbot-webroot" # For SSL challenge

# Project File Names
DOCKER_COMPOSE_FILE_NAME="docker-compose.yml"
DOCKERFILE_NAME="Dockerfile"
APACHE_CONFIG_DIR="docker/apache"
APACHE_CONFIG_FILE="000-default.conf"
NGINX_CONFIG_DIR="nginx/conf"
NGINX_CONFIG_FILE="default.conf"
SQLITE_DB_FILE_NAME="central_sla_data.sqlite"
SQLITE_DB_FILE_HOST_PATH="${HOST_OPT_SLA_MONITOR_DIR}/${SQLITE_DB_FILE_NAME}"

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }

# --- Main Setup Logic ---
clear
print_info "Starting UNIFIED Internet SLA Monitor Setup..."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- Step 0: Detect Mode (Fresh Install vs. Migration) ---
MIGRATION_MODE=false
if [ -d "${HOST_DATA_ROOT}" ]; then
    print_warn "Existing data found at ${HOST_DATA_ROOT}."
    print_warn "Entering MIGRATION mode. Your data will be preserved."
    MIGRATION_MODE=true
    
    # If old container is running, stop it gracefully before proceeding.
    if [ "$(docker ps -q -f name=^/${APP_SERVICE_NAME}$)" ]; then
        print_info "Stopping the old running container..."
        # We need the old docker-compose.yml to exist to run down
        if [ -f "${DOCKER_COMPOSE_FILE_NAME}" ]; then
             sudo docker-compose down
        else
             sudo docker stop "${APP_SERVICE_NAME}" && sudo docker rm "${APP_SERVICE_NAME}"
        fi
        print_info "Old container stopped."
    fi
else
    print_info "No existing data found. Proceeding with a FRESH INSTALLATION."
fi

# --- Step 1: Gather User Input for Secure Setup ---
print_info "This script will configure a secure setup using Nginx and Let's Encrypt."
read -p "Enter the domain name that points to this server (e.g., host.domain.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty. Aborting."; exit 1; fi

read -p "Enter your email address (for Let's Encrypt renewal notices): " EMAIL_ADDRESS
if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty. Aborting."; exit 1; fi


# --- Step 2: Install System Dependencies ---
print_info "Updating package lists and checking dependencies..."
sudo apt-get update -y || { print_error "Apt update failed."; exit 1; }

# Install Docker
if ! command -v docker &> /dev/null; then
    print_info "Installing Docker...";
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common jq && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - && sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y && sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io || { print_error "Docker installation failed"; exit 1; }
    sudo systemctl start docker && sudo systemctl enable docker
else
    print_info "Docker is already installed."
fi

# Install Docker Compose
if ! command -v docker-compose &> /dev/null; then
    print_info "Installing Docker Compose...";
    LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    [ -z "$LATEST_COMPOSE_VERSION" ] && LATEST_COMPOSE_VERSION="v2.24.6"
    sudo curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose || { print_error "Docker Compose download failed"; exit 1; }
else
    print_info "Docker Compose is already installed."
fi

# Install Certbot and SQLite3
if ! command -v certbot &> /dev/null || ! command -v sqlite3 &> /dev/null; then
    print_info "Installing Certbot and SQLite3 client..."
    sudo apt-get install -y certbot sqlite3
else
    print_info "Certbot and SQLite3 are already installed."
fi


# --- Step 3: Create Directories and Configurations ---
print_info "Creating host directories and Docker configurations..."
# Host directories for persistent data
sudo mkdir -p "${HOST_OPT_SLA_MONITOR_DIR}" "${HOST_API_LOGS_DIR}" "${HOST_APACHE_LOGS_DIR}" "${HOST_CERTBOT_WEBROOT_DIR}"
sudo touch "${HOST_API_LOGS_DIR}/sla_api.log"

# Project directories for build context
mkdir -p "${APACHE_CONFIG_DIR}" "${NGINX_CONFIG_DIR}"

# Create Dockerfile
tee "./${DOCKERFILE_NAME}" > /dev/null <<'EOF_DOCKERFILE'
FROM php:8.2-apache
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev libzip-dev zlib1g-dev sqlite3 curl jq bc git iputils-ping dnsutils && \
    docker-php-ext-install -j$(nproc) pdo pdo_sqlite zip && \
    a2enmod rewrite && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY ./docker/apache/000-default.conf /etc/apache2/sites-available/000-default.conf
WORKDIR /var/www/html
COPY ./app/ .
RUN chown -R www-data:www-data /var/www/html && chmod -R 755 /var/www/html
EXPOSE 80
EOF_DOCKERFILE

# Create Apache Config for the APP container
tee "./${APACHE_CONFIG_DIR}/${APACHE_CONFIG_FILE}" > /dev/null <<'EOF_APACHE_CONF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF_APACHE_CONF

# Create the final, two-service docker-compose.yml
tee "./${DOCKER_COMPOSE_FILE_NAME}" > /dev/null <<EOF_DOCKER_COMPOSE
version: '3.8'
services:
  ${APP_SERVICE_NAME}:
    build:
      context: .
      dockerfile: ${DOCKERFILE_NAME}
    container_name: ${APP_SERVICE_NAME}
    restart: unless-stopped
    volumes:
      - ${HOST_OPT_SLA_MONITOR_DIR}:/opt/sla_monitor
      - ${HOST_API_LOGS_DIR}/sla_api.log:/var/log/sla_api.log
      - ${HOST_APACHE_LOGS_DIR}:/var/log/apache2
    environment:
      APACHE_LOG_DIR: /var/log/apache2
    networks:
      - sla-monitor-network

  ${NGINX_SERVICE_NAME}:
    image: nginx:latest
    container_name: ${NGINX_SERVICE_NAME}
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf:/etc/nginx/conf.d
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - ${HOST_CERTBOT_WEBROOT_DIR}:/var/www/certbot
    depends_on:
      - ${APP_SERVICE_NAME}
    networks:
      - sla-monitor-network

networks:
  sla-monitor-network:
    driver: bridge
EOF_DOCKER_COMPOSE

# --- Step 4: Phased Certificate Acquisition ---
print_info "Starting Phase 1: Acquiring SSL Certificate..."

# Create temporary Nginx config for SSL challenge
tee "./${NGINX_CONFIG_DIR}/${NGINX_CONFIG_FILE}" > /dev/null <<EOF_NGINX_TEMP
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 404; } # Or redirect to a maintenance page
}
EOF_NGINX_TEMP

print_info "Starting temporary Nginx to solve challenge..."
sudo docker-compose up -d ${NGINX_SERVICE_NAME}
if [ $? -ne 0 ]; then print_error "Failed to start temporary Nginx. Aborting."; exit 1; fi

print_info "Requesting Let's Encrypt certificate for ${DOMAIN_NAME}..."
sudo certbot certonly --webroot -w "${HOST_CERTBOT_WEBROOT_DIR}" -d "${DOMAIN_NAME}" --email "${EMAIL_ADDRESS}" --agree-tos --no-eff-email --force-renewal
if [ $? -ne 0 ]; then
    print_error "Certbot failed. Please check that your domain name DNS record points to this server's IP and that port 80 is not blocked by an external firewall."
    sudo docker-compose down
    exit 1
fi
print_success "Certificate obtained successfully!"

print_info "Stopping temporary Nginx service..."
sudo docker-compose down


# --- Step 5: Final Configuration and Launch ---
print_info "Starting Phase 2: Deploying final secure configuration..."

# Create the final, permanent Nginx configuration
tee "./${NGINX_CONFIG_DIR}/${NGINX_CONFIG_FILE}" > /dev/null <<EOF_NGINX_FINAL
# Redirect all HTTP traffic to HTTPS
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location /.well-known/acme-challenge/ { root /var/www/certbot; } # For renewals
    location / { return 301 https://\$host\$request_uri; }
}
# Serve the secure application
server {
    listen 443 ssl http2;
    server_name ${DOMAIN_NAME};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf; # Recommended by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # Recommended by Certbot

    location / {
        proxy_pass http://${APP_SERVICE_NAME}:80; # Forward to the app container
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF_NGINX_FINAL

# Add Certbot's recommended SSL options if they don't exist
if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
    print_info "Downloading recommended SSL options from Certbot..."
    sudo curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > ./options-ssl-nginx.conf
    sudo mv ./options-ssl-nginx.conf /etc/letsencrypt/
fi
if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
    print_info "Generating DH parameters (this may take a few minutes)..."
    sudo openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
fi


# --- Step 6: Database & Permissions (Data-Preserving) ---
if [ "${MIGRATION_MODE}" = false ]; then
    print_info "Initializing database schema for new installation..."
    sudo touch "${SQLITE_DB_FILE_HOST_PATH}"
    sudo sqlite3 "${SQLITE_DB_FILE_HOST_PATH}" "
        PRAGMA journal_mode=WAL;
        CREATE TABLE isp_profiles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent_name TEXT NOT NULL,
            agent_identifier TEXT NOT NULL UNIQUE,
            agent_type TEXT DEFAULT 'Client',
            network_interface_to_monitor TEXT,
            sla_target_percentage REAL DEFAULT 99.9,
            rtt_degraded INTEGER DEFAULT 150,
            rtt_poor INTEGER DEFAULT 350,
            loss_degraded REAL DEFAULT 2,
            loss_poor REAL DEFAULT 10,
            ping_jitter_degraded REAL DEFAULT 30,
            ping_jitter_poor REAL DEFAULT 50,
            dns_time_degraded INTEGER DEFAULT 300,
            dns_time_poor INTEGER DEFAULT 800,
            http_time_degraded REAL DEFAULT 1.5,
            http_time_poor REAL DEFAULT 3.0,
            speedtest_dl_degraded REAL DEFAULT 50,
            speedtest_dl_poor REAL DEFAULT 20,
            speedtest_ul_degraded REAL DEFAULT 10,
            speedtest_ul_poor REAL DEFAULT 3,
            teams_webhook_url TEXT,
            alert_hostname_override TEXT,
            notes TEXT,
            is_active INTEGER DEFAULT 1,
            last_heard_from TEXT,
            last_reported_hostname TEXT,
            last_reported_source_ip TEXT
        );
        CREATE TABLE sla_metrics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            isp_profile_id INTEGER NOT NULL,
            timestamp TEXT NOT NULL,
            overall_connectivity TEXT,
            avg_rtt_ms REAL,
            avg_loss_percent REAL,
            avg_jitter_ms REAL,
            dns_status TEXT,
            dns_resolve_time_ms INTEGER,
            http_status TEXT,
            http_response_code INTEGER,
            http_total_time_s REAL,
            speedtest_status TEXT,
            speedtest_download_mbps REAL,
            speedtest_upload_mbps REAL,
            speedtest_ping_ms REAL,
            speedtest_jitter_ms REAL,
            detailed_health_summary TEXT,
            sla_met_interval INTEGER,
            FOREIGN KEY (isp_profile_id) REFERENCES isp_profiles(id) ON DELETE CASCADE,
            UNIQUE(isp_profile_id, timestamp)
        );
        CREATE INDEX IF NOT EXISTS idx_isp_profiles_agent_identifier ON isp_profiles (agent_identifier);
        CREATE INDEX IF NOT EXISTS idx_sla_metrics_timestamp ON sla_metrics (timestamp);
        CREATE INDEX IF NOT EXISTS idx_sla_metrics_isp_profile_id ON sla_metrics (isp_profile_id);
    "
else
    print_info "Existing database found. Skipping schema creation."
    # Self-healing logic for schema updates can be added here in the future.
fi

print_info "Setting final data permissions..."
sudo chown -R root:www-data "${HOST_DATA_ROOT}"
sudo chmod -R 770 "${HOST_DATA_ROOT}"
# Make specific files group-writable by the container's www-data user
sudo chmod 660 "${HOST_API_LOGS_DIR}/sla_api.log"
sudo chmod 660 "${SQLITE_DB_FILE_HOST_PATH}"


# --- Step 7: Build and Launch Final Stack ---
print_info "Building and starting the final, secure application stack..."
sudo docker-compose up --build -d
if [ $? -eq 0 ]; then
    print_success "Deployment complete!"
    sudo docker-compose ps
    echo
    print_info "--------------------------------------------------------------------"
    print_success "Dashboard available at: https://${DOMAIN_NAME}"
    print_info "--------------------------------------------------------------------"
else
    print_error "Failed to start the final Docker stack. Check logs using:"
    print_error "sudo docker-compose logs ${APP_SERVICE_NAME}"
    print_error "sudo docker-compose logs ${NGINX_SERVICE_NAME}"
    exit 1
fi