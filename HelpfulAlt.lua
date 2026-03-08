--[[
    HelpfulAlt - Autonomous support addon for a secondary FFXI account.
    Milestone 4: Debuff removal. Tracks party member buffs via 0x076 packets
    and casts -na spells in priority order. Integrates with the shared casting
    lock used by healing and song upkeep.

    Commands:
        //ha on                     - enable all automation (songs)
        //ha off                    - disable all automation (songs)
        //ha status                 - show all states and settings
        //ha song <1|2> <name>      - change a song slot
        //ha recast                 - show recast timers for configured songs
        //ha heal on|off            - toggle healing independently
        //ha threshold <1-99>       - set HP% threshold for curing
        //ha cure <spell name>      - set which cure spell to use
        //ha debuff on|off          - toggle debuff removal independently
]]

_addon.name     = 'HelpfulAlt'
_addon.version  = '4.0.0'
_addon.author   = 'User'
_addon.commands = {'helpfulalt', 'ha'}

config   = require('config')
res      = require('resources')
require('logger')

-- ---------------------------------------------------------
-- Default settings (written to data/settings.xml on first load)
-- ---------------------------------------------------------
local defaults = {
    -- Song upkeep
    enabled        = true,
    song1          = 'Blade Madrigal',
    song2          = 'Victory March',
    song_count     = 2,
    song_duration  = 110,
    -- Party healing
    heal_enabled   = true,
    heal_threshold = 80,
    cure_spell     = 'Cure IV',
    -- Debuff removal
    debuff_enabled = true,
}

-- Debuff English name (lowercase) -> removal spell.
local DEBUFF_SPELLS = {
    doom          = 'Cursna',
    curse         = 'Cursna',
    petrification = 'Stona',
    paralysis     = 'Paralyna',
    plague        = 'Viruna',
    disease       = 'Viruna',
    silence       = 'Silena',
    blindness     = 'Blindna',
    poison        = 'Poisona',
}

-- Removal priority order (highest priority first).
local DEBUFF_PRIORITY_NAMES = {
    'doom', 'curse', 'petrification', 'paralysis',
    'plague', 'silence', 'blindness', 'poison', 'disease',
}

-- ---------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------
local settings              -- loaded config
local spell_lookup = {}     -- [name] = {spell_id, buff_id}
local active_songs = {}     -- [buff_id] = true  (tracked song buffs on self)
local last_cast    = {}     -- [spell_name] = os.time() of most recent cast attempt
local casting         = false  -- true while a /ma has been issued and not yet resolved
local cast_started_at = 0      -- os.time() when casting was last set to true
local poll_tick       = 0      -- prerender counter for song/sync checks
local heal_tick       = 0      -- prerender counter for party HP check (~1s)
local cure_spell_id   = nil    -- resolved spell_id for the configured cure spell
local party_debuffs   = {}     -- [mob_id] = {[buff_id] = true}; updated from 0x076
local debuff_id_map   = {}     -- [buff_id] = {name, spell_name}; built from res.buffs
local debuff_priority = {}     -- ordered list of {buff_id, name, spell_name}
local last_pos_x      = nil    -- last known x coordinate (movement detection)
local last_pos_z      = nil    -- last known z coordinate (movement detection)
local still_frames    = 0      -- frames since position last changed

-- Player status constants
local STATUS_IDLE     = 0
local STATUS_ENGAGED  = 1
local STATUS_DEAD     = 3
local STATUS_ZONING   = 4

-- Party slot keys in priority order (p0 = self, p1..p5 = others).
local PARTY_KEYS = {'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}

-- Minimum seconds before retrying after a /ma (covers interruption lockout).
local MIN_RECAST_WAIT = 10

-- Frames of unchanged position before the character is considered still (~0.25s at 60fps).
local STILL_THRESHOLD = 15

-- ---------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------

local function log(msg)
    windower.add_to_chat(207, '[HelpfulAlt] ' .. tostring(msg))
end

local function player_status()
    local p = windower.ffxi.get_player()
    return p and p.status
end

local function is_safe_to_cast()
    local s = player_status()
    if s ~= STATUS_IDLE and s ~= STATUS_ENGAGED then return false end
    return still_frames >= STILL_THRESHOLD
end

-- Coerce numeric/bool settings after config.load (XML may load them as strings).
local function coerce_settings()
    settings.song_count     = tonumber(settings.song_count)     or defaults.song_count
    settings.song_duration  = tonumber(settings.song_duration)  or defaults.song_duration
    settings.heal_threshold = tonumber(settings.heal_threshold) or defaults.heal_threshold
end

-- ---------------------------------------------------------
-- Spell resource lookup
-- ---------------------------------------------------------

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

-- Build debuff_id_map and debuff_priority by matching res.buffs against DEBUFF_SPELLS.
local function build_debuff_lookup()
    debuff_id_map = {}
    for id, buff in pairs(res.buffs) do
        local name = buff.english and buff.english:lower()
        if name and DEBUFF_SPELLS[name] then
            debuff_id_map[id] = {name = name, spell_name = DEBUFF_SPELLS[name]}
        end
    end
    debuff_priority = {}
    for _, dname in ipairs(DEBUFF_PRIORITY_NAMES) do
        for bid, entry in pairs(debuff_id_map) do
            if entry.name == dname then
                table.insert(debuff_priority, {
                    buff_id    = bid,
                    name       = dname,
                    spell_name = entry.spell_name,
                })
                break
            end
        end
    end
end

-- ---------------------------------------------------------
-- Song tracking
-- ---------------------------------------------------------

local function slot_name(i)
    return settings['song' .. i]
end

-- Build a reverse map: buff_id -> slot index (configured songs only).
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

-- ---------------------------------------------------------
-- Cast logic - healing
-- ---------------------------------------------------------

-- Find the party member with the lowest hpp below the threshold who is in
-- the current zone, and cast the configured cure spell on them.
local function upkeep_heal()
    if not settings or not settings.heal_enabled then return end
    if casting then return end
    if not is_safe_to_cast() then return end
    if not cure_spell_id then return end

    local ticks = windower.ffxi.get_spell_recasts()[cure_spell_id] or 0
    if ticks > 0 then return end

    local party = windower.ffxi.get_party()
    if not party then return end

    local threshold = settings.heal_threshold
    local target_key = nil
    local lowest_hpp = threshold

    for _, key in ipairs(PARTY_KEYS) do
        local member = party[key]
        -- member.mob exists only when the member is in the same zone.
        if member and member.mob and member.hpp > 0 and member.hpp < lowest_hpp then
            lowest_hpp = member.hpp
            target_key = key
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

-- ---------------------------------------------------------
-- Cast logic - debuff removal
-- ---------------------------------------------------------

-- Scan party members for tracked debuffs (populated via 0x076) and cast the
-- highest-priority removal spell that we know and have off recast.
local function upkeep_debuff()
    if not settings or not settings.debuff_enabled then return end
    if casting then return end
    if not is_safe_to_cast() then return end

    local party = windower.ffxi.get_party()
    if not party then return end
    local known_spells = windower.ffxi.get_spells()
    local recasts      = windower.ffxi.get_spell_recasts()

    for _, key in ipairs(PARTY_KEYS) do
        local member = party[key]
        if member and member.mob then
            local mob_id = member.mob.id
            local debuffs = party_debuffs[mob_id]
            if debuffs and next(debuffs) then
                for _, entry in ipairs(debuff_priority) do
                    if debuffs[entry.buff_id] then
                        local spell_id = get_spell_data(entry.spell_name)
                        if spell_id and known_spells[spell_id] then
                            local ticks = recasts[spell_id] or 0
                            if ticks == 0 then
                                log(('Curing %s (%s) with %s'):format(
                                    member.name, entry.name, entry.spell_name))
                                windower.chat.input('/ma "' .. entry.spell_name .. '" <' .. key .. '>')
                                casting         = true
                                cast_started_at = os.time()
                                return
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------
-- Cast logic - songs
-- ---------------------------------------------------------

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

-- Unified upkeep: healing > debuff removal > song maintenance.
local function upkeep()
    upkeep_heal()
    if not casting then upkeep_debuff() end
    if not casting then upkeep_songs() end
end

-- ---------------------------------------------------------
-- Incoming chunk handler (0x028 action packets, 0x076 party buffs)
-- ---------------------------------------------------------

windower.register_event('incoming chunk', function(id, data)
    -- 0x076: Party Buffs — fires whenever any party member's buffs change.
    -- Structure: 5 entries x 48 bytes, starting at data position 5.
    -- Entry layout: ID(4) Index(2) _unk(2) BitMask(8) Buffs(32)
    -- Buff ID = low_byte + 256 * ext_bits  (ext_bits = 2 bits from BitMask)
    if id == 0x076 then
        for i = 0, 4 do
            local b = i*48+5
            local mob_id = data:byte(b) + data:byte(b+1)*256 + data:byte(b+2)*65536 + data:byte(b+3)*16777216
            if mob_id == 0 then break end
            local debuffs = {}
            for n = 1, 32 do
                local low_byte = data:byte(i*48+5+16+n-1)
                local ext_bits = math.floor(
                    data:byte(i*48+5+8+math.floor((n-1)/4)) / (4^((n-1)%4))
                ) % 4
                local buff_id = low_byte + 256 * ext_bits
                if buff_id == 255 then break end
                if debuff_id_map[buff_id] then
                    debuffs[buff_id] = true
                end
            end
            party_debuffs[mob_id] = debuffs
        end
        if settings and not casting then
            coroutine.wrap(function()
                coroutine.sleep(0.5)
                upkeep_debuff()
            end)()
        end
        return
    end

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
                coroutine.sleep(2)
                upkeep()
            end)()
        end
    end
end)

-- ---------------------------------------------------------
-- Events
-- ---------------------------------------------------------

windower.register_event('load', function()
    settings = config.load(defaults)
    coerce_settings()
    build_spell_lookup()
    build_cure_lookup()
    build_debuff_lookup()
    sync_active_songs()
    log(('Loaded v%s. Songs: %s | %s   Heal: %s (%d%%, %s)   Debuff: %s'):format(
        _addon.version,
        slot_name(1) or '(none)',
        slot_name(2) or '(none)',
        tostring(settings.heal_enabled),
        settings.heal_threshold,
        settings.cure_spell,
        tostring(settings.debuff_enabled)
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
    build_debuff_lookup()
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
    active_songs  = {}
    last_cast     = {}
    casting       = false
    party_debuffs = {}
    last_pos_x    = nil
    last_pos_z    = nil
    still_frames  = 0
end)

windower.register_event('status change', function(new_status)
    if not settings then return end
    if new_status == STATUS_DEAD or new_status == STATUS_ZONING then
        active_songs  = {}
        casting       = false
        party_debuffs = {}
    elseif new_status == STATUS_IDLE or new_status == STATUS_ENGAGED then
        coroutine.wrap(function()
            coroutine.sleep(1)
            sync_active_songs()
            upkeep()
        end)()
    end
end)

-- Periodic checks via prerender:
--   Every ~1s  - party HP check for healing.
--   Every ~5s  - song recast polling + debuff check.
--   Every ~60s - full buff sync + upkeep.
windower.register_event('prerender', function()
    if not settings then return end

    -- Movement detection: compare position each frame; trigger upkeep the moment we stop.
    local me = windower.ffxi.get_mob_by_target('me')
    if me then
        local was_still = still_frames >= STILL_THRESHOLD
        if last_pos_x and (me.x ~= last_pos_x or me.z ~= last_pos_z) then
            still_frames = 0
        else
            still_frames = math.min(still_frames + 1, STILL_THRESHOLD)
        end
        last_pos_x = me.x
        last_pos_z = me.z
        -- Fire upkeep immediately when the character comes to a stop.
        if not was_still and still_frames >= STILL_THRESHOLD and not casting then
            upkeep()
        end
    end

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
        upkeep()
    elseif poll_tick % 300 == 0 then  -- ~5s
        if casting and (os.time() - cast_started_at) > 30 then
            log('Cast timed out - resetting.')
            casting = false
        end
        upkeep()
    end
end)

-- ---------------------------------------------------------
-- Addon commands  (//ha <command> [args])
-- ---------------------------------------------------------

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'help'):lower()
    local args = {...}

    -- on / off
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

    -- heal on / off
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

    -- debuff on / off
    elseif cmd == 'debuff' then
        local sub = args[1] and args[1]:lower()
        if sub == 'on' then
            settings.debuff_enabled = true
            settings:save('all')
            log('Debuff removal enabled.')
        elseif sub == 'off' then
            settings.debuff_enabled = false
            settings:save('all')
            log('Debuff removal disabled.')
        else
            log('Usage: //ha debuff on|off')
        end

    -- threshold <pct>
    elseif cmd == 'threshold' then
        local pct = tonumber(args[1])
        if not pct or pct < 1 or pct > 99 then
            log('Usage: //ha threshold <1-99>')
            return
        end
        settings.heal_threshold = pct
        settings:save('all')
        log(('Heal threshold set to %d%%.'):format(pct))

    -- cure <spell name>
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

    -- status
    elseif cmd == 'status' then
        log(('Enabled: %s   Casting lock: %s'):format(
            tostring(settings.enabled), tostring(casting)))
        log(('Heal: %s   Threshold: %d%%   Cure: %s%s'):format(
            tostring(settings.heal_enabled),
            settings.heal_threshold,
            settings.cure_spell,
            cure_spell_id and '' or ' (!! not found in resources)'
        ))
        log(('Debuff: %s   Tracking %d debuff types'):format(
            tostring(settings.debuff_enabled),
            #debuff_priority
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

    -- recast
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

    -- song <slot> <name>
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

    -- help / fallthrough
    else
        log('Commands:  on | off | status | recast | song <1|2> <name>')
        log('           heal on|off | threshold <1-99> | cure <spell name>')
        log('           debuff on|off')
    end
end)
