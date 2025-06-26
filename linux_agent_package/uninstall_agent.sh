#!/bin/bash

# Revised script to completely uninstall the SLA Monitor Agent and its components.

# --- Configuration Variables ---
MONITOR_SCRIPT_DIR="/opt/sla_monitor"
AGENT_LOG_FILE="/var/log/internet_sla_monitor_agent.log"
CRON_FILE_NAME="sla-monitor-agent-cron"
CRON_FILE_DEST="/etc/cron.d/${CRON_FILE_NAME}"
OOKLA_REPO_FILE="/etc/apt/sources.list.d/ookla_speedtest-cli.list"

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

# --- Uninstallation Logic ---
print_warn "This script will stop and remove all components of the SLA Monitor Agent."
echo
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# 1. Remove the cron job to stop the script from running
print_info "Removing agent cron job..."
if [ -f "${CRON_FILE_DEST}" ]; then
    sudo rm -f "${CRON_FILE_DEST}"
    print_info "Cron job at ${CRON_FILE_DEST} removed."
else
    print_warn "Cron job not found, nothing to remove."
fi
echo

# 2. NEW: Remove the Ookla Speedtest repository to fix 'apt update' issues
print_info "Removing Ookla Speedtest repository source..."
if [ -f "${OOKLA_REPO_FILE}" ]; then
    sudo rm -f "${OOKLA_REPO_FILE}"
    print_info "Repository file ${OOKLA_REPO_FILE} removed."
    print_info "Running 'apt-get update' to refresh sources and confirm fix..."
    sudo apt-get update
else
    print_warn "Ookla repository file not found, nothing to remove."
fi
echo

# 3. Ask for confirmation before deleting the script and config files
print_warn "The next step will PERMANENTLY DELETE the script and its configuration."
read -p "Are you sure you want to delete the directory at ${MONITOR_SCRIPT_DIR}? [y/N]: " confirm_delete_dir

if [[ "$confirm_delete_dir" == [yY] || "$confirm_delete_dir" == [yY][eE][sS] ]]; then
    print_info "Deleting script directory: ${MONITOR_SCRIPT_DIR}"
    if [ -d "${MONITOR_SCRIPT_DIR}" ]; then
        sudo rm -rf "${MONITOR_SCRIPT_DIR}"
        print_info "Script directory deleted successfully."
    else
        print_warn "Script directory not found, nothing to delete."
    fi
else
    print_info "Skipping deletion of script directory."
fi
echo

# 4. Remove the log file
print_info "Deleting log file: ${AGENT_LOG_FILE}"
if [ -f "${AGENT_LOG_FILE}" ]; then
    sudo rm -f "${AGENT_LOG_FILE}"
    print_info "Log file removed."
else
    print_warn "Log file not found, nothing to remove."
fi
echo

# 5. Ask for confirmation before uninstalling system packages
print_warn "The agent installed system-wide packages: curl, jq, bc, speedtest, etc."
print_warn "These may be used by other applications on your system."
read -p "Would you like to UNINSTALL these dependencies? [y/N]: " confirm_uninstall_deps

if [[ "$confirm_uninstall_deps" == [yY] || "$confirm_uninstall_deps" == [yY][eE][sS] ]]; then
    print_info "Uninstalling dependencies..."
    sudo apt-get purge -y curl jq bc iputils-ping dnsutils sqlite3 speedtest*
    sudo apt-get autoremove -y
    print_info "Dependencies have been uninstalled."
else
    print_info "Skipping uninstallation of dependencies."
fi
echo

print_info "SLA Monitor Agent uninstallation script has finished."