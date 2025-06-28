#!/bin/bash

# setup_agent_linux.sh - FINAL PRODUCTION VERSION
# Includes resilient installation logic and proactive cleanup of broken repositories.

# --- Configuration Variables ---
MONITOR_SCRIPT_NAME="monitor_internet.sh"
AGENT_CONFIG_NAME="agent_config.env"
MONITOR_SCRIPT_DIR="/opt/sla_monitor"
MONITOR_SCRIPT_PATH="${MONITOR_SCRIPT_DIR}/${MONITOR_SCRIPT_NAME}"
CONFIG_FILE_PATH="${MONITOR_SCRIPT_DIR}/${AGENT_CONFIG_NAME}"
AGENT_LOG_FILE="/var/log/internet_sla_monitor_agent.log"
OOKLA_REPO_FILE="/etc/apt/sources.list.d/ookla_speedtest-cli.list"

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

# --- Main Setup Logic ---
print_info "Starting SLA Monitor AGENT Setup (Linux)..."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# 1. Check for source files
for file in "./${MONITOR_SCRIPT_NAME}" "./${AGENT_CONFIG_NAME}"; do
    if [ ! -f "$file" ]; then print_error "Source file '$file' not found in current directory."; exit 1; fi
done

# 2. *** NEW: Proactively clean up potentially broken repositories first ***
print_info "Ensuring system package manager is in a clean state..."
if [ -f "$OOKLA_REPO_FILE" ]; then
    sudo rm -f "$OOKLA_REPO_FILE"
    print_info "Removed existing Ookla repository file to ensure a clean update."
fi

# 3. Install Core Dependencies from Main Repositories
print_info "Updating package list and installing core dependencies..."
sudo apt-get update -y || { print_error "Initial Apt update failed. Please check network and repository settings."; exit 1; }
sudo apt-get install -y curl jq bc iputils-ping dnsutils || { print_error "Core dependency installation failed."; exit 1; }

# 4. Resiliently Attempt to install Speedtest CLI
print_info "Attempting to install Speedtest CLI..."
SPEEDTEST_INSTALLED=false

# First, try the official Ookla version
print_info "Trying official Ookla Speedtest..."
if curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash; then
    # The repo script runs its own 'apt-get update'. Now try to install the package.
    if sudo apt-get install -y speedtest; then
        print_info "Ookla Speedtest installed successfully."
        SPEEDTEST_INSTALLED=true
    else
        print_warn "Ookla repo was added, but the 'speedtest' package failed to install (likely unavailable for this OS)."
        # Clean up the broken repo file again, just in case.
        sudo rm -f "$OOKLA_REPO_FILE"
    fi
else
    print_warn "Could not add the Ookla Speedtest repository script."
fi

# If Ookla version failed, fall back to the community version
if [ "$SPEEDTEST_INSTALLED" = false ]; then
    print_info "Falling back to community 'speedtest-cli' from main repositories..."
    if sudo apt-get install -y speedtest-cli; then
        print_info "Community speedtest-cli installed successfully."
    else
        print_warn "Could not install any version of Speedtest CLI. Speedtest will be skipped."
    fi
fi

# Accept license terms for whichever speedtest was installed
print_info "Attempting to accept Speedtest license terms..."
if command -v speedtest &> /dev/null; then sudo speedtest --accept-license --accept-gdpr > /dev/null 2>&1; fi
if command -v speedtest-cli &> /dev/null; then sudo speedtest-cli --accept-license --accept-gdpr > /dev/null 2>&1; fi


# 5. Fix ping permissions for reliable cron execution
print_info "Ensuring 'ping' has necessary permissions for non-interactive execution..."
if command -v ping &> /dev/null; then
    sudo chmod u+s $(which ping)
    print_info "Set 'setuid' permission on ping command."
else
    print_warn "Could not find 'ping' command to set permissions."
fi

# 6. Deploy Application Files Safely
print_info "Creating script directory: ${MONITOR_SCRIPT_DIR}"
sudo mkdir -p "${MONITOR_SCRIPT_DIR}"

if [ ! -f "${CONFIG_FILE_PATH}" ]; then
    print_info "Copying agent configuration template to ${CONFIG_FILE_PATH}"
    sudo cp "./${AGENT_CONFIG_NAME}" "${CONFIG_FILE_PATH}"; sudo chown root:root "${CONFIG_FILE_PATH}"; sudo chmod 600 "${CONFIG_FILE_PATH}"
else
    print_warn "Config file ${CONFIG_FILE_PATH} already exists. Skipping copy."
fi

print_info "Copying agent monitoring script to ${MONITOR_SCRIPT_PATH}"
sudo cp "./${MONITOR_SCRIPT_NAME}" "${MONITOR_SCRIPT_PATH}"; sudo chmod +x "${MONITOR_SCRIPT_PATH}"; sudo chown root:root "${MONITOR_SCRIPT_PATH}"

# 7. Set up Logging and Cron Job
print_info "Setting up log file and cron job..."
sudo touch "${AGENT_LOG_FILE}"; sudo chown syslog:adm "${AGENT_LOG_FILE}"; sudo chmod 640 "${AGENT_LOG_FILE}"

CRON_FILE_NAME="sla-monitor-agent-cron"
CRON_FILE_DEST="/etc/cron.d/${CRON_FILE_NAME}"
print_info "Creating cron job at ${CRON_FILE_DEST}"
sudo cat <<EOF > "${CRON_FILE_DEST}"
# SLA Monitor AGENT Cron Job
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/15 * * * * root ${MONITOR_SCRIPT_PATH}
EOF
sudo chown root:root "${CRON_FILE_DEST}"; sudo chmod 644 "${CRON_FILE_DEST}"
print_info "Agent cron job created successfully."

print_info "--------------------------------------------------------------------"
print_info "SLA Monitor AGENT Setup finished."
print_warn "IMPORTANT: Customize ${CONFIG_FILE_PATH} with a unique"
print_warn "AGENT_IDENTIFIER and the correct CENTRAL_API_URL."
print_info "--------------------------------------------------------------------"