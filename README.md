# Distributed Internet SLA Monitor

This project provides a distributed system to monitor internet connection SLAs from multiple locations (Linux and Windows agents), sending data to a central server for aggregated display, historical logging, charting, and alerting. The central server application is designed to be run in a Docker container.

## Architecture

*   **Central Server (Dockerized):** Hosts the main dashboard, a central SQLite database (via Docker volume), and API endpoints for agents. Apache and PHP run inside the Docker container.
*   **Agent Machines (Linux/Windows):** Run monitoring scripts, perform tests based on centrally managed (or local fallback) profiles, and submit data to the central server API.

## Features

*   **Multi-Agent Support:** Monitor multiple ISP connections or client locations.
*   **Cross-Platform Agents:** Includes a Bash agent for Linux and a PowerShell agent template for Windows.
*   **Centralized Dashboard:** Web interface on the central server to view:
    *   Overall SLA averages (grouped by ISP agents, Client agents, All agents).
    *   A list of all reporting agents with summary status.
    *   Detailed metrics, charts (Chart.js), and historical SLA for individual selected agents.
*   **Comprehensive Monitoring (per agent):** Ping (RTT, Loss, Jitter), DNS Resolution, HTTP Accessibility, Speedtest.
*   **SQLite Database Logging:** Central database stores historical metrics.
*   **External Configuration:**
    *   Central server general settings: `central_server_package/app/sla_config.env.template`.
    *   Agent identity & API URL: `agent_config.env.template` (Linux) / `agent_config.ps1.template` (Windows).
    *   ISP/Agent Profiles (thresholds, etc.): Managed in the central SQLite database, with agents fetching their config. New agents can be auto-profiled with defaults.
*   **Teams Notifications:** Central server's monitor script (if configured to monitor its own connection) or a future central alerting mechanism can send alerts. Agent-specific alerts are based on their fetched profiles.
*   **Automated Setup Scripts:**
    *   `central_server_package/setup_central_server.sh`: Sets up Docker, directories, initial DB/config on host, and launches the Docker Compose setup.
    *   `linux_agent_package/setup_agent_linux.sh`: For Linux agents.
    *   `windows_agent_package/setup_agent_windows.ps1`: For Windows agents (basic setup).

## Prerequisites

*   **Central Server Host:** Linux machine with `sudo` access, Docker, and Docker Compose installed (setup script attempts to install them).
*   **Linux Agent:** Ubuntu/Debian-based system, `sudo` access, standard CLI tools (curl, jq, bc, ping, dig, sqlite3), speedtest client.
*   **Windows Agent:** Windows machine with PowerShell 5.1+, Administrator access for setup. Manual installation of Ookla's `speedtest.exe` is highly recommended.

## Setup Instructions

**I. Central Dashboard Server**

1.  Clone this repository to your central server:
    ```bash
    git clone https://github.com/YOUR_USERNAME/internet-sla-monitor.git
    cd internet-sla-monitor/central_server_package
    ```
2.  **Prepare Configuration Template:**
    Copy `app/sla_config.env.template` to `app/sla_config.env`.
    ```bash
    cp app/sla_config.env.template app/sla_config.env
    ```
    Edit `app/sla_config.env` if you need to change general defaults (like dashboard refresh). Most agent-specific settings will be in the central database.
3.  **Run the Setup Script:**
    ```bash
    sudo ./setup_central_server.sh
    ```
    This script will:
    *   Install Docker and Docker Compose if missing.
    *   Create host directories for persistent data (e.g., under `/srv/sla_monitor/`).
    *   Copy the initial `app/sla_config.env` to the host volume.
    *   Initialize the central SQLite database schema in the host volume.
    *   Build and start the Docker container using `docker-compose.yml`.
4.  **Manually Add/Edit Agent/ISP Profiles in the Central Database:**
    After setup, the central database is at `/srv/sla_monitor/central_app_data/opt_sla_monitor/central_sla_data.sqlite`.
    ```bash
    sudo sqlite3 /srv/sla_monitor/central_app_data/opt_sla_monitor/central_sla_data.sqlite
    ```
    Use SQL `INSERT` or `UPDATE` commands on the `isp_profiles` table. Each agent you deploy needs a corresponding entry here with a unique `agent_identifier` and its `agent_type` ('ISP' or 'Client'). Fill in all desired thresholds for each profile.
    *Example:*
    ```sql
    INSERT INTO isp_profiles (agent_name, agent_identifier, agent_type, network_interface_to_monitor, sla_target_percentage, rtt_degraded, rtt_poor, teams_webhook_url) 
    VALUES ('Branch Office - WAN1', 'branch01_wan1_agent', 'ISP', 'eth1', 99.0, 150, 350, 'YOUR_TEAMS_URL'); 
    -- (Remember to fill ALL threshold columns relevant for this profile)
    .quit
    ```
5.  **Firewall:** Ensure your host firewall allows port 80 (and 443 if you set up HTTPS via a reverse proxy).
6.  **Access Dashboard:** `http://<central_server_ip>/` (or your configured domain if using a reverse proxy).

**II. Linux Agent Machine**

1.  Clone this repository or copy the `linux_agent_package` directory to the agent machine.
2.  Navigate into `linux_agent_package`.
3.  Copy `agent_config.env.template` to `agent_config.env`.
4.  **Edit `agent_config.env`:**
    *   Set `AGENT_IDENTIFIER` to match the unique ID you created for this agent in the central server's `isp_profiles` table.
    *   Set `CENTRAL_API_URL` to `http://<central_server_ip>/api/submit_metrics.php`.
    *   (Optional) Set `NETWORK_INTERFACE_TO_MONITOR`.
5.  Make setup script executable: `chmod +x setup_agent_linux.sh`
6.  Run setup script: `sudo ./setup_agent_linux.sh`

**III. Windows Agent Machine**

1.  Copy the `windows_agent_package` directory to the Windows machine.
2.  Navigate into `windows_agent_package` using PowerShell.
3.  Copy `agent_config.ps1.template` to `agent_config.ps1`.
4.  **Edit `agent_config.ps1`:**
    *   Set `$AgentConfig.AGENT_IDENTIFIER` to match the central server's `isp_profiles` table.
    *   Set `$AgentConfig.CENTRAL_API_URL`.
5.  **Manually install Ookla's `speedtest.exe`** and ensure it's in PATH or update `Monitor-InternetAgent.ps1`. Run `speedtest.exe --accept-license --accept-gdpr` once.
6.  **Implement/Verify Speedtest Logic** in `Monitor-InternetAgent.ps1`.
7.  Run the setup script from an **Administrator PowerShell**: `.\setup_agent_windows.ps1`

## Configuration Management

*   **Central Server (General):** `/srv/sla_monitor/central_app_data/opt_sla_monitor/sla_config.env` on the Docker host (mounted into container).
*   **Per-Agent/ISP Profiles:** `isp_profiles` table in `/srv/sla_monitor/central_app_data/opt_sla_monitor/central_sla_data.sqlite` on the Docker host.
*   **Agent Connection Settings:** `agent_config.env` (Linux) or `agent_config.ps1` (Windows) on each agent.

## Security

*   **HTTPS for Dashboard/API:** Strongly recommended. Use a reverse proxy (Nginx, Traefik, Caddy) in front of the Docker container to handle SSL.
*   **API Key Authentication:** The provided PHP API scripts have comments for basic API key checks. This should be implemented for production.
*   Review and harden Apache and PHP configurations inside the Docker image if needed.

## Troubleshooting

*   **Central Docker Logs:** `sudo docker logs sla_monitor_central_app`
*   **Central API Log:** `/srv/sla_monitor/central_app_data/api_logs/sla_api.log` on the Docker host.
*   **Agent Logs:** `/var/log/internet_sla_monitor_agent.log` (Linux) or `C:\SLA_Monitor_Agent\internet_monitor_agent_windows.log` (Windows).