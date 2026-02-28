#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# OPS Sentinel Suite — Installer
# ═══════════════════════════════════════════════════════════════
# Usage:
#   ./install.sh              Install the suite
#   ./install.sh --uninstall  Remove the suite (preserves logs)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/share/ops-sentinel"
CONFIG_DIR="$HOME/.sentinel-config"
STATE_DIR="$HOME/.sentinel-state"
LOG_DIR="$HOME/.sentinel-logs"
PLIST_NAME="com.ops.sentinel.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Uninstall ───
if [[ "${1:-}" == "--uninstall" ]]; then
    echo -e "${BOLD}Uninstalling OPS Sentinel Suite...${NC}"

    # Stop daemon
    if launchctl list 2>/dev/null | grep -q "com.ops.sentinel"; then
        launchctl unload "$PLIST_DEST" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} Daemon stopped"
    fi

    # Stop web server
    if launchctl list 2>/dev/null | grep -q "com.ops.sentinel.web"; then
        launchctl unload "$HOME/Library/LaunchAgents/com.ops.sentinel.web.plist" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} Web server stopped"
    fi
    rm -f "$HOME/Library/LaunchAgents/com.ops.sentinel.web.plist"
    echo -e "  ${GREEN}✓${NC} Web LaunchAgent removed"

    # Remove LaunchAgent
    rm -f "$PLIST_DEST"
    echo -e "  ${GREEN}✓${NC} LaunchAgent removed"

    # Remove scripts (preserve config and logs)
    rm -rf "$INSTALL_DIR"
    echo -e "  ${GREEN}✓${NC} Scripts removed from $INSTALL_DIR"

    echo ""
    echo -e "${YELLOW}Preserved:${NC} $CONFIG_DIR (config), $LOG_DIR (logs), $STATE_DIR (state)"
    echo "Remove manually if desired."
    exit 0
fi

# ─── Install ───
echo -e "${BOLD}Installing OPS Sentinel Suite...${NC}"
echo ""

# 1. Create directories
echo -e "  Creating directories..."
mkdir -p "$INSTALL_DIR/lib" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
echo -e "  ${GREEN}✓${NC} $INSTALL_DIR"
echo -e "  ${GREEN}✓${NC} $CONFIG_DIR"
echo -e "  ${GREEN}✓${NC} $STATE_DIR"
echo -e "  ${GREEN}✓${NC} $LOG_DIR"

# 2. Copy scripts
echo -e "  Copying scripts..."
cp "$SCRIPT_DIR/scripts/sentinel-utils.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/sentinel-daemon.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/sentinel-status.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/sentinel-triage.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/lib/"*.sh "$INSTALL_DIR/lib/"
cp "$SCRIPT_DIR/scripts/sentinel-webserver.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/sentinel-dashboard.html" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/sentinel-daemon.sh"
chmod +x "$INSTALL_DIR/sentinel-status.sh"
chmod +x "$INSTALL_DIR/sentinel-triage.sh"
echo -e "  ${GREEN}✓${NC} Scripts installed"
echo -e "  ${GREEN}✓${NC} Web dashboard installed"

# 3. Copy config (don't overwrite existing)
if [[ ! -f "$CONFIG_DIR/sentinel.conf" ]]; then
    cp "$SCRIPT_DIR/config/sentinel.conf" "$CONFIG_DIR/"
    echo -e "  ${GREEN}✓${NC} Default config installed"
else
    echo -e "  ${YELLOW}~${NC} Config exists — preserved (update manually if needed)"
fi

# 4. Install LaunchAgent (generated with correct paths)
echo -e "  Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_DEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ops.sentinel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALL_DIR}/sentinel-daemon.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/sentinel-daemon-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/sentinel-daemon-stderr.log</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
PLIST

echo -e "  ${GREEN}✓${NC} LaunchAgent installed"

# Install web server LaunchAgent
WEB_PLIST_NAME="com.ops.sentinel.web.plist"
WEB_PLIST_DEST="$HOME/Library/LaunchAgents/$WEB_PLIST_NAME"

cat > "$WEB_PLIST_DEST" <<WEBPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ops.sentinel.web</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/python3</string>
        <string>${INSTALL_DIR}/sentinel-webserver.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/sentinel-web-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/sentinel-web-stderr.log</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
WEBPLIST

echo -e "  ${GREEN}✓${NC} Web server LaunchAgent installed"

# 5. Add shell aliases
ZSHRC="$HOME/.zshrc"
if [[ -f "$ZSHRC" ]]; then
    if ! grep -q "sentinel-status" "$ZSHRC" 2>/dev/null; then
        {
            echo ""
            echo "# OPS Sentinel Suite"
            echo "alias sentinel-status='${INSTALL_DIR}/sentinel-status.sh'"
            echo "alias sentinel-triage='${INSTALL_DIR}/sentinel-triage.sh'"
        } >> "$ZSHRC"
        echo -e "  ${GREEN}✓${NC} Shell aliases added to .zshrc"
    else
        echo -e "  ${YELLOW}~${NC} Shell aliases already in .zshrc"
    fi
else
    echo -e "  ${YELLOW}~${NC} No .zshrc found — add aliases manually"
fi

# 6. Check for terminal-notifier (actionable notifications)
if command -v terminal-notifier &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} terminal-notifier found — clickable notifications enabled"
else
    echo -e "  ${YELLOW}~${NC} terminal-notifier not found — notifications won't be clickable"
    echo -e "    Install with: brew install terminal-notifier"
fi

# 7. Generate web auth token if not exists
if [[ ! -f "$CONFIG_DIR/web.token" ]]; then
    python3 -c "import secrets; print(secrets.token_hex(16))" > "$CONFIG_DIR/web.token"
    chmod 600 "$CONFIG_DIR/web.token"
    echo -e "  ${GREEN}✓${NC} Web auth token generated"
else
    echo -e "  ${YELLOW}~${NC} Web auth token exists — preserved"
fi

# 8. DON'T start daemon automatically — let user decide
echo ""
echo -e "${GREEN}${BOLD}OPS Sentinel Suite installed successfully!${NC}"
echo ""
echo "Commands:"
echo "  sentinel-status    — Live dashboard"
echo "  sentinel-triage    — Emergency mode"
echo "  sentinel-dashboard — http://localhost:8888"
echo ""
echo "To start the daemon:"
echo "  launchctl load $PLIST_DEST"
echo ""
echo "To start the web dashboard:"
echo "  launchctl load ~/Library/LaunchAgents/com.ops.sentinel.web.plist"
echo "  Then open: http://localhost:8888"
echo ""
echo "Config: $CONFIG_DIR/sentinel.conf"
echo "Logs:   $LOG_DIR/sentinel.log"
echo ""
echo "To verify installation:"
echo "  bash ${INSTALL_DIR}/sentinel-daemon.sh --once"
