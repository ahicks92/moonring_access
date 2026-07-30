-- ma_scanner.lua — categorized map-feature scanner (the Tangledeep/Factorio
-- Access model). Two navigation axes over a FROZEN snapshot: Ctrl+PageUp/Down
-- switches category, PageUp/Down steps entries (nearest-first). Membership
-- and order freeze at rescan; names and offsets are re-queried LIVE at speak
-- time so a moved monster's offset is current. Selection survives rescans via
-- stable string keys. Home points the exploration cursor at the entry; End
-- rescans.

local hooks = require("ma_hooks")
local speech = require("ma_speech")
local text = require("ma_text")
local map = require("ma_map")
local synth = require("ma_synth")

local st = hooks.state
st.scanner = st.scanner or {}
local S = st.scanner

local M = {}

local SCAN_RADIUS = 40   -- tiles around the player, comfortably > the window

local CATEGORIES = { "visible", "monsters", "npcs", "doors", "stairs", "loot", "signs", "secrets", "all" }
local CAT_NAMES = {
    visible = "Visible", monsters = "Monsters", npcs = "People",
    doors = "Doors and gates", stairs = "Stairs and exits", loot = "Loot",
    signs = "Readables", secrets = "Secrets", all = "Everything",
}

local DOOR_ROOTS = {
    doorClosed = true, doorOpen = true, doorLocked = true, doorMetal = true,
    doorBroken = true, gateClosed = true, gateOpen = true, gateLocked = true,
}
local STAIR_ROOTS = { stairsUp = true, stairsDown = true }
local LOOT_ROOTS = {
    chestClosed = true, crateClosed = true, barrelClosed = true, bookshelf = true,
}

-- ----------------------------------------------------------- feature kinds --
-- A feature: { key, cat, name(), pos() -> x, y or nil (gone) }

local function actor_feature(a, cat)
    return {
        key = "actor:" .. tostring(a.ID),
        cat = cat,
        name = function()
            local ok, n = pcall(a.getDisplayName, a)
            n = ok and n or "creature"
            if a.isDead or a.isCorpse then n = n .. ", dead" end
            return n
        end,
        pos = function()
            if a.isDead or a.isCorpse or not a.position then return nil end
            return a.position.x, a.position.y
        end,
        visible = function()
            local ok, v = pcall(a.getIsVisibleToPlayer, a)
            return ok and v or false
        end,
    }
end

local function tile_feature(x, y, cat, label)
    return {
        key = "tile:" .. cat .. ":" .. x .. "," .. y,
        cat = cat,
        name = function()
            -- Re-read the root live: an opened door / looted chest renames.
            local root = map.root(x, y)
            return map.root_name(root) or label
        end,
        pos = function() return x, y end,
        visible = function() return map.visible(x, y) or false end,
    }
end

local function trigger_feature(x, y, label)
    return {
        key = "trig:" .. label .. ":" .. x .. "," .. y,
        cat = label == "something readable" and "signs" or "stairs",
        name = function() return label end,
        pos = function() return x, y end,
        visible = function() return map.visible(x, y) or false end,
    }
end

-- --------------------------------------------------------------- snapshot --

local function build_snapshot()
    local p = map.player()
    if not p or not p.position then return nil end
    local px, py = p.position.x, p.position.y
    local feats = {}

    -- Actors.
    local am = G_stateGame.actorManager
    for _, a in ipairs(am.actorArray or {}) do
        if a ~= p and not a.isDead and not a.isCorpse and a.position then
            local ok, vis = pcall(a.getIsVisibleToPlayer, a)
            if ok and vis then
                feats[#feats + 1] = actor_feature(a, a.faction == "enemy" and "monsters" or "npcs")
            end
        end
    end

    -- Unrevealed secrets (deliberately NOT gated on remembered — hidden
    -- things are invisible to everyone; surfacing them is the point until we
    -- know vanilla discovery is viable by ear). Hidden traps come from the
    -- trigger list below.
    pcall(function()
        local list = G_stateGame.triggerData:getAllTriggersOnLevelWithActionName(
            G_stateGame.currentWorldName, "fnTrap")
        for _, t in ipairs(list or {}) do
            if not map.trap_revealed_root(map.root(t.x, t.y)) then
                local f = trigger_feature(t.x, t.y, "hidden trap")
                f.cat = "secrets"
                feats[#feats + 1] = f
            end
        end
    end)

    -- Remembered tiles: doors, stairs, loot; triggers: readables, entrances.
    local SKIP = { playerStart = true, firewall = true, tutorial = true }
    for dy = -SCAN_RADIUS, SCAN_RADIUS do
        for dx = -SCAN_RADIUS, SCAN_RADIUS do
            local x, y = px + dx, py + dy
            if map.secret_door_at(x, y) then
                local f = tile_feature(x, y, "secrets", "hidden door")
                f.cat = "secrets"
                f.name = function()
                    return map.secret_door_at(x, y) and "hidden door" or "secret door, revealed"
                end
                feats[#feats + 1] = f
            end
            if map.remembered(x, y) then
                local root = map.root(x, y)
                if root then
                    if DOOR_ROOTS[root] then
                        feats[#feats + 1] = tile_feature(x, y, "doors", root)
                    elseif STAIR_ROOTS[root] then
                        feats[#feats + 1] = tile_feature(x, y, "stairs", root)
                    elseif LOOT_ROOTS[root] then
                        feats[#feats + 1] = tile_feature(x, y, "loot", root)
                    end
                end
                if G_stateGame.triggerData and G_stateGame.currentWorldName then
                    local ok, list = pcall(G_stateGame.triggerData.getAllTriggersOnLevelAtXYZeroIndexed,
                        G_stateGame.triggerData, G_stateGame.currentWorldName, x, y)
                    if ok and type(list) == "table" then
                        for _, t in ipairs(list) do
                            local a = t and t.action
                            if a == "read" then
                                feats[#feats + 1] = trigger_feature(x, y, "something readable")
                            elseif a == "search" then
                                local f = trigger_feature(x, y, "searchable spot")
                                f.cat = "loot"
                                feats[#feats + 1] = f
                            elseif a == "warp" then
                                feats[#feats + 1] = trigger_feature(x, y, "passage")
                            elseif a and not SKIP[a] then
                                feats[#feats + 1] = trigger_feature(x, y, tostring(a))
                            end
                        end
                    end
                end
            end
        end
    end

    -- Nearest-first within the snapshot (frozen order).
    for _, f in ipairs(feats) do
        local x, y = f.pos()
        f._d = x and text.dist(x - px, y - py) or 9999
    end
    table.sort(feats, function(a, b) return a._d < b._d end)
    return feats
end

local function in_category(f, cat)
    if cat == "all" then return true end
    if cat == "visible" then return f.visible() end
    return f.cat == cat
end

local function category_list(cat)
    local out = {}
    for _, f in ipairs(S.feats or {}) do
        if in_category(f, cat) then out[#out + 1] = f end
    end
    return out
end

-- ------------------------------------------------------------- navigation --

local function speak_entry(list, idx, with_cat)
    local f = list[idx]
    local p = map.player()
    if not f or not p then return end
    local x, y = f.pos()
    local where = "gone"
    if x then where = text.offset(x - p.position.x, y - p.position.y) end
    local prefix = with_cat and (CAT_NAMES[S.cat or "visible"] .. ": ") or ""
    speech.say(prefix .. f.name() .. ", " .. where .. ", " .. idx .. " of " .. #list .. ".", true)
end

function M.rescan(silent)
    local ok, feats = pcall(build_snapshot)
    if not ok or not feats then return end
    S.feats = feats
    S.cat = S.cat or "visible"
    -- Reconcile: keep the selected feature by key if it survived.
    local list = category_list(S.cat)
    local idx = 1
    if S.sel_key then
        for i, f in ipairs(list) do
            if f.key == S.sel_key then idx = i break end
        end
    end
    S.idx = math.min(idx, math.max(1, #list))
    if not silent then
        speech.say("Scanned: " .. #feats .. " features.", true)
    end
end

local function ensure_scan()
    if not S.feats then M.rescan(true) end
    return S.feats ~= nil
end

function M.step_entry(dir)
    if not ensure_scan() then return end
    local list = category_list(S.cat or "visible")
    if #list == 0 then
        speech.say(CAT_NAMES[S.cat or "visible"] .. ": nothing found.", true)
        return
    end
    S.idx = ((S.idx or 1) - 1 + (dir == "down" and 1 or -1)) % #list + 1
    S.sel_key = list[S.idx].key
    synth.cue("scan_tick")
    speak_entry(list, S.idx, false)
end

function M.step_category(dir)
    if not ensure_scan() then return end
    local ci = 1
    for i, c in ipairs(CATEGORIES) do
        if c == (S.cat or "visible") then ci = i end
    end
    ci = (ci - 1 + (dir == "down" and 1 or -1)) % #CATEGORIES + 1
    S.cat = CATEGORIES[ci]
    S.idx = 1
    local list = category_list(S.cat)
    if #list == 0 then
        speech.say(CAT_NAMES[S.cat] .. ": nothing found.", true)
        return
    end
    S.sel_key = list[S.idx].key
    speak_entry(list, S.idx, true)
end

-- Home: point the exploration cursor at the selected feature.
function M.goto_selected()
    if not ensure_scan() then return end
    local list = category_list(S.cat or "visible")
    local f = list[S.idx or 1]
    if not f then
        speech.say("Nothing selected.", true)
        return
    end
    local x, y = f.pos()
    if not x then
        speech.say(f.name() .. " is gone.", true)
        return
    end
    require("ma_cursor").jump_to(x, y)
end

-- World-change watch: a new map invalidates every snapshot.
function M.watch_tick()
    local world = G_stateGame and G_stateGame.currentWorldName
    if world ~= S.world then
        S.world = world
        S.feats = nil
        S.sel_key = nil
        S.idx = 1
    end
end

return M
