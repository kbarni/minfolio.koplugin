-- SPDX-License-Identifier: AGPL-3.0-only
-- Frontlight (brightness/warmth) control for minfolio.koplugin (PLAN.md §5 Tier 1).
-- Requires KOReader: `lipc_get`/`lipc_set` shell out to the Kindle framework's
-- powerd (`io.popen`/`os.execute`, always available, but the frontlight state
-- they expose only exists on-device), and `FL.captureBeforeSuspend`/
-- `FL.scheduleWakeSync` schedule through `UIManager`. Because it reads live
-- device state at module-load time (see below) and requires real KOReader
-- modules, this cannot be `require`d and executed under plain luajit -- only
-- `loadfile`-parsed, exactly like main.lua itself -- so no off-device test
-- suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 1, §10 step 4):
-- read_frontlight_state, FL (including its FL.captureBeforeSuspend/
-- FL.scheduleWakeSync methods), save_frontlight_state, lipc_get, lipc_set,
-- FL_MAX, FL_AMBER_MAX, FL_HAS_AMBER, FL_STEP, FL_AMBER_STEP, FL_BRIGHT_NOW,
-- FL_AMBER_NOW, FL_SAVED, fl_apply, fl_restore_if_needed, fl_adjust, toggle_light.
--
-- main.lua's original `local FL` (declared with no initializer, assigned a few
-- lines later) was a forward declaration: `save_frontlight_state`, textually
-- defined first, closes over FL as an upvalue before FL_MAX/FL_BRIGHT_NOW/etc.
-- are computed and FL itself is assigned. Here FL is a table field (`M.FL`)
-- instead of a bare local, so no forward declaration is needed: `M.FL.xxx`
-- resolves at call time, by which point M.FL is always already assigned --
-- module load runs top to bottom, uninterrupted, before any external caller can
-- reach in. This preserves the original load-time computation order exactly
-- (PLAN.md §11): every FL_*/M.FL value below is still computed once, at
-- `require` time, in the same relative order as main.lua computed it before.
-- Do not make any of this lazy -- see this module's caller in main.lua for the
-- require-ordering rationale.
--
-- Required by callers as `local FL = require("minfolio_frontlight")`.

local Config = require("minfolio_config")
local IO = require("minfolio_io")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local M = {}

function M.read_frontlight_state()
    local ok, state = pcall(dofile, Config.FL_STATE_PATH)
    return (ok and type(state) == "table") and state or {}
end

function M.save_frontlight_state()
    lfs.mkdir(Config.STATE_DIR)
    IO.write_file(Config.FL_STATE_PATH, string.format(
        "return { on = %s, bright = %d, last = %d, amber = %d }\n",
        M.FL.on and "true" or "false",
        math.floor(M.FL.bright or 0),
        math.floor(M.FL.last or 0),
        math.floor(M.FL.amber or 0)
    ))
end

-- Frontlight is driven through the Kindle framework's powerd (lipc) -- the same
-- controller the OS uses: flIntensity = brightness, currentAmberLevel = warmth.
-- Going through the framework (instead of writing the fp9966 sysfs banks behind
-- its back) means our changes persist across wakes and behave like the native
-- controls: no dual-controller fights, no self-relighting, no warmth drift, and
-- warmth no longer changes the brightness number.
function M.lipc_get(prop)
    local h = io.popen("lipc-get-prop com.lab126.powerd " .. prop .. " 2>/dev/null")
    if not h then return nil end
    local v = h:read("*l"); h:close()
    return tonumber(v)
end
function M.lipc_set(prop, v)
    os.execute("lipc-set-prop com.lab126.powerd " .. prop .. " " .. math.floor(v) .. " >/dev/null 2>&1")
end
M.FL_MAX = M.lipc_get("flMaxIntensity") or 24
M.FL_AMBER_MAX = 24
M.FL_HAS_AMBER = M.lipc_get("currentAmberLevel") ~= nil
M.FL_STEP = math.max(1, math.floor(M.FL_MAX / 8))
M.FL_AMBER_STEP = math.max(1, math.floor(M.FL_AMBER_MAX / 6))
M.FL_BRIGHT_NOW = M.lipc_get("flIntensity") or 0
M.FL_AMBER_NOW = M.lipc_get("currentAmberLevel") or 0
M.FL_SAVED = M.read_frontlight_state()
M.FL = {
    bright = M.FL_BRIGHT_NOW,
    amber  = M.FL_AMBER_NOW,
    last   = M.FL_BRIGHT_NOW > 0 and M.FL_BRIGHT_NOW
        or (tonumber(M.FL_SAVED.last or M.FL_SAVED.bright) or math.floor(M.FL_MAX / 2)),
    on     = M.FL_BRIGHT_NOW > 0,
}
function M.fl_apply()
    local b = math.max(0, math.min(M.FL_MAX, M.FL.bright))
    M.lipc_set("flIntensity", b)
    if M.FL_HAS_AMBER then M.lipc_set("currentAmberLevel", math.max(0, math.min(M.FL_AMBER_MAX, M.FL.amber))) end
    M.FL.on = b > 0
    if b > 0 then M.FL.last = b end
    M.save_frontlight_state()
end
-- The framework owns the light and persists it across wakes, so there is nothing
-- to "restore" -- just resync our view (for the Light off/on label) from the
-- framework without changing the hardware.
function M.fl_restore_if_needed()
    local b = M.lipc_get("flIntensity")
    if b then M.FL.bright = b; M.FL.on = b > 0; if b > 0 then M.FL.last = b end end
    if M.FL_HAS_AMBER then local a = M.lipc_get("currentAmberLevel"); if a then M.FL.amber = a end end
end
function M.FL.captureBeforeSuspend()
    if M.FL.wake_pending then
        UIManager:unschedule(M.FL.wake_pending)
        M.FL.wake_pending = nil
        M.FL.before_suspend = nil
    end
    if M.FL.before_suspend then return end
    M.fl_restore_if_needed()
    M.FL.before_suspend = {
        on = M.FL.on, bright = M.FL.bright, last = M.FL.last, amber = M.FL.amber,
    }
    M.save_frontlight_state()
end
function M.FL.scheduleWakeSync()
    if M.FL.wake_pending then return end
    local expected = M.FL.before_suspend
    local fn
    fn = function()
        if M.FL.wake_pending == fn then M.FL.wake_pending = nil end
        M.FL.before_suspend = nil
        if expected then
            -- powerd may still report its transient wake value during onResume.
            -- Restore the state captured immediately before suspend only after the
            -- Kindle framework has finished its own wake transition.
            M.FL.on = expected.on
            M.FL.bright = expected.on and expected.bright or 0
            M.FL.last = expected.last
            M.FL.amber = expected.amber
            M.fl_apply()
        else
            -- A resume without a matching suspend (plugin loaded mid-session): do
            -- not impose stale saved settings; just learn the settled hardware state.
            M.fl_restore_if_needed()
        end
    end
    M.FL.wake_pending = fn
    UIManager:scheduleIn(1.1, fn)
end
function M.fl_adjust(db, da)
    if db and db ~= 0 then
        M.FL.bright = math.max(0, math.min(M.FL_MAX, M.FL.bright + db))
        if M.FL.bright > 0 then M.FL.last = M.FL.bright end
    end
    if da and da ~= 0 and M.FL_HAS_AMBER then
        M.FL.amber = math.max(0, math.min(M.FL_AMBER_MAX, M.FL.amber + da))
    end
    M.fl_apply()
end
function M.toggle_light()
    if M.FL.bright > 0 then
        M.FL.last = M.FL.bright
        M.FL.bright = 0
    else
        M.FL.bright = (M.FL.last and M.FL.last > 0) and M.FL.last or math.floor(M.FL_MAX / 2)
    end
    M.fl_apply()
end

return M
