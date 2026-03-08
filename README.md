# HelpfulAlt

> A Windower 4 addon that autonomously controls a secondary FFXI account playing a healer or support role. Designed to keep your alt running hands-free while you focus on your main character.

**Version:** 4.1.0
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

HelpfulAlt starts fully enabled by default. On load it will immediately check whether your configured songs are active, whether any party members need healing, and whether any party members have removable debuffs.

Enable or disable all automation at any time:

    //ha on
    //ha off

Check current state:

    //ha status

---

## Commands

### Song upkeep

| Command | Description |
|---|---|
| `//ha on` | Enable all automation (songs + healing) |
| `//ha off` | Disable all automation |
| `//ha status` | Show song states, heal settings, and cast lock |
| `//ha recast` | Show recast timers for configured songs |
| `//ha song <1\|2> <name>` | Change a song slot at runtime (saves to config) |

### Party healing

| Command | Description |
|---|---|
| `//ha heal on` | Enable party healing |
| `//ha heal off` | Disable party healing |
| `//ha threshold <1-99>` | Set HP% at which to cure (default: 80) |
| `//ha cure <name>` | Set the cure spell to use (default: Cure IV) |

### Debuff removal

| Command | Description |
|---|---|
| `//ha debuff on` | Enable debuff removal |
| `//ha debuff off` | Disable debuff removal |

### Follow

| Command | Description |
|---|---|
| `//ha follow <name>` | Start following a named character, stopping within 10 yalms |
| `//ha follow off` | Disable following |
| `//ha followdist <yalms>` | Set the distance at which to stop following (default: 10) |

### Examples

    //ha song 1 Blade Madrigal
    //ha song 2 Victory March
    //ha status
    //ha recast
    //ha heal off
    //ha threshold 75
    //ha cure Cure V
    //ha debuff off
    //ha follow Yourname
    //ha followdist 8
    //ha follow off

Song and spell names are case-sensitive and must match the in-game spell name exactly.

---

## Configuration

Settings are saved automatically to `data/settings.xml` on first load. You can edit this file directly or use the runtime commands above.

### Song settings

| Setting | Default | Description |
|---|---|---|
| `enabled` | `true` | Whether song upkeep is active on load |
| `song1` | `Blade Madrigal` | Song in slot 1 (highest priority) |
| `song2` | `Victory March` | Song in slot 2 |
| `song_count` | `2` | Number of song slots to manage (1–2) |
| `song_duration` | `110` | Seconds before re-casting a song with no buff ID tracking |

### Healing settings

| Setting | Default | Description |
|---|---|---|
| `heal_enabled` | `true` | Whether party healing is active on load |
| `heal_threshold` | `80` | Cure a party member when their HP% falls below this value |
| `cure_spell` | `Cure IV` | Spell used to heal party members |

### Debuff settings

| Setting | Default | Description |
|---|---|---|
| `debuff_enabled` | `true` | Whether debuff removal is active on load |

### Follow settings

| Setting | Default | Description |
|---|---|---|
| `follow_enabled` | `false` | Whether following is active on load |
| `follow_target` | `` | Name of the character to follow |
| `follow_distance` | `10` | Yalm radius at which to stop following |

---

## How It Works

### Party healing

Every ~1 second the addon polls `get_party()` and looks for any in-zone party member with HP% below `heal_threshold`. The member with the lowest HP% is targeted first. When a cure is needed the addon issues one `/ma` command and waits for the action packet (category 4) to confirm completion before moving on. Healing takes priority over song upkeep — if someone needs a cure, songs wait.

### Song tracking

Each configured song is monitored using two complementary strategies:

- **Buff ID tracking (preferred):** The addon looks up the buff ID that the spell applies from Windower's spell resources. When a `gain buff` event fires with that ID, the song is marked active. When a `lose buff` event fires, the addon immediately attempts to re-cast.
- **Time-based fallback:** For songs where no buff ID is available in resources, the addon records the time of the last cast and re-casts after `song_duration` seconds.

A quick safety-net check runs every ~5 seconds (for recast polling) and a full buff sync runs every ~60 seconds, catching any missed events or edge cases.

### Debuff removal

The addon listens for the party buffs packet (0x076), which fires whenever any party member's buff list changes. When received, it decodes each member's full buff list (up to 32 slots, using a two-bit extension stored in a bitmask field for IDs above 255) and stores any recognized debuffs keyed by mob ID.

When `upkeep_debuff()` runs, it scans party members in order and checks their stored debuffs against the priority list: Doom > Curse > Petrification > Paralysis > Plague > Silence > Blindness > Poison > Disease. The first match where the removal spell is known (`get_spells()`) and off recast is cast immediately. Debuff removal takes priority over song upkeep but runs after healing.

### Cast sequencing

Only one spell is ever in flight at a time. After each spell completes, an incoming action packet (category 4) triggers the next cast automatically — first checking for party members who need healing, then checking for debuffs to remove, then checking for missing songs. If a spell is on recast, that slot is skipped; the periodic check resumes it once the recast clears.

### Interruption handling

The addon listens for action packet category 8 with param `28787` (cast interrupted). When detected, the `casting` lock is cleared and a retry is scheduled after 10 seconds, avoiding the "Unable to cast spells at this time" lockout. A `last_cast` timestamp also enforces a minimum 10-second window before any retry.

### Follow

Every ~2 seconds the addon checks the distance to the follow target using `get_mob_by_name()`. If the target is beyond `follow_distance` yalms, `/follow <name>` is issued. Once within range, the addon stops re-issuing `/follow`; FFXI's active follow keeps the alt near the target automatically. The follow check runs independently of `settings.enabled`; only `follow_enabled` controls it.

While the character is moving (following), the movement detection block keeps `still_frames` at zero, which blocks spell casting. When both characters are stationary, `still_frames` builds back up and casting resumes normally.

### Safety checks

The addon will not cast while the player is dead or zoning. It resumes automatically when returning to an idle or engaged state. Follow is also suppressed while dead or zoning.

---

## Roadmap

### ✅ Milestone 1 — BRD 2-Song Upkeep
Autonomous maintenance of two configurable songs. Reactive buff tracking with time-based fallback, interruption handling, and a periodic safety-net.

### ✅ Milestone 2 — Robustness & Action-Packet Sequencing
Cast sequencing driven by incoming action packets instead of a timed delay. Interruption detection via packet category. Faster recast polling. Fixed numeric config coercion bug that prevented the second song from casting.

### ✅ Milestone 3 — Party Healing
Monitor party HP% and cure members below a configurable threshold. Healing takes priority over song upkeep. Configurable cure spell and HP threshold.

### ✅ Milestone 4 — Debuff Removal
Track party member debuffs via 0x076 packets. Priority-ordered removal (Doom > Curse > Petrify > Paralysis > Plague > Silence > Blindness > Poison > Disease). Job-aware via `get_spells()`. Debuff removal runs between healing and song upkeep in the shared casting lock.

### ✅ Milestone 4.1 — Follow *(current)*
Keep Alt within a configurable yalm radius of a named character. Issues `/follow` every ~2s when beyond threshold; cancels via `setkey numpad2` when within range. Movement detection automatically suspends casting while following.

### Milestone 5 — 3 and 4 Song Support
- Expand `song_count` to support up to 4 slots (`song3`, `song4` config keys)
- `//ha song 3 <name>` / `//ha song 4 <name>` commands
- `//ha status` and `//ha recast` show all active slots

### Milestone 6 — MP Rest and Raise
- Monitor own MP% and enter `/heal` when it drops below a configurable floor
- Resume when MP recovers to a configurable ceiling
- Resting is suppressed while anyone needs healing, raising, or debuffing
- Detect KO'd party members and cast Raise (configurable spell)
- Priority stack: Raise > Heal > Debuff > Rest > Songs
- Commands: `//ha rest on/off`, `//ha mpfloor <pct>`, `//ha mpceil <pct>`, `//ha raise <spell>`

---

## Change Log

### 4.1.0
- Added: Follow feature - keeps Alt within a configurable yalm radius of a named character
- Added: `//ha follow <name>`, `//ha follow off`, `//ha followdist <yalms>` commands
- Added: `follow_enabled`, `follow_target`, `follow_distance` settings
- Added: `setkey numpad2` used to cancel `/follow` once within stop distance
- Added: Follow suppressed while dead or zoning; `is_following` flag reset on zone change
- Updated: `//ha status` shows follow state (enabled, target, distance, active flag)
- Updated: Movement detection naturally suppresses casting while the character is following

### 4.0.0
- Added: Debuff removal — tracks party member debuffs via 0x076 packet and casts -na spells in priority order (Doom > Curse > Petrification > Paralysis > Plague > Silence > Blindness > Poison > Disease)
- Added: Debuff removal respects the shared casting lock (healing > debuff > songs)
- Added: Job-aware spell selection via `windower.ffxi.get_spells()` — only attempts spells the character has learned
- Added: `//ha debuff on/off` command and `debuff_enabled` setting
- Updated: `//ha status` now shows debuff enabled state and tracked debuff count
- Updated: 0x076 handler triggers `upkeep_debuff()` immediately when party buffs change

### 3.0.0
- Added: Party healing — polls party HP% every ~1 second and casts a configurable cure spell when any in-zone member falls below the threshold
- Added: Healing takes priority over song upkeep; both share the same casting lock so only one spell is ever in flight
- Added: `//ha heal on/off`, `//ha threshold <pct>`, `//ha cure <spell name>` commands
- Added: `heal_enabled`, `heal_threshold`, `cure_spell` settings
- Updated: `//ha status` now shows heal settings alongside song status
- Updated: `//ha on/off` controls all automation; `//ha heal on/off` toggles healing independently

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

- Song and spell names must be spelled and capitalised exactly as they appear in-game (e.g. `Cure IV`, not `cure iv`). Use `//ha status` to verify a spell was found in resources.
- If the character is silenced, the addon will continuously attempt to cast songs until silence is removed. Silena is detected as a debuff and will be cast on affected party members, but self-silence is not yet handled specially.
- `song_count` must currently be set by editing `data/settings.xml` directly. A runtime command will be added in a future milestone.
- The cure and removal spells are not automatically filtered by current job level — the addon checks only whether the spell has been learned (`get_spells()`). If the current job cannot use a spell, the server will reject the cast and the interruption handler will clear the lock.
- Debuff tracking relies on 0x076 packets. The initial state is empty on load; debuffs are populated on the next buff change event for each party member.
