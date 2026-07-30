-- SPDX-License-Identifier: AGPL-3.0-only
-- Pure text/UTF-8/path helpers for minfolio.koplugin (PLAN.md §5 Tier 0). Deliberately zero
-- KOReader dependencies: no `require("ui/...")`, no Device, nothing that only exists inside a
-- running KOReader process. That is not a style preference, it is the only way any of this can
-- be checked off-device -- see minfolio_text_test.lua, runnable with plain lua/luajit, no
-- KOReader install required:
--   luajit minfolio_text_test.lua
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 0, §10 step 2): utf8_left,
-- utf8_right, utf8_snap, char_is_space, prev_word_col, next_word_col, split_text_lines,
-- path_join, path_base, is_markdown_file, copy_arr.
--
-- Deliberately EXCLUDES path_parent: it reads the module-level NOTES_DIR config value, so it
-- belongs in minfolio_config (a later work package), not here.
--
-- Required by callers as `local Text = require("minfolio_text")`.

local M = {}

function M.split_text_lines(text)
    local lines = {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do lines[#lines+1] = line end
    if #lines == 0 then lines = { "" } end
    return lines
end

-- UTF-8 cursor helpers: move/delete by whole characters, not bytes (continuation bytes are 0x80..0xBF)
function M.utf8_left(s, c)
    if c <= 0 then return 0 end
    c = c - 1
    while c > 0 do local b = s:byte(c+1); if b and b >= 0x80 and b < 0xC0 then c = c - 1 else break end end
    return c
end
function M.utf8_right(s, c)
    if c >= #s then return #s end
    c = c + 1
    while c < #s do local b = s:byte(c+1); if b and b >= 0x80 and b < 0xC0 then c = c + 1 else break end end
    return c
end
function M.utf8_snap(s, c)        -- snap a byte index back to the nearest char boundary
    while c > 0 and c < #s do local b = s:byte(c+1); if b and b >= 0x80 and b < 0xC0 then c = c - 1 else break end end
    return c
end
function M.char_is_space(s)
    return s ~= "" and s:match("^%s$") ~= nil
end
function M.prev_word_col(s, c)
    local p = math.max(0, math.min(c or 0, #s))
    while p > 0 do
        local q = M.utf8_left(s, p)
        if not M.char_is_space(s:sub(q + 1, p)) then break end
        p = q
    end
    while p > 0 do
        local q = M.utf8_left(s, p)
        if M.char_is_space(s:sub(q + 1, p)) then break end
        p = q
    end
    return p
end
function M.next_word_col(s, c)
    local p = math.max(0, math.min(c or 0, #s))
    while p < #s do
        local q = M.utf8_right(s, p)
        if not M.char_is_space(s:sub(p + 1, q)) then break end
        p = q
    end
    while p < #s do
        local q = M.utf8_right(s, p)
        if M.char_is_space(s:sub(p + 1, q)) then break end
        p = q
    end
    return p
end

function M.copy_arr(t) local r = {}; for i = 1, #t do r[i] = t[i] end; return r end

function M.path_join(dir, name)
    if dir == "/" then return "/" .. name end
    return dir .. "/" .. name
end

function M.path_base(path)
    local p = tostring(path or ""):gsub("/+$", "")
    return p:match("[^/]+$") or p
end

function M.is_markdown_file(name)
    return tostring(name or ""):lower():match("%.md$") ~= nil
end

return M
