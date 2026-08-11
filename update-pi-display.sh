#!/bin/bash
set -euo pipefail

# Farin TV Display Update Script
# Updates the agent and Openbox config on existing kiosks.

CURRENT_USER="$(whoami)"
USER_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
AGENT_DIR="$USER_HOME/farin-agent"
CONFIG_FILE="$USER_HOME/.farin-tv-config.json"
PROJECT_URL="https://farin.app"
DEVICE_TOKEN="$(jq -r '.token // empty' "$CONFIG_FILE" 2>/dev/null || true)"
UPDATE_REQUESTED_AT="${FARIN_UPDATE_REQUESTED_AT:-}"
UPDATE_TOKEN="${FARIN_DEVICE_TOKEN:-$DEVICE_TOKEN}"
UPDATE_MARKER="${FARIN_UPDATE_MARKER:-}"
UPDATE_REPORTED=0

report_update_status() {
    local status="$1"
    local details="${2:-}"
    [[ -n "$UPDATE_REQUESTED_AT" && -n "$UPDATE_TOKEN" ]] || return 0
    local body
    body="$(jq -cn \
        --arg requested_at "$UPDATE_REQUESTED_AT" \
        --arg status "$status" \
        --arg error "$details" \
        --arg version "2026-08-10-remote-update-v1" \
        '{requested_at:$requested_at,status:$status,error:($error // ""),version:$version}')"
    if curl -fsS --max-time 15 \
        -X POST "$PROJECT_URL/api/tv/command" \
        -H "Authorization: Bearer $UPDATE_TOKEN" \
        -H 'Content-Type: application/json' \
        --data "$body" >/dev/null; then
        if [[ "$status" == "completed" || "$status" == "failed" ]]; then
            UPDATE_REPORTED=1
        fi
    fi
}

cleanup_update_marker() {
    if [[ -n "$UPDATE_MARKER" ]]; then
        rm -f -- "$UPDATE_MARKER" || true
    fi
}

on_update_exit() {
    local exit_code="$?"
    if [[ -n "$UPDATE_REQUESTED_AT" && "$UPDATE_REPORTED" -eq 0 ]]; then
        if [[ "$exit_code" -eq 0 ]]; then
            report_update_status completed
        else
            report_update_status failed "Updater exited with code $exit_code"
        fi
    fi
    cleanup_update_marker
    exit "$exit_code"
}

trap on_update_exit EXIT

echo "--- 1. Updating Remote Management Agent ---"

if [[ -f "$CONFIG_FILE" ]]; then
    TMP_CONFIG="$(mktemp)"
    jq --arg project_url "$PROJECT_URL" '.project_url = $project_url' "$CONFIG_FILE" > "$TMP_CONFIG"
    mv "$TMP_CONFIG" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi

cat > "$AGENT_DIR/agent.py" <<'EOF'
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
except Exception:
    pass

CONFIG_PATH = os.path.expanduser("~/.farin-tv-config.json")
AGENT_VERSION = "2026-08-10-remote-update-v1"
POLL_INTERVAL_SECONDS = 5
KIOSK_UPDATE_URL = "https://raw.githubusercontent.com/sgerner/tv-kiosk/main/update-pi-display.sh"


def load_config():
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)

def normalize_rotation(value):
    rotation = str(value or "").strip().lower()
    return rotation if rotation in ["normal", "inverted", "left", "right"] else "normal"

def project_url(config):
    return str(config.get("project_url") or "https://farin.app").rstrip("/")


def auth_headers(config):
    return {
        "Authorization": f"Bearer {config['token']}",
        "Content-Type": "application/json",
        "User-Agent": f"Mozilla/5.0 (compatible; FarinTVAgent/{AGENT_VERSION})",
        "X-Farin-Agent-Version": AGENT_VERSION,
    }


def command_endpoint(config):
    return f"{project_url(config)}/api/tv/command"


def http_json(url, headers, method="GET", payload=None, timeout=20):
    body = None
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_command(config):
    try:
        return http_json(command_endpoint(config), auth_headers(config))
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        print(f"Command poll failed: HTTP {exc.code} {details}", flush=True)
    except Exception as exc:
        print(f"Command poll failed: {exc}", flush=True)
    return {"command": None}


def ack_command(config, requested_at):
    if not requested_at:
        return
    try:
        http_json(
            command_endpoint(config),
            auth_headers(config),
            method="POST",
            payload={"requested_at": requested_at},
        )
        print(f"Command acknowledged: {requested_at}", flush=True)
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        print(f"Command ack failed: HTTP {exc.code} {details}", flush=True)
    except Exception as exc:
        print(f"Command ack failed: {exc}", flush=True)


def report_command_status(config, requested_at, status, details=None, version=None):
    payload = {
        "requested_at": requested_at,
        "status": status,
        "error": details or "",
        "version": version or AGENT_VERSION,
    }
    try:
        http_json(command_endpoint(config), auth_headers(config), method="POST", payload=payload)
    except Exception as exc:
        print(f"Command status report failed: {exc}", flush=True)


def update_marker_path(requested_at):
    import hashlib

    digest = hashlib.sha256(requested_at.encode("utf-8")).hexdigest()[:24]
    marker_dir = os.path.expanduser("~/.config/farin-tv")
    os.makedirs(marker_dir, exist_ok=True)
    return os.path.join(marker_dir, f"kiosk-update-{digest}.active")


def is_approved_update_url(value):
    parsed = urllib.parse.urlparse(value)
    parts = parsed.path.strip("/").split("/")
    return (
        parsed.scheme == "https"
        and parsed.netloc == "raw.githubusercontent.com"
        and len(parts) == 4
        and parts[0] == "sgerner"
        and parts[1] == "tv-kiosk"
        and parts[3] == "update-pi-display.sh"
    )


def start_kiosk_update(config, requested_at, payload):
    import hashlib
    import re

    update_url = str((payload or {}).get("update_url") or KIOSK_UPDATE_URL).strip()
    expected_sha256 = str((payload or {}).get("update_sha256") or "").strip().lower()
    if not is_approved_update_url(update_url):
        print("Ignoring update with an unapproved URL", flush=True)
        report_command_status(config, requested_at, "failed", "Unapproved updater URL")
        return False
    if expected_sha256 and not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        print("Ignoring update with an invalid SHA-256", flush=True)
        report_command_status(config, requested_at, "failed", "Invalid updater SHA-256")
        return False

    marker = update_marker_path(requested_at)
    if os.path.exists(marker):
        return False
    with open(marker, "w", encoding="utf-8") as marker_file:
        marker_file.write(requested_at)

    report_command_status(config, requested_at, "started")
    digest = hashlib.sha256(requested_at.encode("utf-8")).hexdigest()[:12]
    home = os.path.expanduser("~")
    expected_literal = expected_sha256.replace("'", "")
    wrapper = """set -eu
tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT
curl -fsSL --max-time 120 "$FARIN_KIOSK_UPDATE_URL" -o "$tmp_file"
if [ -n "$FARIN_KIOSK_UPDATE_SHA256" ]; then
    echo "$FARIN_KIOSK_UPDATE_SHA256  $tmp_file" | sha256sum -c -
fi
bash "$tmp_file"
"""
    command = [
        "sudo",
        "systemd-run",
        f"--unit=farin-kiosk-update-{digest}",
        "--collect",
        f"--uid={os.getuid()}",
        f"--setenv=HOME={home}",
        f"--setenv=FARIN_KIOSK_UPDATE_URL={update_url}",
        f"--setenv=FARIN_KIOSK_UPDATE_SHA256={expected_literal}",
        f"--setenv=FARIN_DEVICE_TOKEN={config['token']}",
        f"--setenv=FARIN_UPDATE_REQUESTED_AT={requested_at}",
        f"--setenv=FARIN_UPDATE_MARKER={marker}",
        "/bin/bash",
        "-lc",
        wrapper,
    ]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Failed to schedule kiosk update: {result.stderr.strip()}", flush=True)
        report_command_status(config, requested_at, "failed", "Could not schedule updater")
        try:
            os.unlink(marker)
        except FileNotFoundError:
            pass
    return False


def execute_command(command, payload, config, requested_at):
    print(f"Executing Remote Command: {command}", flush=True)
    if command == "reboot":
        subprocess.Popen(["sudo", "reboot"])
        return True
    if command == "system-update":
        subprocess.Popen(
            ["bash", "-lc", "sudo apt-get update && sudo apt-get upgrade -y"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    if command == "restart-kiosk":
        subprocess.run(["pkill", "-o", "chromium"], check=False)
        return True
    if command == "refresh":
        subprocess.run(["pkill", "-o", "chromium"], check=False)
        return True
    if command == "clear-cache":
        subprocess.run(["pkill", "-o", "chromium"], check=False)
        return True
    if command == "reidentify":
        print("Device identification is handled by the browser when available", flush=True)
        return True
    if command == "update-kiosk":
        return start_kiosk_update(config, requested_at, payload)
    if command == "rotate-screen":
        direction = str((payload or {}).get("direction") or "normal").lower()
        if direction in ["normal", "inverted", "left", "right"]:
            subprocess.run([f"{os.path.dirname(os.path.abspath(__file__))}/rotate.sh", direction], check=False)
            return True
        print(f"Ignoring invalid rotation direction: {direction}", flush=True)
        return False
    print(f"Ignoring unsupported command: {command}", flush=True)
    return False

if __name__ == "__main__":
    while True:
        try:
            config = load_config()
            result = fetch_command(config)
            command = result.get("command")
            requested_at = result.get("requested_at")
            payload = result.get("payload") or {}
            if command and requested_at:
                if execute_command(command, payload, config, requested_at):
                    ack_command(config, requested_at)
            time.sleep(POLL_INTERVAL_SECONDS)
        except Exception as e:
            print(f"Agent Error: {e}. Retrying in 10s...")
            time.sleep(10)
EOF

cat > "$AGENT_DIR/rotate.sh" <<'EOF'
#!/bin/sh
set -eu

DIRECTION="${1:-normal}"
DISPLAY_VALUE="${DISPLAY:-:0}"
XAUTHORITY_VALUE="${XAUTHORITY:-$HOME/.Xauthority}"

case "$DIRECTION" in
    normal|inverted|left|right) ;;
    *)
        echo "Invalid rotation direction: $DIRECTION" >&2
        exit 1
        ;;
esac

if [ ! -f "$XAUTHORITY_VALUE" ]; then
    echo "Missing Xauthority file: $XAUTHORITY_VALUE" >&2
    exit 1
fi

if ! DISPLAY="$DISPLAY_VALUE" XAUTHORITY="$XAUTHORITY_VALUE" xrandr -q >/dev/null 2>&1; then
    echo "Unable to query X display $DISPLAY_VALUE with XAUTHORITY=$XAUTHORITY_VALUE" >&2
    exit 1
fi

DISPLAY="$DISPLAY_VALUE" XAUTHORITY="$XAUTHORITY_VALUE" xrandr -o "$DIRECTION"
printf '%s\n' "$DIRECTION" > "$HOME/.farin-tv-orientation"
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

echo "--- 4. Upgrading Kiosk from PyQt6 to Chromium ---"
sudo apt-get update
sudo apt-get install -y chromium zram-tools
sudo apt-get remove -y python3-pyqt6 python3-pyqt6.qtwebengine || true
sudo apt-get autoremove -y || true

cat > "$AGENT_DIR/kiosk.sh" <<'EOF'
#!/bin/bash
set -u

PROFILE_DIR="$HOME/.config/farin-tv/chromium-profile"
LOG_FILE="$HOME/.farin-tv-kiosk.log"
mkdir -p "$PROFILE_DIR"

URL="${1:-https://farin.app/tv}"
DISPLAY="${DISPLAY:-:0}"
XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

while true; do
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$PROFILE_DIR/Default/Preferences" 2>/dev/null || true
    sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$PROFILE_DIR/Default/Preferences" 2>/dev/null || true

    # Remove stale profile locks if no Chromium process owns this profile.
    if ! pgrep -af "/usr/lib/chromium/chromium .*--user-data-dir=$PROFILE_DIR" >/dev/null 2>&1 &&
       ! pgrep -af "/usr/bin/chromium .*--user-data-dir=$PROFILE_DIR" >/dev/null 2>&1; then
        rm -f "$PROFILE_DIR/SingletonLock" "$PROFILE_DIR/SingletonSocket" "$PROFILE_DIR/SingletonCookie"
    fi

    echo "$(date -Is) launching chromium for $URL" | tee -a "$LOG_FILE"

    DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" /usr/bin/chromium \
        --no-memcheck \
        --no-sandbox \
        --user-data-dir="$PROFILE_DIR" \
        --kiosk \
        --noerrdialogs \
        --disable-infobars \
        --no-first-run \
        --disable-session-crashed-bubble \
        --disable-restore-session-state \
        --password-store=basic \
        --disable-background-networking \
        --disable-component-update \
        --disable-default-apps \
        --disable-domain-reliability \
        --disable-dev-shm-usage \
        --disable-gpu \
        --disable-gpu-compositing \
        --disable-accelerated-2d-canvas \
        --disable-features=Translate,BlinkGenPropertyTrees,MediaRouter,OptimizationHints,BackForwardCache,site-per-process \
        --disable-sync \
        --renderer-process-limit=2 \
        --js-flags="--max-old-space-size=96" \
        --disk-cache-size=16777216 \
        --autoplay-policy=no-user-gesture-required \
        --ozone-platform=x11 \
        "$URL" >> "$LOG_FILE" 2>&1

    rc=$?
    echo "$(date -Is) chromium exited with code $rc" | tee -a "$LOG_FILE"
    free -m | sed -n '1,3p' >> "$LOG_FILE" 2>&1 || true
    sleep 3
done
EOF

chmod +x "$AGENT_DIR/kiosk.sh"

echo "--- 5. Upgrading Xinitrc and Autostart to use Chromium ---"
if [[ -n "$DEVICE_TOKEN" ]]; then
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
else
    echo "Warning: could not read device token from $CONFIG_FILE, leaving .xinitrc unchanged."
fi

mkdir -p "$USER_HOME/.config/autostart"
rm -f \
    "$USER_HOME/.config/autostart/farin-tv-display.desktop" \
    "$USER_HOME/.config/autostart/kiosk.desktop" \
    "$USER_HOME/.config/autostart/chromium.desktop" \
    "$USER_HOME/.config/autostart/firefox.desktop"

echo "--- 6. Applying Low-RAM Kernel Optimizations ---"
TOTAL_MEM_MB="$(free -m | awk '/^Mem:/{print $2}')"
if [[ "${TOTAL_MEM_MB:-0}" -lt 1024 ]]; then
    sudo dphys-swapfile swapoff || true
    sudo apt-get purge -y dphys-swapfile || true
    sudo rm -f /var/swap || true

    sudo modprobe zram || true

    sudo tee /etc/default/zramswap >/dev/null <<'EOF'
ALGORITHM=zstd
PERCENT=150
PRIORITY=100
EOF

    if systemctl is-active --quiet zramswap; then
        echo "ZRAM swap already active; keeping the existing instance."
    else
        sudo systemctl daemon-reload || true
        sudo systemctl enable --now zramswap || true
    fi

    cat <<'EOF' | sudo tee /etc/sysctl.d/99-farin-tv.conf >/dev/null
vm.swappiness=60
vm.vfs_cache_pressure=150
vm.min_free_kbytes=12288
vm.overcommit_memory=1
EOF
    sudo sysctl -p /etc/sysctl.d/99-farin-tv.conf || true

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

echo "--- 7. Forcing Legacy X11 (Disabling Wayland) ---"
if command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_wayland W1 || true
fi

echo "--- Update Complete ---"
echo "The agent has been restarted. You can apply the new Openbox bindings and Chromium transition by rebooting: sudo reboot"
