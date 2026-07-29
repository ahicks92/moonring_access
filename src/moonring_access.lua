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

    stage("keyboard hook", function()
        -- After the game rebuilds its key dicts each 40Hz tick: inject dev
        -- keys (and later, claim the mod's own vocabulary).
        hooks.wrap(G_Keyboard, "fixedUpdate", function(orig)
            orig()
            pcall(dev.inject_pending_keys, G_Keyboard)
        end)
    end)

    stage("game text feed", function()
        -- Feed every game-log line to /log. (Speaking these comes in Phase 3;
        -- the dev feed exists from day one so tests can assert on game text.)
        if G_stateGame then
            hooks.wrap(G_stateGame, "addText", function(orig, self, total_text, no_spam)
                pcall(function()
                    if type(total_text) == "string" then
                        local clean = total_text:gsub("%b{}", "")
                        for line in clean:gmatch("[^\n]+") do
                            dev.on_game_text(line)
                        end
                    end
                end)
                return orig(self, total_text, no_spam)
            end)
        end
    end)

    stage("announce", function()
        speech.say("Moonring Access loaded.", true)
    end)

    print("[MoonringAccess] boot complete")
end

return M
