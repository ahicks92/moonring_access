-- ma_dispatcher.lua — drives the overlay system one tick at a time (port of
-- Blindfold's dispatcher, itself a port of Tanglebeep's OverlayDispatcher).
--
-- Holds an ordered list of overlays (last registered = top of the stack) and,
-- per overlay id, an ephemeral focus cache (the KeyGraph state). Each tick it
-- polls overlays top-down for the first non-"inactive" verdict, builds the
-- winner's graph, reconciles focus, and either applies a player navigation
-- command (our own key handling) or speaks a focus change.
--
-- Overlay contract: { id = <string>, handler = fn(self) -> verdict,
-- build = fn(self, builder), sub_identity = fn(self) -> string?,
-- announce = fn(self, ctx)? }. Verdicts:
--   "active"   — driving a screen: build and process.
--   "sleeping" — conceptually open but ceding the screen for now. Keeps the
--                id's focus cache.
--   "pending"  — the screen is MINE but not ready yet. Keeps the cache and
--                reports engaged so nav keys are swallowed, nothing speaks.
--   "inactive" / nil — not driving; the id's cache is cleared.
--
-- announce (MoonringAccess extension) runs once per fresh open / sub-identity
-- swap, before the focused label — the place for a menu title or modal body.
-- An announce that sets ctx.suppress_focus_label = true speaks alone: the
-- focused node's label is skipped for that event (used when a sub-identity
-- swap is a small in-place change — an inventory category flip — where
-- re-reading the focused row is noise).
--
-- sub_identity marks in-place content swaps: when it changes while the id
-- stays active, treat as a fresh open (reset focus to the start node, ignore a
-- same-frame nav command).
--
-- tick(command) returns nil or a result table:
--   { message = <MessageBuilder?>, focus_ref = <backing object?>,
--     moved/clicked/entered } — the caller hands message to speech.say, which
--   builds it (an empty builder speaks nothing).

local KeyGraph = require("ma_keygraph")
local Builder = require("ma_graph")
local MB = require("ma_mb")

local D = {
    overlays = {},
    cache = {},        -- [id] = { state = KeyGraph state, overlay = overlay }
    subid = {},        -- [id] = last reported sub-identity
    active_last = nil, -- id active last tick (sleeping/pending count as active)
    last_spoken = nil, -- structural key last spoken via the no-command path
    _captures = false,
    _pending = false,
}

-- Command kinds that invoke a named vtable action slot on the focused control.
local NODE_ACTIONS = {
    read_info = "on_read_info",
}

function D.register(overlay)
    D.overlays[#D.overlays + 1] = overlay
end

-- True when the active overlay declared input ownership on its last build.
function D.captures()
    return D._captures
end

-- True while an overlay owns or is settling into the screen.
function D.engaged()
    return D._captures or D._pending
end

-- The id of the overlay that drove the last tick (nil = none). Used by the
-- pump to unbind the tooltip buffer when every overlay is gone.
function D.active_id()
    return D.active_last
end

local function find_active()
    for i = #D.overlays, 1, -1 do
        local o = D.overlays[i]
        local ok, verdict = pcall(o.handler, o)
        if ok and verdict and verdict ~= "inactive" then return o, verdict end
    end
    return nil, "inactive"
end

local function render_cb_for(overlay)
    return function(ctx)
        local b = Builder.new()
        overlay:build(b)
        return b:build()
    end
end

-- Focus side-channel carried on every result: the focused node's backing
-- object + structural key (tooltip-buffer binding identity) and its optional
-- deferred/details producers.
local function focus_fields(graph, state, res)
    local node = state.cur and graph.current and graph.current.nodes[state.cur.key]
    res.focus_ref = state.cur and state.cur.ref
    res.focus_key = state.cur and state.cur.key
    res.deferred = node and node.vtable.deferred or nil
    res.details = node and node.vtable.details or nil
    -- on_focus (optional vtable slot): write-only game-cursor sync, so game
    -- code keyed off its own cursor (digit shortcut binding, hover text)
    -- follows OUR focus. Runs after every focus-landing event; idempotent.
    if node and node.vtable.on_focus then pcall(node.vtable.on_focus) end
    return res
end

local function apply_nav(graph, state, ctx, message, command)
    local kind = command.kind

    local slot = NODE_ACTIONS[kind]
    if slot then
        local acted = graph:invoke_node_action(ctx, slot)
        return focus_fields(graph, state,
            { message = message, spoke_label = not acted })
    end

    if kind == "confirm" then
        local acted = graph:click(ctx, command.mods)
        D.last_spoken = state.cur and state.cur.key
        return focus_fields(graph, state,
            { message = message, clicked = true, spoke_label = not acted })
    end

    if kind == "stop_move" then
        local moved = graph:move_stop(ctx, command.dir == "right" and 1 or -1)
        D.last_spoken = state.cur and state.cur.key
        return focus_fields(graph, state,
            { message = message, moved = moved, spoke_label = true })
    end

    -- A value control (a slider) intercepts plain horizontal MOVES to adjust
    -- instead of moving focus (Shift = coarse step); vertical input always
    -- navigates. Home/End are never adjust — they must reach move_to_edge,
    -- or any control with a horizontal adjust (every inventory item's
    -- category switch, sliders) swallows them.
    local dir = command.dir
    if kind == "move" and (dir == "left" or dir == "right")
        and graph:try_horizontal_adjust(ctx, dir == "right" and 1 or -1,
            command.mods and command.mods.shift) then
        return { message = message }
    end

    local moved
    if kind == "move_to_edge" then
        moved = graph:move_to_edge(ctx, dir)
    else
        moved = graph:move(ctx, dir)
    end
    D.last_spoken = state.cur and state.cur.key
    return focus_fields(graph, state,
        { message = message, moved = moved, spoke_label = true })
end

local function build_and_process(overlay, command)
    local entry = D.cache[overlay.id]
    if not entry then
        entry = { state = {}, overlay = overlay }
        D.cache[overlay.id] = entry
    end
    local state = entry.state

    -- Generation check: an in-place content swap behaves as a fresh open.
    if overlay.sub_identity then
        local now = overlay:sub_identity()
        local prev = D.subid[overlay.id]
        D.subid[overlay.id] = now
        if prev ~= nil and prev ~= now then
            state.cur = nil
            D.last_spoken = nil
            command = nil
        end
    end

    local message = MB.new()
    local ctx = { message = message, mods = (command and command.mods) or {} }
    local graph = KeyGraph.new(render_cb_for(overlay), state)

    if not graph:rerender(ctx) then
        D.cache[overlay.id] = nil
        D.subid[overlay.id] = nil
        D.active_last = nil
        D.last_spoken = nil
        D._captures = false
        return nil
    end

    D._captures = graph.current.force_capture and true or false

    if command then
        return apply_nav(graph, state, ctx, message, command)
    end

    -- No command: speak the focus label only when it changed (a fresh open, a
    -- reconcile jump after the focused control vanished, or a suggested move).
    local cur = state.cur
    if not cur or cur.key == D.last_spoken then return nil end
    local fresh = D.last_spoken == nil
    D.last_spoken = cur.key
    if fresh and overlay.announce then
        pcall(overlay.announce, overlay, ctx)
        if ctx.suppress_focus_label then
            return focus_fields(graph, state,
                { message = message, entered = true, spoke_label = false })
        end
        message:sentence()   -- the announcement and the focus label are separate sentences
    end
    local node = graph.current.nodes[cur.key]
    if node and node.vtable.label then node.vtable.label(ctx) end
    return focus_fields(graph, state,
        { message = message, entered = true, spoke_label = true })
end

-- Run one frame, optionally applying a player navigation command:
--   { kind = "move"|"move_to_edge"|"confirm"|<NODE_ACTIONS key>,
--     dir = "up"|"down"|"left"|"right" (moves only), mods = {ctrl,shift,alt}? }
function D.tick(command)
    local overlay, verdict = find_active()
    local active_id = overlay and overlay.id or nil

    -- Cache lifecycle: an id's cache lives while its OWN handler stays
    -- non-inactive — a menu under an alert keeps the player's position
    -- through the round-trip, while a screen that actually closed clears.
    for id, entry in pairs(D.cache) do
        if id ~= active_id then
            local ok, v = pcall(entry.overlay.handler, entry.overlay)
            if not ok or not v or v == "inactive" then
                D.cache[id] = nil
                D.subid[id] = nil
            end
        end
    end
    if D.active_last ~= active_id then D.last_spoken = nil end
    D.active_last = active_id

    D._pending = (verdict == "pending") or false
    if not overlay or verdict == "sleeping" or verdict == "pending" then
        D._captures = false
        return nil
    end

    return build_and_process(overlay, command)
end

-- Dev introspection: the active overlay as the mod sees it — nodes in
-- traversal order with spoken labels, the cursor, and the directional links.
function D.describe()
    local overlay, verdict = find_active()
    if not overlay then return "overlay: none" end
    if verdict ~= "active" then return "overlay: " .. tostring(overlay.id) .. " (" .. verdict .. ")" end

    local render = render_cb_for(overlay)({ message = MB.new(), mods = {} })
    if not render then return "overlay: " .. tostring(overlay.id) .. " (empty)" end

    local entry = D.cache[overlay.id]
    local cur = entry and entry.state.cur and entry.state.cur.key or render.start_key
    local function label_of(node)
        local m = MB.new()
        local ok = pcall(node.vtable.label, { message = m, mods = {} })
        return ok and (m:build() or "") or "<label error>"
    end

    local lines = { "overlay: " .. tostring(overlay.id)
        .. " (capture=" .. tostring(render.force_capture or false) .. ")" }
    for _, key in ipairs(KeyGraph.compute_order(render)) do
        local node = render.nodes[key]
        if node then
            local parts = { (key == cur) and "> \"" or "  \"", label_of(node), "\"" }
            for dir, t in pairs(node.trans) do
                local dest = render.nodes[t.to]
                parts[#parts + 1] = "  " .. dir .. "->\"" .. (dest and label_of(dest) or "?") .. "\""
            end
            lines[#lines + 1] = table.concat(parts)
        end
    end
    return table.concat(lines, "\n")
end

return D
