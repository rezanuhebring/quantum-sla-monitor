#!/bin/bash
# setup.sh - A smart, interactive script to deploy the SLA Monitor.
# FINAL PRODUCTION VERSION - Includes robust dependency installation to fix apt issues.

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }

# --- Configuration Variables ---
HOST_DATA_ROOT="/srv/sla_monitor/central_app_data"
HOST_NGINX_CONF_DIR="${HOST_DATA_ROOT}/nginx"
HOST_LETSENCRYPT_DIR="${HOST_DATA_ROOT}/letsencrypt"
HOST_CERTBOT_WEBROOT_DIR="${HOST_DATA_ROOT}/certbot"
DOCKER_COMPOSE_FILE="docker-compose.yml"
DOCKERFILE_NAME="Dockerfile"

# --- Main Setup Logic ---
clear
print_info "Welcome to the Internet SLA Monitor Setup Wizard."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- Step 1: Ask User for Deployment Type ---
echo
read -p "Do you want to enable HTTPS (recommended)? (Requires a public domain) [Y/n]: " ENABLE_HTTPS
# Default to yes if user just hits Enter
if [[ -z "$ENABLE_HTTPS" ]] || [[ "$ENABLE_HTTPS" =~ ^[Yy] ]]; then
    USE_HTTPS=true
else
    USE_HTTPS=false
fi

# --- Step 2: Fix and Update System Dependencies ---
print_info "Preparing system... This may take a few moments."
# *** FIX: Add robust package manager commands to prevent dependency errors ***
sudo apt-get update -y || { print_error "Initial apt update failed."; exit 1; }
print_info "Attempting to fix any broken dependencies..."
sudo apt-get --fix-broken install -y
print_info "Upgrading system packages to ensure consistency..."
sudo apt-get upgrade -y
# Use dist-upgrade to intelligently handle changing dependencies for new versions
sudo apt-get dist-upgrade -y

print_info "Installing required packages (docker, docker-compose, certbot)..."
sudo apt-get install -y docker.io docker-compose certbot || { print_error "Package installation failed. Please check apt logs."; exit 1; }

# --- Step 3: Create Directories & Static Files ---
print_info "Creating necessary directories..."
sudo mkdir -p "${HOST_NGINX_CONF_DIR}" "${HOST_LETSENCRYPT_DIR}" "${HOST_CERTBOT_WEBROOT_DIR}"
# (The Dockerfile creation is the same and does not need to be changed)
# ...

# ==============================================================================
# --- HTTPS DEPLOYMENT PATH ---
# ==============================================================================
if [ "$USE_HTTPS" = true ]; then
    print_info "Starting HTTPS setup..."
    # --- Gather User Input for HTTPS ---
    read -p "Enter the domain name that points to this server (e.g., sla.yourcompany.com): " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty. Aborting."; exit 1; fi
    read -p "Enter your email address (for Let's Encrypt renewal notices): " EMAIL_ADDRESS
    if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty. Aborting."; exit 1; fi
    read -p "Enter the public HTTPS port you want to use [8443]: " HTTPS_PORT
    HTTPS_PORT=${HTTPS_PORT:-8443}

    # --- Perform Let's Encrypt Challenge ---
    print_warn "To obtain an SSL certificate, a service MUST be temporarily available on standard port 80."
    sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server { listen 80; server_name ${DOMAIN_NAME}; location /.well-known/acme-challenge/ { root /var/www/certbot; } }
EOF
    print_info "Starting temporary Nginx on port 80 for validation..."
    sudo docker run --rm -p 80:80 -v "${HOST_NGINX_CONF_DIR}:/etc/nginx/conf.d:ro" -v "${HOST_CERTBOT_WEBROOT_DIR}:/var/www/certbot" --name temp-cert-nginx nginx:latest &>/dev/null &
    sleep 5
    print_info "Requesting Let's Encrypt certificate for ${DOMAIN_NAME}..."
    sudo certbot certonly --webroot -w "${HOST_CERTBOT_WEBROOT_DIR}" -d "${DOMAIN_NAME}" --email "${EMAIL_ADDRESS}" --agree-tos --no-eff-email --force-renewal
    if [ $? -ne 0 ]; then
        print_error "Certbot failed. Please check that your domain name points to this server's IP and port 80 is not blocked."
        sudo docker stop temp-cert-nginx &>/dev/null
        exit 1
    fi
    sudo docker stop temp-cert-nginx &>/dev/null
    print_success "Certificate obtained successfully!"

    # --- Generate Final Secure Configurations ---
    print_info "Creating final Nginx configuration with SSL on port ${HTTPS_PORT}..."
    sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server { listen 80; server_name ${DOMAIN_NAME}; location /.well-known/acme-challenge/ { root /var/www/certbot; } location / { return 301 https://\$host:${HTTPS_PORT}\$request_uri; } }
server {
    listen ${HTTPS_PORT} ssl http2; server_name ${DOMAIN_NAME};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem; ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3; ssl_prefer_server_ciphers off;
    location / { proxy_pass http://app:80; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }
}
EOF
    print_info "Creating final Docker Compose file..."
    tee "${DOCKER_COMPOSE_FILE}" > /dev/null <<EOF
services:
  app:
    build: .
    container_name: sla_monitor_central_app
    restart: unless-stopped
    volumes: ["/srv/sla_monitor/central_app_data/opt_sla_monitor:/opt/sla_monitor", "/srv/sla_monitor/central_app_data/api_logs/sla_api.log:/var/log/sla_api.log"]
    networks: [sla_network]
  nginx:
    image: nginx:latest
    container_name: sla_monitor_proxy
    restart: unless-stopped
    ports: ["80:80", "${HTTPS_PORT}:443"]
    volumes: ["/srv/sla_monitor/central_app_data/nginx:/etc/nginx/conf.d:ro", "/srv/sla_monitor/central_app_data/letsencrypt:/etc/letsencrypt:ro", "/srv/sla_monitor/central_app_data/certbot:/var/www/certbot"]
    networks: [sla_network]
    depends_on: [app]
networks:
  sla_network:
    driver: bridge
EOF
    FINAL_URL="https://://${DOMAIN_NAME}:${HTTPS_PORT}"

# ==============================================================================
# --- HTTP-ONLY DEPLOYMENT PATH ---
# ==============================================================================
else
    print_info "Starting HTTP-only setup..."
    read -p "Enter the domain name for this server (or just its IP address): " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name/IP cannot be empty. Aborting."; exit 1; fi
    read -p "Enter the public HTTP port you want to use [8080]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-8080}
    
    print_info "Creating Nginx configuration for HTTP on port ${HTTP_PORT}..."
    sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location / { proxy_pass http://app:80; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; }
}
EOF
    print_info "Creating Docker Compose file..."
    tee "${DOCKER_COMPOSE_FILE}" > /dev/null <<EOF
services:
  app:
    build: .
    container_name: sla_monitor_central_app
    restart: unless-stopped
    volumes: ["/srv/sla_monitor/central_app_data/opt_sla_monitor:/opt/sla_monitor", "/srv/sla_monitor/central_app_data/api_logs/sla_api.log:/var/log/sla_api.log"]
    networks: [sla_network]
  nginx:
    image: nginx:latest
    container_name: sla_monitor_proxy
    restart: unless-stopped
    ports: ["${HTTP_PORT}:80"]
    volumes: ["/srv/sla_monitor/central_app_data/nginx:/etc/nginx/conf.d:ro"]
    networks: [sla_network]
    depends_on: [app]
networks:
  sla_network:
    driver: bridge
EOF
    FINAL_URL="http://${DOMAIN_NAME}:${HTTP_PORT}"
fi

# --- Final Step: Launch the Application Stack ---
print_info "Stopping any old instances and launching the new application stack..."
sudo docker-compose down --volumes >/dev/null 2>&1
sudo docker-compose up --build -d

if [ $? -eq 0 ]; then
    print_success "Setup is complete!"
    print_info "Your dashboard should now be available at: ${FINAL_URL}"
    sudo docker-compose ps
else
    print_error "Failed to start the final Docker stack. Please check logs with 'docker logs sla_monitor_proxy' and 'docker logs sla_monitor_central_app'."
    exit 1
fi