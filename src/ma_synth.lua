-- ma_synth.lua — mod-authored audio cues: stereo PCM rendered into SoundData
-- and played through our own Source pool (port of Tanglebeep's Core/Audio
-- concepts: constant-power pan + interaural time delay, band-passed noise,
-- ADSR-ish envelopes). Independent of the game's audio path, so the game's
-- same-frame sound dedup and volume plumbing never touch cues. Master mute
-- (love.audio.setVolume(0)) still silences them, which is what test runs want.

local hooks = require("ma_hooks")
local st = hooks.state
st.synth = st.synth or { sources = {} }
local S = st.synth

local M = {}

local RATE = 44100
local MAX_ITD = 0.0007   -- seconds of far-ear delay at full pan

-- Keep playing Sources referenced so the GC can't stop them; pruned per pump.
function M.prune()
    for i = #S.sources, 1, -1 do
        local src = S.sources[i]
        if not src:isPlaying() then table.remove(S.sources, i) end
    end
end

-- One RBJ biquad bandpass (constant skirt gain), processing a single sample.
local function bandpass_new(freq, q)
    local w0 = 2 * math.pi * freq / RATE
    local alpha = math.sin(w0) / (2 * q)
    local b0, b1, b2 = alpha, 0, -alpha
    local a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
    local x1, x2, y1, y2 = 0, 0, 0, 0
    return function(x)
        local y = (b0 / a0) * x + (b1 / a0) * x1 + (b2 / a0) * x2
            - (a1 / a0) * y1 - (a2 / a0) * y2
        x2, x1 = x1, x
        y2, y1 = y1, y
        return y
    end
end

-- Envelope: linear attack, exponential-ish decay to the end of the grain.
local function envelope(i, n, attack_samples)
    if i < attack_samples then return i / attack_samples end
    local t = (i - attack_samples) / math.max(1, n - attack_samples)
    return (1 - t) * (1 - t)
end

-- events: { {kind="tone"|"noise", freq=hz, dur=seconds, at=seconds, pan=-1..1,
--            vol=0..1, q=bandpass Q (noise only)} ... }
-- Renders everything into ONE stereo SoundData and plays it (a shared buffer
-- keeps multi-ping cues phase-coherent, per Tanglebeep's combat radar).

-- Dev introspection: per-channel energy of a render, to verify panning
-- reaches the samples (curl /eval require('ma_synth').channel_energy{...}).
function M.channel_energy(events)
    local l, r = 0, 0
    local data = M.render(events)
    if not data then return "render failed" end
    for i = 0, data:getSampleCount() - 1 do
        l = l + math.abs(data:getSample(i, 1))
        r = r + math.abs(data:getSample(i, 2))
    end
    return string.format("left=%.1f right=%.1f", l, r)
end

function M.play(events)
    if not events or #events == 0 then return end
    local ok, err = pcall(function()
        local data = M.render(events)
        if not data then return end
        local src = love.audio.newSource(data, "static")
        src:play()
        S.sources[#S.sources + 1] = src
    end)
    if not ok then require("ma_speech").log("synth error: " .. tostring(err)) end
end

function M.render(events)
    if not events or #events == 0 then return nil end
    local ok, result = pcall(function()
        local total = 0
        for _, e in ipairs(events) do
            total = math.max(total, (e.at or 0) + (e.dur or 0.05))
        end
        local n = math.ceil((total + MAX_ITD) * RATE) + 8
        local left = {}
        local right = {}
        for i = 0, n - 1 do left[i] = 0; right[i] = 0 end

        for _, e in ipairs(events) do
            local dur = e.dur or 0.05
            local grain_n = math.floor(dur * RATE)
            local start = math.floor((e.at or 0) * RATE)
            local pan = math.max(-1, math.min(1, e.pan or 0))
            local vol = e.vol or 0.5
            -- Constant-power pan law.
            local theta = (pan + 1) * math.pi / 4
            local lg, rg = math.cos(theta) * vol, math.sin(theta) * vol
            -- Far ear lags by |pan| * MAX_ITD.
            local itd = math.floor(math.abs(pan) * MAX_ITD * RATE)
            local ldelay = pan > 0 and itd or 0
            local rdelay = pan < 0 and itd or 0

            -- Pre-generate the grain, then NORMALIZE its peak before the
            -- envelope. Critical for narrow bandpass noise: at Q=30 the
            -- filter passes a ~9 Hz sliver of the white noise's energy and
            -- the raw ping comes out ~25 dB under everything else (the
            -- Tanglebeep noise pool was RMS-normalized for exactly this).
            local grain = {}
            local peak = 0
            if e.kind == "noise" then
                local bp = bandpass_new(e.freq or 261.63, e.q or 30)
                -- Deterministic LCG so cue timbre is stable run to run.
                local seed = math.floor((e.freq or 261) * 7919) % 2147483647
                for i = 0, grain_n - 1 do
                    seed = (seed * 48271) % 2147483647
                    local s = bp((seed / 2147483647) * 2 - 1)
                    grain[i] = s
                    local a = math.abs(s)
                    if a > peak then peak = a end
                end
            else
                local phase, step = 0, 2 * math.pi * (e.freq or 440) / RATE
                for i = 0, grain_n - 1 do
                    phase = phase + step
                    grain[i] = math.sin(phase)
                end
                peak = 1
            end
            local norm = peak > 0 and (1 / peak) or 1

            local attack = math.floor(0.004 * RATE)
            for i = 0, grain_n - 1 do
                local s = grain[i] * norm * envelope(i, grain_n, attack)
                local li = start + i + ldelay
                local ri = start + i + rdelay
                if li < n then left[li] = left[li] + s * lg end
                if ri < n then right[ri] = right[ri] + s * rg end
            end
        end

        local data = love.sound.newSoundData(n, RATE, 16, 2)
        for i = 0, n - 1 do
            local l = math.max(-1, math.min(1, left[i]))
            local r = math.max(-1, math.min(1, right[i]))
            data:setSample(i, 1, l)
            data:setSample(i, 2, r)
        end
        return data
    end)
    if not ok then
        require("ma_speech").log("synth render error: " .. tostring(result))
        return nil
    end
    return result
end

-- Terrain-differentiated footstep cue: what the game designed and abandoned
-- (its puddle pitch-shift is commented out at actor.lua:6281). Family by
-- terrain root; quiet, short, distinct.
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

-- Simple named cues.
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
