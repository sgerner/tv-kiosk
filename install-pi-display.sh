#!/bin/bash

# Farin TV Display "Zero-Touch" Setup Script
# Usage: curl -sSL https://raw.githubusercontent.com/sgerner/tv-kiosk/main/install-pi-display.sh | bash -s -- --code <CODE> --location <ID>

set -e

# --- Configuration ---
PROJECT_URL="https://farin.app"
API_URL="https://farin.app/api/tv/setup"
SUPABASE_WS_URL="wss://vytrnbknuccguoukzqqd.supabase.co/realtime/v1/websocket"
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlhdCI6MTYzMzg5MTM3NSwiZXhwIjoxOTQ5NDY3Mzc1fQ.J2PR3-m_bsM2I6nmoRVSh69bTx-UwvvIl3-PBtZdWXY"
USER_HOME="/home/$(whoami)"
CONFIG_FILE="$USER_HOME/.farin-tv-config.json"

# --- Parse Args ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --code) SETUP_CODE="$2"; shift ;;
        --location) LOCATION_ID="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$SETUP_CODE" ]; then echo "Error: --code required."; exit 1; fi

echo "--- 1. Preparing Environment ---"
sudo apt-get update
sudo apt-get install -y curl jq

# Low-RAM Optimization: Increase Swap to 1GB
if [ $(free -m | awk '/^Mem:/{print $2}') -lt 1024 ]; then
    echo "Low RAM detected. Increasing swap space for stability..."
    sudo dphys-swapfile swapoff || true
    sudo sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile
    sudo dphys-swapfile setup
    sudo dphys-swapfile swapon
fi

echo "--- 2. Registering Device with Farin Cloud ---"
# ... (registration logic stays the same) ...
# [Note: I am keeping your existing SAFE_HOSTNAME and curl logic here]
SAFE_HOSTNAME=$(hostname | tr -d '"' | tr -d '\\')
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{\"code\": \"$SETUP_CODE\", \"nickname\": \"Raspberry Pi ($SAFE_HOSTNAME)\"}")

HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "Error: Registration failed with status $HTTP_STATUS"
    echo "Response: $BODY"
    exit 1
fi

DEVICE_ID=$(echo "$BODY" | jq -r '.device.id // empty')
DEVICE_TOKEN=$(echo "$BODY" | jq -r '.token // empty')

if [ -z "$DEVICE_ID" ] || [ "$DEVICE_ID" == "null" ]; then
    echo "Error: Could not parse Device ID from response."
    echo "Full Response: $BODY"
    exit 1
fi

# Save config for the Python Agent
echo "{\"device_id\": \"$DEVICE_ID\", \"token\": \"$DEVICE_TOKEN\", \"anon_key\": \"$ANON_KEY\", \"ws_url\": \"$SUPABASE_WS_URL\"}" > "$CONFIG_FILE"
echo "Registration successful. Device ID: $DEVICE_ID"

echo "--- 3. Installing OS Dependencies ---"
# Switched from chromium-browser to firefox-esr
sudo apt-get install -y firefox-esr x11-xserver-utils unclutter python3-pip scrot

# Install Python Websocket Client for the Agent
pip3 install websocket-client requests --break-system-packages || pip3 install websocket-client requests

echo "--- 4. Installing Tailscale ---"
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "Tailscale installed. Remember to run 'sudo tailscale up' later."
fi

echo "--- 5. Setting up Remote Management Agent ---"
mkdir -p "$USER_HOME/farin-agent"
cat <<'EOF' > "$USER_HOME/farin-agent/agent.py"
import json
import os
import subprocess
import time
import websocket # pip3 install websocket-client

CONFIG_PATH = os.path.expanduser("~/.farin-tv-config.json")

def load_config():
    with open(CONFIG_PATH, 'r') as f:
        return json.load(f)

def on_message(ws, message):
    data = json.loads(message)
    # Supabase Realtime Broadcast Format
    if data.get('event') == 'broadcast' and data.get('payload', {}).get('event') == 'command':
        payload = data['payload'].get('payload', {})
        command = payload.get('command')
        print(f"Executing Remote Command: {command}")
        
        if command == 'reboot':
            subprocess.run(['sudo', 'reboot'])
        elif command == 'system-update':
            # Run update in background to not block the socket
            subprocess.Popen(['bash', '-c', 'sudo apt-get update && sudo apt-get upgrade -y'])
        elif command == 'restart-kiosk':
            # Kill Firefox
            subprocess.run(['pkill', 'firefox'])

def on_open(ws):
    config = load_config()
    # Subscribe to the device channel
    subscribe_msg = {
        "topic": f"tv_device:{config['device_id']}",
        "event": "phx_join",
        "payload": {},
        "ref": "1"
    }
    ws.send(json.dumps(subscribe_msg))

def run():
    config = load_config()
    # WebSocket URL for Supabase Realtime
    ws_url = f"{config['ws_url']}?apikey={config['anon_key']}&vsn=1.0.0"
    
    ws = websocket.WebSocketApp(ws_url, on_message=on_message, on_open=on_open)
    ws.run_forever()

if __name__ == "__main__":
    while True:
        try: run()
        except Exception as e:
            print(f"Agent Error: {e}. Retrying in 10s...")
            time.sleep(10)
EOF

# ... (systemd service logic stays the same) ...
sudo bash -c "cat <<EOF > /etc/systemd/system/farin-agent.service
[Unit]
Description=Farin Remote Management Agent
After=network.target

[Service]
ExecStart=/usr/bin/python3 $USER_HOME/farin-agent/agent.py
WorkingDirectory=$USER_HOME/farin-agent
Restart=always
User=$(whoami)

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable farin-agent.service
sudo systemctl start farin-agent.service

echo "--- 6. Configuring Kiosk Autostart ---"
mkdir -p "$USER_HOME/.config/autostart"

# Create a specialized Firefox profile for the Kiosk to disable all prompts
FF_PROFILE_DIR="$USER_HOME/.mozilla/firefox/farin-kiosk"
mkdir -p "$FF_PROFILE_DIR"
cat <<EOF > "$FF_PROFILE_DIR/user.js"
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage", "$PROJECT_URL/tv?token=$DEVICE_TOKEN");
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.tabs.warnOnClose", false);
user_pref("app.update.auto", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("extensions.update.enabled", false);
EOF

# Update the autostart to use the custom profile and kiosk mode
cat <<EOF > "$USER_HOME/.config/autostart/kiosk.desktop"
[Desktop Entry]
Type=Application
Name=Farin TV Display
Exec=firefox --profile "$FF_PROFILE_DIR" --kiosk "$PROJECT_URL/tv?token=$DEVICE_TOKEN"
EOF

# Disable Screen Blanking and Keyrings
cat <<EOF >> "$USER_HOME/.xsessionrc"
# Disable keyring prompts
export (gnome_keyring_control=)
export (gnome_keyring_pid=)

xset s off
xset fp rehash
xset -dpms
xset s noblank
unclutter -idle 0.1 -root &
EOF

echo "--- Setup Complete ---"
echo "Device registered and agent started."
echo "Please REBOOT now: sudo reboot"
