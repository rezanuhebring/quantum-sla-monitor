#!/bin/bash
# secure_setup.sh - A dedicated, interactive script to set up Nginx and Let's Encrypt.
# FINAL PRODUCTION VERSION - Uses a robust netstat check to prevent false positive port conflicts.

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
SECURE_COMPOSE_FILE="secure_docker-compose.yml"

# --- Main Setup Logic ---
print_info "Starting Secure Reverse Proxy Setup..."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- Step 1: Precise Port Conflict Check (The Safety Check) ---
print_info "Checking if required ports (80, 443) are available for validation..."
# *** FIX: Use a more reliable netstat command to prevent false positives on ports like 8080 ***
if sudo netstat -tuln | grep -qE ':80\s|:443\s'; then
    print_error "One or more required ports (80, 443) are already in use."
    print_warn "Please stop any other web servers or Docker containers using these ports and run this script again."
    print_warn "Conflicting services detected:"
    sudo netstat -tulpn | grep -E ':80\s|:443\s'
    exit 1
else
    print_success "Ports 80 and 443 are available."
fi

# --- Step 2: Gather User Input ---
read -p "Enter the domain name that points to this server (e.g., sla.yourcompany.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty. Aborting."; exit 1; fi
read -p "Enter your email address (for Let's Encrypt renewal notices): " EMAIL_ADDRESS
if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty. Aborting."; exit 1; fi
read -p "Enter the public HTTPS port you want to use [8443]: " HTTPS_PORT; HTTPS_PORT=${HTTPS_PORT:-8443}
read -p "Enter the public HTTP port for redirects [8080]: " HTTP_PORT; HTTP_PORT=${HTTP_PORT:-8080}
print_info "Using ports: HTTP=${HTTP_PORT}, HTTPS=${HTTPS_PORT}"

# --- Step 3: Dependencies & Directories ---
sudo systemctl stop apache2 >/dev/null 2>&1 && sudo systemctl disable apache2 >/dev/null 2>&1
print_info "Ensuring Certbot is installed..."
sudo apt-get update -y && sudo apt-get install -y certbot || { print_error "Certbot installation failed."; exit 1; }
print_info "Creating directories..."
sudo mkdir -p "${HOST_NGINX_CONF_DIR}" "${HOST_LETSENCRYPT_DIR}" "${HOST_CERTBOT_WEBROOT_DIR}"

# --- Step 4: Let's Encrypt Challenge ---
print_warn "To obtain an SSL certificate, a service MUST be temporarily available on standard port 80."
# Using Certbot's standalone authenticator is simpler and more reliable than the webroot method with Docker.
print_info "Requesting Let's Encrypt certificate for ${DOMAIN_NAME} using standalone mode..."
sudo certbot certonly --standalone -d "${DOMAIN_NAME}" --email "${EMAIL_ADDRESS}" --agree-tos --no-eff-email --force-renewal --http-01-port 80
if [ $? -ne 0 ]; then
    print_error "Certbot failed. Please check that your domain name points to this server's IP and port 80 is not blocked by a firewall."
    exit 1
fi
print_success "Certificate obtained successfully!"

# --- Step 5: Create Final Nginx and Docker Compose Configurations ---
print_info "Generating final Nginx and Docker Compose configurations..."
# Create the final Nginx config with SSL and custom port redirect
sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    location / { return 301 https://\$host:${HTTPS_PORT}\$request_uri; }
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

# Create the final docker-compose.yml with your custom ports
tee "${SECURE_COMPOSE_FILE}" > /dev/null <<'EOF'
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
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - /srv/sla_monitor/central_app_data/nginx:/etc/nginx/conf.d:ro
      - /srv/sla_monitor/central_app_data/letsencrypt:/etc/letsencrypt:ro
    networks:
      - sla_network
    depends_on: [app]
networks:
  sla_network:
    driver: bridge
EOF

# --- Step 6: Launch the Full Secure Stack ---
print_info "Launching the full application stack on your custom ports..."
# Stop any previous instances of this specific stack before starting.
sudo docker-compose -f "${SECURE_COMPOSE_FILE}" down --volumes >/dev/null 2>&1
sudo docker-compose -f "${SECURE_COMPOSE_FILE}" up --build -d

if [ $? -eq 0 ]; then
    print_success "Setup is complete!"
    print_warn "Your dashboard is now secured with an SSL certificate."
    print_warn "You MUST include the port number in the URL to access it."
    print_success "Access it at: https://${DOMAIN_NAME}:${HTTPS_PORT}"
    sudo docker-compose -f "${SECURE_COMPOSE_FILE}" ps
else
    print_error "Failed to start the final Docker stack. Please check logs."
    exit 1
fi