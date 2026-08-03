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
-- flag. This was written before the ceremony redesign below existed; the
-- "still a single code ... still approved by a human" shape is unchanged in
-- spirit, but see the ARMING section for what actually changed.
--
-- ARMING AND THE CEREMONY REDESIGN (PAIRING_PLAN.md §4, §4.0, WP 2/3):
--
-- §4.0's finding is why any of this exists: inbound UDP is dropped by the
-- Kindle's own firewall (`INPUT DROP`, only `state ESTABLISHED` accepted on
-- wlan0), verified end to end on the device -- so Channel A (UDP) has never
-- actually been reachable, regardless of anything in this file. KOReader
-- runs as root, so the plugin manages the firewall rule itself rather than
-- requiring any change to the device's persistent configuration:
--   iptables -I INPUT -i wlan0 -p udp --dport 42771 -j ACCEPT
-- installed only for a bounded 120s window the user opens deliberately
-- (M.arm/M.disarm/M.isArmed below), and removed on disarm, on window expiry,
-- and -- best-effort, see main.lua's Minfolio:onCloseWidget and M.start's own
-- startup sweep -- on KOReader teardown and on the next plugin load after an
-- unclean one. Outside that window every pairing datagram is dropped BEFORE
-- field validation, nonce/rate-limit bookkeeping, or a prompt: arming is the
-- outer switch in front of the defences described in the HARDENING PASS
-- comment above, not a replacement for any of them.
--
-- The ceremony itself also changed, and this is the part that touches the
-- wire format (see minfolio_pair_msg.lua's KNOWN_TYPES comment for the
-- validator side): v1 had the DESKTOP generate a code and broadcast it in
-- the pair-request datagram for a human to merely compare -- both reviewers
-- rejected that, because it puts the thing being compared on an
-- unauthenticated, sniffable wire. The redesign inverts it: M.generateCode
-- below mints the code on the KINDLE from the same /dev/urandom discipline
-- as M.secret (refuse rather than degrade), the human types it into the
-- desktop, and it never appears in plaintext on the LAN in either direction.
-- `minfolio-pair-offer` (host/port/fingerprint/label, no code, no nonce) is
-- the new datagram shape this enables; `minfolio-pair-request` (the
-- original five-field shape) is kept working too, because Channel B (the
-- SSH file drop) still uses it and because deleting a validated, tested
-- code path is not a decision to make silently inside an unrelated work
-- package -- both converge on the same `confirm_and_pair` local function
-- below, which is what actually generates/uses the Kindle-side code and
-- displays the last 12 hex characters of the offering desktop's certificate
-- fingerprint (PAIRING_PLAN.md §4.3: "a racing attacker's prompt shows
-- different digits").
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
-- Pure, keyed-by-fingerprint pairing store (PAIRING_PLAN.md WP 1) -- see
-- minfolio_pairing_store.lua and minfolio_pairing_store_test.lua. Replaces
-- the old `return { secret = "<hex>" }` single-secret file this module used
-- to write directly.
local Store = require("minfolio_pairing_store")

local M = { port = 42771 }

-- Arming state (PAIRING_PLAN.md §4.0, §4). All five fields are reset
-- together by M.disarm and set together by M.arm; nothing else in this
-- module writes them, so "is armed" always has one authoritative source:
-- M.isArmed(), which also lazily expires a stale window -- see its own
-- comment below for why that, rather than a single long-delayed timer, is
-- the actual enforcement.
M._armed = false
M._armed_code = nil
M._armed_until = nil
M._armed_channel = nil -- "udp+ssh" or "ssh-only", see M.arm
M.ARM_WINDOW_SECONDS = 120

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

-- Returns a fresh six-digit decimal string, or nil if it can't be generated
-- from a real entropy source -- the same refuse-rather-than-degrade
-- discipline as M.secret above, and for the same reason: PAIRING_PLAN.md §4
-- makes this code the thing a human types into the desktop to prove the POST
-- came from the device whose screen they're looking at, so a predictable
-- code (e.g. falling back to a clock reading) would quietly defeat that
-- proof while still looking, on screen, exactly like a real one.
--
-- Not itself the security boundary the way the 48-hex M.secret is -- it is a
-- human-typed, six-digit proof-of-physical-presence factor, not a
-- cryptographic key, so the small modulo bias from reducing 32 bits of
-- entropy to six decimal digits (roughly 1 part in 4,295 -- 2^32 isn't an
-- exact multiple of 1,000,000) is not a meaningful weakness here.
function M.generateCode()
    local f = io.open("/dev/urandom", "rb")
    if not f then
        logger.warn("minfolio pair: /dev/urandom unavailable; refusing to mint a pairing code")
        return nil
    end
    local raw = f:read(4)
    f:close()
    if type(raw) ~= "string" or #raw < 4 then
        logger.warn("minfolio pair: short read from /dev/urandom; refusing to mint a pairing code")
        return nil
    end
    local b1, b2, b3, b4 = raw:byte(1, 4)
    local n = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    return string.format("%06d", n % 1000000)
end

-- ---------------------------------------------------------------------------
-- The firewall rule (PAIRING_PLAN.md §4.0). `M.port` is fixed for the life of
-- the process, so the three commands below are plain string constants rather
-- than rebuilt per call.
-- ---------------------------------------------------------------------------

local IPT_RULE_SPEC = string.format("INPUT -i wlan0 -p udp --dport %d -j ACCEPT", M.port)
local IPT_CHECK_CMD = "iptables -C " .. IPT_RULE_SPEC .. " >/dev/null 2>&1"
local IPT_INSERT_CMD = "iptables -I " .. IPT_RULE_SPEC .. " >/dev/null 2>&1"
local IPT_DELETE_CMD = "iptables -D " .. IPT_RULE_SPEC .. " >/dev/null 2>&1"
local IPT_LIST_CMD = "iptables -L INPUT -n >/dev/null 2>&1"

-- Normalises os.execute's return across the shapes different Lua/LuaJIT
-- builds use for it: confirmed directly against a real device's KOReader
-- luajit that a successful command yields the raw number 0 (Lua 5.1
-- semantics -- the platform exit status, not a boolean); also accepts Lua
-- 5.2+'s `(true, "exit", 0)` shape defensively, since nothing here is harmed
-- by tolerating either.
local function run(cmd)
    local a, _b, c = os.execute(cmd)
    if type(a) == "number" then return a == 0 end
    if a == true then return true end
    if type(c) == "number" then return c == 0 end
    return false
end

-- Verify iptables is actually present and callable before relying on it at
-- all (PAIRING_PLAN.md §4.0: "Unverified: that iptables is present and
-- callable ... Establish it before building §4"). `iptables -L INPUT -n`'s
-- exit status is the check; confirmed on-device that this succeeds (exit 0)
-- when iptables is present and working.
function M.iptablesAvailable()
    return run(IPT_LIST_CMD)
end

-- Installs the accept rule, guarding against inserting a second identical
-- one if it's already present -- confirmed on-device that `iptables -I` does
-- NOT deduplicate, so calling this twice without a matching removal in
-- between would otherwise leave two rules, and a single later disarm would
-- need to remove both (see removeFirewallRule's loop, which does handle that
-- case if it ever happens, but avoiding the duplicate in the first place is
-- simpler than relying on cleanup for it).
function M.installFirewallRule()
    if run(IPT_CHECK_CMD) then return true end
    return run(IPT_INSERT_CMD)
end

-- Removes the accept rule. MUST be idempotent -- called on disarm, on window
-- expiry, from main.lua's KOReader-teardown hook, and as a startup self-heal
-- in M.start -- and confirmed on-device that `iptables -D` on a rule that
-- isn't present exits 1 and writes "Bad rule (does a matching rule exist in
-- that chain?)" to stderr, i.e. -D itself is NOT idempotent. So this checks
-- with -C first and only deletes when -C confirms the rule is actually
-- there, looping (bounded, so a persistently-misbehaving iptables can't hang
-- teardown) to also clean up the unlikely case of more than one identical
-- rule ever having been inserted. Always returns true: "make sure it's
-- gone" has no failure mode a caller needs to react to, whether that's
-- because it succeeded, because iptables is unavailable, or because there
-- was never anything to remove.
function M.removeFirewallRule()
    for _ = 1, 8 do
        if not run(IPT_CHECK_CMD) then break end
        run(IPT_DELETE_CMD)
    end
    return true
end

-- Arms pairing: mints the Kindle-side verification code, opens the UDP port
-- for ARM_WINDOW_SECONDS if iptables is available, and records which
-- channel(s) are consequently in play (PAIRING_PLAN.md §4.0: "the UI must
-- always report which channel it used"). Falls back to Channel B (the SSH
-- file drop, which needs no firewall change) when iptables is missing or the
-- rule can't be installed -- arming still succeeds in that case, just
-- without Channel A.
--
-- Returns (true, code, channel) on success, or (false, nil, nil, reason) if
-- no code could be minted (M.generateCode refusing, exactly like M.secret,
-- when /dev/urandom is unavailable -- there is no degraded fallback).
-- Calling arm() while already armed is a no-op that reports the existing
-- window rather than re-minting a code or re-touching the firewall rule.
function M.arm()
    if M.isArmed() then
        return true, M._armed_code, M._armed_channel
    end
    local code = M.generateCode()
    if not code then
        return false, nil, nil, "no secure random source available for the verification code"
    end
    local channel
    if M.iptablesAvailable() and M.installFirewallRule() then
        channel = "udp+ssh"
    else
        channel = "ssh-only"
    end
    M._armed = true
    M._armed_code = code
    M._armed_channel = channel
    M._armed_until = IO.now_seconds() + M.ARM_WINDOW_SECONDS
    Chrome.trace("pair-armed", "channel=", channel)
    return true, code, channel
end

-- Disarms pairing: removes the firewall rule (always safe to call, even if
-- nothing was ever installed this session -- see removeFirewallRule) and
-- clears the armed state. Safe to call when not armed.
function M.disarm()
    if not M._armed then return end
    M.removeFirewallRule()
    M._armed = false
    M._armed_code = nil
    M._armed_channel = nil
    M._armed_until = nil
    Chrome.trace("pair-disarmed")
end

-- The one authoritative "is pairing armed right now" check. Lazily expires a
-- window whose wall-clock deadline has passed -- called from the ~0.75s
-- discovery tick regardless of whether any datagram arrived (see M.start),
-- from Minfolio:onResume (so a window that elapsed while the device was
-- asleep, when the tick itself may not have been running, is closed
-- promptly on wake rather than sitting open until the next unrelated poll),
-- and from every pairing-menu render -- so there is no single long-delayed
-- one-shot timer this depends on; any of several frequent, independent call
-- sites will notice and disarm.
function M.isArmed()
    if M._armed and (not M._armed_until or IO.now_seconds() >= M._armed_until) then
        M.disarm()
    end
    return M._armed == true
end

function M.currentCode()
    if not M.isArmed() then return nil end
    return M._armed_code
end

function M.armedChannel()
    if not M.isArmed() then return nil end
    return M._armed_channel
end

function M.armedRemainingSeconds()
    if not M.isArmed() then return 0 end
    return math.max(0, math.floor((M._armed_until or 0) - IO.now_seconds() + 0.5))
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

-- Shows the pairing ConfirmBox once a message has passed every defensive
-- gate its caller (M.showPrompt or M.showOffer, below) is responsible for,
-- and handles acceptance: POSTs the Kindle-generated code and a fresh
-- secret to the desktop, and persists the result in the keyed pairing store
-- on success. Shared by both message shapes because, from this point on,
-- there is nothing left that differs between them -- both have already been
-- reduced to (fingerprint, host, port, label-or-nil) plus which channel
-- delivered this specific attempt.
--
-- `label` may be nil: `minfolio-pair-request`'s five-field shape (still used
-- by Channel B, the SSH file drop) has no label field at all, unlike the
-- newer `minfolio-pair-offer`. `attempt_channel_desc` is a short, already-
-- localised string identifying which channel delivered THIS attempt (UDP or
-- the SSH file drop) -- distinct from M._armed_channel, which is which
-- channel(s) are AVAILABLE for the rest of the armed window; the pairing
-- menu (minfolio_pair_menu.lua) shows that one.
--
-- PAIRING_PLAN.md §4.3: showing the last 12 hex characters of the offering
-- desktop's certificate fingerprint here, alongside the Kindle's own code,
-- is what makes the confirmation a check on the identity that will actually
-- be pinned -- a racing attacker's own prompt would show different digits,
-- because it would carry the attacker's own certificate's fingerprint, not
-- the real desktop's.
local function confirm_and_pair(fingerprint, host, port, label, attempt_channel_desc)
    local suffix = fingerprint:sub(-12)
    -- `label` comes straight from an already-field-validated message, but
    -- `validatePairRequest` (the legacy five-field shape, still used by
    -- Channel B) never checks a `label` field at all -- it doesn't expect
    -- one -- so a message could carry one of any type. type() is checked
    -- explicitly rather than just truthiness, or a non-string, non-nil
    -- label (e.g. a table) would reach the string concatenation below and
    -- raise "attempt to concatenate a table value", taking the confirmation
    -- prompt down with it.
    local who = (type(label) == "string" and label ~= "") and label or _("an unnamed desktop")
    -- Captured here, at prompt-build time, rather than read from M._armed_code
    -- inside ok_callback below. The ConfirmBox has no timeout, so it can outlive
    -- the 120-second armed window; when it does, isArmed() lazily calls disarm(),
    -- which nils M._armed_code. The dialog would still be displaying the correct
    -- six digits while the POST sent `code = nil` (rapidjson drops a nil value
    -- entirely, so the field simply vanished from the body), and the desktop
    -- rejected a code the user could read on screen.
    local armed_code = M._armed_code
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
    box = ConfirmBox:new{
        text = _("Pair with ") .. who .. _("?\n\nDesktop identity (last 12 hex of its certificate):\n")
            .. suffix .. _("\n\nAttempt received via: ") .. attempt_channel_desc
            .. _("\n\nIf these match what your desktop shows, type this code into it:\n\n")
            .. tostring(armed_code),
        ok_text = _("Pair"),
        ok_callback = function()
            release()
            -- The armed window is the security boundary, not decoration: a
            -- prompt approved after it closed must not pair. Refusing here, with
            -- a message that says what to do, is both the safe answer and a
            -- clearer one than letting the desktop reject the request for
            -- reasons the Kindle never explains.
            if not M.isArmed() then
                Chrome.notify(_("Pairing window expired -- arm pairing again and retry"))
                return
            end
            local cfg = { host = host, port = port, cert_fingerprint = fingerprint }
            local secret = M.secret()
            if not secret then
                Chrome.notify(_("Could not complete secure pairing: no secure random source available"))
                return
            end
            -- No nonce in the POST body any more: correlation on the
            -- desktop side is now the human typing this same code into the
            -- pending offer's UI, not a value that travelled the network in
            -- both directions (PAIRING_PLAN.md §4).
            local posted, err = M.post(cfg, "/kindle/pair",
                { deviceId = M.deviceId(), secret = secret, code = armed_code })
            if posted then
                lfs.mkdir(Config.STATE_DIR)
                local store = Store.load(Config.MINFOLIO_PAIR_PATH)
                Store.put(store, fingerprint, secret, label, IO.now_seconds())
                local saved, serr = Store.save(Config.MINFOLIO_PAIR_PATH, store)
                if saved then
                    Chrome.notify(_("Desktop paired"))
                else
                    logger.warn("minfolio pair: paired but could not persist the pairing store:", tostring(serr))
                    Chrome.notify(_("Paired, but could not save the pairing record: ") .. tostring(serr))
                end
            else
                Chrome.notify(_("Could not complete secure pairing: ") .. tostring(err or "unknown error"))
            end
            -- One pairing per armed window: close the port immediately
            -- after use rather than waiting out the rest of the 120s,
            -- shrinking the exposure window further still (this is a
            -- deliberate choice beyond what PAIRING_PLAN.md §4 strictly
            -- requires, not a mandated step -- re-arming for a second
            -- desktop is one tap away).
            M.disarm()
        end,
        cancel_callback = release,
    }
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

-- Handles an already-*decoded* `minfolio-pair-request`-shaped message (the
-- original five-field shape: code/host/port/fingerprint/nonce -- still used
-- by Channel B, the SSH file drop), after re-validating it and passing every
-- defensive gate below. `source` is a rate-limit bucket key: the UDP
-- sender's address for Channel A, or the fixed string "local-file" for
-- Channel B, so a flood on either channel is bounded the same way.
--
-- Gate order, and why each one is where it is:
--   0. Armed check -- outside the window this drops silently before any of
--      the gates below even run (PAIRING_PLAN.md §4.0/§8: "outside the armed
--      window, a pair-request/offer produces no prompt at all").
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
--
-- The code/nonce fields on `msg` itself are no longer trusted for anything
-- past validation: the code shown and POSTed is always M._armed_code (the
-- Kindle's own, freshly minted at arm time), never msg.code -- see the
-- ARMING AND THE CEREMONY REDESIGN header comment for why.
function M.showPrompt(msg, source)
    if not M.isArmed() then
        Chrome.trace("pair-request-dropped", "not armed")
        return
    end
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
    confirm_and_pair(msg.fingerprint, msg.host, msg.port, msg.label,
        source == "local-file" and _("SSH file drop") or _("UDP"))
end

-- Handles an already-*decoded* `minfolio-pair-offer`-shaped message
-- (host/port/fingerprint/label -- no code, no nonce; see
-- minfolio_pair_msg.lua's KNOWN_TYPES comment). Same armed/one-prompt/rate-
-- limit gates as M.showPrompt, minus the nonce-replay step: there is no
-- nonce on this shape to replay, and repeatedly re-showing an offer that
-- carries no state of its own is already bounded by the rate limiter, not a
-- distinct hazard the nonce cache exists to close.
function M.showOffer(msg, source)
    if not M.isArmed() then
        Chrome.trace("pair-offer-dropped", "not armed")
        return
    end
    local ok, reason = PairMsg.validatePairOffer(msg)
    if not ok then
        Chrome.trace("pair-offer-rejected", reason or "invalid")
        return
    end
    local now = IO.now_seconds()
    if M._prompt_open then
        Chrome.trace("pair-offer-dropped", "a pairing prompt is already open")
        return
    end
    if not PairMsg.allowPrompt(M._rate_state, source, now) then
        Chrome.trace("pair-offer-rejected", "rate limited")
        return
    end
    confirm_and_pair(msg.fingerprint, msg.host, msg.port, msg.label,
        source == "local-file" and _("SSH file drop") or _("UDP"))
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
    if not ok or type(msg) ~= "table" then return end
    -- Channel B carries either shape over the same file (PROTOCOL.md §2's
    -- five-field pair-request shape, or the newer label-bearing offer
    -- shape); `label` is the one field only the latter has, so its presence
    -- is what tells the two apart -- both M.showPrompt/M.showOffer apply
    -- their own armed/rate-limit/prompt gates regardless of which one runs.
    if msg.label ~= nil then
        M.showOffer(msg, "local-file")
    else
        M.showPrompt(msg, "local-file")
    end
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
                elseif msg.type == "minfolio-pair-offer" then
                    M.showOffer(msg, ip)
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
    -- Best-effort self-heal (PAIRING_PLAN.md §4.0: "an interrupted pairing
    -- must not leave the port open"): a PREVIOUS KOReader session that armed
    -- pairing and then exited uncleanly -- a crash, a force-kill, a power
    -- loss -- runs no Lua teardown code at all, so nothing would otherwise
    -- ever notice or remove a rule it left installed. M._armed is always
    -- fresh-false at this exact point (a brand new Lua state, before
    -- anything in this module could have armed anything), so any matching
    -- rule the kernel already has is unconditionally stale. Safe to call
    -- unconditionally: removeFirewallRule never errors, whether iptables is
    -- missing, the rule was never there, or it genuinely needed removing --
    -- see its own comment. main.lua's Minfolio:onCloseWidget is the other
    -- half of this (the clean-exit path, fired when KOReader itself tears
    -- down); this is the backstop for every path that hook cannot cover.
    M.removeFirewallRule()
    local s = socket.udp(); if not s then return end
    s:setsockname("*", M.port); s:setoption("broadcast", true); s:settimeout(0); M.sock = s
    Chrome.trace("discovery-start", "port=", M.port)
    local function tick()
        -- Lazily expire a stale armed window every ~0.75s tick, independent
        -- of whether any datagram arrived this cycle -- see M.isArmed's own
        -- comment for why this, not a single long-delayed one-shot timer, is
        -- the actual enforcement for "the rule is gone after the window
        -- closes."
        M.isArmed()
        M.poll(); M.pollRequest(); M.beacon()
        UIManager:scheduleIn(0.75, tick)
    end
    UIManager:scheduleIn(0.25, tick)
end

return M
