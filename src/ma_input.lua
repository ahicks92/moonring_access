-- ma_input.lua — the claim/realize input layer (Tanglebeep's InputDrainer
-- discipline).
--
-- CLAIM runs inside the wrapped keyboardHandler.fixedUpdate, right after the
-- game rebuilt its key dictionaries (and after dev-server key injection, so
-- synthesized test keys travel the same path as real ones). It only
-- recognizes and enqueues commands — no speech, no game calls. When the
-- overlay dispatcher owns the screen, the whole menu vocabulary (arrows,
-- wasd, return/kpenter/e, home/end) is eaten so the game's own widget never
-- sees it: one owner, one direction.
--
-- REALIZE (drain) happens from the frame pump, which feeds the commands to
-- the dispatcher and speaks the results.
--
-- Keys outside the game's allKeys scan (home/end, the numpad) get their own
-- edge detection here via love.keyboard.isDown.

local hooks = require("ma_hooks")

local st = hooks.state
st.input = st.input or { queue = {}, extra_prev = {} }
local I = st.input

local M = {}

-- Keys the game's keyboard handler never scans; we edge-detect them ourselves.
-- Numpad names are LOVE KeyConstants (numlock on).
local EXTRA_KEYS = {
    "home", "end", "pageup", "pagedown",
    "kp0", "kp1", "kp2", "kp3", "kp4", "kp5", "kp6", "kp7", "kp8", "kp9",
    "kp.", "kpenter",
}

-- Menu vocabulary while an overlay captures. The game maps IM_INPUT.up/down
-- to BOTH arrows and wasd, and confirm to return/kpenter/e — all of it must
-- be claimed or the game widget double-acts on the same press.
local DIR_KEYS = {
    up = { "up", "w" },
    down = { "down", "s" },
    left = { "left", "a" },
    right = { "right", "d" },
}
local CONFIRM_KEYS = { "return", "kpenter", "e" }

local function push(cmd)
    I.queue[#I.queue + 1] = cmd
end

local function eat(kb, key)
    kb.justPressedDictionary[key] = false
    kb.currentKeyPressDictionary[key] = nil
end

-- Edge-detect the extra keys; returns a set of just-pressed names this tick.
-- Unions in keys synthesized by the dev server (which never reach
-- love.keyboard.isDown).
local function poll_extra()
    local pressed = {}
    for _, k in ipairs(EXTRA_KEYS) do
        local ok, down = pcall(love.keyboard.isDown, k)
        down = ok and down or false
        if down and not I.extra_prev[k] then pressed[k] = true end
        I.extra_prev[k] = down
    end
    if I.injected then
        for _, k in ipairs(EXTRA_KEYS) do
            if I.injected[k] then pressed[k] = true end
        end
        I.injected = nil
    end
    return pressed
end

function M.claim(kb)
    local dispatcher = require("ma_dispatcher")
    local extra = poll_extra()

    local mods = {
        ctrl = (kb.currentKeyPressDictionary["lctrl"] or kb.currentKeyPressDictionary["rctrl"]) and true or false,
        shift = (kb.currentKeyPressDictionary["lshift"] or kb.currentKeyPressDictionary["rshift"]) and true or false,
        alt = (kb.currentKeyPressDictionary["lalt"] or kb.currentKeyPressDictionary["ralt"]) and true or false,
    }

    if dispatcher.engaged() then
        for dir, keys in pairs(DIR_KEYS) do
            local hit = false
            for _, k in ipairs(keys) do
                if kb.justPressedDictionary[k] then hit = true end
            end
            if hit then push({ kind = "move", dir = dir, mods = mods }) end
        end
        for _, k in ipairs(CONFIRM_KEYS) do
            if kb.justPressedDictionary[k] then
                push({ kind = "confirm", mods = mods })
                break
            end
        end
        if kb.justPressedDictionary["space"] then
            push({ kind = "read_info", mods = mods })
        end
        if extra["home"] then push({ kind = "move_to_edge", dir = "left", mods = mods }) end
        if extra["end"] then push({ kind = "move_to_edge", dir = "right", mods = mods }) end

        -- Eat the whole vocabulary unconditionally (held state included), so
        -- neither widget navigation nor movement auto-repeat ever sees it.
        for _, keys in pairs(DIR_KEYS) do
            for _, k in ipairs(keys) do eat(kb, k) end
        end
        for _, k in ipairs(CONFIRM_KEYS) do eat(kb, k) end
        eat(kb, "space")
    end

    -- Review buffers, any context: Ctrl+arrows (arrows only — Ctrl+WASD left
    -- alone). Up/down step lines, left/right switch buffers.
    if mods.ctrl then
        for _, arrow in ipairs({ "up", "down", "left", "right" }) do
            if kb.justPressedDictionary[arrow] then
                if arrow == "up" or arrow == "down" then
                    push({ kind = "app", action = "buffer_step", dir = arrow, mods = mods })
                else
                    push({ kind = "app", action = "buffer_switch", dir = arrow, mods = mods })
                end
            end
            -- Eat held state EVERY tick while Ctrl is down, not just on the
            -- press edge — otherwise the game's 10-tick auto-repeat sees the
            -- held arrow and walks the player.
            eat(kb, arrow)
        end
    end

    -- Gameplay announcer/status chords. Modifier chords are claimed whenever
    -- the game state is active (a held modifier never types); the bare H key
    -- only when nothing UI-ish would want the keypress.
    local gamestate_ok, gamestate = pcall(require, "library.gamestate")
    local in_game = gamestate_ok and G_stateGame ~= nil and gamestate.current() == G_stateGame

    if in_game then
        local CHORDS = {   -- ctrl+letter -> action
            h = "pois", x = "vitals", m = "money", p = "position",
            t = "turns", q = "modes", e = "echo_toggle", c = "character",
            f = "steps_toggle",
        }
        if mods.ctrl then
            for letter, action in pairs(CHORDS) do
                if kb.justPressedDictionary[letter] then
                    push({ kind = "app", action = action, mods = mods })
                end
                eat(kb, letter)   -- held state too (same auto-repeat leak)
            end
        elseif mods.alt then
            if kb.justPressedDictionary["h"] then
                push({ kind = "app", action = "terrain", mods = mods })
            end
            eat(kb, "h")
        elseif kb.justPressedDictionary["h"] and not dispatcher.engaged() then
            local blocked = false
            local ok, b = pcall(G_stateGame.isUIBlockingPlayerMovement, G_stateGame)
            if ok then blocked = b and true or false end
            if not blocked then
                push({ kind = "app", action = "hostiles", mods = mods })
                eat(kb, "h")
            end
        end

        -- Exploration cursor + scanner (gameplay only, never while an overlay
        -- or a game menu owns the screen).
        if not dispatcher.engaged() then
            local blocked = false
            local ok, b = pcall(G_stateGame.isUIBlockingPlayerMovement, G_stateGame)
            if ok then blocked = b and true or false end

            -- During the game's targeting modes the GAME owns the arrows
            -- (they move the aim cursor; ma_target voices it).
            local targeting = G_stateGame.isTargetingLocation or G_stateGame.isTargetingDirection

            if not blocked and not targeting and not mods.ctrl then
                -- Plain/Shift arrows: cursor step / skip. WASD stays player
                -- movement; arrows are the mod's (redundant for walking).
                for _, arrow in ipairs({ "up", "down", "left", "right" }) do
                    if kb.justPressedDictionary[arrow] then
                        push({ kind = "app", action = "cursor_step", dir = arrow,
                            skip = mods.shift, mods = mods })
                    end
                    eat(kb, arrow)   -- held state too, so movement never sees arrows
                end
            end

            -- Numpad ring (game never scans these).
            local NUMPAD_DIRS = { kp8 = "up", kp2 = "down", kp4 = "left", kp6 = "right" }
            for key, dir in pairs(NUMPAD_DIRS) do
                if extra[key] then
                    push({ kind = "app", action = "cursor_step", dir = dir,
                        skip = mods.shift, mods = mods })
                end
            end
            -- kp5: conversation status while talking, else cursor read.
            if extra["kp5"] then
                local talking = false
                pcall(function() talking = require("ma_talk").in_conversation() end)
                push({ kind = "app", action = talking and "talk_status" or "cursor_read", mods = mods })
            end
            if extra["kp0"] then push({ kind = "app", action = "cursor_recenter", mods = mods }) end

            -- Scanner: PageUp/Down entries, Ctrl+PageUp/Down categories,
            -- Home goto, End rescan.
            if extra["pageup"] then
                push({ kind = "app", action = mods.ctrl and "scan_cat" or "scan_entry",
                    dir = "up", mods = mods })
            end
            if extra["pagedown"] then
                push({ kind = "app", action = mods.ctrl and "scan_cat" or "scan_entry",
                    dir = "down", mods = mods })
            end
            if extra["home"] then push({ kind = "app", action = "scan_goto", mods = mods }) end
            if extra["end"] then push({ kind = "app", action = "scan_rescan", mods = mods }) end
        end
    end

    I.last_extra = extra
    I.last_mods = mods
end

-- Realize half: hand the queued commands to the pump, clearing the queue.
function M.drain()
    if #I.queue == 0 then return I.empty or {} end
    local q = I.queue
    I.queue = {}
    return q
end

return M
