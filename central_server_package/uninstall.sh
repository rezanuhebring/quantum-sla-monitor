#!/bin/bash
# uninstall.sh - A safe, interactive script to remove the SLA Monitor.
# Handles both production (Nginx+SSL) and development setups.

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
print_info "This script can uninstall both 'production' and 'development' environments."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- Step 1: Stop and Remove Docker Containers ---
print_info "Checking for running services..."
if [ -f "${DOCKER_COMPOSE_FILE_NAME}" ]; then
    print_warn "This will stop and remove all SLA Monitor containers and their associated networks."
    read -p "Are you sure you want to continue? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        print_info "Aborting."
        exit 0
    fi
    print_info "Stopping and removing containers..."
    # The --volumes flag removes anonymous volumes, which is correct for a full uninstall.
    sudo docker-compose down --volumes
    if [ $? -eq 0 ]; then
        print_success "Containers and networks removed successfully."
    else
        print_error "Failed to remove containers. Please check Docker's status."
    fi
else
    print_info "No docker-compose.yml found. Skipping container removal."
    print_info "If you have old containers running without a compose file, you may need to remove them manually:"
    print_info "sudo docker stop sla_monitor_central_app sla_monitor_nginx"
    print_info "sudo docker rm sla_monitor_central_app sla_monitor_nginx"
fi

# --- Step 2: Remove Persistent Data (CRITICAL STEP) ---
if [ -d "${HOST_DATA_ROOT}" ]; then
    echo
    print_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    print_warn "!!! DANGER ZONE: You are about to delete all persistent data !!!"
    print_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    print_info "This includes the SQLite database, logs, and any other data stored by the application."
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

# --- Step 3: Remove SSL Certificate from Certbot (for Production installs) ---
echo
if ! command -v certbot &> /dev/null; then
    print_info "Certbot is not installed, skipping certificate removal step."
else
    print_info "If you installed in 'production' mode, you may want to remove the SSL certificate."
    read -p "Do you want to check for and delete a certificate? (yes/no): " CHECK_CERT
    if [ "$CHECK_CERT" == "yes" ]; then
        sudo certbot certificates
        read -p "Enter the domain name (Certificate Name) whose certificate you want to delete (leave blank to skip): " DOMAIN_NAME
        if [ -n "$DOMAIN_NAME" ]; then
            # Check if the certificate name exists before attempting deletion
            if sudo certbot certificates | grep -q "Certificate Name: ${DOMAIN_NAME}"; then
                print_warn "This will delete the certificate for '${DOMAIN_NAME}' from Certbot's storage."
                read -p "Proceed? (yes/no): " CONFIRM_CERT
                if [ "$CONFIRM_CERT" == "yes" ]; then
                    sudo certbot delete --cert-name "${DOMAIN_NAME}"
                else
                    print_info "Skipping certificate deletion."
                fi
            else
                print_info "No certificate found with the name '${DOMAIN_NAME}'."
            fi
        else
            print_info "No domain entered. Skipping certificate deletion."
        fi
    else
        print_info "Skipping certificate check."
    fi
fi

echo
print_success "Uninstallation script finished."