-- overlay/message_builder.lua — fluent speech accumulator (port of Tanglebeep's
-- MessageBuilder, itself a port of Factorio Access's speech.lua builder).
--
-- The value it carries is the separation discipline: SEPARATORS AND PUNCTUATION
-- ARE THE BUILDER'S JOB, never the caller's. Consecutive fragments are joined
-- with a space, list_item boundaries with a comma, sentence/exclaim boundaries
-- with terminal punctuation — so a chain of collaborating callbacks each append
-- their piece without coordinating spacing. Boundaries are punctuation-aware:
-- a fragment that already ends punctuated is never double-punctuated.
--
-- Builders nest: fragment/list_item/sentence accept another builder (or any
-- object with :resolve()) and inline its built text as one unit — that is how
-- sortable entries (nearest-first lists) are assembled per-entry and merged
-- into the top-level builder after sorting.
--
-- speech.say() accepts a builder directly and supplies the final full stop;
-- the normal calling convention is to hand say() the builder, unbuilt.
-- Single-use: build() errors if the builder is reused.
local MB = {}
MB.__index = MB

function MB.new()
    return setmetatable({
        parts = {},
        -- "initial" | "list_item" | "fragment" | "fragment_in_list"
        -- | "sentence" | "built"
        state = "initial",
    }, MB)
end

function MB:is_empty() return #self.parts == 0 end

local function check_not_built(self)
    if self.state == "built" then error("attempt to use a MessageBuilder twice", 3) end
end

-- Terminal punctuation a boundary must respect ('.' '!' '?' and ':' — a colon
-- introduces a list and survives sentence boundaries: "Terrain: water. rock.").
local function ends_terminal(s) return s:match("[%.%!%?%:]$") ~= nil end
-- Any trailing punctuation at all (blocks comma insertion).
local function ends_punctuated(s) return s:match("[%,%.%;%:%!%?]$") ~= nil end

-- Append a text fragment. Fragments are separated from preceding content by a
-- space; the first fragment of a fresh list item is preceded by a comma
-- (unless the preceding content already ends punctuated — a "Header:" takes
-- no comma). Nil / empty fragments are ignored so optional pieces can be
-- appended blindly. Accepts another builder (anything with :resolve()) and
-- inlines its text.
function MB:fragment(text)
    check_not_built(self)
    if type(text) == "table" and text.resolve then text = text:resolve() end
    if text == nil or text == "" then return self end
    text = tostring(text)

    -- Opening a new list item: a comma against whatever precedes it.
    if self.state == "list_item" then
        if #self.parts > 0 and not ends_punctuated(self.parts[#self.parts]) then
            self.parts[#self.parts] = self.parts[#self.parts] .. ","
        end
    end
    self.state = (self.state == "list_item" or self.state == "fragment_in_list")
        and "fragment_in_list" or "fragment"

    self.parts[#self.parts + 1] = text
    return self
end

-- Mark a list-item boundary; the next fragment starts a new comma-separated
-- item. The optional fragment is appended right after the boundary.
function MB:list_item(text)
    check_not_built(self)
    self.state = "list_item"
    if text ~= nil then self:fragment(text) end
    return self
end

-- Close the preceding content with `mark`: soft punctuation (, ;) is replaced,
-- terminal punctuation is left alone, bare text gets the mark appended.
local function close_with(self, mark)
    if #self.parts > 0 then
        local last = self.parts[#self.parts]
        if last:match("[%,%;]$") then
            self.parts[#self.parts] = last:sub(1, -2) .. mark
        elseif not ends_terminal(last) then
            self.parts[#self.parts] = last .. mark
        end
    end
    self.state = "sentence"
end

-- Mark a sentence boundary: preceding content is closed with a full stop and
-- the next fragment starts a fresh sentence (and a fresh comma list). The
-- optional fragment is appended right after the boundary.
function MB:sentence(text)
    check_not_built(self)
    close_with(self, ".")
    if text ~= nil then self:fragment(text) end
    return self
end

-- Like sentence() but closes with an exclamation mark (alerts, incoming
-- threats). Call with no argument at the end of a message to punctuate it.
function MB:exclaim(text)
    check_not_built(self)
    close_with(self, "!")
    if text ~= nil then self:fragment(text) end
    return self
end

-- Embeddability: a builder passed to another builder's fragment()/list_item()/
-- sentence() resolves to its built text (nil when empty — ignored upstream).
function MB:resolve()
    if self.state == "built" then return nil end
    return self:build()
end

-- Finalize and return the message, or nil if nothing was appended. The builder
-- is single-use after this.
function MB:build()
    check_not_built(self)
    self.state = "built"
    if #self.parts == 0 then return nil end
    return table.concat(self.parts, " ")
end

return MB
