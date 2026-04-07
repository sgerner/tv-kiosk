#!/bin/bash
set -euo pipefail

# Farin TV Display Update Script
# Updates the agent and Openbox config on existing kiosks.

CURRENT_USER="$(whoami)"
USER_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
AGENT_DIR="$USER_HOME/farin-agent"

echo "--- 1. Updating Remote Management Agent ---"

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
            subprocess.run(["pkill", "-f", "kiosk.py"], check=False)

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

cat > "$AGENT_DIR/rotate.sh" <<'EOF'
#!/bin/sh
xrandr -display :0 -o "$1"
echo "$1" > "$HOME/.farin-tv-orientation"
EOF

chmod +x "$AGENT_DIR/agent.py" "$AGENT_DIR/rotate.sh"
sudo systemctl restart farin-agent.service

echo "--- 2. Updating Openbox Configuration ---"
mkdir -p "$USER_HOME/.config/openbox"
if [[ ! -f "$USER_HOME/.config/openbox/rc.xml" ]]; then
    if [[ -f "/etc/xdg/openbox/rc.xml" ]]; then
        cp "/etc/xdg/openbox/rc.xml" "$USER_HOME/.config/openbox/rc.xml"
    else
        echo '<?xml version="1.0" encoding="UTF-8"?><openbox_config><keyboard></keyboard></openbox_config>' > "$USER_HOME/.config/openbox/rc.xml"
    fi
    sudo chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.config/openbox/rc.xml"
fi

# Ensure we don't duplicate bindings if already present
# First, remove any old xrandr bindings we might have injected previously
sudo sed -i '/<keybind key="C-A-.*">/,/<\/keybind>/d' "$USER_HOME/.config/openbox/rc.xml"

# Inject the new rotate.sh bindings
sudo sed -i '/<keyboard>/a \
  <keybind key="C-A-Up">\n    <action name="Execute">\n      <command>'"$AGENT_DIR"'/rotate.sh normal</command>\n    </action>\n  </keybind>\n  <keybind key="C-A-Down">\n    <action name="Execute">\n      <command>'"$AGENT_DIR"'/rotate.sh inverted</command>\n    </action>\n  </keybind>\n  <keybind key="C-A-Left">\n    <action name="Execute">\n      <command>'"$AGENT_DIR"'/rotate.sh left</command>\n    </action>\n  </keybind>\n  <keybind key="C-A-Right">\n    <action name="Execute">\n      <command>'"$AGENT_DIR"'/rotate.sh right</command>\n    </action>\n  </keybind>' "$USER_HOME/.config/openbox/rc.xml"

echo "--- 3. Updating Xinitrc to Persist Rotation ---"
if ! grep -q 'farin-tv-orientation' "$USER_HOME/.xinitrc"; then
    sudo sed -i '1 a\
\
if [ -f "$HOME/.farin-tv-orientation" ]; then\
    xrandr -o "$(cat "$HOME/.farin-tv-orientation")" || true\
fi\
' "$USER_HOME/.xinitrc"
fi

echo "--- Update Complete ---"
echo "The agent has been restarted. You can apply the new Openbox bindings by rebooting: sudo reboot"
