-- ma_screens.lua — the big Tab-stop screens: shop buy/sell, the character
-- sheet, and the gods screen (skill tree). Same ownership discipline as
-- ma_overlays: game widgets are read-only data + commit targets.
--
-- These are the first overlays built on Tab-stops (begin_stop): arrows move
-- within a pane, Tab/Shift+Tab cycle panes, each pane remembers its cursor.
-- Every item/cell node carries a `details` producer — Space reads it all,
-- the Details buffer (Ctrl+Up/Down) steps the same lines one at a time.

local Id = require("ma_id")
local dispatcher = require("ma_dispatcher")
local gamestate = require("library.gamestate")
local ma_text = require("ma_text")
local items = require("ma_items")
local hooks = require("ma_hooks")
local MB = require("ma_mb")

local M = {}

local function clean(s)
    return ma_text.clean(tostring(s or ""))
end

local function in_game()
    local ok, cur = pcall(gamestate.current)
    return ok and G_stateGame ~= nil and cur == G_stateGame
end

local function round1(n)
    return math.floor((tonumber(n) or 0) * 10 + 0.5) / 10
end

local function pct(fraction)
    return math.floor((tonumber(fraction) or 0) * 100 + 0.5)
end

local function vendor_name(role)
    local name = tostring(role or "the shopkeeper")
    pcall(function()
        local actor = G_stateGame.actorManager:getActorWithRole(role)
        if actor then name = clean(actor:getDisplayName()) end
    end)
    return name
end

-- ------------------------------------------------------------------- buy --
-- The vendor's stock. Stops: stock list, then the money pane. Enter starts
-- the game's own buy flow (number box / confirm — already voiced overlays).
local buy = {
    id = "buy",
    handler = function(self)
        local panel = in_game() and G_stateGame.buyPanel
        return (panel and panel.isOpen) and "active" or "inactive"
    end,
    sub_identity = function(self)
        local panel = G_stateGame and G_stateGame.buyPanel
        return panel and tostring(panel.vendorRole) or nil
    end,
    announce = function(self, ctx)
        local panel = G_stateGame.buyPanel
        local n = #(panel.sortedInventory or {})
        ctx.message:fragment("Buying from"):fragment(vendor_name(panel.vendorRole))
            :list_item(ma_text.plural(n, "item"))
    end,
    build = function(self, b)
        local panel = G_stateGame and G_stateGame.buyPanel
        if not panel or not panel.isOpen then return end
        b:capture_input()
        local game = G_stateGame
        local economy = game.economy
        local inv = panel.sortedInventory or {}

        b:begin_stop("stock", "Stock")
        if #inv == 0 then
            b:add_label(Id.structural("empty"), function(ctx)
                ctx.message:fragment("Nothing for sale.")
            end)
        end
        for i, stock in ipairs(inv) do
            local idx, entry = i, stock
            local function def()
                local ok, d = pcall(game.getObjectDataWithObjectType, game, entry.ID)
                return ok and d or nil
            end
            b:start_row("stock" .. i)
            b:add_item(Id.referenced(entry, "stock:" .. tostring(entry.ID)), {
                label = function(ctx)
                    local d = def()
                    ctx.message:fragment(clean(d and d.name or entry.ID))
                    if (entry.amount or 1) ~= 1 then ctx.message:list_item("x " .. entry.amount) end
                    local ok, price = pcall(economy.getActualBuyValue, economy, d)
                    if ok and price then ctx.message:list_item(price .. " guineas") end
                    ctx.message:list_item(idx .. " of " .. #inv)
                end,
                on_click = function(ctx)
                    panel.cursorPosition = idx   -- visual parity, write-only
                    panel:startBuy(idx)
                end,
                details = function()
                    return items.object_lines(def(), { mode = "buy", vendor_role = panel.vendorRole })
                end,
            })
            b:end_row()
        end

        b:begin_stop("money", "Money")
        b:add_label(Id.structural("gold"), function(ctx)
            ctx.message:fragment("Your money: "
                .. tostring(playerStats and playerStats.money or "unknown") .. " guineas")
        end)
        b:add_label(Id.structural("funds"), function(ctx)
            local funds = "unknown"
            pcall(function() funds = economy:getFundsForShopType(panel.vendorRole) end)
            ctx.message:fragment("Shopkeeper's funds: " .. tostring(funds))
        end)
    end,
}

-- ------------------------------------------------------------------ sell --
-- Your sellable goods, category-filtered like the inventory (left/right =
-- the panel's own moveCategory). Enter starts the game's sell flow.
local sell = {
    id = "sell",
    handler = function(self)
        local panel = in_game() and G_stateGame.sellPanel
        return (panel and panel.isOpen) and "active" or "inactive"
    end,
    sub_identity = function(self)
        local panel = G_stateGame and G_stateGame.sellPanel
        if not panel then return nil end
        return tostring(panel.vendorRole) .. "cat" .. tostring(panel.categoryIndex)
    end,
    announce = function(self, ctx)
        local panel = G_stateGame.sellPanel
        local cat = (G_Globals.categorySellTypes and G_Globals.categorySellTypes[panel.categoryIndex])
            or (G_Globals.categoryTypes and G_Globals.categoryTypes[panel.categoryIndex]) or "items"
        local n = #(panel.sortedInventory or {})
        ctx.message:fragment("Selling to"):fragment(vendor_name(panel.vendorRole))
            :sentence(tostring(cat)):list_item(ma_text.plural(n, "item"))
    end,
    build = function(self, b)
        local panel = G_stateGame and G_stateGame.sellPanel
        if not panel or not panel.isOpen then return end
        b:capture_input()
        local economy = G_stateGame.economy
        local inv = panel.sortedInventory or {}
        local function category_adjust(ctx, sign)
            panel:moveCategory(sign)
        end

        b:begin_stop("goods", "Your goods")
        if #inv == 0 then
            b:add_item(Id.structural("empty"), {
                label = function(ctx) ctx.message:fragment("Nothing to sell in this category.") end,
                on_horizontal_adjust = category_adjust,
            })
        end
        for i, v in ipairs(inv) do
            local idx, item = i, v
            b:start_row("goods" .. i)
            b:add_item(Id.referenced(item, "sell:" .. tostring(item.ID)), {
                label = function(ctx)
                    local name = item.name
                    pcall(function() name = G_stateGame:getModifiedObjectName(item) end)
                    ctx.message:fragment(clean(name))
                    if (item.count or 1) > 1 then ctx.message:list_item("x " .. item.count) end
                    local ok, price = pcall(economy.getActualSellValue, economy, item)
                    if ok and price then ctx.message:list_item(price .. " guineas") end
                    ctx.message:list_item(idx .. " of " .. #inv)
                end,
                on_click = function(ctx)
                    panel.cursorPosition = idx
                    panel:startSell(idx)
                end,
                on_horizontal_adjust = category_adjust,
                details = function()
                    return items.object_lines(item, { mode = "sell", vendor_role = panel.vendorRole })
                end,
            })
            b:end_row()
        end

        b:begin_stop("money", "Money")
        b:add_label(Id.structural("gold"), function(ctx)
            ctx.message:fragment("Your money: "
                .. tostring(playerStats and playerStats.money or "unknown") .. " guineas")
        end)
        b:add_label(Id.structural("funds"), function(ctx)
            local funds = "unknown"
            pcall(function() funds = economy:getFundsForShopType(panel.vendorRole) end)
            ctx.message:fragment("Shopkeeper's funds: " .. tostring(funds))
        end)
    end,
}

-- -------------------------------------------------------------- character --
-- The character sheet (C), rebuilt as a spoken screen: one Tab-stop per
-- section, all values from the same getters the panel draws with. Read-only
-- (the game panel has no cursor and nothing to commit); equipment rows carry
-- item details.
local SLOT_NAMES = {
    { id = "meleeInventoryID", name = "Melee weapon" },
    { id = "rangedInventoryID", name = "Ranged weapon" },
    { id = "headInventoryID", name = "Head" },
    { id = "bodyInventoryID", name = "Body" },
    { id = "handsInventoryID", name = "Hands" },
    { id = "feetInventoryID", name = "Feet" },
    { id = "neckInventoryID", name = "Neck" },
    { id = "cloakInventoryID", name = "Cloak" },
    { id = "shieldInventoryID", name = "Shield" },
    { id = "lampInventoryID", name = "Lamp" },
}

-- One guarded label row: value_fn computes the spoken text on demand.
local function stat_label(b, key, value_fn)
    b:add_label(Id.structural(key), function(ctx)
        local ok, s = pcall(value_fn)
        ctx.message:fragment(ok and s or (key .. " unknown"))
    end)
end

-- The status-effect octet several getters return, as "name N percent" rows
-- for the nonzero entries. `scale` converts the getter's units to percent.
local STATUS_NAMES = { "Rot", "Madness", "Stun", "Torpor", "Blindness", "Bleed", "Flame", "Poison" }
local function status_rows(b, key_prefix, getter, scale)
    local ok, a, b2, c, d, e, f, g, h = pcall(getter)
    if not ok then return end
    local vals = { a, b2, c, d, e, f, g, h }
    for i, name in ipairs(STATUS_NAMES) do
        local v = tonumber(vals[i]) or 0
        if v ~= 0 then
            local shown = scale == "fraction" and pct(v) or round1(v)
            stat_label(b, key_prefix .. name, function()
                return name .. ": " .. shown .. " percent"
            end)
        end
    end
end

local character = {
    id = "character",
    handler = function(self)
        if not in_game() or not G_stateGame.showCharacterPanel then return "inactive" end
        -- As a side pane next to inventory/shop/skill tree, those screens'
        -- overlays own the keyboard; standalone C is ours.
        local g = G_stateGame
        if (g.inventoryPanel and g.inventoryPanel.isOpen)
            or (g.buyPanel and g.buyPanel.isOpen)
            or (g.sellPanel and g.sellPanel.isOpen)
            or (g.skillTree and g.skillTree.isOpen) then
            return "inactive"
        end
        return "active"
    end,
    announce = function(self, ctx)
        local name = playerStats and playerStats.name or "Character"
        ctx.message:fragment(clean(name)):list_item("character sheet")
    end,
    build = function(self, b)
        if not in_game() or not G_stateGame.showCharacterPanel then return end
        b:capture_input()
        local game = G_stateGame
        local player = game.actorManager and game.actorManager.player
        if not player then return end
        local attrs = playerStats and playerStats.currentAttributes or {}

        b:begin_stop("vitals", "Vitals")
        stat_label(b, "health", function()
            return "Health: " .. math.ceil(player.health) .. " of " .. attrs.maxHealth
        end)
        stat_label(b, "energy", function()
            return "Energy: " .. math.floor(attrs.energy or player.energy) .. " of " .. attrs.maxEnergy
        end)
        stat_label(b, "weight", function()
            local cur, max = game:getRawPlayerBurdenAndMaxBurden()
            return "Weight: " .. math.ceil(cur) .. " of " .. math.ceil(max)
        end)
        stat_label(b, "speed", function()
            local mult = game:getPlayerTickCostMultiplier()
            return "Speed: " .. pct(1 / mult) .. " percent"
        end)
        stat_label(b, "money", function()
            return "Money: " .. tostring(playerStats.money) .. " guineas"
        end)

        b:begin_stop("attributes", "Attributes")
        -- The game has no stat tooltips; the one explanation it DOES ship is
        -- each god's stat line on the gods screen ("Strength - suffer fewer
        -- knockbacks..."). Surface those as the attribute rows' details.
        local attr_god = {}
        for _, god in ipairs(G_Globals.skillFactions or {}) do
            local gd = G_Globals.godData[god]
            if gd and gd.shortStat then
                attr_god[gd.shortStat:lower()] = gd
            end
        end
        local ATTRS = { "strength", "finesse", "intellect", "perception", "endurance", "luck" }
        for _, a in ipairs(ATTRS) do
            local key = a
            local function value_text()
                local v = attrs[key]
                if key == "luck" and player.powers and (player.powers.luck or 0) > 0 then
                    v = v + G_Globals.luckPowerBonus
                end
                return key:sub(1, 1):upper() .. key:sub(2) .. ": " .. tostring(v)
            end
            local gd = attr_god[key]
            b:add_item(Id.structural("attr_" .. key), {
                label = function(ctx)
                    local ok, s = pcall(value_text)
                    ctx.message:fragment(ok and s or (key .. " unknown"))
                end,
                details = gd and function()
                    local lines = {}
                    pcall(function() lines[#lines + 1] = value_text() end)
                    lines[#lines + 1] = clean(gd.stat)
                    lines[#lines + 1] = "Improved by devotion to " .. clean(gd.name) .. "."
                    return lines
                end or nil,
            })
        end

        b:begin_stop("melee", "Melee")
        stat_label(b, "melee_dps", function()
            local p, m = player:getFinalMeleeStats(nil, nil, true)
            local s = "Physical DPS: " .. round1(p)
            if (m or 0) ~= 0 then s = s .. ", magical DPS: " .. round1(m) end
            return s
        end)
        stat_label(b, "melee_crit", function()
            return "Critical hit chance: " .. pct(player:getFinalMeleeCrit()) .. " percent"
        end)
        status_rows(b, "melee_", function() return player:getFinalMeleeStatusEffectStats() end, "fraction")

        b:begin_stop("ranged", "Ranged")
        stat_label(b, "ranged_dps", function()
            local p, m = player:getFinalRangedStats(nil, nil, true)
            local s = "Physical DPS: " .. round1(p)
            if (m or 0) ~= 0 then s = s .. ", magical DPS: " .. round1(m) end
            return s
        end)
        stat_label(b, "ranged_crit", function()
            return "Critical hit chance: " .. pct(player:getFinalRangedCrit()) .. " percent"
        end)
        stat_label(b, "ranged_range", function()
            local r = player:getFinalPlayerRange()
            return "Range: " .. (r and tostring(r) or "none")
        end)
        status_rows(b, "ranged_", function() return player:getFinalRangedStatusEffectStats() end, "fraction")

        b:begin_stop("defence", "Defence")
        stat_label(b, "def", function()
            local ac = game.actorManager:getActionClass()
            local p, m = player:getAllDefStats()
            return "Physical: " .. pct(ac.getDefenceValueAsInverseFraction(p))
                .. " percent, magical: " .. pct(ac.getDefenceValueAsInverseFraction(m)) .. " percent"
        end)
        status_rows(b, "def_", function()
            local a, b2, c, d, e, f, g, h = player:getAllStatusEffectDefStats()
            return a, b2, c, d, e, f, g, h
        end, "raw")
        stat_label(b, "stealth", function()
            return "Stealth: " .. tostring(game:getStealthAfterEquipmentAndStatusAlteration())
        end)
        stat_label(b, "block", function()
            local blocking = 0
            local shield = player:getShieldData()
            if shield then blocking = player:getDeterioratedShieldValueOfObject(shield) end
            if player:isBlindFaithActive() then
                blocking = blocking + G_Globals.blindFaithParryFraction
            end
            return "Block: " .. pct(blocking) .. " percent"
        end)
        stat_label(b, "dodge", function()
            return "Dodge: " .. pct(game:getPlayerDodge()) .. " percent"
        end)

        b:begin_stop("equipment", "Equipment")
        local any = false
        for _, slot in ipairs(SLOT_NAMES) do
            local id = player[slot.id]
            if id and id ~= 0 then
                local ok, item = pcall(player.getInventoryItemWithID, player, id)
                if ok and item then
                    any = true
                    local it = item
                    b:start_row("equip_" .. slot.id)
                    b:add_item(Id.referenced(it, "equip:" .. tostring(id)), {
                        label = function(ctx)
                            local name = it.name
                            pcall(function() name = game:getModifiedObjectName(it) end)
                            ctx.message:fragment(slot.name .. ": " .. clean(name))
                        end,
                        details = function()
                            return items.object_lines(it, { mode = "inventory" })
                        end,
                    })
                    b:end_row()
                end
            end
        end
        if not any then
            b:add_label(Id.structural("equip_none"), function(ctx)
                ctx.message:fragment("Nothing equipped.")
            end)
        end
    end,
}

-- ------------------------------------------------------------------- gods --
-- The gods screen (G): CSkillTree's 5x9 grid. Row = a god (column 1 the god
-- itself — dedicate or pray; column 2 the task scroll; the rest gifts).
-- Enter commits through the tree's own activateTileAtCursor, so dedication
-- confirms, prayer, purchases, and bought-skill use all follow game rules.
--
-- skillTileData is file-local in skill_tree.lua; we lift it read-only via
-- debug.getupvalue on a CSkillTree method (cached per boot).
local tile_data_cache = nil
local function skill_tile_data()
    if tile_data_cache then return tile_data_cache end
    local f = CSkillTree and CSkillTree.updateCurrentTileText
    if type(f) ~= "function" then return nil end
    for i = 1, 20 do
        local ok, name, val = pcall(debug.getupvalue, f, i)
        if not ok or not name then break end
        if name == "skillTileData" then
            tile_data_cache = val
            return val
        end
    end
    return nil
end

-- Append the god's summary row (name, devotion, standing) to the builder;
-- returns the builder. Details lines get a string via god_row(MB.new(), y).
local function god_row(m, y)
    local god = G_Globals.skillFactions[y]
    local gd = G_Globals.godData[god] or {}
    m:list_item(clean(gd.name or god))
    pcall(function()
        m:list_item("devotion " .. G_stateGame:getDevotion(god))
    end)
    pcall(function()
        if G_stateGame:isCursedByGod(god) then
            m:list_item("cursed")
        elseif G_stateGame:isDedicatedToGod(god) then
            m:list_item("dedicated")
        elseif playerStats.currentlyFollowingGods and playerStats.currentlyFollowingGods[god] then
            m:list_item("following")
        end
    end)
    return m
end

-- The god's devotional task list (the scroll column's info-pane table):
-- { done, "1)  text ", " = cur/req", "Reward: n" } per task. Returns spoken
-- lines plus done/total counts.
local function god_task_lines(god)
    local lines, done, total = {}, 0, 0
    local ok = pcall(function()
        local ach = G_stateGame:getAchievements()
        for _, t in ipairs(ach.getTaskStringsForGod(god)) do
            total = total + 1
            if t[1] then done = done + 1 end
            local desc = clean(tostring(t[2] or "")):gsub("%s+", " ")
            local cur, req = tostring(t[3] or ""):match("(%d+)%s*/%s*(%d+)")
            local reward = clean(tostring(t[4] or ""))
            local line = MB.new():fragment(desc)
            if t[1] then
                line:list_item("complete")
            else
                if cur then line:list_item(cur .. " of " .. req) end
                if reward ~= "" then line:sentence(reward .. " devotion") end
            end
            lines[#lines + 1] = line:build()
        end
    end)
    if not ok then return nil end
    return lines, done, total
end

local function cell_state_text(tree, cell, td, x)
    if x == 1 then return nil end   -- the god head cell speaks for itself
    if cell.isOpen then return "owned" end
    if cell.isBlocked then return "blocked" end
    if not cell.isAvailable then return "locked" end
    local cost = td and td.cost
    return cost and ("cost " .. cost) or "available"
end

local gods = {
    id = "gods",
    handler = function(self)
        local tree = in_game() and G_stateGame.skillTree
        return (tree and tree.isOpen) and "active" or "inactive"
    end,
    announce = function(self, ctx)
        ctx.message:fragment("Gods.")
    end,
    build = function(self, b)
        local tree = G_stateGame and G_stateGame.skillTree
        if not tree or not tree.isOpen then return end
        b:capture_input()
        local tiles = skill_tile_data() or {}
        for y = 1, tree.gridHeight do
            local god = G_Globals.skillFactions[y]
            local gd = G_Globals.godData[god] or {}
            local yy = y
            -- Collect the row's real cells first: end_row() rejects an empty
            -- row, and a fully blocked rank must not crash the build.
            local row_cells = {}
            for x = 1, tree.gridWidth do
                local cell = tree.cells[y] and tree.cells[y][x]
                if cell and cell.tileDataName ~= "null" and not cell.isBlocked then
                    row_cells[#row_cells + 1] = { x = x, cell = cell, td = tiles[cell.tileDataName] }
                end
            end
            if #row_cells > 0 then
                b:start_row("god" .. y, function(ctx)
                    god_row(ctx.message, yy)
                end)
                for _, rc in ipairs(row_cells) do
                    local xx, the_cell, the_td = rc.x, rc.cell, rc.td
                    b:add_item(Id.structural("cell" .. y .. "_" .. rc.x), {
                        label = function(ctx)
                            if xx == 1 then
                                local verb = "dedicate"
                                pcall(function()
                                    if G_stateGame:isDedicatedToGod(god) then verb = "pray" end
                                end)
                                ctx.message:fragment(clean(gd.name or god)):list_item(verb)
                            elseif xx == 2 then
                                local _, done, total = god_task_lines(god)
                                if total and total > 0 then
                                    ctx.message:fragment("Devotional tasks")
                                        :list_item(done .. " of " .. total .. " complete")
                                else
                                    ctx.message:fragment("Devotional tasks scroll")
                                end
                            else
                                ctx.message:fragment(clean((the_td and the_td.title) or the_cell.tileDataName))
                                local state = cell_state_text(tree, the_cell, the_td, xx)
                                if state then ctx.message:list_item(state) end
                            end
                        end,
                        -- Cursor sync on focus: the tree's digit-shortcut
                        -- binding (1-0 bind an owned gift) reads ITS cursor,
                        -- so it must follow ours.
                        on_focus = function()
                            tree.cursorPos.x = xx - 1
                            tree.cursorPos.y = yy - 1
                            pcall(tree.updateCurrentTileText, tree)
                        end,
                        on_click = function(ctx)
                            tree.cursorPos.x = xx - 1
                            tree.cursorPos.y = yy - 1
                            pcall(tree.updateCurrentTileText, tree)
                            tree:activateTileAtCursor()
                        end,
                        details = function()
                            local lines = {}
                            if xx == 2 then
                                local tasks, done, total = god_task_lines(god)
                                local head = MB.new():fragment(clean(gd.name or god))
                                    :list_item("devotional tasks")
                                if total then head:list_item(done .. " of " .. total .. " complete") end
                                lines[#lines + 1] = head:build()
                                for _, l in ipairs(tasks or {}) do lines[#lines + 1] = l end
                                return lines
                            end
                            if xx == 1 then
                                lines[#lines + 1] = clean(gd.name or god)
                                if gd.stat then lines[#lines + 1] = clean(gd.stat) end
                                if gd.boon then lines[#lines + 1] = "Boon: " .. clean(gd.boon) end
                                if gd.restrictions and gd.restrictions ~= "" then
                                    lines[#lines + 1] = "Taboo: " .. clean(gd.restrictions)
                                end
                                lines[#lines + 1] = god_row(MB.new(), yy):build()
                            else
                                lines[#lines + 1] = clean((the_td and the_td.title) or the_cell.tileDataName)
                                if the_td and the_td.description then
                                    lines[#lines + 1] = clean(the_td.description)
                                end
                                if the_td and the_td.stat and the_td.amount then
                                    lines[#lines + 1] = "Grants " .. the_td.stat .. " +" .. the_td.amount
                                end
                                local state = cell_state_text(tree, the_cell, the_td, xx)
                                if state then lines[#lines + 1] = state end
                                pcall(function()
                                    lines[#lines + 1] = "Your devotion to " .. clean(gd.name or god)
                                        .. ": " .. G_stateGame:getDevotion(god)
                                end)
                            end
                            return lines
                        end,
                    })
                end
                b:end_row()
            end
        end
    end,
}

-- -------------------------------------------------------------------- map --
-- The map screen (M): known locations sorted by distance from the player's
-- overworld position. Enter on a location TRACKS it; Alt+backslash then
-- reads the tracked location's relative distance from anywhere. Locations
-- come from the same data the drawn map labels use (overworldEntryPoints
-- gated on knownLocations/seenLocations), so we never name a place the
-- player hasn't learned about.

-- The player's position in overworld coordinates: live position on the
-- Overworld; inside a zoom/town/dungeon, the game's remembered zoom-in point
-- or the world's own overworld tile.
local function overworld_pos()
    local g = G_stateGame
    if not g then return nil end
    local wd = g.currentWorldData
    if wd and wd.isOverworld then
        local p = g.actorManager and g.actorManager.player
        if p and p.position then return p.position.x, p.position.y end
    end
    local o = playerStats and playerStats.overworldPositionXY
    if o and o.x and o.x ~= 0 then return o.x, o.y end
    if wd and wd.x then return wd.x, wd.y end
    return nil
end

local function compass_offset(dx, dy)
    local parts = {}
    if dx > 0 then parts[#parts + 1] = dx .. " east"
    elseif dx < 0 then parts[#parts + 1] = -dx .. " west" end
    if dy > 0 then parts[#parts + 1] = dy .. " south"
    elseif dy < 0 then parts[#parts + 1] = -dy .. " north" end
    if #parts == 0 then return "here" end
    return table.concat(parts, ", ")
end

local function location_status(name)
    if playerStats.visitedLocations and playerStats.visitedLocations[name] then return "visited" end
    if playerStats.seenLocations and playerStats.seenLocations[name] then return "seen" end
    return "known"
end

-- Known locations sorted nearest-first: { key, name, x, y, dist, status,
-- region }. Distances are Chebyshev (overworld steps).
local function known_locations()
    local list = {}
    local g = G_stateGame
    if not (g and g.triggerData and g.triggerData.overworldEntryPoints) then return list end
    local px, py = overworld_pos()
    local worldData = nil
    pcall(function() worldData = require("world_data") end)
    for _, v in ipairs(g.triggerData.overworldEntryPoints) do
        local name = v.data or v.action
        if name and name ~= "playerStart" and v.x and v.y
            and ((playerStats.knownLocations and playerStats.knownLocations[name])
                or (playerStats.seenLocations and playerStats.seenLocations[name])) then
            local display, region = nil, nil
            pcall(function()
                local wd = worldData and worldData.getWorldDataWithName(name)
                if wd then
                    if wd.displayName and wd.displayName ~= "" then display = wd.displayName end
                    region = wd.overworldRegionName
                end
            end)
            display = display or tostring(name):gsub("_", " ")
            local dist = px and math.max(math.abs(v.x - px), math.abs(v.y - py)) or 0
            list[#list + 1] = {
                key = name, name = clean(display), x = v.x, y = v.y,
                dist = dist, status = location_status(name), region = region,
                dx = px and (v.x - px) or 0, dy = py and (v.y - py) or 0,
            }
        end
    end
    table.sort(list, function(a, b)
        if a.dist ~= b.dist then return a.dist < b.dist end
        return a.name < b.name
    end)
    return list
end

function M.set_tracked(loc)
    hooks.state.tracked = { key = loc.key, name = loc.name, x = loc.x, y = loc.y }
end

-- Alt+backslash: where is the tracked location from here?
function M.tracked_where()
    local speech = require("ma_speech")
    local t = hooks.state.tracked
    if not t then
        speech.say("Nothing tracked. Press Enter on a map screen location to track it.", true)
        return
    end
    if G_stateGame and tostring(G_stateGame.currentWorldName) == tostring(t.key) then
        speech.say(t.name .. ": you are here.", true)
        return
    end
    local px, py = overworld_pos()
    if not px then
        speech.say(t.name .. ": position unknown.", true)
        return
    end
    speech.say(MB.new():fragment(t.name .. ":")
        :fragment(compass_offset(t.x - px, t.y - py)), true)
end

-- --------------------------------------------------------- dungeon map --
-- In dungeons the map key shows the level as a grid of 9x9-cell block
-- summaries (ma_blockmap; blocks align with the generator's half-chunks, so
-- a block is usually one authored room). Arrows move block to block; each
-- landing plays the OniAccess connection-shape earcon for which sides have
-- potential passage, then speaks position and contents. Space reads the
-- full per-side breakdown; Enter points the exploration cursor at the
-- block's most useful feature and closes the map.

local FEATURE_PLURALS = {
    ["chest"] = "chests", ["warp"] = "warps", ["door"] = "doors",
    ["locked door"] = "locked doors",
    ["locked door, have the key"] = "locked doors, have the key",
    ["point of interest"] = "points of interest",
    ["stairs up"] = "stairs up", ["stairs down"] = "stairs down",
}

local function feature_text(name, count)
    if count <= 1 then return name end
    return count .. " " .. (FEATURE_PLURALS[name] or name)
end

-- Label features only: plain doors stay out of the quick label (the earcon
-- already says the side connects; details carry the door/open distinction).
local LABEL_FEATURES = { "stairs down", "stairs up",
    "locked door, have the key", "locked door", "chest", "warp",
    "point of interest" }

local function block_position_text(bx, by, pbx, pby)
    if not pbx then return "block " .. bx .. " " .. by end
    if bx == pbx and by == pby then return "You" end
    return compass_offset(bx - pbx, by - pby)
end

local function append_block_features(m, s)
    for _, name in ipairs(LABEL_FEATURES) do
        local f = s.feats[name]
        if f then m:list_item(feature_text(name, f.count)) end
    end
    if s.water then m:list_item("water") end
    if s.lava then m:list_item("lava") end
    if s.void then m:list_item("void") end
end

local function block_label(ctx, grid, bx, by, pbx, pby)
    local blockmap = require("ma_blockmap")
    local synth = require("ma_synth")
    local s = blockmap.summarize(grid, bx, by)
    ctx.message:fragment(block_position_text(bx, by, pbx, pby))
    if not s then
        ctx.message:list_item("unknown")
        return
    end

    local sides = s.sides
    if sides.north or sides.east or sides.south or sides.west then
        synth.shape_earcon({
            north = sides.north ~= nil, east = sides.east ~= nil,
            south = sides.south ~= nil, west = sides.west ~= nil,
        })
    elseif s.unexplored then
        synth.cue("cursor_unexplored")
    else
        synth.cue("cursor_wall")
    end

    if s.unexplored then
        ctx.message:list_item("unexplored")
        return
    end
    if s.solid then
        ctx.message:list_item("solid")
        return
    end
    if s.frac < 0.15 then ctx.message:list_item("edge seen")
    elseif s.frac < 0.5 then ctx.message:list_item("partly explored") end
    append_block_features(ctx.message, s)
end

local function block_details(grid, bx, by, pbx, pby)
    local blockmap = require("ma_blockmap")
    local s = blockmap.summarize(grid, bx, by)
    local lines = { block_position_text(bx, by, pbx, pby) }
    if not s then
        lines[#lines + 1] = "No map data."
        return lines
    end
    if s.unexplored then
        lines[#lines + 1] = "Unexplored."
        return lines
    end
    lines[#lines + 1] = "Explored " .. pct(s.frac) .. " percent"
    for _, dir in ipairs({ "north", "east", "south", "west" }) do
        local t = s.sides[dir]
        local m = MB.new():fragment(dir:sub(1, 1):upper() .. dir:sub(2) .. ":")
        if not t then
            m:fragment("wall")
        else
            if t.open then m:list_item("open") end
            if t.door then m:list_item("door") end
            if t.locked_key then m:list_item("locked door, have the key")
            elseif t.locked then m:list_item("locked door") end
            if t.frontier then m:list_item("unexplored beyond") end
        end
        lines[#lines + 1] = m:build()
    end
    for _, name in ipairs({ "stairs down", "stairs up",
        "locked door, have the key", "locked door", "door", "chest", "warp",
        "point of interest" }) do
        local f = s.feats[name]
        if f then lines[#lines + 1] = feature_text(name, f.count) end
    end
    if s.water then lines[#lines + 1] = "water" end
    if s.lava then lines[#lines + 1] = "lava" end
    if s.void then lines[#lines + 1] = "void" end
    return lines
end

local function block_click(ctx, grid, bx, by)
    local blockmap = require("ma_blockmap")
    local s = blockmap.summarize(grid, bx, by)
    local target = s and s.best
    if not target then
        ctx.message:fragment("Nothing seen there")
        return
    end
    local wx, wy = require("ma_map").from_map(target.x, target.y)
    if not wx then
        ctx.message:fragment("Nothing seen there")
        return
    end
    pcall(function() G_stateGame:setIsMapOpen(false) end)
    require("ma_cursor").jump_to(wx, wy)
end

local function build_dungeon_map(b, grid)
    b:capture_input()
    local blockmap = require("ma_blockmap")
    local pbx, pby = blockmap.player_block(grid)
    local ids = {}
    for by = 1, grid.bh do
        ids[by] = {}
        for bx = 1, grid.bw do
            local id = Id.structural("blk:" .. bx .. ":" .. by)
            ids[by][bx] = id
            local cbx, cby = bx, by
            b:add_node(id, {
                label = function(ctx) block_label(ctx, grid, cbx, cby, pbx, pby) end,
                on_click = function(ctx) block_click(ctx, grid, cbx, cby) end,
                details = function() return block_details(grid, cbx, cby, pbx, pby) end,
            })
        end
    end
    for by = 1, grid.bh do
        for bx = 1, grid.bw do
            local id = ids[by][bx]
            if bx > 1 then b:connect(id, "left", ids[by][bx - 1]) end
            if bx < grid.bw then b:connect(id, "right", ids[by][bx + 1]) end
            if by > 1 then b:connect(id, "up", ids[by - 1][bx]) end
            if by < grid.bh then b:connect(id, "down", ids[by + 1][bx]) end
        end
    end
    if pbx then b:set_start(ids[pby][pbx]) end
end

local map_screen = {
    id = "map",
    handler = function(self)
        return (in_game() and G_stateGame.isMapOpen) and "active" or "inactive"
    end,
    announce = function(self, ctx)
        local grid = require("ma_blockmap").grid()
        if grid then
            local seen, total = require("ma_blockmap").seen_count(grid)
            ctx.message:fragment("Map")
            local wd = G_stateGame.currentWorldData
            if wd and wd.displayName then ctx.message:list_item(clean(wd.displayName)) end
            ctx.message:list_item(seen .. " of " .. total .. " blocks seen")
            ctx.message:sentence("Enter jumps the cursor")
            return
        end
        local n = #known_locations()
        ctx.message:fragment("Map"):list_item(ma_text.plural(n, "known location"))
            :sentence("Enter tracks")
    end,
    build = function(self, b)
        if not in_game() or not G_stateGame.isMapOpen then return end
        local grid = require("ma_blockmap").grid()
        if grid then return build_dungeon_map(b, grid) end
        b:capture_input()
        local list = known_locations()
        if #list == 0 then
            b:add_label(Id.structural("empty"), function(ctx)
                ctx.message:fragment("No known locations yet.")
            end)
            return
        end
        local tracked = hooks.state.tracked
        for i, loc in ipairs(list) do
            local l = loc
            b:start_row("loc" .. i)
            b:add_item(Id.structural("loc:" .. tostring(l.key)), {
                label = function(ctx)
                    ctx.message:fragment(l.name)
                    ctx.message:list_item(compass_offset(l.dx, l.dy))
                    ctx.message:list_item(l.status)
                    if tracked and tracked.key == l.key then ctx.message:list_item("tracked") end
                end,
                on_click = function(ctx)
                    M.set_tracked(l)
                    ctx.message:fragment("Tracking"):fragment(l.name)
                end,
                details = function()
                    local lines = { l.name }
                    if l.region then lines[#lines + 1] = "Region: " .. clean(l.region) end
                    local where = MB.new():fragment(compass_offset(l.dx, l.dy))
                    if l.dist > 0 then where:list_item(l.dist .. " overworld steps") end
                    lines[#lines + 1] = where:build()
                    lines[#lines + 1] = l.status
                    pcall(function()
                        local vision = G_Globals.hengeToDescription[l.key]
                        if vision and playerStats.seenLocations[l.key] then
                            lines[#lines + 1] = clean(vision)
                        end
                    end)
                    return lines
                end,
            })
            b:end_row()
        end
    end,
}

-- Registered from ma_overlays.register_all between inventory and the modal
-- stack, so game modals (multi-choice, confirm, number box, alerts) opened
-- FROM these screens sit above them.
function M.register()
    dispatcher.register(character)
    dispatcher.register(buy)
    dispatcher.register(sell)
    dispatcher.register(gods)
    dispatcher.register(map_screen)
end

return M
