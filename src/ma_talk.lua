-- ma_talk.lua — the typed-keyword NPC conversation (speech_area.lua) made
-- audible. The game keeps FULL ownership of typing (it is free text); we
-- speak what happens around it:
--   * every NPC line (animalCrossingSpeech carries the exact display string),
--   * the speaker on conversation start (talkTo),
--   * the word the player commits (sayCurrentWord),
--   * autocomplete suggestion changes (currentTypedTag watcher, per pump),
--   * numpad 5 during a conversation: typed-so-far + the visible cloud words.
-- Everything lands in the "conversation" review buffer from conversation
-- start (speaker-prefixed), browsable with Ctrl+arrows.

local hooks = require("ma_hooks")
local speech = require("ma_speech")
local text = require("ma_text")
local buffers = require("ma_buffers")

local st = hooks.state
st.talk = st.talk or {}
local T = st.talk

local M = {}

local function area()
    return G_stateGame and G_stateGame.speechArea
end

function M.install()
    -- Every spoken NPC line funnels through animalCrossingSpeech with the
    -- final display string (state_game.lua:22583).
    hooks.wrap(G_stateGame, "animalCrossingSpeech", function(orig, self, str, masc, id, forced_pitch)
        pcall(function()
            local clean = text.clean(str)
            if clean ~= "" then
                local a = area()
                local who = (a and a.isOpen and a.speakerDisplayName) and text.clean(a.speakerDisplayName) or "NPC"
                speech.say(clean, false)
                buffers.add("conversation", who .. ": " .. clean)
            end
        end)
        return orig(self, str, masc, id, forced_pitch)
    end)

    -- Conversation start: announce the speaker; mark the buffer.
    if CSpeechArea then
        hooks.wrap(CSpeechArea, "talkTo", function(orig, self, name, display_name, is_livestock)
            -- The game re-enters talkTo mid-conversation (keyword responses);
            -- only a genuinely fresh open announces.
            local fresh = not self.isOpen
            pcall(function()
                if fresh then
                    local who = text.clean(display_name or name or "someone")
                    speech.say("Talking to " .. who .. ". Type words, tab completes, enter says.", true)
                    buffers.add("conversation", "--- " .. who .. " ---")
                end
            end)
            return orig(self, name, display_name, is_livestock)
        end)

        -- The word the player commits — spoken BEFORE the reply it triggers.
        hooks.wrap(CSpeechArea, "sayCurrentWord", function(orig, self)
            pcall(function()
                local word = (self.currentTypedTag ~= "" and self.currentTypedTag) or self.string
                if word and word ~= "" then
                    local clean = text.clean(word)
                    speech.say("You say " .. clean .. ".", false)
                    buffers.add("conversation", "You: " .. clean)
                end
            end)
            return orig(self)
        end)
    end
end

-- Pump watcher: speak autocomplete suggestion changes while typing.
function M.tick()
    local a = area()
    if not a or not a.isOpen then
        T.last_tag = nil
        return
    end
    local tag = a.currentTypedTag
    if tag and tag ~= "" and tag ~= T.last_tag then
        T.last_tag = tag
        speech.say(text.clean(tag), true)
    elseif tag == "" then
        T.last_tag = nil
    end
end

function M.in_conversation()
    local a = area()
    return a and a.isOpen or false
end

-- Numpad 5 during a conversation: what's typed + the floating cloud words.
function M.status()
    local a = area()
    if not a or not a.isOpen then return end
    local parts = {}
    if a.string and a.string ~= "" then
        parts[#parts + 1] = "Typed: " .. text.clean(a.string)
    end
    if a.currentTypedTag and a.currentTypedTag ~= "" then
        parts[#parts + 1] = "suggests " .. text.clean(a.currentTypedTag)
    end
    local words = {}
    for _, t in ipairs(a.floatingTags or {}) do
        local w = text.clean(t.text or "")
        if w ~= "" then words[#words + 1] = w end
    end
    if #words > 0 then
        parts[#parts + 1] = "cloud words: " .. table.concat(words, ", ")
    end
    if #parts == 0 then parts[1] = "Nothing typed, no cloud words visible." end
    speech.say(table.concat(parts, ". ") .. ".", true)
end

return M
