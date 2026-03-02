#!/bin/bash

# Dell R730 GPU Fan Control - Installation Script
# This script automates the installation of the fan controller and dashboard.

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}   Dell R730 GPU Fan Control Installer      ${NC}"
echo -e "${GREEN}==============================================${NC}"

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root (sudo ./install.sh)${NC}"
  exit 1
fi

CONFIG_PATH="/var/lib/dell_gpu_fan_control/config.json"
CONFIG_EXISTED=0
if [ -f "$CONFIG_PATH" ]; then
    CONFIG_EXISTED=1
fi

echo -e "\n${GREEN}Installing Dependencies...${NC}"
# Check if apt-get is available (Debian/Ubuntu) or yum (RHEL/CentOS)
# Check if apt-get is available (Debian/Ubuntu) or yum (RHEL/CentOS)
if command -v apt-get &> /dev/null; then
    apt-get update
    apt-get install -y ipmitool python3 python3-pip sqlite3 jq python3-flask
elif command -v yum &> /dev/null; then
    yum install -y ipmitool python3 python3-pip sqlite3 jq
    # Fallback to pip only on RHEL/CentOS if package is missing, or user might need EPEL
    pip3 install flask
else
    echo -e "${RED}Error: Unsupported package manager. Please install dependencies manually.${NC}"
    exit 1
fi

# Resolve iDRAC settings: reuse existing config when available, prompt only when missing.
EXISTING_IDRAC_HOST=""
EXISTING_IDRAC_USER=""
EXISTING_IDRAC_PASS=""
if [ -f "$CONFIG_PATH" ] && command -v jq &> /dev/null; then
    EXISTING_IDRAC_HOST=$(jq -r '.idrac.host // empty' "$CONFIG_PATH" 2>/dev/null)
    EXISTING_IDRAC_USER=$(jq -r '.idrac.username // empty' "$CONFIG_PATH" 2>/dev/null)
    EXISTING_IDRAC_PASS=$(jq -r '.idrac.password // empty' "$CONFIG_PATH" 2>/dev/null)
fi
if [ "$EXISTING_IDRAC_HOST" = "null" ]; then EXISTING_IDRAC_HOST=""; fi
if [ "$EXISTING_IDRAC_USER" = "null" ]; then EXISTING_IDRAC_USER=""; fi
if [ "$EXISTING_IDRAC_PASS" = "null" ]; then EXISTING_IDRAC_PASS=""; fi

if [ -n "$EXISTING_IDRAC_HOST" ] && [ -n "$EXISTING_IDRAC_USER" ] && [ -n "$EXISTING_IDRAC_PASS" ]; then
    IDRAC_HOST="$EXISTING_IDRAC_HOST"
    IDRAC_USER="$EXISTING_IDRAC_USER"
    IDRAC_PASS="$EXISTING_IDRAC_PASS"
    echo -e "\n${GREEN}Using persisted iDRAC settings from ${CONFIG_PATH}${NC}"
    echo -e "  Host: ${YELLOW}${IDRAC_HOST}${NC}"
    echo -e "  User: ${YELLOW}${IDRAC_USER}${NC}"
else
    echo -e "\n${YELLOW}Configuration Required:${NC}"
    read -p "iDRAC IP Address [192.168.1.100]: " idrac_host
    IDRAC_HOST=${idrac_host:-192.168.1.100}

    read -p "iDRAC Username [root]: " idrac_user
    IDRAC_USER=${idrac_user:-root}

    echo -n "iDRAC Password [calvin]: "
    read -s idrac_pass
    echo
    IDRAC_PASS=${idrac_pass:-calvin}
fi

# echo -e "${GREEN}Installing Python Dependencies...${NC}"
# pip3 install flask  <-- Removed to avoid PEP 668 errors on modern Debian/Ubuntu

echo -e "\n${GREEN}Creating Directories...${NC}"
mkdir -p /opt/dell-gpu-fan-control/templates
mkdir -p /var/lib/dell_gpu_fan_control
mkdir -p /var/log

echo -e "${GREEN}Copying Files...${NC}"

# Check if we are in the directory with the files
if [ ! -f "dell_gpu_fan_control.sh" ]; then
    echo -e "${RED}Error: dell_gpu_fan_control.sh not found in current directory.${NC}"
    echo -e "Please run this script from the folder containing the project files."
    exit 1
fi

# Copy main script
cp dell_gpu_fan_control.sh /usr/local/bin/
chmod +x /usr/local/bin/dell_gpu_fan_control.sh

# Copy dashboard files
cp dashboard_server.py /opt/dell-gpu-fan-control/
chmod +x /opt/dell-gpu-fan-control/dashboard_server.py
if [ -d "templates" ]; then
    cp -r templates/* /opt/dell-gpu-fan-control/templates/
else
    echo -e "${YELLOW}Warning: templates directory not found. Dashboard may not work correctly.${NC}"
fi

# Determine Dashboard Port
# Check if a port is already configured in config.json
if [ -f "$CONFIG_PATH" ] && command -v jq &> /dev/null; then
    EXISTING_PORT=$(jq -r '.dashboard.port // empty' "$CONFIG_PATH" 2>/dev/null)
else
    EXISTING_PORT=""
fi

if [ -n "$EXISTING_PORT" ] && [ "$EXISTING_PORT" != "null" ] && [ "$EXISTING_PORT" != "8080" ]; then
    # Use existing configured port (static)
    DASHBOARD_PORT=$EXISTING_PORT
    echo -e "${GREEN}Using Existing Dashboard Port: ${YELLOW}${DASHBOARD_PORT}${NC}"
else
    # Generate random port between 8000 and 9000
    DASHBOARD_PORT=$((RANDOM % 1000 + 8000))
    echo -e "${GREEN}Selected New Random Dashboard Port: ${YELLOW}${DASHBOARD_PORT}${NC}"
fi

echo -e "${GREEN}Generating Configuration...${NC}"

# Find nvidia-smi path for config
NVIDIA_SMI_PATH=$(which nvidia-smi 2>/dev/null)
if [ -z "$NVIDIA_SMI_PATH" ]; then
    # Try common locations
    for path in /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi /usr/sbin/nvidia-smi /bin/nvidia-smi; do
        if [ -x "$path" ]; then
            NVIDIA_SMI_PATH="$path"
            break
        fi
    done
fi
echo -e "${GREEN}Detected nvidia-smi at: ${YELLOW}${NVIDIA_SMI_PATH:-Not Found (will auto-detect at runtime)}${NC}"

# Find nvidia-settings path for optional GPU fan assist
NVIDIA_SETTINGS_PATH=$(which nvidia-settings 2>/dev/null)
if [ -z "$NVIDIA_SETTINGS_PATH" ]; then
    for path in /usr/bin/nvidia-settings /usr/local/bin/nvidia-settings /usr/sbin/nvidia-settings /bin/nvidia-settings; do
        if [ -x "$path" ]; then
            NVIDIA_SETTINGS_PATH="$path"
            break
        fi
    done
fi
echo -e "${GREEN}Detected nvidia-settings at: ${YELLOW}${NVIDIA_SETTINGS_PATH:-Not Found (GPU fan assist optional)}${NC}"

# Build default config, then merge with existing config so credentials/settings persist.
cat > /tmp/config.defaults.json <<EOF
{
  "dashboard": {
    "username": "admin",
    "password_hash": "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8",
    "port": ${DASHBOARD_PORT}
  },
  "idrac": {
    "host": "${IDRAC_HOST}",
    "username": "${IDRAC_USER}",
    "password": "${IDRAC_PASS}"
  },
  "fan_control": {
    "temp_low": 40,
    "temp_normal": 50,
    "temp_warm": 60,
    "temp_hot": 70,
    "temp_critical": 80,
    "chassis_fan_min": 20,
    "chassis_fan_low": 30,
    "chassis_fan_normal": 40,
    "chassis_fan_warm": 55,
    "chassis_fan_hot": 70,
    "chassis_fan_critical": 100,
    "check_interval": 5,
    "rampdown_delay": 20,
    "sustained_hot_checks": 6
  },
  "external": {
    "nvidia_smi_path": "${NVIDIA_SMI_PATH}",
    "nvidia_settings_path": "${NVIDIA_SETTINGS_PATH}",
    "gpu_name": "Quadro RTX 4000",
    "gpu_index": "",
    "gpu_fan_control_enabled": false,
    "gpu_fan_display": ":1",
    "gpu_fan_xauthority": "",
    "gpu_fan_target": 0,
    "gpu_fan_min": 35,
    "gpu_fan_low": 45,
    "gpu_fan_normal": 55,
    "gpu_fan_warm": 65,
    "gpu_fan_hot": 80,
    "gpu_fan_critical": 95,
    "gpu_fan_priority_margin": 20
  }
}
EOF

if [ -f "$CONFIG_PATH" ] && command -v jq &> /dev/null; then
    jq -s '.[0] * .[1]' /tmp/config.defaults.json "$CONFIG_PATH" > /tmp/config.json
else
    cp /tmp/config.defaults.json /tmp/config.json
fi

mv /tmp/config.json "$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"

echo -e "${GREEN}Initializing Database...${NC}"
# Pre-initialize database to avoid "Database not found" errors in dashboard
mkdir -p /var/lib/dell_gpu_fan_control
sqlite3 /var/lib/dell_gpu_fan_control/metrics.db <<EOF
CREATE TABLE IF NOT EXISTS temperature_readings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    gpu_temp INTEGER NOT NULL,
    hotspot_temp INTEGER NOT NULL,
    memory_temp INTEGER NOT NULL,
    max_temp INTEGER NOT NULL,
    fan_speed INTEGER NOT NULL,
    gpu_fan_pct INTEGER NOT NULL DEFAULT -1
);

CREATE TABLE IF NOT EXISTS fan_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    temperature INTEGER NOT NULL,
    fan_speed INTEGER NOT NULL,
    details TEXT
);

CREATE TABLE IF NOT EXISTS statistics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    period_start INTEGER NOT NULL,
    period_end INTEGER NOT NULL,
    peak_gpu_temp INTEGER NOT NULL,
    peak_hotspot_temp INTEGER NOT NULL,
    peak_memory_temp INTEGER NOT NULL,
    avg_gpu_temp INTEGER NOT NULL,
    max_fan_events INTEGER NOT NULL,
    high_temp_warnings INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_temp_timestamp ON temperature_readings(timestamp);
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON fan_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_stats_period ON statistics(period_start, period_end);

-- Insert dummy data to show dashboard immediately (will be stale after 60s)
INSERT INTO temperature_readings (timestamp, gpu_temp, hotspot_temp, memory_temp, max_temp, fan_speed, gpu_fan_pct)
VALUES ($(date +%s), 0, 0, 0, 0, 0, -1);

EOF
chmod 666 /var/lib/dell_gpu_fan_control/metrics.db

echo -e "${GREEN}Configuring Services...${NC}"

if [ -f "dell-gpu-fan-control.service" ]; then
    cp dell-gpu-fan-control.service /etc/systemd/system/
else
     echo -e "${RED}Error: dell-gpu-fan-control.service not found.${NC}"
     exit 1
fi

if [ -f "dell-gpu-dashboard.service" ]; then
    cp dell-gpu-dashboard.service /etc/systemd/system/
else
     echo -e "${RED}Error: dell-gpu-dashboard.service not found.${NC}"
     exit 1
fi

# Reload systemd
systemctl daemon-reload

# Enable and start services
echo -e "${GREEN}Starting Services...${NC}"
systemctl enable dell-gpu-fan-control.service
systemctl restart dell-gpu-fan-control.service

systemctl enable dell-gpu-dashboard.service
systemctl restart dell-gpu-dashboard.service

# Get server IP
SERVER_IP=$(hostname -I | awk '{print $1}')
if command -v jq &> /dev/null && [ -f "$CONFIG_PATH" ]; then
    DASHBOARD_PORT=$(jq -r '.dashboard.port // 8080' "$CONFIG_PATH" 2>/dev/null)
fi

echo -e "\n${GREEN}Installation Complete!${NC}"
echo -e "------------------------------------------------"
echo -e "Dashboard is available at: ${YELLOW}http://${SERVER_IP}:${DASHBOARD_PORT}${NC}"
if [ "$CONFIG_EXISTED" -eq 1 ]; then
    echo -e "Dashboard credentials and iDRAC settings were preserved from existing config."
else
    echo -e "Default Dashboard Login:"
    echo -e "  Username: ${YELLOW}admin${NC}"
    echo -e "  Password: ${YELLOW}password${NC}"
fi
echo -e "------------------------------------------------"
echo -e "Check status with:"
echo -e "  sudo systemctl status dell-gpu-fan-control"
echo -e "  sudo systemctl status dell-gpu-dashboard"
echo -e ""
echo -e "Stop services with:"
echo -e "  sudo systemctl stop dell-gpu-fan-control"
echo -e "  sudo systemctl stop dell-gpu-dashboard"
