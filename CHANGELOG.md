# Changelog

All notable changes to the OPS Sentinel Suite will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.2.0] — 2026-02-28

### Added
- `scripts/sentinel-webserver.py` — Python stdlib HTTP server for web dashboard (GET/POST API, token auth, local subnet restriction) — 2026-02-28
- `scripts/sentinel-dashboard.html` — single-file web dashboard with Chart.js charts, service controls, process kill buttons, config editor, alert timeline — 2026-02-28
- `scripts/lib/write-status.sh` — status.json + history.jsonl + actions.jsonl writer called each daemon cycle — 2026-02-28
- `launchagents/com.ops.sentinel.web.plist` — KeepAlive LaunchAgent for web server — 2026-02-28
- Predictions engine: linear trend extrapolation for swap/disk + kill suggestions based on action history — 2026-02-28
- Action audit trail: all kills, restarts, and janitor actions recorded to actions.jsonl — 2026-02-28
- Web dashboard config: WEB_PORT, WEB_TOKEN_FILE, WEB_REFRESH_SECONDS, WEB_HISTORY_DAYS, WEB_ACTIONS_DAYS — 2026-02-28
- Token-based auth for action endpoints (generated at install, stored in web.token) — 2026-02-28
- Notification click opens web dashboard at `#alert-{timestamp}` deep link (falls back to .txt if server down) — 2026-02-28

### Changed
- `sentinel-daemon.sh` — calls write_status after each cycle to generate dashboard data — 2026-02-28
- `sentinel_notify()` — writes JSON alert files, clicks open web dashboard URL — 2026-02-28
- `install.sh` — installs webserver, dashboard, web LaunchAgent, generates auth token — 2026-02-28
- `check-pressure.sh`, `check-services.sh`, `check-files.sh` — record actions to actions.jsonl — 2026-02-28

## [1.1.0] — 2026-02-27 @ 23:34

### Changed
- Replaced `osascript` notifications with `terminal-notifier` — clicking a notification now opens a rich alert file with full context (what happened, detail, recommended actions, recent log lines) instead of opening Script Editor — 2026-02-27
- All 14 notification call sites across 5 modules now include contextual detail strings (pressure stats, service names/exit codes, backup channel status, disk usage, file counts) — 2026-02-27

### Added
- Alert summary files generated in `~/.sentinel-logs/alerts/` on every notification — auto-cleaned after 24 hours — 2026-02-27
- `install.sh` now checks for `terminal-notifier` and suggests `brew install` if missing — 2026-02-27

## [1.0.0] — 2026-02-25 @ 00:00

### Added
- Complete suite redesign: single layered daemon replaces multi-agent architecture — 2026-02-25
- `config/sentinel.conf` — centralized configuration with env-var overrides for all thresholds, kill tiers, service lists, backup repos, file janitor settings, and daemon intervals — 2026-02-25
- `scripts/lib/check-pressure.sh` — memory/swap detection with 3-tier auto-kill system (Tier 1: expendable apps, Tier 2: heavy optional, Tier 3: expendable bots), pressure gate flag for Phase 2, kill cooldown — 2026-02-25
- `scripts/lib/check-services.sh` — LaunchAgent health monitoring with auto-restart, crash loop detection (3 restarts/hour max), pressure gate integration — 2026-02-25
- `scripts/lib/check-backups.sh` — backup channel verification for OPS sync agent, GitHub push freshness, and OPS-mini mount/staleness — 2026-02-25
- `scripts/lib/check-disk.sh` — root volume free space monitoring with warning (< 10 GB) and critical (< 5 GB) thresholds — 2026-02-25
- `scripts/lib/check-files.sh` — file janitor that auto-sorts files from Downloads/Desktop to OPS-mini by extension category (9 categories), with date prefixes, collision handling, skip logic, and fallback queue — 2026-02-25
- `scripts/sentinel-daemon.sh` — main daemon orchestrator running 5-phase priority pipeline (pressure → services → backups → disk → janitor) with configurable intervals and cycle counter — 2026-02-25
- `scripts/sentinel-status.sh` — live interactive TUI dashboard with 2-second refresh, color-coded bars (memory/swap/CPU/disk), service status table, backup channel status, keyboard controls (q/r/t/k) — 2026-02-25
- `scripts/sentinel-triage.sh` — emergency manual triage tool with RAM estimates, kill preview, explicit confirmation required — 2026-02-25
- `launchagents/com.ops.sentinel.plist` — single KeepAlive LaunchAgent for the daemon — 2026-02-25
- `install.sh` — one-command installer with `--uninstall` support, config preservation, shell alias setup — 2026-02-25
- `tests/` — comprehensive test suite (180 tests) covering all lib modules, config loading, utils, and daemon integration — 2026-02-25
- `docs/plans/2026-02-24-ops-sentinel-suite-redesign.md` — approved design specification — 2026-02-24
- `docs/plans/2026-02-24-sentinel-implementation-plan.md` — 13-task TDD implementation plan — 2026-02-24

### Changed
- Updated `scripts/sentinel-utils.sh` to v0.2.0 — added `load_config()` function with priority-based config loading (explicit arg > user config > repo default) — 2026-02-25

## [0.2.0] — 2026-02-07 @ 06:45

### Added
- Created `scripts/sentinel-utils.sh` — shared foundation sourced by all sentinel scripts, providing machine detection (NODE/MAINFRAME auto-detect), path constants, directory bootstrap, color codes, logging with rotation, cooldown management, argv-safe AppleScript UI wrappers, and configurable threshold defaults — 2026-02-07 @ 06:45

### Removed
- Removed `scripts/.gitkeep` — no longer needed now that real scripts exist in the directory — 2026-02-07 @ 06:45

## [0.0.1] — 2026-02-06 @ 00:00

### Added
- Repository created under ARGS governance — establishing version-controlled home for OPS Sentinel Suite — 2026-02-06 @ 00:00
- Initial repository structure with `scripts/` directory, `README.md` with project overview and component inventory, and `CHANGELOG.md` — 2026-02-06 @ 00:00
- Documentation populated with component inventory, machine differences table, and LaunchAgent listing — 2026-02-06 @ 00:00
