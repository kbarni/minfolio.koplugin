-- SPDX-License-Identifier: AGPL-3.0-only
-- Pure validation, nonce-replay-cache, and prompt-rate-limiting logic for the
-- UDP pair-request path in minfolio_pair.lua (PAIRING_PLAN.md §5.8, §3;
-- ARCHITECTURE.md's Tier 0 rule). Deliberately zero KOReader dependencies: no
-- `require("ui/...")`, no `socket`, no `rapidjson`, nothing that only exists
-- inside a running KOReader process. That is not a style preference, it is
-- the only way any of this can be checked off-device -- see
-- minfolio_pair_msg_test.lua, runnable with plain lua/luajit, no KOReader
-- install required:
--   luajit minfolio_pair_msg_test.lua
--
-- Why this exists: `minfolio_pair.lua`'s `M.poll()` used to show a
-- `ConfirmBox` for any UDP datagram whose five fields were merely *present*
-- (no type/length/range checks), with no cap on how many prompts could stack,
-- no replay protection, and no rate limit -- so a spoofed-source UDP flood
-- could stack unbounded modal dialogs on an e-ink device, and a captured
-- legitimate datagram could be replayed forever to re-show a code the user
-- already approved. `minfolio_pair.lua` cannot be `require`d and executed
-- under plain luajit (it needs `socket`/`rapidjson`/KOReader's UI stack), so
-- the fix had to be split: the part that decides "is this well-formed, have
-- I seen it before, am I allowed to prompt again right now" is pure logic
-- with no KOReader dependency at all, and lives here so it actually has a
-- test suite; only the UDP socket, JSON decode, and the ConfirmBox itself
-- stay in minfolio_pair.lua.
--
-- Time is always an explicit parameter (`now`), never read from a clock
-- inside this module -- that is what makes the nonce-expiry and rate-limit-
-- window tests deterministic without sleeping.
--
-- Required by callers as `local PairMsg = require("minfolio_pair_msg")`.

local M = {}

-- ---------------------------------------------------------------------------
-- Tunable limits. Kept as module fields (not locals) so both this module's
-- own logic and its test suite can reference the exact numbers instead of
-- duplicating them.
-- ---------------------------------------------------------------------------

-- A legitimate pair-request datagram (type/code/host/port/fingerprint/nonce,
-- plus JSON overhead) is a few hundred bytes at most; 1024 gives headroom
-- without letting a flood pad datagrams to waste parse time. Checked BEFORE
-- JSON decoding, on the raw byte string.
M.MAX_DATAGRAM_BYTES = 1024

-- Bounded string lengths for every field that isn't fixed-width.
M.MAX_HOST_LEN = 255      -- generous for an IPv4/IPv6 literal or DNS hostname
M.NONCE_MIN_LEN = 4
M.NONCE_MAX_LEN = 128      -- also bounds the reflected size of a discover reply
M.FINGERPRINT_HEX_LEN = 64 -- sha256 digest, hex-encoded, exactly 64 chars
M.CODE_LEN = 6             -- strictly six digits, no shorter or longer

M.MIN_PORT = 1
M.MAX_PORT = 65535

-- A captured, legitimate pair-request datagram must not be replayable forever
-- just because the desktop's own 60s expiry/one-shot nonce isn't enforced
-- Kindle-side. 60s mirrors the desktop's own window (PAIRING_PLAN.md §3).
M.NONCE_TTL_SECONDS = 60
-- Defensive upper bound on cache size; in normal operation the rate limiter
-- below already keeps this far smaller (see the comment on RATE_LIMIT_GLOBAL).
M.NONCE_CACHE_MAX_ENTRIES = 512

-- Rate limiting bounds how many DISTINCT prompts (not how many datagrams) can
-- appear in a window, because the abuse this defends against is modal-dialog
-- stacking, not raw packet volume (the 32-datagrams/tick cap in
-- minfolio_pair.lua already bounds parse-time CPU cost). A fixed 10s window
-- with 3 prompts per source and 5 total is generous for a legitimate
-- pairing attempt (including a user who cancels and immediately retries)
-- while strictly bounding an attacker's ability to force a continuous stream
-- of prompts the user has to keep dismissing one at a time.
M.RATE_LIMIT_WINDOW_SECONDS = 10
M.RATE_LIMIT_PER_SOURCE = 3
M.RATE_LIMIT_GLOBAL = 5

-- Defensive upper bound on how many distinct source buckets are kept; in
-- normal operation pruning (see allowPrompt) keeps this at or below
-- RATE_LIMIT_GLOBAL, since only a granted prompt creates/refreshes a bucket
-- and grants are globally capped per window.
M.RATE_STATE_MAX_SOURCES = 64

-- How long a shown pairing ConfirmBox is allowed to sit unanswered before
-- minfolio_pair.lua force-releases the "one prompt at a time" gate. This is
-- a last-resort safety valve, not the primary release path (ok_callback and
-- cancel_callback are); see minfolio_pair.lua's own comment for why one is
-- still needed.
M.PROMPT_STUCK_TIMEOUT_SECONDS = 300

-- ---------------------------------------------------------------------------
-- Message-type allowlist. "ignore datagram types you do not recognise" so
-- that a future desktop (a later, separately-approved protocol revision)
-- cannot break this version by sending a type it doesn't understand.
-- ---------------------------------------------------------------------------

local KNOWN_TYPES = {
    ["minfolio-discover"] = true,
    ["minfolio-pair-request"] = true,
}

function M.isKnownType(t)
    return type(t) == "string" and KNOWN_TYPES[t] == true
end

-- "Accept an absent version field as v1." A present version is accepted
-- whenever it is a well-formed positive integer, whatever its value -- this
-- module only ever reads the fixed field set below regardless of `v`, so a
-- future, additive protocol revision that bumps the number cannot make an
-- old Kindle misinterpret anything; it can only add fields this code never
-- looks at. A malformed version field (not a number, not an integer, or less
-- than 1) is rejected as garbage rather than coerced.
function M.isWellFormedVersion(v)
    return v == nil or (type(v) == "number" and v == math.floor(v) and v >= 1)
end

-- ---------------------------------------------------------------------------
-- Field validation. Reject rather than coerce: every check is on the value's
-- actual type, never on a `tonumber()`/`tostring()` of it.
-- ---------------------------------------------------------------------------

local CODE_PATTERN = "^%d%d%d%d%d%d$"
local FINGERPRINT_PATTERN = "^%x+$"
-- Bounded, restricted charset: covers hex/decimal, UUIDs, and base64/base64url
-- tokens (with padding), which is generous for an "opaque" nonce per
-- PROTOCOL.md while still rejecting control characters, whitespace, quotes,
-- and anything else that isn't plausibly an opaque token.
local NONCE_PATTERN = "^[%w%-_%.%+/=]+$"
-- IPv4, IPv6 (colons), or a DNS hostname -- never shell/path/quote metachars.
local HOST_PATTERN = "^[%w%.%-:]+$"

function M.validNonceFormat(nonce)
    return type(nonce) == "string"
        and #nonce >= M.NONCE_MIN_LEN and #nonce <= M.NONCE_MAX_LEN
        and nonce:match(NONCE_PATTERN) ~= nil
end

-- True when `raw` (the still-encoded datagram bytes) is too large to even be
-- worth JSON-decoding. Call this BEFORE decoding, on every received
-- datagram -- decoding first and validating after still pays the parse cost
-- a flood is trying to impose.
function M.oversized(raw)
    return type(raw) ~= "string" or #raw > M.MAX_DATAGRAM_BYTES
end

-- Validates an already-decoded pair-request payload table. Returns `true` or
-- `false, reason`. Every one of code/host/port/fingerprint/nonce is checked
-- for type, length, and range.
--
-- Deliberately does NOT check a `type` field: per PROTOCOL.md §2, Channel A
-- (UDP) messages carry `type = "minfolio-pair-request"`, but Channel B (the
-- SSH-file-drop descriptor at `<MINFOLIO_REMOTE_DIR>/pair-request.lua`)
-- carries only "the same five fields" and no type tag at all -- the two
-- channels converge on this one validator precisely because both hand it
-- the same five-field shape. Routing on `msg.type` is the UDP caller's own
-- job (minfolio_pair.lua's `M.poll()` dispatch), not this function's.
function M.validatePairRequest(msg)
    if type(msg) ~= "table" then return false, "not a table" end
    if not M.isWellFormedVersion(msg.v) then return false, "malformed version" end

    if type(msg.code) ~= "string" or not msg.code:match(CODE_PATTERN) then
        return false, "malformed code"
    end
    if type(msg.host) ~= "string" or #msg.host == 0 or #msg.host > M.MAX_HOST_LEN
        or not msg.host:match(HOST_PATTERN) then
        return false, "malformed host"
    end
    if type(msg.port) ~= "number" or msg.port ~= math.floor(msg.port)
        or msg.port < M.MIN_PORT or msg.port > M.MAX_PORT then
        return false, "malformed port"
    end
    if type(msg.fingerprint) ~= "string" or #msg.fingerprint ~= M.FINGERPRINT_HEX_LEN
        or not msg.fingerprint:match(FINGERPRINT_PATTERN) then
        return false, "malformed fingerprint"
    end
    if not M.validNonceFormat(msg.nonce) then
        return false, "malformed nonce"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Nonce replay cache. Kept as an explicit state object (not module-global
-- state) so tests can create fresh, isolated caches.
-- ---------------------------------------------------------------------------

function M.newNonceCache()
    return { seen = {} }
end

function M.pruneNonceCache(cache, now)
    local count = 0
    for nonce, seen_at in pairs(cache.seen) do
        if now - seen_at > M.NONCE_TTL_SECONDS then
            cache.seen[nonce] = nil
        else
            count = count + 1
        end
    end
    if count > M.NONCE_CACHE_MAX_ENTRIES then
        -- Should not happen in normal operation (see the comment on
        -- NONCE_CACHE_MAX_ENTRIES above) -- fail safe by dropping the whole
        -- cache rather than growing it unboundedly.
        cache.seen = {}
    end
end

-- True when `nonce` was already remembered and has not yet expired -- i.e.
-- this is a replay and must be dropped.
function M.nonceSeen(cache, nonce, now)
    M.pruneNonceCache(cache, now)
    return cache.seen[nonce] ~= nil
end

function M.rememberNonce(cache, nonce, now)
    M.pruneNonceCache(cache, now)
    cache.seen[nonce] = now
end

-- ---------------------------------------------------------------------------
-- Prompt rate limiter: fixed windows, per-source and global.
-- ---------------------------------------------------------------------------

function M.newRateState()
    return { global = { windowStart = 0, count = 0 }, perSource = {} }
end

local function prune_rate_sources(state, now)
    local count = 0
    for src, s in pairs(state.perSource) do
        if now - s.windowStart >= M.RATE_LIMIT_WINDOW_SECONDS then
            state.perSource[src] = nil
        else
            count = count + 1
        end
    end
    if count > M.RATE_STATE_MAX_SOURCES then
        -- Extreme/anomalous case (see the comment on RATE_STATE_MAX_SOURCES);
        -- the global cap above still bounds total prompts regardless.
        state.perSource = {}
    end
end

-- Returns true iff a prompt for `source` (the UDP source address, or a fixed
-- string such as "local-file" for the SSH-file-drop channel) is allowed
-- right now, and if so records the grant against both the per-source and
-- global windows. Returns false, granting nothing, otherwise -- callers must
-- not show a prompt when this returns false.
function M.allowPrompt(state, source, now)
    source = tostring(source or "unknown")

    local g = state.global
    if now - g.windowStart >= M.RATE_LIMIT_WINDOW_SECONDS then
        g.windowStart, g.count = now, 0
    end
    if g.count >= M.RATE_LIMIT_GLOBAL then return false end

    local s = state.perSource[source]
    if not s or now - s.windowStart >= M.RATE_LIMIT_WINDOW_SECONDS then
        s = { windowStart = now, count = 0 }
    end
    if s.count >= M.RATE_LIMIT_PER_SOURCE then return false end

    g.count = g.count + 1
    s.count = s.count + 1
    state.perSource[source] = s
    prune_rate_sources(state, now)
    return true
end

return M
