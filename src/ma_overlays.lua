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

-- Strip the game's {col1}/{white} colour markup for speech.
local function clean(text)
    return (tostring(text or ""):gsub("%b{}", ""))
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

-- Bottom-to-top: the topmost open modal wins, mirroring getUIInput order.
function M.register_all()
    dispatcher.register(multi_choice)
    dispatcher.register(confirm)
    dispatcher.register(number_box)
    dispatcher.register(text_input)
    dispatcher.register(tutorial)
    dispatcher.register(alert)
end

return M
