-- ma_map.lua — safe world-coordinate map queries shared by the cursor, wall
-- echo, and scanner. Every game call is pcall-guarded; nil means "can't tell"
-- (off the 96x96 sliding window, no game state, etc.). All take WORLD coords
-- and convert internally.

local M = {}

function M.game_map()
    return G_stateGame and G_stateGame.map
end

function M.player()
    return G_stateGame and G_stateGame.actorManager and G_stateGame.actorManager.player
end

-- world -> 0-indexed map-window coords, or nil when outside the window.
function M.to_map(x, y)
    local map = M.game_map()
    if not map then return nil end
    local ok, mx, my = pcall(map.convertWorldXYToMapXYZeroIndexed, map, x, y)
    if not ok or type(mx) ~= "number" then return nil end
    if mx < 0 or my < 0 or mx >= 96 or my >= 96 then return nil end
    return mx, my
end

local function map_bool(method, x, y)
    local map = M.game_map()
    local mx, my = M.to_map(x, y)
    if not map or not mx then return nil end
    local ok, v = pcall(map[method], map, mx, my)
    if not ok then return nil end
    return v and true or false
end

function M.walkable(x, y) return map_bool("isWalkableXYZeroIndexed", x, y) end
function M.remembered(x, y) return map_bool("getIsRemembered", x, y) end
function M.visible(x, y) return map_bool("getIsVisibleAndLitXYZeroIndexed", x, y) end

function M.root(x, y)
    local map = M.game_map()
    local mx, my = M.to_map(x, y)
    if not map or not mx then return nil end
    local ok, root = pcall(map.getRootAtMapXYZeroIndexed, map, mx, my)
    return ok and root or nil
end

function M.root_name(root)
    if not root then return nil end
    local named = CCellData and CCellData.rootToText and CCellData.rootToText[root]
    return named or root
end

-- Display name of the overworld location whose entry tile is (x, y), when
-- the player knows or has seen it — the exact gate the game's map screen
-- labels use (seeLocation fires the moment the tile is visible and lit, so
-- anything we can announce is already named for sighted players). nil when
-- unknown or not a location tile.
function M.location_name_at(x, y)
    if not G_stateGame or tostring(G_stateGame.currentWorldName) ~= "Overworld" then return nil end
    local td = G_stateGame.triggerData
    if not (td and td.overworldEntryPoints) then return nil end
    for _, v in ipairs(td.overworldEntryPoints) do
        if v.x == x and v.y == y then
            local name = v.data or v.action
            if name and name ~= "playerStart"
                and ((playerStats.knownLocations and playerStats.knownLocations[name])
                    or (playerStats.seenLocations and playerStats.seenLocations[name])) then
                local display = nil
                pcall(function()
                    local wd = require("world_data").getWorldDataWithName(name)
                    if wd and wd.displayName and wd.displayName ~= "" then display = wd.displayName end
                end)
                return display or tostring(name):gsub("_", " ")
            end
            return nil
        end
    end
    return nil
end

-- Spoken name for the tile root at (x, y): an overworld location tile
-- carries its display name once known or seen — "Runacarr henge", "Yarrow
-- village", "Yarrow Cave" (the kind is appended only when the name doesn't
-- already contain it). Everything else is the plain root name.
function M.root_label(x, y, root)
    root = root or M.root(x, y)
    local base = M.root_name(root)
    local loc = M.location_name_at(x, y)
    if loc then
        local l = loc:lower()
        for word in tostring(base or ""):lower():gmatch("%a+") do
            if l:find(word, 1, true) then return loc end
        end
        if base then return loc .. " " .. tostring(base):lower() end
        return loc
    end
    return base
end

-- True when a trigger action IS an overworld location name (the game's
-- enter-location triggers carry the destination world as their action).
-- The tile's icon root announces these — speaking the raw world name would
-- stutter ("Runacarr henge, henge1") or leak an unseen location's identity.
function M.is_location_action(action)
    if not action or not G_stateGame then return false end
    if tostring(G_stateGame.currentWorldName) ~= "Overworld" then return false end
    local wd = nil
    pcall(function() wd = require("world_data").getWorldDataWithName(tostring(action)) end)
    return wd ~= nil
end

-- Unrevealed secret door at world x,y (cell NAME check; reveals rewrite the
-- cell so revealed ones drop out naturally).
function M.secret_door_at(x, y)
    local map = M.game_map()
    local mx, my = M.to_map(x, y)
    if not map or not mx then return false end
    local ok, data = pcall(map.getCellDataAtMapXYZeroIndexed, map, mx, my)
    if not ok or not data then return false end
    return (CCellData and CCellData.cellIsSecretDoor and CCellData.cellIsSecretDoor[data.name]) and true or false
end

-- Roots a revealed trap can wear; an fnTrap trigger on any other root is
-- still hidden.
local REVEALED_TRAP_ROOTS = {
    trapSpikesOn = true, trapSpikesOff = true, trapdoorOpen = true,
    trapdoorClosed = true, fireTrapOff = true, fire = true, embers = true,
    deadEmbers = true, amberTrapOn = true, amberTrapOff = true,
}

function M.trap_revealed_root(root)
    return root and REVEALED_TRAP_ROOTS[root] or false
end

-- Area exits: walkable tiles on the current world's boundary (stepping past
-- them leaves the zoom/town — visually the world just ends there). Adjacent
-- boundary tiles MERGE into one exit per contiguous run, anchored at the
-- run tile that connects to the interior (nearest run-center among tiles
-- with an inward walkable neighbor). A run sealed off from the inside is
-- not an exit. Returns { {x, y, width, edge, key, tiles} ... }.
function M.area_exits()
    if not G_stateGame then return {} end
    local wd = G_stateGame.currentWorldData
    if not wd or G_stateGame.currentWorldName == "Overworld" then return {} end
    local minX, maxX, minY, maxY = wd.minX, wd.maxX, wd.minY, wd.maxY
    if not (minX and maxX and minY and maxY) then return {} end

    local exits = {}
    local function scan_edge(edge, x0, y0, sx, sy, len, ix, iy)
        local run = nil
        for i = 0, len do
            local x, y = x0 + sx * i, y0 + sy * i
            local walk = M.walkable(x, y) == true
            if walk then
                run = run or {}
                run[#run + 1] = { x = x, y = y }
            end
            if run and (not walk or i == len) then
                local best, mid = nil, (#run + 1) / 2
                for j, t in ipairs(run) do
                    if M.walkable(t.x + ix, t.y + iy) == true then
                        if not best or math.abs(j - mid) < math.abs(best.j - mid) then
                            best = { j = j, t = t }
                        end
                    end
                end
                if best then
                    exits[#exits + 1] = {
                        x = best.t.x, y = best.t.y, width = #run, edge = edge,
                        key = edge .. ":" .. run[1].x .. "," .. run[1].y .. "x" .. #run,
                        tiles = run,
                    }
                end
                run = nil
            end
        end
    end
    scan_edge("north", minX, minY, 1, 0, maxX - minX, 0, 1)
    scan_edge("south", minX, maxY, 1, 0, maxX - minX, 0, -1)
    scan_edge("west", minX, minY, 0, 1, maxY - minY, 1, 0)
    scan_edge("east", maxX, minY, 0, 1, maxY - minY, -1, 0)
    return exits
end

-- Object roots: one physical thing the player interacts with. The game
-- models these as root + one or more triggers (a locked chest is root
-- chestLocked + a `container` trigger for contents + a `locked_chest`
-- trigger for the lock); for speech they merge into ONE entry.
local OBJECT_ROOTS = {
    chestClosed = true, chestOpen = true, chestLocked = true,
    crateClosed = true, crateOpen = true, crateHuge = true,
    crateHugeOpen = true, crateHugeBroken = true,
    barrelClosed = true, barrelOpen = true,
    bookshelf = true, bookshelfSearched = true, bookshelfEmpty = true,
}
local SKIP_ACTIONS = { playerStart = true, firewall = true, tutorial = true, mon = true }

-- Display name for an object TYPE string (trigger data fields, ground
-- pickups). The visible pickup IS the object, so naming it is parity.
function M.object_name(object_type)
    if not object_type then return nil end
    local od = G_stateGame and G_stateGame.objectData and G_stateGame.objectData[object_type]
    local name = od and od.name
    if name and name ~= "" and name ~= "NA" then return tostring(name) end
    return tostring(object_type)
end

local function trigger_actions_at(x, y)
    local actions = {}
    if not (G_stateGame and G_stateGame.triggerData and G_stateGame.currentWorldName) then return actions end
    local ok, list = pcall(G_stateGame.triggerData.getAllTriggersOnLevelAtXYZeroIndexed,
        G_stateGame.triggerData, G_stateGame.currentWorldName, x, y)
    if ok and type(list) == "table" then
        for _, t in ipairs(list) do
            if t and t.action then
                actions[#actions + 1] = tostring(t.action)
                -- "object" pickups carry their item type in data.
                if tostring(t.action) == "object" then
                    actions[#actions] = "object:" .. tostring(t.data)
                end
            end
        end
    end
    return actions
end

-- Spoken names for the things on a tile. An object root absorbs its own
-- triggers into one entry (the game's display name — which already carries
-- lock state — plus modifiers it doesn't). Non-object tiles list trigger
-- names individually. NEVER exposes trigger data fields (contents / which
-- key): sighted players can't see inside either.
-- Returns names(list), merged(bool — an object entry absorbed the tile).
function M.tile_things(x, y)
    local root = M.root(x, y)
    local actions = trigger_actions_at(x, y)
    if root and OBJECT_ROOTS[root] then
        local base = M.root_name(root) or "container"
        local lower = base:lower()
        local mods = {}
        for _, a in ipairs(actions) do
            if a == "locked_chest" then
                if not lower:find("locked") then mods[#mods + 1] = "locked" end
            elseif a == "container" then
                -- implied by the object itself
            elseif a == "search" then mods[#mods + 1] = "searchable"
            elseif a == "read" then mods[#mods + 1] = "readable"
            elseif a == "warp" then mods[#mods + 1] = "passage"
            elseif not SKIP_ACTIONS[a] then mods[#mods + 1] = a end
        end
        local m = require("ma_mb").new():list_item(base)
        for _, mod in ipairs(mods) do m:list_item(mod) end
        return { m:build() }, true
    end
    local names = {}
    for _, a in ipairs(actions) do
        if a == "read" then names[#names + 1] = "something readable"
        elseif a == "search" then names[#names + 1] = "searchable spot"
        elseif a == "warp" then names[#names + 1] = "passage"
        elseif a == "container" then names[#names + 1] = "container"
        elseif a == "locked_chest" then names[#names + 1] = "locked container"
        elseif a:sub(1, 7) == "object:" then
            names[#names + 1] = M.object_name(a:sub(8))
        elseif not SKIP_ACTIONS[a] and not M.is_location_action(a) then
            names[#names + 1] = a
        end
    end
    return names, false
end

-- Overworld icon-family things AT a tile (gatherables via the game's own
-- predicates; prey prints while the player is within the game's print
-- range; the fish ripple). Used by the exploration cursor so arrowing the
-- world map reads what the icons show.
local GATHER = {
    { fn = "isHerbAtWorldXY", name = "herb" },
    { fn = "isBerryAtWorldXY", name = "berries" },
    { fn = "isKindlingAtWorldXY", name = "kindling" },
    { fn = "isTearAtWorldXY", name = "something odd" },
    { fn = "isWitchesHerbAtWorldXY", name = "strange plant" },
}

-- Gatherables at an Overworld tile — but ONLY when the game would currently
-- reveal them. Sighted players never see gatherables at range: the game
-- sparkles them per step (performOverworldFeatureCheck) only when ADJACENT —
-- herbs/berries/tears/strange plants in the 8 surrounding tiles, kindling
-- only cardinally. Reporting any wider would be information sighted players
-- don't have. Out of reveal range: empty.
function M.gatherables_at(x, y)
    local names = {}
    if not G_stateGame or tostring(G_stateGame.currentWorldName) ~= "Overworld" then return names end
    local p = M.player()
    if not p or not p.position then return names end
    local adx = math.abs(x - p.position.x)
    local ady = math.abs(y - p.position.y)
    if math.max(adx, ady) > 1 then return names end
    local cardinal = adx + ady <= 1   -- NSEW neighbor or underfoot
    for _, g in ipairs(GATHER) do
        if (g.fn ~= "isKindlingAtWorldXY" or cardinal)
            and type(G_stateGame[g.fn]) == "function" then
            local ok, hit = pcall(G_stateGame[g.fn], G_stateGame, x, y)
            if ok and hit then names[#names + 1] = g.name end
        end
    end
    return names
end

-- All currently-revealed gatherables around the player, as {name, dx, dy}.
function M.gatherable_reveals(px, py)
    local list = {}
    if not G_stateGame or tostring(G_stateGame.currentWorldName) ~= "Overworld" then return list end
    for dy = -1, 1 do
        for dx = -1, 1 do
            for _, n in ipairs(M.gatherables_at(px + dx, py + dy)) do
                list[#list + 1] = { name = n, dx = dx, dy = dy }
            end
        end
    end
    return list
end

function M.overworld_icons_at(x, y)
    if not G_stateGame or tostring(G_stateGame.currentWorldName) ~= "Overworld" then return {} end
    local names = M.gatherables_at(x, y)
    pcall(function()
        local p = M.player()
        local range = (G_Globals and G_Globals.huntDetectionDistanceWolf) or 8
        local function check(animal)
            if animal and animal.position and animal.position.x == x and animal.position.y == y then
                local d = math.max(math.abs(x - p.position.x), math.abs(y - p.position.y))
                if d < range then names[#names + 1] = "hoofprints" end
            end
        end
        check(playerStats.foodAnimal)
        local alive = true
        pcall(function() alive = not G_stateGame.speechArea:isPropertyNonZero("killed_sleathen") end)
        if alive then check(playerStats.sleathen) end
    end)
    pcall(function()
        if playerStats.isFishPresent and playerStats.fishPositionX == x
            and playerStats.fishPositionY == y then
            names[#names + 1] = "water ripples"
        end
    end)
    return names
end

-- Is this tile a walkable boundary tile (part of some exit run)? Returns the
-- edge name(s) or nil. Cheap point query for the cursor — no run merging.
function M.area_exit_edge_at(x, y)
    if not G_stateGame then return nil end
    local wd = G_stateGame.currentWorldData
    if not wd or G_stateGame.currentWorldName == "Overworld" then return nil end
    local minX, maxX, minY, maxY = wd.minX, wd.maxX, wd.minY, wd.maxY
    if not (minX and maxX and minY and maxY) then return nil end
    if x < minX or x > maxX or y < minY or y > maxY then return nil end
    local edges = {}
    if y == minY then edges[#edges + 1] = "north" end
    if y == maxY then edges[#edges + 1] = "south" end
    if x == minX then edges[#edges + 1] = "west" end
    if x == maxX then edges[#edges + 1] = "east" end
    if #edges == 0 then return nil end
    if M.walkable(x, y) ~= true then return nil end
    return table.concat(edges, " ")
end

-- Path shape naming: Factorio Access's pipe shape verbalization (fa-info.lua
-- ent_info_pipe_shape + entity-info.cfg locale). Straights are vertical or
-- horizontal; an end is named for the side the stub FACES (connected north =
-- "south end"); corners list the vertical connection then the horizontal;
-- a T is its through-line plus the branch direction. Returns (text, key):
-- key is a stable differential token so walkers and the cursor speak only
-- shape CHANGES — following a road is silent until it bends or branches.
local PATH_ROOTS = { path = true, bridge = true }
local OPPOSITE = { north = "south", south = "north", east = "west", west = "east" }

function M.path_shape_text(x, y)
    local root = M.root(x, y)
    if not root or not PATH_ROOTS[root] then return nil end
    local label = root == "bridge" and "Bridge" or "Path"
    local n = PATH_ROOTS[M.root(x, y - 1)] or false
    local s = PATH_ROOTS[M.root(x, y + 1)] or false
    local e = PATH_ROOTS[M.root(x + 1, y)] or false
    local w = PATH_ROOTS[M.root(x - 1, y)] or false

    local key = "path:" .. (n and "n" or "") .. (e and "e" or "")
        .. (s and "s" or "") .. (w and "w" or "")
    local count = (n and 1 or 0) + (s and 1 or 0) + (e and 1 or 0) + (w and 1 or 0)

    if count == 0 then return label .. ", lonely", key end
    if count == 1 then
        local conn = n and "north" or s and "south" or e and "east" or "west"
        return label .. ", " .. OPPOSITE[conn] .. " end", key
    end
    if count == 2 then
        if n and s then return label .. ", vertical", key end
        if e and w then return label .. ", horizontal", key end
        local vert = n and "north" or "south"
        local horiz = e and "east" or "west"
        return label .. ", corner " .. vert .. " and " .. horiz, key
    end
    if count == 3 then
        if n and s then
            return label .. ", vertical and " .. (e and "east" or "west"), key
        end
        return label .. ", horizontal and " .. (n and "north" or "south"), key
    end
    return label .. ", cross", key
end

-- Light emitted by the CELL at x,y (torches, glowing mushrooms, crystal
-- lights...). The game's own lightRadius field — the same number
-- isNextToLight uses for the sneak detection penalty. 0 = dark cell.
function M.light_radius_at(x, y)
    local map = M.game_map()
    local mx, my = M.to_map(x, y)
    if not map or not mx then return 0 end
    local ok, data = pcall(map.getCellDataAtMapXYZeroIndexed, map, mx, my)
    if not ok or not data then return 0 end
    return tonumber(data.lightRadius) or 0
end

-- Is the cell at world x,y covered by amber fog? (Standing in amber accrues
-- the "mad" status; the field drifts with the wind.) Unknown/out-of-window
-- reads as false.
function M.is_amber(x, y)
    local map = M.game_map()
    local mx, my = M.to_map(x, y)
    if not map or not mx then return false end
    local ok, v = pcall(map.getIsAmberOnMapXYZeroIndexed, map, mx, my)
    return (ok and v) and true or false
end

function M.creature_at(x, y)
    local am = G_stateGame and G_stateGame.actorManager
    if not am then return nil end
    local ok, c = pcall(am.getCreatureAtWorldXY, am, x, y)
    return ok and c or nil
end

-- "Blocked for walking" with unknown treated as blocked (safe for echo/shape).
function M.blocked(x, y)
    local w = M.walkable(x, y)
    if w == nil then return true end
    return not w
end

return M
