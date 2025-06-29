#!/bin/bash
# setup.sh - A smart, interactive script to deploy the SLA Monitor.
# Can deploy with a standard HTTP proxy or a secure HTTPS proxy with Let's Encrypt.

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
DOCKER_COMPOSE_FILE="docker-compose.yml" # This script will now generate the main compose file.

# --- Main Setup Logic ---
clear
print_info "Welcome to the Internet SLA Monitor Setup Wizard."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- Step 1: Ask User for Deployment Type ---
echo
print_warn "This script can deploy the dashboard in two ways:"
print_warn "1. HTTP (Standard): Fast and simple, for use inside a trusted network."
print_warn "2. HTTPS (Secure): Professional setup with a free SSL certificate from Let's Encrypt."
echo
read -p "Do you want to enable HTTPS? (Requires a public domain name) [y/N]: " ENABLE_HTTPS

# --- Step 2: Install Base Dependencies & Create Dirs ---
print_info "Installing required packages (docker, docker-compose, etc.)..."
sudo apt-get update -y && sudo apt-get install -y docker.io docker-compose >/dev/null || { print_error "Package installation failed."; exit 1; }
print_info "Creating necessary directories..."
sudo mkdir -p "${HOST_NGINX_CONF_DIR}" "${HOST_LETSENCRYPT_DIR}" "${HOST_CERTBOT_WEBROOT_DIR}"
# This Dockerfile is required for both setups
tee "./${DOCKERFILE_NAME}" > /dev/null <<'EOF_DOCKERFILE'
FROM php:8.2-apache AS builder
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev libzip-dev zlib1g-dev && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN docker-php-ext-install -j$(nproc) pdo pdo_sqlite zip
FROM php:8.2-apache
COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
RUN apt-get update && apt-get install -y --no-install-recommends sqlite3 curl jq bc git iputils-ping dnsutils procps nano less ca-certificates gnupg && \
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash && \
    apt-get install -y --no-install-recommends speedtest && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN docker-php-ext-enable pdo pdo_sqlite zip && a2enmod rewrite headers ssl expires
WORKDIR /var/www/html/sla_status
COPY ./app/ .
RUN chown -R www-data:www-data /var/www/html/sla_status && find /var/www/html/sla_status -type d -exec chmod 755 {} \; && find /var/www/html/sla_status -type f -exec chmod 644 {} \;
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD curl -f http://localhost/index.html || exit 1
EOF_DOCKERFILE

# ==============================================================================
# --- HTTPS DEPLOYMENT PATH ---
# ==============================================================================
if [[ "$ENABLE_HTTPS" =~ ^[Yy] ]]; then
    print_info "Starting HTTPS setup..."
    # --- Gather User Input for HTTPS ---
    read -p "Enter the domain name that points to this server (e.g., sla.yourcompany.com): " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty. Aborting."; exit 1; fi
    read -p "Enter your email address (for Let's Encrypt renewal notices): " EMAIL_ADDRESS
    if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty. Aborting."; exit 1; fi
    read -p "Enter the public HTTPS port you want to use [8443]: " HTTPS_PORT
    HTTPS_PORT=${HTTPS_PORT:-8443}

    # --- Install Certbot & Perform Challenge ---
    print_info "Ensuring Certbot is installed..."
    sudo apt-get install -y certbot >/dev/null || { print_error "Certbot installation failed."; exit 1; }
    
    # Create a temporary Nginx config for the challenge on standard port 80
    sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server { listen 80; server_name ${DOMAIN_NAME}; location /.well-known/acme-challenge/ { root /var/www/certbot; } }
EOF
    # Start a temporary Nginx container just for the challenge
    print_info "Starting temporary Nginx on port 80 for validation..."
    sudo docker run --rm -p 80:80 -v "${HOST_NGINX_CONF_DIR}:/etc/nginx/conf.d:ro" -v "${HOST_CERTBOT_WEBROOT_DIR}:/var/www/certbot" --name temp-cert-nginx nginx:latest &>/dev/null &
    sleep 5 # Give Nginx a moment to start

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
# This server block redirects any stray HTTP traffic to your custom HTTPS port
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location / { return 301 https://\$host:${HTTPS_PORT}\$request_uri; }
}
# This is the main server block for your secure application
server {
    listen ${HTTPS_PORT} ssl http2;
    server_name ${DOMAIN_NAME};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    location / {
        proxy_pass http://app:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
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
    FINAL_URL="https://${DOMAIN_NAME}:${HTTPS_PORT}"

# ==============================================================================
# --- HTTP-ONLY DEPLOYMENT PATH ---
# ==============================================================================
else
    print_info "Starting HTTP-only setup..."
    # --- Gather User Input for HTTP ---
    read -p "Enter the domain name for this server (or just its IP address): " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name/IP cannot be empty. Aborting."; exit 1; fi
    read -p "Enter the public HTTP port you want to use [8080]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-8080}
    
    # --- Generate Simple HTTP Configurations ---
    print_info "Creating Nginx configuration for HTTP on port ${HTTP_PORT}..."
    sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server {
    listen 80; # Nginx inside the container always listens on port 80
    server_name ${DOMAIN_NAME};
    location / {
        proxy_pass http://app:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
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