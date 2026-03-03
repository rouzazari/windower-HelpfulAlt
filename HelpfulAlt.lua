--[[
    HelpfulAlt — Autonomous support addon for a secondary FFXI account.
    Milestone 3: Party healing. Monitors party HP% and casts a configurable
    cure spell on members below the threshold. Healing takes priority over
    song upkeep; both share the same casting lock.

    Commands:
        //ha on                     — enable all automation
        //ha off                    — disable all automation
        //ha status                 — show songs, heal settings, and cast state
        //ha song <1|2> <name>      — change a song slot
        //ha recast                 — show recast timers for configured songs
        //ha heal on|off            — toggle healing independently
        //ha threshold <1-99>       — set HP% threshold for curing
        //ha cure <spell name>      — set which cure spell to use
]]

_addon.name     = 'HelpfulAlt'
_addon.version  = '3.0.0'
_addon.author   = 'User'
_addon.commands = {'helpfulalt', 'ha'}

config   = require('config')
res      = require('resources')
require('logger')

-- ─────────────────────────────────────────────────────────
-- Default settings (written to data/settings.xml on first load)
-- ─────────────────────────────────────────────────────────
local defaults = {
    -- Song upkeep
    enabled       = true,
    song1         = 'Blade Madrigal',
    song2         = 'Victory March',
    song_count    = 2,
    song_duration = 110,
    -- Party healing
    heal_enabled  = true,
    heal_threshold = 80,   -- cure when party member hpp < this value
    cure_spell    = 'Cure IV',
}

-- ─────────────────────────────────────────────────────────
-- Runtime state
-- ─────────────────────────────────────────────────────────
local settings              -- loaded config
-- Maps every spell name → {spell_id, buff_id}; used for songs and cure spells.
local spell_lookup = {}
local active_songs = {}     -- [buff_id] = true  (only tracked song buff IDs)
local last_cast    = {}     -- [spell_name] = os.time() of most recent cast attempt
local casting         = false  -- true while a /ma has been issued and not yet resolved
local cast_started_at = 0      -- os.time() when casting was last set to true
local poll_tick       = 0      -- prerender counter for song/sync checks (~5s and ~60s)
local heal_tick       = 0      -- prerender counter for party HP check (~1s)
local cure_spell_id   = nil    -- resolved spell_id for the configured cure spell

-- Player status constants
local STATUS_IDLE     = 0
local STATUS_ENGAGED  = 1
local STATUS_DEAD     = 3
local STATUS_ZONING   = 4

-- Party slot keys in priority order (p0 = self, p1..p5 = others).
local PARTY_KEYS = {'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}

-- Minimum seconds before retrying after a /ma (covers interruption lockout).
local MIN_RECAST_WAIT = 10

-- ─────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────

local function log(msg)
    windower.add_to_chat(207, '[HelpfulAlt] ' .. tostring(msg))
end

local function player_status()
    local p = windower.ffxi.get_player()
    return p and p.status
end

local function is_safe_to_cast()
    local s = player_status()
    return s == STATUS_IDLE or s == STATUS_ENGAGED
end

-- Coerce numeric/bool settings after config.load (XML may load them as strings).
local function coerce_settings()
    settings.song_count     = tonumber(settings.song_count)     or defaults.song_count
    settings.song_duration  = tonumber(settings.song_duration)  or defaults.song_duration
    settings.heal_threshold = tonumber(settings.heal_threshold) or defaults.heal_threshold
end

-- ─────────────────────────────────────────────────────────
-- Spell resource lookup
-- ─────────────────────────────────────────────────────────

local function build_spell_lookup()
    spell_lookup = {}
    for id, spell in pairs(res.spells) do
        local name = spell.en
        if name then
            spell_lookup[name] = {
                spell_id = id,
                buff_id  = spell.status,
            }
        end
    end
end

-- Returns spell_id and buff_id for a spell name, or nil, nil.
local function get_spell_data(name)
    local d = spell_lookup[name]
    if not d then return nil, nil end
    return d.spell_id, d.buff_id
end

-- Resolve the cure spell_id from the current settings.
local function build_cure_lookup()
    if not settings then return end
    local sid = get_spell_data(settings.cure_spell)
    cure_spell_id = sid
    if not cure_spell_id then
        log('Warning: cure spell "' .. tostring(settings.cure_spell) .. '" not found in resources.')
    end
end

-- ─────────────────────────────────────────────────────────
-- Song tracking
-- ─────────────────────────────────────────────────────────

local function slot_name(i)
    return settings['song' .. i]
end

-- Build a reverse map: buff_id → slot index (configured songs only).
local function build_buff_map()
    local m = {}
    for i = 1, settings.song_count do
        local name = slot_name(i)
        if name then
            local _, buff_id = get_spell_data(name)
            if buff_id and buff_id ~= 0 then
                m[buff_id] = i
            end
        end
    end
    return m
end

-- Sync active_songs from the player's live buff list.
local function sync_active_songs()
    active_songs = {}
    local p = windower.ffxi.get_player()
    if not p then return end
    local buff_map = build_buff_map()
    for _, buff_id in ipairs(p.buffs) do
        if buff_map[buff_id] then
            active_songs[buff_id] = true
        end
    end
end

-- Determine whether a song slot currently needs to be cast.
local function slot_needs_cast(i)
    local name = slot_name(i)
    if not name or name == '' then return false end

    local spell_id, buff_id = get_spell_data(name)
    if not spell_id then return false end

    local t = last_cast[name]
    if t and (os.time() - t) < MIN_RECAST_WAIT then return false end

    if buff_id and buff_id ~= 0 then
        return not active_songs[buff_id]
    else
        if not t then return true end
        return (os.time() - t) >= settings.song_duration
    end
end

-- ─────────────────────────────────────────────────────────
-- Cast logic — healing
-- ─────────────────────────────────────────────────────────

-- Find the party member with the lowest hpp below the threshold who is in
-- the current zone, and cast the configured cure spell on them.
local function upkeep_heal()
    if not settings or not settings.heal_enabled then return end
    if casting then return end
    if not is_safe_to_cast() then return end
    if not cure_spell_id then return end

    -- Check cure spell recast.
    local ticks = windower.ffxi.get_spell_recasts()[cure_spell_id] or 0
    if ticks > 0 then return end

    local party = windower.ffxi.get_party()
    if not party then return end

    local threshold = settings.heal_threshold
    local target_key = nil
    local lowest_hpp = threshold  -- only cure members strictly below threshold

    for _, key in ipairs(PARTY_KEYS) do
        local member = party[key]
        -- member.mob exists only when the member is in the same zone.
        if member and member.mob and member.hpp > 0 and member.hpp < lowest_hpp then
            lowest_hpp  = member.hpp
            target_key  = key
        end
    end

    if not target_key then return end

    local member = party[target_key]
    log(('Curing %s (%d%% HP) with %s'):format(
        member.name, member.hpp, settings.cure_spell))
    windower.chat.input('/ma "' .. settings.cure_spell .. '" <' .. target_key .. '>')
    casting         = true
    cast_started_at = os.time()
end

-- ─────────────────────────────────────────────────────────
-- Cast logic — songs
-- ─────────────────────────────────────────────────────────

-- Scan all song slots and cast the first missing, ready one.
local function upkeep_songs()
    if not settings or not settings.enabled then return end
    if casting then return end
    if not is_safe_to_cast() then return end

    for i = 1, settings.song_count do
        if slot_needs_cast(i) then
            local name     = slot_name(i)
            local spell_id = get_spell_data(name)

            local ticks = windower.ffxi.get_spell_recasts()[spell_id] or 0
            if ticks == 0 then
                log('Casting ' .. name)
                windower.chat.input('/ma "' .. name .. '" <me>')
                last_cast[name]  = os.time()
                casting          = true
                cast_started_at  = os.time()
                return
            end
        end
    end
end

-- Unified upkeep: healing takes priority over song maintenance.
local function upkeep()
    upkeep_heal()
    if not casting then
        upkeep_songs()
    end
end

-- ─────────────────────────────────────────────────────────
-- Action packet handler (incoming 0x028)
--
-- Category 4 (spell finish): act.param = spell_id
-- Category 8 (cast begin/interrupt): act.param = 24931 (start) or
--   28787 (interrupt); act.targets[1].actions[1].param = spell_id
-- ─────────────────────────────────────────────────────────

windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x028 then return end
    if not settings then return end

    local act = windower.packets.parse_action(data)
    local p   = windower.ffxi.get_player()
    if not p or act.actor_id ~= p.id then return end

    if act.category == 8 then
        if act.param == 28787 then
            casting = false
            log('Cast interrupted. Will retry in ' .. MIN_RECAST_WAIT .. 's.')
            coroutine.wrap(function()
                coroutine.sleep(MIN_RECAST_WAIT + 2)
                upkeep()
            end)()
        end

    elseif act.category == 4 then
        if casting then
            -- Update active_songs immediately for song completions.
            local completed_spell_id = act.param
            for i = 1, settings.song_count do
                local name = slot_name(i)
                if name then
                    local sid, bid = get_spell_data(name)
                    if sid == completed_spell_id and bid and bid ~= 0 then
                        if act.targets and act.targets[1] and act.targets[1].id == p.id then
                            active_songs[bid] = true
                        end
                        break
                    end
                end
            end
            casting = false
            coroutine.wrap(function()
                coroutine.sleep(1)
                upkeep()
            end)()
        end
    end
end)

-- ─────────────────────────────────────────────────────────
-- Events
-- ─────────────────────────────────────────────────────────

windower.register_event('load', function()
    settings = config.load(defaults)
    coerce_settings()
    build_spell_lookup()
    build_cure_lookup()
    sync_active_songs()
    log(('Loaded v%s. Songs: %s | %s   Heal: %s (threshold %d%%, %s)'):format(
        _addon.version,
        slot_name(1) or '(none)',
        slot_name(2) or '(none)',
        tostring(settings.heal_enabled),
        settings.heal_threshold,
        settings.cure_spell
    ))
    if settings.enabled then
        coroutine.wrap(function()
            coroutine.sleep(1)
            upkeep()
        end)()
    end
end)

windower.register_event('unload', function()
    settings:save('all')
end)

windower.register_event('login', function()
    build_spell_lookup()
    build_cure_lookup()
    sync_active_songs()
    if settings and settings.enabled then
        coroutine.wrap(function()
            coroutine.sleep(2)
            upkeep()
        end)()
    end
end)

windower.register_event('gain buff', function(buff_id)
    if not settings then return end
    local buff_map = build_buff_map()
    if buff_map[buff_id] then
        active_songs[buff_id] = true
    end
end)

windower.register_event('lose buff', function(buff_id)
    if not settings then return end
    local buff_map = build_buff_map()
    if buff_map[buff_id] then
        active_songs[buff_id] = nil
        local slot = buff_map[buff_id]
        log(('Song slot %d ("%s") fell off - recasting.'):format(slot, slot_name(slot) or '?'))
        upkeep()
    end
end)

windower.register_event('zone change', function()
    active_songs = {}
    last_cast    = {}
    casting      = false
end)

windower.register_event('status change', function(new_status)
    if not settings then return end
    if new_status == STATUS_DEAD or new_status == STATUS_ZONING then
        active_songs = {}
        casting      = false
    elseif new_status == STATUS_IDLE or new_status == STATUS_ENGAGED then
        coroutine.wrap(function()
            coroutine.sleep(1)
            sync_active_songs()
            upkeep()
        end)()
    end
end)

-- Periodic checks via prerender:
--   Every ~1s  — party HP check for healing.
--   Every ~5s  — song recast polling.
--   Every ~60s — full buff sync.
windower.register_event('prerender', function()
    if not settings then return end

    -- Healing check: ~1s regardless of enabled flag (heal_enabled controls it internally).
    heal_tick = heal_tick + 1
    if heal_tick >= 60 then
        heal_tick = 0
        upkeep_heal()
    end

    if not settings.enabled then return end

    poll_tick = poll_tick + 1
    if poll_tick >= 3600 then  -- ~60s
        poll_tick = 0
        if casting and (os.time() - cast_started_at) > 60 then
            log('Cast timed out - resetting.')
            casting = false
        end
        sync_active_songs()
        upkeep_songs()
    elseif poll_tick % 300 == 0 then  -- ~5s
        if casting and (os.time() - cast_started_at) > 30 then
            log('Cast timed out - resetting.')
            casting = false
        end
        upkeep_songs()
    end
end)

-- ─────────────────────────────────────────────────────────
-- Addon commands  (//ha <command> [args])
-- ─────────────────────────────────────────────────────────

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'help'):lower()
    local args = {...}

    -- ── on / off ──────────────────────────────────────────
    if cmd == 'on' then
        settings.enabled = true
        settings:save('all')
        log('Enabled.')
        sync_active_songs()
        upkeep()

    elseif cmd == 'off' then
        settings.enabled = false
        settings:save('all')
        log('Disabled.')

    -- ── heal on / off ─────────────────────────────────────
    elseif cmd == 'heal' then
        local sub = args[1] and args[1]:lower()
        if sub == 'on' then
            settings.heal_enabled = true
            settings:save('all')
            log('Healing enabled.')
        elseif sub == 'off' then
            settings.heal_enabled = false
            settings:save('all')
            log('Healing disabled.')
        else
            log('Usage: //ha heal on|off')
        end

    -- ── threshold <pct> ───────────────────────────────────
    elseif cmd == 'threshold' then
        local pct = tonumber(args[1])
        if not pct or pct < 1 or pct > 99 then
            log('Usage: //ha threshold <1-99>')
            return
        end
        settings.heal_threshold = pct
        settings:save('all')
        log(('Heal threshold set to %d%%.'):format(pct))

    -- ── cure <spell name> ─────────────────────────────────
    elseif cmd == 'cure' then
        local name = table.concat(args, ' ', 1)
        if name == '' then
            log('Usage: //ha cure <Spell Name>')
            return
        end
        local spell_id = get_spell_data(name)
        if not spell_id then
            log(('Unknown spell: "%s" - check spelling and capitalisation.'):format(name))
            return
        end
        settings.cure_spell = name
        settings:save('all')
        build_cure_lookup()
        log(('Cure spell set to: %s'):format(name))

    -- ── status ────────────────────────────────────────────
    elseif cmd == 'status' then
        log(('Enabled: %s   Casting lock: %s'):format(
            tostring(settings.enabled), tostring(casting)))
        log(('Heal: %s   Threshold: %d%%   Cure: %s%s'):format(
            tostring(settings.heal_enabled),
            settings.heal_threshold,
            settings.cure_spell,
            cure_spell_id and '' or ' (!! not found in resources)'
        ))
        for i = 1, settings.song_count do
            local name               = slot_name(i) or '(none)'
            local spell_id, buff_id  = get_spell_data(name)
            local has_buff_tracking  = buff_id and buff_id ~= 0
            local active
            if has_buff_tracking then
                active = active_songs[buff_id] and 'ACTIVE' or 'MISSING'
            else
                local t = last_cast[name]
                if not t then
                    active = 'MISSING (no buff tracking)'
                elseif (os.time() - t) >= settings.song_duration then
                    active = 'EXPIRED (no buff tracking)'
                else
                    active = ('CAST ~%ds ago (no buff tracking)'):format(os.time() - t)
                end
            end
            log(('  [%d] %-24s  %s%s'):format(
                i, name, active,
                spell_id and '' or '  !! spell not found in resources'
            ))
        end

    -- ── recast ────────────────────────────────────────────
    elseif cmd == 'recast' then
        local recasts = windower.ffxi.get_spell_recasts()
        for i = 1, settings.song_count do
            local name     = slot_name(i) or '(none)'
            local spell_id = get_spell_data(name)
            if spell_id then
                local ticks = recasts[spell_id] or 0
                local secs  = math.ceil(ticks / 60)
                log(('  [%d] %-24s  %s'):format(
                    i, name, secs > 0 and (secs .. 's remaining') or 'Ready'))
            else
                log(('  [%d] %-24s  (spell not found in resources)'):format(i, name))
            end
        end

    -- ── song <slot> <name> ────────────────────────────────
    elseif cmd == 'song' then
        local slot = tonumber(args[1])
        local name = table.concat(args, ' ', 2)

        if not slot or slot < 1 or slot > settings.song_count or name == '' then
            log('Usage: //ha song <1|2> <Song Name>')
            return
        end

        local spell_id = get_spell_data(name)
        if not spell_id then
            log(('Unknown song: "%s" - check spelling and capitalisation.'):format(name))
            return
        end

        settings['song' .. slot] = name
        settings:save('all')
        sync_active_songs()
        log(('Slot %d set to: %s'):format(slot, name))
        upkeep()

    -- ── help / fallthrough ────────────────────────────────
    else
        log('Commands:  on | off | status | recast | song <1|2> <name>')
        log('           heal on|off | threshold <1-99> | cure <spell name>')
    end
end)
