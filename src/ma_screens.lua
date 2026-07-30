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
        ctx.message:fragment("Buying from " .. vendor_name(panel.vendorRole) .. ", "
            .. n .. (n == 1 and " item." or " items."))
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
                    if (entry.amount or 1) ~= 1 then ctx.message:fragment("x " .. entry.amount) end
                    local ok, price = pcall(economy.getActualBuyValue, economy, d)
                    if ok and price then ctx.message:fragment(price .. " guineas") end
                    ctx.message:fragment(idx .. " of " .. #inv)
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
        ctx.message:fragment("Selling to " .. vendor_name(panel.vendorRole) .. ". "
            .. tostring(cat) .. ", " .. n .. (n == 1 and " item." or " items."))
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
                    if (item.count or 1) > 1 then ctx.message:fragment("x " .. item.count) end
                    local ok, price = pcall(economy.getActualSellValue, economy, item)
                    if ok and price then ctx.message:fragment(price .. " guineas") end
                    ctx.message:fragment(idx .. " of " .. #inv)
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
        ctx.message:fragment(clean(name) .. ", character sheet.")
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

local function god_row_text(y)
    local god = G_Globals.skillFactions[y]
    local gd = G_Globals.godData[god] or {}
    local parts = { clean(gd.name or god) }
    pcall(function()
        parts[#parts + 1] = "devotion " .. G_stateGame:getDevotion(god)
    end)
    pcall(function()
        if G_stateGame:isCursedByGod(god) then
            parts[#parts + 1] = "cursed"
        elseif G_stateGame:isDedicatedToGod(god) then
            parts[#parts + 1] = "dedicated"
        elseif playerStats.currentlyFollowingGods and playerStats.currentlyFollowingGods[god] then
            parts[#parts + 1] = "following"
        end
    end)
    return table.concat(parts, ", ")
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
            local progress = cur and (cur .. " of " .. req) or ""
            local reward = clean(tostring(t[4] or ""))
            local line = desc
            if t[1] then
                line = line .. ", complete"
            else
                if progress ~= "" then line = line .. ", " .. progress end
                if reward ~= "" then line = line .. ". " .. reward .. " devotion" end
            end
            lines[#lines + 1] = line
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
                    ctx.message:fragment(god_row_text(yy) .. ".")
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
                                ctx.message:fragment(clean(gd.name or god) .. ", " .. verb)
                            elseif xx == 2 then
                                local _, done, total = god_task_lines(god)
                                if total and total > 0 then
                                    ctx.message:fragment("Devotional tasks, "
                                        .. done .. " of " .. total .. " complete")
                                else
                                    ctx.message:fragment("Devotional tasks scroll")
                                end
                            else
                                ctx.message:fragment(clean((the_td and the_td.title) or the_cell.tileDataName))
                                local state = cell_state_text(tree, the_cell, the_td, xx)
                                if state then ctx.message:fragment(state) end
                            end
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
                                lines[#lines + 1] = clean(gd.name or god) .. ", devotional tasks"
                                    .. (total and (", " .. done .. " of " .. total .. " complete") or "")
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
                                lines[#lines + 1] = god_row_text(yy)
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

-- Registered from ma_overlays.register_all between inventory and the modal
-- stack, so game modals (multi-choice, confirm, number box, alerts) opened
-- FROM these screens sit above them.
function M.register()
    dispatcher.register(character)
    dispatcher.register(buy)
    dispatcher.register(sell)
    dispatcher.register(gods)
end

return M
