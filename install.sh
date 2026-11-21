#!/usr/bin/env bash
#
# NodeMonitor agent installer for Linux servers (systemd distros).
#
# One-line install (set NM_TOKEN from the panel's Servers page first):
#
#   curl -fsSL https://raw.githubusercontent.com/NodeMonitor/agent/main/install.sh | NM_TOKEN=<TOKEN> bash
#
# What it does:
#   1. Downloads nodemonitor-agent.sh for the release you choose and VERIFIES
#      its SHA-256 against the release checksums.txt (mandatory).
#   2. Creates a locked-down 'nodemonitor' system user and directories.
#   3. Registers the host with your agent-api endpoint (one-time token).
#   4. Installs a hardened systemd unit and starts the service.
#
# Environment:
#   NM_TOKEN              registration token from the panel (required on first install)
#   NM_SERVER             agent-api base URL (default: https://agent.nodemon.net)
#   NM_NAME               display name (default: hostname)
#   NM_VERSION            release tag to install (default: latest release)
#   NM_ALLOW_INSECURE=1   permit plaintext http:// NM_SERVER (local testing only)
#
# Re-running this script upgrades the agent: it re-downloads the pinned-or-latest
# release, re-verifies, and restarts the service (existing config is preserved).
# To remove everything, use uninstall.sh.

set -euo pipefail

GITHUB_REPO="NodeMonitor/agent"
DEFAULT_SERVER="https://agent.nodemon.net"
INSTALL_BIN="/usr/local/bin/nodemonitor-agent"
CONFIG_DIR="/etc/nodemonitor"
CONFIG_FILE="$CONFIG_DIR/agent.conf"
STATE_DIR="/var/lib/nodemonitor"
SYSTEM_USER="nodemonitor"
UNIT_FILE="/etc/systemd/system/nodemonitor-agent.service"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
	[ "$(id -u)" -eq 0 ] || fail "this installer must run as root — prefix with sudo"
}

require_linux_systemd() {
	[ "$(uname -s)" = "Linux" ] || fail "this installer supports Linux only (see INSTALLATION.md for other platforms)"
	command -v systemctl >/dev/null 2>&1 || fail "systemd not found — this installer targets systemd distributions"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

# latest_tag resolves the newest release tag from the GitHub API.
latest_tag() {
	local tag
	tag=$(curl -fsSL --max-time 15 "https://api.github.com/repos/$GITHUB_REPO/releases/latest" \
		| grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*: *"//;s/"$//')
	[ -n "$tag" ] || fail "could not resolve the latest release tag from GitHub"
	printf '%s' "$tag"
}

# download_verified fetches a release file and verifies its SHA-256 against
# the release's checksums.txt. Verification is mandatory, not optional.
# The expected hash is stored in EXPECTED_SHA256 so callers can re-verify
# the file after moving it into place (closing the verify-then-install
# TOCTOU window on multi-user hosts).
EXPECTED_SHA256=""
download_verified() {
	local version="$1" asset="$2" destination="$3"
	local base="https://github.com/$GITHUB_REPO/releases/download/$version"

	log "downloading $asset (release $version)"
	curl -fsSL --max-time 60 -o "$destination" "$base/$asset" \
		|| fail "download failed: $base/$asset"

	log "verifying SHA-256 checksum"
	local expected actual
	expected=$(curl -fsSL --max-time 30 "$base/checksums.txt" \
		| grep -E "[[:space:]]${asset}\$" | awk '{print $1}')
	[ -n "$expected" ] || fail "checksums.txt has no entry for $asset — refusing to install an unverified file"
	actual=$(sha256sum "$destination" | awk '{print $1}')
	[ "$actual" = "$expected" ] || fail "checksum mismatch for $asset (expected $expected, got $actual) — do NOT install this file"
	EXPECTED_SHA256="$expected"
	log "checksum OK ($actual)"
}

ensure_user() {
	if id "$SYSTEM_USER" >/dev/null 2>&1; then
		log "system user '$SYSTEM_USER' exists"
	else
		log "creating locked system user '$SYSTEM_USER'"
		useradd --system --no-create-home --shell /usr/sbin/nologin "$SYSTEM_USER" 2>/dev/null \
			|| useradd --system --no-create-home --shell /bin/false "$SYSTEM_USER"
	fi
}

ensure_dirs() {
	mkdir -p "$CONFIG_DIR" "$STATE_DIR"
	chown root:"$SYSTEM_USER" "$CONFIG_DIR"
	chmod 750 "$CONFIG_DIR"
	# The state dir must be writable by the service user (it persists network
	# counters there); root ownership with r-x for the group made every write
	# fail silently. State is non-sensitive (byte counters), so user-owned 700.
	chown "$SYSTEM_USER":"$SYSTEM_USER" "$STATE_DIR"
	chmod 700 "$STATE_DIR"
}

write_unit() {
	log "writing systemd unit with hardening"
	cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=NodeMonitor host agent
Documentation=https://github.com/$GITHUB_REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SYSTEM_USER
Group=$SYSTEM_USER
ExecStart=$INSTALL_BIN run
Environment=NM_CONFIG_FILE=$CONFIG_FILE
Environment=NM_STATE_DIR=$STATE_DIR
Restart=always
RestartSec=10s
# Throttle permanent crash loops instead of restarting forever.
StartLimitIntervalSec=300
StartLimitBurst=10

# Hardening: the agent only reads /proc and writes its state dir.
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
RestrictNamespaces=yes
SystemCallArchitectures=native
CapabilityBoundingSet=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=$STATE_DIR

[Install]
WantedBy=multi-user.target
UNIT
	chmod 644 "$UNIT_FILE"
}

register_agent() {
	if [ -r "$CONFIG_FILE" ] && grep -q '^agent_id=' "$CONFIG_FILE"; then
		log "existing agent configuration found — skipping registration (upgrade)"
		return 0
	fi
	[ -n "${NM_TOKEN:-}" ] || fail "NM_TOKEN is required on first install (create a registration token in the panel under Servers)"

	log "registering host with $NM_SERVER"
	# Token via environment, not argv: command lines are world-readable in
	# /proc for the lifetime of the register process.
	NM_TOKEN="$NM_TOKEN" "$INSTALL_BIN" register --server "$NM_SERVER" ${NM_NAME:+--name "$NM_NAME"} --config "$CONFIG_FILE"

	chown root:"$SYSTEM_USER" "$CONFIG_FILE"
	chmod 640 "$CONFIG_FILE"
}

main() {
	require_root
	require_linux_systemd
	require_command curl
	require_command sha256sum

	NM_SERVER="${NM_SERVER:-$DEFAULT_SERVER}"
	NM_VERSION="${NM_VERSION:-}"
	[ -n "$NM_VERSION" ] || NM_VERSION=$(latest_tag)
	# The version is interpolated into a download URL; only accept release tags.
	case "$NM_VERSION" in
		v[0-9]*.[0-9]*.[0-9]*) ;;
		*) fail "NM_VERSION must be a release tag like v1.2.3 (got: $NM_VERSION)" ;;
	esac

	ensure_user
	ensure_dirs

	# Stage in a private mktemp file, not a PID-predictable /tmp path: a local
	# user could otherwise pre-create a symlink (or swap the file between the
	# checksum check and the privileged install). mktemp creates 0600.
	local tmp_script
	tmp_script="$(mktemp)"
	download_verified "$NM_VERSION" "nodemonitor-agent.sh" "$tmp_script"

	install -m 0755 -o root -g root "$tmp_script" "$INSTALL_BIN"
	rm -f "$tmp_script"

	# Re-verify the installed copy against the checksum we validated, so the
	# window between verification and install cannot swap the file.
	local installed_sum
	installed_sum=$(sha256sum "$INSTALL_BIN" | awk '{print $1}')
	[ "$installed_sum" = "$EXPECTED_SHA256" ] \
		|| fail "installed binary failed re-verification (expected $EXPECTED_SHA256, got $installed_sum) — possible tampering; not starting the service"

	register_agent
	write_unit

	log "reloading systemd and starting the service"
	systemctl daemon-reload
	systemctl enable --now nodemonitor-agent.service

	log "installed NodeMonitor agent $NM_VERSION"
	log "the host appears on the panel's Servers page once the first heartbeat lands (about 30s)"
	log "to verify: systemctl status nodemonitor-agent && nodemonitor-agent check"
}

main "$@"
