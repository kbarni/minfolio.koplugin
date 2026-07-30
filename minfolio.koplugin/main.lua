-- SPDX-License-Identifier: AGPL-3.0-only
-- Minfolio: a native KOReader live-styled Markdown editor for the Kindle, launched from KUAL.
-- The KUAL shortcut writes a target into /tmp/minfolio_launch; this opens the notes browser at startup.
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
Font.fontmap.ifont = Font.fontmap.ifont or "NotoSans-Italic.ttf"
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local Config = require("minfolio_config")
local Keys = require("minfolio_keys")
local Frontlight = require("minfolio_frontlight")
-- The original FL table (state plus its captureBeforeSuspend/scheduleWakeSync
-- methods) is a field of the module, so bind it directly and every existing
-- FL.xxx call site keeps working untouched.
local FL = Frontlight.FL
local Chrome = require("minfolio_chrome")
local App = require("minfolio_app")
-- Desktop discovery/pairing (PLAN.md §5 Tier 2); moved out of this file
-- along with the transport it depends on (minfolio_remote, below it in the
-- require graph, not read directly here -- only Minfolio:init's
-- Pair.start() call site remains in this file).
local Pair = require("minfolio_pair")
-- Notes browser (PLAN.md §5 Tier 5, §10 step 9) -- the last inline subsystem
-- this file used to hold (dir listing/dialogs/edit_note). Required here for
-- its load-time side effect (registering App.hooks.open_note/open_picker/
-- file_manager, so the editor and the remote-session controller keep
-- reaching it only through App.*, never by name) and for Browser.open_notes(),
-- which the launch flag, the dispatcher action, and the main-menu entry
-- below all call directly.
local Browser = require("minfolio_browser")

-- ============================ Plugin ============================
local Minfolio = WidgetContainer:extend{ name = "minfolio", is_doc_only = false }

local LAUNCH_FLAG = "/tmp/minfolio_launch"
local function read_launch_target(path)
    local fp = io.open(path, "r"); if not fp then return nil end
    local t = fp:read("*l"); fp:close()
    return t and t:gsub("%s+$", "")
end

function Minfolio:openLaunchTarget(target)
    if not target or target == "" then return end
    logger.info("minfolio launch target =", tostring(target))
    Chrome.trace("launch-target", tostring(target))
    if target == "notes" or target == "open" then
        UIManager:scheduleIn(0.1, Browser.open_notes)
    elseif target:match("^edit:") then                  -- open a specific file in the editor
        local path = target:sub(6)
        UIManager:scheduleIn(0.1, function() App.openNote(path) end)
    elseif target:match("^remote:") then
        local descriptor = target:sub(8)
        UIManager:scheduleIn(0.1, function() App.remoteEdit(descriptor) end)
    elseif target:match("^remote%-stop:") then
        local session_id = target:sub(13)
        UIManager:scheduleIn(0.1, function() App.remoteStop(session_id) end)
    end
end

function Minfolio:pollLaunchFlag()
    local target = read_launch_target(LAUNCH_FLAG)
    if target and target ~= "" then
        Chrome.trace("launch-flag-consumed", tostring(target))
        os.remove(LAUNCH_FLAG)
        self:openLaunchTarget(target)
    end
    UIManager:scheduleIn(0.5, function() self:pollLaunchFlag() end)
end

function Minfolio:onResume()
    Chrome.trace("plugin-resume")
    -- Both operations wait for the screensaver/framework wake transition to settle.
    FL.scheduleWakeSync()
    Chrome.schedule_wake_repaint()
end
function Minfolio:onSuspend()
    Chrome.trace("plugin-suspend")
    FL.captureBeforeSuspend()
end

function Minfolio:onDispatcherRegisterActions()
    Dispatcher:registerAction("minfolio_open",
        { category = "none", event = "MinfolioOpen", title = _("Open Minfolio"), general = true })
end

function Minfolio:init()
    Chrome.trace("plugin-init", "notes_dir=", Config.NOTES_DIR)
    Keys.install_keyboard_aliases()
    Pair.start()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if not _G.__minfolio_launch_polling then
        _G.__minfolio_launch_polling = true
        UIManager:scheduleIn(0.5, function() self:pollLaunchFlag() end)
    end
    local target = read_launch_target(LAUNCH_FLAG)
    if target and target ~= "" then
        os.remove(LAUNCH_FLAG)
        self:openLaunchTarget(target)
    end
end

function Minfolio:onMinfolioOpen() Browser.open_notes(); return true end

function Minfolio:addToMainMenu(menu_items)
    menu_items.minfolio = {
        text = _("Minfolio"),
        sorting_hint = "more_tools",
        callback = function() Browser.open_notes() end,
    }
end

return Minfolio
