#!/usr/bin/env bash
#
# NodeMonitor agent uninstaller for Linux (systemd distros).
#
#   sudo bash uninstall.sh          # stop + remove agent binary, unit, state
#   sudo bash uninstall.sh --purge  # additionally delete config and the system user
#
# The default keeps /etc/nodemonitor/agent.conf (which contains this host's
# identity) so the same server can be re-registered or reinstalled later.
# --purge removes everything, including the credentials file.

set -euo pipefail

INSTALL_BIN="/usr/local/bin/nodemonitor-agent"
CONFIG_DIR="/etc/nodemonitor"
STATE_DIR="/var/lib/nodemonitor"
SYSTEM_USER="nodemonitor"
UNIT_FILE="/etc/systemd/system/nodemonitor-agent.service"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

require_root() {
	[ "$(id -u)" -eq 0 ] || echo_and_exit "this uninstaller must run as root — prefix with sudo"
}

echo_and_exit() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root

if command -v systemctl >/dev/null 2>&1; then
	log "stopping and disabling nodemonitor-agent.service"
	systemctl disable --now nodemonitor-agent.service 2>/dev/null || true
	systemctl daemon-reload || true
else
	log "systemd not found; skipping service management"
fi

for path in "$UNIT_FILE" "$INSTALL_BIN"; do
	if [ -e "$path" ]; then
		log "removing $path"
		rm -f "$path"
	fi
done

log "removing state directory $STATE_DIR"
rm -rf "$STATE_DIR"

if [ "${1:-}" = "--purge" ]; then
	log "removing configuration directory $CONFIG_DIR (--purge)"
	rm -rf "$CONFIG_DIR"
	if id "$SYSTEM_USER" >/dev/null 2>&1; then
		log "removing system user '$SYSTEM_USER' (--purge)"
		userdel "$SYSTEM_USER" 2>/dev/null || true
	fi
	log "purge complete"
else
	log "config kept at $CONFIG_DIR (re-run with --purge to delete it and the service user)"
fi

log "uninstalled"
