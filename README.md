# OPS Sentinel Suite

Machine-agnostic automation suite for OPS-connected machines in the AETHER ecosystem.

## Overview

The OPS Sentinel Suite provides system monitoring, OPS volume enforcement, and cleanup automation for both NODE and MAINFRAME machines.

## Components

### Scripts
| Script | Purpose |
|--------|---------|
| `sentinel-utils.sh` | Shared utilities (logging, cooldown, dialogs) |
| `sentinel-monitor.sh` | Background system monitor (memory/swap/disk) |
| `sentinel-status.sh` | Quick status check (manual) |
| `sentinel-cleanup.sh` | Cleanup tool |
| `sentinel-watchdog.sh` | Background watchdog |
| `ops-enforcer.sh` | OPS mount/symlink enforcement |
| `ops-mount-unlock.sh` | OPS auto-mount/unlock |
| `leave-readiness.sh` | Pre-departure cleanup |
| `leave-mode.sh` | Resource recovery mode |
| `disk-headroom-enforcer.sh` | Disk space monitoring |
| `memory-pressure-enforcer.sh` | Memory pressure monitoring |

### LaunchAgents
- `com.USER.sentinel-monitor.plist` (5 min interval)
- `com.USER.sentinel-watchdog.plist` (5 min interval)
- `com.USER.ops-enforcer.plist` (10 min interval)
- `com.USER.ops-mount.plist` (60 sec interval)
- `com.USER.disk-headroom.plist` (10 min interval)
- `com.USER.memory-pressure.plist` (10 min interval)

## Machine Differences

| Aspect | MAINFRAME | NODE |
|--------|-----------|------|
| Hostname | mainframe.local | node.local |
| User | portcity | curl |
| Homebrew | `/usr/local/` | `/opt/homebrew/` |
| Architecture | Intel | Apple Silicon |

## Installation

```bash
./install.sh
```

## License

Internal use only — AETHER Project.
