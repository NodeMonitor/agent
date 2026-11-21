# Installation guide

## Requirements

- Linux with systemd (Debian ≥ 10, Ubuntu ≥ 20.04, RHEL/Alma/Rocky ≥ 8, Alpine ≥ 3.16 with the `openrc`→systemd note below, Arch, and similar)
- amd64 or arm64
- `bash`, `curl`, `sha256sum`, `df`, `awk` (present on all of the above)
- Outbound HTTPS to your NodeMonitor agent-api endpoint

Alpine ships OpenRC by default; the installer writes a systemd unit, so on
Alpine either enable `systemd` (unusual) or run the agent from an init script /
cron entry manually — see "Manual installation" below.

## One-line install

1. In the NodeMonitor panel, open **Servers → Add server** and copy the
   registration token (one-time, expires in 24h).
2. Run on the target host as root:

```sh
curl -fsSL https://raw.githubusercontent.com/NodeMonitor/agent/main/install.sh \
  | NM_TOKEN=<your-token> bash
```

With options:

```sh
curl -fsSL https://raw.githubusercontent.com/NodeMonitor/agent/main/install.sh \
  | NM_TOKEN=<token> NM_SERVER=https://api.example.net NM_NAME=prod-db-1 bash
```

| Variable | Meaning |
|---|---|
| `NM_TOKEN` | registration token (required on first install) |
| `NM_SERVER` | agent-api base URL (default `https://api.nodemon.net`) |
| `NM_NAME` | display name shown in the panel (default: hostname) |
| `NM_VERSION` | pin a release tag, e.g. `v1.0.0` (default: latest release) |

The installer: verifies the script SHA-256 against the release `checksums.txt`
(mandatory — it refuses unverified files), creates a locked `nodemonitor`
system user, registers the host (burns the token, writes
`/etc/nodemonitor/agent.conf` mode `0640` root:`nodemonitor`), installs a
hardened systemd unit (`NoNewPrivileges`, `ProtectSystem=strict`,
`PrivateTmp`, `PrivateDevices`, `RestrictSUIDSGID`, `RestrictAddressFamilies`,
`ReadWritePaths=/var/lib/nodemonitor`), and enables + starts the service.

## Verify

```sh
systemctl status nodemonitor-agent
journalctl -u nodemonitor-agent -n 50
nodemonitor-agent check
```

The host appears on the panel's Servers page after the first heartbeat
(about 30 seconds).

## Upgrade

Re-run the installer with the same environment (no token needed once a config
exists — the registration step is skipped). To pin a specific release:

```sh
curl -fsSL https://raw.githubusercontent.com/NodeMonitor/agent/main/install.sh \
  | NM_VERSION=v1.1.0 bash
```

## Uninstall

```sh
sudo bash uninstall.sh          # stop + remove binary, unit, state (keeps config)
sudo bash uninstall.sh --purge  # also removes /etc/nodemonitor and the 'nodemonitor' user
```

Revoking access instead: delete or revoke the server in the panel; the next
push receives `403 AGENT_REVOKED` and the unit enters a failed state. Then run
`uninstall.sh --purge` on the host.

## Manual installation (no systemd, restricted hosts)

```sh
# 1. Fetch and verify
curl -fsSL -o nodemonitor-agent.sh \
  https://github.com/NodeMonitor/agent/releases/latest/download/nodemonitor-agent.sh
curl -fsSL -o checksums.txt \
  https://github.com/NodeMonitor/agent/releases/latest/download/checksums.txt
grep nodemonitor-agent.sh checksums.txt | sha256sum -c -

# 2. Register (writes ./agent.conf by default)
chmod +x nodemonitor-agent.sh
sudo ./nodemonitor-agent.sh register --server https://api.example.net --token <TOKEN>

# 3. Run continuously (cron every minute is fine — the script loop skips
#    overlapping work via its own intervals):
#    * * * * * nodemonitor run --once   (see note below)
# or keep a long-running loop under your init system:
sudo nohup nodemonitor-agent.sh run >/var/log/nodemonitor-agent.log 2>&1 &
```

> Note: the `--once` mode is not implemented yet; under cron, use the
> long-running loop above or wrap `run` with your init system.

## Configuration reference

`/etc/nodemonitor/agent.conf` (key=value, parsed by `grep`, never sourced):

| Key | Default | Meaning |
|---|---|---|
| `server_url` | set at register | agent-api base URL (HTTPS) |
| `agent_id` | set at register | agent identity |
| `agent_secret` | set at register | per-agent secret (0600 file) |
| `collect_interval_seconds` | `15` | metric sampling cadence (≥ 5) |
| `report_interval_seconds` | `60` | push cadence (≥ 10) |
| `heartbeat_interval_seconds` | `30` | liveness ping cadence |

Environment overrides: `NM_CONFIG_FILE`, `NM_STATE_DIR`, `NM_ALLOW_INSECURE=1`
(permit plaintext http — local testing only).

## Data handling

- Metrics live in memory (max 12 buffered samples) and are pushed to your
  configured endpoint only.
- The only files written are `/etc/nodemonitor/agent.conf` and
  `/var/lib/nodemonitor/net.state` (last network counters, so rates survive
  restarts without a giant first sample).
- To stop all collection and erase local state: `uninstall.sh --purge`.
