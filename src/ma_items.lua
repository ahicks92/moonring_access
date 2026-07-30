-- ma_items.lua — the shared item detail builder: one object's "tooltip" as a
-- list of spoken lines, mirroring the game's item info pane (buy_panel /
-- sell_panel / inventory_panel drawItemInfoArea). The SAME lines feed both
-- interactions: Space reads them joined, the Details buffer (Ctrl+Up/Down)
-- steps them one at a time.
--
-- Parity rules: stats show under the game's own visibility rules (the sell
-- panel hides them for unidentified reqID items; the buy panel never does);
-- prospective stat CHANGES ("Strength +2") are identified-items-only, exactly
-- like the character panel's before/after preview. Nothing here reads data a
-- sighted player can't see on the same screen.

local text = require("ma_text")

local M = {}

local function clean(s)
    return text.clean(tostring(s or ""))
end

local function signed(n)
    n = math.floor(n + 0.5)
    return (n > 0 and "+" or "") .. tostring(n)
end

local function round2(n)
    return math.floor(n * 100 + 0.5) / 100
end

-- Prospective attribute deltas if v were equipped (swap-aware: the game
-- recomputes with v in its slot in place of whatever is there now).
-- getPlayerAttributesAfterEquipmentAndStatusAlteration is side-effect-free
-- when handed a prospective item — the health/energy writeback only runs on
-- the nil path.
local DELTA_STATS = {
    { key = "strength", name = "Strength" },
    { key = "finesse", name = "Finesse" },
    { key = "intellect", name = "Intellect" },
    { key = "perception", name = "Perception" },
    { key = "endurance", name = "Endurance" },
    { key = "luck", name = "Luck" },
    { key = "maxHealth", name = "Max health" },
    { key = "maxEnergy", name = "Max energy" },
}

local function add_delta_lines(v, add)
    local game = G_stateGame
    if v.reqID and not game:isObjectDataIdentified(v) then return end
    if not (G_Globals.categoryToLocationIDs and G_Globals.categoryToLocationIDs[v.category]) then return end
    local ok, prospective = pcall(game.getPlayerAttributesAfterEquipmentAndStatusAlteration, game, v)
    if not ok or type(prospective) ~= "table" then return end
    local cur = playerStats and playerStats.currentAttributes or {}
    for _, s in ipairs(DELTA_STATS) do
        local d = (tonumber(prospective[s.key]) or 0) - (tonumber(cur[s.key]) or 0)
        if d ~= 0 then add("If equipped: " .. s.name .. " " .. signed(d)) end
    end
end

local function add_stat_lines(v, add)
    local game = G_stateGame

    if v.useFX1 == "feed" then
        local mult = ""
        pcall(function() mult = " (x" .. game:getFoodEnduranceMultiplierValueTo2DP() .. " endurance bonus)" end)
        add("Food: " .. tostring(v.useVar1) .. mult)
    end
    if (v.hands or 0) > 0 then
        add("Hits multiple targets: " .. (v.isWideSwing and "yes" or "no"))
        add("Hands required: " .. ((v.hands or 0) > 1 and "two-handed" or "one-handed"))
    end
    if v.useFX1 == "heal" then add("Healing: " .. tostring(v.useVar1)) end
    if v.useFX2 == "heal" then add("Healing: " .. tostring(v.useVar2)) end

    -- Requirements, with the game's red-digit "you don't qualify" as words.
    local WEARABLE = { melee = true, ranged = true, head = true, body = true,
        hands = true, feet = true, neck = true, shield = true }
    if WEARABLE[v.category] then
        local attrs = {}
        pcall(function() attrs = game:getPlayerCurrentAttributes() end)
        local REQS = {
            { key = "strReq", attr = "strength", name = "Strength" },
            { key = "finReq", attr = "finesse", name = "Finesse" },
            { key = "intReq", attr = "intellect", name = "Intellect" },
            { key = "perReq", attr = "perception", name = "Perception" },
            { key = "endReq", attr = "endurance", name = "Endurance" },
        }
        for _, r in ipairs(REQS) do
            local req = tonumber(v[r.key]) or 0
            if req ~= 0 then
                local have = tonumber(attrs[r.attr]) or 0
                add(r.name .. " required: " .. req .. (have < req and " (you have " .. have .. ")" or ""))
            end
        end
    end

    if (v.weight or 0) > 0 then add("Weight: " .. v.weight) end

    local function dam(label, d, variance)
        if (d or 0) ~= 0 then
            local s = tostring(d)
            pcall(function() s = game:convertDamageToString(d, variance) end)
            add(label .. ": " .. s)
        end
    end
    dam("Raw physical damage", v.physicalMeleeDam, v.meleeVariance)
    dam("Raw magical damage", v.magicalMeleeDam, v.meleeVariance)
    dam("Raw physical ranged damage", v.physicalRangedDam, v.rangedVariance)
    dam("Raw magical ranged damage", v.magicalRangedDam, v.rangedVariance)
    if (v.meleeCritChance or 0) ~= 0 then add("Melee critical hit chance: " .. (v.meleeCritChance * 100) .. " percent") end
    if (v.rangedCritChance or 0) ~= 0 then add("Ranged critical hit chance: " .. (v.rangedCritChance * 100) .. " percent") end
    if (v.weaponTimeCost or 0) ~= 0 then add("Attack time: " .. round2(v.weaponTimeCost / 24) .. " seconds") end
    if (v.cooldown or 0) ~= 0 then add("Reload time: " .. round2(v.cooldown / 24) .. " seconds") end

    local BONUSES = {
        { key = "strBonus", name = "Strength bonus" },
        { key = "finBonus", name = "Finesse bonus" },
        { key = "intBonus", name = "Intellect bonus" },
        { key = "perBonus", name = "Perception bonus" },
        { key = "endBonus", name = "Endurance bonus" },
        { key = "luckBonus", name = "Luck bonus" },
    }
    for _, bn in ipairs(BONUSES) do
        if (v[bn.key] or 0) ~= 0 then add(bn.name .. ": " .. signed(v[bn.key])) end
    end

    -- Defence percentages via the game's own inverse-fraction display math.
    local function def(label, raw)
        if (raw or 0) ~= 0 then
            local shown = raw
            pcall(function()
                local ac = game.actorManager:getActionClass()
                shown = round2(ac.getDefenceValueAsInverseFraction(raw)) * 100
            end)
            add(label .. ": " .. shown .. " percent")
        end
    end
    def("Physical defense", v.physicalDef)
    def("Magical defense", v.magicalDef)

    local MULTS = {
        { key = "physicalMeleeDamMult", name = "Physical melee multiplier" },
        { key = "magicalMeleeDamMult", name = "Magical melee multiplier" },
        { key = "physicalRangedDamMult", name = "Physical ranged multiplier" },
        { key = "magicalRangedDamMult", name = "Magical ranged multiplier" },
        { key = "physicalDefMult", name = "Physical defence multiplier" },
        { key = "magicalDefMult", name = "Magical defence multiplier" },
    }
    for _, mn in ipairs(MULTS) do
        if (v[mn.key] or 0) > 0 then add(mn.name .. ": " .. (1 + v[mn.key])) end
    end
    if (v.rangeBonus or 0) > 0 then add("Range bonus: " .. v.rangeBonus) end

    local STATUS_DEFS = {
        { key = "rotDef", name = "Rot defence" },
        { key = "madDef", name = "Madness defence" },
        { key = "stunDef", name = "Stun defence" },
        { key = "torporDef", name = "Torpor defence" },
        { key = "blindDef", name = "Blindness defence" },
        { key = "bleedDef", name = "Bleed defence" },
        { key = "flameDef", name = "Flame defence" },
        { key = "poisonDef", name = "Poison defence" },
        { key = "wetDef", name = "Waterproofing" },
    }
    for _, sd in ipairs(STATUS_DEFS) do
        if (v[sd.key] or 0) ~= 0 then add(sd.name .. ": " .. round2(v[sd.key]) .. " percent") end
    end
    if (v.shieldBlockFraction or 0) ~= 0 then
        add("Shield block chance: " .. math.floor(v.shieldBlockFraction * 100) .. " percent")
    end
    if (v.stealth or 0) ~= 0 then add("Stealth modifier: " .. v.stealth .. " tiles") end

    add_delta_lines(v, add)
end

-- The full detail lines for object data `v`.
-- opts.mode: "inventory" | "buy" | "sell" (price story + gates differ);
-- opts.vendor_role: the shop's actor role (buy/sell modes).
function M.object_lines(v, opts)
    if not v or not G_stateGame then return {} end
    opts = opts or {}
    local mode = opts.mode or "inventory"
    local game = G_stateGame
    local economy = game.economy
    local lines = {}
    local function add(line)
        if line and line ~= "" then lines[#lines + 1] = line end
    end

    -- Name + description head the list: line 1 orients, and read-all starts
    -- the way the game's pane does.
    local name = v.name
    pcall(function() name = game:getModifiedObjectName(v) end)
    add(clean(name))
    pcall(function() add(clean(game:getModifiedObjectDescription(v))) end)

    if mode == "buy" then
        pcall(function()
            add("You own: " .. game.inventoryPanel:getObjectCountFromObjectType(v.objectType))
        end)
    end
    pcall(function()
        local uses = CEconomy.discountArray[economy:getLocalEconomyLocationName()]
        for _, use in ipairs(uses or {}) do
            if v.use == use then add("Local product") break end
        end
    end)

    -- Stats: the sell panel (and inventory) hide them for unidentified reqID
    -- items; the buy panel shows stock stats unconditionally.
    local stats_visible = mode == "buy" or not v.reqID
    if not stats_visible then
        local ok, identified = pcall(game.isObjectDataIdentified, game, v)
        stats_visible = ok and identified or false
    end
    if stats_visible then
        pcall(add_stat_lines, v, add)
    else
        add("Unidentified. Use a Rosetta to divine this item.")
    end

    -- The price story, exactly the game's arithmetic.
    if mode == "buy" then
        pcall(function()
            local base = v.price
            add("Base price: " .. base)
            local demand_price = math.floor(base * economy:getSpecificItemPriceFluctuationFraction(v))
            if demand_price ~= base then add("Demand: " .. signed(demand_price - base)) end
            local faction = economy:getFactionRelationshipAlteration()
            local final_price = math.floor((1 - faction) * demand_price)
            if final_price ~= demand_price then add("Reputation: " .. signed(final_price - demand_price)) end
            add("You buy for: " .. final_price)
            if opts.vendor_role then
                add("Shopkeeper's funds: " .. economy:getFundsForShopType(opts.vendor_role))
            end
        end)
    elseif mode == "sell" then
        pcall(function()
            local base = game:getAdjustedGamePriceForObjectData(v)
            add("Base price: " .. base)
            local demand_price = math.floor(base * economy:getSpecificItemPriceFluctuationFraction(v))
            if demand_price ~= base then add("Demand: " .. signed(demand_price - base)) end
            local after_wear = math.floor(economy:getDeteriorationMultiplier(v) * demand_price)
            if after_wear ~= demand_price then add("Wear and tear: " .. signed(after_wear - demand_price)) end
            local after_tax = math.floor(after_wear * G_Globals.sellMarkdownFraction)
            if after_tax ~= after_wear then add("Sale tax: " .. signed(after_tax - after_wear)) end
            local sell_price = economy:getActualSellValue(v)
            if sell_price ~= after_tax then add("Reputation: " .. signed(sell_price - after_tax)) end
            add("You sell for: " .. sell_price)
            if opts.vendor_role then
                local funds = economy:getFundsForShopType(opts.vendor_role)
                add("Shopkeeper's funds: " .. funds)
                if funds < sell_price then add("The shopkeeper cannot afford this") end
            end
        end)
    end

    return lines
end

return M
