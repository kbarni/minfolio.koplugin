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

-- Both writers below check `write` AND `close`. Checking only `write` is not
-- enough: io.write is buffered, so a short-disk / unmounted-volume failure is
-- routinely first reported by close(), and Lua's file:write returns the handle
-- (truthy) having queued bytes that never reach the disk. `/mnt/us` disappearing
-- mid-session is normal on a Kindle -- plugging in USB unmounts it while the
-- editor keeps autosaving -- so this is the expected path, not a corner case.
local function write_and_close(f, data)
    local ok_write, werr = f:write(data)
    local ok_close, cerr = f:close()
    if not ok_write then return false, werr or "write failed" end
    if not ok_close then return false, cerr or "close failed" end
    return true
end

function M.write_file(path, data)
    local f, oerr = io.open(path, "wb")
    if not f then return false, oerr or "could not open for writing" end
    return write_and_close(f, data)
end

-- Crash-safe replacement: write a sibling temp file, fsync-by-close, then rename
-- over the target. `io.open(path, "w")` truncates the destination *before* the
-- first byte is written, so a plain write that then fails leaves the file empty
-- or half-written -- for a notes file that is the user's document, destroyed by
-- the very autosave meant to protect it. Renaming within the same directory is a
-- metadata operation that either happens or doesn't, so the previous contents
-- survive every failure. This is the same discipline minfolio_pairing_store.lua
-- already applies to pairing metadata and minfolio_sync.lua to the remote inbox;
-- the notes themselves were the one thing still written in place.
--
-- Returns true, or false plus a reason. The temp file is removed on every
-- failure path so a failed save cannot leave litter next to the note.
function M.write_file_atomic(path, data)
    local tmp = path .. ".minfolio-tmp"
    local f, oerr = io.open(tmp, "wb")
    if not f then return false, oerr or "could not open the temporary file" end
    local ok, err = write_and_close(f, data)
    if not ok then
        os.remove(tmp)
        return false, err
    end
    local renamed, rerr = os.rename(tmp, path)
    if not renamed then
        os.remove(tmp)
        return false, rerr or "could not replace the original file"
    end
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
