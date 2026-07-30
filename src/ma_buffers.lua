-- ma_buffers.lua — review buffers: browsable scrollback the player steps
-- through at their own pace (Ctrl+Left/Right switch buffer, Ctrl+Up/Down step
-- lines; up = older). Content survives /reload via hooks.state.
--
-- The cursor snaps back to "latest" whenever a line is added, so stepping is
-- always relative to now (Tanglebeep's GameEventLog rule).

local hooks = require("ma_hooks")

local st = hooks.state
st.buffers = st.buffers or {
    order = { "log", "conversation", "words", "details" },
    names = { log = "Game log", conversation = "Conversation",
        words = "Ask about", details = "Details" },
    lines = { log = {}, conversation = {}, words = {}, details = {} },
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
if not B.lines.details then
    B.order = { "log", "conversation", "words", "details" }
    B.names.details = "Details"
    B.lines.details = {}
end

-- The details (tooltip) buffer binding — Blindfold's focus buffer. Bound to
-- the overlay-focused control's backing identity; its producer regenerates
-- the lines from live game state on every step (cursor preserved), so values
-- never go stale. Module-local on purpose: producers are closures over a
-- render and must not outlive a /reload.
local DB = { id = nil, producer = nil, prev_current = nil }

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

local function index_of_key(key)
    for i, k in ipairs(B.order) do
        if k == key then return i end
    end
    return nil
end

local function run_producer()
    if not DB.producer then return nil end
    local ok, lines = pcall(DB.producer)
    if not ok or type(lines) ~= "table" then return nil end
    local copy = {}
    for i, l in ipairs(lines) do copy[i] = tostring(l) end
    return copy
end

-- Bind the details buffer to the overlay-focused control. id is the binding
-- identity (backing object or structural key); producer() -> lines. Silently
-- makes Details the current buffer so Ctrl+Down immediately reads the first
-- line; the previously current buffer is restored on unbind. A control with
-- no producer (or no lines) unbinds — stale details never linger.
function M.bind_details(id, producer)
    if producer == nil then M.unbind_details() return end
    local same = DB.id ~= nil and DB.id == id
    DB.id = id
    DB.producer = producer
    if same then return end   -- fresh producer, same entity: keep the cursor
    local lines = run_producer()
    if not lines or #lines == 0 then M.unbind_details() return end
    B.lines.details = lines
    B.pos.details = 0          -- read top-down: first Ctrl+Down = line 1
    local di = index_of_key("details")
    if di and B.current ~= di then
        DB.prev_current = DB.prev_current or B.current
        B.current = di
    end
end

function M.unbind_details()
    DB.id = nil
    DB.producer = nil
    B.lines.details = {}
    B.pos.details = nil
    local di = index_of_key("details")
    if di and B.current == di then
        B.current = DB.prev_current or 1
        if not B.order[B.current] then B.current = 1 end
    end
    DB.prev_current = nil
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
            -- Scrollback buffers park at latest; the details buffer reads
            -- top-down, so re-entering it restarts at the first line.
            B.pos[key] = (key == "details") and 0 or nil
            return require("ma_mb").new():fragment(B.names[key])
                :list_item(require("ma_text").plural(#B.lines[key], "line"))
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

    -- Details regenerate from live game state on every step (values like
    -- prices and prospective stats stay honest); the cursor is preserved,
    -- clamped if the list shrank.
    if key == "details" and DB.producer then
        local fresh = run_producer()
        if fresh and #fresh > 0 then
            B.lines.details = fresh
            local pos = B.pos.details
            if pos and pos > #fresh then B.pos.details = #fresh end
        end
    end

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
