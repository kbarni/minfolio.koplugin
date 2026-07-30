-- SPDX-License-Identifier: AGPL-3.0-only
-- Pure Markdown parsing for minfolio.koplugin (PLAN.md §5 Tier 0). Deliberately zero KOReader
-- dependencies: no `require("ui/...")`, no Font, no Blitbuffer, nothing that only exists
-- inside a running KOReader process. That is not a style preference, it is the only way any
-- of this can be checked off-device -- see minfolio_md_test.lua, runnable with plain
-- lua/luajit, no KOReader install required:
--   luajit minfolio_md_test.lua
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 0, §10 step 2): md_inline,
-- md_tokenize, md_trim, md_table_row_prefix, md_split_table_row, md_table_separator,
-- md_table_block, and md_split_line_prefix. The last of these was, before this move,
-- forward-declared at main.lua:3868 and assigned far away at main.lua:4682 -- this module is
-- its natural home (pure line-prefix parsing), not a workaround for the forward declaration.
--
-- Deliberately EXCLUDES md_face/md_color (need Font/Blitbuffer -- render-facing helpers that
-- belong in a later minfolio_style module) and MD_FACES/MDEDIT_TABLE_PAD_X/Y (render
-- constants, same later module). Pulling those in here would silently reintroduce a KOReader
-- dependency into what must stay a pure, off-device-testable module.
--
-- Required by callers as `local MD = require("minfolio_md")`.

local M = {}

-- `hl` (highlight) is a background flag carried through recursion, orthogonal to
-- text style: everything parsed inside a ==...== region inherits it, so bold /
-- italic / code inside a highlight keep their own style AND get the highlight fill.
function M.md_inline(text, hl)
    local spans, i, n, buf = {}, 1, #text, ""
    local function push(t, s, display) if t ~= "" then spans[#spans+1] = { text = t, style = s, display = display, hl = hl or nil } end end
    local function push_nested(inner, style)
        for _, s in ipairs(M.md_inline(inner, hl)) do
            if s.style ~= "syntax" then s.style = style end
            spans[#spans+1] = s
        end
    end
    while i <= n do
        local c2 = text:sub(i, i+1)
        local c1 = text:sub(i, i)
        local closer, inner_start, marker
        if c2 == "**" then marker = "**"; inner_start = i+2
        elseif c2 == "==" then marker = "=="; inner_start = i+2
        elseif c1 == "*" then marker = "*"; inner_start = i+1
        elseif c1 == "`" then marker = "`"; inner_start = i+1
        end
        if marker then closer = text:find(marker, inner_start, true) end
        if marker and closer then
            push(buf, "normal"); buf = ""
            if marker == "==" then
                -- Recurse so the highlight's contents keep their own inline styles;
                -- every returned span carries hl = true for the fill.
                push(marker, "syntax", "")
                for _, s in ipairs(M.md_inline(text:sub(inner_start, closer-1), true)) do spans[#spans+1] = s end
                push(marker, "syntax", "")
            else
                local sty = (marker == "**") and "bold" or (marker == "*") and "italic" or "code"
                push(marker, "syntax", "")
                if marker == "`" then push(text:sub(inner_start, closer-1), sty)
                else push_nested(text:sub(inner_start, closer-1), sty) end
                push(marker, "syntax", "")
            end
            i = closer + #marker
        else
            buf = buf .. c1; i = i + 1
        end
    end
    push(buf, "normal")
    if #spans == 0 then spans[1] = { text = "", style = "normal", hl = hl or nil } end
    return spans
end

function M.md_tokenize(textstr)
    local lines = {}
    local function with_prefix(prefix, rest, block, display, style)
        local spans = {}
        if prefix and prefix ~= "" then spans[#spans+1] = { text = prefix, style = style or "syntax", display = display or "" } end
        for _, s in ipairs(M.md_inline(rest)) do spans[#spans+1] = s end
        return { block = block or "normal", spans = spans }
    end
    for line in (tostring(textstr or "") .. "\n"):gmatch("(.-)\n") do
        local hashes, hrest = line:match("^(#+%s+)(.*)$")
        if hashes then
            local level = math.min(#hashes:gsub("%s", ""), 3)
            lines[#lines+1] = { block = "h"..level, spans = {{ text = hashes, style = "syntax", display = "" }, { text = hrest, style = "h"..level }} }
        else
            local pre, rest = line:match("^(%s*[%-%*%+]%s+)(.*)$")
            local ordered = false
            if not pre then
                pre, rest = line:match("^(%s*%d+%.%s+)(.*)$")
                ordered = pre ~= nil
            end
            if pre then
                local task, taskrest = rest:match("^(%[[ xX]%]%s+)(.*)$")
                local spans = {}
                spans[#spans+1] = { text = pre, style = "bullet", display = task and "" or (ordered and pre:gsub("^%s+", "") or "\226\128\162 ") }
                if task then
                    local checked = task:match("%[[xX]%]") ~= nil
                    spans[#spans+1] = { text = task, style = "task", display = checked and "\226\152\145 " or "\226\152\144 " }
                    rest = taskrest
                end
                for _, s in ipairs(M.md_inline(rest)) do spans[#spans+1] = s end
                -- Keep the leading whitespace so nested items render indented; the
                -- marker span's display drops it (fixed glyph), so the indent is
                -- reapplied as real horizontal space in layoutLine.
                lines[#lines+1] = { block = "bullet", spans = spans, indent_ws = pre:match("^%s*") or "" }
            else
                local task, taskrest = line:match("^(%s*%[[ xX]%]%s+)(.*)$")
                if task then
                    local checked = task:match("%[[xX]%]") ~= nil
                    local tok = with_prefix(task, taskrest, "bullet", checked and "\226\152\145 " or "\226\152\144 ", "task")
                    tok.indent_ws = task:match("^%s*") or ""
                    lines[#lines+1] = tok
                else
                    if line:match("^>%s?") then
                        pre, rest = line:match("^(>%s?)(.*)$")
                        lines[#lines+1] = with_prefix(pre, rest, "quote", "", "syntax")
                    else
                        lines[#lines+1] = { block = "normal", spans = M.md_inline(line) }
                    end
                end
            end
        end
    end
    return lines
end

function M.md_trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

-- ATX heading: one to six leading '#' followed by whitespace.
-- Returns hashes, text, prefix -- or nil when the line is not a heading.
--
-- Written as "#+" plus an explicit length check, NOT as "#{1,6}". Lua patterns
-- have no {n,m} quantifier: '{' and '}' are ordinary characters, so "#{1,6}"
-- matches the *literal* six-character text "#{1,6}" and therefore never matches
-- a real heading. That pattern was duplicated at six call sites, so heading
-- detection was broken everywhere at once -- the mindmap rendered every heading
-- as a flat paragraph with its '#' markers still attached, and the editor's
-- Outline always reported "No headings". Keeping the rule in one function is
-- what stops the next copy of it from going wrong again.
function M.heading(line)
    line = tostring(line or "")
    local hashes, text = line:match("^(#+)%s+(.-)%s*$")
    if not hashes or #hashes > 6 then return nil end
    return hashes, text, line:match("^(#+%s+)")
end

-- Markdown tables are permitted inside blockquotes.  Keep the prefix out of
-- the table grammar, but retain its byte width so cell edits still replace the
-- correct ranges in the original source line.
function M.md_table_row_prefix(line)
    return tostring(line or ""):match("^(%s*>%s?)") or ""
end

function M.md_split_table_row(line)
    line = tostring(line or "")
    local prefix = M.md_table_row_prefix(line)
    local source_offset = #prefix
    if source_offset > 0 then line = line:sub(source_offset + 1) end
    if not line:find("|", 1, true) then return nil end
    local first_pipe = line:find("|", 1, true)
    local last_pipe
    local pos = 1
    while true do
        local p = line:find("|", pos, true)
        if not p then break end
        last_pipe = p
        pos = p + 1
    end
    if not first_pipe or not last_pipe then return nil end

    local leading = line:match("^%s*|") ~= nil
    local trailing = line:match("|%s*$") ~= nil
    local start_pos = leading and (first_pipe + 1) or 1
    local end_pos = trailing and (last_pipe - 1) or #line
    if end_pos < start_pos then return nil end

    local cells = {}
    local cell_start = start_pos
    while cell_start <= end_pos + 1 do
        local pipe = line:find("|", cell_start, true)
        if not pipe or pipe > end_pos then pipe = end_pos + 1 end
        local raw_start, raw_end = cell_start, pipe - 1
        local raw = raw_start <= raw_end and line:sub(raw_start, raw_end) or ""
        local leading_ws = raw:match("^(%s*)") or ""
        local trailing_ws = raw:match("(%s*)$") or ""
        local text_start = raw_start + #leading_ws
        local text_end = raw_end - #trailing_ws
        local text = M.md_trim(raw)
        if text == "" then
            text_start = raw_start
            text_end = raw_start - 1
        end
        cells[#cells+1] = {
            text = text,
            start_col = math.max(0, source_offset + text_start - 1),
            end_col = math.max(0, source_offset + text_end),
        }
        cell_start = pipe + 1
        if pipe > end_pos then break end
    end
    if #cells < 2 then return nil end
    return cells, prefix
end

function M.md_table_separator(cells)
    if not cells or #cells < 2 then return nil end
    local aligns = {}
    for i, cell in ipairs(cells) do
        local spec = M.md_trim(cell.text):gsub("%s+", "")
        if not spec:match("^:?-+:?$") then return nil end
        if spec:match("^:") and spec:match(":$") then aligns[i] = "center"
        elseif spec:match(":$") then aligns[i] = "right"
        else aligns[i] = "left" end
    end
    return aligns
end

function M.md_table_block(lines, start_i)
    local header, prefix = M.md_split_table_row(lines[start_i])
    if not header then return nil end
    local sep, sep_prefix = M.md_split_table_row(lines[start_i + 1])
    if prefix ~= sep_prefix then return nil end
    local aligns = M.md_table_separator(sep)
    if not aligns then return nil end
    local ncols = #sep
    if #header < ncols then return nil end

    local rows = {
        { line = start_i, cells = header, header = true },
    }
    local finish = start_i + 1
    local i = start_i + 2
    while i <= #lines do
        local cells, row_prefix = M.md_split_table_row(lines[i])
        if not cells or row_prefix ~= prefix or #cells < 2 or M.md_table_separator(cells) then break end
        rows[#rows+1] = { line = i, cells = cells }
        finish = i
        i = i + 1
    end
    return { start = start_i, finish = finish, ncols = ncols, aligns = aligns, rows = rows }
end

function M.md_split_line_prefix(line)
    local indent, rest = line:match("^(%s*)(.*)$")
    local marker, body = rest:match("^([%-%*%+]%s+)(.*)$")
    local kind = marker and "bullet" or nil
    if not marker then
        marker, body = rest:match("^(%d+%.%s+)(.*)$")
        kind = marker and "ordered" or nil
    end
    body = body or rest
    local task, task_body = body:match("^(%[[ xX]%]%s+)(.*)$")
    if task then body = task_body end
    return indent or "", kind, marker, task, body
end

return M
