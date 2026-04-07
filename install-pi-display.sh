#!/bin/bash

# Farin TV Display "Zero-Touch" Setup Script
# Usage: curl -sSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/install-pi-display.sh | bash -s -- --code <CODE> --location <ID>

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

echo "--- 1. Registering Device with Farin Cloud ---"
# Call the setup API directly from the script
RESPONSE=$(curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{\"code\": \"$SETUP_CODE\", \"nickname\": \"Raspberry Pi ($(hostname))\"}")

DEVICE_ID=$(echo "$RESPONSE" | jq -r '.device.id')
DEVICE_TOKEN=$(echo "$RESPONSE" | jq -r '.token')

if [ "$DEVICE_ID" == "null" ] || [ -z "$DEVICE_ID" ]; then
    echo "Error: Registration failed. Response: $RESPONSE"
    exit 1
fi

# Save config for the Python Agent
echo "{\"device_id\": \"$DEVICE_ID\", \"token\": \"$DEVICE_TOKEN\", \"anon_key\": \"$ANON_KEY\", \"ws_url\": \"$SUPABASE_WS_URL\"}" > "$CONFIG_FILE"
echo "Registration successful. Device ID: $DEVICE_ID"

echo "--- 2. Installing OS Dependencies ---"
sudo apt-get update
sudo apt-get install -y chromium-browser x11-xserver-utils unclutter curl jq python3-pip scrot

# Install Python Websocket Client for the Agent
pip3 install websocket-client requests --break-system-packages || pip3 install websocket-client requests

echo "--- 3. Installing Tailscale ---"
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "Tailscale installed. Remember to run 'sudo tailscale up' later."
fi

echo "--- 4. Setting up Remote Management Agent ---"
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
            subprocess.run(['pkill', 'chromium'])

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

# Create Systemd Service for the Agent
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

echo "--- 5. Configuring Kiosk Autostart ---"
mkdir -p "$USER_HOME/.config/autostart"
cat <<EOF > "$USER_HOME/.config/autostart/kiosk.desktop"
[Desktop Entry]
Type=Application
Name=Farin TV Display
Exec=bash -c 'sleep 10 && chromium-browser --noerrdialogs --disable-infobars --kiosk "$PROJECT_URL/tv?token=$DEVICE_TOKEN"'
EOF

# Disable Screen Blanking
cat <<EOF >> "$USER_HOME/.xsessionrc"
xset s off
xset fp rehash
xset -dpms
xset s noblank
unclutter -idle 0.1 -root &
EOF

echo "--- Setup Complete ---"
echo "Device registered and agent started."
echo "Please REBOOT now: sudo reboot"
