-- SPDX-License-Identifier: AGPL-3.0-only
-- UDP discovery, beacon, and the pairing handshake for minfolio.koplugin
-- (PLAN.md §5 Tier 2): finds a Kindle from the desktop app's LAN broadcast,
-- shows the pairing confirmation prompt, and persists the per-device secret.
-- Requires `minfolio_remote` for the actual TLS POST transport (see the
-- hazard note below), plus KOReader's `socket`/`rapidjson`/
-- `libs/libkoreader-lfs` and `ui/uimanager`/`ui/widget/confirmbox`. Cannot
-- be `require`d and executed under plain luajit -- only `loadfile`-parsed,
-- exactly like main.lua itself -- so no off-device test suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 2, §10 step 6):
-- MinfolioPair.deviceId, .secret, .post, .showPrompt, .pollRequest, .poll,
-- .beacon, .start, and the `port` field. `.trace`, `.makeKeyboardArrowFree`,
-- and `.disableKeyboardKeyFlash` were already relocated off MinfolioPair in
-- an earlier work package (see minfolio_chrome.lua/minfolio_keys.lua) and
-- are not here.
--
-- MinfolioPair was a bare global before this move (main.lua:71 in the
-- original 5,755-line file, forced by the 200-local ceiling this refactor
-- removes -- see PLAN.md §1/§6.4). It is now M.*. Confirmed by repo-wide
-- grep (including minfolio_sync.lua/.sh, a separate process with its own
-- LUA_PATH) that nothing outside main.lua read it as a global.
--
-- HAZARD, and the one authorised non-verbatim change in this move (PLAN.md
-- §6.3/§11): `.post` used to read `local sock =
-- MinfolioRemote and MinfolioRemote.socket(cfg, 2)` -- a nil-tolerant guard
-- on the MinfolioRemote GLOBAL, which only worked because a global read
-- resolves at call time, 1,854 lines after `MinfolioRemote` was actually
-- assigned in the original file. Now that this module requires
-- minfolio_remote directly (an ordinary module load, resolved once, at the
-- top of this file, long before .post can ever run), the guard would be
-- dead weight testing a local that can never be nil -- worse, if it had been
-- left as `MinfolioRemote and MinfolioRemote.socket(...)` against a name
-- that no longer exists as a global at all post-refactor, it would silently
-- and permanently read nil forever, and desktop pairing would stop posting
-- with no error anywhere (exactly the failure PLAN.md §11
-- warn about). `.post` below therefore calls `Remote.socket(...)` directly.
--
-- Required by callers as `local Pair = require("minfolio_pair")`.

local socket = require("socket")
local rapidjson = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local _ = require("gettext")
local logger = require("logger")

local Remote = require("minfolio_remote")
local Config = require("minfolio_config")
local Chrome = require("minfolio_chrome")
local IO = require("minfolio_io")

local M = { port = 42771 }

function M.deviceId()
    local f = io.open("/proc/usid", "r")
    local id = f and f:read("*l") or nil
    if f then f:close() end
    return (id and id:gsub("[^%w]", "")) or "kindle"
end

function M.secret()
    local f = io.open("/dev/urandom", "rb")
    local raw = f and f:read(24) or tostring(os.time()) .. tostring(socket.gettime())
    if f then f:close() end
    return (raw:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

-- Returns true only when the desktop actually accepted the request.
--
-- This used to return true as soon as the bytes were sent, without reading the
-- response at all. The caller treats that as "paired": it persists the secret
-- and tells the user "Desktop paired". So a pairing the desktop *rejected* --
-- wrong code, expired or unknown nonce, a nonce already consumed by someone
-- else -- was reported as success, leaving the Kindle holding a secret the
-- desktop never stored. Silent divergence: the user believes the two devices
-- are paired and every later session fails for no visible reason.
--
-- Only the status line is needed, so the body is not read; `Connection: close`
-- means closing the socket afterwards discards the rest harmlessly.
function M.post(cfg, path, body)
    local sock = Remote.socket(cfg, 2)
    if not sock then return false end
    local raw = rapidjson.encode(body)
    local req = "POST " .. path .. " HTTP/1.1\r\nHost: " .. cfg.host .. "\r\nContent-Type: application/json\r\nContent-Length: " .. #raw .. "\r\nConnection: close\r\n\r\n" .. raw
    if not Remote.sendAll(sock, req) then pcall(function() sock:close() end); return false end
    local status = sock:receive("*l")
    pcall(function() sock:close() end)
    local code = type(status) == "string" and tonumber(status:match("^HTTP/%d%.%d%s+(%d%d%d)")) or nil
    if not code then
        logger.warn("minfolio pair: no HTTP status from desktop", tostring(status))
        return false
    end
    if code < 200 or code >= 300 then
        logger.warn("minfolio pair: desktop rejected pairing with HTTP", code)
        return false
    end
    return true
end

function M.showPrompt(msg)
    if not (msg and msg.code and msg.host and msg.port and msg.fingerprint and msg.nonce) then return end
    UIManager:show(ConfirmBox:new{ text = _("Pair with this desktop?\n\nVerification code: ") .. tostring(msg.code), ok_text = _("Pair"), ok_callback = function()
        local cfg = { host = msg.host, port = tonumber(msg.port), cert_fingerprint = msg.fingerprint }
        local secret = M.secret()
        if M.post(cfg, "/kindle/pair", { nonce = msg.nonce, code = msg.code, deviceId = M.deviceId(), secret = secret }) then
            lfs.mkdir(Config.STATE_DIR)
            local state = io.open(Config.MINFOLIO_PAIR_PATH, "w")
            if state then state:write(string.format("return { secret = %q }\n", secret)); state:close() end
            Chrome.notify(_("Desktop paired"))
        else Chrome.notify(_("Could not complete secure pairing")) end
    end })
end

function M.pollRequest()
    local flag = "/tmp/minfolio_pair_request"
    local fp = io.open(flag, "r")
    if not fp then return end
    fp:close()
    os.remove(flag)
    local ok, msg = pcall(dofile, Config.MINFOLIO_REMOTE_DIR .. "/pair-request.lua")
    if ok then M.showPrompt(msg) end
end

function M.poll()
    if not M.sock then return end
    -- UDP is untrusted input.  Draining an endless datagram queue in a single
    -- UI callback can starve taps, rendering, and suspend handling.
    local processed, max_per_tick = 0, 32
    while processed < max_per_tick do
        local raw, ip, reply_port = M.sock:receivefrom()
        if not raw then break end
        processed = processed + 1
        local ok, msg = pcall(function() return rapidjson.decode(raw) end)
        if ok and msg.type == "minfolio-discover" and msg.nonce then
            local reply = rapidjson.encode({ type = "minfolio-device", nonce = msg.nonce, id = M.deviceId(), label = "Kindle Minfolio" })
            M.sock:sendto(reply, ip, reply_port)
        elseif ok and msg.type == "minfolio-pair-request" then
            M.showPrompt(msg)
        end
    end
    if processed == max_per_tick then
        local now = IO.now_seconds()
        if not M._last_backpressure_log or now - M._last_backpressure_log >= 30 then
            M._last_backpressure_log = now
            logger.warn("minfolio discovery queue capped; deferring remaining UDP datagrams")
        end
    end
end

function M.beacon()
    if not M.sock then return end
    local msg = rapidjson.encode({ type = "minfolio-device", id = M.deviceId(), label = "Kindle Minfolio" })
    pcall(function() M.sock:sendto(msg, "255.255.255.255", M.port) end)
end

function M.start()
    if M.sock then return end
    local s = socket.udp(); if not s then return end
    s:setsockname("*", M.port); s:setoption("broadcast", true); s:settimeout(0); M.sock = s
    Chrome.trace("discovery-start", "port=", M.port)
    local function tick() M.poll(); M.pollRequest(); M.beacon(); UIManager:scheduleIn(0.75, tick) end
    UIManager:scheduleIn(0.25, tick)
end

return M
