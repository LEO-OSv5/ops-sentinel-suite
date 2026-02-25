# OPS Sentinel Suite — Redesign

> **Date:** 2026-02-24
> **Status:** Approved
> **Mission:** MSN-2026-0004
> **Target:** NODE (node.local, Apple Silicon, 8 GB RAM, user: curl)

---

## Overview

The OPS Sentinel Suite is a self-correcting automation daemon for NODE. It monitors system health, manages services, verifies backups, enforces disk hygiene, and auto-organizes files — all from a single process running every 60 seconds.

**Core philosophy:** Fix problems before they become freezes. Pressure-first. One brain, no internal conflicts.

**Key constraints:**
- Never auto-restart the machine — always user's choice
- Never kill: claude, Ghostty, Finder, WindowServer, tmux
- 8 GB RAM reality — the suite itself must be lightweight (one process, ~2s per cycle)
- All actions logged, all thresholds configurable

---

## Architecture: Layered Daemon

One central script (`sentinel-daemon.sh`) runs every 60 seconds via a single LaunchAgent. It executes a priority-ordered pipeline of checks:

```
sentinel-daemon.sh (every 60s via LaunchAgent)
│
├── source sentinel-utils.sh     ← machine detection, logging, cooldowns, UI
├── source sentinel.conf         ← thresholds, kill lists, service lists
│
├── PHASE 1: PRESSURE       (every cycle)   — self-correction
├── PHASE 2: SERVICES       (every cycle)   — bot health + auto-restart
├── PHASE 3: BACKUPS        (every 10th)    — sync/push/mount verification
├── PHASE 4: DISK           (every 10th)    — free space monitoring
├── PHASE 5: FILE JANITOR   (every 5th)     — auto-sort to OPS-mini
│
└── LOG + ROTATE
```

### Why one daemon, not multiple agents

NODE has 8 GB RAM and routinely hits 5+ GB swap. Multiple LaunchAgents = multiple resident processes that can fire simultaneously, compounding the very problem they solve. One daemon wakes for ~2 seconds every 60 seconds — minimal overhead. The pressure check runs FIRST, so if the machine is dying, RAM is freed before anything else executes. And because it's one brain, Phase 2 (services) knows Phase 1 (pressure) just killed a bot — it won't restart what was intentionally killed.

---

## Phase 1: Pressure Management

Runs every cycle (60s). Reads memory state and takes autonomous action at configurable thresholds.

### Detection

```
Read: vm_stat → pages free, pages active, pages inactive, pages wired
Read: sysctl vm.swapusage → swap used MB
Read: sysctl -n hw.ncpu + uptime → load average vs core count
Calculate: free_mb, swap_used_mb, memory_percent, load_ratio
```

### Action Tiers

| Condition | Action |
|-----------|--------|
| NORMAL (swap < 2 GB) | Log silently, no action |
| WARNING (swap 2-4 GB) | macOS notification: "Memory pressure elevated" |
| CRITICAL (swap > 4 GB OR free < 200 MB) | Auto-kill by tier (see below) |

### Kill Priority (configurable in sentinel.conf)

| Tier | Targets | Rationale |
|------|---------|-----------|
| 1 — Expendable | ChatGPT Atlas, Typeless, other Electron apps | Heavy, rarely essential, first to go |
| 2 — Heavy optional | ollama, Google Updater processes | Resource hogs that can be restarted later |
| 3 — Trading bots | Expendable bots (OCCULT, ADXStoch, SYZYGY) | Only if Tier 1+2 didn't free enough |
| NEVER | claude, Ghostty, Finder, WindowServer, tmux, launchd | Protected always |

### Kill Flow

```
If CRITICAL:
  1. Kill all TIER_1 processes → measure freed RAM
  2. If still critical → kill TIER_2
  3. If STILL critical → kill TIER_3
  4. Notify: "Sentinel freed X MB — killed [list]"
  5. set_cooldown "pressure-kill" 300 (don't re-kill for 5 min)
```

---

## Phase 2: Service Monitoring

Runs every cycle (60s). Checks LaunchAgent health for monitored services.

### Monitored Services (configurable)

- `com.aether.periapsis` (port 8080)
- `com.aether.occult` (port 8081)
- `com.aether.syzygy` (port 8082)
- `com.aether.adxstoch` (port 8083)
- `com.aether.aether-strategy` (port 8084)
- `com.ops.sync`

### Logic

```
For each service in MONITORED_SERVICES:
  status = launchctl list | grep SERVICE → parse exit code

  If exit != 0 (crashed):
    If PHASE_1_WAS_CRITICAL → SKIP (pressure gate: don't restart what was just killed)
    If restarts_this_hour >= MAX_RESTARTS_PER_HOUR (3):
      Log: "CRASH LOOP: SERVICE"
      Notify: "SERVICE is crash-looping — manual intervention needed"
    Else:
      launchctl kickstart -k "gui/$(id -u)/SERVICE"
      Log: "Restarted SERVICE (was exit code X)"
      Notify: "Sentinel restarted SERVICE"
      increment restart counter

  If running: log silently
```

### Pressure Gate

If Phase 1 took CRITICAL action (killed processes), Phase 2 will NOT restart any services that cycle. This prevents the daemon from fighting itself — killing a bot to free RAM then immediately restarting it.

---

## Phase 3: Backup Verification

Runs every 10th cycle (~10 minutes).

### Channels Checked

| Channel | How | Stale Threshold |
|---------|-----|-----------------|
| OPS sync agent | Check `com.ops.sync` last run time via launchctl | 30 minutes |
| GitHub push | `git -C /path/to/repo log --format=%ct -1` for key repos | 24 hours |
| OPS-mini mount | `mount | grep OPS-mini` + stat a known file | 48 hours since last write |

### Key Repos to Check

- `/Users/curl/OPS` (ops repo)
- `/Users/curl/repos/aether-periapsis`
- `/Users/curl/repos/aethernote`
- `/Users/curl/repos/strategist`
- `/Users/curl/repos/ops-sentinel-suite`

### Actions

```
If OPS sync stale > 30 min → Notify: "OPS sync hasn't run in X minutes"
If any repo not pushed in 24h → Notify: "REPO hasn't been pushed in X hours"
If OPS-mini not mounted → Notify: "OPS-mini disconnected — backups paused"
If OPS-mini mounted but stale → Notify: "OPS-mini backup is X hours old"
```

---

## Phase 4: Disk Monitoring

Runs every 10th cycle (~10 minutes).

```
free_gb = df -h / → parse available

If free_gb < 5 → Notify CRITICAL: "NODE SSD critically low: X GB free"
If free_gb < 10 → Notify WARNING: "NODE SSD getting low: X GB free"
Else → log silently
```

---

## Phase 5: File Janitor

Runs every 5th cycle (~5 minutes). Auto-sorts files from hot folders to OPS-mini.

### Source Folders

- `~/Downloads/`
- `~/Desktop/`

### Destination

Primary: `/Volumes/OPS-mini/INTAKE/{category}/`
Fallback (OPS-mini disconnected): `~/Documents/_intake-queue/`

### Sort Rules (by extension)

| Category | Extensions |
|----------|------------|
| docs | .pdf, .doc, .docx, .txt, .md, .rtf, .pages |
| images | .png, .jpg, .jpeg, .gif, .webp, .heic, .svg, .ico |
| video | .mp4, .mov, .mkv, .avi, .webm |
| audio | .mp3, .wav, .flac, .m4a, .aac, .ogg |
| archives | .zip, .tar, .gz, .rar, .7z, .bz2 |
| installers | .dmg, .pkg, .app |
| data | .csv, .xlsx, .json, .xml, .yaml, .yml, .sql |
| code | .py, .js, .ts, .sh, .rb, .go, .rs, .swift |
| other | everything else |

### Behavior

- **MOVE** (not copy) — frees NODE SSD space
- **Date prefix:** `2026-02-24_filename.ext`
- **Collision handling:** append `-1`, `-2`, etc.
- **Age-based sweep:** Desktop > 7 days, Downloads > 3 days → auto-sort regardless
- **Skip in-progress:** `.crdownload`, `.part`, `.tmp` extensions ignored
- **Skip open files:** `lsof` check before moving
- **Queue flush:** when OPS-mini reconnects, move everything from `_intake-queue/` to OPS-mini

---

## Manual Tools

### sentinel-status.sh — Live Interactive Dashboard

A live-updating TUI that refreshes every 2 seconds with keyboard controls.

**Display sections:**
- Memory/Swap/CPU/Disk with animated color-coded bars (green < 60%, yellow 60-80%, red > 80%)
- Service status table with uptime, restart count, crash indicators
- Backup freshness for all channels
- File janitor stats (sorted today, pending)
- Activity log (scrolling recent daemon events)

**Keyboard controls:**
- `q` — quit dashboard
- `r` — restart all crashed services now
- `t` — enter triage mode
- `k` — pick a specific process to kill

### sentinel-triage.sh — Emergency Mode

Manual nuclear option. Always asks for confirmation.

```
sentinel-triage
→ "TRIAGE MODE: Kill all Tier 1+2 apps, stop non-essential bots? [y/N]"
→ Shows what will be killed + estimated RAM freed
→ Requires explicit 'y' to proceed
→ Logs all actions
→ Keeps: PERIAPSIS (primary), claude, Ghostty, Finder, tmux
```

---

## File Structure

```
ops-sentinel-suite/
├── scripts/
│   ├── sentinel-utils.sh          ← EXISTS (shared foundation)
│   ├── sentinel-daemon.sh         ← main daemon (60s pipeline)
│   ├── sentinel-status.sh         ← live interactive dashboard
│   ├── sentinel-triage.sh         ← emergency RAM liberation
│   └── lib/
│       ├── check-pressure.sh      ← memory/swap/CPU + auto-kill
│       ├── check-services.sh      ← LaunchAgent health + auto-restart
│       ├── check-backups.sh       ← OPS sync, GitHub, OPS-mini
│       ├── check-disk.sh          ← free space monitoring
│       └── check-files.sh         ← file janitor (sort to OPS-mini)
├── launchagents/
│   └── com.ops.sentinel.plist     ← single LaunchAgent (60s)
├── config/
│   └── sentinel.conf              ← all thresholds and configuration
├── install.sh                     ← one-command deploy + uninstall
├── docs/
│   └── plans/
│       └── 2026-02-24-ops-sentinel-suite-redesign.md  ← this file
├── README.md
└── CHANGELOG.md
```

---

## Configuration (sentinel.conf)

```bash
# ═══════════════════════════════════════════════
# OPS Sentinel Suite — Configuration
# ═══════════════════════════════════════════════

# --- Pressure Thresholds ---
SWAP_WARNING_MB=2048
SWAP_CRITICAL_MB=4096
MEMORY_FREE_CRITICAL_MB=200

# --- Kill Tiers (comma-separated process names) ---
KILL_TIER_1="ChatGPT Atlas,Typeless"
KILL_TIER_2="ollama"
KILL_TIER_3="com.aether.occult,com.aether.adxstoch,com.aether.syzygy"
KILL_NEVER="claude,Ghostty,Finder,WindowServer,tmux,launchd"

# --- Service Monitoring ---
MONITORED_SERVICES="com.aether.periapsis,com.aether.occult,com.aether.syzygy,com.aether.adxstoch,com.aether.aether-strategy,com.ops.sync"
AUTO_RESTART=true
MAX_RESTARTS_PER_HOUR=3

# --- Backup Freshness ---
GITHUB_STALE_HOURS=24
OPS_SYNC_STALE_MINUTES=30
OPS_MINI_STALE_HOURS=48
GITHUB_REPOS="/Users/curl/OPS,/Users/curl/repos/aether-periapsis,/Users/curl/repos/aethernote,/Users/curl/repos/strategist,/Users/curl/repos/ops-sentinel-suite"

# --- Disk ---
DISK_WARNING_GB=10
DISK_CRITICAL_GB=5

# --- File Janitor ---
JANITOR_ENABLED=true
JANITOR_WATCH_DIRS="$HOME/Downloads,$HOME/Desktop"
JANITOR_DESTINATION="/Volumes/OPS-mini/INTAKE"
JANITOR_FALLBACK_QUEUE="$HOME/Documents/_intake-queue"
JANITOR_DESKTOP_MAX_AGE_DAYS=7
JANITOR_DOWNLOADS_MAX_AGE_DAYS=3
JANITOR_DATE_PREFIX=true
JANITOR_IGNORE="*.crdownload,*.part,*.tmp"

# --- Daemon ---
DAEMON_CYCLE_SECONDS=60
BACKUP_CHECK_INTERVAL=10
DISK_CHECK_INTERVAL=10
JANITOR_CHECK_INTERVAL=5
LOG_MAX_LINES=5000

# --- Notifications ---
NOTIFY_METHOD="macos"
```

---

## Notification Strategy

All notifications use macOS native notification center via `osascript`:
- **INFO** — silent banner (slides in, auto-dismisses)
- **WARNING** — persistent banner (stays until dismissed)
- **CRITICAL** — alert dialog (blocks until user interacts)

Notifications include the Sentinel name and action taken, e.g.:
- "Sentinel freed 660 MB — killed ChatGPT Atlas"
- "SYZYGY crash-looping — 3 restarts in 1 hour"
- "OPS-mini disconnected — file janitor queuing"

---

## Install & Deploy

### install.sh

```
./install.sh
1. Detect machine (NODE/MAINFRAME via sentinel-utils.sh)
2. Create directories:
   ~/.local/share/ops-sentinel/     (scripts)
   ~/.sentinel-state/               (cooldowns, restart counters)
   ~/.sentinel-logs/                (daemon logs)
   ~/.sentinel-config/              (user config)
3. Copy scripts + lib/ to ~/.local/share/ops-sentinel/
4. Copy default sentinel.conf to ~/.sentinel-config/sentinel.conf
5. Install LaunchAgent: com.ops.sentinel.plist → ~/Library/LaunchAgents/
6. Add shell aliases to .zshrc:
   sentinel-status → dashboard
   sentinel-triage → emergency mode
7. launchctl load com.ops.sentinel.plist
8. Run sentinel-status to verify

./install.sh --uninstall
1. launchctl unload com.ops.sentinel.plist
2. Remove LaunchAgent plist
3. Remove shell aliases
4. Preserve logs and config (manual cleanup if wanted)
```

---

## Build Order

1. `sentinel-utils.sh` — EXISTS, may need minor updates for new config loading
2. `sentinel.conf` — configuration file
3. `lib/check-pressure.sh` — pressure detection + tiered kill
4. `lib/check-services.sh` — service health + auto-restart
5. `lib/check-backups.sh` — backup channel verification
6. `lib/check-disk.sh` — disk space monitoring
7. `lib/check-files.sh` — file janitor
8. `sentinel-daemon.sh` — main loop that orchestrates all phases
9. `sentinel-status.sh` — live interactive dashboard
10. `sentinel-triage.sh` — emergency tool
11. `com.ops.sentinel.plist` — LaunchAgent
12. `install.sh` — deployment script
13. Test full cycle on NODE
