-- SPDX-License-Identifier: AGPL-3.0-only
-- Minfolio: a native KOReader live-styled Markdown editor for the Kindle, launched from KUAL.
-- The KUAL shortcut writes a target into /tmp/minfolio_launch; this opens the notes browser at startup.
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local IconWidget = require("ui/widget/iconwidget")
local Font = require("ui/font")
Font.fontmap.ifont = Font.fontmap.ifont or "NotoSans-Italic.ttf"
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Widget = require("ui/widget/widget")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Notification = require("ui/widget/notification")
local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")
rapidjson = require("rapidjson")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local function now_seconds()
    return (socket and socket.gettime and socket.gettime()) or os.time()
end

local function plugin_dir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    return src:match("^(.*)/[^/]*$") or "."
end

local function load_local_config()
    local ok, cfg = pcall(dofile, plugin_dir() .. "/config.lua")
    if ok and type(cfg) == "table" then
        return cfg
    end
    return {}
end

local CONFIG = load_local_config()
local NOTES_DIR = CONFIG.notes_dir or "/mnt/us/notes"
local STATE_DIR = CONFIG.state_dir or "/mnt/us/.minfolio"
MINFOLIO_REMOTE_DIR = "/mnt/us/.minfolio-remote"
local FL_STATE_PATH = STATE_DIR .. "/frontlight.lua"
local MINFOLIO_STATE_PATH = STATE_DIR .. "/state.lua"
MINFOLIO_PAIR_PATH = STATE_DIR .. "/pairing.lua"
-- Migrate only the old persistent settings; remote session caches are disposable.
if not CONFIG.state_dir and lfs.attributes("/mnt/us/minfolio", "mode") == "directory" and lfs.attributes(STATE_DIR, "mode") ~= "directory" then
    lfs.mkdir(STATE_DIR)
    os.rename("/mnt/us/minfolio/state.lua", MINFOLIO_STATE_PATH)
    os.rename("/mnt/us/minfolio/frontlight.lua", FL_STATE_PATH)
end
MinfolioPair = { port = 42771 }
-- Keep lifecycle evidence in KOReader's crash log without making the normal
-- editor path noisy.  These markers make a silent UI-loop stall distinguishable
-- from a clean KOReader exit after the next incident.  This is a table method
-- rather than a local because the plugin is at LuaJIT's local-variable limit.
function MinfolioPair.trace(event, ...)
    logger.info("minfolio trace", event, ...)
end

-- KOReader's stock English keyboard devotes two bottom-row cells to cursor
-- arrows (and exposes up/down on the symbol layers of N and M).  They are easy
-- to hit accidentally in a compact editor, so make an app-local copy with no
-- arrow actions.  Do not mutate the shared layout module: other KOReader views
-- should retain their normal keyboard.
function MinfolioPair.makeKeyboardArrowFree(keyboard)
    local rows, removed = {}, 0
    for _, row in ipairs(keyboard.KEYS or {}) do
        local new_row = {}
        for _, keydef in ipairs(row) do
            local label = type(keydef) == "table" and keydef.label or keydef
            if label == "←" or label == "→" or label == "↑" or label == "↓" then
                removed = removed + 1
            else
                local copy = {}
                if type(keydef) == "table" then
                    for k, v in pairs(keydef) do copy[k] = v end
                    -- N/M use arrows only in the alternate layers.  Retain the
                    -- character rather than leaving an invisible, active key.
                    for k, v in ipairs(copy) do
                        if v == "↑" or v == "↓" or v == "←" or v == "→" then
                            copy[k] = copy[2] or copy[1] or ""
                        end
                    end
                else
                    copy = keydef
                end
                table.insert(new_row, copy)
            end
        end
        table.insert(rows, new_row)
    end
    if removed == 0 then return end
    -- On the English layout this exactly fills the two removed bottom-row cells.
    local last_row = rows[#rows]
    for _, keydef in ipairs(last_row or {}) do
        if type(keydef) == "table" and keydef.label == "_" then
            keydef.width = (tonumber(keydef.width) or 1) + removed
            break
        end
    end
    keyboard.KEYS = rows
    keyboard:initLayer(keyboard.keyboard_layer)
end

function MinfolioPair.disableKeyboardKeyFlash(keyboard)
    -- VirtualKey normally calls forceRePaint() and yieldToEPDC() for every tap
    -- when the global setting is absent (its default is enabled).  On e-ink that
    -- synchronous wait prevents the touch queue from keeping up with fast typing.
    -- Keep this local to Minfolio and reapply it whenever Shift/Symbol rebuilds
    -- the key widgets.
    local stock_init_layer = keyboard.initLayer
    function keyboard:initLayer(layer)
        stock_init_layer(self, layer)
        for _, row in ipairs(self.layout or {}) do
            for _, key in ipairs(row) do key.flash_keyboard = false end
        end
    end
    keyboard:initLayer(keyboard.keyboard_layer)
end

function MinfolioPair.deviceId()
    local f = io.open("/proc/usid", "r")
    local id = f and f:read("*l") or nil
    if f then f:close() end
    return (id and id:gsub("[^%w]", "")) or "kindle"
end
function MinfolioPair.secret()
    local f = io.open("/dev/urandom", "rb")
    local raw = f and f:read(24) or tostring(os.time()) .. tostring(socket.gettime())
    if f then f:close() end
    return (raw:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end
function MinfolioPair.post(cfg, path, body)
    local sock = MinfolioRemote and MinfolioRemote.socket(cfg, 2)
    if not sock then return false end
    local raw = rapidjson.encode(body)
    local req = "POST " .. path .. " HTTP/1.1\r\nHost: " .. cfg.host .. "\r\nContent-Type: application/json\r\nContent-Length: " .. #raw .. "\r\nConnection: close\r\n\r\n" .. raw
    MinfolioRemote.sendAll(sock, req); pcall(function() sock:close() end)
    return true
end
function MinfolioPair.showPrompt(msg)
    if not (msg and msg.code and msg.host and msg.port and msg.fingerprint and msg.nonce) then return end
    UIManager:show(ConfirmBox:new{ text = _("Pair with this desktop?\n\nVerification code: ") .. tostring(msg.code), ok_text = _("Pair"), ok_callback = function()
        local cfg = { host = msg.host, port = tonumber(msg.port), cert_fingerprint = msg.fingerprint }
        local secret = MinfolioPair.secret()
        if MinfolioPair.post(cfg, "/kindle/pair", { nonce = msg.nonce, code = msg.code, deviceId = MinfolioPair.deviceId(), secret = secret }) then
            lfs.mkdir(STATE_DIR)
            local state = io.open(MINFOLIO_PAIR_PATH, "w")
            if state then state:write(string.format("return { secret = %q }\n", secret)); state:close() end
            notify(_("Desktop paired"))
        else notify(_("Could not complete secure pairing")) end
    end })
end
function MinfolioPair.pollRequest()
    local flag = "/tmp/minfolio_pair_request"
    local fp = io.open(flag, "r")
    if not fp then return end
    fp:close()
    os.remove(flag)
    local ok, msg = pcall(dofile, MINFOLIO_REMOTE_DIR .. "/pair-request.lua")
    if ok then MinfolioPair.showPrompt(msg) end
end
function MinfolioPair.poll()
    if not MinfolioPair.sock then return end
    -- UDP is untrusted input.  Draining an endless datagram queue in a single
    -- UI callback can starve taps, rendering, and suspend handling.
    local processed, max_per_tick = 0, 32
    while processed < max_per_tick do
        local raw, ip, reply_port = MinfolioPair.sock:receivefrom()
        if not raw then break end
        processed = processed + 1
        local ok, msg = pcall(function() return rapidjson.decode(raw) end)
        if ok and msg.type == "minfolio-discover" and msg.nonce then
            local reply = rapidjson.encode({ type = "minfolio-device", nonce = msg.nonce, id = MinfolioPair.deviceId(), label = "Kindle Minfolio" })
            MinfolioPair.sock:sendto(reply, ip, reply_port)
        elseif ok and msg.type == "minfolio-pair-request" then
            MinfolioPair.showPrompt(msg)
        end
    end
    if processed == max_per_tick then
        local now = now_seconds()
        if not MinfolioPair._last_backpressure_log or now - MinfolioPair._last_backpressure_log >= 30 then
            MinfolioPair._last_backpressure_log = now
            logger.warn("minfolio discovery queue capped; deferring remaining UDP datagrams")
        end
    end
end
function MinfolioPair.beacon()
    if not MinfolioPair.sock then return end
    local msg = rapidjson.encode({ type = "minfolio-device", id = MinfolioPair.deviceId(), label = "Kindle Minfolio" })
    pcall(function() MinfolioPair.sock:sendto(msg, "255.255.255.255", MinfolioPair.port) end)
end
function MinfolioPair.start()
    if MinfolioPair.sock then return end
    local s = socket.udp(); if not s then return end
    s:setsockname("*", MinfolioPair.port); s:setoption("broadcast", true); s:settimeout(0); MinfolioPair.sock = s
    MinfolioPair.trace("discovery-start", "port=", MinfolioPair.port)
    local function tick() MinfolioPair.poll(); MinfolioPair.pollRequest(); MinfolioPair.beacon(); UIManager:scheduleIn(0.75, tick) end
    UIManager:scheduleIn(0.25, tick)
end
local function status_date_text()
    return os.date("%a, %d %b  %I:%M %p")
end
local function status_time_text()
    return os.date("%I:%M %p")
end
MinfolioBattery = MinfolioBattery or {}
MinfolioBattery.refresh_interval = MinfolioBattery.refresh_interval or 60
local function battery_status_text()
    local ok, pd = pcall(function() return Device:getPowerDevice() end)
    if ok and pd then
        local cap = pd:getCapacity()
        if cap then return tostring(cap) .. "%" end
    end
    return ""
end
local function battery_info()
    local ok, pd = pcall(function() return Device:getPowerDevice() end)
    if not (ok and pd and pd.getCapacity) then return nil end
    local cap = pd:getCapacity()
    if not cap then return nil end
    local charging = false
    local cok, c = pcall(function() return pd:isCharging() end)
    if cok then charging = not not c end
    return { cap = math.max(0, math.min(100, math.floor(cap))), charging = charging }
end
function MinfolioBattery.infoKey(info)
    if not info then return "" end
    return tostring(info.cap) .. ":" .. (info.charging and "1" or "0")
end
function MinfolioBattery.indicatorWidth()
    local bs = function(px) return Screen:scaleBySize(px) end
    local pct = TextWidget:new{ text = "100%", face = Font:getFace("cfont", 17), fgcolor = Blitbuffer.COLOR_BLACK }
    local w = bs(22) + bs(3) + bs(5) + pct:getSize().w
    pct:free()
    return w
end
-- A hand-drawn Kindle-style battery pill (outline + proportional fill + nub) with
-- the percentage beside it. Drawn from primitives so it never depends on an icon
-- font/asset being present, and stays crisp at the device DPI.
local function battery_indicator(info)
    info = info or battery_info()
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
local function write_file(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end
local function split_text_lines(text)
    local lines = {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do lines[#lines+1] = line end
    if #lines == 0 then lines = { "" } end
    return lines
end
local function read_frontlight_state()
    local ok, state = pcall(dofile, FL_STATE_PATH)
    return (ok and type(state) == "table") and state or {}
end
local function clamp_minfolio_scale(scale)
    return math.max(0.6, math.min(1.8, tonumber(scale) or 1.0))
end
local function read_minfolio_state()
    local ok, state = pcall(dofile, MINFOLIO_STATE_PATH)
    return (ok and type(state) == "table") and state or {}
end
local MINFOLIO_STATE = read_minfolio_state()
MINFOLIO_STATE.scale = clamp_minfolio_scale(MINFOLIO_STATE.scale or CONFIG.minfolio_scale)
MINFOLIO_STATE.positions = type(MINFOLIO_STATE.positions) == "table" and MINFOLIO_STATE.positions or {}
local function save_minfolio_state()
    lfs.mkdir(STATE_DIR)
    local positions = {}
    for path, position in pairs(MINFOLIO_STATE.positions) do
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
    write_file(MINFOLIO_STATE_PATH, string.format(
        "return { scale = %.3f, positions = { %s } }\n",
        clamp_minfolio_scale(MINFOLIO_STATE.scale), table.concat(positions, " ")))
end
local FL
local function save_frontlight_state()
    lfs.mkdir(STATE_DIR)
    write_file(FL_STATE_PATH, string.format(
        "return { on = %s, bright = %d, last = %d, amber = %d }\n",
        FL.on and "true" or "false",
        math.floor(FL.bright or 0),
        math.floor(FL.last or 0),
        math.floor(FL.amber or 0)
    ))
end
-- Frontlight is driven through the Kindle framework's powerd (lipc) -- the same
-- controller the OS uses: flIntensity = brightness, currentAmberLevel = warmth.
-- Going through the framework (instead of writing the fp9966 sysfs banks behind
-- its back) means our changes persist across wakes and behave like the native
-- controls: no dual-controller fights, no self-relighting, no warmth drift, and
-- warmth no longer changes the brightness number.
local function lipc_get(prop)
    local h = io.popen("lipc-get-prop com.lab126.powerd " .. prop .. " 2>/dev/null")
    if not h then return nil end
    local v = h:read("*l"); h:close()
    return tonumber(v)
end
local function lipc_set(prop, v)
    os.execute("lipc-set-prop com.lab126.powerd " .. prop .. " " .. math.floor(v) .. " >/dev/null 2>&1")
end
local FL_MAX = lipc_get("flMaxIntensity") or 24
local FL_AMBER_MAX = 24
local FL_HAS_AMBER = lipc_get("currentAmberLevel") ~= nil
local FL_STEP = math.max(1, math.floor(FL_MAX / 8))
local FL_AMBER_STEP = math.max(1, math.floor(FL_AMBER_MAX / 6))
local FL_BRIGHT_NOW = lipc_get("flIntensity") or 0
local FL_AMBER_NOW = lipc_get("currentAmberLevel") or 0
local FL_SAVED = read_frontlight_state()
FL = {
    bright = FL_BRIGHT_NOW,
    amber  = FL_AMBER_NOW,
    last   = FL_BRIGHT_NOW > 0 and FL_BRIGHT_NOW
        or (tonumber(FL_SAVED.last or FL_SAVED.bright) or math.floor(FL_MAX / 2)),
    on     = FL_BRIGHT_NOW > 0,
}
local function fl_apply()
    local b = math.max(0, math.min(FL_MAX, FL.bright))
    lipc_set("flIntensity", b)
    if FL_HAS_AMBER then lipc_set("currentAmberLevel", math.max(0, math.min(FL_AMBER_MAX, FL.amber))) end
    FL.on = b > 0
    if b > 0 then FL.last = b end
    save_frontlight_state()
end
-- The framework owns the light and persists it across wakes, so there is nothing
-- to "restore" -- just resync our view (for the Light off/on label) from the
-- framework without changing the hardware.
local function fl_restore_if_needed()
    local b = lipc_get("flIntensity")
    if b then FL.bright = b; FL.on = b > 0; if b > 0 then FL.last = b end end
    if FL_HAS_AMBER then local a = lipc_get("currentAmberLevel"); if a then FL.amber = a end end
end
function FL.captureBeforeSuspend()
    if FL.wake_pending then
        UIManager:unschedule(FL.wake_pending)
        FL.wake_pending = nil
        FL.before_suspend = nil
    end
    if FL.before_suspend then return end
    fl_restore_if_needed()
    FL.before_suspend = {
        on = FL.on, bright = FL.bright, last = FL.last, amber = FL.amber,
    }
    save_frontlight_state()
end
function FL.scheduleWakeSync()
    if FL.wake_pending then return end
    local expected = FL.before_suspend
    local fn
    fn = function()
        if FL.wake_pending == fn then FL.wake_pending = nil end
        FL.before_suspend = nil
        if expected then
            -- powerd may still report its transient wake value during onResume.
            -- Restore the state captured immediately before suspend only after the
            -- Kindle framework has finished its own wake transition.
            FL.on = expected.on
            FL.bright = expected.on and expected.bright or 0
            FL.last = expected.last
            FL.amber = expected.amber
            fl_apply()
        else
            -- A resume without a matching suspend (plugin loaded mid-session): do
            -- not impose stale saved settings; just learn the settled hardware state.
            fl_restore_if_needed()
        end
    end
    FL.wake_pending = fn
    UIManager:scheduleIn(1.1, fn)
end
local function fl_adjust(db, da)
    if db and db ~= 0 then
        FL.bright = math.max(0, math.min(FL_MAX, FL.bright + db))
        if FL.bright > 0 then FL.last = FL.bright end
    end
    if da and da ~= 0 and FL_HAS_AMBER then
        FL.amber = math.max(0, math.min(FL_AMBER_MAX, FL.amber + da))
    end
    fl_apply()
end
local function toggle_light()
    if FL.bright > 0 then
        FL.last = FL.bright
        FL.bright = 0
    else
        FL.bright = (FL.last and FL.last > 0) and FL.last or math.floor(FL_MAX / 2)
    end
    fl_apply()
end
-- shared controls menu (frontlight brightness/warmth + per-app extras), reused across mirror / notes / launcher
local function show_controls(extra, on_close)
    local items = {
        { text = "Brightness +",  keep = true, callback = function() fl_adjust(FL_STEP, 0) end },
        { text = "Brightness -",  keep = true, callback = function() fl_adjust(-FL_STEP, 0) end },
        { text = FL.bright > 0 and "Light off" or "Light on", callback = toggle_light },
    }
    if FL_HAS_AMBER then
        table.insert(items, 3, { text = "Warmth +", keep = true, callback = function() fl_adjust(0, FL_AMBER_STEP) end })
        table.insert(items, 4, { text = "Warmth -", keep = true, callback = function() fl_adjust(0, -FL_AMBER_STEP) end })
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

-- ============================ Markdown styled renderer (Phase 0) ============================
-- tokenize text -> array of lines, each {block=<style>, spans={{text,style},...}}
local MD_FACES = {
    normal = {"cfont", 22}, h1 = {"tfont", 34}, h2 = {"tfont", 29}, h3 = {"tfont", 25},
    bullet = {"cfont", 22}, task = {"cfont", 22}, quote = {"cfont", 22}, bold = {"tfont", 22}, italic = {"ifont", 22},
    code = {"infont", 20}, syntax = {"cfont", 22},
}
local MD_LH = { normal = 25, h1 = 39, h2 = 33, h3 = 29, bullet = 25, quote = 25 }  -- ~1.15 line-height
local MDEDIT_TABLE_PAD_X = 8
local MDEDIT_TABLE_PAD_Y = 5
local function md_face(style, scale)
    local f = MD_FACES[style] or MD_FACES.normal
    return Font:getFace(f[1], math.floor(f[2] * (scale or 1)))
end
local function md_color(style)
    if style == "syntax" then return Blitbuffer.COLOR_WHITE end
    if style == "code" then return Blitbuffer.Color8(55) end
    if style == "quote" then return Blitbuffer.Color8(95) end
    return Blitbuffer.COLOR_BLACK
end

-- `hl` (highlight) is a background flag carried through recursion, orthogonal to
-- text style: everything parsed inside a ==...== region inherits it, so bold /
-- italic / code inside a highlight keep their own style AND get the highlight fill.
local function md_inline(text, hl)
    local spans, i, n, buf = {}, 1, #text, ""
    local function push(t, s, display) if t ~= "" then spans[#spans+1] = { text = t, style = s, display = display, hl = hl or nil } end end
    local function push_nested(inner, style)
        for _, s in ipairs(md_inline(inner, hl)) do
            if s.style ~= "syntax" then s.style = style end
            spans[#spans+1] = s
        end
    end
    while i <= n do
        local c2 = text:sub(i, i+1)
        local c1 = text:sub(i, i)
        local closer, inner_start, marker
        if c2 == "**" then marker = "**"; inner_start = i+2
        elseif c2 == "==" then marker = "=="; inner_start = i+2
        elseif c1 == "*" then marker = "*"; inner_start = i+1
        elseif c1 == "`" then marker = "`"; inner_start = i+1
        end
        if marker then closer = text:find(marker, inner_start, true) end
        if marker and closer then
            push(buf, "normal"); buf = ""
            if marker == "==" then
                -- Recurse so the highlight's contents keep their own inline styles;
                -- every returned span carries hl = true for the fill.
                push(marker, "syntax", "")
                for _, s in ipairs(md_inline(text:sub(inner_start, closer-1), true)) do spans[#spans+1] = s end
                push(marker, "syntax", "")
            else
                local sty = (marker == "**") and "bold" or (marker == "*") and "italic" or "code"
                push(marker, "syntax", "")
                if marker == "`" then push(text:sub(inner_start, closer-1), sty)
                else push_nested(text:sub(inner_start, closer-1), sty) end
                push(marker, "syntax", "")
            end
            i = closer + #marker
        else
            buf = buf .. c1; i = i + 1
        end
    end
    push(buf, "normal")
    if #spans == 0 then spans[1] = { text = "", style = "normal", hl = hl or nil } end
    return spans
end

local function md_tokenize(textstr)
    local lines = {}
    local function with_prefix(prefix, rest, block, display, style)
        local spans = {}
        if prefix and prefix ~= "" then spans[#spans+1] = { text = prefix, style = style or "syntax", display = display or "" } end
        for _, s in ipairs(md_inline(rest)) do spans[#spans+1] = s end
        return { block = block or "normal", spans = spans }
    end
    for line in (tostring(textstr or "") .. "\n"):gmatch("(.-)\n") do
        local hashes, hrest = line:match("^(#+%s+)(.*)$")
        if hashes then
            local level = math.min(#hashes:gsub("%s", ""), 3)
            lines[#lines+1] = { block = "h"..level, spans = {{ text = hashes, style = "syntax", display = "" }, { text = hrest, style = "h"..level }} }
        else
            local pre, rest = line:match("^(%s*[%-%*%+]%s+)(.*)$")
            local ordered = false
            if not pre then
                pre, rest = line:match("^(%s*%d+%.%s+)(.*)$")
                ordered = pre ~= nil
            end
            if pre then
                local task, taskrest = rest:match("^(%[[ xX]%]%s+)(.*)$")
                local spans = {}
                spans[#spans+1] = { text = pre, style = "bullet", display = task and "" or (ordered and pre:gsub("^%s+", "") or "\226\128\162 ") }
                if task then
                    local checked = task:match("%[[xX]%]") ~= nil
                    spans[#spans+1] = { text = task, style = "task", display = checked and "\226\152\145 " or "\226\152\144 " }
                    rest = taskrest
                end
                for _, s in ipairs(md_inline(rest)) do spans[#spans+1] = s end
                -- Keep the leading whitespace so nested items render indented; the
                -- marker span's display drops it (fixed glyph), so the indent is
                -- reapplied as real horizontal space in layoutLine.
                lines[#lines+1] = { block = "bullet", spans = spans, indent_ws = pre:match("^%s*") or "" }
            else
                local task, taskrest = line:match("^(%s*%[[ xX]%]%s+)(.*)$")
                if task then
                    local checked = task:match("%[[xX]%]") ~= nil
                    local tok = with_prefix(task, taskrest, "bullet", checked and "\226\152\145 " or "\226\152\144 ", "task")
                    tok.indent_ws = task:match("^%s*") or ""
                    lines[#lines+1] = tok
                else
                    if line:match("^>%s?") then
                        pre, rest = line:match("^(>%s?)(.*)$")
                        lines[#lines+1] = with_prefix(pre, rest, "quote", "", "syntax")
                    else
                        lines[#lines+1] = { block = "normal", spans = md_inline(line) }
                    end
                end
            end
        end
    end
    return lines
end

local function md_trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

-- Markdown tables are permitted inside blockquotes.  Keep the prefix out of
-- the table grammar, but retain its byte width so cell edits still replace the
-- correct ranges in the original source line.
local function md_table_row_prefix(line)
    return tostring(line or ""):match("^(%s*>%s?)") or ""
end

local function md_split_table_row(line)
    line = tostring(line or "")
    local prefix = md_table_row_prefix(line)
    local source_offset = #prefix
    if source_offset > 0 then line = line:sub(source_offset + 1) end
    if not line:find("|", 1, true) then return nil end
    local first_pipe = line:find("|", 1, true)
    local last_pipe
    local pos = 1
    while true do
        local p = line:find("|", pos, true)
        if not p then break end
        last_pipe = p
        pos = p + 1
    end
    if not first_pipe or not last_pipe then return nil end

    local leading = line:match("^%s*|") ~= nil
    local trailing = line:match("|%s*$") ~= nil
    local start_pos = leading and (first_pipe + 1) or 1
    local end_pos = trailing and (last_pipe - 1) or #line
    if end_pos < start_pos then return nil end

    local cells = {}
    local cell_start = start_pos
    while cell_start <= end_pos + 1 do
        local pipe = line:find("|", cell_start, true)
        if not pipe or pipe > end_pos then pipe = end_pos + 1 end
        local raw_start, raw_end = cell_start, pipe - 1
        local raw = raw_start <= raw_end and line:sub(raw_start, raw_end) or ""
        local leading_ws = raw:match("^(%s*)") or ""
        local trailing_ws = raw:match("(%s*)$") or ""
        local text_start = raw_start + #leading_ws
        local text_end = raw_end - #trailing_ws
        local text = md_trim(raw)
        if text == "" then
            text_start = raw_start
            text_end = raw_start - 1
        end
        cells[#cells+1] = {
            text = text,
            start_col = math.max(0, source_offset + text_start - 1),
            end_col = math.max(0, source_offset + text_end),
        }
        cell_start = pipe + 1
        if pipe > end_pos then break end
    end
    if #cells < 2 then return nil end
    return cells, prefix
end

local function md_table_separator(cells)
    if not cells or #cells < 2 then return nil end
    local aligns = {}
    for i, cell in ipairs(cells) do
        local spec = md_trim(cell.text):gsub("%s+", "")
        if not spec:match("^:?-+:?$") then return nil end
        if spec:match("^:") and spec:match(":$") then aligns[i] = "center"
        elseif spec:match(":$") then aligns[i] = "right"
        else aligns[i] = "left" end
    end
    return aligns
end

local function md_table_block(lines, start_i)
    local header, prefix = md_split_table_row(lines[start_i])
    if not header then return nil end
    local sep, sep_prefix = md_split_table_row(lines[start_i + 1])
    if prefix ~= sep_prefix then return nil end
    local aligns = md_table_separator(sep)
    if not aligns then return nil end
    local ncols = #sep
    if #header < ncols then return nil end

    local rows = {
        { line = start_i, cells = header, header = true },
    }
    local finish = start_i + 1
    local i = start_i + 2
    while i <= #lines do
        local cells, row_prefix = md_split_table_row(lines[i])
        if not cells or row_prefix ~= prefix or #cells < 2 or md_table_separator(cells) then break end
        rows[#rows+1] = { line = i, cells = cells }
        finish = i
        i = i + 1
    end
    return { start = start_i, finish = finish, ncols = ncols, aligns = aligns, rows = rows }
end

-- ============================ Live styled markdown editor (Phase 1) ============================
-- Shift map for BT-keyboard symbol keys (used by MDEdit:onKeyPress).
local SHIFT_SYM = {
    ["1"]="!", ["2"]="@", ["3"]="#", ["4"]="$", ["5"]="%", ["6"]="^", ["7"]="&", ["8"]="*", ["9"]="(", ["0"]=")",
    ["-"]="_", ["="]="+", ["["]="{", ["]"]="}", ["\\"]="|", [";"]=":", ["'"]='"', [","]="<", ["."]=">", ["/"]="?", ["`"]="~",
}
local KEYPAD_CHAR = {
    KP0 = "0", KP1 = "1", KP2 = "2", KP3 = "3", KP4 = "4", KP5 = "5", KP6 = "6", KP7 = "7", KP8 = "8", KP9 = "9",
    KPMinus = "-", KPPlus = "+", KPDot = ".",
}
local KEYBOARD_EVENT_MAP = {
    [1]="Back", [2]="1", [3]="2", [4]="3", [5]="4", [6]="5", [7]="6", [8]="7", [9]="8", [10]="9", [11]="0",
    [12]="-", [13]="=", [14]="Backspace", [15]="Tab",
    [16]="Q", [17]="W", [18]="E", [19]="R", [20]="T", [21]="Y", [22]="U", [23]="I", [24]="O", [25]="P",
    [26]="[", [27]="]", [28]="Press", [29]="Ctrl",
    [30]="A", [31]="S", [32]="D", [33]="F", [34]="G", [35]="H", [36]="J", [37]="K", [38]="L", [39]=";", [40]="'",
    [41]="`", [42]="Shift", [43]="\\",
    [44]="Z", [45]="X", [46]="C", [47]="V", [48]="B", [49]="N", [50]="M", [51]=",", [52]=".", [53]="/",
    [54]="Shift", [56]="Alt", [57]=" ", [58]="CapsLock",
    [59]="F1", [60]="F2", [61]="F3", [62]="F4", [63]="F5", [64]="F6", [65]="F7", [66]="F8", [67]="F9", [68]="F10",
    [69]="NumLock", [70]="ScrollLock",
    [71]="KP7", [72]="KP8", [73]="KP9", [74]="KPMinus", [75]="KP4", [76]="KP5", [77]="KP6", [78]="KPPlus",
    [79]="KP1", [80]="KP2", [81]="KP3", [82]="KP0", [83]="KPDot", [87]="F11", [88]="F12", [96]="Press",
    [97]="Ctrl", [98]="Home", [99]="PrintScr", [100]="Alt", [102]="Home", [103]="Up", [104]="PageUp",
    [105]="Left", [106]="Right", [107]="End", [108]="Down", [109]="PageDown", [110]="Ins", [111]="Del",
    [114]="VMinus", [115]="VPlus", [116]="Power", [119]="Pause", [125]="Meta", [126]="Meta", [127]="Menu", [139]="Menu",
}
-- UTF-8 cursor helpers: move/delete by whole characters, not bytes (continuation bytes are 0x80..0xBF)
local function utf8_left(s, c)
    if c <= 0 then return 0 end
    c = c - 1
    while c > 0 do local b = s:byte(c+1); if b and b >= 0x80 and b < 0xC0 then c = c - 1 else break end end
    return c
end
local function utf8_right(s, c)
    if c >= #s then return #s end
    c = c + 1
    while c < #s do local b = s:byte(c+1); if b and b >= 0x80 and b < 0xC0 then c = c + 1 else break end end
    return c
end
local function utf8_snap(s, c)        -- snap a byte index back to the nearest char boundary
    while c > 0 and c < #s do local b = s:byte(c+1); if b and b >= 0x80 and b < 0xC0 then c = c - 1 else break end end
    return c
end
local function char_is_space(s)
    return s ~= "" and s:match("^%s$") ~= nil
end
local function prev_word_col(s, c)
    local p = math.max(0, math.min(c or 0, #s))
    while p > 0 do
        local q = utf8_left(s, p)
        if not char_is_space(s:sub(q + 1, p)) then break end
        p = q
    end
    while p > 0 do
        local q = utf8_left(s, p)
        if char_is_space(s:sub(q + 1, p)) then break end
        p = q
    end
    return p
end
local function next_word_col(s, c)
    local p = math.max(0, math.min(c or 0, #s))
    while p < #s do
        local q = utf8_right(s, p)
        if not char_is_space(s:sub(p + 1, q)) then break end
        p = q
    end
    while p < #s do
        local q = utf8_right(s, p)
        if char_is_space(s:sub(p + 1, q)) then break end
        p = q
    end
    return p
end
local function keymod(mods, name)
    if not mods then return nil end
    if type(mods) == "string" then
        return mods == name or mods:lower() == name:lower()
    end
    if mods[name] or mods[name:lower()] or mods[name:upper()] then return true end
    if name == "Ctrl" then return mods.LCtrl or mods.RCtrl end
    if name == "Alt" then return mods.LAlt or mods.RAlt end
    if name == "Meta" then return mods.LMeta or mods.RMeta end
    if name == "Shift" then return mods.LShift or mods.RShift end
    for _, mod in pairs(mods) do
        if type(mod) == "string" and (mod == name or mod:lower() == name:lower()) then return true end
    end
    return nil
end
local function shortcut_mod(mods)
    return keymod(mods, "Ctrl") or keymod(mods, "Meta") or keymod(mods, "Cmd")
        or keymod(mods, "Command") or keymod(mods, "Gui") or keymod(mods, "Super")
end
local function word_key_mod(mods)
    return keymod(mods, "Alt") or shortcut_mod(mods)
end
local function fn_key_mod(mods)
    return keymod(mods, "Fn") or keymod(mods, "Function") or keymod(mods, "Mod5")
end
local function key_mods(key)
    local out = {}
    if Device.input and type(Device.input.modifiers) == "table" then
        for k, v in pairs(Device.input.modifiers) do out[k] = v end
    end
    if key and type(key.modifiers) == "table" then
        for k, v in pairs(key.modifiers) do out[k] = v end
    end
    if key then
        for _, name in ipairs({
            "Shift", "LShift", "RShift",
            "Ctrl", "LCtrl", "RCtrl",
            "Alt", "LAlt", "RAlt",
            "Meta", "LMeta", "RMeta",
            "Cmd", "Command", "Gui", "Super",
            "Fn", "Function", "Mod5",
        }) do
            if key[name] then out[name] = true end
        end
    end
    return out
end
local function install_keyboard_aliases()
    local input = Device.input
    if not input then return end
    local em = input.event_map
    if em then
        for code, name in pairs(KEYBOARD_EVENT_MAP) do
            em[code] = name
        end
    end
    local mods = input.modifiers
    if mods then
        mods.Alt = mods.Alt or false
        mods.Ctrl = mods.Ctrl or false
        mods.Shift = mods.Shift or false
        mods.Meta = mods.Meta or false
        mods.LAlt = mods.LAlt or false
        mods.RAlt = mods.RAlt or false
        mods.LCtrl = mods.LCtrl or false
        mods.RCtrl = mods.RCtrl or false
        mods.LShift = mods.LShift or false
        mods.RShift = mods.RShift or false
        mods.LMeta = mods.LMeta or false
        mods.RMeta = mods.RMeta or false
        mods.Fn = mods.Fn or false
        mods.Function = mods.Function or false
        mods.Mod5 = mods.Mod5 or false
    end
end
local function page_up_key(name)
    return name == "PageUp" or name == "Page_Up" or name == "PgUp" or name == "Prior"
end
local function page_down_key(name)
    return name == "PageDown" or name == "Page_Down" or name == "PgDown" or name == "Next"
end
local function left_key(name)
    return name == "Left" or name == "ArrowLeft" or name == "KEY_LEFT" or name == "CursorLeft"
end
local function right_key(name)
    return name == "Right" or name == "ArrowRight" or name == "KEY_RIGHT" or name == "CursorRight"
end
local function up_key(name)
    return name == "Up" or name == "ArrowUp" or name == "KEY_UP" or name == "CursorUp"
end
local function down_key(name)
    return name == "Down" or name == "ArrowDown" or name == "KEY_DOWN" or name == "CursorDown"
end
local function copy_arr(t) local r = {}; for i = 1, #t do r[i] = t[i] end; return r end
local md_clipboard = ""               -- shared across notes
local function path_join(dir, name)
    if dir == "/" then return "/" .. name end
    return dir .. "/" .. name
end
local function path_parent(path)
    path = tostring(path or NOTES_DIR):gsub("/+$", "")
    if path == "" or path == "/" then return "/" end
    local p = path:match("^(.*)/[^/]+$")
    if not p or p == "" then return "/" end
    return p
end
local function path_base(path)
    local p = tostring(path or ""):gsub("/+$", "")
    return p:match("[^/]+$") or p
end
local function is_markdown_file(name)
    return tostring(name or ""):lower():match("%.md$") ~= nil
end
local function file_signature(path)
    local ok, attr = pcall(lfs.attributes, path)
    if not ok or type(attr) ~= "table" then return nil end
    return {
        mode = attr.mode or "",
        size = tonumber(attr.size) or 0,
        modification = tonumber(attr.modification) or 0,
    }
end
local function same_file_signature(a, b)
    if a == b then return true end
    if not a or not b then return false end
    return a.mode == b.mode and a.size == b.size and a.modification == b.modification
end
local open_markdown_picker, rotate_screen_ccw, show_file_manager   -- fwd decls
-- Only ever one editor at a time. Opening a note while another editor is live
-- (e.g. a re-send via kindle-send, or a duplicate launch-flag write) must not
-- stack a second MDEdit on the same file: both keep polling the file and each
-- one's autosave looks like an external change to the other, producing a
-- "Reloaded from disk" storm and a half-repainted screen. edit_note() enforces
-- the singleton; MDEdit clears it on close.
local active_mdedit
local function notify(text)
    UIManager:show(Notification:new{ text = text, timeout = 3 })
end
local wake_repaint_pending = false
local function schedule_wake_repaint()
    if wake_repaint_pending then return end
    wake_repaint_pending = true
    UIManager:scheduleIn(1.0, function()
        wake_repaint_pending = false
        UIManager:setDirty("all", "full")
    end)
end
local MDEDIT_PAD = 24
local MDEDIT_TOPBAR_H = 56
local MDEDIT_TOPBAR_GAP = 14
local MDEDIT_TOOL_MIN_CELL = 72
local MDEDIT_TOOL_DIVIDER = 1
local MDEDIT_TITLE_ACTION_GAP = 18
local MDEDIT_MENU_W = 52
local MDEDIT_TITLE_W = 360
local MDEDIT_PROGRESS_H = 2
local MDEDIT_PROGRESS_GAP = 10
local MDEDIT_LINE_HEIGHT = 0.80
local MDEDIT_LINE_GAP = 0
local MDEDIT_PARA_GAP = 12
local MDEDIT_CARET_BLINK = 0.55
local MDEDIT_CARET_RESUME_DELAY = 0.70
local MDEDIT_SELECT_PAN_MIN = 18
local MDEDIT_EDIT_SCROLL_PAN_MIN = 42
local MDEDIT_PAGE_PAN_MIN = 24   -- min vertical drag (px) that triggers a page turn
local MDEDIT_EDIT_DTAP = 0.22    -- edit-mode double-tap must be deliberate; same cursor cell prevents reposition taps selecting
local MDEDIT_EDIT_DTAP_MOVE = 18
local MDEDIT_READER_DTAP = 0.25  -- reader double-tap must land within this fast window (also the single-tap page delay)
local MDEDIT_READER_EDGE = 130   -- reader taps within this many px of the L/R/bottom edge are page-turns, never an exit
local MDEDIT_AUTOSAVE_DELAY = 1.0
local MDEDIT_TYPE_FIRST_FLUSH_DELAY = 0.02
local MDEDIT_TYPE_FLUSH_DELAY = 0.045
local MDEDIT_TYPE_BURST_IDLE = 0.30
local MDEDIT_FILE_RELOAD_INTERVAL = 2.0
local MDEDIT_KEYBOARD_SWIPE_EDGE = 90
local MDEDIT_KEYBOARD_SWIPE_DY = 35
-- Hairline gap kept between the last text row and the keyboard's top edge, so the
-- text can run down into the strip that catches the swipe-to-hide gesture without
-- sitting flush against the keys.
local MDEDIT_KBD_TEXT_GAP = 8
-- Light-gray fill drawn behind ==highlighted== text (distinct from the darker
-- selection gray, and light enough to keep black text legible on e-ink).
local MDEDIT_HIGHLIGHT_GRAY = Blitbuffer.Color8(190)
local MINDMAP_PAD = 34
local MINDMAP_TOPBAR_H = 56
local MINDMAP_TOPBAR_GAP = 16
local MINDMAP_TOPBAR_PAD_X = Size.padding.large
local MINDMAP_TOPBAR_PAD_RIGHT = Size.padding.small
-- Match the editor's top framing so mode switches do not shift the chrome.
local MINDMAP_TOPBAR_TOP_PAD = MDEDIT_PAD
local MINDMAP_CLOSE_W = Screen:scaleBySize(50)
local MINDMAP_ACTION_DIVIDER = 1
local MINDMAP_MENU_TITLE_GAP = Screen:scaleBySize(18)
local MINDMAP_ACTION_MIN_W = Screen:scaleBySize(64)
local MINDMAP_EDIT_DTAP = 0.30
local MINDMAP_EDIT_DTAP_MOVE = 28
local MINDMAP_WORLD_TOP = 80
local MINDMAP_WORLD_ROW = 54
local MINDMAP_LABEL_GAP = 8
local MINDMAP_NODE_MIN_W = 200
local MINDMAP_NODE_MAX_W = 560
local MINDMAP_NODE_TAIL = 110
local MINDMAP_COLUMN_GAP = 90
local MINDMAP_NODE_H = 30
local MINDMAP_TEXT_BOTTOM_PAD = Screen:scaleBySize(5)
local MINDMAP_TEXT_LINE_TIGHTEN = Screen:scaleBySize(7)
local MINDMAP_MIN_ZOOM = 0.38
local MINDMAP_MAX_ZOOM = 2.2
local MINDMAP_PAN_GESTURE = 70
local MINDMAP_PAN_STEP = Screen:scaleBySize(100)
local MINDMAP_PAN_MIN_VISIBLE = Screen:scaleBySize(80)

-- ============================ Native Markdown mindmap ============================
-- Mirrors the desktop mindmap's forgiving parser: headings, lists, paragraphs,
-- blockquotes and fenced code blocks all become nodes in one depth stack. The
-- Kindle view stays native and edits Markdown ranges directly, so the editor and
-- map share one source of truth and one interpretation.
local function mindmap_node(kind, text, line, depth, extra)
    local node = {
        kind = kind,
        text = md_trim(text),
        line = line,
        depth = depth or 1,
        children = {},
    }
    if extra then for k, v in pairs(extra) do node[k] = v end end
    return node
end

local function parse_mindmap(markdown, title)
    local lines = split_text_lines(tostring(markdown or ""):gsub("\r\n", "\n"))
    local root = mindmap_node("root", title or "Mindmap", 1, 0)
    local stack = { { depth = 0, node = root } }
    local heading_level = 0
    local i = 1

    local function attach(depth, node)
        while #stack > 1 and stack[#stack].depth >= depth do table.remove(stack) end
        local parent = stack[#stack].node
        node.parent = parent
        parent.children[#parent.children+1] = node
        stack[#stack+1] = { depth = depth, node = node }
    end

    while i <= #lines do
        local line = lines[i] or ""
        if md_trim(line) == "" then
            i = i + 1
        else
            local hashes, htext = line:match("^(#{1,6})%s+(.*)$")
            if hashes then
                local level = #hashes
                heading_level = level
                attach(level, mindmap_node("heading", htext, i, level, { level = level }))
                i = i + 1
            else
                local fence, info = line:match("^%s*(```)(.*)$")
                if not fence then fence, info = line:match("^%s*(~~~)(.*)$") end
                if fence then
                    local marker = fence
                    local start_line = i
                    local raw = { line }
                    i = i + 1
                    while i <= #lines do
                        raw[#raw+1] = lines[i]
                        if lines[i]:match("^%s*" .. marker) then i = i + 1; break end
                        i = i + 1
                    end
                    attach(heading_level + 1, mindmap_node("code", (md_trim(info) ~= "" and ("``` " .. md_trim(info)) or "``` code"), start_line, heading_level + 1, { raw = raw }))
                elseif line:match("^%s*>") then
                    local start_line = i
                    local parts = {}
                    while i <= #lines and (lines[i] or ""):match("^%s*>") do
                        parts[#parts+1] = (lines[i] or ""):gsub("^%s*>%s?", "")
                        i = i + 1
                    end
                    attach(heading_level + 1, mindmap_node("quote", md_trim(table.concat(parts, " ")) ~= "" and table.concat(parts, " ") or "Quote", start_line, heading_level + 1))
                else
                    local indent, marker, rest = line:match("^(%s*)([-*+]%s+)(.*)$")
                    local ordered = false
                    if not marker then
                        indent, marker, rest = line:match("^(%s*)(%d+[.)]%s+)(.*)$")
                        ordered = marker ~= nil
                    end
                    if marker then
                        local nindent = #(tostring(indent or ""):gsub("\t", "  "))
                        local depth = heading_level + 1 + math.floor(nindent / 2)
                        local task, body = rest:match("^(%[[ xX]%]%s+)(.*)$")
                        attach(depth, mindmap_node("list", task and body or rest, i, depth, {
                            marker = marker,
                            ordered = ordered,
                            task = task,
                        }))
                        i = i + 1
                    else
                        local start_line = i
                        local parts = {}
                        while i <= #lines do
                            local l = lines[i] or ""
                            if md_trim(l) == "" then break end
                            if l:match("^(#{1,6})%s+") or l:match("^%s*[-*+]%s+") or l:match("^%s*%d+[.)]%s+")
                                or l:match("^%s*>") or l:match("^%s*```") or l:match("^%s*~~~") then break end
                            parts[#parts+1] = l
                            i = i + 1
                        end
                        attach(heading_level + 1, mindmap_node("paragraph", table.concat(parts, "\n"), start_line, heading_level + 1))
                    end
                end
            end
        end
    end

    if #root.children == 0 then
        root.children[1] = mindmap_node("heading", "Mindmap", 1, 1, { level = 1, parent = root })
    end
    return root
end

local MindmapCanvas = Widget:extend{}
function MindmapCanvas:getSize() return self.dimen end
function MindmapCanvas:paintTo(bb, x, y)
    local map = self.map
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    local function px(v) return math.floor(x + map.pan_x + v * map.zoom) end
    local function py(v) return math.floor(y + map.pan_y + v * map.zoom) end
    local function rect(rx, ry, rw, rh, color)
        local x0, y0, x1, y1 = math.max(x, rx), math.max(y, ry), math.min(x + w, rx + rw), math.min(y + h, ry + rh)
        if x1 > x0 and y1 > y0 then bb:paintRect(x0, y0, x1 - x0, y1 - y0, color) end
    end
    -- E-ink has no inexpensive anti-aliased path primitive. Clean elbows aligned
    -- to each node's visible rule read better than a stepped faux curve.
    for _, entry in ipairs(map.visual_nodes or {}) do
        local node = entry.node
        if node.parent and node.parent.mx then
            local p, n = node.parent, node
            local x1, y1 = px(p.mx + p.mw), py(p.my + p.mh)
            local x2, y2 = px(n.mx), py(n.my + n.mh)
            if not (math.max(x1, x2) < x or math.min(x1, x2) > x + w or math.max(y1, y2) < y or math.min(y1, y2) > y + h) then
                local stroke = math.max(1, math.floor(map.zoom))
                local mid = math.floor((x1 + x2) / 2)
                local color = Blitbuffer.Color8(105)
                rect(math.min(x1, mid), y1 - stroke, math.abs(mid - x1) + stroke, stroke, color)
                rect(mid - stroke, math.min(y1, y2), stroke, math.abs(y2 - y1) + stroke, color)
                rect(math.min(mid, x2), y2 - stroke, math.abs(x2 - mid) + stroke, stroke, color)
            end
        end
    end
    for _, entry in ipairs(map.visual_nodes or {}) do
        local n = entry.node
        local nx, ny = px(n.mx), py(n.my)
        local nw, nh = math.max(2, math.floor(n.mw * map.zoom)), math.max(2, math.floor(n.mh * map.zoom))
        local selected = entry.index == map.selected
        local style = n.kind == "root" and "h1" or map:nodeStyle(n)
        if nx + nw >= x and nx <= x + w and ny + nh >= y and ny <= y + h and nw > 22 and nh > 12 then
            local face = md_face(style, math.max(0.45, map.scale * map.zoom))
            local lines = (selected and map.editing_index == entry.index and map.edit_lines) or n.mlines or { map:nodeText(n) }
            local ty = ny + 1
            local edit_cursor, chars_before, cursor_drawn = selected and map.editing_index == entry.index and map.edit_col, 0, false
            for line_i, text in ipairs(lines) do
                local tw = TextWidget:new{ text = text, face = face, fgcolor = md_color(style) }
                local ts = tw:getSize()
                -- TextWidget paints directly into the BlitBuffer and does not
                -- safely clip negative/off-edge coordinates. Nodes can straddle
                -- the viewport while panning, so only paint fully visible text.
                if nx >= x and nx + ts.w <= x + w and ty >= y and ty + ts.h <= y + h then
                    tw:paintTo(bb, nx, ty)
                end
                if edit_cursor and map.caret_on and not cursor_drawn and (edit_cursor <= chars_before + #text or line_i == #lines) then
                    local col = math.max(0, math.min(#text, edit_cursor - chars_before))
                    local caret_x = nx + map:textw(text:sub(1, col), face)
                    rect(caret_x, ty, math.max(2, math.floor(map.zoom * 2)), ts.h, Blitbuffer.COLOR_BLACK)
                    map.caret_region = Geom:new{ x = caret_x, y = ty, w = math.max(2, math.floor(map.zoom * 2)), h = ts.h }
                    cursor_drawn = true
                end
                chars_before = chars_before + #text + 1
                if line_i < #lines then
                    ty = ty + math.max(1, ts.h - MINDMAP_TEXT_LINE_TIGHTEN)
                end
                tw:free()
            end
        end
        -- The only node chrome is its terminator line, matching Minfolio's map.
        local line_y = ny + nh - math.max(1, math.floor(map.zoom))
        rect(nx, line_y, nw, selected and math.max(4, math.floor(map.zoom * 3)) or math.max(1, math.floor(map.zoom)), selected and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(105))
    end
end

local MindmapView = InputContainer:extend{ editor = nil, is_always_active = true, disable_double_tap = true }
function MindmapView:init()
    self.fw, self.fh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh }
    self.scale = self.editor and self.editor.scale or clamp_minfolio_scale(MINFOLIO_STATE.scale)
    self.parent = self
    self.path = self.editor and self.editor.path or ""
    self.root = parse_mindmap(self.editor and self.editor:currentText() or "", path_base(self.path))
    self.rows, self.selected, self._undo, self.top_zones = {}, 1, {}, {}
    self.zoom, self.pan_x, self.pan_y = 1, 0, 0
    self.caret_on, self._map_caret_blinking = true, true
    self.canvas_y = MINDMAP_TOPBAR_H + MINDMAP_TOPBAR_TOP_PAD + MINDMAP_TOPBAR_GAP
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
            Pan = { GestureRange:new{ ges = "pan", range = self.dimen } },
            PanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
            Pinch = { GestureRange:new{ ges = "pinch", range = self.dimen } },
            Spread = { GestureRange:new{ ges = "spread", range = self.dimen } },
        }
    end
    self:flatten()
    -- Node height depends on the readable font size at the fitted zoom. A few
    -- passes converge the map bounds before its first paint.
    for _ = 1, 3 do
        self:layoutMap()
        self:fitMap()
    end
    self:rebuild()
    self:scheduleMapCaretBlink()
end

function MindmapView:textw(txt, face)
    if txt == "" then return 0 end
    local tw = TextWidget:new{ text = txt, face = face }
    local w = tw:getSize().w; tw:free(); return w
end

function MindmapView:trimToWidth(text, maxw, face)
    if self:textw(text, face) <= maxw then return text end
    local ell, lo, hi, best = "...", 0, #text, "..."
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local s = text:sub(1, mid) .. ell
        if self:textw(s, face) <= maxw then best = s; lo = mid + 1 else hi = mid - 1 end
    end
    return best
end

function MindmapView:flatten()
    local rows = {}
    local function walk(node, depth)
        if node.kind ~= "root" then rows[#rows+1] = { node = node, depth = depth } end
        for _, child in ipairs(node.children or {}) do walk(child, depth + 1) end
    end
    for _, child in ipairs(self.root.children or {}) do walk(child, 0) end
    local text_lines = split_text_lines(self.editor and self.editor:currentText() or "")
    for i, entry in ipairs(rows) do
        local finish = #text_lines
        for j = i + 1, #rows do if rows[j].depth <= entry.depth then finish = math.max(entry.node.line, rows[j].node.line - 1); break end end
        entry.finish, entry.node.finish = finish, finish
    end
    self.rows = rows
    self.selected = math.max(1, math.min(self.selected or 1, math.max(1, #rows)))
end

function MindmapView:nodeStyle(node)
    if node.kind == "heading" then return "h" .. math.min(3, tonumber(node.level) or 3) end
    if node.kind == "code" then return "code" end
    if node.kind == "quote" then return "quote" end
    if node.kind == "list" then return "bullet" end
    return "normal"
end

function MindmapView:nodeText(node)
    local text = md_trim(node.text)
    text = text:gsub("^#{1,6}%s+", "")
    if node.kind == "list" and node.task then text = (node.task:match("%[[xX]%]") and "[x] " or "[ ] ") .. text end
    if node.kind == "paragraph" then text = text:gsub("%s*\n%s*", " ") end
    local plain = {}
    for _, span in ipairs(md_inline(text)) do
        if span.style ~= "syntax" then plain[#plain+1] = span.display or span.text or "" end
    end
    text = table.concat(plain)
    return text ~= "" and text or (node.kind == "paragraph" and "Paragraph" or "Untitled")
end

function MindmapView:mapRegion()
    return Geom:new{ x = 0, y = self.canvas_y, w = self.fw, h = math.max(1, self.fh - self.canvas_y) }
end

function MindmapView:mapDirtyTarget()
    -- The map itself is full-screen while the keyboard is a separate window
    -- above it. Repainting only the map would erase the keyboard's pixels
    -- without repainting that top layer.
    return self.keyboard and "all" or self
end

function MindmapView:scheduleMapCaretBlink()
    UIManager:scheduleIn(MDEDIT_CARET_BLINK, function()
        if not self._map_caret_blinking then return end
        if self.editing_index then
            self.caret_on = not self.caret_on
            UIManager:setDirty(self:mapDirtyTarget(), "ui", self.caret_region or self:mapRegion())
        else
            self.caret_on = false
        end
        self:scheduleMapCaretBlink()
    end)
end

function MindmapView:layoutMap()
    local max_width_by_depth, max_depth = {}, 0
    local function measure(node)
        local style = node.kind == "root" and "h1" or self:nodeStyle(node)
        local text = node.kind == "root" and node.text or (node._edit_text or self:nodeText(node))
        local face = md_face(style, self.scale)
        local text_limit = MINDMAP_NODE_MAX_W - MINDMAP_NODE_TAIL
        node.mw = math.max(MINDMAP_NODE_MIN_W, math.min(MINDMAP_NODE_MAX_W, self:textw(text, face) + MINDMAP_NODE_TAIL))
        node.mlines = self:wrapNodeText(text, math.min(text_limit, node.mw - MINDMAP_NODE_TAIL), face)
        -- The canvas keeps type readable at low zoom (rather than scaling it
        -- below 0.45). Measure that exact rendered face here, then convert its
        -- screen height back to map coordinates. This keeps wrapped labels above
        -- their fixed terminator line instead of letting text paint through it.
        local render_scale = math.max(0.45, self.scale * self.zoom)
        local probe = TextWidget:new{ text = "Hg", face = md_face(style, render_scale) }
        local line_h = probe:getSize().h; probe:free()
        local line_step = math.max(1, line_h - MINDMAP_TEXT_LINE_TIGHTEN)
        local text_h = line_h + math.max(0, #node.mlines - 1) * line_step
        node.mh = math.max(MINDMAP_NODE_H, math.ceil((text_h + MINDMAP_TEXT_BOTTOM_PAD) / self.zoom))
        node._map_depth = node._map_depth or 0
        max_depth = math.max(max_depth, node._map_depth)
        max_width_by_depth[node._map_depth] = math.max(max_width_by_depth[node._map_depth] or 0, node.mw)
        for _, child in ipairs(node.children or {}) do child._map_depth = node._map_depth + 1; measure(child) end
    end
    self.root._map_depth = 0
    measure(self.root)
    local column_x, x = {}, 0
    for depth = 0, max_depth do
        column_x[depth] = x
        x = x + (max_width_by_depth[depth] or MINDMAP_NODE_MIN_W) + MINDMAP_COLUMN_GAP
    end
    local leaf_count, last_leaf_baseline = 0, nil
    local function place(node, depth)
        node.mx = column_x[depth] or 0
        if #node.children == 0 then
            local nominal = MINDMAP_WORLD_TOP + leaf_count * MINDMAP_WORLD_ROW
            -- Labels are bottom-aligned to their terminator line. Expand only
            -- the following branch's gap when its upward-growing label needs it.
            node.baseline = last_leaf_baseline and math.max(
                nominal, last_leaf_baseline + node.mh + MINDMAP_LABEL_GAP
            ) or nominal
            node.my = node.baseline - node.mh
            last_leaf_baseline = node.baseline
            leaf_count = leaf_count + 1
        else
            for _, child in ipairs(node.children) do place(child, depth + 1) end
            node.baseline = (node.children[1].baseline + node.children[#node.children].baseline) / 2
            node.my = node.baseline - node.mh
        end
    end
    place(self.root, 0)

    -- Long parent labels can still collide with a neighbouring parent despite
    -- their children being clear. Resolve those collisions per depth, moving an
    -- entire branch so its internal connector geometry stays intact.
    local by_depth = {}
    local function collect(node)
        local nodes = by_depth[node._map_depth] or {}
        nodes[#nodes + 1] = node
        by_depth[node._map_depth] = nodes
        for _, child in ipairs(node.children) do collect(child) end
    end
    local function shift_branch(node, delta)
        node.baseline, node.my = node.baseline + delta, node.my + delta
        for _, child in ipairs(node.children) do shift_branch(child, delta) end
    end
    local function settle_parents(node)
        if #node.children > 0 then
            for _, child in ipairs(node.children) do settle_parents(child) end
            node.baseline = (node.children[1].baseline + node.children[#node.children].baseline) / 2
            node.my = node.baseline - node.mh
        end
    end
    collect(self.root)
    for depth = max_depth, 1, -1 do
        local previous
        for _, node in ipairs(by_depth[depth] or {}) do
            if previous then
                local delta = previous.baseline + MINDMAP_LABEL_GAP - node.my
                if delta > 0 then shift_branch(node, delta) end
            end
            previous = node
        end
        settle_parents(self.root)
    end
    self.visual_nodes = { { index = 0, node = self.root } }
    for i, entry in ipairs(self.rows) do self.visual_nodes[#self.visual_nodes+1] = { index = i, node = entry.node } end
    self.world_w = math.max(MINDMAP_NODE_MIN_W, x - MINDMAP_COLUMN_GAP)
    local bottom = MINDMAP_WORLD_TOP
    for _, entry in ipairs(self.visual_nodes) do bottom = math.max(bottom, entry.node.baseline) end
    self.world_h = math.max(MINDMAP_NODE_H, bottom + MINDMAP_WORLD_ROW)
end

function MindmapView:wrapNodeText(text, maxw, face)
    local lines, line = {}, ""
    for word in tostring(text or ""):gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if line ~= "" and self:textw(candidate, face) > maxw then
            lines[#lines+1], line = line, word
        else
            line = candidate
        end
    end
    if line ~= "" then lines[#lines+1] = line end
    return #lines > 0 and lines or { "Untitled" }
end

function MindmapView:nodeAt(pos)
    if not pos then return nil end
    local wx = (pos.x - MINDMAP_PAD - self.pan_x) / self.zoom
    local wy = (pos.y - self.canvas_y - self.pan_y) / self.zoom
    local root = self.root
    if root and wx >= root.mx and wx <= root.mx + root.mw and wy >= root.my and wy <= root.my + root.mh then return 0 end
    for i, entry in ipairs(self.rows or {}) do
        local n = entry.node
        if wx >= n.mx and wx <= n.mx + n.mw and wy >= n.my and wy <= n.my + n.mh then return i end
    end
end

function MindmapView:linePrefix(line)
    local prefix = line:match("^(#{1,6}%s+)") or line:match("^(%s*>%s?)")
    if prefix then return prefix end
    local indent, marker, body = line:match("^(%s*)([-*+]%s+)(.*)$")
    if not marker then indent, marker, body = line:match("^(%s*)(%d+[.)]%s+)(.*)$") end
    if marker then return (indent or "") .. marker .. ((body or ""):match("^(%[[ xX]%]%s+)") or "") end
    return ""
end

function MindmapView:showMapKeyboard()
    if self.keyboard or not Device:isTouchDevice() then return end
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local keyboard = VirtualKeyboard:new{ inputbox = self }
    MinfolioPair.makeKeyboardArrowFree(keyboard)
    MinfolioPair.disableKeyboardKeyFlash(keyboard)
    keyboard.modal = false
    self.keyboard = keyboard
    local map, original_close = self, keyboard.onCloseWidget
    function keyboard:onCloseWidget()
        if original_close then original_close(self) end
        if map.keyboard == self then map.keyboard = nil; map:refresh() end
    end
    UIManager:show(keyboard)
end

function MindmapView:hideMapKeyboard()
    if not self.keyboard then return end
    local keyboard = self.keyboard
    self.keyboard = nil
    UIManager:close(keyboard)
end

function MindmapView:beginNodeEdit(index)
    local entry = self.rows and self.rows[index]
    if not entry or not self.editor then return end
    self.selected = index
    local line = (split_text_lines(self.editor:currentText()))[entry.node.line] or ""
    self.editing_index, self.edit_line = index, entry.node.line
    self.caret_on = true
    self.edit_prefix = self:linePrefix(line)
    self.edit_text, self.edit_col = line:sub(#self.edit_prefix + 1), #line - #self.edit_prefix
    entry.node._edit_text = self.edit_text
    self.edit_lines = self:wrapNodeText(self.edit_text, MINDMAP_NODE_MAX_W - MINDMAP_NODE_TAIL, md_face(self:nodeStyle(entry.node), self.scale))
    self:layoutMap()
    self:showMapKeyboard()
    self:refresh()
end

function MindmapView:updateEditLayout()
    local entry = self:selectedEntry()
    if entry then
        entry.node._edit_text = self.edit_text
        self.edit_lines = self:wrapNodeText(self.edit_text, MINDMAP_NODE_MAX_W - MINDMAP_NODE_TAIL, md_face(self:nodeStyle(entry.node), self.scale))
        self:layoutMap()
    end
    self:refresh()
end

function MindmapView:commitNodeEdit()
    if not self.editing_index or not self.editor then return false end
    local line, prefix = self.edit_line, self.edit_prefix
    local text = tostring(self.edit_text or ""):gsub("[\r\n]+", " ")
    local lines = split_text_lines(self.editor:currentText())
    local changed = lines[line] ~= (prefix .. text)
    local entry = self.rows and self.rows[self.editing_index]
    if entry then entry.node._edit_text = nil end
    self.editing_index, self.edit_line, self.edit_prefix, self.edit_text, self.edit_lines = nil, nil, nil, nil, nil
    self.caret_on, self.caret_region = false, nil
    self:hideMapKeyboard()
    if changed then
        self:snapshot()
        lines[line] = prefix .. text
        self:applyLines(lines, line)
    else
        self:refresh()
    end
    return true
end

function MindmapView:cancelNodeEdit()
    if not self.editing_index then return end
    local entry = self.rows and self.rows[self.editing_index]
    if entry then entry.node._edit_text = nil end
    self.editing_index, self.edit_line, self.edit_prefix, self.edit_text, self.edit_lines = nil, nil, nil, nil, nil
    self.caret_on, self.caret_region = false, nil
    self:layoutMap()
    self:hideMapKeyboard()
    self:refresh()
end

-- VirtualKeyboard inputbox interface for the in-place node editor.
function MindmapView:addChars(chars)
    if not self.editing_index then return end
    local before, after = self.edit_text:sub(1, self.edit_col), self.edit_text:sub(self.edit_col + 1)
    self.edit_text = before .. tostring(chars or "") .. after
    self.edit_col = #before + #(tostring(chars or ""))
    self:updateEditLayout()
end
function MindmapView:delChar()
    if self.editing_index and self.edit_col > 0 then
        local start = utf8_left(self.edit_text, self.edit_col)
        self.edit_text, self.edit_col = self.edit_text:sub(1, start) .. self.edit_text:sub(self.edit_col + 1), start
        self:updateEditLayout()
    end
end
function MindmapView:delWord()
    if not self.editing_index then return end
    local start, old = prev_word_col(self.edit_text, self.edit_col), self.edit_col
    self.edit_text, self.edit_col = self.edit_text:sub(1, start) .. self.edit_text:sub(old + 1), start
    self:updateEditLayout()
end
function MindmapView:delToStartOfLine() if self.editing_index then self.edit_text = self.edit_text:sub(self.edit_col + 1); self.edit_col = 0; self:updateEditLayout() end end
function MindmapView:leftChar() if self.editing_index then self.edit_col = utf8_left(self.edit_text, self.edit_col); self:updateEditLayout() end end
function MindmapView:rightChar() if self.editing_index then self.edit_col = utf8_right(self.edit_text, self.edit_col); self:updateEditLayout() end end
function MindmapView:goToStartOfLine() if self.editing_index then self.edit_col = 0; self:updateEditLayout() end end
function MindmapView:goToEndOfLine() if self.editing_index then self.edit_col = #self.edit_text; self:updateEditLayout() end end
function MindmapView:upLine() end
function MindmapView:downLine() end
function MindmapView:scrollUp() end
function MindmapView:scrollDown() end
function MindmapView:onSwitchingKeyboardLayout() end

function MindmapView:fitMap()
    local vw, vh = self.fw - (MINDMAP_PAD * 2), self.fh - self.canvas_y - MINDMAP_PAD
    self.zoom = math.max(MINDMAP_MIN_ZOOM, math.min(1.0, vw / (self.world_w + 40), vh / (self.world_h + 40)))
    self.pan_x = math.floor((vw - self.world_w * self.zoom) / 2)
    self.pan_y = math.floor((vh - self.world_h * self.zoom) / 2)
end

function MindmapView:clampPan()
    local vw, vh = self.fw - (MINDMAP_PAD * 2), self.fh - self.canvas_y - MINDMAP_PAD
    local map_w, map_h = self.world_w * self.zoom, self.world_h * self.zoom
    -- Fitted maps must still be movable. The bounds retain a small visible
    -- slice of content instead of re-centering a map merely because it fits.
    local visible_w = math.min(MINDMAP_PAN_MIN_VISIBLE, map_w)
    local visible_h = math.min(MINDMAP_PAN_MIN_VISIBLE, map_h)
    self.pan_x = math.max(visible_w - map_w, math.min(vw - visible_w, self.pan_x))
    self.pan_y = math.max(visible_h - map_h, math.min(vh - visible_h, self.pan_y))
end

function MindmapView:topBar(cw)
    local title_face = Font:getFace("cfont", 22)
    local action_face = Font:getFace("cfont", 19)
    local raw_title = (path_base(self.path) ~= "" and path_base(self.path) or "Mindmap")
    local labels = {
        { name = "add", text = "Add" },
        { name = "delete", text = "Del" },
        { name = "undo", text = "Undo" },
        { name = "edit", text = "Edit" },
        { name = "close", icon = "close" },
    }
    local action_total = 0
    for _, item in ipairs(labels) do
        item.w = item.icon and MINDMAP_CLOSE_W or math.max(MINDMAP_ACTION_MIN_W, self:textw(item.text, action_face) + 28)
        action_total = action_total + item.w
    end
    action_total = action_total + ((#labels - 1) * MINDMAP_ACTION_DIVIDER)
    local max_title_w = math.max(60, cw - MDEDIT_MENU_W - MINDMAP_MENU_TITLE_GAP - action_total - MDEDIT_TITLE_ACTION_GAP)
    local title = self:trimToWidth(raw_title, max_title_w, title_face)
    local title_w = self:textw(title, title_face)
    local gap_w = math.max(MDEDIT_TITLE_ACTION_GAP, cw - MDEDIT_MENU_W - MINDMAP_MENU_TITLE_GAP - title_w - action_total)
    local x = MDEDIT_MENU_W + MINDMAP_MENU_TITLE_GAP
    self.top_zones.menu = { x0 = 0, x1 = MDEDIT_MENU_W }
    x = x + title_w + gap_w
    local actions = {}
    for i, item in ipairs(labels) do
        if i > 1 then
            actions[#actions+1] = CenterContainer:new{ dimen = Geom:new{ w = MINDMAP_ACTION_DIVIDER, h = MINDMAP_TOPBAR_H },
                LineWidget:new{ background = Blitbuffer.Color8(210), dimen = Geom:new{ w = MINDMAP_ACTION_DIVIDER, h = math.floor(MINDMAP_TOPBAR_H * 0.46) } }
            }
            x = x + MINDMAP_ACTION_DIVIDER
        end
        self.top_zones[item.name] = { x0 = x, x1 = x + item.w }
        actions[#actions+1] = CenterContainer:new{ dimen = Geom:new{ w = item.w, h = MINDMAP_TOPBAR_H },
            item.icon and IconWidget:new{ icon = item.icon, width = Screen:scaleBySize(29), height = Screen:scaleBySize(29) }
                or TextWidget:new{ text = item.text, face = action_face, fgcolor = Blitbuffer.COLOR_BLACK } }
        x = x + item.w
    end
    local content = HorizontalGroup:new{ align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = MDEDIT_MENU_W, h = MINDMAP_TOPBAR_H },
            IconWidget:new{ icon = "appbar.menu", width = Screen:scaleBySize(24), height = Screen:scaleBySize(24) } },
        HorizontalSpan:new{ width = MINDMAP_MENU_TITLE_GAP },
        CenterContainer:new{ dimen = Geom:new{ w = title_w, h = MINDMAP_TOPBAR_H },
            TextWidget:new{ text = title, face = title_face, fgcolor = Blitbuffer.Color8(110) } },
        HorizontalSpan:new{ width = gap_w },
        HorizontalGroup:new(actions),
    }
    local padded = HorizontalGroup:new{ align = "center",
        HorizontalSpan:new{ width = MINDMAP_TOPBAR_PAD_X }, content,
        HorizontalSpan:new{ width = MINDMAP_TOPBAR_PAD_RIGHT } }
    return CenterContainer:new{ dimen = Geom:new{ w = cw + MINDMAP_TOPBAR_PAD_X + MINDMAP_TOPBAR_PAD_RIGHT, h = MINDMAP_TOPBAR_H + MINDMAP_TOPBAR_TOP_PAD }, padded }
end

function MindmapView:rebuild()
    local cw = self.fw - (MINDMAP_PAD * 2)
    local topbar = self:topBar(self.fw - MINDMAP_TOPBAR_PAD_X - MINDMAP_TOPBAR_PAD_RIGHT)
    local canvas_h = self.fh - self.canvas_y - MINDMAP_PAD
    local canvas = MindmapCanvas:new{ map = self, dimen = Geom:new{ w = cw, h = canvas_h } }
    local vg = VerticalGroup:new{ align = "left", topbar, VerticalSpan:new{ width = MINDMAP_TOPBAR_GAP },
        CenterContainer:new{ dimen = Geom:new{ w = self.fw, h = canvas_h }, canvas } }
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0,
        width = self.fw, height = self.fh, vg }
end

function MindmapView:refresh(region)
    self:rebuild()
    UIManager:setDirty(self:mapDirtyTarget(), "ui", region or self:mapRegion())
end

function MindmapView:selectedEntry()
    return self.rows and self.rows[self.selected or 1] or nil
end

function MindmapView:reloadFromEditor(keep_line)
    self.root = parse_mindmap(self.editor and self.editor:currentText() or "", path_base(self.path))
    self:flatten()
    self:layoutMap()
    if keep_line then
        for i, entry in ipairs(self.rows) do
            if entry.node.line and entry.node.line >= keep_line then
                self.selected = i
                break
            end
        end
    end
end

function MindmapView:snapshot()
    if not self.editor then return end
    self._undo[#self._undo+1] = {
        text = self.editor:currentText(),
        selected = self.selected,
        pan_x = self.pan_x, pan_y = self.pan_y, zoom = self.zoom,
    }
    if #self._undo > 80 then table.remove(self._undo, 1) end
end

function MindmapView:applyLines(lines, keep_line)
    if not self.editor then return false end
    local text = table.concat(lines, "\n")
    self.editor.lines = split_text_lines(text)
    self.editor.crow = math.max(1, math.min(keep_line or self.editor.crow or 1, #self.editor.lines))
    self.editor.ccol = math.max(0, math.min(self.editor.ccol or 0, #(self.editor.lines[self.editor.crow] or "")))
    self.editor.sel = nil
    self.editor._vrows_dirty = true
    self.editor:save()
    self:reloadFromEditor(keep_line)
    self:refresh()
    return true
end

function MindmapView:undo()
    local snap = self._undo and table.remove(self._undo)
    if not snap or not self.editor then return notify(_("Nothing to undo")) end
    self.editor.lines = split_text_lines(snap.text or "")
    self.editor._vrows_dirty = true
    self.editor:save()
    self.selected = snap.selected or 1
    self.pan_x, self.pan_y, self.zoom = snap.pan_x or 0, snap.pan_y or 0, snap.zoom or self.zoom
    self:reloadFromEditor()
    self:refresh()
end

function MindmapView:rangeFor(index)
    local entry = self.rows and self.rows[index]
    if not entry then return nil end
    return entry.node.line, entry.finish or entry.node.finish or entry.node.line
end

function MindmapView:siblingRange(index, dir)
    local entry = self.rows and self.rows[index]
    if not entry then return nil end
    local parent = entry.node.parent
    local candidate
    for i, row in ipairs(self.rows) do
        if i ~= index and row.node.parent == parent and (row.depth or 0) == (entry.depth or 0) then
            if dir < 0 and i < index then candidate = i
            elseif dir > 0 and i > index then return i end
        end
    end
    return candidate
end

function MindmapView:lineKind(line)
    local hashes = line:match("^(#{1,6})%s+")
    if hashes then return "heading", #hashes end
    local indent, marker = line:match("^(%s*)([-*+]%s+)")
    if not marker then indent, marker = line:match("^(%s*)(%d+[.)]%s+)") end
    if marker then return "list", #(indent or "") end
    return "paragraph", 0
end

function MindmapView:adjustRangeDepth(lines, first, finish, dir)
    for i = first, finish do
        local line = lines[i] or ""
        local kind = self:lineKind(line)
        if kind == "heading" then
            if dir > 0 then
                lines[i] = "#" .. line
            else
                lines[i] = line:gsub("^#", "", 1)
            end
        elseif kind == "list" then
            if dir > 0 then
                lines[i] = "  " .. line
            else
                lines[i] = line:gsub("^  ", "", 1)
                if lines[i] == line then lines[i] = line:gsub("^%s", "", 1) end
            end
        end
    end
end

function MindmapView:addChild()
    if self.selected == 0 and self.editor then
        local lines = split_text_lines(self.editor:currentText())
        self:snapshot()
        if #lines > 0 and md_trim(lines[#lines] or "") ~= "" then table.insert(lines, "") end
        table.insert(lines, "# New node")
        return self:applyLines(lines, #lines)
    end
    local entry = self:selectedEntry()
    if not entry or not self.editor then return end
    local first, finish = self:rangeFor(self.selected)
    local lines = split_text_lines(self.editor:currentText())
    local line = lines[first] or ""
    local kind, level = self:lineKind(line)
    local new_line
    if kind == "heading" then
        new_line = string.rep("#", math.min(6, level + 1)) .. " New node"
    elseif kind == "list" then
        new_line = string.rep(" ", level + 2) .. "- New node"
    else
        new_line = "- New node"
    end
    self:snapshot()
    table.insert(lines, finish + 1, new_line)
    self:applyLines(lines, finish + 1)
end

function MindmapView:deleteSelected()
    local first, finish = self:rangeFor(self.selected)
    if not first or not self.editor then return end
    local lines = split_text_lines(self.editor:currentText())
    self:snapshot()
    for _ = first, finish do table.remove(lines, first) end
    if #lines == 0 then lines[1] = "" end
    self.selected = math.max(1, math.min(self.selected, math.max(1, #self.rows - 1)))
    self:applyLines(lines, first)
end

function MindmapView:moveSibling(dir)
    local other = self:siblingRange(self.selected, dir)
    if not other or not self.editor then return notify(_("No sibling there")) end
    local a1, a2 = self:rangeFor(self.selected)
    local b1, b2 = self:rangeFor(other)
    local lines = split_text_lines(self.editor:currentText())
    self:snapshot()
    if dir < 0 then
        local block_a, block_b = {}, {}
        for i = b1, b2 do block_b[#block_b+1] = lines[i] end
        for i = a1, a2 do block_a[#block_a+1] = lines[i] end
        for _ = b1, a2 do table.remove(lines, b1) end
        for i = #block_a, 1, -1 do table.insert(lines, b1, block_a[i]) end
        for i = #block_b, 1, -1 do table.insert(lines, b1 + #block_a, block_b[i]) end
        self.selected = other
        self:applyLines(lines, b1)
    else
        local block_a, block_b = {}, {}
        for i = a1, a2 do block_a[#block_a+1] = lines[i] end
        for i = b1, b2 do block_b[#block_b+1] = lines[i] end
        for _ = a1, b2 do table.remove(lines, a1) end
        for i = #block_b, 1, -1 do table.insert(lines, a1, block_b[i]) end
        for i = #block_a, 1, -1 do table.insert(lines, a1 + #block_b, block_a[i]) end
        self.selected = other
        self:applyLines(lines, a1 + #block_b)
    end
end

function MindmapView:reattach(dir)
    local first, finish = self:rangeFor(self.selected)
    if not first or not self.editor then return end
    local lines = split_text_lines(self.editor:currentText())
    local line = lines[first] or ""
    local kind, level = self:lineKind(line)
    if dir < 0 and ((kind == "heading" and level <= 1) or (kind == "list" and level <= 0) or kind == "paragraph") then
        return notify(_("Cannot outdent this node"))
    end
    if dir > 0 and kind == "heading" and level >= 6 then return notify(_("Heading is already deepest")) end
    self:snapshot()
    self:adjustRangeDepth(lines, first, finish, dir)
    self:applyLines(lines, first)
end

function MindmapView:close()
    if self.editing_index then self:commitNodeEdit() end
    self._map_caret_blinking = false
    UIManager:close(self)
    if self.editor then self.editor:refresh{ layout_dirty = false, full = true } end
end

function MindmapView:saveAndClose()
    if self.editing_index then self:commitNodeEdit() end
    self._map_caret_blinking = false
    UIManager:close(self)
    if self.editor then self.editor:saveAndClose() end
end

function MindmapView:openControls()
    show_controls({
        { text = "Back to editor", callback = function() self:close() end },
        { text = "Edit selected node", callback = function()
            local entry = self:selectedEntry()
            self:jumpTo(entry and entry.node.line)
        end },
        { text = "Add child node", keep = true, callback = function() self:addChild() end },
        { text = "Delete selected branch", keep = true, callback = function() self:deleteSelected() end },
        { text = "Undo map edit", keep = true, callback = function() self:undo() end },
        { text = "Move branch up", keep = true, callback = function() self:moveSibling(-1) end },
        { text = "Move branch down", keep = true, callback = function() self:moveSibling(1) end },
        { text = "Attach under previous branch", keep = true, callback = function() self:reattach(1) end },
        { text = "Attach to parent branch", keep = true, callback = function() self:reattach(-1) end },
        { text = "Zoom in", keep = true, callback = function() self:zoomAt(nil, 1.25) end },
        { text = "Zoom out", keep = true, callback = function() self:zoomAt(nil, 0.8) end },
        { text = "Fit map to screen", keep = true, callback = function() self:fitMap(); self:refresh() end },
        { text = "Text size +", keep = true, callback = function()
            if self.editor then self.editor:bumpScale(0.1); self.scale = self.editor.scale end
            self:refresh()
        end },
        { text = "Text size -", keep = true, callback = function()
            if self.editor then self.editor:bumpScale(-0.1); self.scale = self.editor.scale end
            self:refresh()
        end },
        { text = "⟲ Rotate screen", callback = function() rotate_screen_ccw() end },
    }, function() self:refresh() end)
end

function MindmapView:jumpTo(line)
    if self.editor and line then
        self.editor:setReaderMode(false, line, 0)
    end
    self:close()
end

function MindmapView:onTap(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    if self.editing_index then self:commitNodeEdit() end
    if p.y < 95 then
        local x = p.x - MINDMAP_TOPBAR_PAD_X
        for name, z in pairs(self.top_zones or {}) do
            if x >= z.x0 and x < z.x1 then
                if name == "menu" then self:openControls()
                elseif name == "add" then self:addChild()
                elseif name == "delete" then self:deleteSelected()
                elseif name == "undo" then self:undo()
                elseif name == "edit" then self:close()
                elseif name == "close" then self:saveAndClose() end
                return true
            end
        end
        return true
    end
    local hit = self:nodeAt(p)
    if hit ~= nil then
        local now = now_seconds()
        local last = self._last_node_tap
        if hit > 0 and last and last.index == hit and now - last.t < MINDMAP_EDIT_DTAP
            and math.abs(p.x - last.x) < MINDMAP_EDIT_DTAP_MOVE and math.abs(p.y - last.y) < MINDMAP_EDIT_DTAP_MOVE then
            self._last_node_tap = nil
            self:beginNodeEdit(hit)
        else
            self.selected = hit
            self._last_node_tap = { index = hit, x = p.x, y = p.y, t = now }
            self:refresh()
        end
        return true
    end
    return true
end

function MindmapView:onDoubleTap(_, ges)
    local hit = self:nodeAt(ges and ges.pos)
    if hit then self:beginNodeEdit(hit) end
    return true
end

function MindmapView:onPan(_, ges)
    local p, sp = ges and ges.pos, ges and ges.start_pos
    if not p or not sp then return true end
    local dx, dy = p.x - sp.x, p.y - sp.y
    local horizontal = math.abs(dx) >= math.abs(dy)
    local distance = horizontal and dx or dy
    local steps = math.floor(math.abs(distance) / MINDMAP_PAN_GESTURE)
    local direction = distance < 0 and -1 or 1
    local signature = (horizontal and "x" or "y") .. direction
    if self._pan_signature ~= signature then self._pan_signature, self._pan_moved = signature, false end
    -- Panning is intentionally coarse, like zoom: one small, predictable move
    -- per swipe rather than a viewport-sized jump for every gesture update.
    if steps > 0 and not self._pan_moved then
        if horizontal then self.pan_x = self.pan_x + direction * MINDMAP_PAN_STEP
        else self.pan_y = self.pan_y + direction * MINDMAP_PAN_STEP end
        self:clampPan()
        self._pan_moved = true
        self:refresh()
    end
    return true
end

function MindmapView:onPanRelease()
    self._pan_signature, self._pan_moved = nil, nil
    return true
end

function MindmapView:zoomAt(pos, factor)
    local old = self.zoom
    local new = math.max(MINDMAP_MIN_ZOOM, math.min(MINDMAP_MAX_ZOOM, old * factor))
    if new == old then return end
    local cx = pos and (pos.x - MINDMAP_PAD) or (self.fw - MINDMAP_PAD * 2) / 2
    local cy = pos and (pos.y - self.canvas_y) or (self.fh - self.canvas_y - MINDMAP_PAD) / 2
    local wx, wy = (cx - self.pan_x) / old, (cy - self.pan_y) / old
    self.zoom = new
    self.pan_x, self.pan_y = cx - wx * new, cy - wy * new
    self:layoutMap()
    self:clampPan()
    self:refresh()
end

function MindmapView:onPinch(_, ges)
    self:zoomAt(ges and ges.pos, 1 - math.min(0.35, (ges and ges.distance or 0) / 700))
    return true
end

function MindmapView:onSpread(_, ges)
    self:zoomAt(ges and ges.pos, 1 + math.min(0.5, (ges and ges.distance or 0) / 500))
    return true
end

function MindmapView:centerSelected()
    local entry = self:selectedEntry()
    if not entry then return end
    local n = entry.node
    local vw, vh = self.fw - MINDMAP_PAD * 2, self.fh - self.canvas_y - MINDMAP_PAD
    self.pan_x = vw / 2 - (n.mx + n.mw / 2) * self.zoom
    self.pan_y = vh / 2 - (n.my + MINDMAP_NODE_H / 2) * self.zoom
    self:clampPan()
end

function MindmapView:onKeyPress(key)
    local name = key and key.key
    if not name then return true end
    local mods = key_mods(key)
    if self.editing_index then
        if name == "Backspace" or name == "BackSpace" then self:delChar()
        elseif name == "Left" then self:leftChar()
        elseif name == "Right" then self:rightChar()
        elseif name == "Home" then self:goToStartOfLine()
        elseif name == "End" then self:goToEndOfLine()
        elseif name == "Press" or name == "Return" or name == "Enter" then self:commitNodeEdit()
        elseif name == "Back" or name == "Esc" or name == "Escape" then self:cancelNodeEdit()
        elseif not shortcut_mod(mods) and #tostring(name) == 1 then self:addChars(name) end
        return true
    end
    if up_key(name) then
        self.selected = math.max(1, (self.selected or 1) - 1); self:centerSelected(); self:refresh()
    elseif down_key(name) then
        self.selected = math.min(#self.rows, (self.selected or 1) + 1); self:centerSelected(); self:refresh()
    elseif left_key(name) then self:reattach(-1)
    elseif right_key(name) then self:reattach(1)
    elseif page_up_key(name) then self:zoomAt(nil, 0.8)
    elseif page_down_key(name) or name == "Space" or name == "space" or name == " " then self:zoomAt(nil, 1.25)
    elseif name == "+" or name == "=" then self:zoomAt(nil, 1.25)
    elseif name == "-" then self:zoomAt(nil, 0.8)
    elseif tostring(name):lower() == "a" then self:addChild()
    elseif name == "Backspace" or name == "BackSpace" or name == "Del" or name == "Delete" then self:deleteSelected()
    elseif shortcut_mod(mods) and tostring(name):lower() == "z" then self:undo()
    elseif name == "Press" or name == "Return" or name == "Enter" or name == "KP_Enter" then
        local entry = self:selectedEntry()
        self:jumpTo(entry and entry.node.line)
    elseif name == "Back" or name == "Esc" or name == "Escape" then self:close() end
    return true
end

function MindmapView:onScreenResize()
    self.fw, self.fh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh }
    if self.ges_events then
        for _, ev in pairs(self.ges_events) do
            for _, range in ipairs(ev) do range.range = self.dimen end
        end
    end
    self.canvas_y = MINDMAP_TOPBAR_H + MINDMAP_TOPBAR_TOP_PAD + MINDMAP_TOPBAR_GAP
    self:refresh()
    return true
end

-- A remote session is deliberately dormant until the desktop explicitly writes
-- a descriptor and launches `remote:`. There is no discovery loop or background
-- connection merely because Minfolio is open.
MinfolioRemote = {}
function MinfolioRemote.socket(cfg, timeout)
    local sock, err = socket.tcp()
    if not sock then return nil, err end
    sock:settimeout(timeout or 1)
    local ok, cerr = sock:connect(cfg.host, cfg.port)
    if not ok then pcall(function() sock:close() end); return nil, cerr end
    local ok_ssl, ssl = pcall(require, "ssl")
    if not ok_ssl then pcall(function() sock:close() end); return nil, "LuaSec missing" end
    local wrapped, werr = ssl.wrap(sock, { mode = "client", protocol = "any", verify = "none", options = "all" })
    if not wrapped then pcall(function() sock:close() end); return nil, werr end
    wrapped:settimeout(timeout or 1)
    while true do
        local hs_ok, hs_err = wrapped:dohandshake()
        if hs_ok then break end
        if hs_err ~= "wantread" and hs_err ~= "wantwrite" then pcall(function() wrapped:close() end); return nil, hs_err end
    end
    local cert = wrapped:getpeercertificate()
    local fpr = cert and cert:digest("sha256"):lower():gsub(":", "") or nil
    if not fpr or fpr ~= tostring(cfg.cert_fingerprint or ""):lower():gsub(":", "") then
        pcall(function() wrapped:close() end); return nil, "desktop certificate pin mismatch"
    end
    return wrapped
end

function MinfolioRemote.sendAll(sock, data)
    local pos = 1
    while pos <= #data do
        local sent, err = sock:send(data, pos)
        if not sent then return false, err end
        pos = sent + 1
    end
    return true
end

local MDEdit = InputContainer:extend{ path = nil, remote = nil, on_close = nil, is_always_active = true }
function MDEdit:init()
    install_keyboard_aliases()
    self.fw, self.fh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh }
    self.covers_fullscreen = true
    self.scale = clamp_minfolio_scale(MINFOLIO_STATE.scale)
    self.parent = self            -- VirtualKeyboard reads inputbox.parent
    self.keyboard = nil
    self._wcache = {}             -- measured word widths (style|scale|text -> px)
    self._hcache = {}             -- measured text heights (style|scale -> px)
    self.sel = nil                -- selection anchor {row,col} (cursor is the other end)
    self.caret_on = true
    self._caret_blinking = true
    self.reader_mode = false
    local text = read_file(self.path) or ""
    self.lines = split_text_lines(text)
    -- The editor never owns a socket. A separate process does TLS and leaves
    -- only local, atomically-written files for this widget to consume.
    self.remote_revision = self.remote and tonumber(self.remote.revision) or 0
    self._file_signature = file_signature(self.path)
    self._file_text = text
    self.crow, self.ccol, self.top, self.vtop = 1, 0, 1, 1
    self:restorePosition()
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap       = { GestureRange:new{ ges = "tap",        range = self.dimen } },
            DoubleTap = { GestureRange:new{ ges = "double_tap", range = self.dimen } },
            Pan       = { GestureRange:new{ ges = "pan",        range = self.dimen } },
            PanRelease= { GestureRange:new{ ges = "pan_release", range = self.dimen } },
            Swipe     = { GestureRange:new{ ges = "swipe",      range = self.dimen } },
            Hold      = { GestureRange:new{ ges = "hold",       range = self.dimen } },
        }
        if Device.input then
            -- Disable KOReader's own double-tap so taps arrive immediately; we
            -- detect double-taps ourselves (edit: word-select, reader: exit) via
            -- timestamps, which is reliable and gives us the tap position.
            self._old_disable_double_tap = Device.input.disable_double_tap
            Device.input.disable_double_tap = true
        end
    end
    self:rebuild()
    -- A first full draw is still settling when this widget is opened from the
    -- file browser.  Do not let the caret's tiny partial redraw race it: on an
    -- e-ink screen that can preserve a blank patch from the browser instead of
    -- the newly-built editor beneath it.
    self:scheduleCaretBlink(MDEDIT_CARET_RESUME_DELAY)
    self:scheduleFilePoll()
    MinfolioPair.trace("editor-open", "path=", tostring(self.path), "lines=", #self.lines,
        "remote=", self.remote and "yes" or "no")
    self:scheduleHeartbeat(10)
end
-- Store a logical visual-row anchor, not a raw visual row number. This lets a
-- note reopen at the same passage after a rotation or a font-size change has
-- changed how many screen rows the preceding text occupies.
function MDEdit:restorePosition()
    if self.remote then return end -- remote documents are short-lived session shadows
    local position = MINFOLIO_STATE.positions[self.path]
    if type(position) ~= "table" then return end

    self.crow = math.max(1, math.min(#self.lines, math.floor(tonumber(position.crow) or 1)))
    self.ccol = math.max(0, math.min(#(self.lines[self.crow] or ""), math.floor(tonumber(position.ccol) or 0)))
    self.reader_mode = not not position.reader_mode

    local target_line = math.max(1, math.floor(tonumber(position.line) or self.crow))
    local target_ri = math.max(1, math.floor(tonumber(position.ri) or 1))
    local target_kind = type(position.kind) == "string" and position.kind or nil
    local rows = self:visualRows(self:textWidth())
    for vi, row in ipairs(rows) do
        if row.line == target_line and (not target_kind or row.kind == target_kind)
            and (row.ri or 1) >= target_ri then
            self.vtop = vi
            break
        end
    end
    -- In edit mode, rebuilding normally scrolls to the caret. Mark this as a
    -- deliberate restored scroll position so the saved passage takes priority.
    if not self.reader_mode then
        self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    end
end
function MDEdit:savePosition()
    if self.remote then return end
    local rows = self:visualRows(self:textWidth())
    local top = rows[math.max(1, math.min(#rows, self.vtop or 1))] or {}
    MINFOLIO_STATE.positions[self.path] = {
        line = top.line or self.crow or 1,
        ri = top.ri or 1,
        kind = top.kind or "row",
        crow = self.crow or 1,
        ccol = self.ccol or 0,
        reader_mode = self.reader_mode,
    }
    save_minfolio_state()
end
-- a thin caret bar that sits between styled spans without disturbing them
function MDEdit:caret(h)
    return LineWidget:new{ background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = 3, h = h or math.floor(32 * self.scale) } }
end
function MDEdit:scheduleCaretBlink(delay)
    if self._caret_blink_pending then
        UIManager:unschedule(self._caret_blink_pending)
        self._caret_blink_pending = nil
    end
    local fn
    fn = function()
        if self._caret_blink_pending == fn then self._caret_blink_pending = nil end
        if not self._caret_blinking then return end
        if self.reader_mode then
            self.caret_on = false
            self:scheduleCaretBlink()
            return
        end
        local prev_vtop = self.vtop
        local prev_caret = self.caret_region
        self.caret_on = not self.caret_on
        self:rebuild()
        local region
        if prev_vtop and self.vtop and prev_vtop ~= self.vtop then
            region = self.editor_body_region
        else
            region = self:unionRegion(prev_caret, self.caret_region)
        end
        local dirty_full = false
        if self._last_dirty_at and now_seconds() - self._last_dirty_at < MDEDIT_CARET_BLINK then
            if self._last_dirty_full then
                dirty_full = true
                region = nil
            else
                region = self:unionRegion(self._last_dirty_region, region)
            end
        end
        if dirty_full or region then UIManager:setDirty(self, "ui", region) end
        self:scheduleCaretBlink()
    end
    self._caret_blink_pending = fn
    UIManager:scheduleIn(delay or MDEDIT_CARET_BLINK, fn)
end
-- Keep a solid caret throughout an input burst. Besides being easier to follow,
-- this prevents the blink timer from doing a second full widget rebuild while a
-- typing repaint is already in flight. Each key resets the idle countdown; the
-- first post-input blink happens only after the burst has settled.
function MDEdit:pauseCaretBlinkForInput()
    if not self._caret_blinking or self.reader_mode then return end
    self.caret_on = true
    self:scheduleCaretBlink(MDEDIT_CARET_RESUME_DELAY)
end
function MDEdit:textw(txt, face)        -- measured rendered width of a string
    if txt == "" then return 0 end
    local tw = TextWidget:new{ text = txt, face = face }
    local w = tw:getSize().w; tw:free(); return w
end
function MDEdit:texth(style)
    local key = style .. "|" .. self.scale
    local c = self._hcache[key]
    if c then return c end
    local tw = TextWidget:new{ text = "Hg", face = md_face(style, self.scale) }
    local h = tw:getSize().h; tw:free()
    self._hcache[key] = h; return h
end
function MDEdit:wordw(txt, style)        -- cached measured width (keyed by style + scale)
    if txt == "" then return 0 end
    local key = style .. "|" .. self.scale .. "|" .. txt
    local c = self._wcache[key]
    if c then return c end
    local w = self:textw(txt, md_face(style, self.scale))
    self._wcache[key] = w; return w
end
function MDEdit:rowTextHeight(row)
    if not row.segs or #row.segs == 0 then return self:texth("normal") end
    local h = 0
    for _, seg in ipairs(row.segs) do h = math.max(h, self:texth(seg.style)) end
    return math.max(1, h)
end
function MDEdit:rowHeight(row, block)
    local measured = self:rowTextHeight(row)
    return math.max(1, math.ceil(measured * MDEDIT_LINE_HEIGHT)) + math.max(0, math.floor(MDEDIT_LINE_GAP * self.scale))
end
function MDEdit:trimToWidth(text, maxw, face)
    if self:textw(text, face) <= maxw then return text end
    local ell = "..."
    local lo, hi, best = 0, #text, ell
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local s = text:sub(1, mid) .. ell
        if self:textw(s, face) <= maxw then best = s; lo = mid + 1 else hi = mid - 1 end
    end
    return best
end
function MDEdit:toolCell(lbl, fnt, sz, w)
    w = w or MDEDIT_TOOL_MIN_CELL
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = MDEDIT_TOPBAR_H },
            TextWidget:new{ text = lbl, face = Font:getFace(fnt or "tfont", sz or 24), fgcolor = Blitbuffer.COLOR_BLACK } } }
end
function MDEdit:toolDivider()
    return CenterContainer:new{ dimen = Geom:new{ w = MDEDIT_TOOL_DIVIDER, h = MDEDIT_TOPBAR_H },
        LineWidget:new{ background = Blitbuffer.Color8(205), dimen = Geom:new{ w = MDEDIT_TOOL_DIVIDER, h = math.floor(MDEDIT_TOPBAR_H * 0.62) } } }
end
function MDEdit:progressBar(width)
    local visual_count = self.visual_count or #self.lines
    local visible = self.visible_vrows or 16
    local w = math.max(1, width or 1)
    local filled = w
    if visual_count > visible then
        local bottom = math.min(visual_count, (self.vtop or 1) + visible - 1)
        filled = math.max(1, math.min(w, math.floor(w * bottom / visual_count)))
    end
    local parts = { align = "top" }
    if filled > 0 then
        parts[#parts+1] = LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = filled, h = MDEDIT_PROGRESS_H },
        }
    end
    if filled < w then
        parts[#parts+1] = LineWidget:new{
            background = Blitbuffer.Color8(205),
            dimen = Geom:new{ w = w - filled, h = MDEDIT_PROGRESS_H },
        }
    end
    return HorizontalGroup:new(parts)
end
function MDEdit:menuGlyph()
    -- Same "appbar.menu" icon KOReader's own title bars use, so this matches
    -- the hamburger on the file-listing screen instead of a hand-drawn glyph.
    return CenterContainer:new{ dimen = Geom:new{ w = MDEDIT_MENU_W, h = MDEDIT_TOPBAR_H },
        IconWidget:new{ icon = "appbar.menu", width = Screen:scaleBySize(24), height = Screen:scaleBySize(24) } }
end
function MDEdit:buildTopBar(cw)
    local title_face = Font:getFace("cfont", 22)
    local raw_title = self.path:match("[^/]+$") or "note"
    self.top_zones = {}
    -- Find is a temporary mode: its compact controls replace the formatting
    -- toolbar, leaving a persistent query field and touch-sized navigation
    -- targets instead of obscuring the document with a dialog.
    if self._find_bar_visible then
        local action_face = Font:getFace("tfont", 21)
        local prev_w = math.max(MDEDIT_TOOL_MIN_CELL, self:textw("Previous", action_face) + 18)
        local next_w = math.max(MDEDIT_TOOL_MIN_CELL, self:textw("Next", action_face) + 18)
        local done_w = math.max(MDEDIT_TOOL_MIN_CELL, self:textw("Done", action_face) + 18)
        local query_w = math.max(80, cw - prev_w - next_w - done_w)
        local query = self:trimToWidth((self._find_query and self._find_query ~= "")
            and ("Find: " .. self._find_query) or "Find: enter text", query_w - 16, title_face)
        local x = 0
        self.top_zones.find_input = { x0 = x, x1 = x + query_w }; x = x + query_w
        self.top_zones.find_previous = { x0 = x, x1 = x + prev_w }; x = x + prev_w
        self.top_zones.find_next = { x0 = x, x1 = x + next_w }; x = x + next_w
        self.top_zones.find_done = { x0 = x, x1 = x + done_w }
        return HorizontalGroup:new{ align = "center",
            FrameContainer:new{ bordersize = 1, padding = 5, margin = 0, width = query_w, height = MDEDIT_TOPBAR_H,
                CenterContainer:new{ dimen = Geom:new{ w = query_w - 12, h = MDEDIT_TOPBAR_H - 2 },
                    TextWidget:new{ text = query, face = title_face, fgcolor = Blitbuffer.COLOR_BLACK } } },
            self:toolCell("Previous", "tfont", 21, prev_w),
            self:toolCell("Next", "tfont", 21, next_w),
            self:toolCell("Done", "tfont", 21, done_w),
        }
    end
    if self.reader_mode then
        -- Reader mode: no formatting toolbar. A single explicit "Edit" button so
        -- the reader never has to guess the double-tap gesture.
        local edit_face = Font:getFace("tfont", 24)
        local edit_w = math.max(MDEDIT_TOOL_MIN_CELL, self:textw("Edit", edit_face) + 28)
        local max_title_w = math.max(80, cw - MDEDIT_MENU_W - edit_w - MDEDIT_TITLE_ACTION_GAP)
        local title = self:trimToWidth(raw_title, max_title_w, title_face)
        local title_w = self:textw(title, title_face)
        local gap_w = math.max(MDEDIT_TITLE_ACTION_GAP, cw - MDEDIT_MENU_W - title_w - edit_w)
        local x = MDEDIT_MENU_W
        self.top_zones.menu = { x0 = 0, x1 = MDEDIT_MENU_W }
        x = x + title_w + gap_w
        self.top_zones.edit = { x0 = x, x1 = x + edit_w }
        return HorizontalGroup:new{ align = "center",
            self:menuGlyph(),
            CenterContainer:new{ dimen = Geom:new{ w = title_w, h = MDEDIT_TOPBAR_H },
                TextWidget:new{ text = title, face = title_face, fgcolor = Blitbuffer.Color8(110) } },
            HorizontalSpan:new{ width = gap_w },
            CenterContainer:new{ dimen = Geom:new{ w = edit_w, h = MDEDIT_TOPBAR_H },
                TextWidget:new{ text = "Edit", face = edit_face, fgcolor = Blitbuffer.COLOR_BLACK } },
        }
    end
    -- Reader glyph is a rectangle split into two columns (◫, vertical bisecting
    -- line) so it reads as a two-column page rather than many thin bars.
    local tools = { "H", "B", "I", "\226\128\162", "1.", "\226\152\144", "\226\151\171" }
    local divider_w = #tools * MDEDIT_TOOL_DIVIDER
    local min_action_w = ((#tools + 1) * MDEDIT_TOOL_MIN_CELL) + divider_w
    local max_title_w = math.min(MDEDIT_TITLE_W, math.max(80, cw - MDEDIT_MENU_W - min_action_w - MDEDIT_TITLE_ACTION_GAP))
    local title = self:trimToWidth(raw_title, max_title_w, title_face)
    local title_w = self:textw(title, title_face)
    local gap_w = math.min(MDEDIT_TITLE_ACTION_GAP, math.max(0, cw - MDEDIT_MENU_W - title_w - min_action_w))
    local action_w = math.max(min_action_w, cw - MDEDIT_MENU_W - title_w - gap_w)
    local tool_cell_w = math.max(MDEDIT_TOOL_MIN_CELL, math.floor((action_w - divider_w) / (#tools + 1)))
    action_w = tool_cell_w * (#tools + 1) + divider_w
    local x = MDEDIT_MENU_W
    self.top_zones.menu = { x0 = 0, x1 = MDEDIT_MENU_W }
    local title_widget = CenterContainer:new{ dimen = Geom:new{ w = title_w, h = MDEDIT_TOPBAR_H },
        TextWidget:new{ text = title, face = title_face, fgcolor = Blitbuffer.Color8(110) } }
    x = x + title_w + gap_w
    local tool_widgets = {}
    local tool_names = { "header", "bold", "italic", "list", "ordered", "task", "reader" }
    for i, lbl in ipairs(tools) do
        if i > 1 then
            tool_widgets[#tool_widgets+1] = self:toolDivider()
            x = x + MDEDIT_TOOL_DIVIDER
        end
        self.top_zones[tool_names[i]] = { x0 = x, x1 = x + tool_cell_w }
        local glyph_tool = i == 6 or i == 8   -- checkbox + reader glyphs render from cfont
        tool_widgets[#tool_widgets+1] = self:toolCell(lbl, glyph_tool and "cfont" or "tfont", glyph_tool and 24 or 23, tool_cell_w)
        x = x + tool_cell_w
    end
    x = x + MDEDIT_TOOL_DIVIDER
    self.top_zones.close = { x0 = x, x1 = x + tool_cell_w }
    return HorizontalGroup:new{ align = "center",
        self:menuGlyph(),
        title_widget,
        HorizontalSpan:new{ width = gap_w },
        HorizontalGroup:new(tool_widgets),
        self:toolDivider(),
        self:toolCell("\226\156\149", "cfont", 30, tool_cell_w),
    }
end
-- The toolbar/title subtree is static during typing, yet rebuilding it shapes the
-- same title and eight tool glyphs again for every input flush and caret blink.
-- Reuse it until width or mode changes; keep the matching hit zones with it.
function MDEdit:topBar(cw)
    -- Tag the find component rather than storing the bare query: an empty query
    -- is a real find-bar state ("Find: enter text"), and it must not collide
    -- with the no-find-bar key or the cache serves the wrong bar and hit zones.
    local key = table.concat({ tostring(cw), self.reader_mode and "reader" or "edit",
        self._find_bar_visible and ("find:" .. (self._find_query or "")) or "nofind" }, "|")
    local cached = self._topbar_cache
    if cached and cached.key == key then
        self.top_zones = cached.zones
        return cached.widget
    end
    local widget = self:buildTopBar(cw)
    self._topbar_cache = { key = key, widget = widget, zones = self.top_zones }
    return widget
end
function MDEdit:pointToCursor(pos)
    if not pos then return self.crow, self.ccol end
    local nearest, nearest_dist
    for _, rm in ipairs(self.row_map or {}) do
        if pos.y >= rm.y0 and pos.y < rm.y1 then
            local raw_col
            if rm.table then raw_col = self:tableColAtX(rm, pos.x - MDEDIT_PAD)
            else raw_col = self:colAtX(rm.row, pos.x - MDEDIT_PAD) end
            local col = utf8_snap(self.lines[rm.line], raw_col)
            return rm.line, col
        end
        local dist = pos.y < rm.y0 and (rm.y0 - pos.y) or (pos.y - rm.y1)
        if not nearest_dist or dist < nearest_dist then
            nearest, nearest_dist = rm, dist
        end
    end
    if nearest then
        local raw_col
        if nearest.table then raw_col = self:tableColAtX(nearest, pos.x - MDEDIT_PAD)
        else raw_col = self:colAtX(nearest.row, pos.x - MDEDIT_PAD) end
        return nearest.line, utf8_snap(self.lines[nearest.line], raw_col)
    end
    if pos.y < (self.row_map and self.row_map[1] and self.row_map[1].y0 or self.fh) then
        return self.row_map and self.row_map[1] and self.row_map[1].line or self.top, 0
    end
    local last = self.row_map and self.row_map[#self.row_map]
    if last then return last.line, #self.lines[last.line] end
    return self.crow, self.ccol
end
function MDEdit:visibleWordRange(row, col)
    local line = self.lines[row] or ""
    local toks = md_tokenize(line)[1]
    local byte, target, prev_visible = 0, nil, nil
    for _, span in ipairs(toks.spans or {}) do
        local raw = span.text or ""
        local display = span.display
        if display == nil then display = raw end
        local start_col, end_col = byte, byte + #raw
        if display ~= "" and span.style ~= "syntax" and span.style ~= "bullet" and span.style ~= "task" then
            local candidate = { start_col, end_col, raw }
            if col >= start_col and col <= end_col then
                target = candidate
                break
            elseif col < start_col then
                target = candidate
                break
            end
            prev_visible = candidate
        end
        byte = end_col
    end
    target = target or prev_visible
    if not target then return nil end
    local start_col, end_col, raw = target[1], target[2], target[3]
    local local_col = math.max(0, math.min(#raw, col - start_col))
    local lo, hi = prev_word_col(raw, local_col), next_word_col(raw, local_col)
    if lo == hi and #raw > 0 then
        if local_col <= 0 then hi = next_word_col(raw, 0)
        else lo = prev_word_col(raw, utf8_left(raw, local_col)) end
    end
    if lo == hi then return start_col, end_col end
    return start_col + lo, start_col + hi
end
function MDEdit:selectWordAt(pos)
    local row, col = self:pointToCursor(pos)
    local line = self.lines[row] or ""
    local lo, hi = self:visibleWordRange(row, col)
    if not lo then lo, hi = prev_word_col(line, col), next_word_col(line, col) end
    if lo == hi and #line > 0 then hi = utf8_right(line, lo) end
    self._desired_x = nil
    self.sel = { row = row, col = lo }
    self.crow, self.ccol = row, hi
    self:refresh{ layout_dirty = false, selection = true }
end
function MDEdit:currentWordRange()
    local line = self.lines[self.crow] or ""
    if line == "" then return nil end
    local lo, hi = prev_word_col(line, self.ccol), next_word_col(line, self.ccol)
    if lo == hi and self.ccol > 0 then lo = prev_word_col(line, utf8_left(line, self.ccol)) end
    if lo == hi and self.ccol < #line then hi = next_word_col(line, utf8_right(line, self.ccol)) end
    if lo ~= hi then return lo, hi end
    return nil
end
-- word-wrap a logical line into visual rows that fit availw; each row/seg tracks its start byte
function MDEdit:layoutLine(toks, availw)
    local rows, byte = {}, 0
    local hanging = 0
    local base_indent = 0
    if toks.block == "bullet" then
        -- Nesting depth: leading whitespace becomes real horizontal indent (the
        -- marker glyph itself carries no indent). Continuation rows hang under the
        -- text, so they start at base_indent + marker width.
        if toks.indent_ws and toks.indent_ws ~= "" then
            base_indent = self:wordw(toks.indent_ws, "bullet")
        end
        hanging = base_indent
        for _, span in ipairs(toks.spans) do
            local raw = span.text or ""
            local display = span.display
            if display == nil or display == raw then break end
            if display ~= "" then hanging = hanging + self:wordw(display, span.style) end
        end
    end
    local function newRow(indent, sb)
        indent = indent or 0
        return { segs = {}, w = indent, sb = sb or 0, indent = indent }
    end
    local row = newRow(base_indent, 0)
    for _, span in ipairs(toks.spans) do
        local raw = span.text or ""
        local display = span.display
        if display == nil then display = raw end
        if display ~= raw then
            local uw = display ~= "" and self:wordw(display, span.style) or 0
            row.segs[#row.segs+1] = { text = raw, display = display, style = span.style, hl = span.hl, w = uw, sb = byte }
            row.w = row.w + uw; byte = byte + #raw
        else
            local pos = 1
            while pos <= #raw do
                local unit = raw:match("^%s+", pos) or raw:match("^%S+", pos) or raw:sub(pos)
                local uw = self:wordw(unit, span.style)
                if not unit:match("^%s") and #row.segs > 0 and row.w + uw > availw then
                    rows[#rows+1] = row; row = newRow(hanging, byte)
                end
                row.segs[#row.segs+1] = { text = unit, display = unit, style = span.style, hl = span.hl, w = uw, sb = byte }
                row.w = row.w + uw; byte = byte + #unit; pos = pos + #unit
            end
        end
    end
    rows[#rows+1] = row
    return rows
end
-- Rendering a row shapes glyphs into TextWidgets, which hold native (malloc'ed)
-- buffers that only :free() releases promptly -- Lua's GC won't get to them in
-- time. rebuild() re-renders every visible row on every scroll/cursor-move/caret
-- blink, so without this cache we'd shape fresh glyphs (and leak the old ones)
-- many times a second. A row's identity is stable across those redraws (see the
-- wrap cache in computeVisualRows below); only its own text or a scale change
-- actually needs a re-render.
function MDEdit:renderRow(row)
    if #row.segs == 0 then return VerticalSpan:new{ width = 2 } end
    if row._rendered and row._rendered_scale == self.scale then return row._rendered end
    if row._rendered then row._rendered:free() end
    local hg = HorizontalGroup:new{ align = "top" }
    if row.indent and row.indent > 0 then hg[#hg+1] = HorizontalSpan:new{ width = row.indent } end
    for _, seg in ipairs(row.segs) do
        local display = seg.display
        if display == nil then display = seg.text end
        if display ~= "" then
            hg[#hg+1] = TextWidget:new{ text = display,
                face = md_face(seg.style, self.scale), fgcolor = md_color(seg.style) }
        end
    end
    row._rendered, row._rendered_scale = hg, self.scale
    return hg
end
function MDEdit:tableInlineSpans(text, base_style)
    local spans = {}
    for _, span in ipairs(md_inline(tostring(text or ""))) do
        if span.style ~= "syntax" then
            local style = span.style == "normal" and base_style or span.style
            local display = span.display == nil and span.text or span.display
            if display ~= "" then
                spans[#spans+1] = { text = display, display = display, style = style, hl = span.hl }
            end
        end
    end
    return spans
end
function MDEdit:tableInlineWidth(text, base_style)
    local width = 0
    for _, span in ipairs(self:tableInlineSpans(text, base_style)) do
        width = width + self:wordw(span.display or span.text or "", span.style)
    end
    return width
end
-- Inline-aware greedy wrapping for table cells. Markdown markers have already
-- been removed by tableInlineSpans, while each visible run retains its face and
-- highlight flag. Over-long words are still hard-broken on UTF-8 boundaries.
function MDEdit:wrapTableCell(text, base_style, maxw)
    local rows = {}
    local function new_row() return { segs = {}, w = 0, sb = 0, indent = 0 } end
    local row = new_row()
    local function finish_row()
        rows[#rows+1] = row
        row = new_row()
    end
    local function append(piece, style, hl)
        if piece == "" then return end
        local width = self:wordw(piece, style)
        row.segs[#row.segs+1] = { text = piece, display = piece, style = style, hl = hl, w = width }
        row.w = row.w + width
    end
    for _, span in ipairs(self:tableInlineSpans(text, base_style)) do
        local raw, pos = span.display or span.text or "", 1
        while pos <= #raw do
            local unit = raw:match("^%s+", pos) or raw:match("^%S+", pos) or raw:sub(pos)
            local width = self:wordw(unit, span.style)
            if not unit:match("^%s") and #row.segs > 0 and row.w + width > maxw then finish_row() end
            if not unit:match("^%s") and width > maxw then
                local rest = unit
                while rest ~= "" do
                    local i, piece = 0, ""
                    while true do
                        local nxt = utf8_right(rest, i)
                        if nxt == i then break end
                        local candidate = rest:sub(1, nxt)
                        if self:wordw(candidate, span.style) <= maxw then piece, i = candidate, nxt else break end
                    end
                    if piece == "" then piece = rest:sub(1, math.max(1, utf8_right(rest, 0))) end
                    append(piece, span.style, span.hl)
                    rest = rest:sub(#piece + 1)
                    if rest ~= "" then finish_row() end
                end
            else
                append(unit, span.style, span.hl)
            end
            pos = pos + #unit
        end
    end
    if #row.segs > 0 or #rows == 0 then rows[#rows+1] = row end
    return rows
end
function MDEdit:layoutTable(tbl, availw)
    local pad_x = math.floor(MDEDIT_TABLE_PAD_X * self.scale)
    local pad_x2 = 2 * pad_x
    local minw = math.max(34, math.floor(42 * self.scale))
    -- Natural single-line width each column would like, so short columns can stay
    -- compact while long ones absorb the wrapping.
    local nat = {}
    for c = 1, tbl.ncols do nat[c] = minw end
    for _, tr in ipairs(tbl.rows) do
        local style = tr.header and "bold" or "normal"
        for c = 1, tbl.ncols do
            local cell = tr.cells[c]
            -- Reserve padding + the cell's 1px left/right borders (the same 2px the
            -- wrap width subtracts below) + a little rounding slack, so a column
            -- sized to its own text never wraps that text mid-word.
            nat[c] = math.max(nat[c], self:tableInlineWidth(cell and cell.text or "", style) + pad_x2 + 4)
        end
    end
    local natsum = 0
    for c = 1, tbl.ncols do natsum = natsum + nat[c] end
    local widths = {}
    if natsum <= availw then
        for c = 1, tbl.ncols do widths[c] = nat[c] end
    else
        -- Water-filling: columns narrower than an even share keep their natural
        -- width; the remaining space is split evenly among the wide columns, which
        -- then wrap. Repeats until the wide set is stable.
        local remaining, count, avail = {}, tbl.ncols, availw
        for c = 1, tbl.ncols do remaining[c] = true end
        while true do
            local share = math.floor(avail / math.max(1, count))
            local changed = false
            for c = 1, tbl.ncols do
                if remaining[c] and nat[c] <= share then
                    widths[c] = nat[c]; remaining[c] = false
                    avail = avail - nat[c]; count = count - 1; changed = true
                end
            end
            if not changed or count == 0 then break end
        end
        if count > 0 then
            local share = math.max(minw, math.floor(avail / count))
            for c = 1, tbl.ncols do if remaining[c] then widths[c] = share end end
        end
    end
    local total = 0
    for c = 1, tbl.ncols do widths[c] = math.max(minw, widths[c]); total = total + widths[c] end

    local pad_y = math.floor(MDEDIT_TABLE_PAD_Y * self.scale)
    local entries = {}
    for ri, tr in ipairs(tbl.rows) do
        local style = tr.header and "bold" or "normal"
        local wrapped, content_h = {}, 0
        for c = 1, tbl.ncols do
            local cell = tr.cells[c]
            local inner = math.max(1, widths[c] - pad_x2 - 2)
            local wl = self:wrapTableCell(cell and cell.text or "", style, inner)
            wrapped[c] = wl
            local cell_h = 0
            for _, line in ipairs(wl) do cell_h = cell_h + self:rowTextHeight(line) end
            content_h = math.max(content_h, cell_h)
        end
        local rowh = math.max(24, content_h + 2 * pad_y + 2)
        entries[#entries+1] = {
            kind = "table_row",
            line = tr.line,
            table = tbl,
            cells = tr.cells,
            header = tr.header,
            ri = ri,
            h = rowh,
            w = total,
            col_widths = widths,
            aligns = tbl.aligns,
            wrapped = wrapped,
        }
    end
    return entries
end
function MDEdit:tableCell(lines, colw, rowh, align)
    local pad_x = math.floor(MDEDIT_TABLE_PAD_X * self.scale)
    local border = 1
    -- FrameContainer:getSize() ignores its own `width`/`height` and measures its
    -- content, so passing width=colw does NOT make a cell occupy the column -- the
    -- row then packs cells at their text width and columns drift out of alignment.
    -- Wrap the content in a fixed-`dimen` LeftContainer so every cell in a column
    -- is exactly colw x rowh and the columns line up across rows.
    local inner_w = math.max(1, colw - 2 * border)
    local inner_h = math.max(1, rowh - 2 * border)
    local vg = VerticalGroup:new{ align = "left" }
    for _, line in ipairs(lines or {}) do
        local lineh = self:rowTextHeight(line)
        local tw = line.w or 0
        local left = pad_x
        if align == "right" then left = math.max(pad_x, inner_w - pad_x - tw)
        elseif align == "center" then left = math.max(pad_x, math.floor((inner_w - tw) / 2)) end
        local layers = { dimen = Geom:new{ w = math.max(1, tw), h = lineh } }
        local hx, hstart = 0, nil
        local function flush_highlight(xend)
            if hstart and xend > hstart then
                layers[#layers+1] = HorizontalGroup:new{ align = "top",
                    HorizontalSpan:new{ width = hstart },
                    LineWidget:new{ background = MDEDIT_HIGHLIGHT_GRAY,
                        dimen = Geom:new{ w = math.max(2, xend - hstart), h = lineh } },
                }
            end
            hstart = nil
        end
        for _, seg in ipairs(line.segs or {}) do
            if seg.hl then
                if (seg.w or 0) > 0 and not hstart then hstart = hx end
            else
                flush_highlight(hx)
            end
            hx = hx + (seg.w or 0)
        end
        flush_highlight(hx)
        layers[#layers+1] = self:renderRow(line)
        vg[#vg+1] = HorizontalGroup:new{
            HorizontalSpan:new{ width = left }, OverlapGroup:new(layers),
        }
    end
    return FrameContainer:new{ bordersize = border, padding = 0, margin = 0,
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, vg } }
end
function MDEdit:renderTableRow(vr)
    local hg = HorizontalGroup:new{ align = "top" }
    for c = 1, #vr.col_widths do
        hg[#hg+1] = self:tableCell(vr.wrapped and vr.wrapped[c], vr.col_widths[c], vr.h, vr.aligns[c])
    end
    return hg
end
function MDEdit:tableColAtX(rm, x)
    if x < 0 then
        local first = rm.cells and rm.cells[1]
        return first and (first.start_col or 0) or 0
    end
    local hit = self:tableCellAtX(rm, x)
    if hit then
        local cell, w = hit.cell, hit.width
        local pad_x = math.floor(MDEDIT_TABLE_PAD_X * self.scale)
        local inner_x = math.max(0, math.min(w - (2 * pad_x), hit.inner_x))
        local span = math.max(0, (cell.end_col or 0) - (cell.start_col or 0))
        if span <= 0 then return cell.start_col or 0 end
        return math.floor((cell.start_col or 0) + (span * inner_x / math.max(1, w - (2 * pad_x))))
    end
    local last = rm.cells and rm.cells[#rm.cells]
    return last and (last.end_col or last.start_col or 0) or 0
end
function MDEdit:tableCellAtX(rm, x)
    if x < 0 then return nil end
    local acc = 0
    local widths = rm.col_widths or {}
    for c = 1, #widths do
        local w = widths[c]
        if x < acc + w then
            local cell = rm.cells and rm.cells[c]
            if not cell then return nil end
            local pad_x = math.floor(MDEDIT_TABLE_PAD_X * self.scale)
            return {
                line = rm.line,
                col = c,
                cell = cell,
                x0 = acc,
                x1 = acc + w,
                width = w,
                inner_x = x - acc - pad_x,
            }
        end
        acc = acc + w
    end
    return nil
end
function MDEdit:tableCellAtPos(pos)
    if not pos then return nil end
    for _, rm in ipairs(self.row_map or {}) do
        if rm.table and pos.y >= rm.y0 and pos.y < rm.y1 then
            return self:tableCellAtX(rm, pos.x - MDEDIT_PAD)
        end
    end
    return nil
end
function MDEdit:replaceTableCell(hit, value)
    if not hit or not hit.line or not hit.cell then return false end
    local line = self.lines[hit.line]
    if not line then return false end
    local cell = hit.cell
    local clean = tostring(value or ""):gsub("[\r\n]+", " "):gsub("|", "/")
    local before = line:sub(1, cell.start_col)
    local after = line:sub((cell.end_col or cell.start_col) + 1)
    self.lines[hit.line] = before .. clean .. after
    self.crow = hit.line
    self.ccol = #before + #clean
    self._vrows_dirty = true
    return true
end
function MDEdit:openTableCellEditor(hit)
    if not hit or not hit.cell then return false end
    self:flushTypeBuffer()
    if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
    self._rtap = nil
    -- The editor's own non-modal keyboard targets MDEdit directly. Leaving it on
    -- the stack under an InputDialog makes its keys continue editing the document,
    -- even though the table-cell field is visibly on top.
    if self.keyboard then self:hideKeyboard() end
    local dlg
    local restored = false
    local function restore_editor_focus()
        if restored then return false end
        restored = true
        self._table_cell_dialog = nil
        self.is_always_active = true
        return true
    end
    -- The dialog and its on-screen keyboard cover a large slice of the screen;
    -- closing them only repaints that dialog region, leaving the editor beneath
    -- half-blank. Force a full editor repaint on either exit.
    local function dismiss(layout_dirty)
        restore_editor_focus()
        UIManager:close(dlg)
        self:refresh{ layout_dirty = layout_dirty and true or false, full = true }
    end
    dlg = InputDialog:new{
        title = string.format(_("Table cell %d"), hit.col or 1),
        input = hit.cell.text or "",
        buttons = {{
            { text = _("Cancel"), callback = function() dismiss(false) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = dlg:getInputText() or ""
                self:snapshot()
                self._burst = nil
                self:replaceTableCell(hit, value)
                self:save()
                dismiss(true)
            end },
        }},
    }
    local input = dlg._input_widget
    if input then
        local function input_prev_word_pos()
            local p = math.max(1, math.min(input.charpos or 1, #(input.charlist or {}) + 1))
            while p > 1 and char_is_space(input.charlist[p - 1] or "") do p = p - 1 end
            while p > 1 and not char_is_space(input.charlist[p - 1] or "") do p = p - 1 end
            return p
        end
        local function input_next_word_pos()
            local p = math.max(1, math.min(input.charpos or 1, #(input.charlist or {}) + 1))
            while p <= #(input.charlist or {}) and char_is_space(input.charlist[p] or "") do p = p + 1 end
            while p <= #(input.charlist or {}) and not char_is_space(input.charlist[p] or "") do p = p + 1 end
            return p
        end
        local function input_del_word_left()
            local p = input.charpos or 1
            local start = input_prev_word_pos()
            if start < p then input:delSelection(start, p - 1) else input:delChar() end
        end
        local original_on_key_press = input.onKeyPress
        function input:onKeyPress(key)
            local name = key and key.key
            local mods = key_mods(key)
            if name and word_key_mod(mods) and left_key(name) then
                self:moveCursorToCharPos(input_prev_word_pos())
                return true
            elseif name and word_key_mod(mods) and right_key(name) then
                self:moveCursorToCharPos(input_next_word_pos())
                return true
            elseif name and word_key_mod(mods)
                and (name == "Backspace" or name == "BackSpace" or name == "Del" or name == "Delete") then
                input_del_word_left()
                return true
            end
            return original_on_key_press(self, key)
        end
    end
    -- MDEdit is normally always active so external keyboards work reliably. A
    -- modal input field is the exception: suspend the document's key handler so
    -- physical keystrokes are delivered exclusively to InputDialog.
    self._table_cell_dialog = dlg
    self.is_always_active = false
    local editor, original_close = self, dlg.onCloseWidget
    function dlg:onCloseWidget()
        if original_close then original_close(self) end
        if restore_editor_focus() and editor._caret_blinking then
            editor:refresh{ layout_dirty = false, full = true }
        end
    end
    UIManager:show(dlg)
    dlg:onShowKeyboard()
    return true
end
function MDEdit:cursorInRows(rows)       -- (visual row index, x within row) for the cursor
    for ri = #rows, 1, -1 do
        if self.ccol >= rows[ri].sb then
            return ri, self:rowXAt(rows[ri], self.ccol)
        end
    end
    return 1, 0
end
function MDEdit:colAtX(row, x)           -- byte column nearest x within a visual row (for tap-to-place)
    local b, accx = row.sb, row.indent or 0
    if x < accx then return b end
    for _, seg in ipairs(row.segs) do
        if x < accx + seg.w then
            local display = seg.display
            if display == nil then display = seg.text end
            if display ~= seg.text then
                return b + ((x - accx) < (seg.w / 2) and 0 or #seg.text)
            end
            local prev = 0
            for ci = 1, #seg.text do
                local w = self:wordw(seg.text:sub(1, ci), seg.style)
                if accx + w >= x then
                    if (x - accx - prev) < (accx + w - x) then return b + ci - 1 else return b + ci end
                end
                prev = w
            end
            return b + #seg.text
        end
        accx = accx + seg.w; b = b + #seg.text
    end
    return b
end
-- Tokenize + word-wrap the whole document into visual rows. This is the
-- expensive step (md_tokenize + font-width measurement per line), so its
-- result is cached (see :visualRows) and only recomputed when the text or the
-- available width changes -- never on a plain scroll.
-- Releases the native TextWidget buffers (see renderRow) cached on a wrap-cache
-- entry's rows. Call this only for entries that are actually being dropped.
local function free_wrap_entry(entry)
    for _, row in ipairs(entry.rows) do
        if row._rendered then row._rendered:free(); row._rendered = nil end
    end
end
function MDEdit:computeVisualRows(text_w)
    -- Per-logical-line wrap cache keyed by the line's exact text. Editing one
    -- line is a single cache miss (the tokenize + word-wrap for that line);
    -- every other line is reused untouched, so a keystroke re-wraps one line
    -- instead of the whole document. The cache is rebuilt from the live lines
    -- each pass, so it can never grow past the current document.
    local prev = (self._wrap_cache_w == text_w) and self._wrap_cache or nil
    local old_cache = self._wrap_cache
    local cache, out = {}, {}
    local function appendLine(i)
        local text = self.lines[i]
        local entry = cache[text] or (prev and prev[text])
        if not entry then
            local toks = md_tokenize(text)[1]
            entry = { rows = self:layoutLine(toks, text_w), block = toks.block }
        end
        cache[text] = entry
        for ri, row in ipairs(entry.rows) do
            out[#out+1] = { kind = "row", line = i, row = row, block = entry.block, ri = ri }
        end
        if i < #self.lines then
            out[#out+1] = { kind = "gap", line = i, h = MDEDIT_PARA_GAP }
        end
    end
    local i = 1
    while i <= #self.lines do
        -- Tables render as tables in every mode (edit and reader). Cells are
        -- edited by tapping them (openTableCellEditor); the raw pipe syntax is
        -- never shown as plain text.
        local tbl = md_table_block(self.lines, i)
        if tbl then
            for _, entry in ipairs(self:layoutTable(tbl, text_w)) do
                out[#out+1] = entry
            end
            if tbl.finish < #self.lines then
                out[#out+1] = { kind = "gap", line = tbl.finish, h = MDEDIT_PARA_GAP }
            end
            i = tbl.finish + 1
        else
            appendLine(i)
            i = i + 1
        end
    end
    if old_cache then
        for text, entry in pairs(old_cache) do
            if cache[text] ~= entry then free_wrap_entry(entry) end
        end
    end
    self._wrap_cache, self._wrap_cache_w = cache, text_w
    if #out == 0 then out[1] = { kind = "row", line = 1, row = { segs = {}, w = 0, sb = 0 }, block = "normal", ri = 1 } end
    return out
end
-- Cached accessor: recompute only when the content is marked dirty (any edit
-- calls :refresh, which sets _vrows_dirty) or the text width changed (rotation).
function MDEdit:visualRows(text_w)
    if self._vrows and self._vrows_w == text_w and not self._vrows_dirty then
        return self._vrows
    end
    if self._vrows then
        local seen = {}
        for _, vr in ipairs(self._vrows) do
            local row = vr.row
            if row and row._rendered and not seen[row] then row._rendered:free(); row._rendered = nil; seen[row] = true end
        end
    end
    self._vrows = self:computeVisualRows(text_w)
    self._vrows_w = text_w
    self._vrows_dirty = false
    self:reindexVisualRows()
    return self._vrows
end
function MDEdit:reindexVisualRows()
    local ranges = {}
    for vi, vr in ipairs(self._vrows or {}) do
        if vr.kind == "row" and vr.line then
            local r = ranges[vr.line]
            if not r then ranges[vr.line] = { first = vi, last = vi }
            else r.last = vi end
        end
    end
    self._vrow_line_ranges = ranges
end
-- Fast path for ordinary single-line typing/backspace. It deliberately bails
-- out around tables and structural changes, where a full layout is safer.
function MDEdit:updateVisualLine(line)
    local vrows, text_w = self._vrows, self._vrows_w
    if not vrows or text_w ~= self:textWidth() or self._vrows_dirty then return false end
    local text = self.lines[line] or ""
    if text:find("|", 1, true) or ((self.lines[line - 1] or ""):find("|", 1, true))
        or ((self.lines[line + 1] or ""):find("|", 1, true)) then return false end
    local range = self._vrow_line_ranges and self._vrow_line_ranges[line]
    if not range then return false end
    for vi = range.first, range.last do
        if vrows[vi].kind ~= "row" then return false end
    end
    local toks = md_tokenize(text)[1]
    local replacement = {}
    for ri, row in ipairs(self:layoutLine(toks, text_w)) do
        replacement[#replacement+1] = { kind = "row", line = line, row = row, block = toks.block, ri = ri }
    end
    -- Release native glyph buffers for only the superseded rows. These rows are
    -- not stored in the content-keyed wrap cache on this incremental path.
    for vi = range.first, range.last do
        local row = vrows[vi].row
        if row and row._rendered then row._rendered:free(); row._rendered = nil end
    end
    local remove = range.last - range.first + 1
    for _ = 1, remove do table.remove(vrows, range.first) end
    for i = #replacement, 1, -1 do table.insert(vrows, range.first, replacement[i]) end
    self:reindexVisualRows()
    self._incremental_vrow_edits = (self._incremental_vrow_edits or 0) + 1
    -- Periodically rebuild the content-keyed cache, which bounds memory from
    -- unique words typed over a long session without taxing each keystroke.
    if self._incremental_vrow_edits >= 32 then self._vrows_dirty = true; self._incremental_vrow_edits = 0 end
    return true
end
-- Locate the caret within the cached rows. Cheap: only scans row metadata and
-- measures within the single logical line that holds the cursor.
function MDEdit:cursorVisual(vrows)
    local crow_rows, map = {}, {}
    for vi = 1, #vrows do
        local vr = vrows[vi]
        if vr.kind == "row" and vr.line == self.crow then
            crow_rows[#crow_rows+1] = vr.row
            map[#crow_rows] = vi
        end
    end
    if #crow_rows == 0 then return nil, nil end
    local cri, cx = self:cursorInRows(crow_rows)
    return map[cri], cx
end
function MDEdit:textWidth()
    return self.fw - (MDEDIT_PAD * 2)
end
function MDEdit:moveCursorVisual(drow)
    local vrows = self:visualRows(self:textWidth())
    local vi, cx = self:cursorVisual(vrows)
    if not vi then return false end
    local target_x = self._desired_x or cx or 0
    local text_rows, current_idx = {}, nil
    for i, vr in ipairs(vrows) do
        if vr.kind == "row" then
            text_rows[#text_rows+1] = { vi = i, vr = vr }
            if i == vi then current_idx = #text_rows end
        end
    end
    if not current_idx then return false end
    local target = text_rows[current_idx + (drow < 0 and -1 or 1)]
    local vr = target and target.vr
    if not vr or vr.kind ~= "row" then return true end
    self._desired_x = target_x
    self.crow = vr.line
    self.ccol = utf8_snap(self.lines[self.crow], self:colAtX(vr.row, target_x))
    return true
end
function MDEdit:visualRowHeight(vr)
    if vr.kind == "gap" then return vr.h or 0 end
    if vr.kind == "table_row" then return vr.h or 0 end
    return self:rowHeight(vr.row, vr.block)
end
function MDEdit:rebuild()
    local cw = self.fw - (MDEDIT_PAD * 2)
    local text_w = self:textWidth()
    local topbar = self:topBar(cw)
    local vg = VerticalGroup:new{ align = "left", topbar, VerticalSpan:new{ width = MDEDIT_TOPBAR_GAP } }
    local kbd_h = 0
    if self.keyboard then
        kbd_h = self.keyboard.dimen and self.keyboard.dimen.h or math.floor(self.fh * 0.36)
    end
    local editor_top = MDEDIT_PAD + MDEDIT_TOPBAR_H + MDEDIT_TOPBAR_GAP
    local progress_area = MDEDIT_PROGRESS_GAP + MDEDIT_PROGRESS_H
    -- The repaint area always runs from the top down to the keyboard's top edge
    -- (or the whole screen when no keyboard is up). Text, though, stops short of
    -- that: with the keyboard up the progress bar and the frame's bottom padding
    -- are hidden behind it and aren't needed, so text may run down to just above
    -- the keyboard (leaving only MDEDIT_KBD_TEXT_GAP); otherwise it leaves room for
    -- the pinned progress bar and the bottom padding.
    local refresh_bottom = self.fh - kbd_h
    local body_bottom = self.keyboard and (refresh_bottom - MDEDIT_KBD_TEXT_GAP)
        or (self.fh - MDEDIT_PAD - progress_area)
    local budget = body_bottom - editor_top
    self.visible_budget = budget
    local body = VerticalGroup:new{ align = "left" }
    local visual_rows = self:visualRows(text_w)
    self.visual_count = #visual_rows
    self.vtop = math.max(1, math.min(self.visual_count, self.vtop or 1))
    local cursor_vi, cursor_cx
    if not self.reader_mode then cursor_vi, cursor_cx = self:cursorVisual(visual_rows) end
    local manual_scroll = self._manual_scroll_cursor
        and self._manual_scroll_cursor.row == self.crow
        and self._manual_scroll_cursor.col == self.ccol
    if self._manual_scroll_cursor and not manual_scroll then self._manual_scroll_cursor = nil end
    if not self.reader_mode and cursor_vi and not manual_scroll then
        if cursor_vi < self.vtop then self.vtop = cursor_vi end
        local used_to_cursor = 0
        for vi = self.vtop, cursor_vi do
            used_to_cursor = used_to_cursor + self:visualRowHeight(visual_rows[vi])
        end
        while self.vtop < cursor_vi and used_to_cursor > budget do
            used_to_cursor = used_to_cursor - self:visualRowHeight(visual_rows[self.vtop])
            self.vtop = self.vtop + 1
        end
    end
    self.row_map = {}
    self.caret_region = nil
    local ytop, used, shown = editor_top, 0, 0
    for vi = self.vtop, #visual_rows do
        local vr = visual_rows[vi]
        if vr.kind == "gap" then
            if used + vr.h > budget then break end
            body[#body+1] = VerticalSpan:new{ width = vr.h }
            used = used + vr.h
            shown = shown + 1
        elseif vr.kind == "table_row" then
            local rowh = vr.h
            if used + rowh > budget then break end
            body[#body+1] = self:renderTableRow(vr)
            self.row_map[#self.row_map+1] = {
                y0 = ytop + used,
                y1 = ytop + used + rowh,
                line = vr.line,
                table = vr.table,
                cells = vr.cells,
                col_widths = vr.col_widths,
            }
            used = used + rowh
            shown = shown + 1
        else
            local i, row = vr.line, vr.row
            local texth = self:rowTextHeight(row)
            local rowh = self:rowHeight(row, vr.block)
            local text_y = math.max(0, math.floor((rowh - texth) / 2))
            if used + rowh > budget then break end
            local slo, shi = self:lineSel(i)
            local args = { dimen = Geom:new{ w = text_w, h = rowh } }
            -- Persistent ==highlight== fill, drawn behind the text in every mode.
            -- Contiguous highlight segments are merged into one bar so word gaps
            -- don't leave hairline seams. (Selection, added next, paints on top.)
            local hx, hstart = row.indent or 0, nil
            local function flush_hl(xend)
                if hstart and xend > hstart then
                    args[#args+1] = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = hstart },
                        LineWidget:new{ background = MDEDIT_HIGHLIGHT_GRAY, dimen = Geom:new{ w = math.max(2, xend - hstart), h = rowh } } }
                end
                hstart = nil
            end
            for _, seg in ipairs(row.segs) do
                if seg.hl then
                    -- Keep the run open across hidden zero-width inner markers (the
                    -- **/`/* of nested styles) so the fill is one continuous bar.
                    if (seg.w or 0) > 0 and not hstart then hstart = hx end
                else
                    flush_hl(hx)
                end
                hx = hx + (seg.w or 0)
            end
            flush_hl(hx)
            if slo then                                   -- selection highlight, drawn behind the text
                local rb = row.sb
                for _, sg in ipairs(row.segs) do rb = rb + #sg.text end
                local a, b = math.max(slo, row.sb), math.min(shi, rb)
                if a < b then
                    local x0, x1 = self:rowXAt(row, a), self:rowXAt(row, b)
                    args[#args+1] = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = x0 },
                        LineWidget:new{ background = Blitbuffer.Color8(205), dimen = Geom:new{ w = math.max(2, x1 - x0), h = rowh } } }
                end
            end
            args[#args+1] = VerticalGroup:new{ VerticalSpan:new{ width = text_y }, self:renderRow(row) }
            if vi == cursor_vi and cursor_cx and not self.reader_mode then
                local caret_h = math.max(18, math.min(rowh - 2, texth))
                local caret_y = math.max(0, text_y + math.floor((texth - caret_h) / 2))
                if self.caret_on then
                    args[#args+1] = VerticalGroup:new{
                        VerticalSpan:new{ width = caret_y },
                        HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = cursor_cx }, self:caret(caret_h) },
                    }
                end
                self.caret_region = Geom:new{
                    x = MDEDIT_PAD + cursor_cx - 2, y = ytop + used + caret_y, w = 7, h = caret_h,
                }
            end
            body[#body+1] = OverlapGroup:new(args)
            self.row_map[#self.row_map+1] = { y0 = ytop + used, y1 = ytop + used + rowh, line = i, row = row }
            used = used + rowh
            shown = shown + 1
        end
    end
    self.visible_vrows = math.max(1, shown)   -- visual entries (rows+gaps) on screen
    self.top = self.row_map[1] and self.row_map[1].line or 1
    vg[#vg+1] = body
    self.editor_refresh_region = Geom:new{
        x = 0, y = 0, w = self.fw,
        h = math.max(1, refresh_bottom),
    }
    -- Same as editor_refresh_region but starting below the top bar. The toolbar/
    -- title never change while scrolling, selecting, or reflowing text, so those
    -- repaints should leave it untouched (no e-ink flash of a stable strip).
    self.editor_body_region = Geom:new{
        x = 0, y = editor_top, w = self.fw,
        h = math.max(1, refresh_bottom - editor_top),
    }
    -- The progress bar is pinned to the very bottom of the screen (below the text
    -- frame's padding) so it holds a fixed position regardless of how much text is
    -- on screen, and never crowds the last line. It's dropped entirely while the
    -- keyboard is up -- it would only sit hidden behind the keys, and skipping it
    -- frees that strip for text.
    local layers = OverlapGroup:new{
        dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh },
        FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = MDEDIT_PAD,
            width = self.fw, height = self.fh, vg },
    }
    if not self.keyboard then
        layers[#layers+1] = BottomContainer:new{ dimen = Geom:new{ w = self.fw, h = self.fh - 5 }, self:progressBar(cw) }
    end
    self[1] = layers
end
-- Bounding bands (full width) of logical-line rows, for narrow e-ink refreshes
-- while typing.
function MDEdit:lineBand(row)
    local y0, y1
    for _, rm in ipairs(self.row_map or {}) do
        if rm.line == row then
            y0 = math.min(y0 or rm.y0, rm.y0)
            y1 = math.max(y1 or rm.y1, rm.y1)
        end
    end
    if not y0 then return nil end
    return Geom:new{ x = 0, y = math.max(0, y0 - 2), w = self.fw, h = (y1 - y0) + 10 }
end
-- Band (full width) from the cursor's own visual row down through the rest of the
-- current logical line. A same-line edit changes the cursor's row AND can rewrap
-- the rows after it within the line (a word crossing the wrap boundary), but never
-- the rows above the cursor -- so this is the tightest region that stays correct.
-- (When the line's height changes, content below shifts too; that's the reflow
-- path, which repaints from here down to the bottom.)
function MDEdit:cursorRowBand()
    local y0, y1
    for _, rm in ipairs(self.row_map or {}) do
        if rm.line == self.crow and rm.row then
            local sb = rm.row.sb or 0
            local rb = sb
            for _, sg in ipairs(rm.row.segs or {}) do rb = rb + #(sg.text or "") end
            if not y0 then
                if self.ccol >= sb and self.ccol <= rb then y0, y1 = rm.y0, rm.y1 end
            else
                y1 = math.max(y1, rm.y1)   -- extend through later rows of the same line
            end
        end
    end
    if not y0 then return self:lineBand(self.crow) end   -- fallback: whole line
    return Geom:new{ x = 0, y = math.max(0, y0 - 2), w = self.fw, h = (y1 - y0) + 10 }
end
-- Stable description of the pixels produced by one wrapped text row. Comparing
-- these before and after a local edit lets us skip wrapped rows whose contents did
-- not actually move. Geometry is compared separately when building the region.
function MDEdit:rowPaintKey(rm)
    if not (rm and rm.row) then return nil end
    local row = rm.row
    local parts = {
        tostring(row.indent or 0), tostring(row.w or 0),
    }
    for _, seg in ipairs(row.segs or {}) do
        local visible = seg.display == nil and (seg.text or "") or seg.display
        parts[#parts+1] = table.concat({
            visible, seg.style or "", seg.hl and "1" or "0", tostring(seg.w or 0),
        }, "\2")
    end
    return table.concat(parts, "\3")
end
-- Rendered prefix before an absolute source column. This catches Markdown edits
-- that restyle text to the left of the insertion point (for example completing a
-- closing ** marker), where starting the refresh at the caret would be incorrect.
function MDEdit:rowPrefixPaintKey(row, col)
    local parts, byte = { tostring(row.indent or 0) }, row.sb or 0
    for _, seg in ipairs(row.segs or {}) do
        local raw = seg.text or ""
        local take = math.max(0, math.min(#raw, (col or byte) - byte))
        if take > 0 then
            local visible
            -- layoutLine stores ordinary text with display == raw. Treat that as
            -- directly sliceable text; only genuinely synthetic/hidden display
            -- values (bullets, task boxes, Markdown markers) need all-or-nothing
            -- handling. Misclassifying display == raw made edits at a word end
            -- look like the rendered prefix changed and widened the dirty row to
            -- x = 0, flashing all text to the left of the cursor.
            if seg.display == nil or seg.display == raw then
                visible = raw:sub(1, take)
            elseif take >= #raw then
                visible = seg.display
            else
                visible = "" -- hidden/synthetic markers have no useful partial glyph prefix
            end
            parts[#parts+1] = table.concat({
                visible, seg.style or "", seg.hl and "1" or "0",
            }, "\2")
        end
        byte = byte + #raw
        if byte >= (col or byte) then break end
    end
    return table.concat(parts, "\3")
end
-- X position of the UTF-8 character immediately before an absolute source
-- column within this visual row. Starting precise refreshes here protects the
-- preceding glyph's edge/kerning pixels from being left white by e-ink updates.
function MDEdit:previousGlyphX(row, col)
    local raw = {}
    for _, seg in ipairs(row.segs or {}) do raw[#raw+1] = seg.text or "" end
    raw = table.concat(raw)
    local local_col = math.max(0, math.min(#raw, (col or row.sb or 0) - (row.sb or 0)))
    local prev_col = utf8_left(raw, local_col)
    return self:rowXAt(row, (row.sb or 0) + prev_col)
end
-- Regions changed by an insertion/deletion within one logical line. The first
-- affected row starts at the earlier old/new edit position; later rows are only
-- included when wrapping actually changed their rendered pixels. Extending each
-- changed tail to the right edge is deliberate: narrower e-ink updates left stale
-- glyph fragments, but there is no reason to repaint unchanged rows below it.
function MDEdit:changedLineRegions(prev_row_map, row_map, row, prev_col, col)
    local old, new = {}, {}
    for _, rm in ipairs(prev_row_map or {}) do
        if rm.line == row and rm.row then old[#old+1] = rm end
    end
    for _, rm in ipairs(row_map or {}) do
        if rm.line == row and rm.row then new[#new+1] = rm end
    end
    if #old == 0 or #old ~= #new then return nil end

    local regions = {}
    for i = 1, #old do
        local before, after = old[i], new[i]
        if self:rowPaintKey(before) ~= self:rowPaintKey(after)
            or before.y0 ~= after.y0 or before.y1 ~= after.y1 then
            local x = 0
            local old_sb = before.row.sb or 0
            local new_sb = after.row.sb or 0
            local old_rb, new_rb = old_sb, new_sb
            for _, seg in ipairs(before.row.segs or {}) do old_rb = old_rb + #(seg.text or "") end
            for _, seg in ipairs(after.row.segs or {}) do new_rb = new_rb + #(seg.text or "") end
            local old_here = prev_col and prev_col >= old_sb and prev_col <= old_rb
            local new_here = col and col >= new_sb and col <= new_rb
            if old_here or new_here then
                local change_col = math.min(prev_col or col or 0, col or prev_col or 0)
                local prefix_changed = self:rowPrefixPaintKey(before.row, change_col)
                    ~= self:rowPrefixPaintKey(after.row, change_col)
                if not prefix_changed then
                    local old_x = change_col >= old_sb and change_col <= old_rb
                        and self:previousGlyphX(before.row, change_col) or nil
                    local new_x = change_col >= new_sb and change_col <= new_rb
                        and self:previousGlyphX(after.row, change_col) or nil
                    local edit_x = old_x and new_x and math.min(old_x, new_x) or old_x or new_x or 0
                    x = math.max(0, MDEDIT_PAD + edit_x - 2)
                end
            end
            local y0 = math.max(0, math.min(before.y0, after.y0) - 2)
            local y1 = math.max(before.y1, after.y1) + 8
            regions[#regions+1] = Geom:new{
                x = x, y = y0, w = math.max(1, self.fw - x), h = math.max(1, y1 - y0),
            }
        end
    end
    return regions
end
-- The slice from the top of a logical line down to the bottom of the editor.
-- After a reflow (wrap/newline/join) or a line-height change, only this line and
-- everything below it moved; the top bar and lines above are untouched, so this
-- avoids repainting (and flashing) the whole page.
function MDEdit:regionFromLineToBottom(row)
    local band = self:lineBand(row)
    if not band then return nil end
    local bottom = self.editor_refresh_region.y + self.editor_refresh_region.h
    return Geom:new{ x = 0, y = band.y, w = self.fw, h = math.max(1, bottom - band.y) }
end
-- Like regionFromLineToBottom but starting at the cursor's own visual row rather
-- than the top of its (possibly tall, wrapped) paragraph. A same-line reflow -- a
-- word wrapping within the paragraph -- only shifts content from the cursor down,
-- so the rows above the cursor must not be blanked/repainted.
function MDEdit:regionFromCursorRowToBottom()
    local y0
    for _, rm in ipairs(self.row_map or {}) do
        if rm.line == self.crow and rm.row then
            local sb = rm.row.sb or 0
            local rb = sb
            for _, sg in ipairs(rm.row.segs or {}) do rb = rb + #(sg.text or "") end
            if self.ccol >= sb and self.ccol <= rb then y0 = rm.y0; break end
        end
    end
    if not y0 then return nil end
    local top = math.max(0, y0 - 2)
    local bottom = self.editor_refresh_region.y + self.editor_refresh_region.h
    return Geom:new{ x = 0, y = top, w = self.fw, h = math.max(1, bottom - top) }
end
function MDEdit:unionRegion(a, b)
    if not a then return b end
    if not b then return a end
    local x0 = math.min(a.x, b.x)
    local y0 = math.min(a.y, b.y)
    local x1 = math.max(a.x + a.w, b.x + b.w)
    local y1 = math.max(a.y + a.h, b.y + b.h)
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end
function MDEdit:selectionIsMultiline()
    local lr, _, hr = self:selRange()
    return lr ~= nil and hr ~= nil and lr ~= hr
end
function MDEdit:caretRowTop(caret, row_map)
    if not caret then return nil end
    local cy = caret.y + math.floor(caret.h / 2)
    for _, rm in ipairs(row_map or {}) do
        if rm.row and cy >= rm.y0 and cy <= rm.y1 then return rm.y0 end
    end
    return nil
end
function MDEdit:regionFromCaretTransitionToBottom(prev_caret, prev_row_map)
    local old_top = self:caretRowTop(prev_caret, prev_row_map)
    local new_top = self:caretRowTop(self.caret_region, self.row_map)
    local top = old_top and new_top and math.min(old_top, new_top) or old_top or new_top
    if not top then return nil end
    top = math.max(0, top - 2)
    local bottom = self.editor_refresh_region.y + self.editor_refresh_region.h
    return Geom:new{ x = 0, y = top, w = self.fw, h = math.max(1, bottom - top) }
end
-- Full-width band spanning every *visible* row of logical lines [from,to]. Lets a
-- highlight add/remove repaint just the edited line(s) instead of the whole screen.
-- Returns nil if none of those lines are currently on screen.
function MDEdit:linesRegion(from, to)
    if not from or not to then return nil end
    if from > to then from, to = to, from end
    local y0, y1
    for _, rm in ipairs(self.row_map or {}) do
        if rm.line >= from and rm.line <= to then
            y0 = y0 and math.min(y0, rm.y0) or rm.y0
            y1 = y1 and math.max(y1, rm.y1) or rm.y1
        end
    end
    if not y0 then return nil end
    return Geom:new{ x = 0, y = y0, w = self.fw, h = math.max(1, y1 - y0) }
end
function MDEdit:refresh(opts)
    opts = opts or {}
    if opts.layout_dirty ~= false then
        self._vrows_dirty = true          -- content may have changed; rebuild the layout cache
    end
    self.caret_on = true
    local prev_count = self.visual_count
    local prev_vtop = self.vtop
    local prev_crow = self._render_crow or self.crow
    local prev_ccol = self._render_ccol or self.ccol
    local prev_band = self:lineBand(self.crow)
    local prev_caret = self.caret_region
    local prev_row_map = self.row_map
    local prev_sel_multiline = self._render_sel_multiline
    local prev_has_selection = not not self._render_has_selection
    self:rebuild()
    local region = self.keyboard and self.editor_refresh_region or nil
    local regions
    local vtop_changed = prev_vtop and self.vtop and prev_vtop ~= self.vtop
    -- A same-line selection used to disappear from state without repainting:
    -- unlike multi-line selections it had no special dirty hint. Track whether
    -- the previous frame had any visible selection so clearing it always erases
    -- the old highlight.
    local has_selection = self:hasSel()
    local selection_dirty = opts.selection or prev_sel_multiline or self:selectionIsMultiline()
        or prev_has_selection ~= has_selection
    local band = self:lineBand(self.crow)
    local line_geometry_changed = prev_band and band
        and (prev_band.y ~= band.y or prev_band.h ~= band.h)
    -- If the wrapped-row count is unchanged, the edit stayed within one logical
    -- line and nothing below it moved -- refresh only the affected tail of that
    -- line. A reflow (wrap change, newline, line join) or a line-height change
    -- shifts the edited line and everything below it, but leaves the top bar and
    -- the lines above untouched -- repaint only that lower slice.
    -- With the on-screen keyboard visible, keep refreshing the whole editor band;
    -- partial editor redraws above a live keyboard leave mixed e-ink regions.
    local reflow = prev_count and self.visual_count ~= prev_count
    if opts.lines then
        -- Caller knows exactly which logical lines changed (e.g. a highlight edit):
        -- repaint only those, never the whole screen.
        region = self:linesRegion(opts.lines[1], opts.lines[2]) or self.editor_body_region
    elseif opts.full then
        region = self.editor_refresh_region
    elseif selection_dirty or vtop_changed then
        region = self.editor_body_region
    elseif reflow or line_geometry_changed then
        if self.keyboard then
            region = self.editor_refresh_region
        elseif prev_crow == self.crow then
            -- Reflow within the same paragraph (a word wrapped): only content from
            -- the earlier of the old/new cursor rows down moved. Including the old
            -- row clears text that moved onto the new row without repainting above it.
            region = self:regionFromCaretTransitionToBottom(prev_caret, prev_row_map)
                or self:regionFromCursorRowToBottom()
                or self:regionFromLineToBottom(self.crow)
                or self.editor_refresh_region
        else
            -- Line split/join: the edit spans two logical lines; repaint from the
            -- higher of the two down.
            region = self:regionFromLineToBottom(math.min(prev_crow or self.crow, self.crow))
                or self.editor_refresh_region
        end
    elseif prev_count and self.visual_count == prev_count then
        if opts.cursor_move then
            if prev_caret and self.caret_region then
                regions = { prev_caret, self.caret_region }
                band = nil
            elseif prev_caret or self.caret_region then
                band = prev_caret or self.caret_region
            elseif prev_crow and prev_crow ~= self.crow then
                band = self:unionRegion(self:lineBand(prev_crow), band)
            end
        elseif opts.precise_edit and prev_crow == self.crow then
            -- Ordinary typing/backspace: compare the old and new wrapped rows and
            -- invalidate only rows whose pixels changed. In the common case this
            -- is one tail on one row, even near the bottom of the screen.
            regions = self:changedLineRegions(prev_row_map, self.row_map,
                self.crow, prev_ccol, self.ccol)
            if regions then
                -- A zero-width Markdown marker can change the source without
                -- changing row pixels; in that case only the caret moved.
                if #regions == 0 then
                    if prev_caret then regions[#regions+1] = prev_caret end
                    if self.caret_region then regions[#regions+1] = self.caret_region end
                end
                band = nil
            else
                band = self:cursorRowBand()
            end
        else
            -- Broader same-line edits may alter styling without going through the
            -- precise path, so conservatively refresh from the cursor row onward.
            band = self:cursorRowBand()
        end
        if band then region = band end
    end
    self._render_crow = self.crow
    self._render_ccol = self.ccol
    self._render_sel_multiline = self:selectionIsMultiline()
    self._render_has_selection = has_selection
    self._last_dirty_at = now_seconds()
    self._last_dirty_region = regions and self.caret_region or region
    self._last_dirty_full = not regions and region == nil
    if regions then
        for _, dirty_region in ipairs(regions) do
            UIManager:setDirty(self, "ui", dirty_region)
        end
    else
        UIManager:setDirty(self, "ui", region)
    end
end
-- Scroll-only repaint: vtop moved but the text is unchanged, so reuse the
-- cached visual rows instead of re-tokenizing the whole document.
function MDEdit:refreshScroll()
    self.caret_on = true
    self:rebuild()
    UIManager:setDirty(self, "ui", self.editor_body_region)
end
function MDEdit:checkRemoteInbox()
    if not self.remote then return end
    local revision = tonumber(read_file(self.remote.revision_path) or "")
    if not revision or revision <= (self.remote_revision or 0) then return end
    -- Preserve local Kindle changes until the worker has handed them off.
    if self._dirty or lfs.attributes(self.remote.outbox_path, "mode") then return end
    local text = read_file(self.remote.inbox_path)
    if text == nil then return end
    self.remote_revision = revision
    if text == self:currentText() then return end
    write_file(self.path, text)
    self.lines = split_text_lines(text)
    self.crow = math.max(1, math.min(self.crow or 1, #self.lines))
    self.ccol = math.max(0, math.min(self.ccol or 0, #(self.lines[self.crow] or "")))
    self.sel, self._desired_x, self._burst = nil, nil, nil
    self._undo, self._redo = {}, {}
    self._file_text, self._file_signature = text, file_signature(self.path)
    self:refresh{ layout_dirty = true, full = true }
end
function MDEdit:scheduleAutosave()
    self._dirty = true
    if self._autosave_paused_for_external then return end
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    local fn
    fn = function()
        if self._autosave_pending == fn then self._autosave_pending = nil end
        if self._dirty and not self._autosave_paused_for_external then self:save() end
    end
    self._autosave_pending = fn
    UIManager:scheduleIn(MDEDIT_AUTOSAVE_DELAY, fn)
end
function MDEdit:flushAutosave()
    self:flushTypeBuffer()
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    if self._autosave_paused_for_external then return end
    if self._dirty then self:save() end
end
function MDEdit:currentText()
    self:flushTypeBuffer()
    return table.concat(self.lines, "\n")
end
function MDEdit:reloadFromDisk(text, sig)
    if text == nil then text = read_file(self.path) end
    if text == nil then return false end
    self.lines = split_text_lines(text)
    self.crow = math.max(1, math.min(self.crow or 1, #self.lines))
    self.ccol = math.max(0, math.min(self.ccol or 0, #(self.lines[self.crow] or "")))
    self.sel = nil
    self._desired_x = nil
    self._burst = nil
    self._undo, self._redo = {}, {}
    self._dirty = false
    self._file_text = text
    self._file_signature = sig or file_signature(self.path)
    self._external_change_prompted = nil
    self._autosave_paused_for_external = nil
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    self:refresh{ layout_dirty = true, full = true }
    notify(_("Reloaded from disk"))
    return true
end
function MDEdit:promptExternalReload(text, sig)
    if self._external_change_prompted then return end
    self._external_change_prompted = true
    self._autosave_paused_for_external = true
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    UIManager:show(ConfirmBox:new{
        text = _("File changed on disk. Reload and discard unsaved edits?\nAutosave is paused until you reload or save."),
        ok_text = _("Reload"),
        ok_callback = function() self:reloadFromDisk(text, sig) end,
    })
end
function MDEdit:checkExternalFile()
    local sig = file_signature(self.path)
    if same_file_signature(sig, self._file_signature) then return end
    local text = read_file(self.path)
    if text == nil then
        if not self._external_missing_notified then
            self._external_missing_notified = true
            notify(_("File is unavailable on disk"))
        end
        return
    end
    self._external_missing_notified = nil
    if text == self:currentText() then
        self._file_text = text
        self._file_signature = sig
        self._dirty = false
        self._autosave_paused_for_external = nil
        return
    end
    if self._dirty then
        self:promptExternalReload(text, sig)
    else
        self:reloadFromDisk(text, sig)
    end
end
function MDEdit:scheduleFilePoll()
    if self._file_poll_pending then UIManager:unschedule(self._file_poll_pending); self._file_poll_pending = nil end
    local fn
    fn = function()
        if self._file_poll_pending == fn then self._file_poll_pending = nil end
        if self._closing then return end
        self:checkExternalFile()
        self:checkRemoteInbox()
        self:scheduleFilePoll()
    end
    self._file_poll_pending = fn
    UIManager:scheduleIn(MDEDIT_FILE_RELOAD_INTERVAL, fn)
end
-- A heartbeat is intentionally infrequent.  If the UI loop is delayed, the
-- next entry records the gap; if KOReader dies, the last marker identifies the
-- last known healthy editor state without materially affecting battery life.
function MDEdit:scheduleHeartbeat(delay)
    if self._heartbeat_pending then
        UIManager:unschedule(self._heartbeat_pending)
        self._heartbeat_pending = nil
    end
    local fn
    fn = function()
        if self._heartbeat_pending == fn then self._heartbeat_pending = nil end
        if self._closing then return end
        local now = now_seconds()
        local gap = self._heartbeat_at and (now - self._heartbeat_at) or 0
        MinfolioPair.trace("editor-heartbeat", "path=", tostring(self.path),
            "gap=", string.format("%.2f", gap), "row=", self.crow or 0,
            "vtop=", self.vtop or 0, "dirty=", self._dirty and "yes" or "no")
        self._heartbeat_at = now
        self:scheduleHeartbeat(60)
    end
    self._heartbeat_pending = fn
    UIManager:scheduleIn(delay or 60, fn)
end
function MDEdit:snapshot()
    self:scheduleAutosave()
    self._undo = self._undo or {}
    self._undo[#self._undo+1] = { lines = copy_arr(self.lines), crow = self.crow, ccol = self.ccol }
    if #self._undo > 80 then table.remove(self._undo, 1) end
    self._redo = {}
end
function MDEdit:snapshotLine()
    self:scheduleAutosave()
    self._undo = self._undo or {}
    self._undo[#self._undo+1] = {
        kind = "line", line = self.crow, text = self.lines[self.crow] or "",
        crow = self.crow, ccol = self.ccol,
    }
    if #self._undo > 80 then table.remove(self._undo, 1) end
    self._redo = {}
end
function MDEdit:edit(tag)             -- snapshot once per edit "burst" (typing vs deleting)
    if self._burst ~= tag then
        -- The sustained typing/backspace path changes one logical line. Keeping
        -- just that line avoids copying every line of a large note for undo.
        if tag == "type" or (tag == "del" and self.ccol > 0) then self:snapshotLine() else self:snapshot() end
    else self:scheduleAutosave() end
    self._burst = tag
end
function MDEdit:_restore(stack, other)
    if not (stack and #stack > 0) then return end
    local s = table.remove(stack)
    if s.kind == "line" then
        other[#other+1] = { kind = "line", line = s.line, text = self.lines[s.line] or "", crow = self.crow, ccol = self.ccol }
        self.lines[s.line] = s.text
        self.crow, self.ccol = s.crow, s.ccol
    else
        other[#other+1] = { lines = copy_arr(self.lines), crow = self.crow, ccol = self.ccol }
        self.lines, self.crow, self.ccol = s.lines, s.crow, s.ccol
    end
    self._burst = nil
    self._desired_x = nil
    self:scheduleAutosave()
    self:refresh()
end
function MDEdit:undo() self._redo = self._redo or {}; self:_restore(self._undo, self._redo) end
function MDEdit:redo() self._undo = self._undo or {}; self:_restore(self._redo, self._undo) end
-- ---- selection + clipboard (anchor in self.sel, cursor at crow/ccol) ----
function MDEdit:selRange()
    if not self.sel then return nil end
    local ar, ac, br, bc = self.sel.row, self.sel.col, self.crow, self.ccol
    if ar < br or (ar == br and ac <= bc) then return ar, ac, br, bc else return br, bc, ar, ac end
end
function MDEdit:hasSel()
    local lr, lc, hr, hc = self:selRange()
    return lr ~= nil and not (lr == hr and lc == hc)
end
function MDEdit:lineSel(i)            -- selected byte range [lo,hi] within line i, or nil
    local lr, lc, hr, hc = self:selRange()
    if not lr or i < lr or i > hr then return nil end
    if lr == hr then if lc == hc then return nil end; return lc, hc end
    if i == lr then return lc, #self.lines[i]
    elseif i == hr then return 0, hc
    else return 0, #self.lines[i] end
end
function MDEdit:selText()
    local lr, lc, hr, hc = self:selRange()
    if not lr then return "" end
    if lr == hr then return self.lines[lr]:sub(lc+1, hc) end
    local parts = { self.lines[lr]:sub(lc+1) }
    for k = lr+1, hr-1 do parts[#parts+1] = self.lines[k] end
    parts[#parts+1] = self.lines[hr]:sub(1, hc)
    return table.concat(parts, "\n")
end
function MDEdit:deleteSelection()
    local lr, lc, hr, hc = self:selRange()
    if not lr then return false end
    self._desired_x = nil
    if lr == hr then
        self.lines[lr] = self.lines[lr]:sub(1, lc) .. self.lines[lr]:sub(hc+1)
    else
        self.lines[lr] = self.lines[lr]:sub(1, lc) .. self.lines[hr]:sub(hc+1)
        for k = hr, lr+1, -1 do table.remove(self.lines, k) end
    end
    self.crow, self.ccol, self.sel = lr, lc, nil
    return true
end
function MDEdit:copy() if self:hasSel() then md_clipboard = self:selText() end end
function MDEdit:cut()
    if not self:hasSel() then return end
    md_clipboard = self:selText(); self:snapshot(); self._burst = nil
    self._desired_x = nil
    self:deleteSelection(); self:refresh()
end
function MDEdit:paste()
    if not md_clipboard or md_clipboard == "" then return end
    self:snapshot(); self._burst = nil
    self._desired_x = nil
    if self:hasSel() then self:deleteSelection() end
    local cl = {}
    for line in (md_clipboard .. "\n"):gmatch("(.-)\n") do cl[#cl+1] = line end
    local l = self.lines[self.crow]
    if #cl <= 1 then
        local one = cl[1] or ""
        self.lines[self.crow] = l:sub(1, self.ccol) .. one .. l:sub(self.ccol+1)
        self.ccol = self.ccol + #one
    else
        local tail = l:sub(self.ccol+1)
        self.lines[self.crow] = l:sub(1, self.ccol) .. cl[1]
        for k = 2, #cl do table.insert(self.lines, self.crow + k - 1, cl[k]) end
        self.crow = self.crow + #cl - 1
        self.ccol = #cl[#cl]
        self.lines[self.crow] = self.lines[self.crow] .. tail
    end
    self:refresh()
end
function MDEdit:selectAll()
    self._desired_x = nil
    self.sel = { row = 1, col = 0 }
    self.crow = #self.lines; self.ccol = #self.lines[#self.lines]
    self:refresh{ layout_dirty = false, selection = true, full = true }
end
function MDEdit:rowXAt(row, p)        -- x of absolute byte col p within a visual row
    local b, x = row.sb, row.indent or 0
    for _, seg in ipairs(row.segs) do
        if p <= b + #seg.text then
            local display = seg.display
            if display == nil then display = seg.text end
            if display == "" then return x end
            if display ~= seg.text then
                local raw_len = math.max(1, #seg.text)
                return x + math.floor(seg.w * math.max(0, p - b) / raw_len)
            end
            return x + self:wordw(seg.text:sub(1, p - b), seg.style)
        end
        x = x + seg.w; b = b + #seg.text
    end
    return x
end
function MDEdit:arrow(drow, dcol, m)  -- arrow key with optional Shift (select) / Alt-or-Command (word)
    self:flushTypeBuffer()
    local selecting = keymod(m, "Shift")
    if selecting then if not self.sel then self.sel = { row = self.crow, col = self.ccol } end
    else self.sel = nil end
    if word_key_mod(m) and dcol ~= 0 then if dcol < 0 then self:wordLeft(selecting) else self:wordRight(selecting) end
    else self:moveCursor(drow, dcol, { selection = selecting }) end
end
local md_split_line_prefix
function MDEdit:insertTypedText(s)
    if not s or s == "" then return end
    self:pauseCaretBlinkForInput()
    self._desired_x = nil
    local had_sel = self:hasSel()
    if had_sel then self:snapshot(); self._burst = nil; self:deleteSelection() else self:edit("type") end
    for i = 1, #s do
        local ch = s:sub(i, i)
        local l = self.lines[self.crow]
        if ch == " " and self.ccol >= 1 and l:sub(self.ccol, self.ccol) == " "
           and (self.ccol < 2 or l:sub(self.ccol-1, self.ccol-1) ~= " ") then
            self.lines[self.crow] = l:sub(1, self.ccol-1) .. ". " .. l:sub(self.ccol+1)
            self.ccol = self.ccol + 1
        else
            self.lines[self.crow] = l:sub(1, self.ccol) .. ch .. l:sub(self.ccol+1)
            self.ccol = self.ccol + #ch
        end
    end
    self._last_type_flush_at = now_seconds()
    local incremental = not had_sel and self:updateVisualLine(self.crow)
    self:refresh{ layout_dirty = not incremental, precise_edit = not had_sel }
end
function MDEdit:flushTypeBuffer()
    if self._type_flush_pending then
        UIManager:unschedule(self._type_flush_pending)
        self._type_flush_pending = nil
    end
    local s = self._type_buffer
    self._type_buffer = nil
    if s and s ~= "" then self:insertTypedText(s) end
end
function MDEdit:queueTypedChar(ch)
    self:pauseCaretBlinkForInput()
    self._type_buffer = (self._type_buffer or "") .. ch
    -- Give the first key after an idle pause near-immediate feedback, then settle
    -- into a slightly wider cadence that batches sustained typing efficiently.
    -- The pending callback is never rescheduled by later keys, so fast input
    -- cannot defer rendering indefinitely.
    if self._type_flush_pending then return end
    local now = now_seconds()
    local first_in_burst = not self._last_type_flush_at
        or now - self._last_type_flush_at >= MDEDIT_TYPE_BURST_IDLE
    local delay = first_in_burst and MDEDIT_TYPE_FIRST_FLUSH_DELAY or MDEDIT_TYPE_FLUSH_DELAY
    local fn
    fn = function()
        if self._type_flush_pending == fn then self._type_flush_pending = nil end
        local s = self._type_buffer
        self._type_buffer = nil
        if s and s ~= "" then self:insertTypedText(s) end
    end
    self._type_flush_pending = fn
    UIManager:scheduleIn(delay, fn)
end
function MDEdit:queueVirtualChars(s)
    self:pauseCaretBlinkForInput()
    self._type_buffer = (self._type_buffer or "") .. s
    self._virtual_key_count = (self._virtual_key_count or 0) + #s
    -- On-screen input has no hardware repeat to keep responsive.  More
    -- importantly, rebuilding the Markdown view every 45 ms can monopolize the
    -- Kindle's UI loop long enough for subsequent touch contacts to be dropped.
    -- Debounce the visual update instead: taps only append a short Lua string,
    -- then the complete burst is rendered once the finger cadence pauses.
    if self._type_flush_pending then
        UIManager:unschedule(self._type_flush_pending)
        self._type_flush_pending = nil
    end
    local fn
    fn = function()
        if self._type_flush_pending == fn then self._type_flush_pending = nil end
        local text = self._type_buffer
        self._type_buffer = nil
        if text and text ~= "" then self:insertTypedText(text) end
    end
    self._type_flush_pending = fn
    UIManager:scheduleIn(0.18, fn)
end
function MDEdit:addChars(s)
    -- Newline remains an immediate structural edit, after flushing any pending
    -- virtual text. Regular on-screen keys use the debounce above.
    if s == "\n" then
        self:flushTypeBuffer()
        return self:newline()
    end
    self:queueVirtualChars(s)
end
function MDEdit:newline()
    self:flushTypeBuffer()
    self:snapshot(); self._burst = nil
    self._desired_x = nil
    if self:hasSel() then self:deleteSelection() end
    local l = self.lines[self.crow]
    local before, after = l:sub(1, self.ccol), l:sub(self.ccol+1)
    local prefix = ""
    if md_split_line_prefix then
        local indent, kind, marker, task, body = md_split_line_prefix(before)
        if (kind or task) and body == "" and after == "" then
            self.lines[self.crow] = indent
            self.ccol = #indent
            return self:refresh()
        end
        if kind == "ordered" then
            local n = tonumber((marker or ""):match("^(%d+)")) or 1
            prefix = indent .. tostring(n + 1) .. ". "
        elseif kind == "bullet" then
            prefix = indent .. (marker or "- ")
        elseif task then
            prefix = indent
        end
        if task then prefix = prefix .. "[ ] " end
    end
    table.insert(self.lines, self.crow+1, prefix .. after)
    self.lines[self.crow] = before
    self.crow = self.crow + 1; self.ccol = #prefix
    self:refresh()
end
function MDEdit:delChar()
    self._desired_x = nil
    if self:hasSel() then self:snapshot(); self._burst = nil; self:deleteSelection(); return self:refresh() end
    self:edit("del")
    if self.ccol > 0 then
        local l = self.lines[self.crow]
        local prev = utf8_left(l, self.ccol)          -- delete the whole UTF-8 char to the left
        self.lines[self.crow] = l:sub(1, prev) .. l:sub(self.ccol+1)
        self.ccol = prev
        local incremental = self:updateVisualLine(self.crow)
        return self:refresh{ layout_dirty = not incremental, precise_edit = true }
    elseif self.crow > 1 then
        local prev = self.lines[self.crow-1]
        self.ccol = #prev
        self.lines[self.crow-1] = prev .. self.lines[self.crow]
        table.remove(self.lines, self.crow); self.crow = self.crow - 1
    end
    self:refresh()
end
function MDEdit:moveCursor(drow, dcol, opts)
    self._burst = nil
    if dcol ~= 0 then self._desired_x = nil end
    if dcol < 0 then
        if self.ccol <= 0 then
            if self.crow > 1 then self.crow = self.crow - 1; self.ccol = #self.lines[self.crow] end
        else self.ccol = utf8_left(self.lines[self.crow], self.ccol) end
    elseif dcol > 0 then
        if self.ccol >= #self.lines[self.crow] then
            if self.crow < #self.lines then self.crow = self.crow + 1; self.ccol = 0 end
        else self.ccol = utf8_right(self.lines[self.crow], self.ccol) end
    end
    if drow ~= 0 then
        if not self:moveCursorVisual(drow) then
            self.crow = math.max(1, math.min(#self.lines, self.crow + drow))
            self.ccol = math.min(self.ccol, #self.lines[self.crow])
        end
    end
    opts = opts or {}
    opts.layout_dirty = false
    opts.cursor_move = true
    self:refresh(opts)
end
-- VirtualKeyboard inputbox interface
function MDEdit:leftChar()  self.sel = nil; self:moveCursor(0, -1) end
function MDEdit:rightChar() self.sel = nil; self:moveCursor(0, 1) end
function MDEdit:upLine()    self.sel = nil; self:moveCursor(-1, 0) end
function MDEdit:downLine()  self.sel = nil; self:moveCursor(1, 0) end
function MDEdit:goToStartOfLine() self._desired_x = nil; self.ccol = 0; self:refresh{ layout_dirty = false, cursor_move = true } end
function MDEdit:goToEndOfLine()   self._desired_x = nil; self.ccol = #self.lines[self.crow]; self:refresh{ layout_dirty = false, cursor_move = true } end
function MDEdit:delToStartOfLine()
    self:snapshot(); self._burst = nil
    self._desired_x = nil
    local l = self.lines[self.crow]; self.lines[self.crow] = l:sub(self.ccol+1); self.ccol = 0; self:refresh()
end
function MDEdit:delWord()
    self._desired_x = nil
    if self:hasSel() then self:snapshot(); self._burst = nil; self:deleteSelection(); return self:refresh() end
    -- At the start of a line there is no word to delete on this line; fall back to
    -- delChar so a word-delete still joins with the previous line (matches every
    -- editor, and is the path the Bluetooth keyboard's backspace takes).
    if self.ccol <= 0 then return self:delChar() end
    self:snapshot(); self._burst = nil
    local l = self.lines[self.crow]
    local before = l:sub(1, prev_word_col(l, self.ccol))
    self.lines[self.crow] = before .. l:sub(self.ccol+1); self.ccol = #before; self:refresh{ precise_edit = true }
end
function MDEdit:wordLeft(selecting)
    self._burst = nil
    self._desired_x = nil
    self.ccol = prev_word_col(self.lines[self.crow], self.ccol); self:refresh{ layout_dirty = false, selection = selecting, cursor_move = true }
end
function MDEdit:wordRight(selecting)
    self._burst = nil
    self._desired_x = nil
    self.ccol = next_word_col(self.lines[self.crow], self.ccol); self:refresh{ layout_dirty = false, selection = selecting, cursor_move = true }
end
function MDEdit:scrollBy(lines)
    local old = self.vtop or 1
    local max_top = math.max(1, self.visual_count or #self.lines)
    self.vtop = math.max(1, math.min(max_top, old + lines))
    if self.vtop ~= old then
        self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    end
    self:refreshScroll()
end
function MDEdit:pageBy(direction)
    local old = self.vtop or 1
    local last = self._last_page_scroll
    local step
    if last and last.from ~= last.to and last.to == old and last.dir == -direction then
        step = math.abs(last.to - last.from)
    else
        step = self:pageStep(direction)
    end
    self:scrollBy(direction * step)
    if self.vtop ~= old then
        self._last_page_scroll = { dir = direction, from = old, to = self.vtop or old }
    else
        self._last_page_scroll = nil
    end
end
-- Page turns advance by roughly 3/4 of the visible editor height. Count
-- rendered row heights instead of visible row count so headings, gaps, and
-- tables don't distort physical scroll distance.
function MDEdit:pageStep(direction)
    local rows = self._vrows
    local start = self.vtop or 1
    if not rows or #rows == 0 then return math.max(1, math.floor((self.visible_vrows or 12) * 0.75)) end
    local target = math.max(1, math.floor((self.visible_budget or math.floor(self.fh / 2)) * 0.75))
    local step, used = 0, 0
    if (direction or 1) < 0 then
        while start - step > 1 and used < target do
            step = step + 1
            used = used + self:visualRowHeight(rows[start - step])
        end
    else
        while start + step <= #rows and used < target do
            step = step + 1
            used = used + self:visualRowHeight(rows[start + step - 1])
        end
    end
    return math.max(1, step)
end
function MDEdit:pageUp()   self:pageBy(-1) end
function MDEdit:pageDown() self:pageBy(1) end
function MDEdit:pageLeft()  self:pageUp() end
function MDEdit:pageRight() self:pageDown() end
function MDEdit:pageFromTap(pos)
    if pos and pos.x < (self.fw / 2) then self:pageLeft() else self:pageRight() end
end
function MDEdit:outlineItems()
    self:flushTypeBuffer()
    local items = {}
    for i, line in ipairs(self.lines or {}) do
        local hashes, text = tostring(line or ""):match("^(#{1,6})%s+(.-)%s*$")
        if hashes then
            local level = #hashes
            local indent = string.rep("  ", math.max(0, level - 1))
            local label = md_trim(text)
            if label ~= "" then
                items[#items+1] = {
                    text = string.format("%s%s", indent, label),
                    callback = function() self:jumpToLine(i) end,
                }
            end
        end
    end
    if #items == 0 then
        items[1] = { text = _("No headings"), select_enabled = false, dim = true }
    end
    return items
end
function MDEdit:jumpToLine(line)
    self:flushTypeBuffer()
    local target = math.max(1, math.min(tonumber(line) or 1, #self.lines))
    self.crow, self.ccol = target, 0
    self.sel, self._desired_x, self._burst = nil, nil, nil
    local vrows = self:visualRows(self:textWidth())
    local target_vi = 1
    for vi, vr in ipairs(vrows or {}) do
        if vr.line and vr.line >= target then target_vi = vi; break end
    end
    self.vtop = target_vi
    self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    self:refreshScroll()
end
-- ---- find ---------------------------------------------------------------
-- Find deliberately uses the editor selection for the active result. This
-- makes the match visible in both the styled editor and reader mode, and keeps
-- copy/keyboard behaviour consistent with a normal text selection.
function MDEdit:findMatches(query)
    if not query or query == "" then return {} end
    local needle = query:lower()
    local matches = {}
    for row, line in ipairs(self.lines or {}) do
        local haystack = tostring(line or ""):lower()
        local from = 1
        while true do
            local first, last = haystack:find(needle, from, true)
            if not first then break end
            matches[#matches + 1] = { row = row, start_col = first - 1, end_col = last }
            from = last + 1 -- non-overlapping results, like standard Find
        end
    end
    return matches
end
function MDEdit:showFindMatch(match, index, total)
    if not match then return false end
    self._find_match = match
    self._find_match_index = index
    self.sel = { row = match.row, col = match.start_col }
    self.crow, self.ccol = match.row, match.end_col
    self._desired_x, self._burst = nil, nil
    local target_vi = 1
    for vi, row in ipairs(self:visualRows(self:textWidth()) or {}) do
        local text_row = row.row or {}
        local row_end = text_row.sb or 0
        for _, seg in ipairs(text_row.segs or {}) do row_end = math.max(row_end, (seg.sb or 0) + #(seg.text or "")) end
        if row.line == match.row and (text_row.sb or 0) <= match.start_col and row_end >= match.start_col then
            target_vi = vi
            break
        end
    end
    self.vtop = target_vi
    self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    self:refresh{ layout_dirty = false, selection = true }
    notify(string.format(_("Match %d of %d"), index, total))
    return true
end
function MDEdit:findNext(query, direction)
    self:flushTypeBuffer()
    query = query or self._find_query or ""
    if query == "" then notify(_("Enter text to find")); return false end
    self._find_query = query
    self._find_bar_visible = true
    local matches = self:findMatches(query)
    if #matches == 0 then
        self._find_match, self._find_match_index = nil, nil
        self:refresh{ layout_dirty = false, full = true }
        notify(_("No matches"))
        return false
    end
    direction = direction or 1
    local current = self._find_match_index
    local active = self._find_match
    if not (active and active.row == self.crow and active.end_col == self.ccol
        and self.sel and self.sel.row == active.row and self.sel.col == active.start_col) then
        current = nil
    end
    if current and matches[current]
        and matches[current].row == active.row and matches[current].start_col == active.start_col then
        current = ((current - 1 + direction) % #matches) + 1
    elseif direction > 0 then
        current = 1
        for i, match in ipairs(matches) do
            if match.row > self.crow or (match.row == self.crow and match.start_col >= self.ccol) then
                current = i
                break
            end
        end
    else
        current = #matches
        for i = #matches, 1, -1 do
            local match = matches[i]
            if match.row < self.crow or (match.row == self.crow and match.end_col <= self.ccol) then
                current = i
                break
            end
        end
    end
    local index = current
    return self:showFindMatch(matches[index], index, #matches)
end
function MDEdit:goToFindMatch()
    local matches = self:findMatches(self._find_query)
    local index = self._find_match_index
    if index and matches[index] then return self:showFindMatch(matches[index], index, #matches) end
    return self:findNext(self._find_query, 1)
end
function MDEdit:openFindDialog()
    self:flushTypeBuffer()
    if self._find_dialog then return end
    if self.keyboard then self:hideKeyboard() end
    local initial = self._find_query or (self:hasSel() and self:selText()) or ""
    local dlg
    local restored = false
    local function restore_focus()
        if restored then return end
        restored = true
        self._find_dialog = nil
        self.is_always_active = true
        self:refresh{ layout_dirty = false, full = true }
    end
    local function close_then(action)
        local query = dlg:getInputText() or ""
        UIManager:close(dlg)
        if action then action(query) end
    end
    dlg = InputDialog:new{
        title = _("Find"),
        input = initial,
        buttons = {
            {
                { text = _("Cancel"), callback = function() close_then() end },
                { text = _("Previous"), callback = function() close_then(function(q) self:findNext(q, -1) end) end },
            },
            {
                { text = _("Next"), is_enter_default = true, callback = function() close_then(function(q) self:findNext(q, 1) end) end },
                { text = _("Go to match"), callback = function() close_then(function(q)
                    self._find_query = q
                    self._find_bar_visible = true
                    self:goToFindMatch()
                end) end },
            },
        },
    }
    self._find_dialog = dlg
    self.is_always_active = false
    local original_close = dlg.onCloseWidget
    function dlg:onCloseWidget()
        if original_close then original_close(self) end
        restore_focus()
    end
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end
function MDEdit:setReaderMode(enabled, target_row, target_col)
    enabled = not not enabled
    if self.reader_mode == enabled then return end
    self.reader_mode = enabled
    self._pan_mode = nil
    self._last_tap = nil
    self._desired_x = nil
    self.sel = nil
    if enabled then
        if self.keyboard then self:hideKeyboard() end
        self.caret_on = false
        notify(_("Reader mode: tap Edit to return"))
    else
        local trow = target_row or self.top
        self.crow = math.max(1, math.min(#self.lines, trow))
        self.ccol = math.max(0, math.min(target_col or self.ccol or 0, #(self.lines[self.crow] or "")))
        self.caret_on = true
        notify(_("Editing mode"))
    end
    -- The top bar itself changes on a mode switch (formatting tools <-> "Edit"),
    -- so force a full repaint; the partial-region paths only cover the text body
    -- and would leave a stale toolbar when the keyboard is hidden.
    self:refresh{ full = true }
end
function MDEdit:onSwitchingKeyboardLayout() end
function MDEdit:showKeyboard()
    if self.reader_mode then return end
    if self.keyboard then return end
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local keyboard = VirtualKeyboard:new{ inputbox = self }
    MinfolioPair.makeKeyboardArrowFree(keyboard)
    MinfolioPair.disableKeyboardKeyFlash(keyboard)
    keyboard.modal = false
    self.keyboard = keyboard
    local editor = self
    local original_close = keyboard.onCloseWidget
    function keyboard:onCloseWidget()
        if original_close then original_close(self) end
        if editor.keyboard == self then
            editor.keyboard = nil
            if editor._caret_blinking then
                editor:refresh{ layout_dirty = false, full = true }
            end
        end
    end
    self:refresh{ layout_dirty = false, full = true }
    UIManager:show(keyboard)
end

function MDEdit:isPointInKeyboard(pos)
    if not self.keyboard or not pos then return false end
    local dimen = self.keyboard.dimen
    local top = dimen and dimen.y or (self.fh - ((dimen and dimen.h) or math.floor(self.fh * 0.36)))
    return pos.y >= top
end
function MDEdit:hideKeyboard()
    if not self.keyboard then return end
    local keyboard = self.keyboard
    self.keyboard = nil
    UIManager:close(keyboard)
    self:refresh{ layout_dirty = false, full = true }
end
function MDEdit:isKeyboardRevealGesture(ges)
    if self.reader_mode or self.keyboard then return false end
    local p = ges and ges.pos
    local sp = ges and ges.start_pos or p
    if not p or not sp then return false end
    local x = sp.x or p.x
    local bottom_y = math.max(sp.y or 0, p.y or 0)
    local dy = (p.y or 0) - (sp.y or 0)
    local center = x >= self.fw * 0.36 and x <= self.fw * 0.64
    local from_bottom = bottom_y >= self.fh - MDEDIT_KEYBOARD_SWIPE_EDGE
    local upward = (ges.direction == "north") or dy <= -MDEDIT_KEYBOARD_SWIPE_DY
    return center and from_bottom and upward
end
-- Inverse of the reveal gesture: a downward swipe that STARTS just above the
-- keyboard's top edge hides it. The keyboard's own keys swallow swipes, so the
-- gesture has to begin in the text area (which the editor reliably receives),
-- right where the text meets the keyboard -- a deliberate "push it down" motion.
function MDEdit:isKeyboardHideGesture(ges)
    if not self.keyboard then return false end
    local p = ges and ges.pos
    local sp = ges and ges.start_pos or p
    if not p or not sp then return false end
    local kbd_h = (self.keyboard.dimen and self.keyboard.dimen.h) or math.floor(self.fh * 0.36)
    local kbd_top = self.fh - kbd_h
    local start_y = sp.y or p.y or 0
    local dx = (p.x or 0) - (sp.x or 0)
    local dy = (p.y or 0) - (sp.y or 0)
    -- Start within the strip just above the keyboard (in the text area, so we get
    -- the event), then move clearly downward.  KOReader can label a diagonal or
    -- even mostly horizontal select-drag as "south", so do not trust its
    -- direction field without checking the actual displacement.
    local near_kbd_top = start_y >= kbd_top - MDEDIT_KEYBOARD_SWIPE_EDGE and start_y <= kbd_top
    local downward = dy >= MDEDIT_KEYBOARD_SWIPE_DY and math.abs(dy) >= math.abs(dx) * 1.25
    return near_kbd_top and downward
end
function MDEdit:save()
    self:flushTypeBuffer()
    local text = self:currentText()
    local out = io.open(self.path, "w")
    if out then
        out:write(text)
        out:close()
        self._dirty = false
        self._file_text = text
        self._file_signature = file_signature(self.path)
        if self.remote then write_file(self.remote.outbox_path, text) end
        self._external_change_prompted = nil
        self._autosave_paused_for_external = nil
        if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
        return true
    end
    return false
end
-- Handles both the app's own Rotate screen action and any generic resize;
-- rotate_screen_ccw() has already applied Screen:setRotationMode by the time
-- this runs, so this only needs to reflow the editor at the new dimensions.
function MDEdit:onScreenResize()
    self.fw, self.fh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh }
    if self.ges_events then
        for _, ev in pairs(self.ges_events) do
            for _, range in ipairs(ev) do range.range = self.dimen end
        end
    end
    self._wcache, self._hcache = {}, {}
    if self._wrap_cache then
        for _, entry in pairs(self._wrap_cache) do free_wrap_entry(entry) end
    end
    self._wrap_cache = nil
    self:refresh{ layout_dirty = true, full = true }
    return true
end
function MDEdit:onResume()
    MinfolioPair.trace("editor-resume", "path=", tostring(self.path))
    self:checkExternalFile()
    self.caret_on = true
    self:refresh{ layout_dirty = false, full = true }
    FL.scheduleWakeSync()
    schedule_wake_repaint()
end
function MDEdit:onSuspend()
    MinfolioPair.trace("editor-suspend", "path=", tostring(self.path))
    FL.captureBeforeSuspend()
end
function MDEdit:schedulePhysicalKeyboardRepaint()
    if self._physical_keyboard_repaint_pending then
        UIManager:unschedule(self._physical_keyboard_repaint_pending)
        self._physical_keyboard_repaint_pending = nil
    end
    local fn
    fn = function()
        if self._physical_keyboard_repaint_pending == fn then
            self._physical_keyboard_repaint_pending = nil
        end
        if self._closing then return end
        -- externalkeyboard shows a one-second modal notice, then broadcasts this
        -- event halfway through its lifetime. Repaint after that notice is gone;
        -- an arrow key in the meantime must not be the final, caret-only refresh.
        self:refresh{ layout_dirty = false, full = true }
    end
    self._physical_keyboard_repaint_pending = fn
    UIManager:scheduleIn(0.65, fn)
end
-- A Bluetooth/USB keyboard attaching or detaching repaints chrome (and can close
-- the on-screen keyboard) outside our control, leaving the screen half-blank.
-- With a physical keyboard there is no need for the on-screen one, so hide it;
-- either way force a full repaint so nothing is left stale. Return nothing so the
-- broadcast keeps propagating to other widgets.
function MDEdit:onPhysicalKeyboardConnected()
    -- The external-keyboard plugin rebuilds Device.input.event_map from scratch on
    -- attach (and re-inits input events), wiping our key aliases -- Fn/page keys,
    -- symbol keys, modifier flags. Re-apply them so e.g. Fn+Down keeps paging.
    install_keyboard_aliases()
    if self.keyboard then
        self:hideKeyboard()             -- hideKeyboard already does a full repaint
    else
        self:refresh{ layout_dirty = false, full = true }
    end
    self:schedulePhysicalKeyboardRepaint()
end
function MDEdit:onPhysicalKeyboardDisconnected()
    self:refresh{ layout_dirty = false, full = true }
    self:schedulePhysicalKeyboardRepaint()
end
function MDEdit:saveAndClose()
    self:save()
    local keyboard = self.keyboard
    self.keyboard = nil
    if keyboard then UIManager:close(keyboard) end
    UIManager:close(self)
    if self.on_close then self.on_close() end
end
function MDEdit:saveAndOpenMarkdown()
    self:save()
    local keyboard = self.keyboard
    self.keyboard = nil
    if keyboard then UIManager:close(keyboard) end
    UIManager:close(self)
    if open_markdown_picker then open_markdown_picker(path_parent(self.path)) end
end
function MDEdit:onCloseWidget()
    MinfolioPair.trace("editor-close", "path=", tostring(self.path), "dirty=", self._dirty and "yes" or "no")
    self._closing = true
    -- Flush before signalling the worker. The old ordering removed the shadow
    -- first, then autosave recreated it, leaving an orphaned remote session.
    self:flushTypeBuffer()
    self:flushAutosave()
    self:savePosition()
    if self.remote then
        write_file(self.remote.closing_path, "1")
        -- `remote-session.lua` is a shared handoff owned by the desktop
        -- launcher.  A successor session may already have replaced it while
        -- this editor is closing; deleting it here races that launch and can
        -- leave the new worker/editor with no descriptor. The per-session
        -- `closing` marker is the only state this editor owns.
    end
    if active_mdedit == self then active_mdedit = nil end
    self._caret_blinking = false
    if self._caret_blink_pending then
        UIManager:unschedule(self._caret_blink_pending)
        self._caret_blink_pending = nil
    end
    if self._file_poll_pending then UIManager:unschedule(self._file_poll_pending); self._file_poll_pending = nil end
    if self._heartbeat_pending then UIManager:unschedule(self._heartbeat_pending); self._heartbeat_pending = nil end
    if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
    if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
    if self._physical_keyboard_repaint_pending then
        UIManager:unschedule(self._physical_keyboard_repaint_pending)
        self._physical_keyboard_repaint_pending = nil
    end
    if Device.input and self._old_disable_double_tap ~= nil then
        Device.input.disable_double_tap = self._old_disable_double_tap
    end
    -- Free every cached row's native TextWidget buffers, not just the ones
    -- currently on screen (UIManager's own close-time free only reaches the
    -- visible tree); off-screen rows are only reachable through this cache.
    if self._wrap_cache then
        for _, entry in pairs(self._wrap_cache) do free_wrap_entry(entry) end
        self._wrap_cache = nil
    end
end
function MDEdit:onKeyPress(key)
    local name = key and key.key
    if not name then return true end
    local m = key_mods(key)
    if shortcut_mod(m) and name:lower() == "f" then
        self:openFindDialog()
        return true
    end
    if self.reader_mode then
        if left_key(name) or up_key(name) or page_up_key(name) then self:pageLeft()
        elseif right_key(name) or down_key(name) or name == "Space" or name == "space" or name == " "
            or name == "Press" or name == "Return" or name == "Enter" or name == "KP_Enter"
            or page_down_key(name) then self:pageRight()
        end
        return true
    end
    local lname = name:lower()
    if shortcut_mod(m) and #name == 1 then
        self:flushTypeBuffer()
        if lname == "z" then if keymod(m, "Shift") then self:redo() else self:undo() end; return true
        elseif lname == "y" then self:redo(); return true
        elseif lname == "c" then self:copy(); return true
        elseif lname == "x" then self:cut(); return true
        elseif lname == "v" then self:paste(); return true
        elseif lname == "a" then self:selectAll(); return true end
    end
    if name == "Backspace" or name == "BackSpace" or name == "Del" or name == "Delete" then
        self:flushTypeBuffer()
        if word_key_mod(m) then self:delWord() else self:delChar() end
    elseif name == "Press" or name == "Return" or name == "Enter" or name == "KP_Enter" then self:newline()
    elseif fn_key_mod(m) and up_key(name) then self:flushTypeBuffer(); self.sel = nil; self:pageUp()
    elseif fn_key_mod(m) and down_key(name) then self:flushTypeBuffer(); self.sel = nil; self:pageDown()
    elseif left_key(name)  then self:arrow(0, -1, m)
    elseif right_key(name) then self:arrow(0, 1, m)
    elseif up_key(name)    then self:arrow(-1, 0, m)
    elseif down_key(name)  then self:arrow(1, 0, m)
    elseif page_up_key(name) then self:flushTypeBuffer(); self.sel = nil; self:pageUp()
    elseif page_down_key(name) then self:flushTypeBuffer(); self.sel = nil; self:pageDown()
    elseif name == "Space" or name == "space" or name == " " then if keymod(m, "Alt") then self:flushTypeBuffer(); self.sel = nil; self:wordRight() else self:queueTypedChar(" ") end
    elseif name == "ISO_Left_Tab" or name == "BackTab" then self:flushTypeBuffer(); self:indentLine(-1)
    elseif name == "Tab" then
        self:flushTypeBuffer()
        if keymod(m, "Shift") then self:indentLine(-1)
        else
            local _, kind, _, task = md_split_line_prefix(self.lines[self.crow])
            if kind or task then self:indentLine(1) else self:addChars("  ") end
        end
    elseif name == "Home" then self:flushTypeBuffer(); self:goToStartOfLine()
    elseif name == "End" then self:flushTypeBuffer(); self:goToEndOfLine()
    elseif KEYPAD_CHAR[name] then self:queueTypedChar(KEYPAD_CHAR[name])
    elseif #name == 1 then
        if keymod(m, "Alt") then return true end
        local ch = lname
        if keymod(m, "Shift") then
            if SHIFT_SYM[ch] then ch = SHIFT_SYM[ch] elseif ch:match("%a") then ch = ch:upper() end
        end
        self:queueTypedChar(ch)
    end
    return true
end
function MDEdit:onHold()
    if self.reader_mode then return true end
    -- A text-selection drag can briefly be classified as a hold before its pan
    -- events arrive. Keyboard visibility must not change during that gesture;
    -- use the deliberate downward swipe or the menu action to hide it instead.
    return true
end
function MDEdit:onSwipe(_, ges)
    -- A fast finger-lift after a reader-mode select comes through as a swipe
    -- rather than pan_release; commit the highlight here too so a quick drag works.
    if self._pan_mode == "rselect" then
        self._pan_mode = nil
        self:commitHighlightFromSelection()
        return true
    end
    -- Do not create or close the keyboard until this swipe has ended. Showing it
    -- from onPan places a new keyboard underneath the finger still performing
    -- the gesture, so its trailing touch-up can be interpreted as a key press.
    if self._pan_mode == "keyboard_reveal" then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active, self._pan_paged, self._pan_mode = nil, nil, nil
        self:showKeyboard()
        return true
    end
    if self._pan_mode == "keyboard_hide" then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active, self._pan_paged, self._pan_mode = nil, nil, nil
        self:hideKeyboard()
        return true
    end
    if self._pan_mode == "select" then self._pan_mode = nil; return true end
    if self:isKeyboardRevealGesture(ges) then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active = nil
        self._pan_paged = nil
        self._pan_mode = nil
        self:showKeyboard()
        return true
    end
    if self:isKeyboardHideGesture(ges) then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active = nil
        self._pan_paged = nil
        self._pan_mode = nil
        self:hideKeyboard()
        return true
    end
    -- Paging is handled in onPan, so swipes only clear the current gesture mode.
    -- Do not hide the keyboard on arbitrary south swipes (accidental ones are
    -- common while editing); the deliberate hide gesture above handles it.
    if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
    self._pan_active = nil
    self._pan_paged = nil
    self._pan_mode = nil
    return true
end
function MDEdit:bumpScale(d)
    self.scale = clamp_minfolio_scale(self.scale + d)
    MINFOLIO_STATE.scale = self.scale
    save_minfolio_state()
    self._wcache = {}; self._hcache = {}
    if self._wrap_cache then
        for _, entry in pairs(self._wrap_cache) do free_wrap_entry(entry) end
    end
    self._wrap_cache = nil          -- scale changes wrapping/heights; drop the per-line cache
    self:refresh()
end
function MDEdit:fmtWrap(mk)          -- wrap selection (or the cursor) in markers
    self:snapshot(); self._burst = nil
    if self:hasSel() then
        local lr, lc, hr, hc = self:selRange()
        if lr == hr then                -- wrap a single-line selection
            local l = self.lines[lr]
            self.lines[lr] = l:sub(1, lc) .. mk .. l:sub(lc+1, hc) .. mk .. l:sub(hc+1)
            self.crow = lr; self.ccol = hc + 2*#mk; self.sel = nil
            return self:refresh()
        end
    end
    local wl, wh = self:currentWordRange()
    if wl and wh then
        local l = self.lines[self.crow]
        self.lines[self.crow] = l:sub(1, wl) .. mk .. l:sub(wl+1, wh) .. mk .. l:sub(wh+1)
        self.ccol = wh + 2 * #mk
        return self:refresh()
    end
    local l = self.lines[self.crow]
    self.lines[self.crow] = l:sub(1, self.ccol) .. mk .. mk .. l:sub(self.ccol+1)
    self.ccol = self.ccol + #mk; self:refresh()
end
md_split_line_prefix = function(line)
    local indent, rest = line:match("^(%s*)(.*)$")
    local marker, body = rest:match("^([%-%*%+]%s+)(.*)$")
    local kind = marker and "bullet" or nil
    if not marker then
        marker, body = rest:match("^(%d+%.%s+)(.*)$")
        kind = marker and "ordered" or nil
    end
    body = body or rest
    local task, task_body = body:match("^(%[[ xX]%]%s+)(.*)$")
    if task then body = task_body end
    return indent or "", kind, marker, task, body
end
function MDEdit:setLinePrefix(kind, want_task)
    self:snapshot(); self._burst = nil
    local line = self.lines[self.crow]
    local indent, old_kind, marker, task, body = md_split_line_prefix(line)
    local old_prefix = indent .. (marker or "") .. (task or "")
    local new_marker = marker or ""
    if kind == "bullet" then
        new_marker = old_kind == "bullet" and "" or "- "
    elseif kind == "ordered" then
        new_marker = old_kind == "ordered" and "" or "1. "
    end
    local new_task = task or ""
    if want_task ~= nil then new_task = want_task and "[ ] " or "" end
    local new_prefix = indent .. new_marker .. new_task
    self.lines[self.crow] = new_prefix .. body
    self.ccol = math.max(0, self.ccol + #new_prefix - #old_prefix)
    self:refresh()
end
-- Indent (dir > 0) or outdent (dir < 0) the current logical line by one level
-- (INDENT_UNIT). Nesting is stored as leading whitespace; layoutLine turns it
-- into visual indent. Returns true if the line changed.
function MDEdit:indentLine(dir)
    local INDENT_UNIT = "  "
    local line = self.lines[self.crow]
    local indent, rest = line:match("^(%s*)(.*)$")
    local new_indent
    if dir > 0 then
        new_indent = INDENT_UNIT .. indent
    elseif indent:sub(1, #INDENT_UNIT) == INDENT_UNIT then
        new_indent = indent:sub(#INDENT_UNIT + 1)
    elseif #indent > 0 then
        new_indent = ""                       -- collapse a stray partial indent
    else
        return false                          -- already at column 0, nothing to do
    end
    self:snapshot(); self._burst = nil
    local newline = new_indent .. rest
    self.lines[self.crow] = newline
    self.ccol = math.max(0, math.min(#newline, self.ccol + (#newline - #line)))
    self:refresh()
    return true
end
function MDEdit:fmtToggle(findpat, prefix)  -- remove existing line prefix, else add it
    self:snapshot(); self._burst = nil
    local l = self.lines[self.crow]
    local pre = l:match(findpat)
    if pre then self.lines[self.crow] = l:sub(#pre+1); self.ccol = math.max(0, self.ccol - #pre)
    else self.lines[self.crow] = prefix .. l; self.ccol = self.ccol + #prefix end
    self:refresh()
end
function MDEdit:fmtHeader() self:fmtToggle("^(#+%s)", "# ") end
function MDEdit:fmtList()   self:setLinePrefix("bullet") end
function MDEdit:fmtOrdered() self:setLinePrefix("ordered") end
function MDEdit:fmtTask()
    local _, kind, _, task = md_split_line_prefix(self.lines[self.crow])
    if task then
        self:setLinePrefix(nil, false)
    else
        self:setLinePrefix(kind and nil or "bullet", true)
    end
end
function MDEdit:insertTable()
    self:snapshot(); self._burst = nil
    if self:hasSel() then self:deleteSelection() end
    local rows = { "| Column 1 | Column 2 |", "|---|---|", "|  |  |" }
    local l = self.lines[self.crow] or ""
    local before, after = l:sub(1, self.ccol), l:sub(self.ccol + 1)
    local body_row
    if before == "" and after == "" then
        self.lines[self.crow] = rows[1]
        for i = 2, #rows do table.insert(self.lines, self.crow + i - 1, rows[i]) end
        body_row = self.crow + 2
    else
        self.lines[self.crow] = before
        local insert_at = self.crow
        for _, row in ipairs(rows) do
            insert_at = insert_at + 1
            table.insert(self.lines, insert_at, row)
        end
        if after ~= "" then table.insert(self.lines, insert_at + 1, after) end
        body_row = self.crow + 3
    end
    self.crow = math.min(#self.lines, body_row)
    self.ccol = math.min(2, #(self.lines[self.crow] or ""))
    self:refresh()
end
function MDEdit:openMindmap()
    self:save()
    if self.keyboard then self:hideKeyboard() end
    local map = MindmapView:new{ editor = self }
    UIManager:show(map, "full")
end
function MDEdit:runTopAction(name)
    if name == "find_input" then self:openFindDialog()
    elseif name == "find_previous" then self:findNext(self._find_query, -1)
    elseif name == "find_next" then self:findNext(self._find_query, 1)
    elseif name == "find_done" then
        self._find_bar_visible = nil
        self._topbar_cache = nil
        self:refresh{ layout_dirty = false, full = true }
    elseif name == "menu" then self:openControls()
    elseif name == "edit" then self:setReaderMode(false)
    elseif self.reader_mode and name == "close" then self:saveAndClose()
    elseif self.reader_mode then return
    elseif name == "header" then self:fmtHeader()
    elseif name == "bold" then self:fmtWrap("**")
    elseif name == "italic" then self:fmtWrap("*")
    elseif name == "list" then self:fmtList()
    elseif name == "ordered" then self:fmtOrdered()
    elseif name == "task" then self:fmtTask()
    elseif name == "mindmap" then self:openMindmap()
    elseif name == "reader" then self:setReaderMode(true)
    elseif name == "table" then self:insertTable()
    elseif name == "smaller" then self:bumpScale(-0.1)
    elseif name == "larger" then self:bumpScale(0.1)
    elseif name == "close" then self:saveAndClose()
    end
end
function MDEdit:openControls()
    if self.reader_mode then
        show_controls({
            { text = "Find...", callback = function() self:openFindDialog() end },
            { text = "Outline", sub_item_table_func = function() return self:outlineItems() end },
            { text = "Exit reader mode", callback = function() self:setReaderMode(false) end },
            { text = "⟲ Rotate screen", callback = function() rotate_screen_ccw() end },
            { text = "Save & close note", callback = function() self:saveAndClose() end },
        })
        return
    end
    local keyboard_item
    if self.keyboard then
        keyboard_item = { text = "Hide keyboard", callback = function() self:hideKeyboard() end }
    else
        keyboard_item = { text = "Show keyboard", callback = function() self:showKeyboard() end }
    end
    show_controls({
        { text = "Find...", callback = function() self:openFindDialog() end },
        { text = "Outline", sub_item_table_func = function() return self:outlineItems() end },
        { text = "Mindmap mode", callback = function() self:openMindmap() end },
        { text = "Reader mode", callback = function() self:setReaderMode(true) end },
        keyboard_item,
        { text = "Heading", callback = function() self:fmtHeader() end },
        { text = "Bold", callback = function() self:fmtWrap("**") end },
        { text = "Italic", callback = function() self:fmtWrap("*") end },
        { text = "List item", callback = function() self:fmtList() end },
        { text = "Numbered list", callback = function() self:fmtOrdered() end },
        { text = "Checkbox", callback = function() self:fmtTask() end },
        { text = "Table", callback = function() self:insertTable() end },
        { text = "Text size +", callback = function() self:bumpScale(0.1) end },
        { text = "Text size -", callback = function() self:bumpScale(-0.1) end },
        { text = "Select all", callback = function() self:selectAll() end },
        { text = "Copy",  callback = function() self:copy() end },
        { text = "Cut",   callback = function() self:cut() end },
        { text = "Paste", callback = function() self:paste() end },
        { text = "Undo",  callback = function() self:undo() end },
        { text = "Redo",  callback = function() self:redo() end },
        { text = "⟲ Rotate screen", callback = function() rotate_screen_ccw() end },
        { text = "Open .md file...", callback = function() self:saveAndOpenMarkdown() end },
        { text = "Save & close note", callback = function() self:saveAndClose() end },
    })
end
function MDEdit:onTap(_, ges)
    local p = ges.pos
    if not p then return true end
    if self._pan_mode or self._pan_paged then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active = nil
        self._pan_paged = nil
        self._pan_mode = nil
        self._last_tap = nil
        return true
    end
    self._pan_mode = nil
    -- The native keyboard is non-modal so editor controls remain reachable.
    -- Never let a key tap also fall through to the document underneath it.
    if self:isPointInKeyboard(p) then return true end
    if p.y < 95 then                                          -- top bar
        local x = p.x - MDEDIT_PAD
        for name, z in pairs(self.top_zones or {}) do
            if x >= z.x0 and x < z.x1 then self:runTopAction(name); return true end
        end
        return true
    end
    if self.reader_mode then
        -- Tapping on an existing highlight removes it (checked before the edge
        -- page-turn zones, so a highlight near a screen edge still deletes).
        if p.y >= 95 then
            local hrow, hcol = self:pointToCursor(p)
            if self:highlightRangeAt(hrow, hcol) then
                if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
                self._rtap = nil
                self:snapshot(); self._burst = nil
                self:removeHighlightAt(hrow, hcol)
                self:save()
                self:refresh{ lines = { hrow, hrow } }
                return true
            end
        end
        -- Taps near the L/R/bottom edge are page-turns (likely scrolling), never
        -- an exit gesture -- page immediately, no double-tap delay.
        if p.x < MDEDIT_READER_EDGE or p.x > self.fw - MDEDIT_READER_EDGE
            or p.y > self.fh - MDEDIT_READER_EDGE then
            self._rtap = nil
            if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
            self:pageFromTap(p)
            return true
        end
        local table_hit = self:tableCellAtPos(p)
        if table_hit then
            self:openTableCellEditor(table_hit)
            return true
        end
        local now = now_seconds()
        if self._rtap and now - self._rtap.t < MDEDIT_READER_DTAP
            and math.abs(p.x - self._rtap.x) < 40 and math.abs(p.y - self._rtap.y) < 40 then
            -- fast double tap: cancel the pending page turn, drop into edit mode
            -- with the cursor placed where the user tapped.
            self._rtap = nil
            if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
            local row, col = self:pointToCursor(p)
            self:setReaderMode(false, row, col)
            return true
        end
        self._rtap = { t = now, x = p.x, y = p.y }
        if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
        local pos = { x = p.x, y = p.y }
        local fn
        fn = function()
            if self._page_pending == fn then self._page_pending = nil end
            self:pageFromTap(pos)
        end
        self._page_pending = fn
        UIManager:scheduleIn(MDEDIT_READER_DTAP, fn)
        return true
    end
    -- Tables render as tables in edit mode too, so a tap on a cell edits that
    -- cell (rather than trying to drop a text caret into a rendered table).
    local table_hit = self:tableCellAtPos(p)
    if table_hit then
        self:openTableCellEditor(table_hit)
        return true
    end
    local now = now_seconds()
    local tap_row, tap_col = self:pointToCursor(p)
    if self._last_tap and now - self._last_tap.t < MDEDIT_EDIT_DTAP
        and math.abs(p.x - self._last_tap.x) < MDEDIT_EDIT_DTAP_MOVE
        and math.abs(p.y - self._last_tap.y) < MDEDIT_EDIT_DTAP_MOVE
        and tap_row == self._last_tap.row
        and tap_col == self._last_tap.col then
        self._last_tap = nil
        self:selectWordAt(p)
        return true
    end
    self._last_tap = { t = now, x = p.x, y = p.y, row = tap_row, col = tap_col }
    self.crow, self.ccol = tap_row, tap_col
    self._desired_x = nil
    self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    self.sel = nil; self:refresh{ layout_dirty = false, cursor_move = true }
    return true
end
function MDEdit:onDoubleTap(_, ges)
    -- Backup path: only reached if KOReader's double_tap is somehow active
    -- (we normally disable it and detect double-taps in onTap).
    self._pan_mode = nil
    if self.reader_mode then
        local p = ges.pos
        if p and p.y >= 95 and p.x >= MDEDIT_READER_EDGE and p.x <= self.fw - MDEDIT_READER_EDGE
            and p.y <= self.fh - MDEDIT_READER_EDGE then
            local table_hit = self:tableCellAtPos(p)
            if table_hit then
                self:openTableCellEditor(table_hit)
                return true
            end
            local row, col = self:pointToCursor(p)
            self:setReaderMode(false, row, col)
        end
        return true
    end
    if ges.pos and ges.pos.y >= 95 then self:selectWordAt(ges.pos) end
    return true
end
function MDEdit:onPan(_, ges)
    local p = ges.pos
    local sp = ges.start_pos
    if not sp and p then
        if self._pan_active and self._pan_start_x and self._pan_start_y then
            sp = { x = self._pan_start_x, y = self._pan_start_y }
        else
            sp = p
        end
    end
    if not p or not sp or sp.y < 95 then return true end
    if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
    local reset
    reset = function()
        if self._pan_reset == reset then
            self._pan_reset = nil
            if self.reader_mode and self._pan_mode == "rselect" then
                self._pan_active = nil
                self._pan_paged = nil
                self._pan_mode = nil
                self:commitHighlightFromSelection()
                return
            end
            -- Keep a selection mode latched until the finger is released:
            -- otherwise a later pan update can be reclassified as vertical and
            -- turn the selection gesture into a page scroll.
            if not self.reader_mode and self._pan_mode == "select" then return end
            self._pan_active = nil
            self._pan_paged = nil
            self._pan_mode = nil
        end
    end
    self._pan_reset = reset
    UIManager:scheduleIn(self.reader_mode and 1.25 or 0.35, reset)
    local is_new_pan = not self._pan_active
        or (ges.start_pos and self._pan_start_x
            and (math.abs(sp.x - self._pan_start_x) > 2 or math.abs(sp.y - self._pan_start_y) > 2))
    -- KOReader occasionally reports a slightly different start_pos while the
    -- same finger is still dragging. Once a drag has become a text selection,
    -- that must never reset its mode until release: a reset lets the next
    -- vertical sample take the scroll branch.
    if is_new_pan and self._pan_mode ~= "select" then
        self._pan_active = true
        self._pan_start_x, self._pan_start_y = sp.x, sp.y
        self._pan_mode, self._pan_last_y, self._pan_paged = nil, sp.y, false
    end
    if self.reader_mode then
        local dx, dy = p.x - sp.x, p.y - sp.y
        local adx, ady = math.abs(dx), math.abs(dy)
        -- Already committed this drag to selecting: extend the selection to the
        -- finger, following it across lines. Vertical motion no longer pages here
        -- (the mode is latched), which is what lets a highlight span multiple lines.
        if self._pan_mode == "rselect" then
            local row, col = self:pointToCursor(p)
            self.crow, self.ccol = row, col
            self._manual_scroll_cursor = { row = row, col = col }
            self:refresh{ layout_dirty = false, selection = true }
            return true
        end
        if self._pan_mode == "rpage" then return true end
        if not self._pan_mode then
            if math.max(adx, ady) < MDEDIT_SELECT_PAN_MIN then return true end
            if adx >= ady * 1.2 then
                -- Horizontal-dominant start -> select text (to become a highlight).
                self._pan_mode = "rselect"
                local sr, sc = self:pointToCursor(sp)
                self.sel = { row = sr, col = sc }
                local row, col = self:pointToCursor(p)
                self.crow, self.ccol = row, col
                self._manual_scroll_cursor = { row = row, col = col }
                self:refresh{ layout_dirty = false, selection = true }
            else
                -- Vertical-dominant start -> page (one turn per drag, then latch).
                self._pan_mode = "rpage"
                self.sel = nil
                if not self._pan_paged and ady >= MDEDIT_PAGE_PAN_MIN then
                    self._pan_paged = true
                    if dy < 0 then self:pageDown() else self:pageUp() end
                end
            end
        end
        return true
    end
    local dx, dy = p.x - sp.x, p.y - sp.y
    local adx, ady = math.abs(dx), math.abs(dy)
    if self._pan_mode == "keyboard" then return true end
    if self:isKeyboardRevealGesture(ges) then
        self._pan_mode = "keyboard_reveal"
        self._pan_paged = true
        return true
    end
    if self:isKeyboardHideGesture(ges) then
        self._pan_mode = "keyboard_hide"
        self._pan_paged = true
        return true
    end
    if not self._pan_mode then
        if math.max(adx, ady) < MDEDIT_SELECT_PAN_MIN then return true end
        if adx >= ady * 1.2 then
            self._pan_mode = "select"
            local sr, sc = self:pointToCursor(sp)
            self.sel = { row = sr, col = sc }
        elseif ady >= MDEDIT_EDIT_SCROLL_PAN_MIN then
            self._pan_mode = "scroll"
            self.sel = nil
        else
            return true
        end
    end
    if self._pan_mode == "scroll" then
        -- One page turn per drag, then latch until the finger lifts.
        if not self._pan_paged then
            self._pan_paged = true
            if dy < 0 then self:pageDown() else self:pageUp() end
        end
        return true
    end
    local row, col = self:pointToCursor(p)
    self.crow, self.ccol = row, col
    -- The finger is placing the cursor, so pin the viewport to it (same as a tap):
    -- without this, rebuild() auto-scrolls to chase the cursor whenever the drag
    -- crosses onto an off-screen or partially-visible line. Next to a tall table
    -- that scroll is a full page jump, so a select-drag near a table reads as the
    -- page navigating up or down depending on which side of the fold the line sits.
    self._manual_scroll_cursor = { row = row, col = col }
    self:refresh{ layout_dirty = false, selection = true }
    return true
end
-- Finger lifted after a (slow) pan. In reader mode this ends a text selection, so
-- turn whatever was selected into a ==highlight==. Edit-mode selections persist
-- (cleared by the next tap), matching the previous behaviour.
function MDEdit:onPanRelease(_, ges)
    if self.reader_mode and self._pan_mode == "rselect" then
        self._pan_mode = nil
        self:commitHighlightFromSelection()
        return true
    end
    if self._pan_mode == "select" then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active, self._pan_paged, self._pan_mode = nil, nil, nil
        return true
    end
    return false   -- let other handlers (movable dialogs, etc.) see non-select releases
end
-- Wrap the current selection in == == markers, one span per logical line so a
-- multi-line selection produces valid per-line highlights. Whitespace at the ends
-- of each wrapped slice is left outside the markers, then the saved highlight is
-- expanded to the touched word boundaries so it never starts/stops mid-word.
function MDEdit:commitHighlightFromSelection()
    if not self:hasSel() then self.sel = nil; return self:refresh{ layout_dirty = false, selection = true } end
    local lr, lc, hr, hc = self:selRange()
    local function highlight_ranges(line, a, b)
        local toks = md_tokenize(line)[1]
        local byte, ranges = 0, {}
        for _, span in ipairs(toks.spans or {}) do
            local raw = span.text or ""
            local display = span.display
            if display == nil then display = raw end
            local start_col, end_col = byte, byte + #raw
            if display ~= "" and span.style ~= "syntax" and span.style ~= "bullet" and span.style ~= "task" then
                if end_col > a and start_col < b then
                    local from = math.max(0, math.min(#raw, a - start_col))
                    local to = math.max(0, math.min(#raw, b - start_col))
                    local lo = prev_word_col(raw, from)
                    local hi = next_word_col(raw, to)
                    if lo == hi and #raw > 0 then lo, hi = 0, #raw end
                    if hi == 0 and #raw > 0 then hi = #raw end
                    if hi > lo then ranges[#ranges+1] = { start_col + lo, start_col + hi } end
                end
            end
            byte = end_col
        end
        return ranges
    end
    local function wrap_range(li, a, b)
        local line = self.lines[li]
        if not line then return end
        a = math.max(0, math.min(a, #line)); b = math.max(a, math.min(b, #line))
        local ranges = highlight_ranges(line, a, b)
        for k = #ranges, 1, -1 do
            local ra, rb = ranges[k][1], ranges[k][2]
            local slice = line:sub(ra + 1, rb)
            if not slice:find("==", 1, true) then         -- avoid nesting/doubling markers
                line = line:sub(1, ra) .. "==" .. slice .. "==" .. line:sub(rb + 1)
            end
        end
        self.lines[li] = line
    end
    self:snapshot(); self._burst = nil
    if lr == hr then
        wrap_range(lr, lc, hc)
    else
        -- Back-to-front so each edit leaves earlier lines' byte offsets intact.
        wrap_range(hr, 0, hc)
        for k = hr - 1, lr + 1, -1 do wrap_range(k, 0, #self.lines[k]) end
        wrap_range(lr, lc, #self.lines[lr])
    end
    self.sel = nil
    self:save()
    -- Only the wrapped lines changed (== is zero-width, so wrapping is unaffected);
    -- repaint just those rows rather than flashing the whole screen.
    self:refresh{ lines = { lr, hr } }
end
-- If byte column `col` on line `line_i` falls inside a ==...== region, return the
-- 1-based byte indices of the opening and closing '==' markers; else nil.
function MDEdit:highlightRangeAt(line_i, col)
    local line = self.lines[line_i]
    if not line then return nil end
    local pos = 1
    while true do
        local s = line:find("==", pos, true)
        if not s then return nil end
        local e = line:find("==", s + 2, true)
        if not e then return nil end
        -- Hit if the cursor byte offset lands anywhere from the opening marker
        -- through the closing marker (inclusive of both == pairs).
        if col >= s - 1 and col <= e + 1 then return s, e end
        pos = e + 2
    end
end
-- Strip the ==...== markers of the highlight containing `col`, keeping the text.
function MDEdit:removeHighlightAt(line_i, col)
    local s, e = self:highlightRangeAt(line_i, col)
    if not s then return false end
    local line = self.lines[line_i]
    line = line:sub(1, e - 1) .. line:sub(e + 2)          -- drop closing == first (higher index)
    line = line:sub(1, s - 1) .. line:sub(s + 2)          -- then the opening ==
    self.lines[line_i] = line
    return true
end

-- ============================ Minfolio (native KOReader) ============================
local function edit_note(path, remote)
    MinfolioPair.trace("edit-request", "path=", tostring(path), "remote=", remote and "yes" or "no")
    fl_restore_if_needed()
    if active_mdedit and not active_mdedit._closing then
        -- Already editing this exact file: keep the live editor (with its cursor
        -- and unsaved edits) instead of stacking a duplicate that would fight it.
        if active_mdedit.path == path then return end
        -- Switching files: flush and close the current editor first so only one
        -- editor (and one file poller) is ever live. Suppress its on_close so we
        -- don't bounce through the listing on the way to the next note.
        active_mdedit.on_close = nil
        active_mdedit:saveAndClose()
    end
    -- Closing the document always returns to the Minfolio file listing at the
    -- note's folder -- even when the note was opened by a send from the computer
    -- (launch flag), which otherwise would drop back to KOReader.
    local ed = MDEdit:new{ path = path, remote = remote, on_close = function()
        if show_file_manager then show_file_manager(path_parent(path)) end
    end }
    active_mdedit = ed
    UIManager:show(ed, "full")   -- "full" forces a complete repaint over the menu
    MinfolioPair.trace("editor-shown", "path=", tostring(path))
    -- Closing the file browser and showing the editor each queue their own dirty
    -- updates.  Reassert the editor after that transition has drained so a
    -- browser-region update cannot win and leave a partially blank launch view.
    UIManager:scheduleIn(0.12, function()
        if active_mdedit == ed and not ed._closing then
            UIManager:setDirty(ed, "full")
        end
    end)
end

function MinfolioRemote.edit(descriptor_path)
    local ok, cfg = pcall(dofile, descriptor_path)
    if not ok or type(cfg) ~= "table" or type(cfg.host) ~= "string" or type(cfg.port) ~= "number" then
        notify(_("Invalid secure desktop editing session")); return
    end
    if type(cfg.session_id) ~= "string" or not cfg.session_id:match("^[A-Za-z0-9_-]+$")
        or type(cfg.token) ~= "string" or type(cfg.cert_fingerprint) ~= "string" then
        notify(_("Invalid secure desktop editing session")); return
    end
    lfs.mkdir(STATE_DIR)
    local expected_directory = MINFOLIO_REMOTE_DIR .. "/" .. cfg.session_id
    if cfg.directory ~= expected_directory then notify(_("Invalid secure desktop editing session")); return end
    lfs.mkdir(MINFOLIO_REMOTE_DIR); lfs.mkdir(cfg.directory)
    local shadow = cfg.directory .. "/document.md"
    cfg.outbox_path = cfg.directory .. "/outbox.md"
    cfg.inbox_path = cfg.directory .. "/inbox.md"
    cfg.revision_path = cfg.directory .. "/revision"
    cfg.closing_path = cfg.directory .. "/closing"
    -- The initial content arrives over the existing encrypted SSH launch command.
    -- It is written before MDEdit is constructed, so the editor never opens blank.
    if not read_file(shadow) then write_file(shadow, type(cfg.content) == "string" and cfg.content or "") end
    edit_note(shadow, cfg)
end

function MinfolioRemote.stop(session_id)
    if active_mdedit and active_mdedit.remote and active_mdedit.remote.session_id == session_id then
        active_mdedit:saveAndClose()
    end
end

-- Rotates the whole device screen 90° counter-clockwise (repeat to cycle through
-- upright / sideways / upside-down / sideways-the-other-way, same 4 modes KOReader
-- itself uses for its own rotation).
rotate_screen_ccw = function()
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

local function clean_entry_name(name, add_md_ext)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or name == "." or name == ".." or name:find("/", 1, true) or name:find("%z") then
        return nil
    end
    if add_md_ext and not name:match("%.%w+$") then name = name .. ".md" end
    return name
end

local function ensure_dir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    return lfs.mkdir(path)
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "file" then return os.remove(path) end
    if mode ~= "directory" then return false end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            if not remove_tree(path_join(path, name)) then return false end
        end
    end
    return lfs.rmdir(path)
end

local function dir_entries(dir)
    local dirs, files = {}, {}
    local ok = pcall(function()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." and not name:match("^%.") then
                local path = path_join(dir, name)
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    dirs[#dirs+1] = name
                elseif mode == "file" then
                    files[#files+1] = name
                end
            end
        end
    end)
    table.sort(dirs)
    table.sort(files)
    return dirs, files, ok
end

open_markdown_picker = function(start_dir)
    local dir = start_dir or NOTES_DIR
    if lfs.attributes(dir, "mode") ~= "directory" then dir = NOTES_DIR end
    if lfs.attributes(dir, "mode") ~= "directory" then dir = "/mnt/us" end

    local dirs, all_files, ok = dir_entries(dir)
    local files = {}
    for _, name in ipairs(all_files) do
        if is_markdown_file(name) then files[#files+1] = name end
    end

    local items = {}
    if dir ~= "/" then items[#items+1] = { text = "../", kind = "dir", path = path_parent(dir) } end
    if dir ~= NOTES_DIR and lfs.attributes(NOTES_DIR, "mode") == "directory" then
        items[#items+1] = { text = _("Minfolio folder"), kind = "dir", path = NOTES_DIR }
    end
    for _, name in ipairs(dirs) do
        items[#items+1] = { text = name .. "/", kind = "dir", path = path_join(dir, name) }
    end
    for _, name in ipairs(files) do
        items[#items+1] = { text = name, kind = "file", path = path_join(dir, name) }
    end
    if #items == 0 or not ok then
        items[#items+1] = { text = ok and _("No Markdown files here") or _("Cannot read this folder"), kind = "noop" }
    end

    local menu
    menu = Menu:new{
        title = _("Open .md") .. " - " .. (path_base(dir) ~= "" and dir or "/"),
        item_table = items,
        is_popout = false,
        onMenuSelect = function(_self, item)
            if item.kind == "dir" then
                UIManager:close(menu)
                open_markdown_picker(item.path)
            elseif item.kind == "file" then
                UIManager:close(menu)
                edit_note(item.path)
            end
        end,
    }
    UIManager:show(menu)
end

local function refresh_file_manager(menu, dir)
    -- Folder navigation replaces the current Menu's item table. Keeping one
    -- window avoids a growing KOReader widget stack and preserves the current
    -- browser instead of looking like every folder opened a new screen.
    if menu and menu.minfolioNavigate then return menu:minfolioNavigate(dir) end
    show_file_manager(dir)
end

-- Let a name-entry dialog toggle its on-screen keyboard by swiping: up shows it,
-- down hides it. Handy when a Bluetooth keyboard is attached and the on-screen
-- one is just wasting space (swipe down), or you want it back (swipe up).
local function attach_kbd_swipe(dlg)
    dlg.ges_events = dlg.ges_events or {}
    dlg.ges_events.MinfolioKbdSwipe = {
        GestureRange:new{ ges = "swipe",
            range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } },
    }
    function dlg:onMinfolioKbdSwipe(_, ges)
        local d = ges and ges.direction
        if d == "north" then self:onShowKeyboard()
        elseif d == "south" then self:onCloseKeyboard() end
        return true
    end
end
local function show_new_entry_dialog(menu, dir, kind)
    local is_folder = kind == "folder"
    local dlg
    dlg = InputDialog:new{
        title = is_folder and _("New folder") or _("New note"),
        input = "",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Create"), is_enter_default = true, callback = function()
                local name = clean_entry_name(dlg:getInputText(), not is_folder)
                UIManager:close(dlg)
                if not name then notify(_("Invalid name")); return end
                local path = path_join(dir, name)
                if lfs.attributes(path, "mode") then notify(_("Name already exists")); return end
                if is_folder then
                    if ensure_dir(path) then
                        refresh_file_manager(menu, dir)
                    else
                        notify(_("Could not create folder"))
                    end
                else
                    if write_file(path, "") then
                        if menu then UIManager:close(menu) end
                        edit_note(path)
                    else
                        notify(_("Could not create note"))
                    end
                end
            end },
        }},
    }
    attach_kbd_swipe(dlg)
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function show_rename_dialog(parent_menu, dir, item)
    local dlg
    dlg = InputDialog:new{
        title = _("Rename"),
        input = item.name,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Rename"), is_enter_default = true, callback = function()
                local name = clean_entry_name(dlg:getInputText(), item.kind == "file" and is_markdown_file(item.name))
                UIManager:close(dlg)
                if not name then notify(_("Invalid name")); return end
                if name == item.name then return end
                local dest = path_join(dir, name)
                if lfs.attributes(dest, "mode") then notify(_("Name already exists")); return end
                if os.rename(item.path, dest) then
                    refresh_file_manager(parent_menu, dir)
                else
                    notify(_("Could not rename"))
                end
            end },
        }},
    }
    attach_kbd_swipe(dlg)
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function confirm_delete(parent_menu, dir, item)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Delete %s?"), item.name),
        ok_text = _("Delete"),
        ok_callback = function()
            if remove_tree(item.path) then
                refresh_file_manager(parent_menu, dir)
            else
                notify(_("Could not delete"))
            end
        end,
    })
end

local function show_item_actions(parent_menu, dir, item)
    -- A ButtonDialog is the right widget for a long-press context menu: it sizes
    -- itself to its buttons (big tap targets, no empty filler), unlike a fixed-
    -- height Menu which renders a few tiny rows in a mostly-blank box.
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function act(cb)
        return function() UIManager:close(dialog); UIManager:scheduleIn(0.01, cb) end
    end
    local buttons = {}
    if item.kind == "dir" then
        buttons[#buttons+1] = {{ text = _("Open folder"),
            callback = act(function() refresh_file_manager(parent_menu, item.path) end) }}
    elseif is_markdown_file(item.name) then
        buttons[#buttons+1] = {{ text = _("Open"), callback = act(function()
            if parent_menu then UIManager:close(parent_menu) end
            edit_note(item.path)
        end) }}
    end
    buttons[#buttons+1] = {{ text = _("Rename"),
        callback = act(function() show_rename_dialog(parent_menu, dir, item) end) }}
    buttons[#buttons+1] = {{ text = _("Delete"),
        callback = act(function() confirm_delete(parent_menu, dir, item) end) }}
    dialog = ButtonDialog:new{
        title = item.name,
        title_align = "center",
        width_factor = 0.72,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

show_file_manager = function(start_dir)
    fl_restore_if_needed()
    ensure_dir(NOTES_DIR)
    local dir = start_dir or NOTES_DIR
    if lfs.attributes(dir, "mode") ~= "directory" then dir = NOTES_DIR end

    local dirs, files, ok = dir_entries(dir)
    local menu
    local items = {
        { text = "＋ " .. _("New note"), kind = "new_note" },
        { text = "＋ " .. _("New folder"), kind = "new_folder" },
        { text = _("Open .md file..."), is_open = true },
    }
    if dir ~= NOTES_DIR then items[#items+1] = { text = "../", kind = "dir_nav", path = path_parent(dir) } end
    for _, name in ipairs(dirs) do
        local item = { text = name .. "/", kind = "dir", name = name, path = path_join(dir, name) }
        item.hold_callback = function() show_item_actions(menu, dir, item) end
        items[#items+1] = item
    end
    for _, name in ipairs(files) do
        local item = { text = name, kind = "file", name = name, path = path_join(dir, name) }
        item.hold_callback = function() show_item_actions(menu, dir, item) end
        items[#items+1] = item
    end
    if not ok then items[#items+1] = { text = _("Cannot read this folder"), kind = "noop" } end
    logger.info("minfolio open_notes: showing", #items, "items")
    -- Custom title bar so we can show a Kindle-style battery indicator to the left
    -- of the close (X) icon. TitleBar only exposes a single right icon (the close
    -- button), so the battery is added as an extra right-aligned overlap child.
    local title_text = _("Minfolio") .. " - " .. (dir == NOTES_DIR and path_base(NOTES_DIR) or dir)
    local batt_info = battery_info()
    -- TitleBar knows about its close icon but not the extra battery widget we
    -- overlay on the right. Reserve that whole region in its title layout so a
    -- long folder path is ellipsized before it can paint underneath the percent.
    local battery_title_reserve = batt_info and (MinfolioBattery.indicatorWidth() + Screen:scaleBySize(44)) or 0
    local title_bar = TitleBar:new{
        width = Screen:getWidth(),
        align = "center",
        title = title_text,
        title_h_padding = Size.padding.large + battery_title_reserve,
        with_bottom_line = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            show_controls({ { text = "⟲ " .. _("Rotate screen"), callback = rotate_screen_ccw } })
        end,
        close_callback = function() if menu then menu:onClose() end end,
    }
    local batt = battery_indicator(batt_info)
    local batt_cell
    if batt then
        -- Vertically centered in the title bar, then nudged up ~8px: shrinking the
        -- centering box's height by 16 raises the centered battery by half that.
        batt_cell = CenterContainer:new{
            dimen = Geom:new{ w = MinfolioBattery.indicatorWidth(), h = math.max(1, title_bar:getHeight() - 16) }, batt }
        table.insert(title_bar, HorizontalGroup:new{
            align = "center", overlap_align = "right",
            batt_cell, HorizontalSpan:new{ width = Screen:scaleBySize(44) },
        })
    end
    menu = Menu:new{
        title = title_text,
        item_table = items,
        is_popout = false,
        handle_hold_on_hold_release = true,
        custom_title_bar = title_bar,
        onMenuSelect = function(_self, item)
            local current_dir = _self._minfolio_dir or dir
            -- The editor is fullscreen and returns here via its on_close, so close
            -- this listing rather than leaving it stacked underneath.
            if item.kind == "new_note" then show_new_entry_dialog(menu, current_dir, "note")
            elseif item.kind == "new_folder" then show_new_entry_dialog(menu, current_dir, "folder")
            elseif item.is_open then open_markdown_picker(current_dir)
            elseif item.kind == "dir_nav" then refresh_file_manager(menu, item.path)
            elseif item.kind == "dir" then refresh_file_manager(menu, item.path)
            elseif item.kind == "file" then
                if is_markdown_file(item.name) then UIManager:close(menu); edit_note(item.path) else show_item_actions(menu, dir, item) end
            end
        end,
        onMenuHold = function(_self, item)
            logger.info("minfolio file manager hold:", item and item.name, item and item.kind)
            if item and item.hold_callback then
                item.hold_callback()
            elseif item and (item.kind == "dir" or item.kind == "file") then
                show_item_actions(menu, _self._minfolio_dir or dir, item)
            end
            return true
        end,
    }
    menu._minfolio_dir = dir
    function menu:minfolioNavigate(next_dir)
        if lfs.attributes(next_dir, "mode") ~= "directory" then return end
        local next_dirs, next_files, readable = dir_entries(next_dir)
        local next_items = {
            { text = "＋ " .. _("New note"), kind = "new_note" },
            { text = "＋ " .. _("New folder"), kind = "new_folder" },
            { text = _("Open .md file..."), is_open = true },
        }
        if next_dir ~= NOTES_DIR then next_items[#next_items+1] = { text = "../", kind = "dir_nav", path = path_parent(next_dir) } end
        for _, name in ipairs(next_dirs) do
            local item = { text = name .. "/", kind = "dir", name = name, path = path_join(next_dir, name) }
            item.hold_callback = function() show_item_actions(self, next_dir, item) end
            next_items[#next_items+1] = item
        end
        for _, name in ipairs(next_files) do
            local item = { text = name, kind = "file", name = name, path = path_join(next_dir, name) }
            item.hold_callback = function() show_item_actions(self, next_dir, item) end
            next_items[#next_items+1] = item
        end
        if not readable then next_items[#next_items+1] = { text = _("Cannot read this folder"), kind = "noop" } end
        self._minfolio_dir = next_dir
        local next_title = _("Minfolio") .. " - " .. (next_dir == NOTES_DIR and path_base(NOTES_DIR) or next_dir)
        self:switchItemTable(next_title, next_items)
        logger.info("minfolio file manager navigated:", next_dir)
    end
    if batt_cell then
        menu._battery_key = MinfolioBattery.infoKey(batt_info)
        local function schedule_battery_refresh()
            local fn
            fn = function()
                if menu._battery_refresh_pending == fn then menu._battery_refresh_pending = nil end
                if menu._battery_closed then return end
                local info = battery_info()
                local key = MinfolioBattery.infoKey(info)
                if info and key ~= menu._battery_key then
                    if batt_cell[1] and batt_cell[1].free then batt_cell[1]:free() end
                    batt_cell[1] = battery_indicator(info)
                    menu._battery_key = key
                    UIManager:setDirty(menu, "ui")
                end
                schedule_battery_refresh()
            end
            menu._battery_refresh_pending = fn
            UIManager:scheduleIn(MinfolioBattery.refresh_interval, fn)
        end
        local original_close = menu.onCloseWidget
        function menu:onCloseWidget()
            self._battery_closed = true
            if self._battery_refresh_pending then
                UIManager:unschedule(self._battery_refresh_pending)
                self._battery_refresh_pending = nil
            end
            if original_close then original_close(self) end
        end
        schedule_battery_refresh()
    end
    title_bar.show_parent = menu
    if title_bar.left_button then title_bar.left_button.show_parent = menu end
    if title_bar.right_button then title_bar.right_button.show_parent = menu end
    -- KOReader's Menu closes on a south swipe, so swiping in the blank space
    -- dismisses the whole browser unexpectedly. Keep only left/right for paging
    -- and ignore vertical/diagonal swipes -- the X in the title bar is the way to
    -- close.
    function menu:onSwipe(_, ges)
        local d = ges and ges.direction
        if d == "west" then self:onNextPage()
        elseif d == "east" then self:onPrevPage() end
        return true
    end
    UIManager:show(menu)
end

local function open_notes()
    show_file_manager(NOTES_DIR)
end

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
    MinfolioPair.trace("launch-target", tostring(target))
    if target == "notes" or target == "open" then
        UIManager:scheduleIn(0.1, open_notes)
    elseif target:match("^edit:") then                  -- open a specific file in the editor
        local path = target:sub(6)
        UIManager:scheduleIn(0.1, function() edit_note(path) end)
    elseif target:match("^remote:") then
        local descriptor = target:sub(8)
        UIManager:scheduleIn(0.1, function() MinfolioRemote.edit(descriptor) end)
    elseif target:match("^remote%-stop:") then
        local session_id = target:sub(13)
        UIManager:scheduleIn(0.1, function() MinfolioRemote.stop(session_id) end)
    end
end

function Minfolio:pollLaunchFlag()
    local target = read_launch_target(LAUNCH_FLAG)
    if target and target ~= "" then
        MinfolioPair.trace("launch-flag-consumed", tostring(target))
        os.remove(LAUNCH_FLAG)
        self:openLaunchTarget(target)
    end
    UIManager:scheduleIn(0.5, function() self:pollLaunchFlag() end)
end

function Minfolio:onResume()
    MinfolioPair.trace("plugin-resume")
    -- Both operations wait for the screensaver/framework wake transition to settle.
    FL.scheduleWakeSync()
    schedule_wake_repaint()
end
function Minfolio:onSuspend()
    MinfolioPair.trace("plugin-suspend")
    FL.captureBeforeSuspend()
end

function Minfolio:onDispatcherRegisterActions()
    Dispatcher:registerAction("minfolio_open",
        { category = "none", event = "MinfolioOpen", title = _("Open Minfolio"), general = true })
end

function Minfolio:init()
    MinfolioPair.trace("plugin-init", "notes_dir=", NOTES_DIR)
    install_keyboard_aliases()
    MinfolioPair.start()
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

function Minfolio:onMinfolioOpen() open_notes(); return true end

function Minfolio:addToMainMenu(menu_items)
    menu_items.minfolio = {
        text = _("Minfolio"),
        sorting_hint = "more_tools",
        callback = function() open_notes() end,
    }
end

return Minfolio
