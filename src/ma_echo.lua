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

-- Movement-relative echo (Shades-of-Doom lineage, per Austin):
--   * ONE forward ping, only in the direction just moved. North/south keep
--     their fifth-up/fifth-down pitch, centered. East/west pings PAN BY
--     PROXIMITY: hard-side while the wall is distant, sliding toward center
--     as it closes — centered means it is in your face.
--   * Side-width monitors: what a moving player actually wants is "did my
--     sides get wider or narrower". Sides are relative to heading (moving
--     west, south is your left). When a side's clearance CHANGES since the
--     last same-heading step, that side chirps: up = widened, down =
--     narrowed. A heading change resets the baseline silently (the axes no
--     longer compare).
function M.on_move(dx, dy)
    if not E.enabled then return end
    -- Only cardinal single steps carry heading; teleports/world swaps reset.
    if not dx or math.abs(dx) + math.abs(dy) ~= 1 then
        E.prev = nil
        return
    end
    local p = map.player()
    if not p or not p.position then return end
    local px, py = p.position.x, p.position.y

    -- Forward ping: fixed compass identities (west always left, east always
    -- right, north a rising pair, south a falling pair).
    local d = wall_distance(px, py, dx, dy)
    if d then
        local dir = dy < 0 and "north" or dy > 0 and "south"
            or dx < 0 and "west" or "east"
        synth.play_wall_forward(dir, d)
    end

    -- Side widths, perpendicular to heading. left = heading rotated CCW in
    -- screen coords: (dy, -dx); verified: moving west (-1,0) -> left (0,1) =
    -- south. Open beyond range counts as MAX_DIST + 1 so "wall came into
    -- range" and "wall left range" both register as changes.
    local lw = wall_distance(px, py, dy, -dx) or (MAX_DIST + 1)
    local rw = wall_distance(px, py, -dy, dx) or (MAX_DIST + 1)
    local heading = dx .. "," .. dy
    if E.prev and E.prev.heading == heading then
        if lw ~= E.prev.lw then synth.width_cue(-1, lw > E.prev.lw) end
        if rw ~= E.prev.rw then synth.width_cue(1, rw > E.prev.rw) end
    end
    E.prev = { heading = heading, lw = lw, rw = rw }
end

return M
