-- ma_speech.lua — screen-reader output for MoonringAccess.
--
-- Primary backend is Prism (https://github.com/ethindp/prism, MPL-2.0): one
-- native library abstracting over screen readers and TTS engines (NVDA, JAWS,
-- SAPI, OneCore, ...), loaded via LuaJIT FFI. Ported from Blindfold's
-- speech.lua, which in turn ports wotr-access's PrismHandler. A log fallback
-- always runs, and an observer tap fires for EVERY say() upstream of both the
-- mute gate and Prism — that is how the dev server records speech the agent
-- can't hear (and how muted test runs stay verifiable).
--
-- MOONRING_ACCESS_MUTE=1 (set by scripts/launch.ps1 unless -Speak) suppresses
-- Prism output entirely; logging and the observer still run.
--
-- Native handles live in hooks.state.speech so a /reload never re-inits Prism.

local ffi = require("ffi")
local bit = require("bit")
local hooks = require("ma_hooks")

local st = hooks.state
st.speech = st.speech or { loaded = false }
local S = st.speech

local M = {}
M.observer = nil   -- function(text) — set by the dev server

-- cdefs are process-global in LuaJIT: guard against re-declaration on reload.
if not st.speech_cdef_done then
    ffi.cdef([[
        int   MultiByteToWideChar(unsigned int cp, unsigned long flags,
                                  const char* mb, int cbmb, wchar_t* wc, int cchwc);
        void* LoadLibraryW(const wchar_t* path);

        typedef struct prism_ctx prism_ctx;
        typedef struct prism_backend prism_backend;

        prism_ctx*     prism_init(void* config);
        void           prism_shutdown(prism_ctx* ctx);
        size_t         prism_registry_count(prism_ctx* ctx);
        uint64_t       prism_registry_id_at(prism_ctx* ctx, size_t index);
        const char*    prism_registry_name(prism_ctx* ctx, uint64_t id);
        prism_backend* prism_registry_create(prism_ctx* ctx, uint64_t id);
        prism_backend* prism_registry_create_best(prism_ctx* ctx);
        int            prism_backend_initialize(prism_backend* backend);
        void           prism_backend_free(prism_backend* backend);
        uint64_t       prism_backend_get_features(prism_backend* backend);
        const char*    prism_backend_name(prism_backend* backend);
        int            prism_backend_speak(prism_backend* backend, const char* text_utf8, bool interrupt);
        int            prism_backend_output(prism_backend* backend, const char* text_utf8, bool interrupt);
        int            prism_backend_stop(prism_backend* backend);
    ]])
    st.speech_cdef_done = true
end

local OK = 0
local NOT_IMPLEMENTED = 9
local SUPPORTS_OUTPUT = 0x20   -- prism_backend_get_features bit

local LOG_FILE = "moonring_access.log"

local function log(text)
    pcall(function()
        love.filesystem.append(LOG_FILE, os.date("%H:%M:%S ") .. text .. "\n")
    end)
end
M.log = log

-- UTF-8 Lua string -> null-terminated UTF-16LE buffer for the wide Win32 API.
-- ffi.load routes through the ANSI LoadLibraryA, which garbles non-ASCII
-- install paths; we load the DLL ourselves through the wide API, then bind by
-- bare name to the already-loaded module.
local CP_UTF8 = 65001
local function to_wide(s)
    local n = ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, -1, nil, 0)
    if n <= 0 then return nil end
    local buf = ffi.new("wchar_t[?]", n)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, -1, buf, n)
    return buf
end

function M.muted()
    return os.getenv("MOONRING_ACCESS_MUTE") ~= nil
end

-- Load Prism from the mod's lib/ folder and acquire the best backend. mod_dir
-- is the deployed mod path (through the junction is fine for LoadLibraryW).
function M.init(mod_dir)
    -- Fresh log each session (init runs once; reloads skip down below).
    if not S.log_started then
        pcall(function()
            love.filesystem.write(LOG_FILE, os.date("%Y-%m-%d %H:%M:%S") .. " MoonringAccess session start\n")
        end)
        S.log_started = true
    end
    if S.loaded then return true end   -- reload: Prism already up

    local lib_dir = (mod_dir .. "/lib"):gsub("/", "\\")
    local ok, err = pcall(function()
        local wide = to_wide(lib_dir .. "\\prism.dll")
        assert(wide and ffi.C.LoadLibraryW(wide) ~= nil,
            "LoadLibraryW failed for " .. lib_dir .. "\\prism.dll")
        S.prism = ffi.load("prism")
        S.ctx = S.prism.prism_init(nil)
        assert(S.ctx ~= nil, "prism_init returned null")
        S.backend = S.prism.prism_registry_create_best(S.ctx)
        assert(S.backend ~= nil, "no usable speech backend on this machine")
        S.supports_output = bit.band(tonumber(S.prism.prism_backend_get_features(S.backend)) or 0,
            SUPPORTS_OUTPUT) ~= 0
        S.loaded = true
    end)
    if S.loaded then
        local name = S.prism.prism_backend_name(S.backend)
        log("Prism loaded (backend: " .. (name ~= nil and ffi.string(name) or "unknown") .. ")"
            .. (M.muted() and " [MUTED]" or ""))
    else
        log("Prism NOT loaded (" .. tostring(err) ..
            "). Drop the x64 prism.dll into " .. lib_dir .. " . Running with log output only.")
    end
    return S.loaded
end

-- Speak text. interrupt defaults to false (never cut off in-progress speech
-- unless the caller means it). The observer and log fire unconditionally.
function M.say(text, interrupt)
    if type(text) ~= "string" or text == "" then return end
    if M.observer then pcall(M.observer, text) end
    log("say: " .. text)
    if not S.loaded or M.muted() then return end
    local cut = interrupt == true
    pcall(function()
        -- output drives speech AND braille where supported; anything but a
        -- clean OK falls through to plain speak so we still produce audio.
        if S.supports_output then
            local e = S.prism.prism_backend_output(S.backend, text, cut)
            if e == OK then return end
            if e ~= NOT_IMPLEMENTED then
                log("prism output error " .. tostring(e) .. ", falling back to speak")
            end
        end
        S.prism.prism_backend_speak(S.backend, text, cut)
    end)
end

function M.silence()
    if S.loaded then pcall(function() S.prism.prism_backend_stop(S.backend) end) end
end

return M
