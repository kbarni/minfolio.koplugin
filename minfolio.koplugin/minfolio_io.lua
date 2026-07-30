-- SPDX-License-Identifier: AGPL-3.0-only
-- File I/O and timing helpers for minfolio.koplugin (PLAN.md §5 Tier 1). NOT
-- KOReader-free: `file_signature` calls `lfs.attributes` (KOReader's bundled
-- `libs/libkoreader-lfs`, required at the top of this module) and `now_seconds`
-- reads `socket.gettime` (`socket`, also required at the top). Neither is a
-- stock rock available under plain luajit outside a KOReader checkout (verified:
-- `luajit -e 'require("libs/libkoreader-lfs")'` and `require("socket")` both fail
-- to resolve in this environment), so this module cannot be `require`d and
-- executed off-device -- only `loadfile`-parsed, exactly like main.lua itself.
-- `write_file`/`read_file`/`same_file_signature` are themselves pure Lua, but the
-- module's top-level requires make the file as a whole non-off-device-loadable,
-- so no test suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 1, §10 step 4):
-- write_file, read_file, file_signature, same_file_signature, now_seconds.
--
-- Required by callers as `local IO = require("minfolio_io")`.

local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")

local M = {}

function M.now_seconds()
    return (socket and socket.gettime and socket.gettime()) or os.time()
end

function M.write_file(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

function M.read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

function M.file_signature(path)
    local ok, attr = pcall(lfs.attributes, path)
    if not ok or type(attr) ~= "table" then return nil end
    return {
        mode = attr.mode or "",
        size = tonumber(attr.size) or 0,
        modification = tonumber(attr.modification) or 0,
    }
end

function M.same_file_signature(a, b)
    if a == b then return true end
    if not a or not b then return false end
    return a.mode == b.mode and a.size == b.size and a.modification == b.modification
end

return M
