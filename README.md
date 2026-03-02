# HelpfulAlt

> A Windower 4 addon that autonomously controls a secondary FFXI account playing a healer or support role. Designed to keep your alt running hands-free while you focus on your main character.

**Version:** 1.0.1
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
| `song_count` | `2` | Number of song slots to manage (1–2 in Milestone 1) |
| `cast_delay` | `4.5` | Seconds to wait between consecutive song casts |
| `song_duration` | `110` | Seconds before re-casting a song with no buff ID tracking |

---

## How It Works

### Song tracking

Each configured song is monitored using two complementary strategies:

- **Buff ID tracking (preferred):** The addon looks up the buff ID that the spell applies from Windower's spell resources. When a `gain buff` event fires with that ID, the song is marked active. When a `lose buff` event fires, the addon immediately attempts to re-cast.
- **Time-based fallback:** For songs where no buff ID is available in resources, the addon records the time of the last cast and re-casts after `song_duration` seconds.

A periodic safety-net check runs every ~60 seconds regardless of events, catching any missed buff events or edge cases.

### Cast sequencing

When one or more songs are missing, a coroutine casts them in slot priority order (slot 1 first). A `cast_delay` pause between consecutive casts prevents packet flooding. If a spell is on recast, the addon polls until it becomes available before casting.

### Interruption handling

After issuing a `/ma` command, the addon waits at least 10 seconds before retrying that song. This prevents the "Unable to cast spells at this time" error that occurs when a cast is interrupted and the game has a brief recovery lockout.

### Safety checks

The addon will not cast while the player is dead or zoning. It resumes automatically when returning to an idle or engaged state.

---

## Roadmap

### ✅ Milestone 1 — BRD 2-Song Upkeep *(current)*
Autonomous maintenance of two configurable songs. Reactive buff tracking with time-based fallback, interruption handling, and a periodic safety-net.

### Milestone 2 — Robustness & Extended Song Configuration
- Runtime song slot changes with full validation
- Improved interruption detection via action packets
- `//ha song` support for all slots

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
- If the BRD is silenced, the addon will continuously attempt to cast and poll recasts until silence is removed. Silence detection will be addressed in a future milestone.
- `song_count` must currently be set by editing `data/settings.xml` directly. A runtime command will be added in Milestone 3.
