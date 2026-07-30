-- SPDX-License-Identifier: AGPL-3.0-only
-- Screen chrome for minfolio.koplugin (PLAN.md §5 Tier 1): status text, the
-- battery indicator, the shared controls popup menu, notifications, wake
-- repaint scheduling, screen rotation, and lifecycle trace logging. Requires
-- KOReader throughout (`Device`, `Screen`, `UIManager`, and a widget-heavy set
-- for the battery pill and the controls Menu), so this cannot be `require`d
-- and executed under plain luajit -- only `loadfile`-parsed, exactly like
-- main.lua itself -- so no off-device test suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 1, §10 step 4):
-- battery_info, battery_indicator, MinfolioBattery, show_controls, notify,
-- wake_repaint_pending, schedule_wake_repaint, and rotate_screen_ccw (whose
-- body lived stranded in the browser region of main.lua behind a forward
-- declaration -- see the note below).
--
-- MinfolioBattery was a bare global before this move (main.lua:227, forced by
-- the 200-local ceiling this refactor removes -- see PLAN.md §1/§6.4). It is
-- now M.MinfolioBattery. Confirmed by repo-wide grep -- including
-- minfolio_sync.lua/.sh (a separate process with its own LUA_PATH) and every
-- sibling plugin under kindle-utils/ (kindle-inbox, kindle-mirror,
-- kindle-tools) -- that nothing outside main.lua reads it; one sibling file
-- (kindle-inbox/kinbox.koplugin/kinbox_ui.lua) mentions MinfolioPair in a
-- comment only, and does not mention MinfolioBattery at all.
--
-- Also relocated here (PLAN.md §5 Tier 1, §1): MinfolioPair.trace, as
-- `M.trace`. Lifecycle logging is not a pairing concern -- it was only a
-- MinfolioPair table field because table fields do not consume the 200-local
-- budget this refactor removes. Every call site's `MinfolioPair.trace(...)`
-- became `Chrome.trace(...)`.
--
-- `rotate_screen_ccw` was one of main.lua's five forward-declared locals
-- (`local open_markdown_picker, rotate_screen_ccw, show_file_manager`); its
-- body is moved verbatim here as `M.rotate_screen_ccw`. The other two moved
-- to minfolio_browser, which forward-declares them itself, so main.lua no
-- longer forward-declares anything at all.
--
-- notify's two forward-reference workaround call sites: main.lua's
-- `MinfolioPair.showPrompt` (the "Desktop paired" / "Could not complete secure
-- pairing" notifications) used to inline `UIManager:show(Notification:new{...})`
-- directly, because at that point in the original file `local function notify`
-- had not been defined yet -- calling it there compiled to a silent nil-global
-- read (this was GGET-lint bug #1, see scripts/deploy.sh's GGET_KNOWN_BUGS
-- history). Now that `notify` lives in a module required at the top of
-- main.lua, both call sites are reachable from line 1 onward, so they were
-- restored to plain `Chrome.notify(...)` calls -- the workaround's reason no
-- longer applies.
--
-- status_date_text, status_time_text and battery_status_text were moved here
-- and then DELETED: they had zero call sites anywhere, confirmed three times
-- (an initial pre-refactor sweep, a re-check during the move, and a final
-- sweep across every module before removal). Removed at the repo owner's request
-- rather than carried, per this work
-- package's behaviour-preserving mandate; deleting them is a separate decision
-- for the repo owner.
--
-- Required by callers as `local Chrome = require("minfolio_chrome")`.

local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local TextWidget = require("ui/widget/textwidget")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local logger = require("logger")
local FL = require("minfolio_frontlight")

local M = {}

-- Keep lifecycle evidence in KOReader's crash log without making the normal
-- editor path noisy.  These markers make a silent UI-loop stall distinguishable
-- from a clean KOReader exit after the next incident.  This is a table method
-- rather than a local because the plugin is at LuaJIT's local-variable limit.
function M.trace(event, ...)
    logger.info("minfolio trace", event, ...)
end

M.MinfolioBattery = M.MinfolioBattery or {}
M.MinfolioBattery.refresh_interval = M.MinfolioBattery.refresh_interval or 60
function M.battery_info()
    local ok, pd = pcall(function() return Device:getPowerDevice() end)
    if not (ok and pd and pd.getCapacity) then return nil end
    local cap = pd:getCapacity()
    if not cap then return nil end
    local charging = false
    local cok, c = pcall(function() return pd:isCharging() end)
    if cok then charging = not not c end
    return { cap = math.max(0, math.min(100, math.floor(cap))), charging = charging }
end
function M.MinfolioBattery.infoKey(info)
    if not info then return "" end
    return tostring(info.cap) .. ":" .. (info.charging and "1" or "0")
end
function M.MinfolioBattery.indicatorWidth()
    local bs = function(px) return Screen:scaleBySize(px) end
    local pct = TextWidget:new{ text = "100%", face = Font:getFace("cfont", 17), fgcolor = Blitbuffer.COLOR_BLACK }
    local w = bs(22) + bs(3) + bs(5) + pct:getSize().w
    pct:free()
    return w
end
-- A hand-drawn Kindle-style battery pill (outline + proportional fill + nub) with
-- the percentage beside it. Drawn from primitives so it never depends on an icon
-- font/asset being present, and stays crisp at the device DPI.
function M.battery_indicator(info)
    info = info or M.battery_info()
    if not info then return nil end
    local bs = function(px) return Screen:scaleBySize(px) end
    local bw, bh, pad = bs(22), bs(13), bs(1)
    local inner_w = bw - 2 * (1 + pad)
    local inner_h = bh - 2 * (1 + pad)
    local fill_w = info.charging and inner_w or math.max(0, math.min(inner_w, math.floor(inner_w * info.cap / 100)))
    local fill = HorizontalGroup:new{ align = "top" }
    if fill_w > 0 then
        fill[#fill+1] = LineWidget:new{ background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{ w = fill_w, h = inner_h } }
    end
    if inner_w - fill_w > 0 then
        fill[#fill+1] = LineWidget:new{ background = Blitbuffer.Color8(215), dimen = Geom:new{ w = inner_w - fill_w, h = inner_h } }
    end
    local body = FrameContainer:new{ bordersize = 1, radius = bs(2), padding = pad, margin = 0,
        width = bw, height = bh, fill }
    local nub = CenterContainer:new{ dimen = Geom:new{ w = bs(3), h = bh },
        LineWidget:new{ background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{ w = bs(2), h = bs(6) } } }
    local pct = TextWidget:new{ text = tostring(info.cap) .. "%",
        face = Font:getFace("cfont", 17), fgcolor = Blitbuffer.COLOR_BLACK }
    return HorizontalGroup:new{ align = "center", body, nub, HorizontalSpan:new{ width = bs(5) }, pct }
end
-- shared controls menu (frontlight brightness/warmth + per-app extras), reused across mirror / notes / launcher
function M.show_controls(extra, on_close)
    local items = {
        { text = "Brightness +",  keep = true, callback = function() FL.fl_adjust(FL.FL_STEP, 0) end },
        { text = "Brightness -",  keep = true, callback = function() FL.fl_adjust(-FL.FL_STEP, 0) end },
        { text = FL.FL.bright > 0 and "Light off" or "Light on", callback = FL.toggle_light },
    }
    if FL.FL_HAS_AMBER then
        table.insert(items, 3, { text = "Warmth +", keep = true, callback = function() FL.fl_adjust(0, FL.FL_AMBER_STEP) end })
        table.insert(items, 4, { text = "Warmth -", keep = true, callback = function() FL.fl_adjust(0, -FL.FL_AMBER_STEP) end })
    end
    for _, it in ipairs(extra or {}) do items[#items+1] = it end
    local menu
    local closed_by_select = false
    menu = Menu:new{
        title = "Controls", item_table = items, is_popout = true,
        width = math.floor(Screen:getWidth() * 0.72), height = math.floor(Screen:getHeight() * 0.7),
        onMenuSelect = function(_s, item)
            local sub_items = item.sub_item_table
            if not sub_items and item.sub_item_table_func then sub_items = item.sub_item_table_func() end
            if sub_items ~= nil then
                sub_items.title = menu.title
                table.insert(menu.item_table_stack, menu.item_table)
                menu:switchItemTable(item.text, sub_items)
                return true
            end
            if item.keep then
                if item.callback then item.callback() end
                return
            end
            closed_by_select = true
            UIManager:close(menu)
            if on_close then on_close() end
            if item.callback then UIManager:scheduleIn(0.01, item.callback) end
        end,
        close_callback = function() if not closed_by_select and on_close then on_close() end end,
    }
    UIManager:show(menu)
    return menu
end

function M.notify(text)
    UIManager:show(Notification:new{ text = text, timeout = 3 })
end
M.wake_repaint_pending = false
function M.schedule_wake_repaint()
    if M.wake_repaint_pending then return end
    M.wake_repaint_pending = true
    UIManager:scheduleIn(1.0, function()
        M.wake_repaint_pending = false
        UIManager:setDirty("all", "full")
    end)
end

-- Rotates the whole device screen 90° counter-clockwise (repeat to cycle through
-- upright / sideways / upside-down / sideways-the-other-way, same 4 modes KOReader
-- itself uses for its own rotation).
function M.rotate_screen_ccw()
    local mode = Screen:getRotationMode()
    Screen:setRotationMode((mode - 1) % 4)
    -- Every full-screen widget we show (the file listing, the editor, any
    -- popout) is sized from Screen:getWidth()/getHeight() at construction
    -- time, so it goes stale the instant the physical rotation flips those --
    -- reads as a frozen/undersized screen. Broadcasting ScreenResize reaches
    -- every widget in the stack (including ones sitting hidden underneath
    -- another, e.g. the file list behind an open note), not just the one on
    -- top, so nothing is left showing a layout built for the old dimensions.
    UIManager:broadcastEvent(require("ui/event"):new("ScreenResize"))
end

return M
