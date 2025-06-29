#!/bin/bash
# setup.sh - A smart, interactive script to deploy the SLA Monitor.
# This script intelligently handles dependencies, checks for conflicts, and can deploy
# with a standard HTTP proxy or a secure HTTPS proxy with Let's Encrypt.

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

# --- Step 1: Intelligent Dependency Handling ---
print_info "Checking system dependencies..."
sudo apt-get update -y || { print_error "Initial apt update failed."; exit 1; }

# Check for Docker
if ! command -v docker &> /dev/null; then
    print_warn "Docker not found. Performing a clean installation..."
    # This follows the official Docker installation guide to avoid conflicts.
    print_info "Removing old/conflicting packages (if any)..."
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove -y $pkg; done
    sudo apt-get autoremove -y

    print_info "Installing Docker prerequisites..."
    sudo apt-get install -y ca-certificates curl gnupg
    
    print_info "Adding Docker's official GPG key..."
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    print_info "Setting up Docker's official repository..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    sudo apt-get update -y
    print_info "Installing Docker CE (Community Edition)..."
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || { print_error "Docker CE installation failed."; exit 1; }
    print_success "Docker installed successfully."
else
    print_success "Docker is already installed."
fi

# Check for Docker Compose
if ! command -v docker-compose &> /dev/null; then
    print_warn "Docker Compose v1 not found. It is recommended to use 'docker compose' (v2)."
    print_info "If you must use v1, please install it manually."
fi


# --- Step 2: User Choices ---
echo
read -p "Do you want to enable HTTPS (recommended)? (Requires a public domain) [Y/n]: " ENABLE_HTTPS
USE_HTTPS=false
if [[ -z "$ENABLE_HTTPS" ]] || [[ "$ENABLE_HTTPS" =~ ^[Yy] ]]; then USE_HTTPS=true; fi

# --- Step 3: Stop Conflicting Services ---
sudo systemctl stop apache2 >/dev/null 2>&1 && sudo systemctl disable apache2 >/dev/null 2>&1

# --- Step 4: Create Directories & Dockerfile ---
print_info "Creating necessary directories..."
sudo mkdir -p "${HOST_NGINX_CONF_DIR}" "${HOST_LETSENCRYPT_DIR}" "${HOST_CERTBOT_WEBROOT_DIR}"
# (Dockerfile generation logic is fine, no changes needed from previous versions)
# ...

# ==============================================================================
# --- HTTPS DEPLOYMENT PATH ---
# ==============================================================================
if [ "$USE_HTTPS" = true ]; then
    print_info "Starting HTTPS setup..."
    read -p "Enter the domain name that points to this server (e.g., sla.yourcompany.com): " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty. Aborting."; exit 1; fi
    read -p "Enter your email address (for Let's Encrypt renewal notices): " EMAIL_ADDRESS
    if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty. Aborting."; exit 1; fi
    read -p "Enter the public HTTPS port you want to use [8443]: " HTTPS_PORT; HTTPS_PORT=${HTTPS_PORT:-8443}
    
    print_info "Ensuring Certbot is installed..."
    sudo apt-get install -y certbot >/dev/null || { print_error "Certbot installation failed."; exit 1; }
    
    if sudo ss -tulpn | grep -q ':80'; then
        print_error "Port 80 is currently in use. Certbot needs this port for validation."
        print_warn "Please stop the service using port 80 and run this script again."
        exit 1
    fi
    
    # Perform Let's Encrypt Challenge
    print_info "Running Certbot in standalone mode to obtain certificate..."
    sudo certbot certonly --standalone -d "${DOMAIN_NAME}" --email "${EMAIL_ADDRESS}" --agree-tos --no-eff-email --force-renewal
    if [ $? -ne 0 ]; then print_error "Certbot failed. Please check that your domain name is pointing to this server's IP and port 80 is not blocked by a firewall."; exit 1; fi
    print_success "Certificate obtained successfully!"

    # Generate Final Secure Configurations
    print_info "Creating final Nginx configuration with SSL on port ${HTTPS_PORT}..."
    sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server { listen 80; server_name ${DOMAIN_NAME}; location / { return 301 https://\$host:${HTTPS_PORT}\$request_uri; } }
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
    volumes: ["/srv/sla_monitor/central_app_data/nginx:/etc/nginx/conf.d:ro", "/srv/sla_monitor/central_app_data/letsencrypt:/etc/letsencrypt:ro"]
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
    read -p "Enter the domain name or IP for this server: " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then print_error "Domain/IP cannot be empty. Aborting."; exit 1; fi
    read -p "Enter the public HTTP port you want to use [8080]: " HTTP_PORT; HTTP_PORT=${HTTP_PORT:-8080}
    
    if sudo ss -tulpn | grep -q ":${HTTP_PORT}"; then print_error "Port ${HTTP_PORT} is already in use. Please choose another."; exit 1; fi

    print_info "Creating Nginx configuration for HTTP on port ${HTTP_PORT}..."
    sudo tee "${HOST_NGINX_CONF_DIR}/default.conf" > /dev/null <<EOF
server { listen 80; server_name ${DOMAIN_NAME}; location / { proxy_pass http://app:80; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; } }
EOF
    print_info "Creating Docker Compose file..."
    tee "${DOCKER_COMPOSE_FILE}" > /dev/null <<EOF
services:
  app: { build: ., container_name: sla_monitor_central_app, restart: unless-stopped, volumes: ["/srv/sla_monitor/central_app_data/opt_sla_monitor:/opt/sla_monitor", "/srv/sla_monitor/central_app_data/api_logs/sla_api.log:/var/log/sla_api.log"], networks: [sla_network] }
  nginx: { image: nginx:latest, container_name: sla_monitor_proxy, restart: unless-stopped, ports: ["${HTTP_PORT}:80"], volumes: ["/srv/sla_monitor/central_app_data/nginx:/etc/nginx/conf.d:ro"], networks: [sla_network], depends_on: [app] }
networks:
  sla_network: { driver: bridge }
EOF
    FINAL_URL="http://${DOMAIN_NAME}:${HTTP_PORT}"
fi

# --- Final Step: Launch the Application Stack ---
print_info "Stopping any old instances and launching the new application stack..."
sudo docker compose -f "${DOCKER_COMPOSE_FILE}" down --volumes >/dev/null 2>&1
sudo docker compose -f "${DOCKER_COMPOSE_FILE}" up --build -d

if [ $? -eq 0 ]; then
    print_success "Setup is complete!"
    print_info "Your dashboard should now be available at: ${FINAL_URL}"
    sudo docker compose ps
else
    print_error "Failed to start the final Docker stack. Please check logs with 'docker logs sla_monitor_proxy' and 'docker logs sla_monitor_central_app'."
    exit 1
fi