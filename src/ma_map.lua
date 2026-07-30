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

local function trigger_actions_at(x, y)
    local actions = {}
    if not (G_stateGame and G_stateGame.triggerData and G_stateGame.currentWorldName) then return actions end
    local ok, list = pcall(G_stateGame.triggerData.getAllTriggersOnLevelAtXYZeroIndexed,
        G_stateGame.triggerData, G_stateGame.currentWorldName, x, y)
    if ok and type(list) == "table" then
        for _, t in ipairs(list) do
            if t and t.action then actions[#actions + 1] = tostring(t.action) end
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
        local name = base
        if #mods > 0 then name = name .. ", " .. table.concat(mods, ", ") end
        return { name }, true
    end
    local names = {}
    for _, a in ipairs(actions) do
        if a == "read" then names[#names + 1] = "something readable"
        elseif a == "search" then names[#names + 1] = "searchable spot"
        elseif a == "warp" then names[#names + 1] = "passage"
        elseif a == "container" then names[#names + 1] = "container"
        elseif a == "locked_chest" then names[#names + 1] = "locked container"
        elseif not SKIP_ACTIONS[a] then names[#names + 1] = a end
    end
    return names, false
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
