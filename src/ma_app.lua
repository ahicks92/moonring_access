-- ma_app.lua — gameplay one-shot actions: the H-family announcers, status
-- chords, review-buffer navigation, and the per-turn tile watcher.
--
-- Everything reads live game state at speak time (never cached), through
-- pcall guards: a read that breaks on some game state must degrade to
-- silence-with-log, not a crash.

local text = require("ma_text")
local speech = require("ma_speech")
local buffers = require("ma_buffers")
local hooks = require("ma_hooks")

local st = hooks.state
st.watch = st.watch or {}
local W = st.watch

local M = {}

local function player()
    return G_stateGame and G_stateGame.actorManager and G_stateGame.actorManager.player
end

local function root_name(root)
    if not root then return nil end
    local named = CCellData and CCellData.rootToText and CCellData.rootToText[root]
    return named or root
end

-- ------------------------------------------------------------- announcers --

-- H: hostiles the player can currently see, nearest first.
local function announce_hostiles()
    local p = player()
    if not p then return end
    local found = {}
    for _, a in ipairs(G_stateGame.actorManager.actorArray) do
        if a ~= p and not a.isDead and not a.isCorpse and a.faction == "enemy" then
            local ok, vis = pcall(a.getIsVisibleToPlayer, a)
            if ok and vis then
                local dx = a.position.x - p.position.x
                local dy = a.position.y - p.position.y
                local okn, name = pcall(a.getDisplayName, a)
                found[#found + 1] = {
                    d = text.dist(dx, dy),
                    s = (okn and name or a.actorType or "creature") .. ", " .. text.offset(dx, dy),
                }
            end
        end
    end
    if #found == 0 then
        speech.say("No hostiles in sight.", true)
        return
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    local parts = {}
    for i = 1, math.min(#found, 10) do parts[#parts + 1] = found[i].s end
    speech.say(#found .. (#found == 1 and " hostile: " or " hostiles: ") .. table.concat(parts, "; "), true)
end

-- Map roots worth reporting as points of interest.
local POI_ROOTS = {
    doorClosed = true, doorOpen = true, doorLocked = true, doorMetal = true,
    doorBroken = true, gateClosed = true, gateOpen = true, gateLocked = true,
    tileDoor = true, openDoor = true,
    stairsUp = true, stairsDown = true, floorDoor = true,
    trapdoorOpen = true, trapdoorClosed = true,
    chestClosed = true, crateClosed = true, barrelClosed = true, bookshelf = true,
    campfire = true, bed = true, throne = true, well = true,
}

local POI_RADIUS = 12

-- Iterate remembered tiles in a box around the player; cb(x, y, dx, dy, root).
local function each_remembered_tile(cb)
    local p = player()
    if not p then return end
    local map = G_stateGame.map
    local px, py = p.position.x, p.position.y
    for dy = -POI_RADIUS, POI_RADIUS do
        for dx = -POI_RADIUS, POI_RADIUS do
            local x, y = px + dx, py + dy
            local ok, mx, my = pcall(map.convertWorldXYToMapXYZeroIndexed, map, x, y)
            if ok and mx then
                local okr, rem = pcall(map.getIsRemembered, map, mx, my)
                if okr and rem then
                    local okroot, root = pcall(map.getRootAtMapXYZeroIndexed, map, mx, my)
                    cb(x, y, dx, dy, okroot and root or nil)
                end
            end
        end
    end
end

-- Triggers (signs, searchables, entrances) at a tile, as a spoken name.
local function trigger_names_at(x, y)
    local names = {}
    if not (G_stateGame.triggerData and G_stateGame.currentWorldName) then return names end
    local ok, list = pcall(G_stateGame.triggerData.getAllTriggersOnLevelAtXYZeroIndexed,
        G_stateGame.triggerData, G_stateGame.currentWorldName, x, y)
    if not ok or type(list) ~= "table" then return names end
    -- Non-informative internal trigger actions a player never interacts with.
    local SKIP = { playerStart = true, firewall = true, tutorial = true }
    for _, t in ipairs(list) do
        local action = t and t.action
        if action == "read" then
            names[#names + 1] = "something readable"
        elseif action == "search" then
            names[#names + 1] = "searchable spot"
        elseif action == "warp" then
            names[#names + 1] = "passage"
        elseif action and not SKIP[action] then
            names[#names + 1] = tostring(action)
        end
    end
    return names
end

-- Ctrl+H: points of interest — interesting roots + triggers, nearest first.
local function announce_pois()
    local found = {}
    each_remembered_tile(function(x, y, dx, dy, root)
        if root and POI_ROOTS[root] then
            found[#found + 1] = { d = text.dist(dx, dy),
                s = root_name(root) .. ", " .. text.offset(dx, dy) }
        end
        for _, tn in ipairs(trigger_names_at(x, y)) do
            found[#found + 1] = { d = text.dist(dx, dy), s = tn .. ", " .. text.offset(dx, dy) }
        end
    end)
    if #found == 0 then
        speech.say("No points of interest within " .. POI_RADIUS .. " tiles.", true)
        return
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    local parts = {}
    for i = 1, math.min(#found, 12) do parts[#parts + 1] = found[i].s end
    speech.say(#found .. " points of interest: " .. table.concat(parts, "; "), true)
end

-- Terrain roots too common to be worth naming in the Alt+H sweep.
local BORING_ROOTS = {
    blank = true, floor = true, grass = true, woodFloor = true, path = true,
    dirt = true, sand = true, stoneFloor = true, wall = true, mountains = true,
}

-- Alt+H: distinct terrain in range, grouped by kind, nearest instance + count.
local function announce_terrain()
    local groups = {}
    each_remembered_tile(function(x, y, dx, dy, root)
        if root and not BORING_ROOTS[root] then
            local g = groups[root]
            local d = text.dist(dx, dy)
            if not g then
                groups[root] = { count = 1, d = d, dx = dx, dy = dy }
            else
                g.count = g.count + 1
                if d < g.d then g.d = d; g.dx = dx; g.dy = dy end
            end
        end
    end)
    local list = {}
    for root, g in pairs(groups) do
        list[#list + 1] = { d = g.d,
            s = root_name(root) .. (g.count > 1 and (" times " .. g.count) or "")
                .. ", nearest " .. text.offset(g.dx, g.dy) }
    end
    if #list == 0 then
        speech.say("No notable terrain within " .. POI_RADIUS .. " tiles.", true)
        return
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local parts = {}
    for i = 1, math.min(#list, 8) do parts[#parts + 1] = list[i].s end
    speech.say("Terrain: " .. table.concat(parts, "; "), true)
end

-- ----------------------------------------------------------------- status --

local function round(n)
    return math.floor((tonumber(n) or 0) + 0.5)
end

local function announce_vitals()
    local ps = playerStats
    if not ps then return end
    local parts = {
        "Health " .. round(ps.health) .. " of " .. round(ps.maxHealth),
        "poise " .. round(ps.poise) .. " of " .. round(ps.maxPoise),
        "energy " .. round(ps.energy) .. " of " .. round(ps.maxEnergy),
        "food " .. round(ps.food) .. " of " .. round(ps.maxFood),
    }
    speech.say(table.concat(parts, ", "), true)
end

local function announce_money()
    if playerStats then speech.say(playerStats.money .. " guineas.", true) end
end

local function announce_position()
    local p = player()
    if not p then return end
    local world = tostring(G_stateGame.currentWorldName or "unknown")
    speech.say(world .. ", " .. p.position.x .. ", " .. p.position.y .. ".", true)
end

local function announce_turns()
    speech.say("Turn " .. tostring(G_stateGame.playerTurns or 0) .. ".", true)
end

-- Ctrl+S: HOW MANY hidden things remain on this level — knowledge without
-- locations, so "did I find everything" is answerable. Locations live in the
-- scanner's Secrets category (on until we learn whether vanilla discovery is
-- even viable for a blind player).
local function announce_secrets()
    local ma_map = require("ma_map")
    local p = player()
    if not p then return end
    local doors = 0
    for dy = -47, 47 do
        for dx = -47, 47 do
            if ma_map.secret_door_at(p.position.x + dx, p.position.y + dy) then
                doors = doors + 1
            end
        end
    end
    local traps = 0
    pcall(function()
        local list = G_stateGame.triggerData:getAllTriggersOnLevelWithActionName(
            G_stateGame.currentWorldName, "fnTrap")
        for _, t in ipairs(list or {}) do
            local root = ma_map.root(t.x, t.y)
            if not ma_map.trap_revealed_root(root) then traps = traps + 1 end
        end
    end)
    speech.say("Hidden here: " .. doors .. (doors == 1 and " door, " or " doors, ")
        .. traps .. (traps == 1 and " trap." or " traps."), true)
end

local function announce_modes()
    local safety = G_stateGame.safetyModeOn
    local sneak = playerStats and playerStats.isSneaking
    speech.say("Safety " .. (safety and "on" or "off")
        .. ", quiet " .. (sneak and "on" or "off") .. ".", true)
end

-- ------------------------------------------------------------ turn watcher --

-- Called every pump frame; announces tile changes as the player moves.
-- Differential: terrain root only when it CHANGED; triggers on the new tile
-- always. Non-interrupting — it follows the game-log lines of the same turn.
function M.watch_tick()
    local p = player()
    if not p or not p.position then W.px, W.py = nil, nil; return end
    local x, y = p.position.x, p.position.y
    if x == W.px and y == W.py then return end
    local first = W.px == nil
    local mdx, mdy = nil, nil
    if not first then mdx, mdy = x - W.px, y - W.py end
    W.px, W.py = x, y
    if first then W.root = nil; return end   -- world entry; "Entering X" covers it

    local parts = {}
    local ok, root = pcall(p.getCurrentTileRoot, p)
    root = ok and root or nil
    if root ~= W.root then
        W.root = root
        local named = root and not BORING_ROOTS[root] and root_name(root) or nil
        if named then parts[#parts + 1] = named end
    end
    for _, tn in ipairs(trigger_names_at(x, y)) do
        parts[#parts + 1] = tn
    end
    if #parts > 0 then
        speech.say(table.concat(parts, ", ") .. ".", false)
    end

    -- The wall echo fires on every real move (the primary spatial channel),
    -- preceded by a terrain-differentiated step cue. The movement delta gives
    -- the echo its heading (forward ping + side-width monitors).
    if W.steps_enabled ~= false then
        pcall(function() require("ma_synth").step_cue(root) end)
    end
    pcall(function() require("ma_echo").on_move(mdx, mdy) end)
end

-- --------------------------------------------------------- reveal watchers --
-- Sighted players get a white flash ON the revealed tile; the game's own log
-- line ("You spot a secret door!") says what but never where. Wrap the two
-- perception-reveal checks to speak the location.

local function offset_from_player_map_xy(mx, my)
    local p = player()
    if not p then return nil end
    local map = G_stateGame.map
    local ok, pmx, pmy = pcall(map.convertWorldXYToMapXYZeroIndexed, map, p.position.x, p.position.y)
    if not ok or not pmx then return nil end
    return text.offset(mx - pmx, my - pmy)
end

function M.install()
    hooks.wrap(G_stateGame, "checkForSecretDoorAtMapXYZeroIndexed", function(orig, self, x, y, guaranteed)
        local was_secret = false
        pcall(function()
            local data = self.map:getCellDataAtMapXYZeroIndexed(x, y)
            was_secret = (data and CCellData.cellIsSecretDoor[data.name]) and true or false
        end)
        local r = orig(self, x, y, guaranteed)
        if was_secret then
            pcall(function()
                local data = self.map:getCellDataAtMapXYZeroIndexed(x, y)
                if not (data and CCellData.cellIsSecretDoor[data.name]) then
                    local where = offset_from_player_map_xy(x, y)
                    if where then speech.say("Secret door " .. where .. ".", false) end
                end
            end)
        end
        return r
    end)

    -- Tab target cycling: the game plays a click but never names who you
    -- landed on. Speak name + offset (or "No target") — this is how you know
    -- who E will talk to or R will shoot.
    hooks.wrap(G_stateGame, "focusOnNextTarget", function(orig, self)
        local r = orig(self)
        pcall(function()
            local p = player()
            local t = p and p.target
            if not t then
                speech.say("Target cleared.", true)
                return
            end
            local ok, name = pcall(t.getDisplayName, t)
            local dx = t.position.x - p.position.x
            local dy = t.position.y - p.position.y
            speech.say((ok and name or "target") .. ", " .. text.offset(dx, dy) .. ".", true)
        end)
        return r
    end)

    hooks.wrap(G_stateGame, "checkForTrapAtMapXYZeroIndexed", function(orig, self, x, y, guaranteed)
        local before
        pcall(function() before = self.map:getRootAtMapXYZeroIndexed(x, y) end)
        local r = orig(self, x, y, guaranteed)
        pcall(function()
            local after = self.map:getRootAtMapXYZeroIndexed(x, y)
            if r and after ~= before then
                local where = offset_from_player_map_xy(x, y)
                local name = root_name(after) or "a trap"
                if where then speech.say(name .. " spotted " .. where .. ".", false) end
            end
        end)
        return r
    end)
end

-- --------------------------------------------------------------- dispatch --

local ACTIONS = {
    hostiles = announce_hostiles,
    pois = announce_pois,
    terrain = announce_terrain,
    vitals = announce_vitals,
    money = announce_money,
    position = announce_position,
    turns = announce_turns,
    modes = announce_modes,
    secrets = announce_secrets,
    cursor_step = function(cmd) require("ma_cursor").step(cmd.dir, cmd.skip) end,
    cursor_read = function() require("ma_cursor").read() end,
    cursor_recenter = function() require("ma_cursor").recenter() end,
    scan_entry = function(cmd) require("ma_scanner").step_entry(cmd.dir) end,
    scan_cat = function(cmd) require("ma_scanner").step_category(cmd.dir) end,
    scan_goto = function() require("ma_scanner").goto_selected() end,
    scan_rescan = function() require("ma_scanner").rescan(false) end,
    echo_toggle = function()
        local on = require("ma_echo").toggle()
        speech.say("Wall echo " .. (on and "on." or "off."), true)
    end,
    talk_status = function() require("ma_talk").status() end,
    tune_toggle = function()
        local hs = require("ma_hooks").state
        hs.tuning_open = not hs.tuning_open
        if not hs.tuning_open then speech.say("Tuning closed.", true) end
        -- Opening announces itself through the overlay dispatcher.
    end,
    steps_toggle = function()
        W.steps_enabled = (W.steps_enabled == false)
        speech.say("Step sounds " .. (W.steps_enabled ~= false and "on." or "off."), true)
    end,
    character = function()
        local ps = playerStats
        if not ps then return end
        local p = G_stateGame.actorManager.player
        local parts = {
            tostring(ps.name) .. ", level " .. tostring(ps.level),
            "strength " .. ps.strength .. ", intellect " .. ps.intellect
                .. ", finesse " .. ps.finesse .. ", perception " .. ps.perception
                .. ", endurance " .. ps.endurance .. ", luck " .. ps.luck,
        }
        local ok, melee = pcall(p.getMeleeWeaponData, p)
        if ok and melee and melee.name then parts[#parts + 1] = "wielding " .. melee.name end
        local ok2, ranged = pcall(p.getRangedWeaponData, p)
        if ok2 and ranged and ranged.name then parts[#parts + 1] = "ranged " .. ranged.name end
        speech.say(table.concat(parts, ". ") .. ".", true)
    end,
}

function M.dispatch(cmd)
    if cmd.action == "buffer_switch" then
        speech.say(buffers.switch(cmd.dir), true)
        return
    elseif cmd.action == "buffer_step" then
        speech.say(buffers.step(cmd.dir), true)
        return
    end
    local fn = ACTIONS[cmd.action]
    if fn then
        local ok, err = pcall(fn, cmd)
        if not ok then speech.log("action " .. cmd.action .. " failed: " .. tostring(err)) end
    end
end

return M
