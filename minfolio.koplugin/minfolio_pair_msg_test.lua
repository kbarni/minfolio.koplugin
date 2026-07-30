-- SPDX-License-Identifier: AGPL-3.0-only
-- Off-device unit tests for minfolio_pair_msg.lua (PAIRING_PLAN.md §5.8, §3). Run with plain
-- lua/luajit, no KOReader install required:
--   luajit minfolio_pair_msg_test.lua
-- Exit code is 0 iff every assertion passed.

package.path = (arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or ".") .. "/?.lua;" .. package.path
local PairMsg = require("minfolio_pair_msg")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL: " .. label .. "\n")
    end
end

-- A well-formed baseline message every rejection test mutates one field of,
-- so each test isolates exactly one reason for rejection.
local function valid_msg()
    return {
        type = "minfolio-pair-request",
        code = "123456",
        host = "198.51.100.7",
        port = 8443,
        fingerprint = string.rep("a1", 32), -- 64 hex chars
        nonce = "abcDEF123_-.",
    }
end

-- ---------------------------------------------------------------------------
-- validatePairRequest: the happy path
-- ---------------------------------------------------------------------------

check("a well-formed message passes validation", PairMsg.validatePairRequest(valid_msg()) == true)

do
    local m = valid_msg()
    m.v = 1
    check("an explicit v=1 still passes", PairMsg.validatePairRequest(m) == true)
end

do
    -- Forward compatibility: "so a future desktop cannot break this one" --
    -- a message with a version we don't recognise the exact history of is
    -- still validated against the FIXED fields this code knows how to check;
    -- it is not rejected purely for carrying a version number that isn't 1.
    local m = valid_msg()
    m.v = 2
    check("a numeric version other than 1 does not by itself cause rejection", PairMsg.validatePairRequest(m) == true)
end

-- ---------------------------------------------------------------------------
-- Oversized datagrams (checked before JSON decoding, on raw bytes)
-- ---------------------------------------------------------------------------

check("a datagram exactly at the size cap is not oversized",
    PairMsg.oversized(string.rep("x", PairMsg.MAX_DATAGRAM_BYTES)) == false)
check("a datagram one byte over the size cap is oversized",
    PairMsg.oversized(string.rep("x", PairMsg.MAX_DATAGRAM_BYTES + 1)) == true)
check("a non-string raw value is treated as oversized/invalid", PairMsg.oversized(nil) == true)
check("a huge datagram is oversized", PairMsg.oversized(string.rep("x", 1024 * 1024)) == true)

-- ---------------------------------------------------------------------------
-- Non-table / garbage top-level messages must never error, only reject
-- ---------------------------------------------------------------------------

check("nil message rejected", PairMsg.validatePairRequest(nil) == false)
check("string message rejected (e.g. a bare JSON string literal)", PairMsg.validatePairRequest("not a table") == false)
check("number message rejected (e.g. a bare JSON number literal)", PairMsg.validatePairRequest(42) == false)
check("boolean message rejected (e.g. a bare JSON true/false literal)", PairMsg.validatePairRequest(true) == false)

-- ---------------------------------------------------------------------------
-- validatePairRequest deliberately does not gate on a `type` field: Channel B
-- (the SSH-file-drop descriptor, PROTOCOL.md §2) carries the same five
-- fields with no `type` tag at all, so both channels can converge on this one
-- validator. Type-based routing is minfolio_pair.lua's `M.poll()` dispatch's
-- own job, exercised as part of the discover/pair-request branch, not here.
-- ---------------------------------------------------------------------------

do
    local m = valid_msg()
    m.type = nil -- Channel B shape: no type field at all
    check("a message with no type field at all still validates (Channel B has none)", PairMsg.validatePairRequest(m) == true)
end
do
    local m = valid_msg()
    m.type = "minfolio-discover" -- an irrelevant/unrelated type value present alongside valid fields
    check("an incidental type field does not affect field validation either way", PairMsg.validatePairRequest(m) == true)
end

-- ---------------------------------------------------------------------------
-- Wrong types for otherwise-present fields (reject, do not coerce)
-- ---------------------------------------------------------------------------

do
    local m = valid_msg(); m.code = 123456
    check("a numeric code is rejected, not coerced to a string", PairMsg.validatePairRequest(m) == false)
end
do
    local m = valid_msg(); m.host = 12345
    check("a numeric host is rejected", PairMsg.validatePairRequest(m) == false)
end
do
    local m = valid_msg(); m.port = "8443"
    check("a string port is rejected, not coerced to a number", PairMsg.validatePairRequest(m) == false)
end
do
    local m = valid_msg(); m.fingerprint = 123
    check("a numeric fingerprint is rejected", PairMsg.validatePairRequest(m) == false)
end
do
    local m = valid_msg(); m.nonce = { "not", "a", "string" }
    check("a table nonce is rejected", PairMsg.validatePairRequest(m) == false)
end

-- ---------------------------------------------------------------------------
-- Out-of-range port
-- ---------------------------------------------------------------------------

check("port 1 (minimum) is valid", (function() local m = valid_msg(); m.port = 1; return PairMsg.validatePairRequest(m) end)())
check("port 65535 (maximum) is valid", (function() local m = valid_msg(); m.port = 65535; return PairMsg.validatePairRequest(m) end)())
check("port 0 is rejected", not (function() local m = valid_msg(); m.port = 0; return PairMsg.validatePairRequest(m) end)())
check("a negative port is rejected", not (function() local m = valid_msg(); m.port = -1; return PairMsg.validatePairRequest(m) end)())
check("port 65536 (one over maximum) is rejected", not (function() local m = valid_msg(); m.port = 65536; return PairMsg.validatePairRequest(m) end)())
check("a non-integer port is rejected", not (function() local m = valid_msg(); m.port = 8443.5; return PairMsg.validatePairRequest(m) end)())

-- ---------------------------------------------------------------------------
-- Malformed fingerprint
-- ---------------------------------------------------------------------------

check("a fingerprint one char short of 64 is rejected",
    not (function() local m = valid_msg(); m.fingerprint = string.rep("a", 63); return PairMsg.validatePairRequest(m) end)())
check("a fingerprint one char over 64 is rejected",
    not (function() local m = valid_msg(); m.fingerprint = string.rep("a", 65); return PairMsg.validatePairRequest(m) end)())
check("an empty fingerprint is rejected",
    not (function() local m = valid_msg(); m.fingerprint = ""; return PairMsg.validatePairRequest(m) end)())
check("a fingerprint containing a non-hex character is rejected",
    not (function() local m = valid_msg(); m.fingerprint = string.rep("a", 63) .. "g"; return PairMsg.validatePairRequest(m) end)())
check("a 64-char uppercase-hex fingerprint is accepted",
    (function() local m = valid_msg(); m.fingerprint = string.rep("AB", 32); return PairMsg.validatePairRequest(m) end)())

-- ---------------------------------------------------------------------------
-- Bad code format
-- ---------------------------------------------------------------------------

check("a 5-digit code is rejected", not (function() local m = valid_msg(); m.code = "12345"; return PairMsg.validatePairRequest(m) end)())
check("a 7-digit code is rejected", not (function() local m = valid_msg(); m.code = "1234567"; return PairMsg.validatePairRequest(m) end)())
check("a code containing a letter is rejected", not (function() local m = valid_msg(); m.code = "12345a"; return PairMsg.validatePairRequest(m) end)())
check("a code with a leading space is rejected", not (function() local m = valid_msg(); m.code = " 12345"; return PairMsg.validatePairRequest(m) end)())
check("an empty code is rejected", not (function() local m = valid_msg(); m.code = ""; return PairMsg.validatePairRequest(m) end)())

-- ---------------------------------------------------------------------------
-- Bad host
-- ---------------------------------------------------------------------------

check("an empty host is rejected", not (function() local m = valid_msg(); m.host = ""; return PairMsg.validatePairRequest(m) end)())
check("a host over the length cap is rejected",
    not (function() local m = valid_msg(); m.host = string.rep("a", PairMsg.MAX_HOST_LEN + 1); return PairMsg.validatePairRequest(m) end)())
check("a host at exactly the length cap is accepted",
    (function() local m = valid_msg(); m.host = string.rep("a", PairMsg.MAX_HOST_LEN); return PairMsg.validatePairRequest(m) end)())
check("a host containing a space is rejected", not (function() local m = valid_msg(); m.host = "evil host"; return PairMsg.validatePairRequest(m) end)())
check("a host containing shell metacharacters is rejected",
    not (function() local m = valid_msg(); m.host = "host;rm -rf /"; return PairMsg.validatePairRequest(m) end)())
check("an IPv6 literal (colons) is accepted", (function() local m = valid_msg(); m.host = "fe80::1"; return PairMsg.validatePairRequest(m) end)())

-- ---------------------------------------------------------------------------
-- Bad nonce
-- ---------------------------------------------------------------------------

check("a nonce shorter than the minimum is rejected",
    not (function() local m = valid_msg(); m.nonce = string.rep("a", PairMsg.NONCE_MIN_LEN - 1); return PairMsg.validatePairRequest(m) end)())
check("a nonce at exactly the minimum length is accepted",
    (function() local m = valid_msg(); m.nonce = string.rep("a", PairMsg.NONCE_MIN_LEN); return PairMsg.validatePairRequest(m) end)())
check("a nonce over the maximum length is rejected",
    not (function() local m = valid_msg(); m.nonce = string.rep("a", PairMsg.NONCE_MAX_LEN + 1); return PairMsg.validatePairRequest(m) end)())
check("a nonce at exactly the maximum length is accepted",
    (function() local m = valid_msg(); m.nonce = string.rep("a", PairMsg.NONCE_MAX_LEN); return PairMsg.validatePairRequest(m) end)())
check("a nonce containing whitespace is rejected", not (function() local m = valid_msg(); m.nonce = "abc def"; return PairMsg.validatePairRequest(m) end)())
check("a nonce containing a quote is rejected", not (function() local m = valid_msg(); m.nonce = 'abc"def'; return PairMsg.validatePairRequest(m) end)())
check("an empty nonce is rejected", not (function() local m = valid_msg(); m.nonce = ""; return PairMsg.validatePairRequest(m) end)())

-- ---------------------------------------------------------------------------
-- Version tolerance
-- ---------------------------------------------------------------------------

check("absent version field is well-formed (treated as v1)", PairMsg.isWellFormedVersion(nil) == true)
check("v=1 is well-formed", PairMsg.isWellFormedVersion(1) == true)
check("v=2 is well-formed (a future, additive bump)", PairMsg.isWellFormedVersion(2) == true)
check("v=0 is not well-formed (versions start at 1)", PairMsg.isWellFormedVersion(0) == false)
check("a negative version is not well-formed", PairMsg.isWellFormedVersion(-1) == false)
check("a fractional version is not well-formed", PairMsg.isWellFormedVersion(1.5) == false)
check("a string version is not well-formed (reject, do not coerce)", PairMsg.isWellFormedVersion("1") == false)
check("a boolean version is not well-formed", PairMsg.isWellFormedVersion(true) == false)
do
    local m = valid_msg(); m.v = "1"
    check("a string-typed v field on a full message is rejected", PairMsg.validatePairRequest(m) == false)
end

-- ---------------------------------------------------------------------------
-- isKnownType: "ignore datagram types you do not recognise"
-- ---------------------------------------------------------------------------

check("minfolio-discover is a known type", PairMsg.isKnownType("minfolio-discover") == true)
check("minfolio-pair-request is a known type", PairMsg.isKnownType("minfolio-pair-request") == true)
check("a hypothetical future type is NOT known (must be ignored, not invented here)",
    PairMsg.isKnownType("minfolio-pair-offer") == false)
check("an empty string is not a known type", PairMsg.isKnownType("") == false)
check("a nil type is not known", PairMsg.isKnownType(nil) == false)
check("a non-string type is not known", PairMsg.isKnownType(123) == false)

-- ---------------------------------------------------------------------------
-- Replayed nonce
-- ---------------------------------------------------------------------------

do
    local cache = PairMsg.newNonceCache()
    local now = 1000
    check("a nonce not yet remembered is not a replay", PairMsg.nonceSeen(cache, "abc123", now) == false)
    PairMsg.rememberNonce(cache, "abc123", now)
    check("the same nonce is a replay immediately after being remembered", PairMsg.nonceSeen(cache, "abc123", now) == true)
    check("the same nonce is still a replay shortly afterwards", PairMsg.nonceSeen(cache, "abc123", now + 5) == true)
    check("a different nonce in the same cache is not a replay", PairMsg.nonceSeen(cache, "xyz789", now) == false)
end

-- ---------------------------------------------------------------------------
-- Expired nonce: the TTL must actually let a nonce age out of the cache
-- ---------------------------------------------------------------------------

do
    local cache = PairMsg.newNonceCache()
    local now = 2000
    PairMsg.rememberNonce(cache, "will-expire", now)
    check("a nonce is still a replay just before its TTL elapses",
        PairMsg.nonceSeen(cache, "will-expire", now + PairMsg.NONCE_TTL_SECONDS) == true)
    check("a nonce is no longer a replay once its TTL has elapsed",
        PairMsg.nonceSeen(cache, "will-expire", now + PairMsg.NONCE_TTL_SECONDS + 1) == false)
end

-- ---------------------------------------------------------------------------
-- Rate limiting: per-source and global
-- ---------------------------------------------------------------------------

do
    local state = PairMsg.newRateState()
    local now = 5000
    for i = 1, PairMsg.RATE_LIMIT_PER_SOURCE do
        check("prompt " .. i .. " is allowed for a source within its per-source budget",
            PairMsg.allowPrompt(state, "1.2.3.4", now) == true)
    end
    check("a prompt beyond the per-source budget is rejected within the same window",
        PairMsg.allowPrompt(state, "1.2.3.4", now) == false)
    check("a different source is not blocked by another source's exhausted budget",
        PairMsg.allowPrompt(state, "5.6.7.8", now) == true)
    check("the exhausted source's budget resets once the window has fully elapsed",
        PairMsg.allowPrompt(state, "1.2.3.4", now + PairMsg.RATE_LIMIT_WINDOW_SECONDS + 1) == true)
end

do
    -- Global cap: even across many distinct sources, only RATE_LIMIT_GLOBAL
    -- prompts may be granted within one window -- otherwise a spoofed-source
    -- flood could bypass the per-source limit just by rotating addresses.
    local state = PairMsg.newRateState()
    local now = 9000
    local granted = 0
    for i = 1, PairMsg.RATE_LIMIT_GLOBAL do
        if PairMsg.allowPrompt(state, "src-" .. i, now) then granted = granted + 1 end
    end
    check("exactly RATE_LIMIT_GLOBAL prompts are granted across distinct sources in one window",
        granted == PairMsg.RATE_LIMIT_GLOBAL)
    check("one more distinct source is blocked once the global cap is reached",
        PairMsg.allowPrompt(state, "src-overflow", now) == false)
    check("the global cap resets once the window has fully elapsed",
        PairMsg.allowPrompt(state, "src-overflow", now + PairMsg.RATE_LIMIT_WINDOW_SECONDS + 1) == true)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
