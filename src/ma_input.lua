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
        if extra["home"] then push({ kind = "move_to_edge", dir = "left", mods = mods }) end
        if extra["end"] then push({ kind = "move_to_edge", dir = "right", mods = mods }) end

        -- Eat the whole vocabulary unconditionally (held state included), so
        -- neither widget navigation nor movement auto-repeat ever sees it.
        for _, keys in pairs(DIR_KEYS) do
            for _, k in ipairs(keys) do eat(kb, k) end
        end
        for _, k in ipairs(CONFIRM_KEYS) do eat(kb, k) end
    end

    -- Gameplay-context keys (exploration cursor, announcers) arrive in later
    -- phases; they will consume `extra` and mod chords here.
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
