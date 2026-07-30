-- ma_shapes.lua — classify the walls around a tile into a spoken shape
-- ("dead end, open north", "northwest corner", "east-west hallway"), the
-- Tanglebeep TileShapes idea reduced to cardinal walls: Moonring movement is
-- strictly 4-way, so the four cardinals carry the navigable truth.
--
-- blocked(dx, dy) is injected so the same classifier serves the exploration
-- cursor and the wall echo with whatever passability rule the caller wants.

local M = {}

local DIRS = {
    { name = "north", dx = 0, dy = -1 },
    { name = "east",  dx = 1, dy = 0 },
    { name = "south", dx = 0, dy = 1 },
    { name = "west",  dx = -1, dy = 0 },
}

-- Returns a spoken shape, or nil for fully open (silence is the open cue).
function M.describe(blocked)
    local walls, open = {}, {}
    for _, d in ipairs(DIRS) do
        if blocked(d.dx, d.dy) then walls[#walls + 1] = d.name
        else open[#open + 1] = d.name end
    end

    local n = #walls
    if n == 0 then return nil end
    if n == 4 then return "enclosed" end
    if n == 3 then return "dead end, open " .. open[1] end
    if n == 1 then return "wall " .. walls[1] end

    -- Two walls: opposite = hallway, adjacent = corner.
    local w = { [walls[1]] = true, [walls[2]] = true }
    if w.north and w.south then return "east-west hallway" end
    if w.east and w.west then return "north-south hallway" end
    local ns = w.north and "north" or "south"
    local ew = w.east and "east" or "west"
    return ns .. ew .. " corner"
end

return M
