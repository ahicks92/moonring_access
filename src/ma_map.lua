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
