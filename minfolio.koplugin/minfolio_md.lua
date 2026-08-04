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
-- Fenced code blocks (md_fence, md_fence_closes, md_code_block, md_code_map,
-- md_code_token) were added later, and are grouped together below md_trim. They
-- are the second multi-line construct here, after tables: a fence's meaning is
-- not readable from its own line, so they take (lines, i) like md_table_block.
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

-- The blockquote markers at the head of a line. Returns prefix, depth, rest --
-- or nil when the line is not quoted.
--
-- A loop rather than a pattern because Lua patterns have no repeated capture:
-- "^((>%s?)+)" does not mean what it looks like, and "^>%s?" alone reads only
-- the first level, which is how "> > text" used to render as a quote containing
-- a literal "> ".
--
-- The prefix is returned whole and verbatim, both markers and the spaces between
-- them, because the tokenizer emits it as ONE hidden span. Every byte of the
-- source line has to be inside some span or the editor's byte<->x mapping
-- (rowXAt, colAtX, a row's `sb`) drifts by however many bytes were dropped, and
-- the caret lands in the wrong place.
--
-- Depth is uncapped here. Clamping belongs to whatever renders the indent, not
-- to the reading of the document.
function M.md_quote_prefix(line)
    line = tostring(line or "")
    local pos, depth = 1, 0
    while true do
        local _, stop = line:find("^>%s?", pos)
        if not stop then break end
        depth = depth + 1
        pos = stop + 1
    end
    if depth == 0 then return nil end
    return line:sub(1, pos - 1), depth, line:sub(pos)
end

-- A thematic break -- the horizontal rule (CommonMark 4.1). Returns the marker
-- character and how many of it, or nil.
--
-- Three or more of `-`, `*` or `_`, all the same character, with any amount of
-- space or tab between and after them, and up to three leading spaces. So "---",
-- "***", "___", "- - -" and "   ---   " are all rules; "--", "-*-" and "--- x"
-- are not.
--
-- This is checked BEFORE the list-item branch in md_tokenize, which is the
-- precedence CommonMark specifies and not merely a convenience: "- - -" matches
-- the bullet pattern too, and whichever branch runs first decides. Reading it as
-- a list produced a bullet whose text was "- -", which is nobody's intent.
--
-- Table separators ("|---|---|") start with a pipe and never reach here, and a
-- fence is backticks or tildes, so neither construct is at risk from this.
function M.md_thematic_break(line)
    line = tostring(line or "")
    local indent, rest = line:match("^( *)(.*)$")
    if #indent > 3 then return nil end
    local ch = rest:sub(1, 1)
    if ch ~= "-" and ch ~= "*" and ch ~= "_" then return nil end
    local count = 0
    for i = 1, #rest do
        local c = rest:sub(i, i)
        if c == ch then
            count = count + 1
        elseif c ~= " " and c ~= "\t" then
            return nil
        end
    end
    if count < 3 then return nil end
    return ch, count
end

function M.md_tokenize(textstr)
    local lines = {}
    local function with_prefix(prefix, rest, block, display, style)
        local spans = {}
        if prefix and prefix ~= "" then spans[#spans+1] = { text = prefix, style = style or "syntax", display = display or "" } end
        for _, s in ipairs(M.md_inline(rest)) do spans[#spans+1] = s end
        return { block = block or "normal", spans = spans }
    end
    -- The one construct here whose reading depends on lines other than its own:
    -- everything between an opening ``` and its closer is verbatim, so none of
    -- the rules below may look at it. `fence` holds the opening marker while a
    -- block is open. Callers that tokenize a single line at a time (the editor's
    -- layout path) cannot carry this state in a string, so they must find the
    -- block themselves with M.md_code_block and call M.md_code_token per line.
    local fence
    for line in (tostring(textstr or "") .. "\n"):gmatch("(.-)\n") do
        local marker, info = M.md_fence(line)
        if fence then
            local closes = M.md_fence_closes(fence, marker, info)
            lines[#lines+1] = M.md_code_token(line, closes)
            if closes then fence = nil end
        elseif marker then
            fence = marker
            lines[#lines+1] = M.md_code_token(line, true)
        elseif M.md_thematic_break(line) then
            -- The whole line is one hidden span. Nothing of it renders (the rule
            -- is drawn by the view), but every byte stays inside a span so the
            -- caret can still be placed on the line and the rule deleted --
            -- exactly how a heading's "# " and a quote's "> " are handled.
            lines[#lines+1] = { block = "hr", spans = {{ text = line, style = "syntax", display = "" }} }
        else
            local hashes, hrest = line:match("^(#+%s+)(.*)$")
            if hashes then
                local level = math.min(#hashes:gsub("%s", ""), 3)
                lines[#lines+1] = { block = "h"..level, spans = {{ text = hashes, style = "syntax", display = "" }, { text = hrest, style = "h"..level }} }
            else
                local pre, rest = line:match("^(%s*[%-%*%+]%s+)(.*)$")
                local ordered = false
                if not pre then
                    -- "1)" is an ordered-list delimiter in CommonMark exactly like
                    -- "1.", and parse_mindmap/lineKind already accepted both -- so a
                    -- "1)" list showed up as list nodes in the mindmap while this
                    -- tokenizer rendered the same lines as plain paragraphs, and
                    -- md_split_line_prefix (below) gave them no continuation on
                    -- Enter. One document, two disagreeing readings of it.
                    pre, rest = line:match("^(%s*%d+[%.%)]%s+)(.*)$")
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
                        local qpre, qdepth, qrest = M.md_quote_prefix(line)
                        if qpre then
                            -- quote_depth is what the renderer indents by and how
                            -- many rules it draws; the markers themselves stay
                            -- hidden (display = "") like every other syntax span.
                            local tok = with_prefix(qpre, qrest, "quote", "", "syntax")
                            tok.quote_depth = qdepth
                            lines[#lines+1] = tok
                        else
                            lines[#lines+1] = { block = "normal", spans = M.md_inline(line) }
                        end
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

-- ---------------------------------------------------------------------------
-- Fenced code blocks (CommonMark 4.5)
--
-- Like tables, and unlike everything else in this file, a fence is not a
-- property of the line it sits on: ``` opens a region in which no other
-- Markdown rule applies, and only a matching closer ends it. Every consumer
-- therefore needs the surrounding lines, which is why these take (lines, i) --
-- the same shape as md_table_block -- rather than the (line) shape used by
-- md_split_line_prefix and friends.
-- ---------------------------------------------------------------------------

-- A fence line: three or more backticks or tildes, optionally indented.
-- Returns marker, info, indent -- or nil when the line is not a fence.
--
-- "```+" is three-or-more backticks: two literal ones plus a "+" quantifier on
-- the third. It is NOT "`{3,}" -- Lua patterns have no {n,m} quantifier at all,
-- the same trap that broke every heading site until M.heading centralised it.
function M.md_fence(line)
    line = tostring(line or "")
    local indent, marker, info = line:match("^(%s*)(```+)(.*)$")
    if not marker then indent, marker, info = line:match("^(%s*)(~~~+)(.*)$") end
    if not marker then return nil end
    -- CommonMark: a backtick opener's info string may not contain a backtick, or
    -- a line of inline code like ``a `b` c`` would read as a fence.
    if marker:sub(1, 1) == "`" and info:find("`", 1, true) then return nil end
    return marker, M.md_trim(info), indent
end

-- Does the fence line described by (marker, info) close a block opened by
-- `open`? Only a run of the same character, at least as long, with nothing but
-- whitespace after it -- so ``` never closes a ~~~ block, and ```lua inside a
-- block is content, not a closer.
function M.md_fence_closes(open, marker, info)
    if not open or not marker then return false end
    return marker:sub(1, 1) == open:sub(1, 1) and #marker >= #open and (info or "") == ""
end

-- The fenced block opened at lines[start_i], or nil if that line is not a fence.
-- `finish` is the closing fence's line, or #lines when the fence is never closed
-- -- CommonMark's rule, and the one that makes typing a fence feel right: the
-- block appears the moment the opener exists and stops growing once the closer
-- is typed, instead of waiting for a complete pair before showing anything.
function M.md_code_block(lines, start_i)
    local marker, info = M.md_fence(lines and lines[start_i])
    if not marker then return nil end
    local finish, closed = #lines, false
    for i = start_i + 1, #lines do
        local m, minfo = M.md_fence(lines[i])
        if M.md_fence_closes(marker, m, minfo) then
            finish, closed = i, true
            break
        end
    end
    return { start = start_i, finish = finish, lang = info, marker = marker, closed = closed }
end

-- Line number -> "fence" | "code" for every line covered by a fenced block, so a
-- caller holding one line number can ask whether Markdown applies there at all
-- (the editor's Enter-continuation and Outline both do). One pass; md_code_block
-- returns nil immediately for a non-fence line, so this is O(#lines).
function M.md_code_map(lines)
    local map, i = {}, 1
    lines = lines or {}
    while i <= #lines do
        local blk = M.md_code_block(lines, i)
        if blk then
            for li = blk.start, blk.finish do map[li] = "code" end
            map[blk.start] = "fence"
            if blk.closed then map[blk.finish] = "fence" end
            i = blk.finish + 1
        else
            i = i + 1
        end
    end
    return map
end

-- One tokenized line of a fenced block, in md_tokenize's token shape so the
-- editor's layout path can treat it like any other line. Deliberately does NOT
-- go through md_inline: inside a fence, `**` is two asterisks, a leading '#' is
-- a comment and not a heading, and the leading whitespace carrying the code's
-- own indentation is content that has to survive verbatim.
function M.md_code_token(text, is_fence)
    text = tostring(text or "")
    if is_fence then
        return { block = "code_fence", spans = {{ text = text, style = "fence" }} }
    end
    return { block = "code", spans = {{ text = text, style = "code" }} }
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

-- Tick or untick a task line: "- [ ] x" <-> "- [x] x". Returns the new line and
-- the new checked state, or nil when the line carries no checkbox at all.
--
-- Only the three bytes of the box itself are rewritten. Everything around them
-- -- the indent, the list marker, the run of whitespace after the box, the text
-- -- is carried through untouched, so ticking a box can never reflow, reindent
-- or renumber the line it is on. That is also why this replaces a fixed 3-byte
-- slice rather than rebuilding the prefix from md_split_line_prefix's pieces:
-- "[ ]" and "[x]" are always exactly three bytes, and a rebuild would normalise
-- spacing the user chose.
--
-- "[X]" (capital) unticks like any other checked box, but always ticks back to
-- lowercase "[x]" -- the form md_tokenize's own task rendering and this
-- plugin's fmtTask both produce.
function M.md_toggle_task(line)
    line = tostring(line or "")
    local indent, _kind, marker, task = M.md_split_line_prefix(line)
    if not task then return nil end
    local box_at = #indent + #(marker or "")
    local checked = task:match("^%[[xX]%]") ~= nil
    return line:sub(1, box_at) .. (checked and "[ ]" or "[x]") .. line:sub(box_at + 4), not checked
end

function M.md_split_line_prefix(line)
    local indent, rest = line:match("^(%s*)(.*)$")
    local marker, body = rest:match("^([%-%*%+]%s+)(.*)$")
    local kind = marker and "bullet" or nil
    if not marker then
        -- Both CommonMark delimiters; see md_tokenize's note above.
        marker, body = rest:match("^(%d+[%.%)]%s+)(.*)$")
        kind = marker and "ordered" or nil
    end
    body = body or rest
    local task, task_body = body:match("^(%[[ xX]%]%s+)(.*)$")
    if task then body = task_body end
    return indent or "", kind, marker, task, body
end

-- What pressing Enter at byte column `col` of `line` owes the document.
-- Returns EITHER a prefix for the new line (`prefix, nil`) OR a replacement for
-- the current one (`nil, reset`) when the construct being continued is empty and
-- Enter should end it instead of extending it.
--
-- Lifted out of MDEdit:newline (Tier 4, untestable here) when blockquotes joined
-- lists as a continuable construct, per CLAUDE.md's rule that logic which can be
-- pure should be: this is the one function in the plugin that decides what a
-- keystroke writes into the document, it already shipped one bug of that kind
-- (continuing "1) first" handed back "2. ", switching delimiter mid-list), and
-- every rule below is a pure function of a line and a column.
--
-- The two ending rules, both "one Enter peels one construct":
--   "- "     -> ""      an empty list item ends the list, keeping the indent
--   "> - "   -> "> "    ...and inside a quote it ends the list, not the quote
--   "> "     -> ""      an empty quoted line then ends the quote
--
-- The quote prefix is read from the WHOLE line but only carried when the caret
-- sits past it. Splitting a line from inside its own "> " must not hand the new
-- line a second copy of the marker -- there, the split is just a split.
--
-- Everything carried is carried VERBATIM: "> ", ">> " and "> > " each continue
-- in the spelling the author used, and an ordered list keeps its own delimiter.
-- Normalising here would rewrite the author's file as a side effect of pressing
-- Enter.
function M.md_line_continuation(line, col)
    line = tostring(line or "")
    col = math.max(0, math.min(#line, math.floor(tonumber(col) or #line)))
    local before, after = line:sub(1, col), line:sub(col + 1)

    local quote = ""
    local qpre = M.md_quote_prefix(line)
    if qpre and col >= #qpre then quote = qpre end

    local indent, kind, marker, task, body = M.md_split_line_prefix(before:sub(#quote + 1))
    if (kind or task) and body == "" and after == "" then
        return nil, quote .. indent
    end
    if quote ~= "" and before == quote and after == "" then
        return nil, ""
    end

    local prefix = quote
    if kind == "ordered" then
        local n = tonumber((marker or ""):match("^(%d+)")) or 1
        local delim = (marker or ""):match("^%d+([%.%)])") or "."
        prefix = quote .. indent .. tostring(n + 1) .. delim .. " "
    elseif kind == "bullet" then
        prefix = quote .. indent .. (marker or "- ")
    elseif task then
        prefix = quote .. indent
    end
    if task then prefix = prefix .. "[ ] " end
    return prefix, nil
end

return M
