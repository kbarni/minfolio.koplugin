-- SPDX-License-Identifier: AGPL-3.0-only
-- Pure, KOReader-free pairing store for minfolio.koplugin (PAIRING_PLAN.md WP 1,
-- §5.4, §5.7; ARCHITECTURE.md's Tier 0 rule). Deliberately zero KOReader
-- dependencies: no `require("ui/...")`, no `libs/libkoreader-lfs`, nothing that
-- only exists inside a running KOReader process -- only `io`/`os` from the
-- plain Lua standard library, both already on scripts/deploy.sh's GGET
-- allowlist. That is not a style preference, it is the only way any of this
-- can be checked off-device -- see minfolio_pairing_store_test.lua, runnable
-- with plain lua/luajit, no KOReader install required:
--   luajit minfolio_pairing_store_test.lua
--
-- Why this replaces the old `pairing.lua` format: the old file was
-- `return { secret = "<hex>" }` -- one secret, full stop, with no way to
-- express two paired desktops or "forget this one" (PAIRING_PLAN.md §1's
-- multi-device goal, §5.7's unpair). The new format is keyed by the
-- fingerprint of the desktop's own TLS certificate, the one identity the
-- Kindle actually pins against on every later connection (PROTOCOL.md §4):
--
--   { ["<64-hex-char fingerprint>"] = { secret = "<hex>", label = "<name>",
--                                        paired_at = <unix time> }, ... }
--
-- Migration is discard-only, deliberately (PAIRING_PLAN.md §5.3, "Migration
-- discards a working pairing... discard-and-re-pair is deliberate and
-- unambiguous"). The old format carries no fingerprint at all, so there is no
-- honest way to adopt its one secret into a fingerprint-keyed store -- every
-- candidate key would be a guess, and a wrong guess would pin a secret to the
-- wrong identity forever, which is worse than simply asking the user to
-- re-pair. M.migrate (below) is the ONLY place that interprets whatever a
-- store file's contents turned out to be; a file that isn't already a
-- well-formed new-format store -- old format, corrupt, or garbage -- is
-- discarded wholesale and reported as such, never partially adopted.
--
-- Every write goes through M.save, which writes to a sibling `.tmp` file,
-- reads it back through the same validation M.load itself uses, and only
-- then renames it over the live path -- so a crash mid-write, a truncated
-- write, or a bug that serializes something unreadable leaves the PREVIOUS
-- store file untouched rather than corrupting it in place.
--
-- Required by callers as `local Store = require("minfolio_pairing_store")`.

local M = {}

-- SHA-256 digest, hex-encoded: exactly 64 characters. Mirrors
-- minfolio_pair_msg.lua's FINGERPRINT_HEX_LEN -- both modules validate the
-- same shape of fingerprint, for the same reason (it's the TLS certificate
-- digest), but are kept independent rather than sharing a require: this
-- module must stay usable by itself (its own test suite requires nothing but
-- this file), and duplicating one integer constant is a smaller liability
-- than coupling the on-disk store format to the UDP message validator.
M.FINGERPRINT_LEN = 64
M.MAX_LABEL_LEN = 64

local FINGERPRINT_PATTERN = "^%x+$"

local function is_valid_fingerprint(fp)
    return type(fp) == "string" and #fp == M.FINGERPRINT_LEN and fp:match(FINGERPRINT_PATTERN) ~= nil
end

local function is_valid_entry(e)
    return type(e) == "table"
        and type(e.secret) == "string" and #e.secret > 0
        and type(e.label) == "string" and #e.label > 0 and #e.label <= M.MAX_LABEL_LEN
        and type(e.paired_at) == "number"
end

-- True iff `t` is a well-formed NEW-format store: every key is a valid
-- fingerprint, every value is a well-formed entry, and it does NOT also carry
-- the OLD format's bare top-level `secret` field. That last check matters
-- because an old-format file is just as much "a table" as a new-format one --
-- without it, a table that happens to have zero fingerprint-shaped keys AND a
-- top-level `secret` string would look like a valid (empty) new store rather
-- than what it actually is.
function M.isValidStore(t)
    if type(t) ~= "table" then return false end
    if t.secret ~= nil then return false end
    for k, v in pairs(t) do
        if not is_valid_fingerprint(k) then return false end
        if not is_valid_entry(v) then return false end
    end
    return true
end

-- Given whatever a store file's `dofile` actually produced -- a well-formed
-- new-format store, the old single-secret format, or outright garbage --
-- returns a store that is safe to use, plus whether anything had to be
-- discarded and why. This is the ONLY place old-format or malformed data is
-- interpreted; every other function in this module assumes it is already
-- looking at a clean store.
--
-- Returns (store, discarded, reason). `store` is always a valid table per
-- M.isValidStore, never nil.
function M.migrate(raw)
    if type(raw) ~= "table" then
        return {}, true, "store file did not produce a table"
    end
    if M.isValidStore(raw) then
        -- Still rebuilt field-by-field rather than returned as-is: a future
        -- change to what counts as "valid" must not let an old, already-
        -- validated table slip stale fields through unnoticed.
        local clean = {}
        for k, v in pairs(raw) do
            clean[k] = { secret = v.secret, label = v.label, paired_at = v.paired_at }
        end
        return clean, false, nil
    end
    if type(raw.secret) == "string" then
        return {}, true, "old single-secret pairing.lua format has no fingerprint; discarded, re-pair required"
    end
    return {}, true, "unrecognised or corrupt pairing store; discarded, re-pair required"
end

-- Loads the store at `path`. Returns (store, info):
--   store: always a valid table (per M.isValidStore), never nil.
--   info:  { existed = bool, discarded = bool, reason = string|nil }
--
-- A path that doesn't exist yet (first run, or right after a discard) is not
-- an error -- it's the same as an empty store, existed = false.
function M.load(path)
    if type(path) ~= "string" or path == "" then
        return {}, { existed = false, discarded = false, reason = "no path given" }
    end
    local f = io.open(path, "r")
    if not f then
        return {}, { existed = false, discarded = false }
    end
    f:close()
    local ok, result = pcall(dofile, path)
    if not ok then
        return {}, { existed = true, discarded = true, reason = "store file failed to load: " .. tostring(result) }
    end
    local clean, discarded, reason = M.migrate(result)
    return clean, { existed = true, discarded = discarded, reason = reason }
end

-- Lua-literal-quotes a string safely for use inside `return { ... }` source,
-- via the standard library's own %q (handles quotes, backslashes, newlines,
-- and control characters -- anything a label or secret could legally
-- contain -- without hand-rolling escaping logic that could disagree with
-- what the Lua reader on the other end actually accepts).
local function quote(s)
    return string.format("%q", s)
end

-- Serializes `store` (assumed already valid -- callers of M.save check this
-- first) as `dofile`-able Lua source. Keys are sorted so the output is
-- deterministic -- easier to diff by hand, and required for
-- minfolio_pairing_store_test.lua to assert exact output.
function M.serialize(store)
    local keys = {}
    for k in pairs(store) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = { "-- Minfolio pairing store. Keyed by the paired desktop's TLS certificate\n",
                     "-- fingerprint. Do not hand-edit; a malformed entry is discarded wholesale\n",
                     "-- on next load (minfolio_pairing_store.lua's M.migrate).\n",
                     "return {\n" }
    for _, k in ipairs(keys) do
        local e = store[k]
        parts[#parts + 1] = string.format("  [%s] = { secret = %s, label = %s, paired_at = %d },\n",
            quote(k), quote(e.secret), quote(e.label), math.floor(e.paired_at))
    end
    parts[#parts + 1] = "}\n"
    return table.concat(parts)
end

-- Writes `store` to `path` atomically. Refuses outright to serialize an
-- invalid store (defensive -- every mutator below already keeps the store
-- valid, but this is the last line of defence before anything touches disk).
-- The temp file is written, read back through M.load's own validation, and
-- only THEN renamed over the live path -- so a write that failed partway, or
-- somehow produced something unreadable, is caught before it can ever become
-- the store a later M.load would see. A crash between the write and the
-- rename leaves the OLD file at `path` completely untouched, because nothing
-- has renamed over it yet.
--
-- Returns (true) on success, or (false, reason) otherwise.
function M.save(path, store)
    if type(path) ~= "string" or path == "" then return false, "no path given" end
    if not M.isValidStore(store) then return false, "refusing to save an invalid store" end
    local tmp = path .. ".tmp"
    local f, ferr = io.open(tmp, "w")
    if not f then return false, ferr or "could not open temp file for writing" end
    local ok_write, werr = pcall(function() f:write(M.serialize(store)) end)
    f:close()
    if not ok_write then
        os.remove(tmp)
        return false, tostring(werr)
    end
    local loaded, info = M.load(tmp)
    if info.discarded or not M.isValidStore(loaded) then
        os.remove(tmp)
        return false, "written store failed validation on read-back; not installed"
    end
    local ok_rename, rerr = os.rename(tmp, path)
    if not ok_rename then
        os.remove(tmp)
        return false, rerr or "rename failed"
    end
    return true
end

-- Returns an array of { fingerprint, label, paired_at } sorted by label then
-- fingerprint, for a stable, predictable on-screen order. Deliberately never
-- includes `secret` -- nothing that renders this list (minfolio_pair_menu.lua)
-- has any legitimate reason to hold the secret in hand.
function M.list(store)
    local out = {}
    for fingerprint, e in pairs(store) do
        out[#out + 1] = { fingerprint = fingerprint, label = e.label, paired_at = e.paired_at }
    end
    table.sort(out, function(a, b)
        if a.label ~= b.label then return a.label < b.label end
        return a.fingerprint < b.fingerprint
    end)
    return out
end

-- Adds or replaces the pairing record for `fingerprint`. Validates every
-- field itself rather than trusting the caller, since a malformed record
-- written here would otherwise only be caught later, at save time, with a
-- less specific error. `label` is truncated (not rejected) when over-length
-- and defaulted when absent/empty, because a desktop-supplied label is
-- display text, not a security-relevant value -- rejecting the whole pairing
-- over a cosmetic field would be a worse failure mode than trimming it.
-- `paired_at` defaults to `os.time()` when absent so every real caller can
-- simply omit it; tests pass an explicit value for determinism.
--
-- Returns (true) on success, or (false, reason) if the fingerprint or secret
-- -- the two fields with real security weight -- are malformed.
function M.put(store, fingerprint, secret, label, paired_at)
    if not is_valid_fingerprint(fingerprint) then return false, "invalid fingerprint" end
    if type(secret) ~= "string" or #secret == 0 then return false, "invalid secret" end
    if type(label) ~= "string" or label == "" then label = "Unnamed desktop" end
    if #label > M.MAX_LABEL_LEN then label = label:sub(1, M.MAX_LABEL_LEN) end
    paired_at = tonumber(paired_at)
    if not paired_at then paired_at = os.time() end
    store[fingerprint] = { secret = secret, label = label, paired_at = math.floor(paired_at) }
    return true
end

-- Removes the pairing record for `fingerprint`. Returns true iff a record was
-- actually present and removed; false (a no-op) for an already-absent
-- fingerprint, so a caller can distinguish "deleted" from "nothing to do"
-- without needing its own presence check first.
function M.delete(store, fingerprint)
    if store[fingerprint] == nil then return false end
    store[fingerprint] = nil
    return true
end

function M.get(store, fingerprint)
    return store[fingerprint]
end

return M
