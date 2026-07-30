-- SPDX-License-Identifier: AGPL-3.0-only
-- Plugin location, local config file, and on-disk state paths for minfolio.koplugin
-- (PLAN.md §5 Tier 1). NOT KOReader-free: the state-directory migration block below
-- calls `lfs.attributes`/`lfs.mkdir` (KOReader's bundled `libs/libkoreader-lfs`,
-- required at the top of this module) unconditionally at module-load time, so this
-- module cannot be `require`d and executed under plain luajit -- only `loadfile`-
-- parsed, exactly like main.lua itself. `plugin_dir`/`load_local_config` are pure
-- Lua (`debug.getinfo`, `dofile`, `pcall`) and would be off-device-testable in
-- isolation, but the module as a whole is not, so no test suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 1, §10 step 4):
-- plugin_dir, load_local_config, CONFIG, NOTES_DIR, STATE_DIR, FL_STATE_PATH,
-- MINFOLIO_STATE_PATH, the lfs state-directory migration block, and path_parent
-- (it reads NOTES_DIR, which is why it lives here and not in minfolio_text).
--
-- MINFOLIO_REMOTE_DIR and MINFOLIO_PAIR_PATH were bare globals before this move
-- (main.lua:64/67, forced by the 200-local ceiling this refactor removes -- see
-- PLAN.md §1/§6.4). They are now ordinary fields of this module's returned table.
-- Confirmed by repo-wide grep (including minfolio_sync.lua/.sh, which run as a
-- separate process with their own LUA_PATH) that nothing outside main.lua read
-- either name as a global.
--
-- Required by callers as `local Config = require("minfolio_config")`.

local lfs = require("libs/libkoreader-lfs")

local M = {}

function M.plugin_dir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    return src:match("^(.*)/[^/]*$") or "."
end

function M.load_local_config()
    local ok, cfg = pcall(dofile, M.plugin_dir() .. "/config.lua")
    if ok and type(cfg) == "table" then
        return cfg
    end
    return {}
end

M.CONFIG = M.load_local_config()
M.NOTES_DIR = M.CONFIG.notes_dir or "/mnt/us/notes"
M.STATE_DIR = M.CONFIG.state_dir or "/mnt/us/.minfolio"
M.MINFOLIO_REMOTE_DIR = "/mnt/us/.minfolio-remote"
M.FL_STATE_PATH = M.STATE_DIR .. "/frontlight.lua"
M.MINFOLIO_STATE_PATH = M.STATE_DIR .. "/state.lua"
M.MINFOLIO_PAIR_PATH = M.STATE_DIR .. "/pairing.lua"
-- Migrate only the old persistent settings; remote session caches are disposable.
if not M.CONFIG.state_dir and lfs.attributes("/mnt/us/minfolio", "mode") == "directory" and lfs.attributes(M.STATE_DIR, "mode") ~= "directory" then
    lfs.mkdir(M.STATE_DIR)
    os.rename("/mnt/us/minfolio/state.lua", M.MINFOLIO_STATE_PATH)
    os.rename("/mnt/us/minfolio/frontlight.lua", M.FL_STATE_PATH)
end

function M.path_parent(path)
    path = tostring(path or M.NOTES_DIR):gsub("/+$", "")
    if path == "" or path == "/" then return "/" end
    local p = path:match("^(.*)/[^/]+$")
    if not p or p == "" then return "/" end
    return p
end

return M
