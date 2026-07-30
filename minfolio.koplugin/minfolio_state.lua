-- SPDX-License-Identifier: AGPL-3.0-only
-- Persisted editor state (scale, per-note cursor/scroll positions) for
-- minfolio.koplugin (PLAN.md §5 Tier 1). NOT KOReader-free: `save_minfolio_state`
-- calls `lfs.mkdir` (KOReader's bundled `libs/libkoreader-lfs`, required at the
-- top of this module), and this module requires minfolio_config/minfolio_io,
-- neither of which is off-device-loadable either (see their headers). So this
-- module cannot be `require`d and executed under plain luajit -- only
-- `loadfile`-parsed, exactly like main.lua itself. No test suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 1, §10 step 4):
-- clamp_minfolio_scale, read_minfolio_state, MINFOLIO_STATE, save_minfolio_state.
--
-- Deliberately EXCLUDES read_frontlight_state: despite sitting in the same region
-- of main.lua as the functions above, it is frontlight state, not editor state,
-- and is assigned to a later work package's minfolio_frontlight.lua (PLAN.md §4
-- correction 5, §5 Tier 1).
--
-- Required by callers as `local State = require("minfolio_state")`.

local Config = require("minfolio_config")
local IO = require("minfolio_io")
local lfs = require("libs/libkoreader-lfs")

local M = {}

function M.clamp_minfolio_scale(scale)
    return math.max(0.6, math.min(1.8, tonumber(scale) or 1.0))
end

function M.read_minfolio_state()
    local ok, state = pcall(dofile, Config.MINFOLIO_STATE_PATH)
    return (ok and type(state) == "table") and state or {}
end

M.MINFOLIO_STATE = M.read_minfolio_state()
M.MINFOLIO_STATE.scale = M.clamp_minfolio_scale(M.MINFOLIO_STATE.scale or Config.CONFIG.minfolio_scale)
M.MINFOLIO_STATE.positions = type(M.MINFOLIO_STATE.positions) == "table" and M.MINFOLIO_STATE.positions or {}

function M.save_minfolio_state()
    lfs.mkdir(Config.STATE_DIR)
    local positions = {}
    for path, position in pairs(M.MINFOLIO_STATE.positions) do
        if type(path) == "string" and type(position) == "table" then
            local line = math.max(1, math.floor(tonumber(position.line) or 1))
            local ri = math.max(1, math.floor(tonumber(position.ri) or 1))
            local crow = math.max(1, math.floor(tonumber(position.crow) or 1))
            local ccol = math.max(0, math.floor(tonumber(position.ccol) or 0))
            positions[#positions + 1] = string.format(
                "[%q] = { line = %d, ri = %d, kind = %q, crow = %d, ccol = %d, reader_mode = %s },",
                path, line, ri, tostring(position.kind or "row"), crow, ccol,
                position.reader_mode and "true" or "false")
        end
    end
    IO.write_file(Config.MINFOLIO_STATE_PATH, string.format(
        "return { scale = %.3f, positions = { %s } }\n",
        M.clamp_minfolio_scale(M.MINFOLIO_STATE.scale), table.concat(positions, " ")))
end

return M
