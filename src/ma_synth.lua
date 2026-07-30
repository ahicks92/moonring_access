-- ma_synth.lua — mod-authored audio cues, a faithful Lua port of Tanglebeep's
-- Core/Audio grain pipeline (GrainTimeline/PanLaw/AllpassFractionalDelay/
-- NoisePool/AdsrGrain/WallEchoCue+Synth).
--
-- The load-bearing subtleties, learned the hard way:
--   * DECORRELATION: the left and right wall pings draw DIFFERENT slices from
--     a shared pre-filtered noise pool. Two identical signals panned hard
--     left/right fuse into one phantom-center image; decorrelated noise stays
--     two sources. (A first draft used per-frequency deterministic noise —
--     identical ears — and the whole echo collapsed to mono.)
--   * RMS NORMALIZATION: a Q=30 bandpass passes a ~9 Hz sliver of white
--     noise's energy; pools are normalized to a target RMS so Q changes
--     timbre, not loudness.
--   * ITD: the far ear gets the signal |pan| * 0.7 ms later, as an integer
--     sample shift plus a first-order allpass for the fractional remainder.

local hooks = require("ma_hooks")
local st = hooks.state
st.synth = st.synth or { sources = {} }
local S = st.synth

local M = {}

local RATE = 44100

-- ==================== WallEchoCue constants (Tanglebeep) ====================
local WALL = {
    base_hz = 261.63,               -- C4, left/right walls
    vertical_semitones = 7,         -- fifth up = north, fifth down = south
    q = 30,
    ms_per_tile = 35,
    db_per_tile = -3,
    initial_volume = 0.8,
    horizontal_gain = 1.0,
    up_gain = 1.0,
    down_gain = 1.3,                -- lowest band reads quieter; boost by ear
    attack = 0.002, decay = 0.030, sustain = 0.060, release = 0.01,
    sustain_level = 0.8,
    target_rms = 0.3,
    pool_seconds = 2.0,
    warmup_samples = 128,
    noise_seed = 12345,
}
WALL.itd_ms = 0.7                   -- far-ear delay at |pan| = 1, milliseconds

local ALLPASS_FLUSH = 32            -- frames of ringout tail
local TUNING_FILE = "moonring_access_tuning.lua"

local function refresh_derived()
    WALL.tone_seconds = WALL.attack + WALL.decay + WALL.sustain + WALL.release
    WALL.up_hz = WALL.base_hz * math.pow(2, WALL.vertical_semitones / 12)
    WALL.down_hz = WALL.base_hz * math.pow(2, -WALL.vertical_semitones / 12)
end

-- Apply persisted tuning over the defaults (file survives restarts; the
-- in-memory override table survives /reload).
S.tuning = S.tuning or (function()
    local ok, chunk = pcall(love.filesystem.load, TUNING_FILE)
    if ok and chunk then
        local ok2, t = pcall(chunk)
        if ok2 and type(t) == "table" then return t end
    end
    return {}
end)()
for k, v in pairs(S.tuning) do WALL[k] = v end
refresh_derived()

-- Parameters exposed to the live tuning menu. Pool-shaping params invalidate
-- the noise pools on change.
local TUNABLE = {
    { key = "initial_volume", label = "Wall volume", min = 0.1, max = 2.0, step = 0.05 },
    { key = "itd_ms", label = "Ear delay milliseconds", min = 0, max = 2.5, step = 0.1 },
    { key = "ms_per_tile", label = "Delay per tile", min = 10, max = 100, step = 5 },
    { key = "db_per_tile", label = "Decibels per tile", min = -8, max = -1, step = 0.5 },
    { key = "q", label = "Tone purity Q", min = 5, max = 80, step = 5, pools = true },
    { key = "vertical_semitones", label = "Vertical interval semitones", min = 2, max = 12, step = 1, pools = true },
    { key = "down_gain", label = "South loudness", min = 0.5, max = 2.5, step = 0.1 },
    { key = "up_gain", label = "North loudness", min = 0.5, max = 2.5, step = 0.1 },
    { key = "horizontal_gain", label = "Side loudness", min = 0.5, max = 2.5, step = 0.1 },
}

function M.tuning_params() return TUNABLE end

function M.get_tuning(key) return WALL[key] end

function M.set_tuning(key, value)
    for _, p in ipairs(TUNABLE) do
        if p.key == key then
            value = math.max(p.min, math.min(p.max, value))
            WALL[key] = value
            S.tuning[key] = value
            refresh_derived()
            if p.pools then S.pools = {} end
            return value
        end
    end
end

function M.save_tuning()
    local parts = { "return {" }
    for k, v in pairs(S.tuning) do
        parts[#parts + 1] = string.format("  %s = %s,", k, tostring(v))
    end
    parts[#parts + 1] = "}"
    local ok = pcall(love.filesystem.write, TUNING_FILE, table.concat(parts, "\n"))
    return ok
end

-- Reference pattern for tuning by ear: equidistant side walls (the pan/ITD
-- acid test) plus a vertical pair.
function M.demo()
    M.play_walls({ left = 2, right = 2, up = 4, down = 4 })
end

-- ============================ DSP primitives ================================

-- RBJ bandpass (constant 0 dB peak gain), one sample at a time.
local function bandpass_new(freq, q)
    local w0 = 2 * math.pi * freq / RATE
    local alpha = math.sin(w0) / (2 * q)
    local b0, b2 = alpha, -alpha
    local a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
    local x1, x2, y1, y2 = 0, 0, 0, 0
    return function(x)
        local y = (b0 / a0) * x + (b2 / a0) * x2 - (a1 / a0) * y1 - (a2 / a0) * y2
        x2, x1 = x1, x
        y2, y1 = y1, y
        return y
    end
end

-- ADSR envelope value at time t (seconds); segments sum to the grain length.
local function adsr(t, a, d, s, r, sustain_level)
    if t < 0 then return 0 end
    if t < a then return t / a end
    t = t - a
    if t < d then return 1 + (sustain_level - 1) * (t / d) end
    t = t - d
    if t < s then return sustain_level end
    t = t - s
    if t < r then return sustain_level * (1 - t / r) end
    return 0
end

-- ============================ Noise pools ===================================
-- One pool per band: filter pool_seconds of white noise once (discarding the
-- filter's warm-up transient), RMS-normalize, then hand out successive
-- non-overlapping slices. The LCG state persists across refills so every
-- slice is a fresh draw.

local function pool_refill(pool)
    local n = math.floor(WALL.pool_seconds * RATE)
    local total = n + WALL.warmup_samples
    local bp = bandpass_new(pool.center, WALL.q)
    local seed = pool.seed
    local data = {}
    for i = 0, total - 1 do
        seed = (seed * 48271) % 2147483647
        data[i] = bp((seed / 2147483647) * 2 - 1)
    end
    pool.seed = seed
    -- Drop warmup, RMS-normalize the rest to the target.
    local out = {}
    local sum = 0
    for i = 0, n - 1 do
        local v = data[i + WALL.warmup_samples]
        out[i] = v
        sum = sum + v * v
    end
    local rms = math.sqrt(sum / n)
    if rms > 1e-9 then
        local scale = WALL.target_rms / rms
        for i = 0, n - 1 do out[i] = out[i] * scale end
    end
    pool.data = out
    pool.len = n
    pool.cursor = 0
end

local function pool_get(name, center)
    S.pools = S.pools or {}
    local pool = S.pools[name]
    if not pool then
        pool = { center = center, seed = WALL.noise_seed }
        pool_refill(pool)
        S.pools[name] = pool
    end
    return pool
end

-- Take a slice of `seconds`, advancing the cursor (a fresh draw every call).
local function pool_take(pool, seconds)
    local count = math.min(math.ceil(seconds * RATE), pool.len)
    if pool.cursor + count > pool.len then pool_refill(pool) end
    local slice = { data = pool.data, offset = pool.cursor, count = count }
    pool.cursor = pool.cursor + count
    return slice
end

-- ========================= Timeline rendering ===============================
-- placements: { grain = fn(i) -> sample for grain-local frame i,
--               frames = grain length, start = seconds, pan = -1..1,
--               gain = linear }

local function render_placements(placements)
    local total = 0
    for _, p in ipairs(placements) do
        local frames = math.floor(p.start * RATE) + p.frames
        if frames > total then total = frames end
    end
    if total == 0 then return nil end
    local max_itd = WALL.itd_ms / 1000
    local padding = math.ceil(max_itd * RATE) + ALLPASS_FLUSH
    local n = total + padding
    local left, right = {}, {}
    for i = 0, n - 1 do left[i] = 0; right[i] = 0 end

    for _, p in ipairs(placements) do
        local pan = math.max(-1, math.min(1, p.pan or 0))
        -- Constant-power pan law.
        local theta = (pan + 1) * math.pi / 4
        local lg = math.cos(theta) * (p.gain or 1)
        local rg = math.sin(theta) * (p.gain or 1)

        -- ITD split: integer shift + allpass fractional remainder, with the
        -- fraction held in [0.5, 1.5) so the allpass pole stays tame.
        local delay_samples = math.abs(pan) * max_itd * RATE
        local int_delay, ap_a, ap_x, ap_y = 0, nil, 0, 0
        if delay_samples >= 0.5 then
            int_delay = math.floor(delay_samples - 0.5)
            local frac = delay_samples - int_delay
            ap_a = (1 - frac) / (1 + frac)
        end
        local far_is_left = pan > 0
        local far_is_right = pan < 0

        local first = math.floor(p.start * RATE)
        for i = 0, p.frames - 1 do
            local s = p.grain(i)
            local fi = first + i
            if fi >= 0 and fi < n then
                if far_is_left or far_is_right then
                    local far = s
                    if ap_a then
                        far = ap_a * s + ap_x - ap_a * ap_y
                        ap_x, ap_y = s, far
                    end
                    local di = fi + int_delay
                    if far_is_left then
                        right[fi] = right[fi] + s * rg
                        if di < n then left[di] = left[di] + far * lg end
                    else
                        left[fi] = left[fi] + s * lg
                        if di < n then right[di] = right[di] + far * rg end
                    end
                else
                    left[fi] = left[fi] + s * lg
                    right[fi] = right[fi] + s * rg
                end
            end
        end
        -- Flush the allpass ringout into the far channel's tail.
        if ap_a then
            for k = 0, ALLPASS_FLUSH - 1 do
                local fi = first + p.frames + k + int_delay
                if fi >= n then break end
                local far = ap_a * 0 + ap_x - ap_a * ap_y
                ap_x, ap_y = 0, far
                if far_is_left then left[fi] = left[fi] + far * lg
                else right[fi] = right[fi] + far * rg end
            end
        end
    end

    local data = love.sound.newSoundData(n, RATE, 16, 2)
    for i = 0, n - 1 do
        data:setSample(i, 1, math.max(-1, math.min(1, left[i])))
        data:setSample(i, 2, math.max(-1, math.min(1, right[i])))
    end
    return data
end

local function play_data(data)
    if not data then return end
    local src = love.audio.newSource(data, "static")
    src:play()
    S.sources[#S.sources + 1] = src
end

-- ====================== Event API (simple cues) =============================
-- events: { {kind="tone"|"noise", freq, dur, at, pan, vol, q} ... } — tones
-- for the cursor/step cues, noise rendered through a throwaway slice.

local function event_placement(e)
    local dur = e.dur or 0.05
    local frames = math.floor(dur * RATE)
    local grain
    if e.kind == "noise" then
        local slice = pool_take(pool_get("adhoc" .. tostring(e.freq), e.freq or WALL.base_hz), dur)
        grain = function(i)
            local v = slice.data[slice.offset + i] or 0
            -- Simple attack/decay for ad-hoc noise (wall pings use ADSR).
            local t = i / frames
            return v * (i < 176 and i / 176 or (1 - t) * (1 - t)) / WALL.target_rms * 0.5
        end
    else
        local step = 2 * math.pi * (e.freq or 440) / RATE
        local attack = math.floor(0.004 * RATE)
        grain = function(i)
            local env = i < attack and i / attack or (1 - i / frames) * (1 - i / frames)
            return math.sin(i * step) * env
        end
    end
    return { grain = grain, frames = frames, start = e.at or 0,
        pan = e.pan or 0, gain = e.vol or 0.5 }
end

function M.render(events)
    if not events or #events == 0 then return nil end
    local placements = {}
    for _, e in ipairs(events) do placements[#placements + 1] = event_placement(e) end
    local ok, data = pcall(render_placements, placements)
    if not ok then
        require("ma_speech").log("synth render error: " .. tostring(data))
        return nil
    end
    return data
end

function M.play(events)
    local data = M.render(events)
    local ok, err = pcall(play_data, data)
    if not ok then require("ma_speech").log("synth play error: " .. tostring(err)) end
end

-- ========================= Wall echo (the port) =============================
-- distances: { left = tiles or nil, right = , up = , down = }.

local function wall_placement(dist, pool, pan, loudness)
    local slice = pool_take(pool, WALL.tone_seconds)
    local gain = WALL.initial_volume
        * math.pow(10, WALL.db_per_tile * math.max(0, dist - 1) / 20) * loudness
    local start = math.max(0, dist - 1) * WALL.ms_per_tile / 1000
    return {
        grain = function(i)
            local v = slice.data[slice.offset + i] or 0
            return v * adsr(i / RATE, WALL.attack, WALL.decay, WALL.sustain,
                WALL.release, WALL.sustain_level)
        end,
        frames = slice.count, start = start, pan = pan, gain = gain,
    }
end

-- One forward wall ping with an explicit pan (the movement-direction echo).
-- band: "base" (east/west pitch), "up", "down". Distance still drives onset
-- delay and gain by the same adjacent-referenced law.
function M.play_wall_forward(band, dist, pan)
    local ok, err = pcall(function()
        local pool
        if band == "up" then pool = pool_get("up", WALL.up_hz)
        elseif band == "down" then pool = pool_get("down", WALL.down_hz)
        else pool = pool_get("base", WALL.base_hz) end
        local loud = band == "down" and WALL.down_gain
            or band == "up" and WALL.up_gain or WALL.horizontal_gain
        local p = wall_placement(dist, pool, pan, loud)
        play_data(render_placements({ p }))
    end)
    if not ok then require("ma_speech").log("forward wall error: " .. tostring(err)) end
end

-- Side-width change cue: a two-tone chirp panned to that side. Wider = up
-- (520 -> 780 Hz), narrower = down. Deliberately plain first-pass sounds.
function M.width_cue(side, wider)
    local a, b = 520, 780
    if not wider then a, b = 780, 520 end
    local pan = side * 0.9
    M.play({
        { kind = "tone", freq = a, dur = 0.035, pan = pan, vol = 0.3 },
        { kind = "tone", freq = b, dur = 0.035, at = 0.04, pan = pan, vol = 0.3 },
    })
end

function M.play_walls(d)
    local ok, err = pcall(function()
        local placements = {}
        local base = pool_get("base", WALL.base_hz)
        if d.left then placements[#placements + 1] = wall_placement(d.left, base, -1, WALL.horizontal_gain) end
        if d.right then placements[#placements + 1] = wall_placement(d.right, base, 1, WALL.horizontal_gain) end
        if d.up then placements[#placements + 1] = wall_placement(d.up, pool_get("up", WALL.up_hz), 0, WALL.up_gain) end
        if d.down then placements[#placements + 1] = wall_placement(d.down, pool_get("down", WALL.down_hz), 0, WALL.down_gain) end
        if #placements == 0 then return end
        play_data(render_placements(placements))
    end)
    if not ok then require("ma_speech").log("wall echo error: " .. tostring(err)) end
end

-- ============================ Housekeeping ==================================

function M.prune()
    for i = #S.sources, 1, -1 do
        local src = S.sources[i]
        if not src:isPlaying() then table.remove(S.sources, i) end
    end
end

-- Dev introspection: per-channel energy of a render (pan verification).
function M.channel_energy(events)
    local data = M.render(events)
    if not data then return "render failed" end
    local l, r = 0, 0
    for i = 0, data:getSampleCount() - 1 do
        l = l + math.abs(data:getSample(i, 1))
        r = r + math.abs(data:getSample(i, 2))
    end
    return string.format("left=%.1f right=%.1f", l, r)
end

-- ======================= Named cues (unchanged API) =========================

-- Terrain-differentiated footstep cue (the game designed then abandoned
-- terrain steps; its puddle pitch-shift is commented out at actor.lua:6281).
local STEP_FAMILIES = {
    wood = { kind = "tone", freq = 170, dur = 0.035, vol = 0.22 },
    soft = { kind = "noise", freq = 420, q = 2, dur = 0.045, vol = 0.3 },
    stone = { kind = "tone", freq = 540, dur = 0.02, vol = 0.18 },
    water = { kind = "tone", freq = 640, dur = 0.03, vol = 0.22, second = { kind = "tone", freq = 920, dur = 0.03, at = 0.035, vol = 0.18 } },
    sand = { kind = "noise", freq = 300, q = 1.5, dur = 0.05, vol = 0.26 },
}

local ROOT_TO_FAMILY = {
    woodFloor = "wood", floorboards = "wood", tileSqueak = "wood", bridge = "wood",
    grass = "soft", bushes = "soft", fern = "soft", swamp = "soft", trees = "soft",
    dirt = "soft", mud = "soft",
    floor = "stone", stoneFloor = "stone", path = "stone", rock = "stone",
    hills = "stone", mountains = "stone",
    water = "water", puddle = "water", sea = "water", shallows = "water",
    sand = "sand", shore = "sand",
}

function M.step_cue(root)
    local fam = STEP_FAMILIES[ROOT_TO_FAMILY[root or ""] or "stone"]
    local events = { { kind = fam.kind, freq = fam.freq, q = fam.q, dur = fam.dur, vol = fam.vol } }
    if fam.second then events[#events + 1] = fam.second end
    M.play(events)
end

function M.cue(name)
    if name == "cursor_ground" then
        M.play({ { kind = "tone", freq = 880, dur = 0.03, vol = 0.25 } })
    elseif name == "cursor_wall" then
        M.play({ { kind = "tone", freq = 220, dur = 0.05, vol = 0.3 } })
    elseif name == "cursor_entity" then
        M.play({ { kind = "tone", freq = 880, dur = 0.03, vol = 0.25 },
                 { kind = "tone", freq = 1318.5, dur = 0.04, at = 0.04, vol = 0.3 } })
    elseif name == "cursor_unexplored" then
        M.play({ { kind = "tone", freq = 110, dur = 0.04, vol = 0.2 } })
    elseif name == "scan_tick" then
        M.play({ { kind = "tone", freq = 660, dur = 0.02, vol = 0.2 } })
    end
end

return M
