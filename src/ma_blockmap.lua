-- ma_blockmap.lua — the dungeon map as a grid of 9x9-cell block summaries.
--
-- Why 9: the game's Wang-tile generator (state_game_dungeon_chunks.lua)
-- assembles every non-fixed dungeon from 18x9 chunks placed on 9-cell
-- half-chunk boundaries, with a deterministic origin: sx = floor(96/2) -
-- floor((8*9)/2) - 2 = 10. Blocks anchored there line up with the
-- generator's half-chunks, so a summary cell is usually one authored room
-- (or half of one). Hand-authored "fixed" dungeons don't follow the grid;
-- for those the world rect is simply partitioned into 9-cell blocks.
--
-- PARITY: everything here is derived from cell.isRemembered — exactly the
-- gate the game's own drawn dungeon map uses (createDungeonMapImage skips
-- unremembered cells). Secret doors are treated as walls, as drawn. The
-- locked-door "you have the key" distinction copies the drawn map's
-- inventory check verbatim.
--
-- Coordinates are 0-indexed map-window coords throughout (in dungeons the
-- window doesn't slide; ma_map.from_map converts back to world for the
-- cursor jump).

local M = {}

local BLOCK = 9
local WANG_ORIGIN = 10   -- generator's sx/sy; verify against a live dungeon
local WANG_BLOCKS = 8

local LOCKED_DOOR = { doorLocked = true, doorLocked2 = true, doorMetal = true,
    gateLocked = true }
local POI = { plateOff = true, bell = true, bellRinging = true }

-- The block grid for the current world, or nil when this world has no
-- dungeon map (the map key shows the overworld map instead).
function M.grid()
    local g = G_stateGame
    if not g then return nil end
    local wd = g.currentWorldData
    if not (wd and wd.dungeonType) then return nil end

    local generated = wd.is100LevelDungeon and true or false
    if not generated then
        pcall(function()
            local dd = require("dungeon_data")
            generated = dd.getData(wd.dungeonType) ~= nil
        end)
    end

    if generated then
        return {
            x0 = WANG_ORIGIN, y0 = WANG_ORIGIN,
            bw = WANG_BLOCKS, bh = WANG_BLOCKS,
            max_x = WANG_ORIGIN + WANG_BLOCKS * BLOCK - 1,
            max_y = WANG_ORIGIN + WANG_BLOCKS * BLOCK - 1,
        }
    end

    -- Fixed (hand-authored) dungeon: partition the declared world rect.
    local x0, y0 = wd.minX or 0, wd.minY or 0
    local mx, my = wd.maxX or 95, wd.maxY or 95
    return {
        x0 = x0, y0 = y0,
        bw = math.ceil((mx - x0 + 1) / BLOCK),
        bh = math.ceil((my - y0 + 1) / BLOCK),
        max_x = mx, max_y = my,
    }
end

local function block_rect(grid, bx, by)
    local x1 = grid.x0 + (bx - 1) * BLOCK
    local y1 = grid.y0 + (by - 1) * BLOCK
    return x1, y1, math.min(x1 + BLOCK - 1, grid.max_x),
        math.min(y1 + BLOCK - 1, grid.max_y)
end

-- The block the player stands in, or nil.
function M.player_block(grid)
    local ma_map = require("ma_map")
    local p = ma_map.player()
    if not (p and p.position) then return nil end
    local mx, my = ma_map.to_map(p.position.x, p.position.y)
    if not mx then return nil end
    local bx = math.floor((mx - grid.x0) / BLOCK) + 1
    local by = math.floor((my - grid.y0) / BLOCK) + 1
    if bx < 1 or bx > grid.bw or by < 1 or by > grid.bh then return nil end
    return bx, by
end

-- Potential passability of a cell for side connectivity: nil = not yet
-- remembered (unknown), false = wall (secret doors included, as drawn),
-- true = walkable now or after an interaction (any door or gate).
local function pass_at(gm, x, y)
    local cell = gm:getCellXYZeroIndexed(x, y)
    if not cell or not cell.isRemembered then return nil end
    local cd = gm:getCellDataAtMapXYZeroIndexed(x, y)
    if not cd then return false end
    if CCellData.cellIsSecretDoor[cd.name] then return false end
    if cd.isWalkable or CCellData.cellIsDoor[cd.name] then return true end
    return false
end

-- Classify one boundary crossing (both cells passable): the door wins over
-- plain floor, a locked door over a plain one.
local function crossing(g, gm, x1, y1, x2, y2, side)
    for _, pt in ipairs({ { x1, y1 }, { x2, y2 } }) do
        local cd = gm:getCellDataAtMapXYZeroIndexed(pt[1], pt[2])
        local name = cd and cd.name
        if name and CCellData.cellIsDoor[name]
            and name ~= "doorOpen" and name ~= "gateOpen" then
            if LOCKED_DOOR[name] then
                local trig = g.triggerData:getFirstTriggerOnLevelWithActionNameAtXYZeroIndexed(
                    g.currentWorldName, pt[1], pt[2], "locked_door")
                local player = g.actorManager and g.actorManager.player
                if trig and player and player:findInventoryObjectWithName(trig.data) then
                    side.locked_key = true
                elseif trig then
                    side.locked = true
                else
                    side.door = true   -- trigger missing: drawn as a plain door
                end
            else
                side.door = true
            end
            return
        end
    end
    side.open = true
end

-- Scan one side of a block. dx,dy point OUTWARD toward the neighbor.
--
-- Two signals, both parity-clean (derived from remembered cells only):
--   CROSSING: a remembered passable pair straddling the block boundary —
--     classified open/door/locked by the cells involved.
--   FRONTIER: any remembered passable cell in the block whose neighbor in
--     this direction is not yet remembered — the explored region has an
--     open edge facing this way (a corridor or room mouth running into
--     darkness on the drawn map). Corridors often go dark a cell or two
--     before the boundary row, so this must scan the whole block, not
--     just the boundary line.
local function scan_side(g, gm, x1, y1, x2, y2, dx, dy)
    local side = {}
    local boundary_x = dx == -1 and x1 or dx == 1 and x2 or nil
    local boundary_y = dy == -1 and y1 or dy == 1 and y2 or nil
    for y = y1, y2 do
        for x = x1, x2 do
            if pass_at(gm, x, y) then
                local fx, fy = x + dx, y + dy
                local far = pass_at(gm, fx, fy)
                if far == nil then
                    side.frontier = true
                elseif far and (x == boundary_x or y == boundary_y) then
                    crossing(g, gm, x, y, fx, fy, side)
                end
            end
        end
    end
    if side.open or side.door or side.locked or side.locked_key or side.frontier then
        return side
    end
    return nil
end

-- Summarize block (bx, by). Returns nil when the game map is unavailable.
-- {
--   total, remembered, passable, frac, unexplored, solid,
--   water, lava, void,
--   feats = { [name] = { count, x, y } },   -- first-found coords per feature
--   sides = { north/east/south/west = { open, door, locked, locked_key,
--             frontier } or nil },          -- nil = no potential passage
--   best = { x, y } or nil,                 -- cursor-jump target
-- }
function M.summarize(grid, bx, by)
    local g = G_stateGame
    local gm = g and g.map
    if not gm then return nil end

    local ok, res = pcall(function()
        local x1, y1, x2, y2 = block_rect(grid, bx, by)
        local s = { total = 0, remembered = 0, passable = 0,
            water = false, lava = false, void = false,
            feats = {}, sides = {} }

        local function feat(name, x, y)
            local f = s.feats[name]
            if not f then s.feats[name] = { count = 1, x = x, y = y }
            else f.count = f.count + 1 end
        end

        local cx = (x1 + x2) / 2
        local cy = (y1 + y2) / 2
        local center, center_d

        local player = g.actorManager and g.actorManager.player
        for y = y1, y2 do
            for x = x1, x2 do
                s.total = s.total + 1
                local cell = gm:getCellXYZeroIndexed(x, y)
                if cell and cell.isRemembered then
                    s.remembered = s.remembered + 1
                    local cd = gm:getCellDataAtMapXYZeroIndexed(x, y)
                    local name = cd and cd.name
                    if cd then
                        local secret = CCellData.cellIsSecretDoor[name]
                        local door = CCellData.cellIsDoor[name] and not secret
                        if cd.isWalkable or door then
                            s.passable = s.passable + 1
                            local d = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                            if not center_d or d < center_d then
                                center_d = d
                                center = { x = x, y = y }
                            end
                        end
                        if cell.isSea or cell.isPuddle then s.water = true end
                        if cell.isLava then s.lava = true end
                        if cell.isVoid then s.void = true end

                        if name == "stairsUp" then feat("stairs up", x, y)
                        elseif name == "stairsDown" or name == "floorDoor" then
                            feat("stairs down", x, y)
                        elseif CCellData.cellIsChest[name] then feat("chest", x, y)
                        elseif CCellData.cellIsTeleport[name] then feat("warp", x, y)
                        elseif POI[name] then feat("point of interest", x, y)
                        elseif door and LOCKED_DOOR[name] then
                            -- The drawn map's key check, verbatim.
                            local trig = g.triggerData:getFirstTriggerOnLevelWithActionNameAtXYZeroIndexed(
                                g.currentWorldName, x, y, "locked_door")
                            if trig and player and player:findInventoryObjectWithName(trig.data) then
                                feat("locked door, have the key", x, y)
                            elseif trig then feat("locked door", x, y)
                            else feat("door", x, y) end
                        elseif door and name ~= "doorOpen" and name ~= "gateOpen" then
                            feat("door", x, y)
                        end
                    end
                end
            end
        end

        s.frac = s.total > 0 and s.remembered / s.total or 0
        s.unexplored = s.remembered == 0
        s.solid = s.remembered > 0 and s.passable == 0

        if not s.unexplored then
            if by > 1 then s.sides.north = scan_side(g, gm, x1, y1, x2, y2, 0, -1) end
            if by < grid.bh then s.sides.south = scan_side(g, gm, x1, y1, x2, y2, 0, 1) end
            if bx > 1 then s.sides.west = scan_side(g, gm, x1, y1, x2, y2, -1, 0) end
            if bx < grid.bw then s.sides.east = scan_side(g, gm, x1, y1, x2, y2, 1, 0) end
        end

        -- Cursor-jump target: the most navigation-worthy feature, else the
        -- centermost passable cell.
        for _, name in ipairs({ "stairs down", "stairs up",
            "locked door, have the key", "locked door", "warp", "chest",
            "point of interest", "door" }) do
            local f = s.feats[name]
            if f then s.best = { x = f.x, y = f.y }; break end
        end
        s.best = s.best or center

        return s
    end)
    return ok and res or nil
end

-- How many blocks have at least one remembered cell (the map-open count).
function M.seen_count(grid)
    local g = G_stateGame
    local gm = g and g.map
    if not gm then return 0, grid.bw * grid.bh end
    local seen = 0
    pcall(function()
        for by = 1, grid.bh do
            for bx = 1, grid.bw do
                local x1, y1, x2, y2 = block_rect(grid, bx, by)
                local found = false
                for y = y1, y2 do
                    for x = x1, x2 do
                        local cell = gm:getCellXYZeroIndexed(x, y)
                        if cell and cell.isRemembered then found = true; break end
                    end
                    if found then break end
                end
                if found then seen = seen + 1 end
            end
        end
    end)
    return seen, grid.bw * grid.bh
end

return M
