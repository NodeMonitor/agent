# NodeMonitor agent

The NodeMonitor host agent is a **single bash script**. There is no compiled
binary, no hidden download, and no dependency beyond `bash`, `curl`, and the
coreutils present on every Linux server. Read `nodemonitor-agent.sh` end to
end before you install it — that is the point of it being one file.

The agent reports host metrics to your NodeMonitor instance so the Servers
page can show fleet health, host telemetry, and history. It never opens
inbound ports, never executes anything the API sends it, and writes nothing
outside its config and state directories.

## What it collects

| Metric | Source | Notes |
|---|---|---|
| CPU utilisation | `/proc/stat` | sampled as deltas between collections |
| Load averages | `/proc/loadavg` | 1m / 5m / 15m |
| Memory used/total | `/proc/meminfo` | `used = total − MemAvailable` |
| Swap used/total | `/proc/meminfo` | |
| Per-mount filesystem use | `df -kP` | block devices only, deduped, 8 largest |
| Root filesystem aggregate | `df -kP /` | the `disk_*` aggregate fields |
| Network byte rates | `/proc/net/dev` | rates computed on the host (bytes/sec) |
| Uptime | `/proc/uptime` | |
| Process count | `/proc` | numeric PID directory count |

Identity sent with every push: hostname, platform (`linux`), architecture,
agent version. **Nothing else** — no process lists, no command output, no
environment data.

## Transport and credentials

- The agent pushes over HTTPS using HTTP Basic auth (`agent_id` + per-agent
  secret). The secret is generated at registration, stored `0600` in
  `/etc/nodemonitor/agent.conf`, and never leaves the host except in the auth
  header. Plaintext `http://` endpoints are refused unless you set
  `NM_ALLOW_INSECURE=1` (local testing only).
- Metrics are buffered in memory (last 12 samples) and retried with backoff;
  nothing is lost during short API outages.
- When credentials are revoked from the panel, the API answers
  `403 AGENT_REVOKED`, the agent logs it clearly and exits non-zero so systemd
  marks the unit failed. Re-run the installer with a fresh token to re-register.

## Install

Create a registration token in the NodeMonitor panel (Servers → Add server),
then on the target host:

```sh
curl -fsSL https://raw.githubusercontent.com/NodeMonitor/agent/main/install.sh \
  | NM_TOKEN=<your-token> bash
```

Options: `NM_SERVER` (your agent-api base URL), `NM_NAME` (display name),
`NM_VERSION` (pin a release tag). The installer verifies the script's SHA-256
against the release `checksums.txt` before installing — always.

Full instructions, distro notes, and manual-install steps: [INSTALLATION.md](INSTALLATION.md).

## Upgrade & uninstall

```sh
sudo bash install.sh              # re-run with the same env: downloads, verifies, restarts
sudo bash uninstall.sh            # stops and removes the agent (keeps config)
sudo bash uninstall.sh --purge    # also removes config and the 'nodemonitor' system user
```

## Verify

```sh
systemctl status nodemonitor-agent
nodemonitor-agent check       # validates config, connectivity, and a sample collection
```

## Supported platforms

Linux with systemd on amd64 and arm64 (Debian, Ubuntu, RHEL-family, Alpine,
Arch — anything shipping `bash`, `curl`, `df`, `awk`). Other platforms
(macOS launchd, Windows services) are not supported yet; see the product plan
for the roadmap.

## Repository layout

```
nodemonitor-agent.sh   the agent (daemon, collector, register, check)
install.sh             installer: download → verify checksum → user → systemd
uninstall.sh           uninstaller (--purge removes everything)
INSTALLATION.md        distro notes and manual installation
.github/workflows      shellcheck CI + checksummed release automation
```

## License

[MIT](LICENSE) — audit it, fork it, ship it.
