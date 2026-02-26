# OPS Sentinel Suite

Self-correcting automation daemon for OPS-connected machines. Monitors system health, manages services, verifies backups, enforces disk hygiene, and auto-organizes files — all from a single process running every 60 seconds.

## Architecture

One daemon, five phases, priority-ordered:

```
sentinel-daemon.sh (every 60s via LaunchAgent)
│
├── PHASE 1: PRESSURE       (every cycle)   — RAM/swap monitoring + tiered auto-kill
├── PHASE 2: SERVICES       (every cycle)   — LaunchAgent health + auto-restart
├── PHASE 3: BACKUPS        (every 10th)    — OPS sync, GitHub, OPS-mini verification
├── PHASE 4: DISK           (every 10th)    — free space monitoring
├── PHASE 5: FILE JANITOR   (every 5th)     — auto-sort files to OPS-mini
│
└── LOG + ROTATE
```

**Why one daemon?** NODE has 8 GB RAM and routinely hits swap. Multiple agents = multiple processes that fire simultaneously, compounding the problem. One daemon wakes for ~2 seconds every 60 seconds. Pressure runs first — if the machine is dying, RAM is freed before anything else. And because it's one brain, Phase 2 knows Phase 1 just killed a bot — it won't restart what was intentionally killed.

## Key Constraints

- Never auto-restart the machine — always user's choice
- Never kill: claude, Ghostty, Finder, WindowServer, tmux
- 8 GB RAM reality — the suite itself is lightweight (~2s per cycle)
- All actions logged, all thresholds configurable

## Scripts

| Script | Purpose |
|--------|---------|
| `sentinel-daemon.sh` | Main daemon — runs 5-phase pipeline every 60s |
| `sentinel-status.sh` | Live interactive dashboard (2s refresh, keyboard controls) |
| `sentinel-triage.sh` | Emergency RAM liberation (always asks confirmation) |
| `sentinel-utils.sh` | Shared foundation (logging, cooldowns, notifications) |

### Lib Modules (sourced by daemon)

| Module | Purpose |
|--------|---------|
| `lib/check-pressure.sh` | Memory/swap detection + tiered auto-kill |
| `lib/check-services.sh` | LaunchAgent health + auto-restart + crash loop detection |
| `lib/check-backups.sh` | OPS sync, GitHub push freshness, OPS-mini mount |
| `lib/check-disk.sh` | Free space monitoring with warning/critical alerts |
| `lib/check-files.sh` | File janitor — auto-sort to OPS-mini by extension |

## Dashboard

```
sentinel-status
```

Live-updating TUI with color-coded bars and keyboard controls:
- `q` — quit
- `r` — restart all crashed services
- `t` — enter triage mode
- `k` — kill a specific process

## Configuration

All thresholds in `config/sentinel.conf`. Override any value with environment variables.

## Installation

```bash
./install.sh              # Install the suite
./install.sh --uninstall  # Remove (preserves logs and config)
```

After install, start the daemon:

```bash
launchctl load ~/Library/LaunchAgents/com.ops.sentinel.plist
```

## Machine Differences

| Aspect | MAINFRAME | NODE |
|--------|-----------|------|
| Hostname | mainframe.local | node.local |
| User | portcity | curl |
| Homebrew | `/usr/local/` | `/opt/homebrew/` |
| Architecture | Intel | Apple Silicon |

## License

Internal use only — AETHER Project.
