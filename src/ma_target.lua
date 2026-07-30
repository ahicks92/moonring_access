-- ma_target.lua — voice the game's targeting modes (read-only: the GAME owns
-- the targeting keys; the world is frozen while targeting, so speaking on
-- every cursor move is safe).
--
-- Location mode: player.targetedOffset moves — speak what's under the cursor
-- (creature + health, else terrain), with the offset. Direction mode: speak
-- the aimed compass direction.

local hooks = require("ma_hooks")
local speech = require("ma_speech")
local text = require("ma_text")
local map = require("ma_map")

local st = hooks.state
st.target = st.target or {}
local T = st.target

local M = {}

local function describe_target(x, y, dx, dy)
    local parts = {}
    local c = map.creature_at(x, y)
    if c then
        local ok, name = pcall(c.getDisplayName, c)
        local label = ok and name or "creature"
        if c.health and c.maxHealth and c.maxHealth > 0 then
            label = label .. ", " .. math.floor(c.health / c.maxHealth * 100 + 0.5) .. " percent"
        end
        parts[#parts + 1] = label
    else
        parts[#parts + 1] = map.root_name(map.root(x, y)) or "unknown"
    end
    parts[#parts + 1] = text.offset(dx, dy)
    speech.say(table.concat(parts, ", ") .. ".", true)
end

function M.tick()
    if not G_stateGame then return end
    local p = map.player()
    if not p then return end

    local targeting_loc = G_stateGame.isTargetingLocation
    local targeting_dir = G_stateGame.isTargetingDirection

    if targeting_loc and p.targetedOffset then
        local dx, dy = p.targetedOffset.x, p.targetedOffset.y
        local key = "L" .. dx .. "," .. dy
        if T.last ~= key then
            if T.last == nil then speech.say("Targeting.", true) end
            T.last = key
            describe_target(p.position.x + dx, p.position.y + dy, dx, dy)
        end
    elseif targeting_dir and p.targetDirection then
        local dx, dy = p.targetDirection.x, p.targetDirection.y
        local key = "D" .. dx .. "," .. dy
        if T.last ~= key then
            if T.last == nil then speech.say("Aiming.", true) end
            T.last = key
            local dir = dy < 0 and "north" or dy > 0 and "south" or dx < 0 and "west" or "east"
            speech.say(dir .. ".", true)
        end
    else
        if T.last ~= nil then
            T.last = nil
            speech.say("Targeting ended.", false)
        end
    end
end

return M
