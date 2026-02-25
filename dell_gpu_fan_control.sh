#!/bin/bash

################################################################################
# Dell R730 GPU Temperature-Based Fan Controller
# Optimized for LLM Inference Workloads (Ollama, KoboldCPP, etc.)
# 
# This script monitors Nvidia GPU temperature and dynamically adjusts Dell
# server fan speeds via IPMI to maintain optimal cooling without excessive noise.
#
# Features:
# - Fast 5-second response for bursty LLM workloads
# - Hysteresis: fans ramp UP immediately, ramp DOWN gradually
# - Prevents fan speed oscillation during load transitions
#
# Requirements:
# - ipmitool installed and configured
# - nvidia-smi (comes with Nvidia drivers)
# - IPMI over LAN enabled in iDRAC
################################################################################

# Configuration - loaded from config.json if available, otherwise defaults
CONFIG_FILE="/var/lib/dell_gpu_fan_control/config.json"

# Defaults (used if config.json is missing or jq is not installed)
IDRAC_HOST="192.168.1.100"
IDRAC_USER="root"
IDRAC_PASS="calvin"
TEMP_LOW=40
TEMP_NORMAL=50
TEMP_WARM=60
TEMP_HOT=70
TEMP_CRITICAL=80
CHECK_INTERVAL=5
RAMPDOWN_DELAY=20
GPU_NAME_FILTER="Quadro RTX 4000"
GPU_INDEX=""

# Load from config.json if available
if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
    IDRAC_HOST=$(jq -r '.idrac.host // empty' "$CONFIG_FILE" 2>/dev/null || echo "$IDRAC_HOST")
    IDRAC_USER=$(jq -r '.idrac.username // empty' "$CONFIG_FILE" 2>/dev/null || echo "$IDRAC_USER")
    IDRAC_PASS=$(jq -r '.idrac.password // empty' "$CONFIG_FILE" 2>/dev/null || echo "$IDRAC_PASS")
    TEMP_LOW=$(jq -r '.fan_control.temp_low // empty' "$CONFIG_FILE" 2>/dev/null || echo "$TEMP_LOW")
    TEMP_NORMAL=$(jq -r '.fan_control.temp_normal // empty' "$CONFIG_FILE" 2>/dev/null || echo "$TEMP_NORMAL")
    TEMP_WARM=$(jq -r '.fan_control.temp_warm // empty' "$CONFIG_FILE" 2>/dev/null || echo "$TEMP_WARM")
    TEMP_HOT=$(jq -r '.fan_control.temp_hot // empty' "$CONFIG_FILE" 2>/dev/null || echo "$TEMP_HOT")
    TEMP_CRITICAL=$(jq -r '.fan_control.temp_critical // empty' "$CONFIG_FILE" 2>/dev/null || echo "$TEMP_CRITICAL")
    CHECK_INTERVAL=$(jq -r '.fan_control.check_interval // empty' "$CONFIG_FILE" 2>/dev/null || echo "$CHECK_INTERVAL")
    RAMPDOWN_DELAY=$(jq -r '.fan_control.rampdown_delay // empty' "$CONFIG_FILE" 2>/dev/null || echo "$RAMPDOWN_DELAY")
    GPU_NAME_FILTER=$(jq -r '.external.gpu_name // empty' "$CONFIG_FILE" 2>/dev/null || echo "$GPU_NAME_FILTER")
    GPU_INDEX=$(jq -r '.external.gpu_index // empty' "$CONFIG_FILE" 2>/dev/null || echo "$GPU_INDEX")
fi

# Keep sane defaults if optional external keys are missing/blank in config.
if [ -z "$GPU_NAME_FILTER" ]; then
    GPU_NAME_FILTER="Quadro RTX 4000"
fi

# Fan speed settings (in hex, 0x00-0x64 = 0-100%)
FAN_MIN=0x14       # 20% - minimum for airflow
FAN_LOW=0x1E       # 30% - quiet operation
FAN_NORMAL=0x28    # 40% - normal operation
FAN_MEDIUM=0x37    # 55% - moderate cooling
FAN_HIGH=0x46      # 70% - increased cooling
FAN_MAX=0x64       # 100% - maximum cooling

# Log file
LOG_FILE="/var/log/dell_gpu_fan_control.log"

# Database file for web dashboard
DB_FILE="/var/lib/dell_gpu_fan_control/metrics.db"

################################################################################
# Functions
################################################################################

hex_to_dec() {
    # Convert hex fan speed (e.g. 0x28) to decimal (e.g. 40)
    echo $((16#${1#0x}))
}

init_database() {
    # Create database directory if it doesn't exist
    local db_dir=$(dirname "$DB_FILE")
    if [ ! -d "$db_dir" ]; then
        mkdir -p "$db_dir"
        chmod 755 "$db_dir"
    fi
    
    # Initialize SQLite database with tables
    sqlite3 "$DB_FILE" <<EOF
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
EOF

    # Add new columns on existing databases without dropping history
    local has_gpu_fan_column
    has_gpu_fan_column=$(sqlite3 "$DB_FILE" "PRAGMA table_info(temperature_readings);" | grep -c '|gpu_fan_pct|')
    if [ "$has_gpu_fan_column" -eq 0 ]; then
        sqlite3 "$DB_FILE" "ALTER TABLE temperature_readings ADD COLUMN gpu_fan_pct INTEGER NOT NULL DEFAULT -1;"
    fi
    
    if [ $? -eq 0 ]; then
        log_message "Database initialized at $DB_FILE"
        return 0
    else
        log_message "ERROR: Failed to initialize database"
        return 1
    fi
}

log_to_database() {
    if [ -z "$DB_FILE" ]; then
        return
    fi
    local timestamp=$(date +%s)
    local gpu_temp=$1
    local hotspot_temp=$2
    local memory_temp=$3
    local max_temp=$4
    local gpu_fan_pct=$5
    local fan_speed_hex=$6
    local fan_speed_dec=$(hex_to_dec "$fan_speed_hex")
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO temperature_readings (timestamp, gpu_temp, hotspot_temp, memory_temp, max_temp, fan_speed, gpu_fan_pct)
VALUES ($timestamp, $gpu_temp, $hotspot_temp, $memory_temp, $max_temp, $fan_speed_dec, $gpu_fan_pct);
EOF
}

log_fan_event() {
    if [ -z "$DB_FILE" ]; then
        return
    fi
    local timestamp=$(date +%s)
    local event_type=$1
    local temperature=$2
    local fan_speed_hex=$3
    local details=$4
    # Escape single quotes for SQL safety
    details=${details//\'/\'\'}
    local fan_speed_dec=$(hex_to_dec "$fan_speed_hex")
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO fan_events (timestamp, event_type, temperature, fan_speed, details)
VALUES ($timestamp, '$event_type', $temperature, $fan_speed_dec, '$details');
EOF
}

save_statistics_to_database() {
    local period_end=$(date +%s)
    local avg_temp=0
    if [ "$STATS_TEMP_READINGS" -gt 0 ]; then
        avg_temp=$((STATS_TEMP_SUM / STATS_TEMP_READINGS))
    fi
    
    sqlite3 "$DB_FILE" <<EOF
INSERT INTO statistics (period_start, period_end, peak_gpu_temp, peak_hotspot_temp, peak_memory_temp, 
                       avg_gpu_temp, max_fan_events, high_temp_warnings)
VALUES ($STATS_START_TIME, $period_end, $STATS_PEAK_GPU_TEMP, $STATS_PEAK_HOTSPOT_TEMP, 
        $STATS_PEAK_MEMORY_TEMP, $avg_temp, $STATS_MAX_FAN_COUNT, $STATS_HIGH_TEMP_WARNINGS);
EOF
}

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

resolve_gpu_index() {
    # Select the GPU index to monitor (preferred: configured index, then name match, then 0)
    if [ -n "$GPU_INDEX" ] && [[ "$GPU_INDEX" =~ ^[0-9]+$ ]]; then
        log_message "Using configured GPU index: $GPU_INDEX"
        return
    fi

    local gpu_listing
    gpu_listing=$($NVIDIA_CMD --query-gpu=index,name --format=csv,noheader 2>/dev/null)
    if [ -n "$gpu_listing" ]; then
        GPU_INDEX=$(echo "$gpu_listing" | awk -F', ' -v needle="$GPU_NAME_FILTER" '$2 ~ needle {print $1; exit}')
        if [ -n "$GPU_INDEX" ]; then
            log_message "Using GPU index ${GPU_INDEX} (matched name: ${GPU_NAME_FILTER})"
            return
        fi
    fi

    GPU_INDEX=0
    log_message "No GPU name match for '${GPU_NAME_FILTER}', defaulting to GPU index 0"
}

get_gpu_metrics() {
    # Returns: "gpu_temp hotspot_temp memory_temp gpu_fan_pct" or "-1 -1 -1 -1" if error
    local gpu_temp
    local memory_temp
    local hotspot_temp
    local gpu_fan_pct

    # Get basic telemetry (GPU temp, memory temp, onboard fan speed)
    local basic_temps
    basic_temps=$($NVIDIA_CMD --id="$GPU_INDEX" --query-gpu=temperature.gpu,temperature.memory,fan.speed --format=csv,noheader,nounits 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$basic_temps" ]; then
        # Parse "gpu, memory, fan"
        gpu_temp=$(echo "$basic_temps" | awk -F', ' '{print $1}')
        memory_temp=$(echo "$basic_temps" | awk -F', ' '{print $2}')
        gpu_fan_pct=$(echo "$basic_temps" | awk -F', ' '{print $3}')

        # Try to get hotspot temp via detailed query (TEXT format)
        hotspot_temp=$($NVIDIA_CMD --id="$GPU_INDEX" -q -d TEMPERATURE 2>/dev/null | grep "GPU Hotspot Temperature" | awk -F': ' '{print $2}' | grep -o '[0-9]*' | head -1)

        if [ -z "$hotspot_temp" ]; then
            hotspot_temp=$gpu_temp
        fi

        if [ -z "$memory_temp" ] || [ "$memory_temp" = "N/A" ] || [ "$memory_temp" = "[N/A]" ] || [ "$memory_temp" = "[Not Supported]" ]; then
            memory_temp=$gpu_temp
        fi

        if [ -z "$gpu_fan_pct" ] || [ "$gpu_fan_pct" = "N/A" ] || [ "$gpu_fan_pct" = "[N/A]" ] || [ "$gpu_fan_pct" = "[Not Supported]" ]; then
            gpu_fan_pct=-1
        fi

        echo "$gpu_temp $hotspot_temp $memory_temp $gpu_fan_pct"
    else
        echo "-1 -1 -1 -1"
    fi
}

get_max_temp() {
    # Get the maximum temperature from all sensors
    # This is what we'll use for fan control decisions
    local temps="$1"
    # Use read for efficiency instead of awk subshells
    read -r gpu_temp hotspot_temp memory_temp gpu_fan_pct <<< "$temps"
    
    # Find maximum
    local max_temp=$gpu_temp
    if [ "$hotspot_temp" -gt "$max_temp" ] 2>/dev/null; then
        max_temp=$hotspot_temp
    fi
    if [ "$memory_temp" -gt "$max_temp" ] 2>/dev/null; then
        max_temp=$memory_temp
    fi
    
    echo "$max_temp"
}

set_fan_speed() {
    local speed_hex=$1
    local speed_percent=$(hex_to_dec "$speed_hex")
    
    # Command to set manual fan speed
    ipmitool -I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USER" -P "$IDRAC_PASS" \
        raw 0x30 0x30 0x02 0xff "$speed_hex" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_message "Fan speed set to ${speed_percent}% (${speed_hex})"
        return 0
    else
        log_message "ERROR: Failed to set fan speed"
        return 1
    fi
}

enable_manual_fan_control() {
    # Enable manual fan control mode
    ipmitool -I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USER" -P "$IDRAC_PASS" \
        raw 0x30 0x30 0x01 0x00 >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_message "Manual fan control enabled"
        return 0
    else
        log_message "ERROR: Failed to enable manual fan control"
        return 1
    fi
}

disable_manual_fan_control() {
    # Restore automatic fan control
    ipmitool -I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USER" -P "$IDRAC_PASS" \
        raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_message "Automatic fan control restored"
        return 0
    else
        log_message "ERROR: Failed to restore automatic fan control"
        return 1
    fi
}

disable_third_party_pcie_response() {
    # Disable Dell's aggressive third-party PCIe card cooling
    ipmitool -I lanplus -H "$IDRAC_HOST" -U "$IDRAC_USER" -P "$IDRAC_PASS" \
        raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_message "Third-party PCIe cooling response disabled"
        return 0
    else
        log_message "WARNING: Failed to disable third-party PCIe cooling response"
        return 1
    fi
}

calculate_fan_speed_target() {
    # Calculate fan speed target from GPU temperatures and GPU fan load
    local temp=$1
    local gpu_fan_pct=$2
    local fan_speed

    if [ "$temp" -lt "$TEMP_LOW" ]; then
        fan_speed=$FAN_MIN
    elif [ "$temp" -lt "$TEMP_NORMAL" ]; then
        fan_speed=$FAN_LOW
    elif [ "$temp" -lt "$TEMP_WARM" ]; then
        fan_speed=$FAN_NORMAL
    elif [ "$temp" -lt "$TEMP_HOT" ]; then
        fan_speed=$FAN_MEDIUM
    elif [ "$temp" -lt "$TEMP_CRITICAL" ]; then
        fan_speed=$FAN_HIGH
    else
        fan_speed=$FAN_MAX
    fi

    # If GPU onboard fan is already working hard, increase chassis airflow proactively.
    if [ "$gpu_fan_pct" -ge 95 ] 2>/dev/null; then
        fan_speed=$FAN_MAX
    elif [ "$gpu_fan_pct" -ge 85 ] 2>/dev/null; then
        local fan_speed_dec
        fan_speed_dec=$(hex_to_dec "$fan_speed")
        if [ "$fan_speed_dec" -lt "$(hex_to_dec "$FAN_HIGH")" ]; then
            fan_speed=$FAN_HIGH
        fi
    fi

    echo "$fan_speed"
}

# NOTE: Hysteresis logic is implemented inline in the main monitoring loop below.
# Fans ramp UP immediately and ramp DOWN only after RAMPDOWN_DELAY seconds.

cleanup() {
    log_message "Received termination signal, cleaning up..."
    log_statistics_summary
    save_statistics_to_database
    disable_manual_fan_control
    log_message "Script terminated"
    exit 0
}

# Statistics tracking functions
reset_statistics() {
    STATS_START_TIME=$(date +%s)
    STATS_PEAK_GPU_TEMP=0
    STATS_PEAK_HOTSPOT_TEMP=0
    STATS_PEAK_MEMORY_TEMP=0
    STATS_MAX_FAN_COUNT=0
    STATS_TEMP_READINGS=0
    STATS_TEMP_SUM=0
    STATS_HIGH_TEMP_WARNINGS=0
}

update_statistics() {
    local gpu_temp=$1
    local hotspot_temp=$2
    local memory_temp=$3
    local fan_speed_hex=$4
    
    # Track peak temperatures
    if [ "$gpu_temp" -gt "$STATS_PEAK_GPU_TEMP" ]; then
        STATS_PEAK_GPU_TEMP=$gpu_temp
    fi
    if [ "$hotspot_temp" -gt "$STATS_PEAK_HOTSPOT_TEMP" ]; then
        STATS_PEAK_HOTSPOT_TEMP=$hotspot_temp
    fi
    if [ "$memory_temp" -gt "$STATS_PEAK_MEMORY_TEMP" ]; then
        STATS_PEAK_MEMORY_TEMP=$memory_temp
    fi
    
    # Track average temperature
    STATS_TEMP_READINGS=$((STATS_TEMP_READINGS + 1))
    STATS_TEMP_SUM=$((STATS_TEMP_SUM + gpu_temp))
    
    # Count max fan speed events
    local fan_speed_dec=$(hex_to_dec "$fan_speed_hex")
    if [ "$fan_speed_dec" -ge 90 ]; then
        STATS_MAX_FAN_COUNT=$((STATS_MAX_FAN_COUNT + 1))
    fi
    
    # Track high temperature warnings
    if [ "$gpu_temp" -ge "$TEMP_HOT" ]; then
        STATS_HIGH_TEMP_WARNINGS=$((STATS_HIGH_TEMP_WARNINGS + 1))
    fi
}

log_statistics_summary() {
    local runtime=$(($(date +%s) - STATS_START_TIME))
    local runtime_hours=$((runtime / 3600))
    local runtime_mins=$(((runtime % 3600) / 60))
    
    local avg_temp=0
    if [ "$STATS_TEMP_READINGS" -gt 0 ]; then
        avg_temp=$((STATS_TEMP_SUM / STATS_TEMP_READINGS))
    fi
    
    log_message "=========================================="
    log_message "Statistics Summary (Runtime: ${runtime_hours}h ${runtime_mins}m)"
    log_message "Peak GPU Temp: ${STATS_PEAK_GPU_TEMP}°C"
    log_message "Peak Hotspot Temp: ${STATS_PEAK_HOTSPOT_TEMP}°C"
    log_message "Peak Memory Temp: ${STATS_PEAK_MEMORY_TEMP}°C"
    log_message "Average GPU Temp: ${avg_temp}°C"
    log_message "High Fan Speed Events (90%+): ${STATS_MAX_FAN_COUNT}"
    log_message "High Temperature Warnings (${TEMP_HOT}°C+): ${STATS_HIGH_TEMP_WARNINGS}"
    
    # Cooling adequacy assessment
    if [ "$STATS_PEAK_GPU_TEMP" -ge "$TEMP_CRITICAL" ]; then
        log_message "⚠️  WARNING: Peak temps reached critical levels. Consider:"
        log_message "   - Lowering temperature thresholds"
        log_message "   - Increasing minimum fan speeds"
        log_message "   - Checking for dust buildup"
    elif [ "$STATS_HIGH_TEMP_WARNINGS" -gt $((STATS_TEMP_READINGS / 4)) ]; then
        log_message "⚠️  NOTICE: GPU running hot frequently (>25% of time)"
        log_message "   Consider lowering TEMP_WARM threshold by 5°C"
    fi
    
    log_message "=========================================="
}

################################################################################
# Main
################################################################################

# Set up signal handlers
trap cleanup SIGINT SIGTERM

log_message "=========================================="
log_message "Dell GPU Fan Controller Starting"
log_message "=========================================="

# Find nvidia telemetry command (systemd environment might have restricted PATH)
NVIDIA_CMD=""

# 1. Try config.json first
if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
    CONFIG_PATH=$(jq -r '.external.nvidia_cmd_path // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$CONFIG_PATH" ]; then
        CONFIG_PATH=$(jq -r '.external.nvidia_smi_path // empty' "$CONFIG_FILE" 2>/dev/null)
    fi
    if [ -n "$CONFIG_PATH" ] && [ -x "$CONFIG_PATH" ]; then
        NVIDIA_CMD="$CONFIG_PATH"
        log_message "Using configured NVIDIA telemetry command: $NVIDIA_CMD"
    fi
fi

# 2. Try default PATH (nvidia-rmi first for compatibility, then nvidia-smi)
if [ -z "$NVIDIA_CMD" ] && command -v nvidia-rmi &> /dev/null; then
    NVIDIA_CMD=$(command -v nvidia-rmi)
fi
if [ -z "$NVIDIA_CMD" ] && command -v nvidia-smi &> /dev/null; then
    NVIDIA_CMD=$(command -v nvidia-smi)
fi

# 3. Check common locations
if [ -z "$NVIDIA_CMD" ]; then
    for path in /usr/bin/nvidia-rmi /usr/sbin/nvidia-rmi /usr/local/bin/nvidia-rmi /usr/local/sbin/nvidia-rmi /bin/nvidia-rmi /usr/bin/nvidia-smi /usr/sbin/nvidia-smi /usr/local/bin/nvidia-smi /usr/local/sbin/nvidia-smi /bin/nvidia-smi; do
        if [ -x "$path" ]; then
            NVIDIA_CMD="$path"
            break
        fi
    done
fi

if [ -z "$NVIDIA_CMD" ]; then
    log_message "ERROR: NVIDIA telemetry command not found (tried nvidia-rmi and nvidia-smi). Please install Nvidia drivers."
    log_message "       Debug: PATH is $PATH"
    exit 1
else
    if [ -z "$CONFIG_PATH" ]; then
         log_message "Found NVIDIA telemetry command at: $NVIDIA_CMD"
    fi
fi

resolve_gpu_index

# Check if ipmitool is available
if ! command -v ipmitool &> /dev/null; then
    log_message "ERROR: ipmitool not found. Please install ipmitool."
    exit 1
fi

# Check if sqlite3 is available
if ! command -v sqlite3 &> /dev/null; then
    log_message "WARNING: sqlite3 not found. Web dashboard will not work. Install with: apt-get install sqlite3"
    DB_FILE=""  # Disable database logging
else
    # Initialize database for web dashboard
    log_message "Initializing database for web dashboard..."
    init_database
fi

# Initial setup
log_message "Disabling third-party PCIe cooling response..."
disable_third_party_pcie_response
sleep 2

log_message "Enabling manual fan control..."
enable_manual_fan_control
sleep 2

# Main monitoring loop
log_message "Starting temperature monitoring loop (checking every ${CHECK_INTERVAL}s)..."
log_message "Monitoring: GPU core, hotspot, and memory temperatures"
log_message "Hysteresis enabled: Fans ramp UP immediately, ramp DOWN after ${RAMPDOWN_DELAY}s"
current_fan_speed=""
pending_decrease_speed=""
decrease_pending_since=0
reset_statistics
last_stats_report=$(date +%s)
STATS_REPORT_INTERVAL=3600  # Report statistics every hour

while true; do
    # Get current GPU temperatures from all sensors
    metrics=$(get_gpu_metrics)
    read -r gpu_temp hotspot_temp memory_temp gpu_fan_pct <<< "$metrics"
    
    if [ "$gpu_temp" -eq -1 ]; then
        log_message "ERROR: Could not read GPU temperature. Restoring automatic control."
        disable_manual_fan_control
        sleep 60
        enable_manual_fan_control
        continue
    fi
    
    # Get the maximum temperature across all sensors for fan control
    max_temp=$(get_max_temp "$metrics")
    
    # Log and stats update moved to end of loop to capture final state
    
    # Calculate target fan speed based on maximum temperature
    target_fan_speed=$(calculate_fan_speed_target "$max_temp" "$gpu_fan_pct")
    
    # Convert hex to decimal for comparison
    if [ -n "$current_fan_speed" ]; then
        current_speed_dec=$(hex_to_dec "$current_fan_speed")
    else
        current_speed_dec=0
    fi
    target_speed_dec=$(hex_to_dec "$target_fan_speed")
    
    # Determine if we need to change fan speed
    if [ "$target_speed_dec" -gt "$current_speed_dec" ]; then
        # Temperature rising - respond IMMEDIATELY
        log_message "GPU: ${gpu_temp}°C | Hotspot: ${hotspot_temp}°C | Memory: ${memory_temp}°C | Max: ${max_temp}°C → INCREASING fans"
        set_fan_speed "$target_fan_speed"
        current_fan_speed=$target_fan_speed
        pending_decrease_speed=""
        decrease_pending_since=0
        
        # Log event to database
        if [ -n "$DB_FILE" ]; then
            log_fan_event "INCREASE" "$max_temp" "$target_fan_speed" "Temp rising"
        fi
        
    elif [ "$target_speed_dec" -lt "$current_speed_dec" ]; then
        # Temperature dropping - apply hysteresis
        
        if [ "$pending_decrease_speed" != "$target_fan_speed" ]; then
            # This is a new decrease request, start the timer
            pending_decrease_speed=$target_fan_speed
            decrease_pending_since=$(date +%s)
            log_message "GPU: ${gpu_temp}°C | Hotspot: ${hotspot_temp}°C | Memory: ${memory_temp}°C | Max: ${max_temp}°C → Lower fans possible, waiting ${RAMPDOWN_DELAY}s"
        else
            # We're already waiting for this decrease
            current_time=$(date +%s)
            elapsed=$((current_time - decrease_pending_since))
            
            if [ "$elapsed" -ge "$RAMPDOWN_DELAY" ]; then
                # Enough time has passed, apply the decrease
                log_message "GPU: ${gpu_temp}°C | Hotspot: ${hotspot_temp}°C | Memory: ${memory_temp}°C | Max: ${max_temp}°C → DECREASING fans (stable ${elapsed}s)"
                set_fan_speed "$target_fan_speed"
                current_fan_speed=$target_fan_speed
                pending_decrease_speed=""
                decrease_pending_since=0
                
                # Log event to database
                if [ -n "$DB_FILE" ]; then
                    log_fan_event "DECREASE" "$max_temp" "$target_fan_speed" "Temp stable ${elapsed}s"
                fi
            else
                # Still waiting
                remaining=$((RAMPDOWN_DELAY - elapsed))
                log_message "GPU: ${gpu_temp}°C | Hotspot: ${hotspot_temp}°C | Memory: ${memory_temp}°C | Max: ${max_temp}°C → Waiting ${remaining}s before decreasing"
            fi
        fi
        
    else
        # Temperature stable at current fan speed
        log_message "GPU: ${gpu_temp}°C | Hotspot: ${hotspot_temp}°C | Memory: ${memory_temp}°C | Max: ${max_temp}°C → Fan speed optimal"
        # Reset any pending decrease since we're at the right speed
        pending_decrease_speed=""
        decrease_pending_since=0
    fi
    
    # Check for concerning temperature patterns
    if [ "$max_temp" -ge "$TEMP_CRITICAL" ]; then
        log_message "⚠️  CRITICAL: Temperature at ${max_temp}°C! Fans at maximum."
    elif [ "$max_temp" -ge "$TEMP_HOT" ] && [ "$hotspot_temp" -gt "$gpu_temp" ]; then
        log_message "⚠️  NOTICE: Hotspot temp significantly higher than GPU average (Δ$((hotspot_temp - gpu_temp))°C)"
    fi
    
    # Periodic statistics report
    current_time=$(date +%s)
    if [ $((current_time - last_stats_report)) -ge "$STATS_REPORT_INTERVAL" ]; then
        log_statistics_summary
        if [ -n "$DB_FILE" ]; then
            save_statistics_to_database
        fi
        reset_statistics
        last_stats_report=$current_time
    fi

    # Log to database for web dashboard - AFTER decisions are made so we capture the reaction
    if [ -n "$DB_FILE" ] && [ -n "$current_fan_speed" ]; then
        log_to_database "$gpu_temp" "$hotspot_temp" "$memory_temp" "$max_temp" "$gpu_fan_pct" "$current_fan_speed"
    fi
     
    # Update statistics
    if [ -n "$current_fan_speed" ]; then
        update_statistics "$gpu_temp" "$hotspot_temp" "$memory_temp" "$current_fan_speed"
    fi
    
    sleep "$CHECK_INTERVAL"
done
