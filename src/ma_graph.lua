-- overlay/graph.lua — graph nodes + the builder overlays declare controls into
-- (port of Tanglebeep's GraphNode/GraphBuilder, from Factorio Access menu.lua).
--
-- A NODE is { id, vtable, trans = { up/down/left/right -> transition } }; a
-- TRANSITION is { to = <structural key>, label = fn(ctx)? } (the label speaks
-- only while crossing that edge — used for row/lane announcements). A VTABLE is
-- a plain table of behaviors: label (required; fn(ctx) appending speech to
-- ctx.message) plus optional on_click(ctx, mods), on_horizontal_adjust(ctx,
-- sign, large), and future action slots (on_read_info, ...).
--
-- Two construction styles, never mixed in one build:
--   RAW GRAPH  add_node/connect/set_start — arbitrary nodes + directional edges.
--   MENU SUGAR start_row/add_item/add_label/add_clickable/end_row — rows give
--     2-D navigation (left/right within a row; up/down between rows always
--     lands on the target row's `enter` item or its FIRST item — no column
--     preservation; wire true columns with explicit connect overrides). The
--     row key is currently informational only.
--     Extensions over the C# original: start_row takes an optional row LABEL
--     fn(ctx), spoken as the transition label when vertical navigation ENTERS
--     the row from a different row (the container/lane announcement), and an
--     optional opts table ({ wrap = true } wraps left/right around the ends;
--     { enter = i } sets the vertical landing item).
--
-- STOPS (wotr-access Tab-stops): begin_stop(key, label) groups the rows that
-- follow into one Tab-reachable pane. Arrows never cross a stop (vertical
-- edges are only lowered between rows of the SAME stop); Tab cycles stops in
-- declaration order, landing on the stop's remembered position (keygraph).
-- The key must be stable across rebuilds — it keys the stop memory. An
-- overlay that never calls begin_stop is one implicit unnamed stop.
--
-- build() returns a render { nodes = { [key] = node }, start_key, decl_order,
-- stops = { {key, label, start_key} ... }, force_capture } or nil when empty
-- (the engine treats that as closed).
local Builder = {}
Builder.__index = Builder

function Builder.new()
    return setmetatable({
        rows = {},          -- menu mode: { { items = {entry...}, key = ?, label = fn? } ... }
        current_row = nil,
        raw_order = {},     -- raw mode: declared ids in order
        raw_nodes = {},     -- [key] = { id, vtable }
        raw_edges = {},     -- { from = id, dir = d, to = id }
        start_id = nil,
        stops = {},         -- { { key, label, first_row } ... } in declaration order
        force_capture = false,
    }, Builder)
end

local function check_vtable(vtable)
    assert(type(vtable) == "table" and type(vtable.label) == "function",
        "a control must have a label function")
end

-- --- Raw graph API -----------------------------------------------------------

function Builder:add_node(id, vtable)
    check_vtable(vtable)
    assert(self.raw_nodes[id.key] == nil, "duplicate control id")
    self.raw_order[#self.raw_order + 1] = id
    self.raw_nodes[id.key] = { id = id, vtable = vtable }
    return self
end

-- In raw mode: a directional edge between declared nodes. In MENU mode: an
-- edge OVERRIDE applied after the rows are lowered — set a custom transition,
-- or pass to = nil to REMOVE the lowered edge (e.g. a column with nothing
-- beneath it stops instead of falling to another column). `label` (fn(ctx),
-- optional) speaks while crossing that edge — tables use it for column
-- headers and row names.
function Builder:connect(from, dir, to, label)
    self.raw_edges[#self.raw_edges + 1] = { from = from, dir = dir, to = to, label = label }
    return self
end

-- Focus lands here when there is no prior position; defaults to the first node.
function Builder:set_start(id)
    self.start_id = id
    return self
end

-- --- Menu sugar --------------------------------------------------------------

-- Begin a Tab-stop: every row added after this call belongs to it, until the
-- next begin_stop. `label` is a plain string (or nil), spoken when Tab lands
-- in the stop. Menu mode only.
function Builder:begin_stop(key, label)
    assert(self.current_row == nil, "cannot begin a stop inside a row")
    self.stops[#self.stops + 1] = {
        key = key or ("stop#" .. (#self.stops + 1)),
        label = label,
        first_row = #self.rows + 1,
    }
    return self
end

-- row_opts: { wrap = true } makes left/right wrap around the row's ends;
-- { enter = i } makes vertical navigation arriving from another row land on
-- item i instead of the first item (e.g. the current blind).
function Builder:start_row(row_key, row_label, row_opts)
    assert(self.current_row == nil, "cannot start a row while another is open")
    self.current_row = { items = {}, key = row_key, label = row_label,
        wrap = row_opts and row_opts.wrap,
        enter = row_opts and row_opts.enter,
        stop = #self.stops }
    return self
end

function Builder:end_row()
    assert(self.current_row ~= nil, "no row to end")
    assert(#self.current_row.items > 0, "row cannot be empty")
    self.rows[#self.rows + 1] = self.current_row
    self.current_row = nil
    return self
end

-- Add a control to the current row (or as its own single-item row).
function Builder:add_item(id, vtable)
    check_vtable(vtable)
    local entry = { id = id, vtable = vtable }
    if self.current_row then
        self.current_row.items[#self.current_row.items + 1] = entry
    else
        self.rows[#self.rows + 1] = { items = { entry }, stop = #self.stops }
    end
    return self
end

-- A read-only control that just speaks its label.
function Builder:add_label(id, label)
    return self:add_item(id, { label = label })
end

-- A control that speaks a label and runs on_click on activation.
function Builder:add_clickable(id, label, on_click)
    return self:add_item(id, { label = label, on_click = on_click })
end

-- Declare that this overlay owns keyboard input (a declared property, not
-- inferred from node count). Non-capturing overlays leave input to the game.
function Builder:capture_input()
    self.force_capture = true
    return self
end

-- --- Lowering ----------------------------------------------------------------

-- Where vertical navigation lands in row `to`: its declared enter item, else
-- its FIRST item — never a preserved column position (variable-length rows
-- made index-preserving landings confusing; true column behavior, like the
-- blind panels' select/skip pairs, is wired with explicit connect overrides).
local function vertical_target(from, to, pos)
    if to.enter and to.items[to.enter] then return to.items[to.enter].id end
    return to.items[1].id
end

local function build_menu(self)
    assert(self.current_row == nil, "unclosed row - call end_row()")
    if #self.rows == 0 then return nil end

    local render = { nodes = {}, decl_order = {}, stops = {} }
    for _, row in ipairs(self.rows) do
        for _, item in ipairs(row.items) do
            assert(render.nodes[item.id.key] == nil, "duplicate control id")
            render.nodes[item.id.key] = { id = item.id, vtable = item.vtable, trans = {} }
            render.decl_order[#render.decl_order + 1] = item.id.key
        end
    end

    -- Honor an explicit set_start naming a real node; else first item, first row.
    render.start_key = (self.start_id and render.nodes[self.start_id.key])
        and self.start_id.key or self.rows[1].items[1].id.key

    -- Publish only stops that ended up with at least one row (an empty
    -- category pane simply isn't in the Tab ring this rebuild).
    local stop_start = {}
    for _, row in ipairs(self.rows) do
        if row.stop and row.stop > 0 and not stop_start[row.stop] then
            stop_start[row.stop] = row.items[1].id.key
        end
    end
    for i, s in ipairs(self.stops) do
        if stop_start[i] then
            render.stops[#render.stops + 1] =
                { key = s.key, label = s.label, start_key = stop_start[i] }
        end
    end

    for row_idx, row in ipairs(self.rows) do
        local first_key = row.items[1].id.key
        local last_key = row.items[#row.items].id.key
        local stop_key = (row.stop and row.stop > 0) and self.stops[row.stop].key or nil
        -- Vertical neighbors skip rows of OTHER stops: arrows never leave a
        -- stop, Tab is the only way across.
        local above, below = nil, nil
        for i = row_idx - 1, 1, -1 do
            if self.rows[i].stop == row.stop then above = self.rows[i]; break end
        end
        for i = row_idx + 1, #self.rows do
            if self.rows[i].stop == row.stop then below = self.rows[i]; break end
        end
        for pos, item in ipairs(row.items) do
            local node = render.nodes[item.id.key]
            -- Row metadata for Home/End: inside a multi-item row those jump
            -- to ITS ends (innermost structure wins); also disambiguates
            -- wrapped rows, whose transitions form an edgeless cycle.
            node.row_edges = { first = first_key, last = last_key, size = #row.items }
            node.stop_key = stop_key
            if above then
                node.trans.up = { to = vertical_target(row, above, pos).key, label = above.label }
            end
            if below then
                node.trans.down = { to = vertical_target(row, below, pos).key, label = below.label }
            end
            if pos > 1 then node.trans.left = { to = row.items[pos - 1].id.key }
            elseif row.wrap and #row.items > 1 then node.trans.left = { to = row.items[#row.items].id.key } end
            if pos < #row.items then node.trans.right = { to = row.items[pos + 1].id.key }
            elseif row.wrap and #row.items > 1 then node.trans.right = { to = row.items[1].id.key } end
        end
    end

    -- Apply explicit edge overrides on top of the lowered rows (see connect).
    for _, e in ipairs(self.raw_edges) do
        local from = render.nodes[e.from.key]
        if from then
            if e.to == nil then
                from.trans[e.dir] = nil
            elseif render.nodes[e.to.key] then
                from.trans[e.dir] = { to = e.to.key, label = e.label }
            end
        end
    end
    return render
end

local function build_raw(self)
    local render = { nodes = {}, decl_order = {}, stops = {} }
    for _, id in ipairs(self.raw_order) do
        local e = self.raw_nodes[id.key]
        render.nodes[id.key] = { id = e.id, vtable = e.vtable, trans = {} }
        render.decl_order[#render.decl_order + 1] = id.key
    end
    for _, edge in ipairs(self.raw_edges) do
        -- Skip edges to/from controls that were never declared (and nil-to
        -- removals, which are only meaningful as menu-mode overrides).
        if edge.to and render.nodes[edge.from.key] and render.nodes[edge.to.key] then
            render.nodes[edge.from.key].trans[edge.dir] = { to = edge.to.key, label = edge.label }
        end
    end
    render.start_key = self.start_id and self.start_id.key or self.raw_order[1].key
    return render
end

function Builder:build()
    local has_raw = next(self.raw_nodes) ~= nil
    local has_menu = #self.rows > 0 or self.current_row ~= nil
    assert(not (has_raw and has_menu),
        "cannot mix raw graph (add_node/connect) with menu rows in one build")
    local render = has_raw and build_raw(self) or build_menu(self)
    if render then render.force_capture = self.force_capture end
    return render
end

return Builder
