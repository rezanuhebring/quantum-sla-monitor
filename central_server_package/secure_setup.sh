#!/bin/bash
# secure_setup.sh - A dedicated, interactive script to set up Nginx and Let's Encrypt.
# FINAL VERSION - Fixes the destructive 'docker-compose down' bug.

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
DEFAULT_COMPOSE_FILE="docker-compose.yml"
SECURE_COMPOSE_FILE="secure_docker-compose.yml"

# --- Main Setup Logic ---
print_info "Starting Secure Reverse Proxy Setup..."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- Step 1: Gather User Input ---
print_info "This script will configure Nginx as a reverse proxy with a free SSL certificate."
read -p "Enter the domain name that points to this server (e.g., sla.yourcompany.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty. Aborting."; exit 1; fi

read -p "Enter your email address (for Let's Encrypt renewal notices): " EMAIL_ADDRESS
if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty. Aborting."; exit 1; fi

# --- Step 2: Stop Conflicting Services & Install Certbot ---
print_info "Stopping any running 'apache2' service on the host..."
sudo systemctl stop apache2 >/dev/null 2>&1
sudo systemctl disable apache2 >/dev/null 2>&1

print_info "Ensuring Certbot is installed..."
sudo apt-get update -y && sudo apt-get install -y certbot || { print_error "Certbot installation failed."; exit 1; }

# --- Step 3: Create Directories ---
print_info "Creating directories for Nginx and Certbot..."
sudo mkdir -p "${HOST_NGINX_CONF_DIR}" "${HOST_LETSENCRYPT_DIR}" "${HOST_CERTBOT_WEBROOT_DIR}"

# --- Step 4: Create Temporary Nginx Config for Challenge ---
print_info "Generating temporary Nginx configuration for SSL challenge..."
sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# --- Step 5: Stop any existing Docker setups to free up ports ---
print_info "Stopping any currently running SLA monitor containers to free up ports..."
# *** FIX: Explicitly target specific compose files to avoid destroying unrelated containers ***
if [ -f "${DEFAULT_COMPOSE_FILE}" ]; then
    print_info "-> Stopping services from '${DEFAULT_COMPOSE_FILE}'..."
    sudo docker-compose -f "${DEFAULT_COMPOSE_FILE}" down --volumes >/dev/null 2>&1
fi
if [ -f "${SECURE_COMPOSE_FILE}" ]; then
    print_info "-> Stopping services from '${SECURE_COMPOSE_FILE}' (if script is being re-run)..."
    sudo docker-compose -f "${SECURE_COMPOSE_FILE}" down --volumes >/dev/null 2>&1
fi

# --- Step 6: Run Nginx Temporarily to Obtain Certificate ---
print_info "Starting temporary Nginx service to obtain certificate..."
sudo docker-compose -f "${SECURE_COMPOSE_FILE}" up -d nginx

print_info "Requesting Let's Encrypt certificate for ${DOMAIN_NAME}..."
sudo certbot certonly --webroot -w "${HOST_CERTBOT_WEBROOT_DIR}" -d "${DOMAIN_NAME}" --email "${EMAIL_ADDRESS}" --agree-tos --no-eff-email --force-renewal
if [ $? -ne 0 ]; then
    print_error "Certbot failed. Please check that your domain name is pointing to this server's IP and that port 80 is not blocked by a firewall."
    sudo docker-compose -f "${SECURE_COMPOSE_FILE}" down
    exit 1
fi
print_success "Certificate obtained successfully!"

# --- Step 7: Create Final Nginx Config ---
print_info "Creating final Nginx configuration with SSL..."
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
    
    # Modern security settings from certbot's recommendations
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
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

# --- Step 8: Launch the Full Secure Stack ---
print_info "Launching the full application stack with SSL enabled..."
# Stop the temporary nginx service and start the full stack (app and nginx)
sudo docker-compose -f "${SECURE_COMPOSE_FILE}" up --build -d

if [ $? -eq 0 ]; then
    print_success "Setup is complete!"
    print_info "Your secure dashboard should now be available at: https://${DOMAIN_NAME}"
    sudo docker-compose -f "${SECURE_COMPOSE_FILE}" ps
else
    print_error "Failed to start the final Docker stack. Please check logs."
    exit 1
fi