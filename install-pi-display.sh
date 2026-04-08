#!/bin/bash

# Farin TV Display "Zero-Touch" Setup Script
# Usage:
#   curl -sSL https://raw.githubusercontent.com/sgerner/tv-kiosk/main/install-pi-display.sh | bash -s -- --code <CODE> [--location <ID>]

set -euo pipefail

# --- Configuration ---
PROJECT_URL="https://farin.app"
API_URL="https://farin.app/api/tv/setup"
SUPABASE_WS_URL="wss://vytrnbknuccguoukzqqd.supabase.co/realtime/v1/websocket"
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlhdCI6MTYzMzg5MTM3NSwiZXhwIjoxOTQ5NDY3Mzc1fQ.J2PR3-m_bsM2I6nmoRVSh69bTx-UwvvIl3-PBtZdWXY"

CURRENT_USER="$(whoami)"
USER_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
CONFIG_FILE="$USER_HOME/.farin-tv-config.json"
AGENT_DIR="$USER_HOME/farin-agent"

SETUP_CODE=""
LOCATION_ID=""
WIFI_SSID=""
WIFI_PASSWORD=""
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
APPLY_WIFI_NOW="no"

# --- Helpers ---
append_if_missing() {
    local file="$1"
    local marker="$2"
    local content="$3"

    touch "$file"
    if ! grep -Fq "$marker" "$file"; then
        printf "\n%s\n" "$content" >> "$file"
    fi
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-no}"
    local reply

    if [[ "$default" == "yes" ]]; then
        read -r -p "$prompt [Y/n]: " reply < /dev/tty || true
        reply="${reply:-Y}"
    else
        read -r -p "$prompt [y/N]: " reply < /dev/tty || true
        reply="${reply:-N}"
    fi

    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

configure_wifi() {
    local ssid="$1"
    local password="$2"
    local country="$3"
    local apply_now="$4"

    if [[ -z "$ssid" ]]; then
        echo "No destination Wi-Fi provided. Skipping Wi-Fi setup."
        return 0
    fi

    echo "--- Configuring destination Wi-Fi: $ssid ---"

    # Prefer NetworkManager if available.
    if command -v nmcli >/dev/null 2>&1; then
        echo "Using NetworkManager (nmcli) to save Wi-Fi credentials..."

        # Remove any existing connection with the same name to avoid duplicates.
        sudo nmcli connection delete "$ssid" >/dev/null 2>&1 || true

        sudo nmcli connection add \
            type wifi \
            con-name "$ssid" \
            ifname "*" \
            ssid "$ssid" >/dev/null

        sudo nmcli connection modify "$ssid" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$password" \
            connection.autoconnect yes \
            802-11-wireless-security.key-mgmt wpa-psk >/dev/null

        if [[ -n "$country" ]]; then
            sudo nmcli connection modify "$ssid" 802-11-wireless.cloned-mac-address permanent >/dev/null 2>&1 || true
        fi

        if [[ "$apply_now" == "yes" ]]; then
            echo "Bringing destination Wi-Fi up now..."
            sudo nmcli connection up "$ssid" || true
        else
            echo "Destination Wi-Fi saved. Current connection left unchanged."
        fi

        return 0
    fi

    # Fallback to wpa_supplicant.
    if command -v wpa_passphrase >/dev/null 2>&1; then
        echo "Using wpa_supplicant to save Wi-Fi credentials..."

        local WPA_FILE="/etc/wpa_supplicant/wpa_supplicant.conf"

        if [[ ! -f "$WPA_FILE" ]]; then
            sudo mkdir -p /etc/wpa_supplicant
            sudo tee "$WPA_FILE" >/dev/null <<EOF
country=$country
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
EOF
        fi

        # Remove an existing network block for the same SSID.
        sudo python3 - "$WPA_FILE" "$ssid" <<'PY'
import re
import sys
path = sys.argv[1]
ssid = sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = f.read()
except FileNotFoundError:
    data = ""

pattern = re.compile(r'\n?network=\{.*?ssid="' + re.escape(ssid) + r'".*?\n\}', re.S)
data = re.sub(pattern, '', data)

with open(path, "w", encoding="utf-8") as f:
    f.write(data.rstrip() + "\n")
PY

        wpa_passphrase "$ssid" "$password" | sudo tee -a "$WPA_FILE" >/dev/null

        if ! grep -q "^country=" "$WPA_FILE"; then
            sudo sed -i "1icountry=$country" "$WPA_FILE"
        fi

        sudo chmod 600 "$WPA_FILE"

        if [[ "$apply_now" == "yes" ]]; then
            echo "Applying Wi-Fi config now..."
            sudo wpa_cli -i wlan0 reconfigure || true
        else
            echo "Destination Wi-Fi saved. It should connect automatically when moved."
        fi

        return 0
    fi

    echo "Warning: Neither nmcli nor wpa_passphrase was found. Wi-Fi credentials were not saved."
    return 0
}

# --- Parse Args ---
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --code)
            if [[ $# -lt 2 ]]; then
                echo "Error: --code requires a value."
                exit 1
            fi
            SETUP_CODE="$2"
            shift 2
            ;;
        --location)
            if [[ $# -lt 2 ]]; then
                echo "Error: --location requires a value."
                exit 1
            fi
            LOCATION_ID="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$SETUP_CODE" ]]; then
    echo "Error: --code is required."
    exit 1
fi

echo "--- 0. Destination Wi-Fi Setup ---"
if prompt_yes_no "Would you like to save the destination Wi-Fi details now?" "yes"; then
    read -r -p "Destination Wi-Fi SSID: " WIFI_SSID < /dev/tty
    read -r -s -p "Destination Wi-Fi password: " WIFI_PASSWORD < /dev/tty
    echo
    read -r -p "Wi-Fi country code [$WIFI_COUNTRY]: " WIFI_COUNTRY_INPUT < /dev/tty
    WIFI_COUNTRY="${WIFI_COUNTRY_INPUT:-$WIFI_COUNTRY}"

    if prompt_yes_no "Switch to that Wi-Fi immediately after saving it?" "no"; then
        APPLY_WIFI_NOW="yes"
    fi
fi

echo "--- 1. Preparing Environment ---"
sudo apt-get update
sudo apt-get install -y \
    curl \
    jq \
    python3 \
    python3-pip \
    chromium \
    x11-xserver-utils \
    unclutter \
    scrot \
    openbox \
    xinit \
    wpasupplicant \
    network-manager

# Low-RAM Optimization. Setup ZRAM on low-memory systems.
TOTAL_MEM_MB="$(free -m | awk '/^Mem:/{print $2}')"
if [[ "${TOTAL_MEM_MB:-0}" -lt 1024 ]]; then
    echo "Low RAM detected. Setting up ZRAM for stability and SD card protection..."

    sudo dphys-swapfile swapoff || true
    sudo apt-get purge -y dphys-swapfile || true
    sudo rm -f /var/swap || true

    sudo modprobe zram || true
    sudo apt-get install -y zram-tools || true

    sudo tee /etc/default/zramswap >/dev/null <<'EOF'
ALGORITHM=zstd
PERCENT=150
PRIORITY=100
EOF

    sudo systemctl daemon-reload || true
    sudo systemctl restart zramswap || echo "Warning: ZRAM may not be fully active until after reboot."

    # Aggressive kernel memory management for 512MB Pi
    cat <<'EOF' | sudo tee /etc/sysctl.d/99-farin-tv.conf >/dev/null
vm.swappiness=80
vm.vfs_cache_pressure=500
vm.min_free_kbytes=16384
vm.overcommit_memory=1
EOF
    sudo sysctl -p /etc/sysctl.d/99-farin-tv.conf || true

    # Reduce GPU RAM allocation on 512MB systems since we only need basic 2D drawing
    if grep -q "^gpu_mem=" /boot/config.txt 2>/dev/null; then
        sudo sed -i 's/^gpu_mem=.*/gpu_mem=64/' /boot/config.txt
    elif grep -q "^gpu_mem=" /boot/firmware/config.txt 2>/dev/null; then
        sudo sed -i 's/^gpu_mem=.*/gpu_mem=64/' /boot/firmware/config.txt
    else
        echo "gpu_mem=64" | sudo tee -a /boot/config.txt >/dev/null
    fi

    # Permanently disable the annoying "less than 1GB RAM" popup injected by the Pi wrapper script
    if [[ -f "/usr/bin/chromium-browser" ]]; then
        sudo sed -i 's/want_memcheck=1/want_memcheck=0/g' /usr/bin/chromium-browser || true
    fi
    if [[ -f "/usr/bin/chromium" ]]; then
        sudo sed -i 's/want_memcheck=1/want_memcheck=0/g' /usr/bin/chromium || true
    fi
fi

echo "--- 2. Registering Device with Farin Cloud ---"
SAFE_HOSTNAME="$(hostname | tr -d '"' | tr -d "\\\\")"

if [[ -n "$LOCATION_ID" ]]; then
    JSON_PAYLOAD="$(jq -n \
        --arg code "$SETUP_CODE" \
        --arg nickname "Raspberry Pi ($SAFE_HOSTNAME)" \
        --arg location_id "$LOCATION_ID" \
        '{code: $code, nickname: $nickname, location_id: $location_id}')"
else
    JSON_PAYLOAD="$(jq -n \
        --arg code "$SETUP_CODE" \
        --arg nickname "Raspberry Pi ($SAFE_HOSTNAME)" \
        '{code: $code, nickname: $nickname}')"
fi

RESPONSE="$(
    curl -sS -w '\n%{http_code}' -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD"
)"

HTTP_STATUS="$(echo "$RESPONSE" | tail -n 1)"
BODY="$(echo "$RESPONSE" | sed '$d')"

if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "Error: Registration failed with status $HTTP_STATUS"
    echo "Response: $BODY"
    exit 1
fi

DEVICE_ID="$(echo "$BODY" | jq -r '.device.id // empty')"
DEVICE_TOKEN="$(echo "$BODY" | jq -r '.token // empty')"

if [[ -z "$DEVICE_ID" || "$DEVICE_ID" == "null" ]]; then
    echo "Error: Could not parse Device ID from response."
    echo "Full Response: $BODY"
    exit 1
fi

if [[ -z "$DEVICE_TOKEN" || "$DEVICE_TOKEN" == "null" ]]; then
    echo "Error: Could not parse device token from response."
    echo "Full Response: $BODY"
    exit 1
fi

mkdir -p "$AGENT_DIR"

cat > "$CONFIG_FILE" <<EOF
{
  "device_id": "$DEVICE_ID",
  "token": "$DEVICE_TOKEN",
  "anon_key": "$ANON_KEY",
  "ws_url": "$SUPABASE_WS_URL"
}
EOF

chmod 600 "$CONFIG_FILE"

echo "Registration successful. Device ID: $DEVICE_ID"

echo "--- 3. Saving Destination Wi-Fi ---"
configure_wifi "$WIFI_SSID" "$WIFI_PASSWORD" "$WIFI_COUNTRY" "$APPLY_WIFI_NOW"

echo "--- 4. Installing Python Dependencies ---"
python3 -m pip install --break-system-packages websocket-client requests || \
python3 -m pip install --user websocket-client requests

echo "--- 5. Installing Tailscale ---"
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "Tailscale installed. Remember to run: sudo tailscale up"
fi

echo "--- 6. Setting up Remote Management Agent ---"
cat > "$AGENT_DIR/agent.py" <<'EOF'
import json
import os
import subprocess
import time
import websocket

CONFIG_PATH = os.path.expanduser("~/.farin-tv-config.json")

def load_config():
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)

def on_message(ws, message):
    data = json.loads(message)

    if data.get("event") == "broadcast" and data.get("payload", {}).get("event") == "command":
        payload = data["payload"].get("payload", {})
        command = payload.get("command")
        print(f"Executing Remote Command: {command}")

        if command == "reboot":
            subprocess.run(["sudo", "reboot"], check=False)

        elif command == "system-update":
            subprocess.Popen(
                ["bash", "-lc", "sudo apt-get update && sudo apt-get upgrade -y"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        elif command == "restart-kiosk":
            subprocess.run(["pkill", "-o", "chromium"], check=False)

        elif command == "rotate-screen":
            direction = payload.get("direction", "normal")
            if direction in ["normal", "inverted", "left", "right"]:
                subprocess.run([f"{os.path.dirname(os.path.abspath(__file__))}/rotate.sh", direction], check=False)

def on_error(ws, error):
    print(f"WebSocket Error: {error}")

def on_close(ws, close_status_code, close_msg):
    print(f"WebSocket closed: {close_status_code} {close_msg}")

def on_open(ws):
    config = load_config()
    subscribe_msg = {
        "topic": f"tv_device:{config['device_id']}",
        "event": "phx_join",
        "payload": {},
        "ref": "1",
    }
    ws.send(json.dumps(subscribe_msg))

def run():
    config = load_config()
    ws_url = f"{config['ws_url']}?apikey={config['anon_key']}&vsn=1.0.0"

    ws = websocket.WebSocketApp(
        ws_url,
        on_message=on_message,
        on_open=on_open,
        on_error=on_error,
        on_close=on_close,
    )
    ws.run_forever()

if __name__ == "__main__":
    while True:
        try:
            run()
        except Exception as e:
            print(f"Agent Error: {e}. Retrying in 10s...")
            time.sleep(10)
EOF

cat > "$AGENT_DIR/kiosk.sh" <<'EOF'
#!/bin/bash
set -u

LOG_DIR="$HOME/.local/state/farin-tv"
LOG_FILE="$LOG_DIR/kiosk.log"
mkdir -p "$LOG_DIR"

URL="${1:-https://farin.app/tv}"

# Wait for network and DNS before launching Chromium to prevent the "offline white screen"
until ping -c 1 farin.app >/dev/null 2>&1; do
    echo "$(date -Is) waiting for farin.app DNS/network" >> "$LOG_FILE"
    sleep 2
done

# Loop forever to restart chromium if it crashes
while true; do
    # Remove chromium error flags
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$HOME/.config/chromium/Default/Preferences" 2>/dev/null || true
    sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$HOME/.config/chromium/Default/Preferences" 2>/dev/null || true

    echo "$(date -Is) launching chromium for $URL" >> "$LOG_FILE"

    /usr/bin/chromium \
        --no-memcheck \
        --no-sandbox \
        --kiosk \
        --noerrdialogs \
        --disable-infobars \
        --no-first-run \
        --password-store=basic \
        --disable-dev-shm-usage \
        --disable-features=Translate,BlinkGenPropertyTrees,site-per-process \
        --disable-sync \
        --js-flags="--max-old-space-size=128" \
        --disk-cache-size=33554432 \
        --autoplay-policy=no-user-gesture-required \
        --enable-logging=stderr \
        --v=1 \
        --remote-debugging-port=9222 \
        --remote-debugging-address=0.0.0.0 \
        "$URL" >> "$LOG_FILE" 2>&1

    echo "$(date -Is) chromium exited with code $?" >> "$LOG_FILE"
    sleep 5
done
EOF

chmod +x "$AGENT_DIR/agent.py" "$AGENT_DIR/kiosk.sh" "$AGENT_DIR/rotate.sh"

sudo tee /etc/systemd/system/farin-agent.service >/dev/null <<EOF
[Unit]
Description=Farin Remote Management Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $AGENT_DIR/agent.py
WorkingDirectory=$AGENT_DIR
Restart=always
RestartSec=5
User=$CURRENT_USER
Environment=HOME=$USER_HOME

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable farin-agent.service
sudo systemctl restart farin-agent.service

echo "--- 7. Setting up Minimal X/Openbox Kiosk ---"

mkdir -p "$USER_HOME/.config/openbox"
if [[ -f "/etc/xdg/openbox/rc.xml" ]]; then
    cp "/etc/xdg/openbox/rc.xml" "$USER_HOME/.config/openbox/rc.xml"
else
    echo '<?xml version="1.0" encoding="UTF-8"?><openbox_config><keyboard></keyboard></openbox_config>' > "$USER_HOME/.config/openbox/rc.xml"
fi

# Inject rotation bindings into the keyboard section
sudo sed -i '/<keyboard>/a \
  <keybind key="C-A-Up">\n    <action name="Execute">\n      <command>'"$AGENT_DIR"'/rotate.sh normal</command>\n    </action>\n  </keybind>\n  <keybind key="C-A-Down">\n    <action name="Execute">\n      <command>'"$AGENT_DIR"'/rotate.sh inverted</command>\n    </action>\n  </keybind>\n  <keybind key="C-A-Left">\n    <action name="Execute">\n      <command>'"$AGENT_DIR"'/rotate.sh left</command>\n    </action>\n  </keybind>\n  <keybind key="C-A-Right">\n    <action name="Execute">\n      <command>'"$AGENT_DIR"'/rotate.sh right</command>\n    </action>\n  </keybind>' "$USER_HOME/.config/openbox/rc.xml"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.config/openbox/rc.xml"

cat > "$USER_HOME/.xinitrc" <<EOF
#!/bin/sh

if [ -f "$USER_HOME/.farin-tv-orientation" ]; then
    xrandr -o "\$(cat "$USER_HOME/.farin-tv-orientation")" || true
fi

xset s off
xset -dpms
xset s noblank
unclutter -idle 0.1 -root &

openbox-session &

exec "$AGENT_DIR/kiosk.sh" "$PROJECT_URL/tv?token=$DEVICE_TOKEN"
EOF

chmod +x "$USER_HOME/.xinitrc"

append_if_missing "$USER_HOME/.bash_profile" "# FARIN_TV_AUTO_START" '
# FARIN_TV_AUTO_START
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  startx
fi
'

cat > "$USER_HOME/.xsessionrc" <<'EOF'
export GNOME_KEYRING_CONTROL=
export GNOME_KEYRING_PID=

xset s off
xset -dpms
xset s noblank
unclutter -idle 0.1 -root &
EOF

mkdir -p "$USER_HOME/.config/autostart"
rm -f "$USER_HOME/.config/autostart/farin-tv-display.desktop"

if command -v raspi-config >/dev/null 2>&1; then
    # Disable Wayland and force legacy X11 for Openbox compatibility
    sudo raspi-config nonint do_wayland W1 || true
    # Boot to console auto-login (X11 will be started by .bash_profile)
    sudo raspi-config nonint do_boot_behaviour B2 || true
    # Don't wait for network at boot (we wait in kiosk.sh instead)
    sudo raspi-config nonint do_boot_wait 0 || true
else
    echo "raspi-config not found. Skipping Raspberry Pi boot configuration."
fi

echo "--- Setup Complete ---"
echo "Device registered and agent started."

if [[ -n "$WIFI_SSID" ]]; then
    echo "Destination Wi-Fi saved: $WIFI_SSID"
    if [[ "$APPLY_WIFI_NOW" == "yes" ]]; then
        echo "Attempted to switch to destination Wi-Fi immediately."
    else
        echo "Current network was left unchanged. The device should connect to the destination Wi-Fi when moved."
    fi
fi

echo "Please reboot now:"
echo "  sudo reboot"
