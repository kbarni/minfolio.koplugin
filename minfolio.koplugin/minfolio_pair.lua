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
-- HARDENING PASS (PAIRING_PLAN.md §5.8, §3 "verified findings", §7 risks):
-- `.poll()` used to call `.showPrompt(msg)` for any UDP datagram whose five
-- fields were merely present, with no size/type/length/range checks, no
-- nonce-replay protection, no cap on concurrently open prompts, and no rate
-- limit -- so a spoofed-source UDP flood could stack unbounded ConfirmBoxes
-- on an e-ink device, and a captured legitimate datagram could be replayed
-- forever to re-show a code the user already approved. Fixed by: an
-- oversized-datagram check before JSON decoding; strict field validation
-- (type/length/range, reject rather than coerce) via the new
-- `minfolio_pair_msg` module; a Kindle-side seen-nonce cache with expiry
-- (previously the 60s expiry and one-shot nonce existed only on the
-- desktop); a "one prompt open at a time" gate; and a per-source/global
-- rate limit. `.secret()` now refuses (returns nil) rather than degrading to
-- a non-random fallback when `/dev/urandom` is unavailable, and `.post()` now
-- returns the underlying transport error instead of discarding it, so a pin
-- mismatch and an unreachable host no longer show the same message.
-- `.pollRequest()` now deletes the consumed descriptor file, not just the
-- flag. None of this changes the pairing ceremony itself (still a single
-- code shown in a ConfirmBox, still six-digit, still approved by a human) --
-- see PAIRING_PLAN.md §4 for the separately-approved ceremony redesign this
-- work explicitly excludes.
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
-- Pure validation/nonce-cache/rate-limit logic (PAIRING_PLAN.md §5.8, §3),
-- factored out so it has an off-device test suite -- see
-- minfolio_pair_msg_test.lua and that module's own header comment for why.
local PairMsg = require("minfolio_pair_msg")

local M = { port = 42771 }

-- Stateful defenses against the UDP pair-request path: a bounded nonce-replay
-- cache and a per-source/global prompt rate limiter. The logic that decides
-- "replay?"/"allowed?" is pure and lives in minfolio_pair_msg.lua; only the
-- long-lived state containers and the UI-facing "is a prompt already on
-- screen" flag live here, since neither can be expressed without depending
-- on this module's own lifetime (one plugin load = one set of counters).
M._nonce_cache = PairMsg.newNonceCache()
M._rate_state = PairMsg.newRateState()
-- "Allow at most one pairing prompt open at a time; drop pair packets while
-- one is open." This is the ONLY gate against modal-dialog stacking that
-- cannot be pure logic -- it mirrors real UI state (a ConfirmBox actually on
-- screen), not a value minfolio_pair_msg.lua could compute from inputs alone.
M._prompt_open = false
M._prompt_release_task = nil

function M.deviceId()
    local f = io.open("/proc/usid", "r")
    local id = f and f:read("*l") or nil
    if f then f:close() end
    return (id and id:gsub("[^%w]", "")) or "kindle"
end

-- Returns a fresh 48-hex-char secret, or nil if it can't be generated from a
-- real entropy source. This used to fall back to
-- `tostring(os.time()) .. tostring(socket.gettime())` when /dev/urandom
-- couldn't be opened -- not cryptographically random, and worse, persisted
-- and used exactly as if it were. A pairing secret that failed to be random
-- is not "slightly weaker", it is a guessable credential the desktop will
-- accept forever; refusing outright (the caller must abort pairing on nil,
-- with a clear message) is the only correct response to missing entropy.
function M.secret()
    local f = io.open("/dev/urandom", "rb")
    if not f then
        logger.warn("minfolio pair: /dev/urandom unavailable; refusing to mint a pairing secret")
        return nil
    end
    local raw = f:read(24)
    f:close()
    if type(raw) ~= "string" or #raw < 24 then
        logger.warn("minfolio pair: short read from /dev/urandom; refusing to mint a pairing secret")
        return nil
    end
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
--
-- Returns `true` on a 2xx response, or `false, reason` on any failure. The
-- reason is surfaced all the way to the user-visible notification (see
-- showPrompt below) -- Remote.socket already distinguishes "LuaSec missing",
-- "desktop certificate pin mismatch", and a plain connect error, but this
-- function used to discard all of it and return bare `false`, so every
-- failure showed the same "Could not complete secure pairing" regardless of
-- cause. A pin mismatch (a possible active attack) and an unreachable host
-- (the desktop is simply off) are very different problems and should not
-- look identical to the user.
function M.post(cfg, path, body)
    local sock, sock_err = Remote.socket(cfg, 2)
    if not sock then return false, sock_err or "could not connect to desktop" end
    local raw = rapidjson.encode(body)
    local req = "POST " .. path .. " HTTP/1.1\r\nHost: " .. cfg.host .. "\r\nContent-Type: application/json\r\nContent-Length: " .. #raw .. "\r\nConnection: close\r\n\r\n" .. raw
    local sent_ok, sent_err = Remote.sendAll(sock, req)
    if not sent_ok then
        pcall(function() sock:close() end)
        return false, sent_err or "could not send pairing request"
    end
    local status = sock:receive("*l")
    pcall(function() sock:close() end)
    local code = type(status) == "string" and tonumber(status:match("^HTTP/%d%.%d%s+(%d%d%d)")) or nil
    if not code then
        logger.warn("minfolio pair: no HTTP status from desktop", tostring(status))
        return false, "no response from desktop"
    end
    if code < 200 or code >= 300 then
        logger.warn("minfolio pair: desktop rejected pairing with HTTP", code)
        return false, "desktop rejected pairing (HTTP " .. tostring(code) .. ")"
    end
    return true
end

-- Shows the pairing ConfirmBox for an already-*decoded* message, after
-- re-validating it and passing every defensive gate below. `source` is a
-- rate-limit bucket key: the UDP sender's address for Channel A, or a fixed
-- string such as "local-file" for Channel B (the SSH-file-drop path), so a
-- flood on either channel is bounded the same way.
--
-- Gate order, and why each one is where it is:
--   1. Field validation (cheap, stateless) -- malformed input is dropped
--      before it can consume any stateful budget below.
--   2. Nonce replay check -- a nonce already shown once is dropped
--      unconditionally, regardless of how busy the prompt/rate-limit gates
--      are, since re-showing an already-decided request is never correct.
--   3. "One prompt at a time" -- dropped here WITHOUT marking the nonce as
--      seen, so a legitimate desktop retry (same nonce, resent because UDP
--      is unreliable) can still succeed once the current prompt is
--      dismissed, rather than being permanently burned by a busy signal.
--   4. Rate limit -- also dropped without marking the nonce seen, for the
--      same reason.
--   5. Only once every gate above has passed do we actually mark the nonce
--      seen and show the dialog, so a captured, legitimate datagram cannot
--      replay forever and re-show a code the user already acted on.
function M.showPrompt(msg, source)
    local ok, reason = PairMsg.validatePairRequest(msg)
    if not ok then
        Chrome.trace("pair-request-rejected", reason or "invalid")
        return
    end
    local now = IO.now_seconds()
    if PairMsg.nonceSeen(M._nonce_cache, msg.nonce, now) then
        Chrome.trace("pair-request-rejected", "replayed nonce")
        return
    end
    if M._prompt_open then
        Chrome.trace("pair-request-dropped", "a pairing prompt is already open")
        return
    end
    if not PairMsg.allowPrompt(M._rate_state, source, now) then
        Chrome.trace("pair-request-rejected", "rate limited")
        return
    end
    PairMsg.rememberNonce(M._nonce_cache, msg.nonce, now)
    M._prompt_open = true

    -- Released from the widget's own teardown hook, plus a backstop.
    --
    -- Verified by reading KOReader's frontend/ui/widget/confirmbox.lua on the
    -- device rather than assuming: cancel_callback fires on the Cancel button
    -- (line 110), on onClose (242, the back/close event), and on onTapClose
    -- (249, a tap outside, which routes through onClose). It does NOT fire on
    -- onCloseWidget (236), which runs on *every* close including a programmatic
    -- UIManager:close() from elsewhere. So onCloseWidget is the only hook that
    -- covers every dismiss path, and it is what releases the gate below.
    --
    -- The scheduled release remains only for the one case onCloseWidget cannot
    -- cover: UIManager:show() itself failing, so the widget is never shown and
    -- never torn down. Without some backstop a single stuck flag would disable
    -- pairing for the rest of the session.
    local function release()
        M._prompt_open = false
        if M._prompt_release_task then
            UIManager:unschedule(M._prompt_release_task)
            M._prompt_release_task = nil
        end
    end
    M._prompt_release_task = release
    UIManager:scheduleIn(PairMsg.PROMPT_STUCK_TIMEOUT_SECONDS, release)

    local box
    box = ConfirmBox:new{ text = _("Pair with this desktop?\n\nVerification code: ") .. msg.code, ok_text = _("Pair"), ok_callback = function()
        release()
        local cfg = { host = msg.host, port = msg.port, cert_fingerprint = msg.fingerprint }
        local secret = M.secret()
        if not secret then
            Chrome.notify(_("Could not complete secure pairing: no secure random source available"))
            return
        end
        local posted, err = M.post(cfg, "/kindle/pair", { nonce = msg.nonce, code = msg.code, deviceId = M.deviceId(), secret = secret })
        if posted then
            lfs.mkdir(Config.STATE_DIR)
            local state = io.open(Config.MINFOLIO_PAIR_PATH, "w")
            if state then state:write(string.format("return { secret = %q }\n", secret)); state:close() end
            Chrome.notify(_("Desktop paired"))
        else
            Chrome.notify(_("Could not complete secure pairing: ") .. tostring(err or "unknown error"))
        end
    end, cancel_callback = release }
    -- See the note above: onCloseWidget is the only hook that fires on every
    -- close path, so the gate is released there regardless of how the dialog
    -- went away. release() is idempotent, so the ok/cancel callbacks releasing
    -- first is harmless.
    local stock_on_close_widget = box.onCloseWidget
    function box:onCloseWidget()
        release()
        if stock_on_close_widget then return stock_on_close_widget(self) end
    end
    UIManager:show(box)
end

function M.pollRequest()
    local flag = "/tmp/minfolio_pair_request"
    local fp = io.open(flag, "r")
    if not fp then return end
    fp:close()
    os.remove(flag)
    -- Consume AND delete the descriptor itself, not just the flag. Removing
    -- only the flag (the previous behaviour) left pair-request.lua in place,
    -- so any later touch of the flag -- by another process, a leftover
    -- script, or a bug -- would replay the same old request indefinitely.
    -- Delete it unconditionally, whether or not it parsed, so a corrupt
    -- descriptor cannot linger for replay either.
    local descriptor_path = Config.MINFOLIO_REMOTE_DIR .. "/pair-request.lua"
    local ok, msg = pcall(dofile, descriptor_path)
    os.remove(descriptor_path)
    if ok then M.showPrompt(msg, "local-file") end
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
        -- Reject oversized datagrams before spending a JSON decode on them --
        -- a flood padding its payload to waste parse time is rejected on
        -- byte length alone.
        if not PairMsg.oversized(raw) then
            local ok, msg = pcall(function() return rapidjson.decode(raw) end)
            -- `type(msg) == "table"` guards against a syntactically valid but
            -- non-object JSON payload (e.g. the literal `true`, `123`, or
            -- `null`): indexing `msg.type` below would otherwise raise an
            -- uncaught "attempt to index a <type> value" error for exactly
            -- the kind of malformed input this hardening exists to survive.
            if ok and type(msg) == "table" and PairMsg.isKnownType(msg.type) then
                if msg.type == "minfolio-discover" then
                    -- Version-tolerant: an absent `v` is v1; any well-formed
                    -- version is accepted since only the fixed fields below
                    -- are ever read. The nonce is bounds-checked before being
                    -- echoed back -- an unchecked, attacker-supplied nonce
                    -- echoed into our reply would otherwise let a spoofed-
                    -- source flood use this Kindle as a UDP reflection/
                    -- amplification vector.
                    if PairMsg.isWellFormedVersion(msg.v) and PairMsg.validNonceFormat(msg.nonce) then
                        local reply = rapidjson.encode({ type = "minfolio-device", nonce = msg.nonce, id = M.deviceId(), label = "Kindle Minfolio" })
                        M.sock:sendto(reply, ip, reply_port)
                    end
                elseif msg.type == "minfolio-pair-request" then
                    M.showPrompt(msg, ip)
                end
            end
            -- else: not valid JSON, not a table, or an unrecognised type --
            -- silently ignored, so a future desktop's new datagram types
            -- cannot break this version.
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
