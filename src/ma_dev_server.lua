-- ma_dev_server.lua — in-process HTTP dev server for MoonringAccess.
--
-- The Tanglebeep dev-driver pattern, simplified for Lua: a loopback-only
-- TCP server polled non-blocking from the frame pump (main thread, so /eval
-- needs no marshaling). It lets an agent introspect and drive the live game:
--
--   GET  /health           liveness + frame counter + current state
--   POST /eval             Lua source, run in a persistent env; returns results
--   GET  /speech?since=N   everything say() emitted, monotonic cursor
--   GET  /log?since=N      every game-log line (addText feed), same cursor form
--   POST /key              synthesize keypresses ("w", "lctrl+h", "down down return")
--   GET  /screenshot       capture framebuffer to save dir, return absolute path
--   POST /reload           hot-reload all mod modules from disk, re-boot
--
-- Ring buffers and the listening socket live in hooks.state so /reload does
-- not drop history or the port.

local socket = require("socket")
local hooks = require("ma_hooks")

local st = hooks.state
st.dev = st.dev or {}
local D = st.dev

local M = {}

local PORT = tonumber(os.getenv("MOONRING_ACCESS_PORT") or "") or 8771
local RING_CAP = 500

-- ---------------------------------------------------------------- rings ----
local function ring_new()
    return { items = {}, next_index = 1 }   -- items[k] = {i=abs_index, t=text}
end

local function ring_add(r, text)
    r.items[#r.items + 1] = { i = r.next_index, t = text }
    r.next_index = r.next_index + 1
    if #r.items > RING_CAP then table.remove(r.items, 1) end
end

-- First line "next=N" (pass back as ?since=N), then "index: text" lines.
local function ring_render(r, since)
    since = tonumber(since) or 0
    local out = { "next=" .. r.next_index }
    for _, e in ipairs(r.items) do
        if e.i > since then out[#out + 1] = e.i .. ": " .. e.t end
    end
    return table.concat(out, "\n")
end

D.speech_ring = D.speech_ring or ring_new()
D.log_ring = D.log_ring or ring_new()
D.key_queue = D.key_queue or {}

function M.on_speech(text) ring_add(D.speech_ring, text) end
function M.on_game_text(text) ring_add(D.log_ring, text) end

-- ----------------------------------------------------------------- eval ----
local function do_eval(body)
    if not st.eval_env then
        st.eval_env = setmetatable({}, { __index = _G })
    end
    local chunk, err = load("return " .. body, "eval", "t", st.eval_env)
    if not chunk then
        chunk, err = load(body, "eval", "t", st.eval_env)
    end
    if not chunk then return "[compile] " .. tostring(err) end

    local results = { pcall(chunk) }
    if not results[1] then return "[error] " .. tostring(results[2]) end

    local ok_serpent, serpent = pcall(require, "library.serpent")
    local out = {}
    for i = 2, #results do
        local v = results[i]
        if type(v) == "table" and ok_serpent then
            out[#out + 1] = serpent.line(v, { comment = false, maxlevel = 4, maxnum = 200 })
        else
            out[#out + 1] = tostring(v)
        end
    end
    if #out == 0 then return "ok (no results)" end
    return table.concat(out, "\n")
end

-- ----------------------------------------------------------------- keys ----
-- Body: whitespace-separated presses, each "key" or "mod+key" (e.g. "lctrl+h").
-- Each press is injected for one 40Hz keyboard tick, with a spacing gap so the
-- game can resolve the previous action (movement takes several ticks).
local KEY_GAP_TICKS = 10

local function queue_keys(body)
    local count = 0
    for press in body:gmatch("%S+") do
        local entry = { keys = {} }
        for part in press:gmatch("[^+]+") do
            entry.keys[#entry.keys + 1] = part
        end
        if #entry.keys > 0 then
            D.key_queue[#D.key_queue + 1] = entry
            count = count + 1
        end
    end
    return "queued " .. count
end

-- Called from the post-keyboard hook, once per keyboard fixedUpdate, AFTER the
-- game rebuilt its key dicts (so our writes survive until consumers read them).
function M.inject_pending_keys(kb)
    if D.key_gap and D.key_gap > 0 then
        D.key_gap = D.key_gap - 1
        return
    end
    local entry = table.remove(D.key_queue, 1)
    if not entry then return end
    st.input = st.input or {}
    st.input.injected = st.input.injected or {}
    for _, key in ipairs(entry.keys) do
        kb.currentKeyPressDictionary[key] = true
        kb.justPressedDictionary[key] = true
        -- Keys outside the game's allKeys scan (home/end/numpad) are edge-
        -- detected by ma_input via love.keyboard.isDown, which synthesized
        -- keys never touch — mirror them into an injected set it also reads.
        st.input.injected[key] = true
    end
    D.key_gap = KEY_GAP_TICKS
end

-- ----------------------------------------------------------------- http ----
local function respond(client, code, body)
    body = body or ""
    client:send("HTTP/1.1 " .. code .. "\r\n"
        .. "Content-Type: text/plain; charset=utf-8\r\n"
        .. "Content-Length: " .. #body .. "\r\n"
        .. "Connection: close\r\n\r\n" .. body)
    client:close()
end

local function handle(client)
    client:settimeout(0.5)
    local request, rerr = client:receive("*l")
    if not request then client:close(); return end
    local method, target = request:match("^(%u+)%s+(%S+)")
    if not method then respond(client, "400 Bad Request"); return end

    local content_length = 0
    while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        local len = line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if len then content_length = tonumber(len) end
    end
    local body = ""
    if content_length > 0 then
        body = client:receive(content_length) or ""
    end

    local path, query = target:match("^([^?]+)%??(.*)$")
    local since = query:match("since=(%d+)")

    local ok, err = pcall(function()
        if path == "/health" then
            local state = "unknown"
            pcall(function()
                local gs = require("library.gamestate")
                state = (gs.current() == G_stateGame) and "game" or "title"
            end)
            respond(client, "200 OK", "ok MoonringAccess frame=" .. tostring(st.frame or 0)
                .. " state=" .. state .. " muted=" .. tostring(os.getenv("MOONRING_ACCESS_MUTE") ~= nil))
        elseif path == "/eval" and method == "POST" then
            respond(client, "200 OK", do_eval(body))
        elseif path == "/speech" then
            respond(client, "200 OK", ring_render(D.speech_ring, since))
        elseif path == "/log" then
            respond(client, "200 OK", ring_render(D.log_ring, since))
        elseif path == "/key" and method == "POST" then
            respond(client, "200 OK", queue_keys(body))
        elseif path == "/screenshot" then
            love.filesystem.remove("ma_shot.png")
            love.graphics.captureScreenshot("ma_shot.png")
            respond(client, "200 OK", love.filesystem.getSaveDirectory() .. "/ma_shot.png")
        elseif path == "/gui" then
            respond(client, "200 OK", require("ma_dispatcher").describe())
        elseif path == "/reload" and method == "POST" then
            st.pending_reload = true
            respond(client, "200 OK", "reload scheduled")
        else
            respond(client, "404 Not Found", "unknown: " .. tostring(path))
        end
    end)
    if not ok then
        pcall(respond, client, "500 Internal Server Error", "[host error] " .. tostring(err))
    end
end

function M.start()
    if D.server then return true end   -- reload: keep the bound port
    local server, err = socket.bind("127.0.0.1", PORT)
    if not server then
        require("ma_speech").log("dev server bind FAILED on port " .. PORT .. ": " .. tostring(err))
        return false
    end
    server:settimeout(0)
    D.server = server
    require("ma_speech").log("dev server listening on 127.0.0.1:" .. PORT)
    return true
end

-- Per-frame poll from the pump. Handles a bounded number of connections so a
-- burst can't stall a frame for long.
function M.poll()
    if not D.server then return end
    for _ = 1, 4 do
        local client = D.server:accept()
        if not client then break end
        local ok, err = pcall(handle, client)
        if not ok then
            pcall(function() client:close() end)
            require("ma_speech").log("dev request error: " .. tostring(err))
        end
    end
end

return M
