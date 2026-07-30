-- ma_text.lua — game text -> speakable text.
--
-- Moonring strings carry {col1}/{white} colour markup and private-use glyph
-- characters (U+00E0..U+00FA, injected into the custom bitmap font at
-- main.lua:1094 in glyph_order sequence) standing for input icons. Speech
-- needs the markup stripped and the glyphs named.

local utf8 = require("utf8")

local M = {}

-- glyph_order from main.lua:1096, paired with spoken names.
local GLYPH_NAMES = {
    "A button", "B button", "X button", "Y button", "left bumper",
    "right bumper", "left trigger", "right trigger", "L", "R", "ZL", "ZR",
    "stick", "start", "back", "d-pad up", "d-pad right", "d-pad down",
    "d-pad left", "plus", "minus", "left mouse button", "right mouse button",
    "right stick", "stick 1 click", "stick 2 click", "tick",
}

local GLYPH_MAP = {}
for i, name in ipairs(GLYPH_NAMES) do
    GLYPH_MAP[utf8.char(0xE0 + i - 1)] = name
end

-- Strip {tags}, replace glyph chars with names, drop any other non-ASCII the
-- font can't represent anyway, collapse whitespace.
function M.clean(text)
    if text == nil then return "" end
    local s = tostring(text):gsub("%b{}", "")
    for char, name in pairs(GLYPH_MAP) do
        s = s:gsub(char, name)
    end
    -- Anything else outside printable ASCII is font-private junk for speech.
    s = s:gsub("[\128-\255]", "")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Screen-language relative offset from the player: "3 right, 2 up".
-- Moonring world coords: x grows right (east), y grows DOWN (south).
function M.offset(dx, dy)
    local parts = {}
    if dx ~= 0 then parts[#parts + 1] = math.abs(dx) .. (dx > 0 and " right" or " left") end
    if dy ~= 0 then parts[#parts + 1] = math.abs(dy) .. (dy > 0 and " down" or " up") end
    if #parts == 0 then return "here" end
    return table.concat(parts, ", ")
end

-- Chebyshev distance (grid king-move; matches 4-way travel feel well enough
-- for sorting).
function M.dist(dx, dy)
    return math.max(math.abs(dx), math.abs(dy))
end

-- Counted noun as one atomic phrase: "1 hostile", "3 hostiles". Irregular
-- plurals pass the plural form explicitly.
function M.plural(n, singular, plural)
    local word = n == 1 and singular or (plural or (singular .. "s"))
    return n .. " " .. word
end

return M
