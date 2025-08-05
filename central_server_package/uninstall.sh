#!/bin/bash
# uninstall.sh - A safe, interactive script to remove the SLA Monitor.

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }

# --- Configuration Variables ---
HOST_DATA_ROOT="/srv/sla_monitor/central_app_data"
DOCKER_COMPOSE_FILE_NAME="docker-compose.yml"

# --- Main Uninstall Logic ---
clear
print_warn "--- SLA Monitor Uninstaller ---"
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- Step 1: Stop and Remove Docker Containers ---
print_info "Checking for running services..."
if [ -f "${DOCKER_COMPOSE_FILE_NAME}" ]; then
    print_warn "This will stop and remove all SLA Monitor containers and their networks."
    read -p "Are you sure you want to continue? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        print_info "Aborting."
        exit 0
    fi
    print_info "Stopping containers..."
    # The --volumes flag removes anonymous volumes, which is correct for a full uninstall.
    sudo docker-compose down --volumes
    print_success "Containers and networks removed."
else
    print_info "No docker-compose.yml found. Skipping container removal."
fi

# --- Step 2: Remove Project Files ---
print_info "The following project files will be removed:"
echo " - ${DOCKER_COMPOSE_FILE_NAME}"
echo " - Dockerfile"
echo " - nginx/ directory"
echo " - docker/ directory"
read -p "Proceed with deleting these files? (yes/no): " CONFIRM
if [ "$CONFIRM" == "yes" ]; then
    sudo rm -f "${DOCKER_COMPOSE_FILE_NAME}" Dockerfile
    sudo rm -rf nginx docker
    print_success "Project files removed."
else
    print_info "Skipping project file deletion."
fi

# --- Step 3: Remove Persistent Data (CRITICAL STEP) ---
if [ -d "${HOST_DATA_ROOT}" ]; then
    echo
    print_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    print_warn "!!! DANGER ZONE: You are about to delete all persistent data !!!"
    print_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    print_info "This includes the SQLite database, logs, and any certificates stored within this directory structure."
    print_info "The directory to be deleted is: ${HOST_DATA_ROOT}"
    echo
    read -p "To confirm this IRREVERSIBLE action, type the word 'delete-data': " CONFIRM_DATA
    if [ "$CONFIRM_DATA" == "delete-data" ]; then
        print_info "Deleting ${HOST_DATA_ROOT}..."
        sudo rm -rf "${HOST_DATA_ROOT}"
        print_success "Persistent data has been permanently deleted."
    else
        print_warn "Aborted. Your data at ${HOST_DATA_ROOT} has NOT been touched."
    fi
else
    print_info "No persistent data directory found at ${HOST_DATA_ROOT}. Nothing to delete."
fi

# --- Step 4: Remove SSL Certificate from Certbot ---
echo
print_info "You may also want to remove the SSL certificate from Certbot."
read -p "Enter the domain name whose certificate you want to delete (e.g., sla.soemath.com): " DOMAIN_NAME
if [ -n "$DOMAIN_NAME" ]; then
    if sudo certbot certificates | grep -q "Found the following certs:" && sudo certbot certificates | grep -q "Domains: ${DOMAIN_NAME}"; then
        print_warn "This will delete the certificate for ${DOMAIN_NAME} from Certbot's storage."
        read -p "Proceed? (yes/no): " CONFIRM_CERT
        if [ "$CONFIRM_CERT" == "yes" ]; then
            sudo certbot delete --cert-name "${DOMAIN_NAME}"
            print_success "Certificate for ${DOMAIN_NAME} deleted."
        else
            print_info "Skipping certificate deletion."
        fi
    else
        print_info "No certificate found for '${DOMAIN_NAME}'."
    fi
fi

echo
print_success "Uninstallation script finished."
