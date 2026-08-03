-- SPDX-License-Identifier: AGPL-3.0-only
-- Off-device unit tests for minfolio_find.lua (PLAN.md §7.1). Run with plain lua/luajit, no
-- KOReader install required:
--   luajit minfolio_find_test.lua
-- Exit code is 0 iff every assertion passed.

package.path = (arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or ".") .. "/?.lua;" .. package.path
local Find = require("minfolio_find")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL: " .. label .. "\n")
    end
end

-- The editor's column convention: the cursor at column c sits BEFORE byte c+1,
-- so a match covers line:sub(start_col+1, end_col). MDEdit:showFindMatch sets
-- self.sel to start_col and the cursor to end_col, which is why these are not
-- interchangeable and why the tests below assert both.
local function matched_text(lines, match)
    return lines[match.row]:sub(match.start_col + 1, match.end_col)
end

-- ---------------------------------------------------------------------------
-- matches
-- ---------------------------------------------------------------------------

do
    local lines = { "the quick brown fox", "jumps over the lazy dog" }
    local found = Find.matches(lines, "the")
    check("matches: finds every occurrence across lines", #found == 2)
    check("matches: first result is on the first line at column 0",
        found[1].row == 1 and found[1].start_col == 0 and found[1].end_col == 3)
    check("matches: the reported range covers exactly the query text",
        matched_text(lines, found[1]) == "the" and matched_text(lines, found[2]) == "the")
    check("matches: results are ordered by row", found[1].row < found[2].row)
end

do
    local lines = { "one one one" }
    local found = Find.matches(lines, "one")
    check("matches: repeated hits on one line are all found", #found == 3)
    check("matches: hits on one line are ordered left to right",
        found[1].start_col == 0 and found[2].start_col == 4 and found[3].start_col == 8)
end

do
    -- Non-overlapping, like a standard Find: "aaaa" contains two "aa", not three.
    local found = Find.matches({ "aaaa" }, "aa")
    check("matches: results do not overlap", #found == 2)
    check("matches: the second result starts after the first one ends",
        found[2].start_col == found[1].end_col)
end

do
    local lines = { "Kindle KINDLE kindle" }
    local found = Find.matches(lines, "kindle")
    check("matches: search is case-insensitive", #found == 3)
    check("matches: a lowercase query still reports the original mixed case",
        matched_text(lines, found[1]) == "Kindle" and matched_text(lines, found[2]) == "KINDLE")
    check("matches: an uppercase query finds lowercase text",
        #Find.matches(lines, "KINDLE") == 3)
end

do
    -- Literal matching, not Lua patterns: these queries are all pattern magic
    -- and must find themselves rather than being interpreted.
    check("matches: a query containing '-' is literal", #Find.matches({ "a-b" }, "a-b") == 1)
    check("matches: a query containing '%' is literal", #Find.matches({ "50% off" }, "50%") == 1)
    check("matches: a query containing '.' does not match any character",
        #Find.matches({ "axb" }, "a.b") == 0)
    check("matches: a query of '*' finds a literal asterisk",
        #Find.matches({ "**bold**" }, "*") == 4)
    check("matches: a bracketed query is literal", #Find.matches({ "- [ ] task" }, "[ ]") == 1)
end

check("matches: an empty query finds nothing", #Find.matches({ "text" }, "") == 0)
check("matches: a nil query finds nothing", #Find.matches({ "text" }, nil) == 0)
check("matches: nil lines find nothing", #Find.matches(nil, "text") == 0)
check("matches: no occurrence yields an empty list", #Find.matches({ "abc" }, "zzz") == 0)
check("matches: an empty document finds nothing", #Find.matches({}, "text") == 0)

do
    -- Byte columns, not character columns: the editor's cursor is a byte offset,
    -- so a match after a multi-byte character must report the byte position.
    local lines = { "caf\195\169 latte" }   -- "café latte", é is 2 bytes
    local found = Find.matches(lines, "latte")
    check("matches: columns are byte offsets, past a multibyte character",
        found[1].start_col == 6 and found[1].end_col == 11)
    check("matches: the byte range still slices the right text",
        matched_text(lines, found[1]) == "latte")
end

-- ---------------------------------------------------------------------------
-- sanitize_replacement
-- ---------------------------------------------------------------------------

check("sanitize_replacement: ordinary text passes through", Find.sanitize_replacement("hello") == "hello")
check("sanitize_replacement: a newline becomes a space", Find.sanitize_replacement("a\nb") == "a b")
check("sanitize_replacement: a carriage return becomes a space", Find.sanitize_replacement("a\r\nb") == "a  b")
check("sanitize_replacement: nil becomes the empty string", Find.sanitize_replacement(nil) == "")
check("sanitize_replacement: returns exactly one value, not gsub's count too",
    select("#", Find.sanitize_replacement("a\nb")) == 1)

-- ---------------------------------------------------------------------------
-- replace_one
-- ---------------------------------------------------------------------------

do
    local lines = { "the quick fox", "the lazy dog" }
    local found = Find.matches(lines, "quick")
    local out, col = Find.replace_one(lines, found[1], "slow")
    check("replace_one: the match is replaced", out[1] == "the slow fox")
    check("replace_one: other lines are untouched", out[2] == "the lazy dog")
    check("replace_one: returns the column just past the replacement", col == 8)
    check("replace_one: the caller's array is NOT mutated (undo holds references to it)",
        lines[1] == "the quick fox")
end

do
    local lines = { "aaa" }
    local out = Find.replace_one(lines, Find.matches(lines, "aaa")[1], "")
    check("replace_one: an empty replacement deletes the match", out[1] == "")
end

do
    local lines = { "hello" }
    local out, col = Find.replace_one(lines, nil, "x")
    check("replace_one: a nil match returns the lines unchanged", out[1] == "hello")
    check("replace_one: a nil match reports no cursor column", col == nil)
end

do
    local lines = { "one" }
    local out = Find.replace_one(lines, { row = 9, start_col = 0, end_col = 1 }, "x")
    check("replace_one: a match pointing past the end is ignored, not an error", out[1] == "one")
end

-- ---------------------------------------------------------------------------
-- replace_all
-- ---------------------------------------------------------------------------

do
    local lines = { "cat dog cat", "cat" }
    local out, count = Find.replace_all(lines, "cat", "bird")
    check("replace_all: reports how many replacements it made", count == 3)
    check("replace_all: replaces every hit on a line, not just the first",
        out[1] == "bird dog bird")
    check("replace_all: replaces across lines", out[2] == "bird")
    check("replace_all: the caller's array is NOT mutated", lines[1] == "cat dog cat")
end

do
    -- The reason the splice runs backwards: a LONGER replacement shifts every
    -- later column on the same line. Left to right, the second hit would be
    -- spliced at a stale offset and land inside the wrong text.
    local out = Find.replace_all({ "x x x" }, "x", "long")
    check("replace_all: a longer replacement does not corrupt later hits on the same line",
        out[1] == "long long long")
end

do
    -- And a SHORTER one, the same failure in the other direction.
    local out = Find.replace_all({ "alpha alpha alpha" }, "alpha", "a")
    check("replace_all: a shorter replacement does not corrupt later hits on the same line",
        out[1] == "a a a")
end

do
    -- A replacement containing the query must terminate rather than rescanning
    -- its own output: matches are fixed before any text changes.
    local out, count = Find.replace_all({ "a a" }, "a", "aa")
    check("replace_all: a replacement containing the query terminates", out[1] == "aa aa")
    check("replace_all: and replaces each original hit exactly once", count == 2)
end

do
    local out, count = Find.replace_all({ "keep me" }, "absent", "x")
    check("replace_all: no matches means no replacements", count == 0)
    check("replace_all: no matches leaves the text alone", out[1] == "keep me")
end

do
    local out, count = Find.replace_all({ "text" }, "", "x")
    check("replace_all: an empty query replaces nothing", count == 0 and out[1] == "text")
end

do
    local out, count = Find.replace_all({ "Kindle and kindle" }, "kindle", "Kobo")
    check("replace_all: case-insensitive matching replaces both casings", count == 2)
    check("replace_all: replacement case is literal, it does not follow the original",
        out[1] == "Kobo and Kobo")
end

do
    local out = Find.replace_all({ "delete me here" }, "me ", "")
    check("replace_all: an empty replacement deletes every hit", out[1] == "delete here")
end

do
    -- Whole-document shape is preserved: same number of lines out as in.
    local lines = { "a", "b", "a" }
    local out = Find.replace_all(lines, "a", "z")
    check("replace_all: the line count is unchanged", #out == 3)
    check("replace_all: untouched lines are carried through", out[2] == "b")
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
