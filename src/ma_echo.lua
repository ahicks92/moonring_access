-- ma_echo.lua — wall echo, the primary spatial channel (port of Tanglebeep's
-- WallEcho/WallEchoCue design). On every player move: four cardinal rays out
-- to 8 tiles; each wall renders as a band-passed noise ping in ONE shared
-- stereo buffer.
--
-- Encoding (Tanglebeep-tuned): left/right walls share a base pitch (C4),
-- panned hard left/right with interaural delay; up/down walls are centered,
-- pitched a FIFTH up (north) / down (south) — an octave fell into a low-end
-- hole. Distance -> onset delay (35 ms/tile) and gain (-3 dB/tile), adjacent
-- = instant and full. Band-passed NOISE, not sine: decorrelated noise stays
-- separable where identical sines fuse into one center image.

local hooks = require("ma_hooks")
local map = require("ma_map")
local synth = require("ma_synth")

local st = hooks.state
st.echo = st.echo or { enabled = true }
local E = st.echo

local M = {}

local MAX_DIST = 8
local SEC_PER_TILE = 0.035
local BASE = 261.63                       -- C4 for east/west
local UP = BASE * math.pow(2, 7 / 12)     -- fifth up for north
local DOWN = BASE * math.pow(2, -7 / 12)  -- fifth down for south
local PING = 0.06

local RAYS = {
    { dx = 0, dy = -1, pan = 0, freq = UP },     -- north
    { dx = 0, dy = 1, pan = 0, freq = DOWN },    -- south
    { dx = -1, dy = 0, pan = -1, freq = BASE },  -- west
    { dx = 1, dy = 0, pan = 1, freq = BASE },    -- east
}

local function wall_distance(px, py, dx, dy)
    for d = 1, MAX_DIST do
        if map.blocked(px + dx * d, py + dy * d) then return d end
    end
    return nil
end

function M.toggle()
    E.enabled = not E.enabled
    return E.enabled
end

function M.enabled()
    return E.enabled
end

function M.on_move()
    if not E.enabled then return end
    local p = map.player()
    if not p or not p.position then return end
    local px, py = p.position.x, p.position.y

    local events = {}
    for _, ray in ipairs(RAYS) do
        local d = wall_distance(px, py, ray.dx, ray.dy)
        if d then
            events[#events + 1] = {
                kind = "noise",
                freq = ray.freq,
                q = 30,
                dur = PING,
                at = (d - 1) * SEC_PER_TILE,
                pan = ray.pan,
                vol = 0.45 * math.pow(10, -3 * (d - 1) / 20),
            }
        end
    end
    synth.play(events)
end

return M
