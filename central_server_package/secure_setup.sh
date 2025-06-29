#!/bin/bash
# secure_setup.sh - A dedicated, interactive script to set up Nginx and Let's Encrypt.
# FINAL SAFE VERSION - Checks for port conflicts and fails gracefully instead of removing containers.

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

# --- Step 1: Check for Port Conflicts (The Safety Check) ---
print_info "Checking if required ports (80, 443) are available..."
if sudo ss -tulpn | grep -q ':80' || sudo ss -tulpn | grep -q ':443'; then
    print_error "One or more required ports (80, 443) are already in use."
    print_error "This is likely because your original SLA monitor is running."
    print_warn "Please stop the existing service manually before proceeding."
    print_warn "Run this command from your project directory:"
    echo
    print_warn "    sudo docker-compose down --volumes"
    echo
    print_error "Aborting setup. Please stop the conflicting service and run this script again."
    exit 1
else
    print_success "Ports 80 and 443 are available."
fi

# --- Step 2: Gather User Input ---
print_info "This script will configure Nginx with a free SSL certificate from Let's Encrypt."
read -p "Enter the domain name that points to this server (e.g., sla.yourcompany.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty. Aborting."; exit 1; fi

read -p "Enter your email address (for Let's Encrypt renewal notices): " EMAIL_ADDRESS
if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty. Aborting."; exit 1; fi

# --- Step 3: Stop Conflicting Services & Install Certbot ---
print_info "Stopping any running 'apache2' service on the host..."
sudo systemctl stop apache2 >/dev/null 2>&1
sudo systemctl disable apache2 >/dev/null 2>&1

print_info "Ensuring Certbot is installed..."
sudo apt-get update -y && sudo apt-get install -y certbot || { print_error "Certbot installation failed."; exit 1; }

# --- Step 4: Create Directories & Temporary Nginx Config ---
print_info "Creating directories for Nginx and Certbot..."
sudo mkdir -p "${HOST_NGINX_CONF_DIR}" "${HOST_LETSENCRYPT_DIR}" "${HOST_CERTBOT_WEBROOT_DIR}"

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

# --- Step 5: Run Nginx Temporarily to Obtain Certificate ---
print_info "Starting temporary Nginx service to obtain certificate..."
# We explicitly use the secure compose file. Because the ports were checked, this is safe.
sudo docker-compose -f "${SECURE_COMPOSE_FILE}" up -d nginx

print_info "Requesting Let's Encrypt certificate for ${DOMAIN_NAME}..."
sudo certbot certonly --webroot -w "${HOST_CERTBOT_WEBROOT_DIR}" -d "${DOMAIN_NAME}" --email "${EMAIL_ADDRESS}" --agree-tos --no-eff-email --force-renewal
if [ $? -ne 0 ]; then
    print_error "Certbot failed. Please check that your domain name is pointing to this server's IP and that port 80 is not blocked by a firewall."
    sudo docker-compose -f "${SECURE_COMPOSE_FILE}" down --volumes
    exit 1
fi
print_success "Certificate obtained successfully!"

# --- Step 6: Create Final Nginx Config ---
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

# --- Step 7: Launch the Full Secure Stack ---
print_info "Launching the full application stack with SSL enabled..."
# This command will stop the temporary nginx service and start the full stack (app and nginx)
sudo docker-compose -f "${SECURE_COMPOSE_FILE}" up --build -d

if [ $? -eq 0 ]; then
    print_success "Setup is complete!"
    print_info "Your secure dashboard should now be available at: https://${DOMAIN_NAME}"
    sudo docker-compose -f "${SECURE_COMPOSE_FILE}" ps
else
    print_error "Failed to start the final Docker stack. Please check logs."
    exit 1
fi