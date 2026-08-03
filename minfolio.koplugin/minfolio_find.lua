-- SPDX-License-Identifier: AGPL-3.0-only
-- Find and replace over an array of document lines, for minfolio.koplugin
-- (PLAN.md §5 Tier 0). Deliberately zero KOReader dependencies: no
-- `require("ui/...")`, no UIManager, nothing that only exists inside a running
-- KOReader process. That is not a style preference, it is the only way any of
-- this can be checked off-device -- see minfolio_find_test.lua, runnable with
-- plain lua/luajit, no KOReader install required:
--   luajit minfolio_find_test.lua
--
-- `M.matches` is the body of what was MDEdit:findMatches, moved here unchanged
-- so that the search half and the replace half share one definition of what a
-- match is. The editor's findMatches now delegates to it. Everything about the
-- match convention comes from that original code and is relied on by
-- MDEdit:showFindMatch, so none of it is free to change:
--   * matching is case-insensitive and literal (`find(..., true)`), never a
--     Lua pattern -- a query containing '-' or '%' has to find itself;
--   * results are non-overlapping, scanning each line left to right, exactly
--     like a standard Find;
--   * a match is { row = 1-based line, start_col, end_col } where the columns
--     are BYTE offsets in the editor's convention: the cursor at column c sits
--     before byte c+1, so the matched text is line:sub(start_col+1, end_col);
--   * matches come back ordered by row, then by column within the row -- which
--     is what lets `replace_all` below splice from the end backwards.
--
-- Replacement is literal and does NOT preserve the case of what it replaced:
-- replacing "kindle" with "Kindle" changes every casing to "Kindle", which is
-- usually the point of running it.
--
-- Required by callers as `local Find = require("minfolio_find")`.

local M = {}

function M.matches(lines, query)
    if not query or query == "" then return {} end
    local needle = query:lower()
    local out = {}
    for row, line in ipairs(lines or {}) do
        local haystack = tostring(line or ""):lower()
        local from = 1
        while true do
            local first, last = haystack:find(needle, from, true)
            if not first then break end
            out[#out + 1] = { row = row, start_col = first - 1, end_col = last }
            from = last + 1 -- non-overlapping results, like standard Find
        end
    end
    return out
end

-- A replacement is inserted verbatim into a single line, so a newline in it
-- would put a literal "\n" inside one entry of the lines array -- the one shape
-- the rest of the editor guarantees cannot happen (split_text_lines is what
-- builds that array, and every other insert path splits on newlines first).
-- Callers pass user input through here first. Single-line input widgets cannot
-- produce a newline today; this is a guard against the day one can, not a
-- response to a bug.
function M.sanitize_replacement(s)
    return (tostring(s or ""):gsub("[\r\n]", " "))
end

-- Replace one match. Returns a NEW lines array (the caller's is untouched --
-- MDEdit's undo stack holds references to previous arrays, so mutating in
-- place is not safe here) plus the byte column just past the inserted text,
-- which is where the cursor belongs afterwards.
function M.replace_one(lines, match, replacement)
    local out = {}
    for i = 1, #(lines or {}) do out[i] = lines[i] end
    if not (match and out[match.row]) then return out, nil end
    replacement = tostring(replacement or "")
    local line = tostring(out[match.row] or "")
    out[match.row] = line:sub(1, match.start_col) .. replacement .. line:sub(match.end_col + 1)
    return out, match.start_col + #replacement
end

-- Replace every match of `query`. Returns a new lines array and the number of
-- replacements made.
--
-- The splice runs from the last match backwards. Every match's columns were
-- measured against the ORIGINAL line, so replacing left to right would
-- invalidate the columns of every later match on the same line the moment the
-- replacement differs in length from the query. Backwards, each splice only
-- touches text after the matches still to be processed, so their columns stay
-- correct without any bookkeeping.
--
-- Working from a precomputed match list is also what makes a replacement that
-- contains the query ("a" -> "aa") terminate: the matches are fixed before any
-- text changes, so the new text is never rescanned.
function M.replace_all(lines, query, replacement)
    local found = M.matches(lines, query)
    local out = {}
    for i = 1, #(lines or {}) do out[i] = lines[i] end
    replacement = tostring(replacement or "")
    for i = #found, 1, -1 do
        local match = found[i]
        local line = tostring(out[match.row] or "")
        out[match.row] = line:sub(1, match.start_col) .. replacement .. line:sub(match.end_col + 1)
    end
    return out, #found
end

return M
