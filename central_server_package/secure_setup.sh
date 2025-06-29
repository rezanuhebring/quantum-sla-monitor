#!/bin/bash
# secure_setup.sh - FINAL PRODUCTION VERSION
# Implements the robust "Certbot Companion" pattern to definitively solve the 404 challenge error.

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }

# --- Configuration Variables ---
HOST_DATA_ROOT="/srv/sla_monitor/central_app_data"
HOST_NGINX_CONF_DIR="${HOST_DATA_ROOT}/nginx"
HOST_LETSENCRYPT_DIR="${HOST_DATA_ROOT}/letsencrypt"
HOST_CERTBOT_WEBROOT_DIR="${HOST_DATA_ROOT}/certbot" # Certbot files will be placed here on the host
COMPOSE_FILE="secure_docker-compose.yml"

# --- Main Setup Logic ---
print_info "Starting Secure Reverse Proxy Setup..."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- Step 1: Port Conflict Check ---
if sudo ss -tulpn | grep -qE ':(80|443)\s'; then
    print_error "One or more required ports (80, 443) are already in use."
    print_warn "Please stop any other web servers or Docker containers using these ports and run this script again."
    exit 1
fi

# --- Step 2: User Input ---
read -p "Enter the domain name that points to this server (e.g., sla.yourcompany.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty. Aborting."; exit 1; fi
read -p "Enter your email address (for Let's Encrypt renewal notices): " EMAIL_ADDRESS
if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty. Aborting."; exit 1; fi

# --- Step 3: Dependencies & Directories ---
sudo systemctl stop apache2 >/dev/null 2>&1 && sudo systemctl disable apache2 >/dev/null 2>&1
print_info "Ensuring Docker and Docker Compose are installed..."
sudo apt-get update -y && sudo apt-get install -y docker.io docker-compose || { print_error "Dependency installation failed."; exit 1; }
print_info "Creating directories..."
sudo mkdir -p "${HOST_NGINX_CONF_DIR}" "${HOST_LETSENCRYPT_DIR}" "${HOST_CERTBOT_WEBROOT_DIR}"

# --- Step 4: Create the Docker Compose file with all three services ---
print_info "Generating Docker Compose configuration for App, Nginx, and Certbot..."
tee "${COMPOSE_FILE}" > /dev/null <<EOF
services:
  app:
    build: { context: ., dockerfile: Dockerfile }
    container_name: sla_monitor_central_app
    restart: unless-stopped
    volumes:
      - /srv/sla_monitor/central_app_data/opt_sla_monitor:/opt/sla_monitor
      - /srv/sla_monitor/central_app_data/api_logs/sla_api.log:/var/log/sla_api.log
      - /srv/sla_monitor/central_app_data/apache_logs:/var/log/apache2
    networks:
      - sla_network

  nginx:
    image: nginx:latest
    container_name: sla_monitor_proxy
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ${HOST_NGINX_CONF_DIR}:/etc/nginx/conf.d
      - ${HOST_LETSENCRYPT_DIR}:/etc/letsencrypt
      - ${HOST_CERTBOT_WEBROOT_DIR}:/var/www/certbot
    networks:
      - sla_network
    depends_on: [app]

  certbot:
    image: certbot/certbot
    container_name: sla_monitor_certbot
    volumes:
      - ${HOST_LETSENCRYPT_DIR}:/etc/letsencrypt
      - ${HOST_CERTBOT_WEBROOT_DIR}:/var/www/certbot

networks:
  sla_network:
    driver: bridge
EOF

# --- Step 5: Obtain Certificate using the Certbot Container ---
print_info "Creating dummy certificate to allow Nginx to start..."
sudo mkdir -p "${HOST_LETSENCRYPT_DIR}/live/${DOMAIN_NAME}"
# Create a temporary self-signed cert so Nginx can start before we have a real one
sudo openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "${HOST_LETSENCRYPT_DIR}/live/${DOMAIN_NAME}/privkey.pem" \
    -out "${HOST_LETSENCRYPT_DIR}/live/${DOMAIN_NAME}/fullchain.pem" \
    -subj "/CN=localhost"

print_info "Creating Nginx configuration..."
sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    server_name ${DOMAIN_NAME};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    location / { proxy_pass http://app:80; } # A simple proxy for now
}
EOF

print_info "Starting Nginx to handle the challenge..."
sudo docker-compose -f "${COMPOSE_FILE}" up -d nginx

print_info "Requesting Let's Encrypt certificate for ${DOMAIN_NAME}..."
# Now run certbot inside its own container. It will replace the dummy certs.
sudo docker-compose -f "${COMPOSE_FILE}" run --rm certbot certonly --webroot -w /var/www/certbot --email ${EMAIL_ADDRESS} --agree-tos --no-eff-email -d ${DOMAIN_NAME} --force-renewal

if [ $? -ne 0 ]; then
    print_error "Certbot failed. Please check that your domain name points to this server's IP and port 80 is not blocked."
    sudo docker-compose -f "${COMPOSE_FILE}" down --volumes
    exit 1
fi
print_success "Certificate obtained successfully!"

# --- Step 6: Create Final Nginx Config and Launch Full Stack ---
print_info "Creating final Nginx configuration with SSL hardening..."
sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
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

print_info "Restarting Nginx and launching the full application stack..."
sudo docker-compose -f "${COMPOSE_FILE}" up --build -d --force-recreate nginx app

if [ $? -eq 0 ]; then
    print_success "Setup is complete!"
    print_info "Your secure dashboard should now be available at: https://${DOMAIN_NAME}"
    sudo docker-compose -f "${COMPOSE_FILE}" ps
else
    print_error "Failed to start the final Docker stack. Please check logs."
    exit 1
fi