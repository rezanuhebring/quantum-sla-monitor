#!/bin/bash

# Script to completely uninstall the Central Internet SLA Monitor and its components.

# --- Configuration Variables (should match your setup script) ---
HOST_DATA_ROOT="/srv/sla_monitor/central_app_data"
DOCKER_COMPOSE_FILE_NAME="docker-compose.yml"
DOCKERFILE_NAME="Dockerfile"
CONTAINER_NAME="sla_monitor_central_app"

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

# --- Uninstallation Logic ---
print_warn "This script will stop and remove all components of the SLA Monitor."
print_warn "This includes Docker containers, images, and potentially all stored data."
echo

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run with sudo: sudo $0"
    exit 1
fi

# 1. Stop and remove the Docker container and associated image/network
print_info "Stopping and removing Docker components..."
if [ -f "${DOCKER_COMPOSE_FILE_NAME}" ]; then
    # Use docker-compose down which handles containers, networks, and images
    # The --rmi all flag removes the specific image built for the service
    sudo docker-compose -f "${DOCKER_COMPOSE_FILE_NAME}" down --rmi all
    print_info "Docker-compose services have been taken down."
else
    print_warn "${DOCKER_COMPOSE_FILE_NAME} not found."
    print_info "Attempting to stop and remove container by name: ${CONTAINER_NAME}"
    # Fallback if compose file is missing
    if sudo docker stop "${CONTAINER_NAME}" &>/dev/null; then
        print_info "Container '${CONTAINER_NAME}' stopped."
    fi
    if sudo docker rm "${CONTAINER_NAME}" &>/dev/null; then
        print_info "Container '${CONTAINER_NAME}' removed."
    fi
fi
echo

# 2. Ask for confirmation before deleting persistent data on the host
print_warn "The next step will PERMANENTLY DELETE all application data, logs, and the database."
print_warn "This action CANNOT be undone."
read -p "Are you sure you want to delete the data directory at ${HOST_DATA_ROOT}? [y/N]: " confirm_delete_data

if [[ "$confirm_delete_data" == [yY] || "$confirm_delete_data" == [yY][eE][sS] ]]; then
    print_info "Deleting host data directory: ${HOST_DATA_ROOT}"
    if [ -d "${HOST_DATA_ROOT}" ]; then
        sudo rm -rf "${HOST_DATA_ROOT}"
        print_info "Host data directory deleted successfully."
    else
        print_warn "Host data directory not found, nothing to delete."
    fi
else
    print_info "Skipping deletion of host data directory."
fi
echo

# 3. Clean up local build files
print_info "Deleting local build and configuration files..."
rm -f "${DOCKERFILE_NAME}"
rm -f "${DOCKER_COMPOSE_FILE_NAME}"
rm -rf "docker"
print_info "Local files (Dockerfile, docker-compose.yml, docker/) have been removed."
echo

# 4. Optionally, uninstall Docker itself
print_warn "You can also completely uninstall Docker and Docker Compose from the system."
read -p "Would you like to UNINSTALL DOCKER from this system? [y/N]: " confirm_uninstall_docker

if [[ "$confirm_uninstall_docker" == [yY] || "$confirm_uninstall_docker" == [yY][eE][sS] ]]; then
    print_info "Uninstalling Docker and Docker Compose..."
    # Stop the docker service
    sudo systemctl stop docker
    sudo systemctl disable docker
    # Purge docker packages
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io
    # Remove docker-compose binary
    sudo rm -f /usr/local/bin/docker-compose
    # Clean up residual Docker data (this is very thorough)
    sudo rm -rf /var/lib/docker
    sudo rm -rf /var/lib/containerd
    print_info "Docker has been uninstalled."
else
    print_info "Skipping Docker uninstallation."
fi
echo

print_info "SLA Monitor uninstallation script has finished."