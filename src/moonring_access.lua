-- moonring_access.lua — MoonringAccess boot module, injected by lovely at the
-- end of love.load. Everything the mod does hangs off M.boot(); a boot failure
-- must never take the game down, so the whole thing runs under pcall and
-- reports into the lovely console + a marker file.

local M = {}

function M.boot()
    local ok, err = pcall(function()
        -- Phase 0 smoke test: prove injection and record the real save dir.
        local info = "MoonringAccess injected\n"
            .. "identity: " .. tostring(love.filesystem.getIdentity()) .. "\n"
            .. "save dir: " .. tostring(love.filesystem.getSaveDirectory()) .. "\n"
            .. "fused: " .. tostring(love.filesystem.isFused()) .. "\n"
            .. "love: " .. table.concat({love.getVersion()}, ".", 1, 3) .. "\n"
        love.filesystem.write("moonring_access_smoke.txt", info)
        print("[MoonringAccess] " .. info:gsub("\n", "; "))
    end)
    if not ok then
        print("[MoonringAccess] boot error: " .. tostring(err))
    end
end

return M
