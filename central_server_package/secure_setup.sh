#!/bin/bash
# secure_setup.sh - A dedicated, interactive script to set up Nginx and Let's Encrypt.
# FINAL SAFE & CLEVER VERSION - Detects port conflicts and provides clear instructions.

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

# --- Step 1: Intelligent Port Conflict Check ---
print_info "Checking if required ports (80, 443) are available..."
PORT_80_IN_USE=$(sudo ss -tulpn | grep ':80')
PORT_443_IN_USE=$(sudo ss -tulpn | grep ':443')
CONFLICT_FOUND=false

if [ -n "$PORT_80_IN_USE" ]; then
    print_error "Port 80 is already in use by the following process:"
    echo "    $PORT_80_IN_USE"
    CONFLICT_FOUND=true
fi
if [ -n "$PORT_443_IN_USE" ]; then
    print_error "Port 443 is already in use by the following process:"
    echo "    $PORT_443_IN_USE"
    CONFLICT_FOUND=true
fi

if [ "$CONFLICT_FOUND" = true ]; then
    echo
    print_warn "This is likely because your original SLA monitor setup is running, or another web server is active."
    print_warn "To resolve this, you must stop the conflicting service."
    echo
    print_info "Common Solutions:"
    if [[ "$PORT_80_IN_USE" == *"docker-proxy"* ]]; then
        print_info " -> It looks like a Docker container is using the port. Stop it by running:"
        print_warn "    sudo docker-compose down --volumes"
    elif [[ "$PORT_80_IN_USE" == *"apache2"* ]]; then
        print_info " -> It looks like the host's Apache service is running. Stop and disable it by running:"
        print_warn "    sudo systemctl stop apache2 && sudo systemctl disable apache2"
    fi
    echo
    print_error "Aborting setup. Please resolve the port conflict and run this script again."
    exit 1
else
    print_success "Ports 80 and 443 are available."
fi

# --- Step 2: Gather User Input ---
print_info "This script will configure Nginx with a free SSL certificate from Let's Encrypt."
read -p "Enter the domain name that points to this server (e.g., sla.soemath.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty. Aborting."; exit 1; fi

read -p "Enter your email address (for Let's Encrypt renewal notices): " EMAIL_ADDRESS
if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty. Aborting."; exit 1; fi

# --- Step 3: Install Certbot ---
print_info "Ensuring Certbot is installed..."
sudo apt-get update -y && sudo apt-get install -y certbot || { print_error "Certbot installation failed."; exit 1; }

# --- Step 4: Create Directories & Temporary Nginx Config ---
print_info "Creating directories for Nginx and Certbot..."
sudo mkdir -p "${HOST_NGINX_CONF_DIR}" "${HOST_LETSENCRYPT_DIR}" "${HOST_CERTBOT_WEBROOT_DIR}"
print_info "Generating temporary Nginx configuration for SSL challenge..."
sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server {
    listen 80; server_name ${DOMAIN_NAME};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

# --- Step 5: Run Nginx Temporarily to Obtain Certificate ---
print_info "Starting temporary Nginx service to obtain certificate..."
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
    listen 80; server_name ${DOMAIN_NAME};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2; server_name ${DOMAIN_NAME};
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
    print_error "Failed to start the final Docker stack. Please check logs."; exit 1;
fi