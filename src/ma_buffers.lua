-- ma_buffers.lua — review buffers: browsable scrollback the player steps
-- through at their own pace (Ctrl+Left/Right switch buffer, Ctrl+Up/Down step
-- lines; up = older). Content survives /reload via hooks.state.
--
-- The cursor snaps back to "latest" whenever a line is added, so stepping is
-- always relative to now (Tanglebeep's GameEventLog rule).

local hooks = require("ma_hooks")

local st = hooks.state
st.buffers = st.buffers or {
    order = { "log", "conversation", "words" },
    names = { log = "Game log", conversation = "Conversation", words = "Ask about" },
    lines = { log = {}, conversation = {}, words = {} },
    pos = {},          -- [key] = cursor index into lines, nil = at latest
    current = 1,
}
local B = st.buffers

-- Migration for reloads over an older persisted structure.
if not B.lines.words then
    B.order = { "log", "conversation", "words" }
    B.names.words = "Ask about"
    B.lines.words = {}
end

local CAP = 300

local M = {}

function M.add(key, line)
    local lines = B.lines[key]
    if not lines or line == nil or line == "" then return end
    lines[#lines + 1] = line
    if #lines > CAP then table.remove(lines, 1) end
    B.pos[key] = nil   -- snap to latest
end

function M.clear(key)
    if B.lines[key] then B.lines[key] = {} end
    B.pos[key] = nil
end

-- Replace a buffer's whole content (dynamic buffers like Ask-about).
function M.set_lines(key, lines)
    if not B.lines[key] then return end
    local copy = {}
    for i, l in ipairs(lines or {}) do copy[i] = l end
    B.lines[key] = copy
    B.pos[key] = nil
end

local function current_key()
    return B.order[B.current]
end

-- Switch buffer left/right; returns the announcement. EMPTY BUFFERS ARE
-- SKIPPED (the Blindfold rule): the ring only contains buffers with content,
-- so "Ask about" simply doesn't exist outside conversations. Switching
-- resets the target's cursor to latest — never a stale parked position.
function M.switch(dir)
    local n = #B.order
    local step = dir == "right" and 1 or -1
    local idx = B.current
    for _ = 1, n do
        idx = ((idx - 1 + step) % n) + 1
        if #B.lines[B.order[idx]] > 0 then
            B.current = idx
            local key = current_key()
            B.pos[key] = nil
            local count = #B.lines[key]
            return B.names[key] .. ", " .. count .. (count == 1 and " line" or " lines")
        end
    end
    require("ma_synth").cue("bonk")
    return "All buffers empty"
end

-- Step within the current buffer; "up" = older. Returns the line to speak,
-- or nil after bonking at an edge — every spoken line is a REAL line, no
-- synthetic "at latest"/"oldest" pseudo-entries.
function M.step(dir)
    local key = current_key()
    local lines = B.lines[key]
    if #lines == 0 then return B.names[key] .. " is empty" end

    local pos = B.pos[key]
    if dir == "up" then
        pos = (pos or (#lines + 1)) - 1
        if pos < 1 then
            require("ma_synth").cue("bonk")
            B.pos[key] = 1
            return nil
        end
    else
        if pos == nil or pos >= #lines then
            require("ma_synth").cue("bonk")
            return nil
        end
        pos = pos + 1
    end
    B.pos[key] = pos
    return lines[pos]
end

return M
