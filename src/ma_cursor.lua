-- ma_cursor.lua — the exploration cursor: a second, always-live tile cursor
-- decoupled from the player (Tanglebeep's ExplorationCursor).
--
-- Design rules carried over: speech is DIFFERENTIAL (a step speaks what
-- changed; occupants and triggers always); a sound ALWAYS plays even when
-- speech is silent (passability cue, entity cue stacked); visibility follows
-- the map memory — explored-but-not-visible reads "blurred" once at the
-- boundary, unexplored reads "unexplored"; follow mode re-homes the cursor to
-- the player each game TURN (not each frame), so a mid-turn peek persists.
--
-- Keys (wired in ma_input): arrows / numpad 8-4-6-2 step; Shift+step skips
-- until the tile kind changes; numpad 5 full read; numpad 0 recenter.

local hooks = require("ma_hooks")
local speech = require("ma_speech")
local text = require("ma_text")
local map = require("ma_map")
local shapes = require("ma_shapes")
local synth = require("ma_synth")
local MB = require("ma_mb")

local st = hooks.state
st.cursor = st.cursor or {}
local C = st.cursor

local M = {}

local RANGE = 30   -- max Chebyshev distance from the player

local DIRS = {
    up = { dx = 0, dy = -1 }, down = { dx = 0, dy = 1 },
    left = { dx = -1, dy = 0 }, right = { dx = 1, dy = 0 },
}

local function player_pos()
    local p = map.player()
    if not p or not p.position then return nil end
    return p.position.x, p.position.y
end

local function ensure()
    if C.x then return true end
    local px, py = player_pos()
    if not px then return false end
    C.x, C.y = px, py
    return true
end

-- Visibility class: "visible" | "blurred" | "unexplored"
local function vis_class(x, y)
    if map.visible(x, y) then return "visible" end
    if map.remembered(x, y) then return "blurred" end
    return "unexplored"
end

-- The differential key of a tile: what must change for a step to speak.
-- Path shape is part of the key, so skip-stepping a road stops at corners,
-- junctions, and ends — Shift+arrow follows the road to its next decision.
local function tile_key(x, y)
    local vis = vis_class(x, y)
    if vis == "unexplored" then return "unexplored" end
    local _, shape_key = map.path_shape_text(x, y)
    return tostring(map.root(x, y)) .. "|" .. tostring(shape_key) .. "|" .. vis
        .. (map.is_amber(x, y) and "|amber" or "")
end

local function triggers_at(x, y)
    -- Reuse ma_app's trigger naming through a tiny local copy to avoid a
    -- circular require: ma_app requires nothing from us.
    local names = {}
    if not (G_stateGame and G_stateGame.triggerData and G_stateGame.currentWorldName) then return names end
    local ok, list = pcall(G_stateGame.triggerData.getAllTriggersOnLevelAtXYZeroIndexed,
        G_stateGame.triggerData, G_stateGame.currentWorldName, x, y)
    if not ok or type(list) ~= "table" then return names end
    local SKIP = { playerStart = true, firewall = true, tutorial = true, mon = true,
        fnUp = true, fnDown = true, fnTeleport = true, fnTrap = true,
        fnYellDouseAltar = true,
        teleportPosition = true, fallPosition = true }
    for _, t in ipairs(list) do
        local a = t and t.action
        if a == "read" then names[#names + 1] = "something readable"
        elseif a == "search" then names[#names + 1] = "searchable spot"
        elseif a == "warp" then names[#names + 1] = "passage"
        elseif a == "object" then names[#names + 1] = map.object_name(t.data) or "item"
        elseif a and not SKIP[a] and not map.is_location_action(a) then
            names[#names + 1] = tostring(a)
        end
    end
    return names
end

local function shape_at(x, y)
    return shapes.describe(function(dx, dy) return map.blocked(x + dx, y + dy) end)
end

-- Sound for the tile: always plays, stacking the entity cue on top.
local function play_tile_cues(x, y)
    local vis = vis_class(x, y)
    if vis == "unexplored" then
        synth.cue("cursor_unexplored")
        return
    end
    if map.creature_at(x, y) then
        synth.cue("cursor_entity")
    elseif map.blocked(x, y) then
        synth.cue("cursor_wall")
    else
        synth.cue("cursor_ground")
    end
end

-- Describe the tile into the passed builder as comma-separated list items.
-- full=true reads everything; differential reads only changes vs C.last_*
-- plus occupants/triggers.
local function describe(m, x, y, full)
    local vis = vis_class(x, y)

    if vis == "unexplored" then
        if full or C.last_vis ~= "unexplored" then m:list_item("unexplored") end
        C.last_vis = "unexplored"
        C.last_root = nil
        C.last_shape = nil
        C.last_amber = nil
        return
    end

    -- Object tiles merge root + triggers into one name ("Chest (locked)");
    -- path tiles speak their shape ("Path corner, north and east"); other
    -- tiles speak the plain root, with trigger names as extras below.
    local root = map.root(x, y)
    local things, merged = map.tile_things(x, y)
    local shape_text, shape_key = map.path_shape_text(x, y)
    if full or root ~= C.last_root or shape_key ~= C.last_pathkey then
        if merged then m:list_item(things[1])
        elseif shape_text then m:list_item(shape_text)
        else m:list_item(map.root_label(x, y, root)) end
    end
    C.last_root = root
    C.last_pathkey = shape_key

    -- Amber fog is drawn on any remembered tile, so any tile we narrate here
    -- may carry it (parity-safe: the unexplored branch above returned already).
    -- Differential on both edges — the boundary of the field matters as much
    -- as its presence.
    local amber = map.is_amber(x, y)
    if amber then
        if full or not C.last_amber then m:list_item("amber fog") end
    elseif C.last_amber and not full then
        m:list_item("fog clear")
    end
    C.last_amber = amber

    -- Hazards hidden in the wall vocabulary: always spoken, never
    -- differential — the same rule as the walker (remembered-gated inside).
    local lava, void = map.near_hazards(x, y)
    if lava then m:list_item("near lava") end
    if void then m:list_item("near void") end

    local occupant = map.creature_at(x, y)
    if occupant then
        if occupant.isPlayer then
            m:list_item("you")   -- the overworld player actor has no display name
        else
            local ok, name = pcall(occupant.getDisplayName, occupant)
            m:list_item(ok and name or "creature")
            if occupant.health and occupant.maxHealth and occupant.maxHealth > 0 then
                m:list_item(math.floor(occupant.health / occupant.maxHealth * 100 + 0.5)
                    .. " percent")
            end
        end
    end
    if not merged then
        for _, tn in ipairs(things) do m:list_item(tn) end
    end

    -- Landmark tier, always spoken: standing on a walkable boundary tile
    -- means stepping outward here leaves the area.
    local exit_edge = map.area_exit_edge_at(x, y)
    if exit_edge then m:list_item("area exit " .. exit_edge) end

    -- Overworld icons (herbs, berries, kindling, prints, ripples) at the
    -- cursor tile — arrowing the world map reads what the icons show.
    for _, n in ipairs(map.overworld_icons_at(x, y)) do
        m:list_item(n)
    end

    -- Shape vocabulary (hallway/corner/dead end) only makes sense on a tile
    -- you could stand on. On a blocked tile the useful inverse is which way
    -- the wall continues.
    local shape
    if map.blocked(x, y) then
        local runs = {}
        if map.blocked(x, y - 1) then runs[#runs + 1] = "north" end
        if map.blocked(x, y + 1) then runs[#runs + 1] = "south" end
        if map.blocked(x - 1, y) then runs[#runs + 1] = "west" end
        if map.blocked(x + 1, y) then runs[#runs + 1] = "east" end
        if #runs > 0 and #runs < 4 then
            shape = "continues " .. table.concat(runs, " and ")
        elseif #runs == 0 then
            shape = "isolated"
        end
        -- all four blocked: interior of a mass, say nothing
    else
        shape = shape_at(x, y)
    end
    if shape and (full or shape ~= C.last_shape) then m:list_item(shape) end
    C.last_shape = shape

    if vis == "blurred" and (full or C.last_vis ~= "blurred") then
        m:list_item("blurred")
    end
    C.last_vis = vis
end

function M.step(dir, skip)
    if not ensure() then return end
    local d = DIRS[dir]
    if not d then return end
    local px, py = player_pos()

    local function try_step()
        local nx, ny = C.x + d.dx, C.y + d.dy
        if px and text.dist(nx - px, ny - py) > RANGE then return false end
        C.x, C.y = nx, ny
        return true
    end

    if not skip then
        if not try_step() then
            synth.cue("bonk")
            return
        end
        play_tile_cues(C.x, C.y)
        local m = MB.new()
        describe(m, C.x, C.y, false)
        speech.say(m, true)
        return
    end

    -- Skip: run until the tile kind changes, an occupant/trigger appears, or
    -- the range limit stops us.
    local start_key = tile_key(C.x, C.y)
    local steps = 0
    while steps < RANGE do
        if not try_step() then break end
        steps = steps + 1
        if tile_key(C.x, C.y) ~= start_key
            or map.creature_at(C.x, C.y)
            or #triggers_at(C.x, C.y) > 0 then
            break
        end
    end
    play_tile_cues(C.x, C.y)
    local m = MB.new():list_item("skipped " .. steps)
    describe(m, C.x, C.y, true)
    speech.say(m, true)
end

function M.read()
    if not ensure() then return end
    local px, py = player_pos()
    play_tile_cues(C.x, C.y)
    local m = MB.new()
    describe(m, C.x, C.y, true)
    -- Offsets are always LAST in an utterance (hard rule).
    if px then m:list_item(text.offset(C.x - px, C.y - py)) end
    speech.say(m, true)
end

function M.recenter(silent)
    local px, py = player_pos()
    if not px then return end
    C.x, C.y = px, py
    C.last_root, C.last_shape, C.last_vis, C.last_amber = nil, nil, nil, nil
    if not silent then
        local m = MB.new():fragment("Cursor on you"):sentence()
        describe(m, C.x, C.y, true)
        speech.say(m, true)
    end
end

-- Point the cursor somewhere (the scanner's goto) and read it fully.
function M.jump_to(x, y)
    if not ensure() then return end
    C.x, C.y = x, y
    M.read()
end

-- Follow: re-home to the player when a game turn passed, and ALWAYS on a
-- world transition (stale cross-world coordinates are meaningless).
function M.follow_tick()
    if not G_stateGame then return end
    local world = G_stateGame.currentWorldName
    local turns = G_stateGame.playerTurns or 0
    if C.follow_turn ~= turns or C.world ~= world then
        C.follow_turn = turns
        C.world = world
        local px, py = player_pos()
        if px and (C.x ~= px or C.y ~= py) then
            C.x, C.y = px, py
            C.last_root, C.last_shape, C.last_vis, C.last_amber = nil, nil, nil, nil
        end
    end
end

return M
