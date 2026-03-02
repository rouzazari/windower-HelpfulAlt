# HelpfulAlt

> A Windower 4 addon that autonomously controls a secondary FFXI account playing a healer or support role. Designed to keep your alt running hands-free while you focus on your main character.

**Version:** 2.0.0
**Command:** `//ha` or `//helpfulalt`

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Commands](#commands)
- [Configuration](#configuration)
- [How It Works](#how-it-works)
- [Roadmap](#roadmap)
- [Change Log](#change-log)
- [Known Issues](#known-issues)

---

## Prerequisites

1. [Final Fantasy XI Online](http://www.playonline.com/ff11us/index.shtml)
2. [Windower 4](http://windower.net/)

---

## Installation

1. Copy the `HelpfulAlt` folder into your `Windower4/addons/` directory.
2. Load the addon in-game:

       //lua load HelpfulAlt

   Or add it to your Windower `init.txt` to load automatically on login:

       lua load HelpfulAlt

---

## Usage

HelpfulAlt starts enabled by default. On load it will immediately check whether your configured songs are active and cast any that are missing.

Enable or disable automation at any time:

    //ha on
    //ha off

Check the current state of your songs:

    //ha status

---

## Commands

| Command | Description |
|---|---|
| `//ha on` | Enable autonomous song upkeep |
| `//ha off` | Disable autonomous song upkeep |
| `//ha status` | Show each song slot: active, missing, or last cast time |
| `//ha recast` | Show the recast timer remaining for each configured song |
| `//ha song <1\|2> <name>` | Change a song slot at runtime (saves to config) |

### Examples

    //ha song 1 Blade Madrigal
    //ha song 2 Victory March
    //ha song 2 Advancing March
    //ha status
    //ha recast

Song names are case-sensitive and must match the in-game spell name exactly.

---

## Configuration

Settings are saved automatically to `data/settings.xml` on first load. You can edit this file directly or use the `//ha song` command to update slots at runtime.

| Setting | Default | Description |
|---|---|---|
| `enabled` | `true` | Whether automation is active on load |
| `song1` | `Blade Madrigal` | Song in slot 1 (highest priority) |
| `song2` | `Victory March` | Song in slot 2 |
| `song_count` | `2` | Number of song slots to manage (1–2) |
| `song_duration` | `110` | Seconds before re-casting a song with no buff ID tracking |

---

## How It Works

### Song tracking

Each configured song is monitored using two complementary strategies:

- **Buff ID tracking (preferred):** The addon looks up the buff ID that the spell applies from Windower's spell resources. When a `gain buff` event fires with that ID, the song is marked active. When a `lose buff` event fires, the addon immediately attempts to re-cast.
- **Time-based fallback:** For songs where no buff ID is available in resources, the addon records the time of the last cast and re-casts after `song_duration` seconds.

A quick safety-net check runs every ~5 seconds (for recast polling) and a full buff sync runs every ~60 seconds, catching any missed events or edge cases.

### Cast sequencing

When one or more songs are missing, the addon issues one `/ma` command at a time in slot priority order (slot 1 first). After each spell completes, an incoming action packet (category 4) triggers the next cast automatically. If a spell is on recast, that slot is skipped and the next slot is attempted; the periodic check resumes the skipped slot once the recast clears.

### Interruption handling

The addon listens for action packet category 8 with param `28787` (cast interrupted). When detected, the `casting` lock is cleared and a retry is scheduled after 10 seconds, avoiding the "Unable to cast spells at this time" lockout. A `last_cast` timestamp on each `/ma` also enforces a minimum 10-second window before any retry.

### Safety checks

The addon will not cast while the player is dead or zoning. It resumes automatically when returning to an idle or engaged state.

---

## Roadmap

### ✅ Milestone 1 — BRD 2-Song Upkeep
Autonomous maintenance of two configurable songs. Reactive buff tracking with time-based fallback, interruption handling, and a periodic safety-net.

### ✅ Milestone 2 — Robustness & Action-Packet Sequencing *(current)*
Cast sequencing driven by incoming action packets instead of a timed delay. Interruption detection via packet category. Faster recast polling. Fixed numeric config coercion bug that prevented the second song from casting.

### Milestone 3 — 3 and 4 Song Support
- Expand `song_count` to support up to 4 slots
- Detect available song capacity from equipped gear/traits
- Sequential casting order with configurable priority

### Milestone 4 — Party Healing (WHM / SCH / RDM)
- Monitor party HP% and cast Cure spells when members drop below a threshold
- Configurable HP threshold and cure tier selection
- Commands: `//ha heal on/off`, `//ha threshold <pct>`

### Milestone 5 — Debuff Removal
- Detect debuffs on party members via party buff packets
- Priority-ordered removal (Poison → Curse → Paralysis → Blind → Silence → etc.)
- Job-aware: only attempts spells available on the current job
- Commands: `//ha debuff on/off`

### Milestone 6 — Main Healer Mode
- Full autonomous healing loop suitable for being the primary healer
- MP management with configurable floor — rests to recover when low
- Emergency priority for sudden HP drops and KO'd party members
- Commands: `//ha healer on/off`, `//ha mpfloor <pct>`

---

## Change Log

### 2.0.0
- Reworked: Cast sequencing now driven by incoming action packets (0x028) instead of a fixed `cast_delay` timer, eliminating the coroutine-based inter-song pause
- Fixed: Second song now reliably casts when both songs are missing — root cause was `cast_delay` loaded as a string from XML, causing a silent coroutine error that left the `casting` flag stuck
- Added: `incoming chunk` handler detects spell completion (category 4) and interruption (category 8, param 28787) and drives the next cast automatically
- Added: `coerce_settings()` applies `tonumber()` to all numeric config values after load
- Added: Quick upkeep check every ~5 seconds via `prerender` for faster recast polling (was ~60 seconds)
- Removed: `cast_delay` setting (no longer needed)

### 1.0.1
- Fixed: `sync_active_songs` now only tracks configured song buff IDs, preventing false positives from unrelated buffs sharing the same numeric ID
- Fixed: Songs with no buff ID in resources now use time-based tracking instead of being silently skipped
- Fixed: `pcall` removed from cast coroutine — Lua 5.1 does not allow yielding inside a `pcall`, which caused the inter-song delay to error
- Added: `cast_started_at` timeout resets a stuck `casting` flag after 60 seconds
- Added: Periodic safety-net check via `prerender` every ~60 seconds
- Added: 10-second post-cast cooldown per song to prevent "Unable to cast" errors after interruptions

### 1.0.0
- Initial release: BRD 2-song upkeep with reactive buff tracking and coroutine-based cast sequencing

---

## Known Issues

- Song names must be spelled and capitalised exactly as they appear in-game (e.g. `Blade Madrigal`, not `blade madrigal`). Use `//ha status` to verify a song was found in resources.
- If the BRD is silenced, the addon will continuously attempt to cast until silence is removed. Silence detection will be addressed in a future milestone.
- `song_count` must currently be set by editing `data/settings.xml` directly. A runtime command will be added in Milestone 3.
