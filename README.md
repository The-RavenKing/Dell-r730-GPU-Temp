# Dell R730 GPU Temperature-Based Fan Controller
## Optimized for LLM Inference Workloads

This script provides dynamic fan control for Dell PowerEdge R730 servers with Nvidia GPUs (like the Quadro RTX 4000). It monitors GPU temperature and automatically adjusts server fan speeds to maintain optimal cooling without excessive noise.

**Special optimizations for LLM inference (Ollama, KoboldCPP, OpenBot):**
- **Fast 5-second response** to catch rapid temperature spikes during inference
- **Multi-sensor monitoring** - tracks GPU core, hotspot, and memory temperatures
- **Intelligent fan control** - uses the highest temperature reading for safety
- **Hysteresis logic** - fans ramp UP immediately when temp rises, ramp DOWN gradually when temp drops
- **Prevents fan oscillation** during the bursty load patterns typical of LLM work
- **Statistics tracking** - monitors peak temps, fan usage, and provides hourly summaries
- **Smart alerts** - warns you if cooling is inadequate or temps are concerning
- **Web Dashboard** - real-time monitoring and historical data visualization in your browser

## The Problem

When you install a non-Dell PCIe card (like an Nvidia GPU) into a Dell R730, the server's iDRAC firmware automatically ramps the fans to very high speeds (often 15,000+ RPM or 66-100% fan speed). This is Dell's safety mechanism for third-party cards that haven't been validated.

This script solves that problem by:
1. Disabling Dell's aggressive third-party PCIe cooling response
2. Taking manual control of fan speeds
3. Monitoring GPU core, hotspot, and memory temperatures every 5 seconds
4. Using the highest temperature reading for fan speed decisions (protects against hotspots)
5. Dynamically adjusting fan speeds based on actual temperature needs
6. Using hysteresis to prevent annoying fan speed oscillation:
   - When temperature **rises** → Fans increase **immediately** (protect hardware)
   - When temperature **drops** → Fans decrease after **20 seconds** (prevent oscillation)
7. Tracking statistics and providing insights into cooling performance

## Requirements

### Software
- **ipmitool** - For IPMI communication with iDRAC
  - Linux: `sudo apt-get install ipmitool` (Debian/Ubuntu) or `sudo yum install ipmitool` (RHEL/CentOS)
  - Windows: Install Dell OpenManage BMC Utility
- **nvidia-smi** - Comes with Nvidia drivers
- **Bash shell** - For running the script (Linux/macOS)
- **SQLite3** - For database storage (optional, but required for web dashboard)
  - Linux: `sudo apt-get install sqlite3` (Debian/Ubuntu) or `sudo yum install sqlite3` (RHEL/CentOS)
- **Python 3 + Flask** - For web dashboard (optional)
  - Linux: `sudo apt-get install python3 python3-pip && pip3 install flask`

### Hardware
- Dell PowerEdge R730 (or R730xd)
- Nvidia GPU with temperature sensors
- iDRAC with network access

### iDRAC Configuration
1. Log into your iDRAC web interface
2. Go to: iDRAC Settings → Network → IPMI Settings
3. Enable "Enable IPMI over LAN"
4. Set/verify iDRAC IP address and credentials
5. Click "Apply"

## Installation

### 1. Edit Configuration

Open `dell_gpu_fan_control.sh` and modify these lines at the top:

```bash
IDRAC_HOST="192.168.1.100"  # Change to your iDRAC IP
IDRAC_USER="root"            # Change to your iDRAC username
IDRAC_PASS="calvin"          # Change to your iDRAC password
```

### 2. Adjust Temperature Thresholds (Optional)

The script comes pre-configured with thresholds optimized for LLM inference workloads:

```bash
# Optimized for bursty LLM inference loads
TEMP_LOW=40        # Below this: minimum fan speed (20%)
TEMP_NORMAL=50     # Normal operation (30%)
TEMP_WARM=60       # Moderate cooling (40%)
TEMP_HOT=70        # Increased cooling (55%)
TEMP_CRITICAL=80   # High cooling (70%+)

# Check interval - 5 seconds for fast response to inference bursts
CHECK_INTERVAL=5

# Hysteresis - prevents fan oscillation
RAMPDOWN_DELAY=20  # Wait 20s before decreasing fans
```

**Why these settings work for LLM inference:**
- Lower thresholds (40-60°C) keep the GPU cooler during idle periods
- 5-second checks catch temperature spikes from inference bursts quickly
- 20-second rampdown prevents fans from constantly cycling during typical LLM usage patterns (prompt → inference → idle → repeat)

For the Quadro RTX 4000, the maximum operating temperature is around 90°C, but these thresholds keep it well below that with good safety margins.

**Adjusting for your environment:**
- **Warmer room/datacenter?** Lower all thresholds by 5-10°C
- **24/7 heavy inference?** Consider lowering TEMP_WARM to 55°C
- **Noise sensitive?** Increase TEMP_WARM to 65°C (but monitor temps closely)
- **Fans cycling too much?** Increase RAMPDOWN_DELAY to 30-40 seconds

### 3. Install the Script

```bash
# Make the script executable
chmod +x dell_gpu_fan_control.sh

# Copy to system location
sudo cp dell_gpu_fan_control.sh /usr/local/bin/

# Create log directory
sudo mkdir -p /var/log
```

### 4. Test the Script

Before setting it up as a service, test it manually:

```bash
sudo /usr/local/bin/dell_gpu_fan_control.sh
```

Watch the output for a few minutes. You should see:
- GPU temperature readings from multiple sensors (GPU, hotspot, memory)
- The maximum temperature used for fan decisions
- Fan speed adjustments with clear reasoning
- No errors

Example output:
```
2026-02-11 10:15:23 - GPU: 45°C | Hotspot: 48°C | Memory: 42°C | Max: 48°C → Fan speed optimal
2026-02-11 10:15:28 - GPU: 67°C | Hotspot: 79°C | Memory: 63°C | Max: 79°C → INCREASING fans
```

Press Ctrl+C to stop. The script should restore automatic fan control and display a statistics summary.

### 5. Set Up as a System Service (Linux)

This makes the script run automatically at startup:

```bash
# Copy the service file
sudo cp dell-gpu-fan-control.service /etc/systemd/system/

# Edit the service file to match your iDRAC credentials (in ExecStop line)
sudo nano /etc/systemd/system/dell-gpu-fan-control.service

# Reload systemd
sudo systemctl daemon-reload

# Enable the service to start at boot
sudo systemctl enable dell-gpu-fan-control.service

# Start the service now
sudo systemctl start dell-gpu-fan-control.service

# Check status
sudo systemctl status dell-gpu-fan-control.service
```

### 6. Monitor the Service

```bash
# View live logs
sudo journalctl -u dell-gpu-fan-control.service -f

# View log file
sudo tail -f /var/log/dell_gpu_fan_control.log
```

### 7. Set Up Web Dashboard (Optional but Recommended!)

The web dashboard provides a beautiful real-time interface to monitor your GPU temperatures and fan speeds from any device on your network.

**Features:**
- 📊 Real-time temperature graphs (GPU core, hotspot, memory)
- 📈 Historical data visualization (24h, 7d, 30d views)
- 🔄 Recent fan speed change events log
- 📉 Statistics summaries with min/max/average temps
- 🔄 Auto-refresh every 5 seconds
- 📱 Mobile-friendly responsive design

**Installation:**

```bash
# Install Python Flask (if not already installed)
sudo apt-get install python3 python3-pip
sudo pip3 install flask

# Create installation directory
sudo mkdir -p /opt/dell-gpu-fan-control
sudo mkdir -p /opt/dell-gpu-fan-control/templates

# Copy dashboard files
sudo cp dashboard_server.py /opt/dell-gpu-fan-control/
sudo cp templates/dashboard.html /opt/dell-gpu-fan-control/templates/
sudo chmod +x /opt/dell-gpu-fan-control/dashboard_server.py

# Set up the dashboard service
sudo cp dell-gpu-dashboard.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable and start the dashboard service
sudo systemctl enable dell-gpu-dashboard.service
sudo systemctl start dell-gpu-dashboard.service

# Check status
sudo systemctl status dell-gpu-dashboard.service
```

**Access the Dashboard:**

Open your web browser and navigate to:
- From the server itself: `http://localhost:8080`
- From another computer on your network: `http://YOUR_SERVER_IP:8080`

For example, if your server's IP is `192.168.1.50`, open: `http://192.168.1.50:8080`

**Dashboard Views:**

1. **Current Readings** - Large cards showing current temps and fan speed
2. **Real-Time Monitor** - Line chart showing the last 15min/30min/1hr of data
3. **Historical Data** - Hourly averages over 24h/7d/30d with statistics
4. **Recent Events** - Log of fan speed increases/decreases with timestamps

**Troubleshooting Dashboard:**

```bash
# Check if dashboard service is running
sudo systemctl status dell-gpu-dashboard.service

# View dashboard logs
sudo journalctl -u dell-gpu-dashboard.service -f

# Test manually
cd /opt/dell-gpu-fan-control
python3 dashboard_server.py

# Check if port 8080 is accessible
sudo netstat -tulpn | grep 8080

# If you need to use a different port, edit dashboard_server.py
# Change the PORT = 8080 line to your desired port
```

**Security Note:**

The dashboard listens on all network interfaces (0.0.0.0) by default, making it accessible from your local network. If your server is exposed to the internet, consider:
- Using a firewall to restrict access to trusted IPs only
- Setting up a reverse proxy with HTTPS and authentication
- Changing the HOST variable in dashboard_server.py to '127.0.0.1' (localhost only)

## How the Script Handles LLM Workloads

**The Challenge:** LLM inference creates extremely bursty GPU loads:
```
Idle (40°C) → You send prompt → GPU spikes to 100% → Temp jumps to 70°C in 10s → 
Inference completes → GPU drops to idle → Temp drops back to 45°C in 30s
```

Without smart fan control, your fans would be constantly ramping up and down with every prompt, which is annoying and wears out fan bearings.

**How This Script Solves It:**

1. **Fast Temperature Monitoring (5 seconds)**
   - Checks GPU temp every 5 seconds
   - Catches temperature spikes before they become dangerous
   - Much faster than the 30-second intervals used in general-purpose scripts

2. **Aggressive Upward Response**
   - Temperature rises above threshold? Fans increase **immediately**
   - No delay - protects your GPU from thermal damage
   - Example: Temp 55°C → 65°C = fans go from 30% to 40% within 5 seconds

3. **Gentle Downward Response (Hysteresis)**
   - Temperature drops below threshold? Script waits 20 seconds
   - Only decreases fans if temperature **stays low** for the full delay
   - If temp spikes again during the wait, the timer resets
   - Example: After inference completes, fans stay at 40% for 20 seconds to ensure the GPU isn't about to spike again

**Real-World Example:**
```
00:00 - GPU idle at 42°C, fans at 20%
00:05 - You submit a prompt to Ollama
00:10 - GPU temp hits 68°C, fans immediately ramp to 55%
00:45 - Inference completes, GPU drops to 52°C
00:45 - Script sees lower temp but waits (hysteresis)
01:05 - 20 seconds passed, temp still at 52°C, fans decrease to 30%
01:10 - Another prompt! Temp spikes to 65°C, fans immediately back to 55%
```

This prevents your fans from sounding like a jet engine cycling up and down every 30 seconds!

## Multi-Sensor Temperature Monitoring

**Why Monitor Multiple Sensors?**

The Quadro RTX 4000 (and most modern GPUs) have multiple temperature sensors:

1. **GPU Core Temperature** - Average temperature of the main GPU die
2. **GPU Hotspot Temperature** - The single hottest point on the die (usually 10-15°C hotter than average)
3. **Memory Temperature** - Temperature of the VRAM chips

During LLM inference, different parts of the GPU heat up differently:
- **Text encoding/decoding** → Mostly GPU core and memory
- **Heavy matrix operations** → Can create hotspots on specific compute units
- **Large model loading** → VRAM gets hot

**How the Script Uses This:**

The script monitors all three temperatures and uses **whichever is highest** for fan control decisions:

```
Example during inference:
GPU Core: 65°C
Hotspot:  78°C  ← This one is highest!
Memory:   62°C

Fan decision based on: 78°C (hotspot)
```

This ensures your GPU is protected even if one area is heating up more than the average would suggest.

**Log Output:**
```
GPU: 65°C | Hotspot: 78°C | Memory: 62°C | Max: 78°C → INCREASING fans
```

## Statistics & Monitoring

The script automatically tracks and logs statistics every hour:

**What's Tracked:**
- Peak temperatures reached (GPU, hotspot, memory)
- Average GPU temperature over the period
- Number of times fans hit 90%+ (high cooling events)
- Number of high temperature warnings (temps above 70°C)
- Runtime duration

**Example Hourly Summary:**
```
==========================================
Statistics Summary (Runtime: 1h 15m)
Peak GPU Temp: 72°C
Peak Hotspot Temp: 84°C
Peak Memory Temp: 68°C
Average GPU Temp: 58°C
High Fan Speed Events (90%+): 3
High Temperature Warnings (70°C+): 12
==========================================
```

**Automatic Alerts:**

The script provides smart cooling adequacy assessments:

1. **Critical Warning** - If peak temps hit 80°C+:
   ```
   ⚠️  WARNING: Peak temps reached critical levels. Consider:
      - Lowering temperature thresholds
      - Increasing minimum fan speeds
      - Checking for dust buildup
   ```

2. **Frequent High Temp Notice** - If GPU runs hot >25% of the time:
   ```
   ⚠️  NOTICE: GPU running hot frequently (>25% of time)
      Consider lowering TEMP_WARM threshold by 5°C
   ```

3. **Hotspot Delta Warning** - If hotspot is much hotter than average:
   ```
   ⚠️  NOTICE: Hotspot temp significantly higher than GPU average (Δ13°C)
   ```

These alerts help you fine-tune your cooling configuration over time.

## Manual IPMI Commands

If you just want to disable the aggressive cooling without the script:

### Disable Third-Party PCIe Cooling Response
```bash
ipmitool -I lanplus -H <IDRAC_IP> -U <USER> -P <PASS> raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00
```

### Check Current Status
```bash
ipmitool -I lanplus -H <IDRAC_IP> -U <USER> -P <PASS> raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00
```

Response meanings:
- `16 05 00 00 00 05 00 01 00 00` = Disabled (good)
- `16 05 00 00 00 05 00 00 00 00` = Enabled (default)

### Set Manual Fan Speed
```bash
# Enable manual control
ipmitool -I lanplus -H <IDRAC_IP> -U <USER> -P <PASS> raw 0x30 0x30 0x01 0x00

# Set fan speed (0x1E = 30%)
ipmitool -I lanplus -H <IDRAC_IP> -U <USER> -P <PASS> raw 0x30 0x30 0x02 0xff 0x1E
```

### Restore Automatic Control
```bash
ipmitool -I lanplus -H <IDRAC_IP> -U <USER> -P <PASS> raw 0x30 0x30 0x01 0x01
```

## Temperature Monitoring

### Check GPU Temperatures
```bash
# All temperature sensors
nvidia-smi --query-gpu=temperature.gpu,temperature.memory --format=csv

# Basic GPU temperature
nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader

# Full GPU info including all sensors
nvidia-smi

# Continuous monitoring (updates every 2 seconds)
watch -n 2 nvidia-smi

# View script's log in real-time (shows all three temps)
sudo tail -f /var/log/dell_gpu_fan_control.log
```

## Important Warnings

⚠️ **CRITICAL SAFETY INFORMATION:**

1. **Monitor temperatures closely** for the first few days after setup
2. **Stress test your system** with GPU load to verify cooling is adequate
   - Use tools like `furmark` or run GPU-intensive workloads
3. **This script bypasses Dell's safety mechanisms** - you're responsible for proper cooling
4. **If the script crashes**, fan control may not restore automatically
5. **Keep ambient temperature reasonable** - the script assumes normal datacenter/room temps
6. **Check GPU thermal limits** - The Quadro RTX 4000 has a max temp around 90°C
7. **Backup your data** before implementing this solution

### Signs of Inadequate Cooling:
- GPU temperature consistently above 80°C under load
- System throttling performance
- Unexpected shutdowns
- GPU errors in logs

If you see these, increase the fan speeds in the script or restore automatic control.

## Troubleshooting

### Script won't start
- Verify IPMI over LAN is enabled in iDRAC
- Test ipmitool connectivity: `ipmitool -I lanplus -H <IP> -U <USER> -P <PASS> sdr list`
- Check nvidia-smi works: `nvidia-smi`

### Fans still at full speed
- The third-party PCIe response might re-enable after BIOS updates
- Re-run the disable command manually
- Check iDRAC logs for thermal warnings

### GPU overheating
- Lower temperature thresholds in the script
- Increase minimum fan speed
- Check for dust buildup in server and GPU heatsink
- Verify GPU thermal paste hasn't degraded
- Check if hotspot temps are significantly higher than GPU average (>15°C difference)
  - This could indicate poor thermal paste application or mounting pressure
- Review hourly statistics summaries for patterns

### Service won't stay running
- Check logs: `sudo journalctl -u dell-gpu-fan-control.service -n 50`
- Verify iDRAC credentials are correct
- Test script manually first

## Future Implementation: AI-Driven Analytics & Control

**Concept:**
We are exploring the integration of an AI model to analyze long-term temperature and usage patterns. Instead of relying solely on static thresholds, this system would:

1.  **Learn Your Workload:**
    -   Monitor GPU usage patterns over days/weeks (e.g., identifying when heavy inference tasks usually occur).
    -   Correlate fan speeds with temperature drop rates to understand cooling efficiency in your specific environment.

2.  **Predictive Cooling:**
    -   Anticipate temperature spikes based on historical usage data.
    -   Pre-emptively ramp up fans *before* a heavy task causes thermal throttling, smoothing out the temperature curve.

3.  **Optimization Suggestions:**
    -   Analyze the relationship between fan speed and temperature to find the "sweet spot" for noise vs. cooling.
    -   Examples:
        -   "You could lower fan speeds by 10% during idle periods with no risk."
        -   "Your GPU hotspot delta is increasing; consider repasting."

4.  **Anomaly Detection:**
    -   Detect if cooling performance degrades over time (e.g., due to dust buildup) by comparing current cooling efficiency against the baseline.

*Note: This is currently in the conceptual phase.*

## Alternative Solutions

1. **Pre-made Docker solution**: Check out [tigerblue77/Dell_iDRAC_fan_controller_Docker](https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker)
2. **Python PID controller**: Check out [kk7ds/dellfancontrol](https://github.com/kk7ds/dellfancontrol)

## References

- [Dell KB: Disable Third-Party PCIe Cooling Response](https://www.dell.com/support/kbdoc/en-us/000135682/)
- [Nvidia-SMI Documentation](https://docs.nvidia.com/deploy/nvidia-smi/index.html)
- Dell Community discussions on R730 fan control

## License

This script is provided as-is, without warranty. Use at your own risk. You are responsible for monitoring your system's thermal performance and ensuring adequate cooling.

## Contributing

If you improve this script or find issues, please share your findings. This is particularly helpful for the community dealing with Dell servers and third-party hardware.
