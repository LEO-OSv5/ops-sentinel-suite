# Sentinel Web Dashboard — Design Document

**Date:** 2026-02-28
**Status:** Approved
**Mission:** MSN-2026-0004 (OPS Sentinel Suite)

## Goal

Replace the terminal TUI as the primary monitoring interface with a web dashboard that serves as the notification click target, supports remote monitoring from any device on the local network, and provides full control panel capabilities.

## Architecture

```
sentinel-daemon.sh (every 60s)
│
├── Runs 5-phase pipeline (unchanged)
├── Writes ~/.sentinel-logs/status.json       ← current snapshot
├── Appends ~/.sentinel-logs/history.jsonl    ← time-series data point
├── Writes ~/.sentinel-logs/alerts/alert-*.json  ← alert events
└── Appends ~/.sentinel-logs/actions.jsonl    ← action audit trail

sentinel-webserver.py (always running via LaunchAgent)
│
├── GET /                    → serves dashboard.html
├── GET /api/status          → returns status.json
├── GET /api/history?hours=N → returns history.jsonl (filterable)
├── GET /api/alerts          → returns alert list
├── GET /api/actions         → returns action audit trail
├── POST /api/action/restart → restarts a service via launchctl
├── POST /api/action/kill    → kills a process by PID/name
├── POST /api/action/config  → updates sentinel.conf thresholds
└── POST /api/action/triage  → triggers emergency triage

dashboard.html (single file, no build step)
│
├── System gauges (memory, swap, CPU, disk)
├── Service status table with restart buttons
├── Top processes by RAM with kill buttons
├── Backup channel status
├── Predictions panel (trend extrapolation + kill suggestions)
├── Time-series charts (Chart.js) with window selector
├── Alert timeline (clickable, links to time range)
├── Action audit log
└── Control panel (restart, kill, config editor, triage)
```

**Data flow:** Daemon writes data → Python serves it → Browser renders. Actions: browser → Python → system commands. No database — flat files only.

## Approach Decision

**Python Micro-Server** selected over:
- Bash + socat (too fragile for interactive control)
- Node.js/Bun (30-50MB RAM, overkill for 8GB machine)

Python stdlib `http.server` is pre-installed, ~10-15MB RAM, handles both read and action endpoints.

## Data Model

### status.json (overwritten each cycle)

```json
{
  "timestamp": "2026-02-28T00:01:00Z",
  "cycle": 2595,
  "machine": "NODE",
  "memory": {"used_mb": 7800, "total_mb": 8192, "free_mb": 59, "percent": 95},
  "swap": {"used_mb": 9304, "total_mb": 12288, "percent": 75},
  "disk": {"used_gb": 170, "total_gb": 228, "free_gb": 58, "percent": 74},
  "load": {"avg_1m": 3.2, "cores": 8, "percent": 40},
  "network": {"bytes_in": 12345678, "bytes_out": 9876543},
  "services": [
    {"name": "com.aether.periapsis", "pid": 1234, "exit_code": 0, "status": "running"},
    {"name": "com.aether.occult", "pid": null, "exit_code": 78, "status": "crashed"}
  ],
  "backups": {
    "ops_sync": "registered",
    "ops_mini": "mounted",
    "ops_mini_age_hours": 2,
    "github_stale": []
  },
  "top_processes": [
    {"name": "ollama", "pid": 1234, "rss_mb": 2100, "killable": true},
    {"name": "claude", "pid": 5678, "rss_mb": 800, "killable": false}
  ],
  "pressure_gate": true,
  "phase1_critical": true,
  "predictions": {
    "swap_full_in_minutes": 45,
    "disk_full_in_days": 12,
    "suggested_kills": [
      {"name": "ollama", "rss_mb": 2100, "reason": "Tier 2, would free ~2GB, 90% success rate historically"}
    ],
    "warnings": ["Swap growth rate: +50MB/min — will hit critical in ~45 min"]
  }
}
```

### history.jsonl (appended each cycle, ~150 bytes/line, ~210KB/day)

```
{"t":"2026-02-28T00:01:00","mem":95,"swap":75,"disk":74,"load":40,"free_mb":59,"net_in":1234,"net_out":5678,"top_proc":"ollama:2100,claude:800"}
```

### actions.jsonl (appended on daemon actions)

```
{"t":"2026-02-28T00:01:00","type":"kill","target":"ollama","tier":2,"freed_mb":1200,"success":true}
{"t":"2026-02-28T00:02:00","type":"restart","target":"com.aether.periapsis","exit_code":78}
{"t":"2026-02-28T00:05:00","type":"janitor","files_moved":3,"destination":"/Volumes/OPS-mini/INTAKE"}
```

### Alert JSON files (in ~/.sentinel-logs/alerts/)

```json
{"timestamp": "...", "type": "pressure", "severity": "critical", "message": "...", "detail": "..."}
```

**Retention:** History rotated to 7 days (~1.5MB). Alert files cleaned after 48 hours. Actions rotated to 30 days.

## Dashboard Layout

Clean modern + data-dense. Single responsive page, 6 sections:

1. **Header bar** — Machine name, cycle count, live indicator, time window selector, config button
2. **System gauges** — 4 radial/bar gauges (memory, swap, disk, CPU), free memory callout, pressure state
3. **Services + Backups** — Service table with status/PID/restart buttons, backup channel indicators
4. **Top Processes + Predictions** — RAM leaderboard with kill buttons (protected processes locked), trend warnings, kill suggestions
5. **Trend Charts** — Multi-line time-series (Chart.js), zoomable time window, alert markers on timeline
6. **Alert + Action Timeline** — Chronological feed of alerts and daemon actions, [View] buttons zoom chart to that moment
7. **Control Bar** — Triage mode button, restart-all, config editor drawer

### Key Interactions

- **Time window selector** (1h/6h/24h/7d/All) — filters charts and timeline
- **[Kill]** buttons on killable processes, lock icon on protected
- **[Restart]** buttons per service
- **[View]** on alerts — zooms chart to that moment, shows full detail
- **Notification click** — `http://localhost:8888/#alert-{timestamp}` → auto-scroll + time window
- **Config drawer** — slide-out panel to edit thresholds, saves to sentinel.conf
- **Auto-refresh** — polls /api/status every 5 seconds

## Visual Style

- Clean, modern UI with subtle card-based layout
- Data-dense but not cramped — every element earns its space
- Color coding: green (normal), amber (warning), red (critical)
- Responsive — usable on phone/tablet for remote monitoring

## Security

- **Local network only** — accepts requests from 192.168.x.x, 10.x.x.x, 100.x.x.x (Tailscale), 127.0.0.1
- **Token for actions** — 32-char random token in `~/.sentinel-config/web.token`, required header for POST endpoints
- **Read-only open** — GET endpoints (status, history, alerts) don't require token
- **Target whitelist** — can only kill processes in kill tiers, only restart monitored services, no arbitrary command execution

## Server Details

- **Language:** Python 3 (macOS built-in)
- **Library:** `http.server` (stdlib only, no pip installs)
- **Port:** 8888 (configurable via WEB_PORT in sentinel.conf)
- **RAM:** ~10-15MB
- **LaunchAgent:** `com.ops.sentinel.web` (KeepAlive, RunAtLoad)

## File Changes

### New Files
- `scripts/sentinel-webserver.py` — Python HTTP server (~200 lines)
- `scripts/sentinel-dashboard.html` — Single-file dashboard (HTML+CSS+JS)
- `scripts/lib/write-status.sh` — Status/history/actions JSON writer
- `launchagents/com.ops.sentinel.web.plist` — Web server LaunchAgent

### Modified Files
- `scripts/sentinel-daemon.sh` — Call write-status.sh after each cycle
- `scripts/sentinel-utils.sh` — Notification click → dashboard URL
- `config/sentinel.conf` — Add WEB_PORT, WEB_TOKEN_FILE
- `install.sh` — Install webserver, generate token, add web LaunchAgent

## Predictions Engine

Simple trend analysis, not ML:
- Linear regression on last 30 data points for swap/disk growth rate
- Extrapolate to threshold → "swap full in ~X minutes"
- Kill suggestions: rank by RSS + historical freed_mb from actions.jsonl
- Pattern detection: identify recurring time-of-day spikes (future iteration)
