#!/usr/bin/env bash
#
# NodeMonitor host agent.
#
# A single-file, dependency-light monitoring daemon for Linux servers. It
# reads host metrics from /proc and coreutils, and pushes them to your
# NodeMonitor agent-api endpoint over HTTPS with per-agent credentials.
#
# Everything this script does is in this file: no hidden downloads, no
# compiled parts, no background jobs. Read it end to end before installing.
#
# Data it reads and reports:
#   - hostname, platform, architecture, agent version
#   - CPU utilisation           (/proc/stat, sampled as deltas)
#   - load averages             (/proc/loadavg)
#   - memory and swap usage     (/proc/meminfo)
#   - per-mount filesystem use  (df -kP, block devices only, deduped)
#   - network byte rates        (/proc/net/dev counters, rate computed locally)
#   - uptime and process count  (/proc/uptime, /proc)
#
# Nothing else is collected. The agent never opens inbound ports, never runs
# commands from the API, and never touches files outside its config and state
# directories.
#
# Usage:
#   nodemonitor-agent.sh register --server URL --token TOKEN [--name NAME]
#   nodemonitor-agent.sh run                  # daemon loop (default via systemd)
#   nodemonitor-agent.sh check                # validate config and connectivity
#   nodemonitor-agent.sh version
#
# Configuration lives in $CONFIG_FILE (default /etc/nodemonitor/agent.conf),
# written 0600 by `register`:
#   server_url=https://api.example.net
#   agent_id=...
#   agent_secret=...
#   collect_interval_seconds=15
#   report_interval_seconds=60
#   heartbeat_interval_seconds=30

set -u

AGENT_VERSION="1.0.0"

CONFIG_FILE="${NM_CONFIG_FILE:-/etc/nodemonitor/agent.conf}"
STATE_DIR="${NM_STATE_DIR:-/var/lib/nodemonitor}"

# ---------------------------------------------------------------------------
# Logging (stderr; systemd picks it up via journald)
# ---------------------------------------------------------------------------

log_info()  { printf '[%s] [info ] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
log_warn()  { printf '[%s] [warn ] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
log_error() { printf '[%s] [error] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Config: key=value file, parsed with grep/cut only (never sourced, so a
# malformed config can never execute code).
# ---------------------------------------------------------------------------

config_get() {
	local key="$1"
	local default="${2-}"
	local line=""
	if [ -r "$CONFIG_FILE" ]; then
		line="$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
	fi
	printf '%s' "${line:-$default}"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1 (install curl, or see INSTALLATION.md)"
}

SERVER_URL="" AGENT_ID="" AGENT_SECRET=""
COLLECT_INTERVAL=15 REPORT_INTERVAL=60 HEARTBEAT_INTERVAL=30

load_config() {
	[ -r "$CONFIG_FILE" ] || die "config not readable: $CONFIG_FILE (run 'nodemonitor-agent.sh register' first)"

	SERVER_URL="$(config_get server_url)"
	AGENT_ID="$(config_get agent_id)"
	AGENT_SECRET="$(config_get agent_secret)"
	COLLECT_INTERVAL="$(config_get collect_interval_seconds 15)"
	REPORT_INTERVAL="$(config_get report_interval_seconds 60)"
	HEARTBEAT_INTERVAL="$(config_get heartbeat_interval_seconds 30)"

	[ -n "$SERVER_URL" ]    || die "config missing server_url"
	[ -n "$AGENT_ID" ]      || die "config missing agent_id"
	[ -n "$AGENT_SECRET" ]  || die "config missing agent_secret"

	case "$COLLECT_INTERVAL$REPORT_INTERVAL$HEARTBEAT_INTERVAL" in
		*[!0-9]*) die "interval settings must be integers (seconds)" ;;
	esac
	[ "$COLLECT_INTERVAL" -ge 5 ]  2>/dev/null || die "collect_interval_seconds must be >= 5"
	[ "$REPORT_INTERVAL" -ge 10 ]  2>/dev/null || die "report_interval_seconds must be >= 10"
	[ "$HEARTBEAT_INTERVAL" -ge 5 ] 2>/dev/null || die "heartbeat_interval_seconds must be >= 5"
	[ "$REPORT_INTERVAL" -ge "$COLLECT_INTERVAL" ] 2>/dev/null || die "report_interval_seconds must be >= collect_interval_seconds"
	[ "$HEARTBEAT_INTERVAL" -ge "$COLLECT_INTERVAL" ] 2>/dev/null || die "heartbeat_interval_seconds must be >= collect_interval_seconds"

	# The agent authenticates over HTTPS. Plaintext HTTP is refused explicitly
	# so a typo cannot silently send credentials across the network.
	case "$SERVER_URL" in
		https://*) ;;
		http://*)
			[ "${NM_ALLOW_INSECURE:-0}" = "1" ] || die "server_url uses plaintext http:// — set NM_ALLOW_INSECURE=1 only for local testing"
			;;
		*) die "server_url must start with https:// (or http:// with NM_ALLOW_INSECURE=1)" ;;
	esac
}

# Strip a trailing slash so URL joins are predictable.
api_url() {
	local base="${SERVER_URL%/}"
	printf '%s/v1' "$base"
}

# ---------------------------------------------------------------------------
# JSON helpers (hand-assembled; every string value goes through json_escape)
# ---------------------------------------------------------------------------

json_escape() {
	# Escape backslash, double quote, and tab; strip every other control
	# character (raw control bytes, including newlines, are invalid inside
	# JSON strings). Hostnames and mount paths are the only free-form strings.
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e $'s/\t/\\\\t/g' | tr -d '\000-\037'
}

# ---------------------------------------------------------------------------
# Metric collection. All state lives in memory (this one process) plus the
# previous network counters in $STATE_DIR so rates survive a restart without
# misreporting one huge sample.
# ---------------------------------------------------------------------------

HOSTNAME="$(uname -n 2>/dev/null || printf 'unknown')"
PLATFORM="linux"
ARCH="$(uname -m 2>/dev/null || printf 'unknown')"

PREV_CPU=""           # "user,system,idle,iowait,total" from the previous sample

# cpu_sample reads cumulative jiffies from /proc/stat into "u,s,i,w,t".
cpu_sample() {
	awk '/^cpu / {print $2, $3, $5, $6, $2+$3+$4+$5+$6+$7+$8}' /proc/stat
}

collect_cpu_pct() {
	local now prev
	now="$(cpu_sample)"

	if [ -z "$PREV_CPU" ]; then
		# First run after start: take a short second sample so the first
		# reported value is a real delta, not since-boot noise.
		sleep 0.3
		now="$(cpu_sample)"
	fi

	prev="$PREV_CPU"
	PREV_CPU="$now"

	[ -n "$prev" ] || return 0
	awk -v a="$prev" -v b="$now" '
		BEGIN { split(a, x, " "); split(b, y, " ");
			du = y[1]-x[1]; ds = y[2]-x[2]; di = y[3]-x[3]; dw = y[4]-x[4]; dt = y[5]-x[5];
			if (dt <= 0) { print 0; exit }
			busy = du + ds + dw;
			printf "%.1f", 100.0 * busy / dt
		}'
}

collect_load() { awk '{print $1, $2, $3}' /proc/loadavg; }

collect_uptime_seconds() { awk '{print int($1)}' /proc/uptime; }

collect_memory() {
	# Prints "mem_total mem_used mem_pct swap_total swap_used swap_pct" (bytes / pct).
	awk '
		/MemTotal:/     { t = $2 * 1024 }
		/MemAvailable:/ { a = $2 * 1024 }
		/SwapTotal:/    { st = $2 * 1024 }
		/SwapFree:/     { sf = $2 * 1024 }
		END {
			u = t - a
			su = st - sf
			mp = (t > 0) ? 100.0 * u / t : 0
			sp = (st > 0) ? 100.0 * su / st : 0
			printf "%d %d %.1f %d %d %.1f", t, u, mp, st, su, sp
		}' /proc/meminfo
}

# collect_root_disk reads the aggregate for the / filesystem: a single honest
# number pair, avoiding double counting across stacked mounts.
collect_root_disk() {
	df -kP / 2>/dev/null | awk 'NR == 2 { printf "%d %d %.1f", $2 * 1024, $3 * 1024, ($2 > 0) ? 100.0 * $3 / $2 : 0 }'
}

collect_mounts_json() {
	# Block-device mounts only (skips tmpfs/overlay/proc-style entries), deduped
	# by device, limited to the 8 largest by total size. Human visibility beats
	# exhaustive enumeration; the aggregate disk_* fields still cover the host.
	# Fields are passed through as tab-separated so mount paths containing
	# spaces survive intact.
	df -kP 2>/dev/null | awk '
		NR > 1 && $1 ~ /^\/dev\// && !seen[$1]++ {
			mnt = $6
			for (i = 7; i <= NF; i++) mnt = mnt " " $i
			printf "%d\t%d\t%s\t%s\n", $3 * 1024, $2 * 1024, $1, mnt
		}' | sort -rn | head -n 8 | awk -F'\t' 'BEGIN {
			printf "["
			first = 1
		}
		{
			used = $1; total = $2; dev = $3; mnt = $4;
			pct = (total > 0) ? 100.0 * used / total : 0;
			gsub(/\\/, "\\\\", dev); gsub(/"/, "\\\"", dev);
			gsub(/\\/, "\\\\", mnt); gsub(/"/, "\\\"", mnt);
			printf "%s{\"device\":\"%s\",\"mount_point\":\"%s\",\"used_bytes\":%d,\"total_bytes\":%d,\"used_pct\":%.1f}", (first ? "" : ","), dev, mnt, used, total, pct;
			first = 0
		}
		END { printf "]" }'
}

collect_net_counters() {
	# Total rx/tx bytes across non-loopback interfaces (cumulative counters).
	awk -F'[ :|]+' '
		$1 !~ /lo:/ && $2 ~ /[0-9]/ { rx += $2; tx += $10 }
		END { printf "%d %d", rx + 0, tx + 0 }' /proc/net/dev
}

collect_process_count() {
	local count=0
	for entry in /proc/[0-9]*; do
		[ -d "$entry" ] && count=$((count + 1))
	done
	printf '%d' "$count"
}

# net_rates computes bytes/sec deltas between samples. State persists to disk
# so a restart does not report one misleading spike.
collect_net_rates() {
	local now prev rx tx rx_prev tx_prev ts_prev dt_ms dt_s rx_bps tx_bps
	# Millisecond timestamp from /proc/uptime: GNU date's %3N is not portable
	# (busybox/BSD date emit a literal "N", which kills the arithmetic below
	# on the next tick). /proc/uptime is always present on Linux.
	now="$(awk '{printf "%d", $1 * 1000}' /proc/uptime 2>/dev/null)"
	case "$now" in ''|*[!0-9]*) now="$(( $(date +%s) * 1000 ))" ;; esac
	read -r rx tx <<< "$(collect_net_counters)"

	if [ -r "$STATE_DIR/net.state" ]; then
		read -r rx_prev tx_prev ts_prev < "$STATE_DIR/net.state"
		dt_ms=$((now - ts_prev))
		if [ "$dt_ms" -gt 500 ] && [ "$rx" -ge "$rx_prev" ] && [ "$tx" -ge "$tx_prev" ]; then
			dt_s=$(awk -v ms="$dt_ms" 'BEGIN { printf "%.3f", ms / 1000.0 }')
			rx_bps=$(awk -v d=$((rx - rx_prev)) -v s="$dt_s" 'BEGIN { printf "%.0f", d / s }')
			tx_bps=$(awk -v d=$((tx - tx_prev)) -v s="$dt_s" 'BEGIN { printf "%.0f", d / s }')
		else
			rx_bps=""; tx_bps=""
		fi
	else
		rx_bps=""; tx_bps=""
	fi

	mkdir -p "$STATE_DIR" 2>/dev/null || true
	printf '%d %d %d\n' "$rx" "$tx" "$now" > "$STATE_DIR/net.state" 2>/dev/null || true
	printf '%s %s' "${rx_bps:-0}" "${tx_bps:-0}"
}

# assemble_sample builds one telemetry sample as JSON on stdout.
assemble_sample() {
	local cpu_pct="$1"
	local rx_bps tx_bps
	read -r mem_total mem_used mem_pct swap_total swap_used swap_pct <<< "$(collect_memory)"
	read -r disk_total disk_used disk_pct <<< "$(collect_root_disk)"
	loads="$(collect_load)"
	load_1m="${loads%% *}"; rest="${loads#* }"
	load_5m="${rest%% *}"; load_15m="${rest#* }"
	uptime="$(collect_uptime_seconds)"
	mounts="$(collect_mounts_json)"
	read -r rx_bps tx_bps <<< "$(collect_net_rates)"
	procs="$(collect_process_count)"

	local host platform arch
	host="$(json_escape "$HOSTNAME")"
	platform="$(json_escape "$PLATFORM")"
	arch="$(json_escape "$ARCH")"

	printf '{
  "time": "%s",
  "agent_version": "%s",
  "hostname": "%s",
  "platform": "%s",
  "arch": "%s",
  "cpu_pct": %s,
  "load_1m": %s,
  "load_5m": %s,
  "load_15m": %s,
  "mem_total_bytes": %d,
  "mem_used_bytes": %d,
  "mem_used_pct": %s,
  "disk_total_bytes": %d,
  "disk_used_bytes": %d,
  "disk_used_pct": %s,
  "net_rx_bytes": 0,
  "net_tx_bytes": 0,
  "net_rx_bps": %s,
  "net_tx_bps": %s,
  "process_count": %d,
  "uptime_seconds": %d,
  "swap_total_bytes": %d,
  "swap_used_bytes": %d,
  "swap_used_pct": %s,
  "mounts": %s
}' \
		"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$AGENT_VERSION" "$host" "$platform" "$arch" \
		"${cpu_pct:-0}" "${load_1m:-0}" "${load_5m:-0}" "${load_15m:-0}" \
		"${mem_total:-0}" "${mem_used:-0}" "${mem_pct:-0}" \
		"${disk_total:-0}" "${disk_used:-0}" "${disk_pct:-0}" \
		"${rx_bps:-0}" "${tx_bps:-0}" \
		"${procs:-0}" "${uptime:-0}" \
		"${swap_total:-0}" "${swap_used:-0}" "${swap_pct:-0}" \
		"${mounts:-[]}"
}

# ---------------------------------------------------------------------------
# Push transport
# ---------------------------------------------------------------------------

# api_post PATH BODY — prints the response body and sets RC to the HTTP code.
#
# Deliberately no curl -f: we need the HTTP status of 4xx/5xx responses
# (401/403 drive the revocation kill-switch). Transport failures are detected
# via curl's exit status instead — %{http_code} then prints 000, which the
# callers treat as "no HTTP response". Credentials come from a 0600 netrc
# file rather than -u, so they are never visible in /proc/<pid>/cmdline.
RC=0
NETRC_FILE=""
make_netrc() {
	NETRC_FILE="$(mktemp)" || die "cannot create temporary netrc file"
	chmod 600 "$NETRC_FILE" 2>/dev/null || true
	local host="${SERVER_URL#https://}"
	host="${host#http://}"
	host="${host%%/*}"
	host="${host%%:*}"
	printf 'machine %s login "%s" password "%s"\n' "$host" "$AGENT_ID" "$AGENT_SECRET" > "$NETRC_FILE"
}
drop_netrc() { [ -z "$NETRC_FILE" ] || rm -f "$NETRC_FILE"; }

api_post() {
	local path="$1" body="$2"
	local tmp err rc
	tmp="$(mktemp)"
	err="$(mktemp)"
	rc="$(curl -sS --max-time 10 \
		--netrc-file "$NETRC_FILE" \
		-H 'Content-Type: application/json' \
		-X POST \
		-o "$tmp" -w '%{http_code}' \
		--data-binary "$body" \
		"$SERVER_URL/v1$path" 2>"$err")"
	[ -n "$rc" ] || rc="000"
	RC="$rc"
	cat "$tmp"
	if [ "$RC" = "000" ] && [ -s "$err" ]; then
		log_warn "curl: $(tail -n 1 "$err")"
	fi
	rm -f "$tmp" "$err"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

RUNNING=1
on_signal() { RUNNING=0; }
trap 'drop_netrc; on_signal' INT TERM
trap drop_netrc EXIT

# Sample ring buffer: last N samples, flushed on each successful report.
MAX_BUFFERED=12
SAMPLES=()

buffer_push() {
	SAMPLES+=("$1")
	if [ "${#SAMPLES[@]}" -gt "$MAX_BUFFERED" ]; then
		SAMPLES=("${SAMPLES[@]:1}")
	fi
}

buffer_batch() {
	local out="[" first=1 s
	for s in "${SAMPLES[@]:-}"; do
		[ -n "$s" ] || continue
		if [ "$first" -eq 1 ]; then first=0; else out+=","; fi
		out+="$s"
	done
	printf '%s]' "$out"
}

do_report() {
	[ "${#SAMPLES[@]}" -gt 0 ] || return 0
	local batch
	batch="$(buffer_batch)"
	api_post "/v1/agents/$AGENT_ID/metrics" "{\"samples\":$batch}"
	case "$RC" in
		200|204)
			SAMPLES=()
			report_failures=0
			;;
		401|403)
			# Terminal credential failure (bad secret or revoked). Tell the
			# operator clearly and exit non-zero so systemd marks the unit failed.
			log_error "authentication rejected (HTTP $RC) — check credentials or re-run 'register' after revocation"
			exit 1
			;;
		000)
			log_warn "could not reach agent API (network); keeping ${#SAMPLES[@]} buffered sample(s)"
			return 1
			;;
		*)
			log_warn "agent API returned HTTP $RC; keeping ${#SAMPLES[@]} buffered sample(s)"
			return 1
			;;
	esac
}

do_heartbeat() {
	api_post "/v1/agents/$AGENT_ID/heartbeat" "{\"agent_version\":\"$AGENT_VERSION\"}"
	case "$RC" in
		200|204) return 0 ;;
		401|403) log_error "heartbeat rejected (HTTP $RC) — credentials invalid or revoked"; exit 1 ;;
		*) return 1 ;;
	esac
}

cmd_run() {
	load_config
	require_command curl
	require_command awk
	require_command df

	mkdir -p "$STATE_DIR" 2>/dev/null || log_warn "cannot create state dir $STATE_DIR; network rates reset on restart"

	case "$SERVER_URL" in
		http://*) log_warn "plaintext http:// in use (NM_ALLOW_INSECURE=1): credentials are sent unencrypted" ;;
	esac

	make_netrc

	log_info "agent starting" "version=$AGENT_VERSION" "server=$SERVER_URL" "collect=${COLLECT_INTERVAL}s" "report=${REPORT_INTERVAL}s" "heartbeat=${HEARTBEAT_INTERVAL}s"

	ticks=0
	report_failures=0

	# Prime CPU sampling so the first report has a real delta.
	PREV_CPU="$(cpu_sample)"

	while [ "$RUNNING" -eq 1 ]; do
		sleep "$COLLECT_INTERVAL" &
		SLEEP_PID=$!
		wait "$SLEEP_PID" 2>/dev/null || true
		[ "$RUNNING" -eq 1 ] || break

		sample="$(assemble_sample "$(collect_cpu_pct)")"
		buffer_push "$sample"

		ticks=$((ticks + 1))

		# Report every N collection ticks (report_interval / collect_interval),
		# with backoff after failures: each failure skips the next 2 report
		# windows (~3 report intervals between attempts).
		if [ "$((ticks * COLLECT_INTERVAL % REPORT_INTERVAL))" -lt "$COLLECT_INTERVAL" ]; then
			if [ "$report_failures" -gt 0 ]; then
				report_failures=$((report_failures - 1))
			else
				do_report || report_failures=2
			fi
		fi

		# Heartbeat on its own cadence (cheap liveness + version signal).
		if [ "$((ticks * COLLECT_INTERVAL % HEARTBEAT_INTERVAL))" -lt "$COLLECT_INTERVAL" ]; then
			do_heartbeat || true
		fi
	done

	# Graceful shutdown: one best-effort final flush.
	log_info "signal received; flushing and exiting"
	if [ "${#SAMPLES[@]}" -gt 0 ]; then
		do_report || true
	fi
	log_info "agent stopped"
}

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

cmd_register() {
	local server="" token="" name="" target_config="$CONFIG_FILE"

	while [ $# -gt 0 ]; do
		case "$1" in
			--server) server="$2"; shift 2 ;;
			--token)  token="$2";  shift 2 ;;
			--name)   name="$2";   shift 2 ;;
			--config) target_config="$2"; shift 2 ;;
			*) die "unknown register option: $1 (supported: --server --token --name --config)" ;;
		esac
	done

	# Prefer the NM_TOKEN environment variable: command-line arguments are
	# world-readable via /proc/<pid>/cmdline for the lifetime of the process.
	if [ -z "$token" ] && [ -n "${NM_TOKEN:-}" ]; then
		token="$NM_TOKEN"
	fi

	[ -n "$server" ] || die "register requires --server (e.g. https://api.example.net)"
	[ -n "$token" ]  || die "register requires --token (create one in the NodeMonitor panel under Servers)"

	case "$server" in
		https://*) ;;
		http://*) [ "${NM_ALLOW_INSECURE:-0}" = "1" ] || die "refusing to register against plaintext http:// (use NM_ALLOW_INSECURE=1 for local testing)" ;;
		*) die "--server must start with https://" ;;
	esac

	require_command curl

	if [ -z "$name" ]; then
		name="$(uname -n 2>/dev/null || printf 'unknown-host')"
	fi

	local platform arch
	platform="$(uname -s | tr '[:upper:]' '[:lower:]')"
	arch="$(uname -m)"

	log_info "registering with $server ..."
	local body response tmp body_file
	tmp="$(mktemp)"
	body_file="$(mktemp)"
	body=$(printf '{"token":"%s","name":"%s","hostname":"%s","platform":"%s","arch":"%s","agent_version":"%s"}' \
		"$(json_escape "$token")" "$(json_escape "$name")" "$(json_escape "$HOSTNAME")" \
		"$(json_escape "$platform")" "$(json_escape "$arch")" "$AGENT_VERSION")
	# The registration token goes through a 0600 temp file, not argv: --data
	# would otherwise expose it in /proc/<pid>/cmdline for up to 15 seconds.
	printf '%s' "$body" > "$body_file"
	chmod 600 "$body_file" 2>/dev/null || true

	# No -f: we need the HTTP status of 4xx responses (401 = bad/used token).
	# %{http_code} prints 000 when the transport itself fails.
	response=$(curl -sS --max-time 15 -H 'Content-Type: application/json' \
		-o "$tmp" -w '%{http_code}' -X POST "$server/v1/agents/register" \
		--data-binary @"$body_file" 2>/dev/null)
	[ -n "$response" ] || response="000"
	rm -f "$body_file"

	case "$response" in
		200|201)
			# Extract the fields from the fixed-shape response. The secret is
			# written to the config file immediately and never logged.
			agent_id=$(grep -o '"agent_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp" | head -n 1 | sed 's/.*: *"//;s/"$//')
			agent_secret=$(grep -o '"agent_secret"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp" | head -n 1 | sed 's/.*: *"//;s/"$//')
			rm -f "$tmp"
			[ -n "$agent_id" ] && [ -n "$agent_secret" ] || die "registration response missing credentials"
			;;
		401)
			rm -f "$tmp"
			die "registration rejected: token invalid, expired, or already used"
			;;
		*)
			rm -f "$tmp"
			die "registration failed (HTTP $response)"
			;;
	esac

	umask 077
	mkdir -p "$(dirname "$target_config")" 2>/dev/null || true
	{
		printf 'server_url=%s\n' "$server"
		printf 'agent_id=%s\n' "$agent_id"
		printf 'agent_secret=%s\n' "$agent_secret"
		printf 'collect_interval_seconds=15\n'
		printf 'report_interval_seconds=60\n'
		printf 'heartbeat_interval_seconds=30\n'
	} > "$target_config"
	chmod 600 "$target_config" 2>/dev/null || true

	log_info "registered successfully"
	log_info "config written to $target_config (0600)"
	log_info "start the agent with: nodemonitor-agent run"
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

cmd_check() {
	load_config
	require_command curl

	log_info "config OK: server=$SERVER_URL agent_id=$AGENT_ID"
	log_info "collect=${COLLECT_INTERVAL}s report=${REPORT_INTERVAL}s heartbeat=${HEARTBEAT_INTERVAL}s"

	# Read-only connectivity probe against the gateway.
	if curl -fsS --max-time 10 -o /dev/null "$SERVER_URL/healthz" 2>/dev/null; then
		log_info "API reachable (GET /healthz OK)"
	else
		log_warn "could not reach $SERVER_URL/healthz (the gateway may only allow POST paths)"
	fi

	log_info "sample collection smoke test:"
	PREV_CPU="$(cpu_sample)"
	sleep 0.3
	local sample
	sample="$(assemble_sample "$(collect_cpu_pct)")"
	if printf '%s' "$sample" | grep -q '"cpu_pct"'; then
		log_info "sample assembled OK ($(printf '%s' "$sample" | wc -c | tr -d ' ') bytes)"
	else
		log_error "sample assembly failed"
		return 1
	fi
}

cmd_version() {
	printf 'nodemonitor-agent %s\n' "$AGENT_VERSION"
}

usage() {
	sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-run}" in
	run)      shift 2>/dev/null || true; cmd_run "$@" ;;
	register) shift; cmd_register "$@" ;;
	check)    cmd_check ;;
	version|-V|--version) cmd_version ;;
	help|-h|--help) usage ;;
	*) die "unknown command: $1 (try: run | register | check | version | help)" ;;
esac
