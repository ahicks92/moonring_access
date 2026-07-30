-- ma_overlays.lua — the modal overlays: our keygraph views over the game's
-- modal widgets.
--
-- Ownership discipline: the game's widgets are READ-ONLY data sources when
-- building our graph, and COMMIT TARGETS when a node activates (we call the
-- widget's own methods — selectItemAtCursor, shiftChoiceLeft/Right,
-- setInactive + the stored callback). We never read the game's cursor back.
-- Non-capturing overlays (alert, tutorial, text input, number) leave every
-- key to the game and only announce content; capture overlays (multi-choice,
-- confirm) own the menu vocabulary via ma_input.
--
-- Registration order = stack priority, bottom to top; the topmost open modal
-- wins, mirroring the game's own getUIInput precedence.

local Id = require("ma_id")
local dispatcher = require("ma_dispatcher")
local gamestate = require("library.gamestate")

local M = {}

-- The widget instance on whichever state is current (title screen and game
-- own separate instances of the same classes).
local function widget(name)
    local cur = gamestate.current()
    if cur == G_stateGame then return G_stateGame[name] end
    if cur == G_stateTitleScreen then return G_stateTitleScreen[name] end
    return nil
end

-- Full speech cleanup: colour markup stripped, font glyph chars named.
local ma_text = require("ma_text")
local function clean(text)
    return ma_text.clean(text)
end

-- ------------------------------------------------------------ multi-choice --
-- Generic list menu: the title screen's main menu, in-game options, barkeep /
-- guard / ritual menus. Slider/toggle rows come from specialChoiceDictionary.
local multi_choice = {
    id = "multi_choice",
    handler = function(self)
        local box = widget("multiChoiceBox")
        return (box and box.isOpen) and "active" or "inactive"
    end,
    sub_identity = function(self)
        local box = widget("multiChoiceBox")
        if not box then return nil end
        return tostring(box.bodyText) .. "#" .. tostring(box.choices and #box.choices or 0)
    end,
    announce = function(self, ctx)
        local box = widget("multiChoiceBox")
        if box and box.bodyText and box.bodyText ~= "" then
            ctx.message:fragment(clean(box.bodyText) .. " menu.")
        end
    end,
    build = function(self, b)
        local box = widget("multiChoiceBox")
        if not box or not box.isOpen or not box.choices then return end
        b:capture_input()
        local n = #box.choices
        for i = 1, n do
            local idx = i
            local text = clean(box.choices[i])
            local special = box.specialChoiceDictionary and box.specialChoiceDictionary[i]
            local function value_text()
                local c = box.specialChoiceDictionary[idx]
                if not c then return nil end
                if c.isBoolean then return c.currentValue and "on" or "off" end
                return tostring(c.currentValue)
            end
            local vtable = {
                label = function(ctx)
                    ctx.message:fragment(text)
                    if special then ctx.message:fragment(value_text()) end
                    ctx.message:fragment(idx .. " of " .. n)
                end,
                on_click = function(ctx)
                    if special then
                        box.cursorPosition = idx
                        if box.specialChoiceDictionary[idx].isBoolean then
                            if box.specialChoiceDictionary[idx].currentValue then
                                box:shiftChoiceLeft()
                            else
                                box:shiftChoiceRight()
                            end
                        end
                        ctx.message:fragment(text)
                        ctx.message:fragment(value_text())
                    else
                        box.cursorPosition = idx
                        box:selectItemAtCursor()
                        -- Speak nothing: whatever the choice opened announces
                        -- itself on the next tick.
                    end
                end,
            }
            if special then
                vtable.on_horizontal_adjust = function(ctx, sign)
                    box.cursorPosition = idx
                    if sign > 0 then box:shiftChoiceRight() else box:shiftChoiceLeft() end
                    ctx.message:fragment(value_text())
                end
            end
            b:start_row("choice" .. i)
            b:add_item(Id.structural("choice:" .. i .. ":" .. text), vtable)
            b:end_row()
        end
    end,
}

-- ----------------------------------------------------------------- confirm --
local confirm = {
    id = "confirm",
    handler = function(self)
        local box = widget("confirmBox")
        return (box and box.isOpen) and "active" or "inactive"
    end,
    sub_identity = function(self)
        local box = widget("confirmBox")
        return box and tostring(box.bodyText) or nil
    end,
    announce = function(self, ctx)
        local box = widget("confirmBox")
        if box then ctx.message:fragment(clean(box.bodyText)) end
    end,
    build = function(self, b)
        local box = widget("confirmBox")
        if not box or not box.isOpen then return end
        b:capture_input()
        b:start_row("yes")
        b:add_item(Id.structural("yes"), {
            label = function(ctx) ctx.message:fragment(clean(box.yesText or "Yes")) end,
            on_click = function(ctx)
                box.confirm = true   -- visual parity, write-only
                box:setInactive()
                if box.yesFunction then box.yesFunction(box.yesFunctionObject, box.data) end
                G_playSound("page_close")
            end,
        })
        b:end_row()
        b:start_row("no")
        b:add_item(Id.structural("no"), {
            label = function(ctx) ctx.message:fragment(clean(box.noText or "No")) end,
            on_click = function(ctx)
                box.confirm = false
                box:setInactive()
                G_playSound("page_close")
            end,
        })
        b:end_row()
    end,
}

-- A one-node, non-capturing "announce the modal's text" overlay; the game
-- keeps every key (confirm/cancel close it natively). Queue advances and
-- content swaps re-announce via sub_identity.
local function announce_only(id, widget_name, describe)
    return {
        id = id,
        handler = function(self)
            local box = widget(widget_name)
            return (box and box.isOpen) and "active" or "inactive"
        end,
        sub_identity = function(self)
            local box = widget(widget_name)
            return box and tostring(box.bodyText) or nil
        end,
        build = function(self, b)
            local box = widget(widget_name)
            if not box or not box.isOpen then return end
            b:add_label(Id.structural(id), function(ctx)
                describe(box, ctx)
            end)
        end,
    }
end

local alert = announce_only("alert", "alertBox", function(box, ctx)
    ctx.message:fragment(clean(box.bodyText))
end)

local tutorial = announce_only("tutorial", "tutorialBox", function(box, ctx)
    ctx.message:fragment("Tutorial:")
    ctx.message:fragment(clean(box.bodyText))
end)

local text_input = announce_only("text_input", "textInputBox", function(box, ctx)
    ctx.message:fragment(clean(box.bodyText))
    ctx.message:fragment(box.numbersOnly and "Number entry." or "Text entry.")
    ctx.message:fragment("Type and press enter.")
end)

-- Number box: sub-identity includes the value, so left/right adjustments
-- (handled by the game) re-announce automatically.
local number_box = {
    id = "number_box",
    handler = function(self)
        local box = widget("numberBox")
        return (box and box.isOpen) and "active" or "inactive"
    end,
    sub_identity = function(self)
        local box = widget("numberBox")
        return box and (tostring(box.bodyText) .. "=" .. tostring(box.number)) or nil
    end,
    build = function(self, b)
        local box = widget("numberBox")
        if not box or not box.isOpen then return end
        b:add_label(Id.structural("number"), function(ctx)
            ctx.message:fragment(clean(box.bodyText))
            ctx.message:fragment(tostring(box.number))
            ctx.message:fragment("Left and right to adjust, enter to confirm.")
        end)
    end,
}

-- --------------------------------------------------------------- inventory --
-- Our keygraph over the game's inventory panel. Reads sortedInventory; left/
-- right commit moveCategory (sub-identity resets focus and re-announces the
-- category); enter commits selectItemUnderCursor (equip/use per the game's
-- own logic); space (read_info) speaks the full description.
local inventory = {
    id = "inventory",
    handler = function(self)
        local panel = G_stateGame and G_stateGame.inventoryPanel
        return (panel and panel.isOpen) and "active" or "inactive"
    end,
    sub_identity = function(self)
        local panel = G_stateGame and G_stateGame.inventoryPanel
        if not panel then return nil end
        return "cat" .. tostring(panel.categoryIndex) .. "#" .. tostring(#(panel.sortedInventory or {}))
    end,
    announce = function(self, ctx)
        local panel = G_stateGame.inventoryPanel
        local cat = (G_Globals.categoryTypes and G_Globals.categoryTypes[panel.categoryIndex]) or "items"
        local n = #(panel.sortedInventory or {})
        ctx.message:fragment("Inventory, " .. tostring(cat) .. ", " .. n
            .. (n == 1 and " item." or " items.") .. " Left and right change category.")
    end,
    build = function(self, b)
        local panel = G_stateGame and G_stateGame.inventoryPanel
        if not panel or not panel.isOpen then return end
        b:capture_input()
        local inv = panel.sortedInventory or {}
        local function category_adjust(ctx, sign)
            panel:moveCategory(sign)
            -- sub-identity change re-announces the new category next tick
        end
        if #inv == 0 then
            b:add_item(Id.structural("empty"), {
                label = function(ctx) ctx.message:fragment("Nothing in this category.") end,
                on_horizontal_adjust = category_adjust,
            })
            return
        end
        for i, v in ipairs(inv) do
            local idx, item = i, v
            local function display_name()
                local ok, name = pcall(G_stateGame.getInventoryObjectName, G_stateGame, item.ID)
                return clean((ok and name) or item.name or item.objectType or "item")
            end
            b:start_row("item" .. i)
            b:add_item(Id.referenced(item, "item:" .. tostring(item.ID)), {
                label = function(ctx)
                    ctx.message:fragment(display_name())
                    if (item.count or 1) > 1 then ctx.message:fragment("x " .. item.count) end
                    local ok, worn = pcall(panel.isObjectWornOrWielded, panel, item)
                    if ok and worn then ctx.message:fragment("equipped") end
                    ctx.message:fragment(idx .. " of " .. #inv)
                end,
                on_click = function(ctx)
                    panel.cursorPosition = idx
                    panel:selectItemUnderCursor()
                end,
                on_horizontal_adjust = category_adjust,
                on_read_info = function(ctx)
                    local ok, desc = pcall(G_stateGame.getModifiedObjectDescription, G_stateGame, item)
                    ctx.message:fragment(ok and clean(desc) or "No description.")
                end,
            })
            b:end_row()
        end
    end,
}

-- ---------------------------------------------------------------- top menu --
-- The Escape bar: Character / Inventory / Gods / Notes / Map / Options. One
-- row, left/right; commit mirrors processUICategoryKeys' dispatch
-- (state_game.lua:4906-4941) through the game's own open functions.
local top_menu = {
    id = "top_menu",
    handler = function(self)
        return (G_stateGame and G_stateGame.isTopMenuOpen) and "active" or "inactive"
    end,
    announce = function(self, ctx)
        ctx.message:fragment("Menu bar.")
    end,
    build = function(self, b)
        if not G_stateGame or not G_stateGame.isTopMenuOpen then return end
        b:capture_input()
        local cats = G_stateGame.UICategories or {}
        b:start_row("cats", nil, { wrap = true })
        for i, cat in ipairs(cats) do
            local idx, name = i, cat
            b:add_item(Id.structural("cat:" .. name), {
                label = function(ctx)
                    ctx.message:fragment(name)
                    ctx.message:fragment(idx .. " of " .. #cats)
                end,
                on_click = function(ctx)
                    local game = G_stateGame
                    game.UICategoryIndex = idx
                    if name == "Inventory" and game.isAnimationBlocking then
                        game:openAlertBox("You cannot look in your pack while you are attacking or being attacked.")
                        return
                    end
                    game:toggleIsTopMenuOpen()
                    if name == "Character" then
                        game.showCharacterPanel = true
                        G_playSound("page_open")
                    elseif name == "Inventory" then
                        game:setIsInventoryPanelOpen(not game.inventoryPanel.isOpen)
                    elseif name == "Notes" then
                        game:setIsNotePanelOpen(not game.notePanel.isOpen)
                    elseif name == "Map" then
                        if not game.isMapOpen then game:toggleMap(); G_playSound("page_open") end
                    elseif name == "Gods" then
                        game:setIsSkillTreeOpen(true)
                    elseif name == "Options" then
                        game:openOptionsScreen()
                    end
                end,
            })
        end
        b:end_row()
    end,
}

-- -------------------------------------------------------------- title idle --
-- The attract screen is pure art with no widget: without this, every key is
-- silent until Enter happens to open the menu. One captured node announces
-- the situation (delayed a beat so NVDA's window-focus chatter settles), any
-- direction key re-reads it, Enter opens the menu via the game's own path.
local title_idle = {
    id = "title_idle",
    handler = function(self)
        local ok, cur = pcall(gamestate.current)
        if not ok or cur ~= G_stateTitleScreen then return "inactive" end
        local hooks = require("ma_hooks")
        if (hooks.state.frame or 0) < 150 then return "inactive" end
        local t = G_stateTitleScreen
        for _, w in ipairs({ "multiChoiceBox", "textInputBox", "alertBox", "confirmBox" }) do
            if t[w] and t[w].isOpen then return "inactive" end
        end
        return "active"
    end,
    build = function(self, b)
        b:capture_input()
        b:add_item(Id.structural("begin"), {
            label = function(ctx)
                ctx.message:fragment("Moonring title screen. Press Enter to begin.")
            end,
            on_click = function(ctx)
                G_stateTitleScreen:openOptionsScreen()
            end,
        })
    end,
}

-- Bottom-to-top: the topmost open modal wins, mirroring getUIInput order.
function M.register_all()
    dispatcher.register(title_idle)
    dispatcher.register(top_menu)
    dispatcher.register(inventory)
    dispatcher.register(multi_choice)
    dispatcher.register(confirm)
    dispatcher.register(number_box)
    dispatcher.register(text_input)
    dispatcher.register(tutorial)
    dispatcher.register(alert)
end

return M
