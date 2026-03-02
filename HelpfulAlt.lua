--[[
    HelpfulAlt — Autonomous support addon for a secondary FFXI account.
    Milestone 2: Cast tracking via action packets (0x028). Spells are
    sequenced by actual completion/interruption events rather than a timed
    delay, fixing the two-song initial-cast bug and eliminating coroutine
    errors from XML-string config values.

    Commands:
        //ha on                     — enable automation
        //ha off                    — disable automation
        //ha status                 — show current song state
        //ha song <1|2> <name>      — change a configured song slot
        //ha recast                 — show song recast timers
]]

_addon.name     = 'HelpfulAlt'
_addon.version  = '2.0.0'
_addon.author   = 'User'
_addon.commands = {'helpfulalt', 'ha'}

config   = require('config')
res      = require('resources')
require('logger')

-- ─────────────────────────────────────────────────────────
-- Default settings (written to data/settings.xml on first load)
-- ─────────────────────────────────────────────────────────
local defaults = {
    enabled       = true,
    song1         = 'Blade Madrigal',
    song2         = 'Victory March',
    song_count    = 2,
    -- Re-cast a song after this many seconds if no buff ID is available.
    song_duration = 110,
}

-- ─────────────────────────────────────────────────────────
-- Runtime state
-- ─────────────────────────────────────────────────────────
local settings            -- loaded config
local song_lookup  = {}   -- [spell_name] = {spell_id=N, buff_id=N}
local active_songs = {}   -- [buff_id] = true  (only tracked song buff IDs)
local last_cast    = {}   -- [spell_name] = os.time() of most recent cast attempt
local casting         = false  -- true while a /ma has been issued and not yet resolved
local cast_started_at = 0      -- os.time() when casting was last set to true
local poll_tick       = 0      -- prerender counter for periodic checks

-- Player status constants
local STATUS_IDLE     = 0
local STATUS_ENGAGED  = 1
local STATUS_DEAD     = 3
local STATUS_ZONING   = 4

-- Minimum seconds before retrying after a /ma is issued (handles interruptions).
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

-- Coerce numeric settings after config.load (XML may load them as strings).
local function coerce_settings()
    settings.song_count    = tonumber(settings.song_count)    or defaults.song_count
    settings.song_duration = tonumber(settings.song_duration) or defaults.song_duration
end

-- ─────────────────────────────────────────────────────────
-- Spell resource lookup
-- ─────────────────────────────────────────────────────────

local function build_song_lookup()
    song_lookup = {}
    for id, spell in pairs(res.spells) do
        local name = spell.en
        if name then
            song_lookup[name] = {
                spell_id = id,
                buff_id  = spell.status,  -- may be nil or 0 for some spells
            }
        end
    end
end

-- Returns spell_id and buff_id for a song name, or nil, nil.
local function get_song_data(name)
    local d = song_lookup[name]
    if not d then return nil, nil end
    return d.spell_id, d.buff_id
end

-- ─────────────────────────────────────────────────────────
-- Song tracking
-- ─────────────────────────────────────────────────────────

local function slot_name(i)
    return settings['song' .. i]
end

-- Build a reverse map: buff_id → slot index.
-- Only includes slots whose buff_id is known and non-zero.
local function build_buff_map()
    local m = {}
    for i = 1, settings.song_count do
        local name = slot_name(i)
        if name then
            local _, buff_id = get_song_data(name)
            if buff_id and buff_id ~= 0 then
                m[buff_id] = i
            end
        end
    end
    return m
end

-- Sync active_songs from the player's live buff list.
-- Only stores buff IDs that belong to configured songs.
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

    local spell_id, buff_id = get_song_data(name)
    if not spell_id then return false end  -- spell name not in resources

    -- Cooldown: don't retry too soon after the last cast attempt
    local t = last_cast[name]
    if t and (os.time() - t) < MIN_RECAST_WAIT then return false end

    if buff_id and buff_id ~= 0 then
        return not active_songs[buff_id]
    else
        -- No buff tracking; use time-based fallback
        if not t then return true end
        return (os.time() - t) >= settings.song_duration
    end
end

-- ─────────────────────────────────────────────────────────
-- Cast logic
-- ─────────────────────────────────────────────────────────

-- Scan all slots and cast the first missing, ready song.
-- Issues only ONE /ma at a time. The action packet handler (below) calls
-- this again after each spell completes to continue the sequence.
local function upkeep_songs()
    if not settings or not settings.enabled then return end
    if casting then return end
    if not is_safe_to_cast() then return end

    for i = 1, settings.song_count do
        if slot_needs_cast(i) then
            local name     = slot_name(i)
            local spell_id = get_song_data(name)

            -- If the spell is still on recast, skip to the next slot.
            -- The prerender quick-check will retry when it clears.
            local ticks = windower.ffxi.get_spell_recasts()[spell_id] or 0
            if ticks == 0 then
                log('Casting ' .. name)
                windower.chat.input('/ma "' .. name .. '" <me>')
                last_cast[name]  = os.time()
                casting          = true
                cast_started_at  = os.time()
                return  -- One cast at a time; action packet drives the next
            end
        end
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
    if not settings or not settings.enabled then return end

    local act = windower.packets.parse_action(data)
    local p   = windower.ffxi.get_player()
    if not p or act.actor_id ~= p.id then return end

    -- Category 8: spell cast initiated or interrupted
    if act.category == 8 then
        if act.param == 28787 then
            -- Our cast was interrupted. Clear the flag and schedule a retry
            -- after MIN_RECAST_WAIT so we don't immediately hit the lockout.
            casting = false
            log('Cast interrupted. Will retry in ' .. MIN_RECAST_WAIT .. 's.')
            coroutine.wrap(function()
                coroutine.sleep(MIN_RECAST_WAIT + 2)
                upkeep_songs()
            end)()
        end
        -- param == 24931 means the cast started; casting flag stays true.

    -- Category 4: spell cast completed
    elseif act.category == 4 then
        -- Any spell completion from us while casting = true means our cast
        -- finished. Update active_songs immediately (gain buff fires shortly
        -- after, but this keeps state tight).
        if casting then
            local completed_spell_id = act.param
            for i = 1, settings.song_count do
                local name = slot_name(i)
                if name then
                    local sid, bid = get_song_data(name)
                    if sid == completed_spell_id and bid and bid ~= 0 then
                        if act.targets and act.targets[1] and act.targets[1].id == p.id then
                            active_songs[bid] = true
                        end
                        break
                    end
                end
            end
            casting = false
            -- Brief pause, then check whether more songs still need casting.
            coroutine.wrap(function()
                coroutine.sleep(1)
                upkeep_songs()
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
    build_song_lookup()
    sync_active_songs()
    log(('Loaded v%s. Enabled: %s | %s / %s'):format(
        _addon.version,
        tostring(settings.enabled),
        slot_name(1) or '(none)',
        slot_name(2) or '(none)'
    ))
    if settings.enabled then
        coroutine.wrap(function()
            coroutine.sleep(1)
            upkeep_songs()
        end)()
    end
end)

windower.register_event('unload', function()
    settings:save('all')
end)

windower.register_event('login', function()
    build_song_lookup()
    sync_active_songs()
    if settings and settings.enabled then
        coroutine.wrap(function()
            coroutine.sleep(2)
            upkeep_songs()
        end)()
    end
end)

-- React to gaining a buff: mark the matching song slot as active.
windower.register_event('gain buff', function(buff_id)
    if not settings then return end
    local buff_map = build_buff_map()
    if buff_map[buff_id] then
        active_songs[buff_id] = true
    end
end)

-- React to losing a buff: mark slot as gone and trigger re-cast.
windower.register_event('lose buff', function(buff_id)
    if not settings then return end
    local buff_map = build_buff_map()
    if buff_map[buff_id] then
        active_songs[buff_id] = nil
        local slot = buff_map[buff_id]
        log(('Song slot %d ("%s") fell off — recasting.'):format(slot, slot_name(slot) or '?'))
        upkeep_songs()
    end
end)

-- Zone change: all buffs are cleared server-side; reset tracking.
windower.register_event('zone change', function()
    active_songs = {}
    last_cast    = {}
    casting      = false
end)

-- Status change: pause on death/zoning; resume on idle/engaged.
windower.register_event('status change', function(new_status)
    if not settings then return end
    if new_status == STATUS_DEAD or new_status == STATUS_ZONING then
        active_songs = {}
        casting      = false
    elseif new_status == STATUS_IDLE or new_status == STATUS_ENGAGED then
        coroutine.wrap(function()
            coroutine.sleep(1)
            sync_active_songs()
            upkeep_songs()
        end)()
    end
end)

-- Periodic checks via prerender:
--   Every ~5s  — quick upkeep (catches spells waiting on recast to clear).
--   Every ~60s — full sync (catches any missed buff events).
--   Also resets a stuck casting flag if it's been true for over 30 seconds.
windower.register_event('prerender', function()
    if not settings or not settings.enabled then return end
    poll_tick = poll_tick + 1

    if poll_tick >= 3600 then  -- ~60s at 60 fps
        poll_tick = 0
        if casting and (os.time() - cast_started_at) > 60 then
            log('Cast timed out — resetting.')
            casting = false
        end
        sync_active_songs()
        upkeep_songs()
    elseif poll_tick % 300 == 0 then  -- ~5s
        if casting and (os.time() - cast_started_at) > 30 then
            log('Cast timed out — resetting.')
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
        upkeep_songs()

    elseif cmd == 'off' then
        settings.enabled = false
        settings:save('all')
        log('Disabled.')

    -- ── status ────────────────────────────────────────────
    elseif cmd == 'status' then
        log(('Enabled: %s   Casting lock: %s'):format(
            tostring(settings.enabled), tostring(casting)))
        for i = 1, settings.song_count do
            local name               = slot_name(i) or '(none)'
            local spell_id, buff_id  = get_song_data(name)
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
            local spell_id = get_song_data(name)
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

        local spell_id = get_song_data(name)
        if not spell_id then
            log(('Unknown song: "%s" — check spelling and capitalisation.'):format(name))
            return
        end

        settings['song' .. slot] = name
        settings:save('all')
        sync_active_songs()
        log(('Slot %d set to: %s'):format(slot, name))
        upkeep_songs()

    -- ── help / fallthrough ────────────────────────────────
    else
        log('Commands:  on | off | status | recast | song <1|2> <name>')
    end
end)
