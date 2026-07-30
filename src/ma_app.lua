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
local MB = require("ma_mb")

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
        -- Hostile = enemy faction, OR anything currently targeting the
        -- player (aggroed neutral wildlife never flips faction).
        local hostile = a.faction == "enemy" or (a.target == p)
        if a ~= p and not a.isDead and not a.isCorpse and hostile then
            local ok, vis = pcall(a.getIsVisibleToPlayer, a)
            if ok and vis then
                local dx = a.position.x - p.position.x
                local dy = a.position.y - p.position.y
                local okn, name = pcall(a.getDisplayName, a)
                found[#found + 1] = {
                    d = text.dist(dx, dy),
                    s = MB.new():fragment(okn and name or a.actorType or "creature")
                        :list_item(text.offset(dx, dy)),
                }
            end
        end
    end
    if #found == 0 then
        speech.say("No hostiles in sight.", true)
        return
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    local m = MB.new()
    for i = 1, math.min(#found, 10) do m:sentence(found[i].s) end
    speech.say(m, true)
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
    -- Hazards: things that hurt or hold you.
    web = true, trapSpikesOn = true, trapSpikesOff = true, fireTrapOff = true,
    amberTrapOn = true, amberTrapOff = true, fire = true, embers = true, lava = true,
    -- Overworld location icons.
    village = true, cave_entrance = true, henge = true, ruin = true,
    tower = true, monolith1 = true, monolith2 = true,
    monolithBroken1 = true, monolithBroken2 = true,
    monolith1Inert = true, monolith2Inert = true, monolithShielded = true,
    jettyNorth = true, jettySouth = true, jettyEast = true, jettyWest = true,
}

local POI_RADIUS = 12

-- Iterate tiles in a box around the player; cb(x, y, dx, dy, root).
-- gate: "visible" (line of sight — Ctrl+H, else it spams every remembered
-- door in town) or "remembered" (Alt+H terrain survey).
local function each_gated_tile(gate, cb)
    local ma_map = require("ma_map")
    local p = player()
    if not p then return end
    local px, py = p.position.x, p.position.y
    for dy = -POI_RADIUS, POI_RADIUS do
        for dx = -POI_RADIUS, POI_RADIUS do
            local x, y = px + dx, py + dy
            local pass
            if gate == "visible" then pass = ma_map.visible(x, y)
            else pass = ma_map.remembered(x, y) end
            if pass then
                cb(x, y, dx, dy, ma_map.root(x, y))
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
    local SKIP = { playerStart = true, firewall = true, tutorial = true, mon = true,
        fnUp = true, fnDown = true, fnTeleport = true, fnTrap = true,
        fnYellDouseAltar = true,
        teleportPosition = true, fallPosition = true }
    for _, t in ipairs(list) do
        local action = t and t.action
        if action == "read" then
            names[#names + 1] = "something readable"
        elseif action == "search" then
            names[#names + 1] = "searchable spot"
        elseif action == "warp" then
            names[#names + 1] = "passage"
        elseif action == "object" then
            names[#names + 1] = require("ma_map").object_name(t.data) or "item"
        elseif action and not SKIP[action]
            and not require("ma_map").is_location_action(action) then
            names[#names + 1] = tostring(action)
        end
    end
    return names
end

-- Ctrl+H: points of interest — interesting roots + triggers + area exits,
-- nearest first.
local function announce_pois()
    local found = {}
    local function spot(d, dx, dy, ...)
        local e = MB.new()
        for _, part in ipairs({ ... }) do e:list_item(part) end
        e:list_item(text.offset(dx, dy))
        found[#found + 1] = { d = d, s = e }
    end
    each_gated_tile("visible", function(x, y, dx, dy, root)
        local things, merged = require("ma_map").tile_things(x, y)
        if not merged and root and POI_ROOTS[root] then
            spot(text.dist(dx, dy), dx, dy, require("ma_map").root_label(x, y, root))
        end
        for _, tn in ipairs(things) do
            spot(text.dist(dx, dy), dx, dy, tn)
        end
    end)
    -- Overworld gatherables at the game's own reveal range (adjacent
    -- sparkles — sighted players get nothing wider either).
    pcall(function()
        local p = player()
        for _, g in ipairs(require("ma_map").gatherable_reveals(p.position.x, p.position.y)) do
            spot(text.dist(g.dx, g.dy), g.dx, g.dy, g.name)
        end
    end)
    pcall(function()
        local ma_map = require("ma_map")
        local p = player()
        for _, e in ipairs(ma_map.area_exits()) do
            local known = false
            for _, t in ipairs(e.tiles) do
                if ma_map.remembered(t.x, t.y) then known = true break end
            end
            if known then
                local dx, dy = e.x - p.position.x, e.y - p.position.y
                spot(text.dist(dx, dy), dx, dy, "area exit " .. e.edge,
                    e.width > 1 and (e.width .. " wide") or nil)
            end
        end
    end)
    -- Overworld hoofprints (see discover_landmarks for the channel note).
    pcall(function()
        if tostring(G_stateGame.currentWorldName) ~= "Overworld" then return end
        local p = player()
        local range = (G_Globals and G_Globals.huntDetectionDistanceWolf) or 8
        local function prey_spot(animal)
            if not animal or not animal.position then return end
            local dx, dy = animal.position.x - p.position.x, animal.position.y - p.position.y
            local d = math.max(math.abs(dx), math.abs(dy))
            if d < range then spot(d, dx, dy, "hoofprints") end
        end
        prey_spot(playerStats.foodAnimal)
        local sleathen_alive = true
        pcall(function()
            sleathen_alive = not G_stateGame.speechArea:isPropertyNonZero("killed_sleathen")
        end)
        if sleathen_alive then prey_spot(playerStats.sleathen) end
        -- Fish ripples, same on-screen-ish range as the sweep.
        if playerStats.isFishPresent then
            local dx = playerStats.fishPositionX - p.position.x
            local dy = playerStats.fishPositionY - p.position.y
            if math.max(math.abs(dx), math.abs(dy)) <= POI_RADIUS then
                spot(text.dist(dx, dy), dx, dy, "water ripples")
            end
        end
    end)

    if #found == 0 then
        speech.say("Nothing of interest in sight.", true)
        return
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    local m = MB.new()
    for i = 1, math.min(#found, 12) do m:sentence(found[i].s) end
    if #found > 12 then m:sentence("and " .. (#found - 12) .. " more") end
    speech.say(m, true)
end

-- Terrain roots too common to be worth naming in the Alt+H sweep.
local BORING_ROOTS = {
    blank = true, floor = true, grass = true, woodFloor = true, path = true,
    dirt = true, sand = true, stoneFloor = true, wall = true, mountains = true,
}

-- Alt+H: distinct terrain in range, grouped by kind, nearest instance + count.
local function announce_terrain()
    local groups = {}
    each_gated_tile("remembered", function(x, y, dx, dy, root)
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
        local e = MB.new():fragment(root_name(root))
        if g.count > 1 then e:fragment("times " .. g.count) end
        e:list_item("nearest " .. text.offset(g.dx, g.dy))
        list[#list + 1] = { d = g.d, s = e }
    end
    if #list == 0 then
        speech.say("No notable terrain within " .. POI_RADIUS .. " tiles.", true)
        return
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local m = MB.new()
    for i = 1, math.min(#list, 8) do m:sentence(list[i].s) end
    speech.say(m, true)
end

-- ----------------------------------------------------------------- status --

local function round(n)
    return math.floor((tonumber(n) or 0) + 0.5)
end

local function announce_vitals()
    local ps = playerStats
    local p = player()
    if not ps then return end
    -- CURRENT values live on the player ACTOR (playerStats.poise sits stale
    -- at max while the real poise drains in combat); maxes come from stats.
    local function cur(field)
        if p and type(p[field]) == "number" then return p[field] end
        return ps[field]
    end
    speech.say(MB.new()
        :list_item("Health " .. round(cur("health")) .. " of " .. round(ps.maxHealth))
        :list_item("poise " .. round(cur("poise")) .. " of " .. round(ps.maxPoise))
        :list_item("energy " .. round(cur("energy")) .. " of " .. round(ps.maxEnergy))
        :list_item("food " .. round(ps.food) .. " of " .. round(ps.maxFood)), true)
end

local function announce_money()
    if playerStats then speech.say(playerStats.money .. " guineas.", true) end
end

local function announce_position()
    local p = player()
    if not p then return end
    local world = tostring(G_stateGame.currentWorldName or "unknown")
    speech.say(MB.new():list_item(world)
        :list_item(p.position.x .. ", " .. p.position.y), true)
end

local function announce_turns()
    speech.say("Turn " .. tostring(G_stateGame.playerTurns or 0), true)
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
    speech.say(MB.new():fragment("Hidden here:")
        :list_item(text.plural(doors, "door"))
        :list_item(text.plural(traps, "trap")), true)
end

-- Status effects: each accumulates 0..1 on the player (the icon bar); at 1
-- the active flag flips (isRotting etc.). Spoken names per status key.
local STATUS_NAMES = {
    rot = "rot", mad = "madness", stun = "stun", torpor = "torpor",
    blind = "blindness", bleed = "bleeding", flame = "flame",
    poison = "poison", wet = "wet", oily = "oily", negation = "negation",
    deafness = "deafness", vulnerable = "vulnerable", grappled = "grappled",
    deathly = "deathly", frenzy = "frenzy",
}

-- Ctrl+S: the status bar, on demand — active effects first, then building.
local function announce_statuses()
    local p = player()
    if not p then return end
    local active, building = {}, {}
    for _, key in ipairs(G_Globals.statuses or {}) do
        local flag = G_Globals.statusNameToStatus[key]
        local name = STATUS_NAMES[key] or key
        if flag and p[flag] then
            local v = type(p[key]) == "number" and p[key] or 0
            active[#active + 1] = MB.new():fragment(name)
                :list_item(math.min(100, math.floor(v * 100 + 0.5)) .. " percent left")
        elseif type(p[key]) == "number" and p[key] > 0 then
            building[#building + 1] = name .. " " .. math.floor(p[key] * 100 + 0.5) .. " percent"
        end
    end
    local m = MB.new()
    if #active > 0 then
        m:fragment("Active:")
        for _, s in ipairs(active) do m:list_item(s) end
    end
    if #building > 0 then
        m:sentence("Building:")
        for _, s in ipairs(building) do m:list_item(s) end
    end
    if m:is_empty() then m:fragment("No status effects") end
    speech.say(m, true)
end

-- (Active statuses have no turn counter: the same 0..1 value drains at a
-- condition-dependent rate — wet blocks rot decay, oil blocks flame decay —
-- so "percent left" is the only honest countdown.)

-- Per-frame watcher: announce activations, endings, and upward quarter-band
-- changes while a bar is building (the "watch the bar" information; falls
-- stay quiet, full drain announces once).
function M.status_tick()
    local p = player()
    if not p then W.status = nil; return end
    W.status = W.status or {}
    for _, key in ipairs(G_Globals.statuses or {}) do
        local flag = G_Globals.statusNameToStatus[key]
        local name = STATUS_NAMES[key] or key
        local st = W.status[key]
        if not st then st = { band = 0, active = false }; W.status[key] = st end

        -- Activation and expiry are announced by the GAME's own log lines
        -- ("You are rotten." / "You are no longer rotten."), which we
        -- already speak — only track the edge here, never voice it.
        local is_active = (flag and p[flag]) and true or false
        st.active = is_active

        local v = type(p[key]) == "number" and p[key] or 0
        local band = is_active and 0 or math.floor(math.min(v, 0.99) * 4)   -- 0..3 quarters
        if band > st.band then
            speech.say(MB.new():fragment(name .. " rising")
                :list_item(math.floor(v * 100 + 0.5) .. " percent"), false)
        elseif st.band > 0 and v <= 0 and not is_active then
            speech.say(name .. " faded.", false)
        end
        st.band = v > 0 and band or 0
    end

    -- Gaze/grapple links touching the player: the beam sighted players
    -- watch. Announce the link forming (type, source, offset) and breaking.
    -- The game's own "stares at you!" line is indoors-only and the break is
    -- particles + sfx, so outside (sailing grapples!) this is the only
    -- speech there is.
    pcall(function()
        local tsm = G_stateGame.tileScreenManager
        local world = tostring(G_stateGame.currentWorldName)
        local silent = W.links_world ~= world   -- world swap: no break spam
        W.links_world = world
        local seen = {}
        for _, link in ipairs(tsm.links or {}) do
            if link.ID1 == p.ID or link.ID2 == p.ID then
                local key = tostring(link.label) .. ":" .. tostring(link.ID1)
                    .. ":" .. tostring(link.ID2)
                seen[key] = true
                if not (W.links and W.links[key]) then
                    local other_id = link.ID1 == p.ID and link.ID2 or link.ID1
                    local other = G_stateGame.actorManager:getActorWithID(other_id)
                    local oname = "something"
                    pcall(function() oname = other:getDisplayName() end)
                    -- "flameGazeLink" -> action "flameGaze" -> "Firegaze"
                    local action_key = tostring(link.label):gsub("Link$", "")
                    local pretty = action_key
                    pcall(function()
                        local list = G_stateGame.actorManager:getActionClass():getActionList()
                        pretty = (list[action_key] and list[action_key].name)
                            or (list[link.label] and list[link.label].name) or action_key
                    end)
                    local where = nil
                    pcall(function()
                        where = text.offset(other.position.x - p.position.x,
                            other.position.y - p.position.y)
                    end)
                    local incoming = link.ID2 == p.ID
                    local m = MB.new():fragment(pretty)
                        :fragment(incoming and "link from" or "link to")
                        :fragment(oname)
                    if where then m:list_item(where) end
                    if incoming then m:exclaim() end
                    W.links = W.links or {}
                    W.links[key] = { pretty = pretty, oname = oname, incoming = incoming }
                    if not silent then speech.say(m, true) end
                end
            end
        end
        for key, info in pairs(W.links or {}) do
            if not seen[key] then
                W.links[key] = nil
                if not silent then
                    speech.say(MB.new():fragment(info.pretty)
                        :fragment(info.incoming and "link from" or "link to")
                        :fragment(info.oname):fragment("broken"), false)
                end
            end
        end
    end)

    -- Detection radius, sneaking only: the dashed aggro ring sighted
    -- players watch (drawAggroRange draws it only while sneaking). Shrinks
    -- against walls and in cover, grows next to light — announce every
    -- change, plus the starting value when sneak turns on.
    local sneaking = playerStats and playerStats.isSneaking
    if sneaking then
        local ok, r = pcall(function()
            return G_stateGame:modifyRadiusByStealth(G_Globals.defaultPlayerDetectionRadius)
        end)
        if ok and r ~= W.detect_r then
            W.detect_r = r
            speech.say("Detection radius " .. r, false)
        end
    else
        W.detect_r = nil
    end

    -- Digit-shortcut bindings (skills from the gods screen, items from the
    -- inventory — the game's own 1-0 quickslots). Announce changes; the
    -- first scan after load is a silent baseline.
    pcall(function()
        local tree = G_stateGame.skillTree
        local panel = G_stateGame.inventoryPanel
        local n = G_NumberOfSkillBindings or 10
        local first = W.binds == nil
        W.binds = W.binds or {}
        for i = 1, n do
            local sig, spoken
            local skill_id = tree.skillBindings[i]
            local item = panel.inventoryBindings[i]
            if skill_id then
                sig = "s:" .. tostring(skill_id)
                local act = nil
                pcall(function() act = G_stateGame.actorManager:getActionWithName(skill_id) end)
                spoken = (act and act.name) or tostring(skill_id)
            elseif item then
                sig = "i:" .. tostring(item.ID)
                local ok2, nm = pcall(G_stateGame.getInventoryObjectName, G_stateGame, item.ID)
                spoken = require("ma_text").clean((ok2 and nm) or item.name or "item")
            end
            local slot_key = i == 10 and 0 or i   -- slot 10 is the 0 key
            if not first and sig ~= W.binds[i] then
                if sig then
                    speech.say(MB.new():fragment("Bound to " .. slot_key .. ":")
                        :fragment(spoken), true)
                elseif W.binds[i] then
                    speech.say("Slot " .. slot_key .. " cleared.", true)
                end
            end
            W.binds[i] = sig
        end
    end)
end

local function announce_modes()
    local safety = G_stateGame.safetyModeOn
    local sneak = playerStats and playerStats.isSneaking
    speech.say(MB.new()
        :list_item("Safety " .. (safety and "on" or "off"))
        :list_item("quiet " .. (sneak and "on" or "off")), true)
end

-- ------------------------------------------------------- LOS discovery -----
-- Sighted players get landmarks pushed into awareness the moment they round
-- a corner. Each step, navigation landmarks (doors, stairs, hatches,
-- passages/entrances) that just ENTERED line of sight announce themselves
-- with an offset — once per level per landmark, non-interrupting.

local LANDMARK_ROOTS = {
    doorClosed = true, doorOpen = true, doorLocked = true, doorMetal = true,
    doorBroken = true, gateClosed = true, gateOpen = true, gateLocked = true,
    tileDoor = true, openDoor = true,
    stairsUp = true, stairsDown = true, floorDoor = true,
    trapdoorOpen = true, trapdoorClosed = true,
    -- Overworld location icons.
    village = true, cave_entrance = true, henge = true, ruin = true,
    tower = true, monolith1 = true, monolith2 = true,
    monolithBroken1 = true, monolithBroken2 = true,
    monolith1Inert = true, monolith2Inert = true, monolithShielded = true,
    jettyNorth = true, jettySouth = true, jettyEast = true, jettyWest = true,
}

local LOS_RADIUS = 11   -- >= max view distance (9 + high ground); visible() gates

local function discover_landmarks()
    local ma_map = require("ma_map")
    local p = player()
    if not p then return end
    local world = tostring(G_stateGame.currentWorldName or "?")
    W.seen_landmarks = W.seen_landmarks or {}
    local seen = W.seen_landmarks[world]
    if not seen then seen = {}; W.seen_landmarks[world] = seen end

    local found = {}
    local px, py = p.position.x, p.position.y
    local function spot(d, dx, dy, ...)
        local e = MB.new()
        for _, part in ipairs({ ... }) do e:list_item(part) end
        e:list_item(text.offset(dx, dy))
        found[#found + 1] = { d = d, s = e }
    end
    for dy = -LOS_RADIUS, LOS_RADIUS do
        for dx = -LOS_RADIUS, LOS_RADIUS do
            local x, y = px + dx, py + dy
            if ma_map.visible(x, y) then
                local root = ma_map.root(x, y)
                if root and LANDMARK_ROOTS[root] then
                    local key = x .. ":" .. y .. ":door"
                    if not seen[key] then
                        seen[key] = true
                        spot(text.dist(dx, dy), dx, dy, ma_map.root_label(x, y, root) or "door")
                    end
                end
                for _, tn in ipairs(trigger_names_at(x, y)) do
                    -- Entrances/passages only; signs and searchables stay
                    -- scanner territory (too common for push announcements).
                    if tn ~= "something readable" and tn ~= "searchable spot" then
                        local key = x .. ":" .. y .. ":" .. tn
                        if not seen[key] then
                            seen[key] = true
                            spot(text.dist(dx, dy), dx, dy, tn)
                        end
                    end
                end
            end
        end
    end
    -- Overworld prey: the game draws "pawprint" PARTICLES at prey positions
    -- within hunt-detection range — a channel nothing else reads. Same
    -- range gate as the particle spawn; both animals speak as plain
    -- "hoofprints" (the prints are visually identical for everyone).
    pcall(function()
        if tostring(G_stateGame.currentWorldName) ~= "Overworld" then return end
        local range = (G_Globals and G_Globals.huntDetectionDistanceWolf) or 8
        local function prey_spot(animal)
            if not animal or not animal.position then return end
            local dx, dy = animal.position.x - px, animal.position.y - py
            local d = math.max(math.abs(dx), math.abs(dy))
            if d < range then
                local key = "prey:" .. animal.position.x .. "," .. animal.position.y
                if not seen[key] then
                    seen[key] = true
                    spot(d, dx, dy, "hoofprints")
                end
            end
        end
        prey_spot(playerStats.foodAnimal)
        local sleathen_alive = true
        pcall(function()
            sleathen_alive = not G_stateGame.speechArea:isPropertyNonZero("killed_sleathen")
        end)
        if sleathen_alive then prey_spot(playerStats.sleathen) end

        -- Gatherable icons: the game checks these predicates in a 1-tile
        -- ring and draws icon particles; the "here!" notices are rising
        -- text. Same predicates, same radius (no super-radar): on-tile
        -- always speaks, adjacent speaks once per position.
        local GATHER = {
            { fn = "isHerbAtWorldXY", name = "herb" },
            { fn = "isBerryAtWorldXY", name = "berries" },
            { fn = "isKindlingAtWorldXY", name = "kindling" },
            { fn = "isTearAtWorldXY", name = "something odd" },
            { fn = "isWitchesHerbAtWorldXY", name = "strange plant" },
        }
        for _, g in ipairs(GATHER) do
            if type(G_stateGame[g.fn]) == "function" then
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        local x, y = px + dx, py + dy
                        local ok, hit = pcall(G_stateGame[g.fn], G_stateGame, x, y)
                        if ok and hit then
                            if dx == 0 and dy == 0 then
                                found[#found + 1] = { d = 0, s = g.name .. " here" }
                            else
                                local key = g.name .. ":" .. x .. "," .. y
                                if not seen[key] then
                                    seen[key] = true
                                    spot(1, dx, dy, g.name)
                                end
                            end
                        end
                    end
                end
            end
        end

        -- The fish ripple (viewport-parity radius).
        pcall(function()
            if playerStats.isFishPresent and playerStats.fishPositionX then
                local dx = playerStats.fishPositionX - px
                local dy = playerStats.fishPositionY - py
                local d = math.max(math.abs(dx), math.abs(dy))
                if d <= 7 then
                    local key = "fish:" .. playerStats.fishPositionX .. "," .. playerStats.fishPositionY
                    if not seen[key] then
                        seen[key] = true
                        spot(d, dx, dy, "water ripples")
                    end
                end
            end
        end)
    end)

    -- Merged area exits: announce a run once, when ANY of its tiles becomes
    -- visible, with the offset to its interior-connected anchor.
    for _, e in ipairs(ma_map.area_exits()) do
        local key = "exit:" .. e.key
        if not seen[key] then
            for _, t in ipairs(e.tiles) do
                if ma_map.visible(t.x, t.y) then
                    seen[key] = true
                    spot(text.dist(e.x - px, e.y - py), e.x - px, e.y - py,
                        "area exit " .. e.edge,
                        e.width > 1 and (e.width .. " wide") or nil)
                    break
                end
            end
        end
    end

    if #found > 0 then
        table.sort(found, function(a, b) return a.d < b.d end)
        local m = MB.new():fragment("Spotted:")
        for i = 1, math.min(#found, 5) do m:sentence(found[i].s) end
        if #found > 5 then m:sentence("and " .. (#found - 5) .. " more") end
        speech.say(m, false)
    end
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
    if first then W.root = nil; W.reveals = nil; return end   -- world entry; "Entering X" covers it

    local m = MB.new()
    -- Read the root LIVE at the new coords. getCurrentTileRoot returns the
    -- actor's cached tileRoot, refreshed at the TOP of each fixed tick —
    -- position changes mid-tick, so right after a move the cache still
    -- holds the departed tile and we'd speak one tile behind.
    local root = require("ma_map").root(x, y)
    local root_changed = root ~= W.root
    W.root = root
    -- Path tiles speak their SHAPE (Factorio Access pipe logic). Stepping
    -- ONTO a road announces whatever shape is underfoot; while following
    -- it, only decision points speak (corner, T, crossroads, end) —
    -- straight runs stay silent, even right after a bend.
    local shape_text, shape_key = nil, nil
    pcall(function() shape_text, shape_key = require("ma_map").path_shape_text(x, y) end)
    if shape_text then
        local is_straight = shape_key == "path:ns" or shape_key == "path:ew"
        if root_changed or (shape_key ~= W.path_key and not is_straight) then
            m:list_item(shape_text)
        end
    elseif root_changed then
        local named = root and not BORING_ROOTS[root]
            and require("ma_map").root_label(x, y, root) or nil
        if named then m:list_item(named) end
    end
    W.path_key = shape_key
    for _, tn in ipairs(trigger_names_at(x, y)) do
        m:list_item(tn)
    end
    -- Overworld gatherable reveals: the game sparkles ADJACENT tiles each
    -- step (the "here!" cases speak through the rising-text feed). Keyed by
    -- tile so walking along a berry row announces each bush once, with the
    -- direction sighted players get from the sparkle's position.
    pcall(function()
        local seen = {}
        for _, g in ipairs(require("ma_map").gatherable_reveals(x, y)) do
            if not (g.dx == 0 and g.dy == 0) then
                local key = g.name .. ":" .. (x + g.dx) .. ":" .. (y + g.dy)
                seen[key] = true
                if not (W.reveals and W.reveals[key]) then
                    m:list_item(g.name):list_item(text.offset(g.dx, g.dy))
                end
            end
        end
        W.reveals = seen
    end)
    speech.say(m, false)

    -- The wall echo fires on every real move (the primary spatial channel),
    -- preceded by a terrain-differentiated step cue. The movement delta gives
    -- the echo its heading (forward ping + side-width monitors). Then the
    -- LOS discovery pass announces landmarks that just came into view.
    if W.steps_enabled ~= false then
        pcall(function() require("ma_synth").step_cue(root) end)
    end
    pcall(function() require("ma_echo").on_move(mdx, mdy) end)
    pcall(discover_landmarks)
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
    -- Monster alerts: the rising "!" when something first sees, hears, or
    -- smells you. The game plays an "alerted" sound but never says WHO or
    -- WHERE; sighted players read that off the sprite. showAlert already
    -- gates on the monster being visible to the player, so speaking it
    -- leaks nothing. Per-actor cooldown stops burst repeats.
    hooks.wrap(CActor, "showAlert", function(orig, actor)
        local before = actor.alertTimer
        local r = orig(actor)
        pcall(function()
            if actor.alertTimer == before then return end   -- guards bailed
            st.alerted = st.alerted or {}
            local now = st.frame or 0
            local last = st.alerted[actor.ID]
            if last and now - last < 90 then return end
            st.alerted[actor.ID] = now
            local p = player()
            if not p or not p.position or not actor.position then return end
            local name = "Something"
            pcall(function() name = actor:getCapitalisedDisplayName() end)
            speech.say(MB.new():fragment(name .. " alert")
                :list_item(text.offset(actor.position.x - p.position.x,
                    actor.position.y - p.position.y)), false)
        end)
        return r
    end)

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
                    if where then
                        speech.say(MB.new():fragment("Secret door"):fragment(where), false)
                    end
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
            speech.say(MB.new():fragment(ok and name or "target")
                :list_item(text.offset(dx, dy)), true)
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
                if where then
                    speech.say(MB.new():fragment(name):fragment("spotted"):fragment(where), false)
                end
            end
        end)
        return r
    end)
end

-- "\" on the Overworld: weather report — amber fog proximity, wind, rain,
-- and the calendar moon. Amber matters because standing in it accrues
-- madness; wind because the fog field drifts with it.
local AMBER_SCAN = 15
local WIND_NAMES = { "north", "east", "south", "west" }

local function compass(dx, dy)
    local parts = {}
    if dy ~= 0 then parts[#parts + 1] = math.abs(dy) .. (dy > 0 and " south" or " north") end
    if dx ~= 0 then parts[#parts + 1] = math.abs(dx) .. (dx > 0 and " east" or " west") end
    if #parts == 0 then return "here" end
    return table.concat(parts, ", ")
end

-- Nearest cell (Chebyshev rings outward) whose amber flag equals want_amber.
local function nearest_amber(px, py, want_amber)
    local map = require("ma_map")
    for r = 0, AMBER_SCAN do
        local best
        for dy = -r, r do
            for dx = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r
                    and map.is_amber(px + dx, py + dy) == want_amber then
                    local d = dx * dx + dy * dy
                    if not best or d < best.d then best = { dx = dx, dy = dy, d = d } end
                end
            end
        end
        if best then return best.dx, best.dy end
    end
    return nil
end

local function announce_weather()
    local p = player()
    if not p then return end
    local map = require("ma_map")
    local px, py = p.position.x, p.position.y
    local m = MB.new()

    if map.is_amber(px, py) then
        local dx, dy = nearest_amber(px, py, false)
        m:fragment("Amber fog here")
        if dx then m:list_item("clear " .. compass(dx, dy)) end
    else
        local dx, dy = nearest_amber(px, py, true)
        if dx then m:fragment("Amber fog"):fragment(compass(dx, dy))
        else m:fragment("No amber fog within " .. AMBER_SCAN) end
    end

    -- windDirection names the SOURCE (maritime convention): sailing while
    -- facing it is "into the wind" (slack sails), fog and rain drift the
    -- opposite way. Sighted players learn this from the particle drift.
    local w = G_stateGame.weather
    if w and w.windDirection then
        m:sentence("Wind from the " .. (WIND_NAMES[w.windDirection] or "unknown"))
    end

    local rain = 0
    pcall(function() rain = w:getRainFraction() end)
    if rain < 0.05 then
        m:sentence("Clear skies")
    elseif rain < 0.33 then
        m:sentence("Light rain")
    elseif rain < 0.66 then
        m:sentence("Rain")
    else
        m:sentence("Heavy rain")
    end

    pcall(function()
        local cal = require("calendar")
        local date = cal.getMainDateAsText()
        if date == "Date Unknown" then
            -- Post-game sun/moon cycle: the date is hidden but day/night is real.
            m:sentence(cal.isDay() and "Daytime" or "Night")
        else
            m:sentence(date)
            local god = cal.getGodNameFromMoon(cal.worldMoon)
            if god then m:sentence("Moon of " .. god) end
        end
    end)

    speech.say(m, true)
end

-- --------------------------------------------------------------- dispatch --

local ACTIONS = {
    weather = announce_weather,
    hostiles = announce_hostiles,
    pois = announce_pois,
    terrain = announce_terrain,
    vitals = announce_vitals,
    money = announce_money,
    position = announce_position,
    turns = announce_turns,
    modes = announce_modes,
    secrets = announce_secrets,
    statuses = announce_statuses,
    cursor_step = function(cmd) require("ma_cursor").step(cmd.dir, cmd.skip) end,
    cursor_read = function() require("ma_cursor").read() end,
    cursor_to_target = function()
        local p = player()
        local t = p and p.target
        if t and t.position and not t.isDead then
            require("ma_cursor").jump_to(t.position.x, t.position.y)
        else
            speech.say("No target.", true)
        end
    end,
    cursor_recenter = function() require("ma_cursor").recenter() end,
    tracked_where = function() require("ma_screens").tracked_where() end,
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
        local m = MB.new():fragment(tostring(ps.name))
            :list_item("level " .. tostring(ps.level))
            :sentence("strength " .. ps.strength)
            :list_item("intellect " .. ps.intellect)
            :list_item("finesse " .. ps.finesse)
            :list_item("perception " .. ps.perception)
            :list_item("endurance " .. ps.endurance)
            :list_item("luck " .. ps.luck)
        local ok, melee = pcall(p.getMeleeWeaponData, p)
        if ok and melee and melee.name then m:sentence("wielding " .. melee.name) end
        local ok2, ranged = pcall(p.getRangedWeaponData, p)
        if ok2 and ranged and ranged.name then m:sentence("ranged " .. ranged.name) end
        speech.say(m, true)
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
