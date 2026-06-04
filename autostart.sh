#!/usr/bin/env bash
# Liga/desliga o autostart no login via LaunchAgent.
# Gera o plist apontando pro app instalado (path resolvido em runtime, sem hardcode no repo).
set -euo pipefail

LABEL="io.github.rafaelmgbh.ai-usage-bar"
APP_BIN="${HOME}/Applications/AiUsageBar.app/Contents/MacOS/AiUsageBar"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

case "${1:-}" in
  on)
    [ -x "$APP_BIN" ] || { echo "Build/instale primeiro:  ./build.sh"; exit 1; }
    mkdir -p "${HOME}/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load -w "$PLIST"
    echo "autostart ON  (${LABEL})"
    ;;
  off)
    launchctl unload -w "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "autostart OFF"
    ;;
  *)
    echo "uso: ./autostart.sh on|off"
    exit 1
    ;;
esac
