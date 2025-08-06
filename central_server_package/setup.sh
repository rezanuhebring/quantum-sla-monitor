#!/bin/bash
# setup.sh - UNIFIED SCRIPT FOR PRODUCTION & DEVELOPMENT
# Handles fresh installs and data-preserving migrations for both secure
# production environments (Nginx+SSL) and simple development setups.

# --- Configuration Variables ---
APP_SOURCE_SUBDIR="app"
PROJECT_DIR=$(pwd) # Assumes script is run from the project root

# Service Names
APP_SERVICE_NAME="sla_monitor_central_app"
NGINX_SERVICE_NAME="nginx"

# Host Data Paths
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
print_info "Starting Internet SLA Monitor Setup..."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- Step 0: Choose Environment ---
print_info "Select the environment you want to set up:"
select ENV_TYPE in "production" "development"; do
    case $ENV_TYPE in
        production ) print_info "Selected PRODUCTION environment. This will set up a secure server with Nginx and Let\'s Encrypt SSL."; break;;
        development ) print_info "Selected DEVELOPMENT environment. This will set up a simple server on port 8080 without SSL."; break;;
        * ) echo "Invalid option. Please enter 1 for production or 2 for development.";;
    esac
done


# --- Step 1: Detect Mode (Fresh Install vs. Migration) ---
MIGRATION_MODE=false
if [ -d "${HOST_DATA_ROOT}" ]; then
    print_warn "Existing data found at ${HOST_DATA_ROOT}."
    print_warn "Entering MIGRATION mode. Your data will be preserved."
    MIGRATION_MODE=true
    
    # If any old container is running, stop it gracefully before proceeding.
    # -- FIX APPLIED HERE --
    if [[ -n "$(docker ps -q -f name=^/${APP_SERVICE_NAME}$")" || -n "$(docker ps -q -f name=^/${NGINX_SERVICE_NAME}$")" ]]; then
        print_info "Stopping old running container(s)..."
        # We need a docker-compose.yml to exist to run down
        if [ -f "${DOCKER_COMPOSE_FILE_NAME}" ]; then
             sudo docker-compose down
        else
             # Fallback for very old setups
             sudo docker stop "${APP_SERVICE_NAME}" "${NGINX_SERVICE_NAME}" 2>/dev/null
             sudo docker rm "${APP_SERVICE_NAME}" "${NGINX_SERVICE_NAME}" 2>/dev/null
        fi
        print_info "Old container(s) stopped."
    fi
else
    print_info "No existing data found. Proceeding with a FRESH INSTALLATION."
fi

# --- Step 2: Gather User Input (if Production) ---
if [ "$ENV_TYPE" = "production" ]; then
    print_info "This script will configure a secure setup using Nginx and Let's Encrypt."
    read -p "Enter the domain name that points to this server (e.g., host.domain.com): " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty for production setup. Aborting."; exit 1; fi

    read -p "Enter your email address (for Let\'s Encrypt renewal notices): " EMAIL_ADDRESS
    if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty for production setup. Aborting."; exit 1; fi
fi

# --- Step 3: Install System Dependencies ---
print_info "Updating package lists and checking dependencies..."
sudo apt-get update -y || { print_error "Apt update failed."; exit 1; }

# Install Docker
if ! command -v docker &> /dev/null; then
    print_info "Installing Docker..."
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common jq && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - && sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y && sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io || { print_error "Docker installation failed"; exit 1; }
    sudo systemctl start docker && sudo systemctl enable docker
else
    print_info "Docker is already installed."
fi

# Install Docker Compose
if ! command -v docker-compose &> /dev/null; then
    print_info "Installing Docker Compose..."
    LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    [ -z "$LATEST_COMPOSE_VERSION" ] && LATEST_COMPOSE_VERSION="v2.24.6"
    sudo curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose || { print_error "Docker Compose download failed"; exit 1; }
else
    print_info "Docker Compose is already installed."
fi

# Install Certbot and SQLite3 (Certbot only needed for production)
if ! command -v sqlite3 &> /dev/null; then
    print_info "Installing SQLite3 client..."
    sudo apt-get install -y sqlite3
else
    print_info "SQLite3 is already installed."
fi

if [ "$ENV_TYPE" = "production" ]; then
    if ! command -v certbot &> /dev/null; then
        print_info "Installing Certbot for production setup..."
        sudo apt-get install -y certbot
    else
        print_info "Certbot is already installed."
    fi
fi


# --- Step 4: Create Directories and Configurations ---
print_info "Creating host directories and Docker configurations..."
# Host directories for persistent data
sudo mkdir -p "${HOST_OPT_SLA_MONITOR_DIR}" "${HOST_API_LOGS_DIR}" "${HOST_APACHE_LOGS_DIR}"
if [ "$ENV_TYPE" = "production" ]; then
    sudo mkdir -p "${HOST_CERTBOT_WEBROOT_DIR}"
fi
sudo touch "${HOST_API_LOGS_DIR}/sla_api.log"

# Project directories for build context
mkdir -p "${APACHE_CONFIG_DIR}"
if [ "$ENV_TYPE" = "production" ]; then
    mkdir -p "${NGINX_CONFIG_DIR}"
fi

# Create Dockerfile (same for both environments)
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

# Create docker-compose.yml based on environment
if [ "$ENV_TYPE" = "development" ]; then
    # DEVELOPMENT docker-compose
    tee "./${DOCKER_COMPOSE_FILE_NAME}" > /dev/null <<EOF_DOCKER_COMPOSE_DEV
version: '3.8'
services:
  ${APP_SERVICE_NAME}:
    build:
      context: .
      dockerfile: ${DOCKERFILE_NAME}
    container_name: ${APP_SERVICE_NAME}
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - ${HOST_OPT_SLA_MONITOR_DIR}:/opt/sla_monitor
      - ${HOST_API_LOGS_DIR}/sla_api.log:/var/log/sla_api.log
      - ${HOST_APACHE_LOGS_DIR}:/var/log/apache2
    environment:
      APACHE_LOG_DIR: /var/log/apache2
EOF_DOCKER_COMPOSE_DEV
else
    # PRODUCTION docker-compose
    tee "./${DOCKER_COMPOSE_FILE_NAME}" > /dev/null <<EOF_DOCKER_COMPOSE_PROD
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
EOF_DOCKER_COMPOSE_PROD
fi

# --- Step 5: Certificate Acquisition (Production Only) ---
if [ "$ENV_TYPE" = "production" ]; then
    print_info "Starting Phase 1: Acquiring SSL Certificate..."

    # Create temporary Nginx config for SSL challenge
    tee "./${NGINX_CONFIG_DIR}/${NGINX_CONFIG_FILE}" > /dev/null <<EOF_NGINX_TEMP
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 404; }
}
EOF_NGINX_TEMP

    print_info "Starting temporary Nginx to solve challenge..."
    sudo docker-compose up -d ${NGINX_SERVICE_NAME}
    if [ $? -ne 0 ]; then print_error "Failed to start temporary Nginx. Aborting."; sudo docker-compose down; exit 1; fi

    print_info "Requesting Let's Encrypt certificate for ${DOMAIN_NAME}..."
    sudo certbot certonly --webroot -w "${HOST_CERTBOT_WEBROOT_DIR}" -d "${DOMAIN_NAME}" --email "${EMAIL_ADDRESS}" --agree-tos --no-eff-email --force-renewal
    if [ $? -ne 0 ]; then
        print_error "Certbot failed. Check that your domain DNS record points to this server\'s IP and port 80 is not blocked."
        sudo docker-compose down
        exit 1
    fi
    print_success "Certificate obtained successfully!"

    print_info "Stopping temporary Nginx service..."
    sudo docker-compose down

    print_info "Starting Phase 2: Deploying final secure configuration..."

    # Create the final, permanent Nginx configuration
    tee "./${NGINX_CONFIG_DIR}/${NGINX_CONFIG_FILE}" > /dev/null <<EOF_NGINX_FINAL
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN_NAME};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    location / {
        proxy_pass http://${APP_SERVICE_NAME}:80;
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
        sudo curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf -o /etc/letsencrypt/options-ssl-nginx.conf
    fi
    if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
        print_info "Generating DH parameters (this may take a few minutes)..."
        sudo openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
    fi
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
fi

print_info "Setting final data permissions..."
sudo chown -R root:www-data "${HOST_DATA_ROOT}"
sudo chmod -R 770 "${HOST_DATA_ROOT}"
sudo chmod 660 "${HOST_API_LOGS_DIR}/sla_api.log"
if [ -f "${SQLITE_DB_FILE_HOST_PATH}" ]; then
    sudo chmod 660 "${SQLITE_DB_FILE_HOST_PATH}"
fi


# --- Step 7: Build and Launch Final Stack ---
print_info "Building and starting the application stack..."
sudo docker-compose up --build -d
if [ $? -eq 0 ]; then
    print_success "Deployment complete!"
    sudo docker-compose ps
    echo
    print_info "--------------------------------------------------------------------"
    if [ "$ENV_TYPE" = "production" ]; then
        print_success "Dashboard available at: https://${DOMAIN_NAME}"
    else
        SERVER_IP=$(hostname -I | awk '{print $1}')
        print_success "Dashboard available at: http://${SERVER_IP}:8080"
    fi
    print_info "--------------------------------------------------------------------"
else
    print_error "Failed to start the Docker stack. Check logs using:"
    print_error "sudo docker-compose logs"
    exit 1
fi

# --- Step 8: Schedule Certbot Renewal (Production Only) ---
if [ "$ENV_TYPE" = "production" ]; then
    if ! sudo systemctl list-timers | grep -q 'certbot.timer'; then
        print_info "Setting up Certbot renewal timer..."
        sudo certbot renew --dry-run # Test renewal
        sudo systemctl enable --now certbot.timer
        print_success "Certbot auto-renewal is now active."
    else
        print_info "Certbot renewal timer is already configured."
    fi
fi

print_info "Setup script finished."
exit 0