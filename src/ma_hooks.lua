-- ma_hooks.lua — idempotent monkeypatch helper + the mod's cross-reload state.
--
-- Originals live in a _G registry that survives /reload, so re-running boot
-- rebuilds every wrapper from the ORIGINAL function and never stacks. All mod
-- modules keep reload-surviving state under hooks.state (ring buffers, eval
-- env, prism handles, key queue).

local M = {}

local st = _G.__MoonringAccess
if not st then
    st = {}
    _G.__MoonringAccess = st
end
st.originals = st.originals or {}
M.state = st

-- wrap(tbl, name, wrapper): tbl[name] becomes wrapper(orig, ...).
function M.wrap(tbl, name, wrapper)
    local per = st.originals[tbl]
    if not per then
        per = {}
        st.originals[tbl] = per
    end
    local orig = per[name]
    if orig == nil then
        orig = tbl[name]
        per[name] = orig
    end
    tbl[name] = function(...)
        return wrapper(orig, ...)
    end
end

-- Restore one wrapped function (used sparingly; mostly wrappers stay for the
-- session).
function M.unwrap(tbl, name)
    local per = st.originals[tbl]
    if per and per[name] ~= nil then
        tbl[name] = per[name]
    end
end

return M
