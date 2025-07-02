#!/bin/bash
# secure_uninstall.sh - A dedicated, safe script to remove ONLY the Nginx proxy setup.
# This script will not touch the core application data (database, logs).

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

# --- Main Uninstallation Logic ---
print_warn "This script will stop and remove the SECURE (Nginx) reverse proxy setup."
print_warn "Your core application data (database and logs) will NOT be affected."
echo
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# 1. Stop and remove the Docker containers defined in the secure compose file
print_info "Stopping and removing Nginx and application containers defined in ${SECURE_COMPOSE_FILE}..."
if [ -f "${SECURE_COMPOSE_FILE}" ]; then
    # Use docker-compose down which handles containers and networks for this specific file
    sudo docker-compose -f "${SECURE_COMPOSE_FILE}" down --volumes
    print_info "Secure Docker stack has been taken down."
else
    print_error "${SECURE_COMPOSE_FILE} not found. Cannot proceed."
    exit 1
fi
echo

# 2. Ask for confirmation before deleting Nginx and SSL certificate data
print_warn "The next step will PERMANENTLY DELETE your Nginx configuration and SSL certificates."
read -p "Are you sure you want to delete the proxy configuration files? [y/N]: " confirm_delete_nginx

if [[ "$confirm_delete_nginx" =~ ^[Yy] ]]; then
    print_info "Deleting Nginx and Let's Encrypt data directories..."
    sudo rm -rf "${HOST_NGINX_CONF_DIR}" "${HOST_LETSENCRYPT_DIR}" "${HOST_CERTBOT_WEBROOT_DIR}"
    print_success "Proxy configuration and certificate data deleted."
else
    print_info "Skipping deletion of proxy files."
fi
echo

# 3. Optionally uninstall Certbot
print_warn "You can also uninstall Certbot from this system."
print_warn "Only do this if you are not using it for other websites on this server."
read -p "Would you like to UNINSTALL Certbot? [y/N]: " confirm_uninstall_certbot

if [[ "$confirm_uninstall_certbot" =~ ^[Yy] ]]; then
    print_info "Uninstalling Certbot package..."
    sudo apt-get purge -y certbot
    sudo apt-get autoremove -y
    print_success "Certbot has been uninstalled."
else
    print_info "Skipping Certbot uninstallation."
fi
echo

print_success "Secure proxy uninstallation finished."
print_info "Your system is now clean and ready for another attempt, or to run the original, non-proxied application."