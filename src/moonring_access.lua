-- moonring_access.lua — MoonringAccess boot module, injected by lovely at the
-- end of love.load (all game globals/classes exist by then).
--
-- boot() is idempotent: every game-facing patch goes through ma_hooks.wrap,
-- which rebuilds from stored originals, so /reload can clear the mod's
-- modules, re-require them from disk, and call boot() again safely. A boot
-- failure must never take the game down: each stage runs under pcall and
-- reports to the lovely console + the mod log.

local M = {}

-- Mod file names (love.filesystem-relative) by module name, in load order.
-- Used by the hot-reload path, which bypasses whatever caching lovely's
-- require registration does and always reads current disk contents.
local MODULES = {
    { name = "ma_hooks",       file = "Mods/MoonringAccess/ma_hooks.lua" },
    { name = "ma_speech",      file = "Mods/MoonringAccess/ma_speech.lua" },
    { name = "ma_dev_server",  file = "Mods/MoonringAccess/ma_dev_server.lua" },
    { name = "ma_text",        file = "Mods/MoonringAccess/ma_text.lua" },
    { name = "ma_buffers",     file = "Mods/MoonringAccess/ma_buffers.lua" },
    { name = "ma_id",          file = "Mods/MoonringAccess/ma_id.lua" },
    { name = "ma_mb",          file = "Mods/MoonringAccess/ma_mb.lua" },
    { name = "ma_graph",       file = "Mods/MoonringAccess/ma_graph.lua" },
    { name = "ma_keygraph",    file = "Mods/MoonringAccess/ma_keygraph.lua" },
    { name = "ma_dispatcher",  file = "Mods/MoonringAccess/ma_dispatcher.lua" },
    { name = "ma_input",       file = "Mods/MoonringAccess/ma_input.lua" },
    { name = "ma_screens",     file = "Mods/MoonringAccess/ma_screens.lua" },
    { name = "ma_overlays",    file = "Mods/MoonringAccess/ma_overlays.lua" },
    { name = "ma_map",         file = "Mods/MoonringAccess/ma_map.lua" },
    { name = "ma_items",       file = "Mods/MoonringAccess/ma_items.lua" },
    { name = "ma_synth",       file = "Mods/MoonringAccess/ma_synth.lua" },
    { name = "ma_shapes",      file = "Mods/MoonringAccess/ma_shapes.lua" },
    { name = "ma_cursor",      file = "Mods/MoonringAccess/ma_cursor.lua" },
    { name = "ma_echo",        file = "Mods/MoonringAccess/ma_echo.lua" },
    { name = "ma_scanner",     file = "Mods/MoonringAccess/ma_scanner.lua" },
    { name = "ma_talk",        file = "Mods/MoonringAccess/ma_talk.lua" },
    { name = "ma_target",      file = "Mods/MoonringAccess/ma_target.lua" },
    { name = "ma_app",         file = "Mods/MoonringAccess/ma_app.lua" },
    { name = "moonring_access", file = "Mods/MoonringAccess/moonring_access.lua" },
}

local function stage(what, fn)
    local ok, err = pcall(fn)
    if not ok then
        print("[MoonringAccess] " .. what .. " FAILED: " .. tostring(err))
        pcall(function()
            love.filesystem.append("moonring_access.log",
                os.date("%H:%M:%S ") .. what .. " FAILED: " .. tostring(err) .. "\n")
        end)
    end
    return ok
end

local function do_reload()
    print("[MoonringAccess] hot reload")
    local loaded = {}
    for _, m in ipairs(MODULES) do
        local src, err = love.filesystem.read(m.file)
        if not src then
            print("[MoonringAccess] reload: cannot read " .. m.file .. ": " .. tostring(err))
            return
        end
        local chunk, cerr = load(src, "@" .. m.file)
        if not chunk then
            print("[MoonringAccess] reload: compile error in " .. m.file .. ": " .. tostring(cerr))
            return   -- keep the running version; a broken file must not kill the mod
        end
        loaded[#loaded + 1] = { name = m.name, chunk = chunk }
    end
    -- All files compiled — now (and only now) swap them in.
    for _, l in ipairs(loaded) do
        package.loaded[l.name] = l.chunk() or true
    end
    local fresh = package.loaded["moonring_access"]
    if type(fresh) == "table" and fresh.boot then fresh.boot() end
end

function M.pump(dt)
    local hooks = require("ma_hooks")
    local st = hooks.state
    st.frame = (st.frame or 0) + 1

    local dev = require("ma_dev_server")
    dev.poll()

    -- Realize claimed input: feed each command to the overlay dispatcher and
    -- speak the result. Overlay speech interrupts (it is direct feedback to a
    -- deliberate press).
    local input = require("ma_input")
    local dispatcher = require("ma_dispatcher")
    local speech = require("ma_speech")
    local app = require("ma_app")
    local buffers = require("ma_buffers")

    -- Speak a dispatcher result and bind the tooltip buffer to the focused
    -- control (its `details` producer), so Ctrl+Up/Down break the focused
    -- thing down line by line wherever details exist.
    local function realize_overlay(r)
        if not r then return end
        if r.message then speech.say(r.message, true) end
        if r.focus_key then
            buffers.bind_details(r.focus_ref or r.focus_key, r.details)
        end
    end

    for _, cmd in ipairs(input.drain()) do
        if cmd.kind == "app" then
            app.dispatch(cmd)
        else
            realize_overlay(dispatcher.tick(cmd))
        end
    end

    -- Idle tick: announces fresh opens, sub-identity swaps, and focus
    -- reconciliation jumps even when no key was pressed.
    realize_overlay(dispatcher.tick(nil))
    if not dispatcher.active_id() then buffers.unbind_details() end

    -- Game-log lines captured this frame, coalesced into one non-interrupting
    -- utterance, then the tile watcher (which follows the same turn's prose).
    if st.pending_say and #st.pending_say > 0 then
        speech.say(table.concat(st.pending_say, " "), false)
        st.pending_say = {}
    end
    pcall(app.watch_tick)
    pcall(app.status_tick)

    -- Spatial-tool housekeeping: cursor follow (per game turn), scanner
    -- world-change invalidation, finished-Source pruning; conversation
    -- autocomplete watcher; targeting voice-over.
    pcall(function() require("ma_cursor").follow_tick() end)
    pcall(function() require("ma_scanner").watch_tick() end)
    pcall(function() require("ma_synth").prune() end)
    pcall(function() require("ma_talk").tick() end)
    pcall(function() require("ma_target").tick() end)

    if st.pending_reload then
        st.pending_reload = false
        stage("reload", do_reload)
    end
end

function M.boot()
    local hooks, speech, dev

    stage("modules", function()
        hooks = require("ma_hooks")
        speech = require("ma_speech")
        dev = require("ma_dev_server")
    end)
    if not hooks then return end

    stage("speech init", function()
        local mod_dir = love.filesystem.getSaveDirectory() .. "/Mods/MoonringAccess"
        speech.init(mod_dir)
    end)

    stage("dev server", function()
        dev.start()
        speech.observer = dev.on_speech
    end)

    stage("pump hook", function()
        hooks.wrap(love, "update", function(orig, dt)
            orig(dt)
            local ok, err = pcall(M.pump, dt)
            if not ok then print("[MoonringAccess] pump error: " .. tostring(err)) end
        end)
    end)

    stage("overlays", function()
        require("ma_overlays").register_all()
    end)

    stage("keyboard hook", function()
        -- After the game rebuilds its key dicts each 40Hz tick: inject dev
        -- keys first (so synthesized test keys travel the claim path exactly
        -- like real ones), then claim the mod's vocabulary.
        local input = require("ma_input")
        hooks.wrap(G_Keyboard, "fixedUpdate", function(orig)
            orig()
            pcall(dev.inject_pending_keys, G_Keyboard)
            local ok, err = pcall(input.claim, G_Keyboard)
            if not ok then print("[MoonringAccess] claim error: " .. tostring(err)) end
        end)
    end)

    stage("game text feed", function()
        -- Every game-log line: dev ring (/log), the review buffer, and the
        -- pending-speech list flushed once per frame by the pump.
        local text = require("ma_text")
        local buffers = require("ma_buffers")
        local st = hooks.state
        if G_stateGame then
            hooks.wrap(G_stateGame, "addText", function(orig, self, total_text, no_spam)
                pcall(function()
                    if type(total_text) == "string" then
                        for line in tostring(total_text):gmatch("[^\n]+") do
                            local clean = text.clean(line)
                            if clean ~= "" then
                                dev.on_game_text(clean)
                                buffers.add("log", clean)
                                st.pending_say = st.pending_say or {}
                                st.pending_say[#st.pending_say + 1] = clean
                            end
                        end
                    end
                end)
                return orig(self, total_text, no_spam)
            end)
        end
    end)

    stage("conversation hooks", function()
        if G_stateGame then require("ma_talk").install() end
    end)

    stage("reveal hooks", function()
        if G_stateGame then require("ma_app").install() end
    end)

    stage("mute", function()
        -- MOONRING_ACCESS_MUTE mutes the GAME too, not just mod speech: test
        -- runs must not play music/sfx over the developer's screen reader.
        -- Master OpenAL volume covers music, sfx, and future mod cues alike.
        if speech.muted() then love.audio.setVolume(0) end
    end)

    stage("announce", function()
        speech.say("Moonring Access loaded.", true)
    end)

    print("[MoonringAccess] boot complete")
end

return M
