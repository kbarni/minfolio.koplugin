-- SPDX-License-Identifier: AGPL-3.0-only
-- Off-device unit tests for minfolio_pairing_store.lua (PAIRING_PLAN.md WP 1). Run
-- with plain lua/luajit, no KOReader install required:
--   luajit minfolio_pairing_store_test.lua
-- Exit code is 0 iff every assertion passed.

package.path = (arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or ".") .. "/?.lua;" .. package.path
local Store = require("minfolio_pairing_store")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL: " .. label .. "\n")
    end
end

-- A real-shaped 64-hex-char fingerprint, and a second one differing only in
-- the last byte, so tests can exercise "two distinct desktops" without typing
-- out full SHA-256 digests by hand.
local FP_A = string.rep("a1", 32)
local FP_B = string.rep("a1", 31) .. "b2"

-- Every test that touches disk uses its own fresh temp path (os.tmpname()),
-- and cleans up both the path and its `.tmp` sibling afterwards -- so a
-- failing assertion never leaves stray files behind for the next run to trip
-- over, and tests never share state through a hardcoded path.
local function fresh_path()
    return os.tmpname()
end
local function cleanup(path)
    os.remove(path)
    os.remove(path .. ".tmp")
end

-- `next` itself is not on scripts/deploy.sh's GGET stdlib allowlist (only
-- `pairs`, which this uses instead, already is) -- this avoids adding a
-- fifteenth allowlisted name for the sake of one "is this table empty?"
-- check across a handful of assertions.
local function is_empty(t)
    for _ in pairs(t) do return false end
    return true
end

-- ---------------------------------------------------------------------------
-- isValidStore
-- ---------------------------------------------------------------------------

check("an empty table is a valid (empty) store", Store.isValidStore({}) == true)
check("a well-formed single-entry store is valid",
    Store.isValidStore({ [FP_A] = { secret = "deadbeef", label = "Kal's MacBook", paired_at = 1000 } }) == true)
check("a non-table is never a valid store", Store.isValidStore("nope") == false)
check("nil is never a valid store", Store.isValidStore(nil) == false)
check("a table with the OLD top-level `secret` field is rejected outright, even if otherwise empty",
    Store.isValidStore({ secret = "deadbeef" }) == false)
check("a key that isn't a 64-hex-char fingerprint is rejected",
    Store.isValidStore({ ["not-a-fingerprint"] = { secret = "deadbeef", label = "x", paired_at = 1 } }) == false)
check("a fingerprint one char short of 64 is rejected",
    Store.isValidStore({ [string.rep("a", 63)] = { secret = "deadbeef", label = "x", paired_at = 1 } }) == false)
check("an entry missing `secret` is rejected",
    Store.isValidStore({ [FP_A] = { label = "x", paired_at = 1 } }) == false)
check("an entry with an empty secret is rejected",
    Store.isValidStore({ [FP_A] = { secret = "", label = "x", paired_at = 1 } }) == false)
check("an entry with a non-string label is rejected",
    Store.isValidStore({ [FP_A] = { secret = "deadbeef", label = 5, paired_at = 1 } }) == false)
check("an entry with a non-number paired_at is rejected",
    Store.isValidStore({ [FP_A] = { secret = "deadbeef", label = "x", paired_at = "1" } }) == false)
check("an entry that isn't a table is rejected",
    Store.isValidStore({ [FP_A] = "deadbeef" }) == false)

-- ---------------------------------------------------------------------------
-- migrate: the discard-and-re-pair contract (PAIRING_PLAN.md §5.3)
-- ---------------------------------------------------------------------------

do
    local clean, discarded, reason = Store.migrate({ secret = "deadbeefdeadbeef" })
    check("the OLD single-secret format is discarded, not adopted", discarded == true)
    check("migrating the old format returns an empty store", is_empty(clean))
    check("a reason is given for the old-format discard", type(reason) == "string" and #reason > 0)
end

do
    local clean, discarded = Store.migrate("not a table")
    check("a non-table raw value is discarded", discarded == true)
    check("migrating garbage returns an empty store", is_empty(clean))
end

do
    local clean, discarded = Store.migrate(nil)
    check("nil raw is discarded", discarded == true)
    check("migrating nil returns an empty store", is_empty(clean))
end

do
    local clean, discarded = Store.migrate(42)
    check("a number raw value is discarded", discarded == true)
end

do
    local valid = { [FP_A] = { secret = "deadbeef", label = "Kal's MacBook", paired_at = 1000 } }
    local clean, discarded, reason = Store.migrate(valid)
    check("a well-formed new-format store is NOT discarded", discarded == false)
    check("no discard reason is given when nothing was discarded", reason == nil)
    check("migrating a valid store preserves its entry", clean[FP_A] ~= nil and clean[FP_A].secret == "deadbeef")
end

-- ---------------------------------------------------------------------------
-- load: nonexistent path is an empty store, not an error
-- ---------------------------------------------------------------------------

do
    local path = fresh_path()
    os.remove(path) -- os.tmpname() creates the file on some platforms; ensure it does NOT exist
    local store, info = Store.load(path)
    check("loading a nonexistent path returns an empty store", is_empty(store))
    check("loading a nonexistent path reports existed = false", info.existed == false)
    check("loading a nonexistent path reports discarded = false", info.discarded == false)
end

-- ---------------------------------------------------------------------------
-- load: a corrupt / non-Lua file is discarded, never thrown
-- ---------------------------------------------------------------------------

do
    local path = fresh_path()
    local f = io.open(path, "w")
    f:write("this is not valid Lua source at all {{{\n")
    f:close()
    local store, info = Store.load(path)
    check("a corrupt file yields an empty store", is_empty(store))
    check("a corrupt file is reported as existed = true", info.existed == true)
    check("a corrupt file is reported as discarded = true", info.discarded == true)
    cleanup(path)
end

-- ---------------------------------------------------------------------------
-- load: a file in the OLD single-secret format is discarded, existed = true
-- ---------------------------------------------------------------------------

do
    local path = fresh_path()
    local f = io.open(path, "w")
    f:write('return { secret = "deadbeefdeadbeefdeadbeef" }\n')
    f:close()
    local store, info = Store.load(path)
    check("an old-format file yields an empty store", is_empty(store))
    check("an old-format file is reported as existed = true", info.existed == true)
    check("an old-format file is reported as discarded = true", info.discarded == true)
    cleanup(path)
end

-- ---------------------------------------------------------------------------
-- save + load round trip
-- ---------------------------------------------------------------------------

do
    local path = fresh_path()
    os.remove(path)
    local store = {}
    Store.put(store, FP_A, "secretA", "Kal's MacBook", 1000)
    Store.put(store, FP_B, "secretB", "Work desktop", 2000)
    local ok, err = Store.save(path, store)
    check("saving a valid two-entry store succeeds", ok == true, err)

    local loaded, info = Store.load(path)
    check("round-tripped load reports discarded = false", info.discarded == false)
    check("round-tripped store keeps the first entry's secret", loaded[FP_A] and loaded[FP_A].secret == "secretA")
    check("round-tripped store keeps the first entry's label", loaded[FP_A] and loaded[FP_A].label == "Kal's MacBook")
    check("round-tripped store keeps the first entry's paired_at", loaded[FP_A] and loaded[FP_A].paired_at == 1000)
    check("round-tripped store keeps the second entry", loaded[FP_B] and loaded[FP_B].secret == "secretB")

    local left_tmp = io.open(path .. ".tmp", "r")
    check("no leftover .tmp file remains after a successful save", left_tmp == nil)
    if left_tmp then left_tmp:close() end

    cleanup(path)
end

-- ---------------------------------------------------------------------------
-- save: labels containing quotes, backslashes, and newlines survive %q
-- round-tripping intact
-- ---------------------------------------------------------------------------

do
    local path = fresh_path()
    os.remove(path)
    local tricky = 'Kal\'s "office" PC\\backup\nsecond line'
    local store = {}
    Store.put(store, FP_A, "secretA", tricky, 1000)
    local ok = Store.save(path, store)
    check("saving a store with a tricky label succeeds", ok == true)
    local loaded = Store.load(path)
    check("a label with quotes/backslashes/newlines round-trips byte-for-byte",
        loaded[FP_A] and loaded[FP_A].label == tricky)
    cleanup(path)
end

-- ---------------------------------------------------------------------------
-- save: refuses to write an invalid store, and does not clobber whatever was
-- already at that path
-- ---------------------------------------------------------------------------

do
    local path = fresh_path()
    os.remove(path)
    local good = {}
    Store.put(good, FP_A, "secretA", "Kal's MacBook", 1000)
    check("priming the path with a valid store succeeds", Store.save(path, good) == true)

    local bad = { ["short"] = { secret = "x", label = "y", paired_at = 1 } } -- invalid fingerprint key
    local ok, err = Store.save(path, bad)
    check("saving an invalid store is refused", ok == false)
    check("a refusal reason is given", type(err) == "string" and #err > 0)

    local still_there = Store.load(path)
    check("the previously-saved valid store is untouched after a refused save",
        still_there[FP_A] and still_there[FP_A].secret == "secretA")

    local left_tmp = io.open(path .. ".tmp", "r")
    check("a refused save leaves no .tmp file behind either", left_tmp == nil)
    if left_tmp then left_tmp:close() end

    cleanup(path)
end

check("save() with no path is refused", (function()
    local ok = Store.save(nil, {})
    return ok == false
end)())
check("save() of a non-table is refused", (function()
    local ok = Store.save(fresh_path(), "not a store")
    return ok == false
end)())

-- ---------------------------------------------------------------------------
-- put: validation, defaulting, and truncation
-- ---------------------------------------------------------------------------

do
    local store = {}
    check("put() with an invalid fingerprint is refused", Store.put(store, "not-hex", "s", "l", 1) == false)
    check("put() with an empty secret is refused", Store.put(store, FP_A, "", "l", 1) == false)
    check("put() with a non-string secret is refused", Store.put(store, FP_A, 42, "l", 1) == false)
end

do
    local store = {}
    check("put() succeeds with a well-formed fingerprint/secret", Store.put(store, FP_A, "s", "My PC", 1) == true)
end

do
    local store = {}
    Store.put(store, FP_A, "s", nil, 1000)
    check("an absent label defaults to a generic name", store[FP_A].label == "Unnamed desktop")
end

do
    local store = {}
    Store.put(store, FP_A, "s", "", 1000)
    check("an empty-string label defaults to a generic name", store[FP_A].label == "Unnamed desktop")
end

do
    local store = {}
    local long = string.rep("x", Store.MAX_LABEL_LEN + 20)
    Store.put(store, FP_A, "s", long, 1000)
    check("an over-length label is truncated, not rejected", #store[FP_A].label == Store.MAX_LABEL_LEN)
end

do
    local store = {}
    Store.put(store, FP_A, "s", "My PC") -- paired_at omitted
    check("an omitted paired_at defaults to something (os.time())", type(store[FP_A].paired_at) == "number")
end

-- ---------------------------------------------------------------------------
-- delete
-- ---------------------------------------------------------------------------

do
    local store = {}
    Store.put(store, FP_A, "s", "My PC", 1)
    check("delete() of a present fingerprint returns true", Store.delete(store, FP_A) == true)
    check("the entry is actually gone after delete()", store[FP_A] == nil)
    check("delete() of an already-absent fingerprint returns false (no-op)", Store.delete(store, FP_A) == false)
end

-- ---------------------------------------------------------------------------
-- get
-- ---------------------------------------------------------------------------

do
    local store = {}
    Store.put(store, FP_A, "s", "My PC", 1)
    check("get() returns the entry for a present fingerprint", Store.get(store, FP_A) ~= nil)
    check("get() returns nil for an absent fingerprint", Store.get(store, FP_B) == nil)
end

-- ---------------------------------------------------------------------------
-- list: sorted, and never exposes the secret
-- ---------------------------------------------------------------------------

do
    local store = {}
    Store.put(store, FP_A, "secretA", "Zebra desktop", 1000)
    Store.put(store, FP_B, "secretB", "Alpha desktop", 2000)
    local list = Store.list(store)
    check("list() returns one entry per paired desktop", #list == 2)
    check("list() sorts by label", list[1].label == "Alpha desktop" and list[2].label == "Zebra desktop")
    check("list() entries carry the fingerprint", list[1].fingerprint == FP_B)
    check("list() entries carry paired_at", list[1].paired_at == 2000)
    check("list() entries do NOT carry the secret", list[1].secret == nil and list[2].secret == nil)
end

do
    check("list() of an empty store returns an empty array", #Store.list({}) == 0)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
