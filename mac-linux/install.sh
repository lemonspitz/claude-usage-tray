#!/bin/sh
# Installs and starts the Claude usage tray widget on macOS or Linux.
# Usage: sh install.sh
set -e

APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-usage-tray"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required. macOS: run 'xcode-select --install'. Linux: install python3 + python3-venv."
    exit 1
fi

mkdir -p "$APP_DIR"
cp "$SRC_DIR/claude_usage_tray.py" "$APP_DIR/"

if [ "$(uname)" = "Linux" ]; then
    if ! python3 -c "import gi; gi.require_version('AyatanaAppIndicator3', '0.1')" 2>/dev/null; then
        echo "Note: for a proper tray icon, install the AppIndicator bindings, e.g. on Ubuntu/Debian:"
        echo "  sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1"
        echo "On Fedora: sudo dnf install python3-gobject libayatana-appindicator-gtk3"
        echo "GNOME also needs the 'AppIndicator and KStatusNotifierItem Support' extension."
    fi
    # system site packages so the venv can use the distro's gi (GTK) bindings
    python3 -m venv --system-site-packages "$APP_DIR/venv"
else
    python3 -m venv "$APP_DIR/venv"
fi

"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet pystray pillow

nohup "$APP_DIR/venv/bin/python" "$APP_DIR/claude_usage_tray.py" >/dev/null 2>&1 &

echo "Claude usage tray is running (installed in $APP_DIR)."
echo "Click the icon and choose 'Start at login' to keep it running after a restart."
