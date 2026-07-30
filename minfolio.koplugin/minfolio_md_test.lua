-- SPDX-License-Identifier: AGPL-3.0-only
-- Off-device unit tests for minfolio_md.lua (PLAN.md §7.1). Run with plain lua/luajit, no
-- KOReader install required:
--   luajit minfolio_md_test.lua
-- Exit code is 0 iff every assertion passed.

package.path = (arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or ".") .. "/?.lua;" .. package.path
local MD = require("minfolio_md")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL: " .. label .. "\n")
    end
end

-- ---------------------------------------------------------------------------
-- md_tokenize: headings
-- ---------------------------------------------------------------------------

do
    local lines = MD.md_tokenize("# Title")
    check("h1: one output line", #lines == 1)
    check("h1: block is h1", lines[1].block == "h1")
    check("h1: syntax span carries the hashes", lines[1].spans[1].text == "# " and lines[1].spans[1].style == "syntax")
    check("h1: text span carries the heading text with h1 style", lines[1].spans[2].text == "Title" and lines[1].spans[2].style == "h1")
end

do
    local lines = MD.md_tokenize("## Sub")
    check("h2: block is h2", lines[1].block == "h2")
end

do
    local lines = MD.md_tokenize("### Sub")
    check("h3: block is h3", lines[1].block == "h3")
end

do
    -- Heading depth is capped at h3 (math.min(#hashes, 3)) -- a level-4+ heading still renders,
    -- just clamped, not dropped.
    local lines = MD.md_tokenize("#### Deep")
    check("h4+ clamps to h3, does not drop the line", lines[1].block == "h3" and lines[1].spans[2].text == "Deep")
end

do
    check("a bare '#' with no following text/space is NOT a heading (plain paragraph text)",
        MD.md_tokenize("#no-space")[1].block == "normal")
end

-- ---------------------------------------------------------------------------
-- md_tokenize / md_inline: bold, italic, code, highlight
-- ---------------------------------------------------------------------------

do
    local spans = MD.md_tokenize("This is **bold** text.")[1].spans
    local found_bold
    for _, s in ipairs(spans) do
        if s.text == "bold" and s.style == "bold" then found_bold = true end
    end
    check("bold: inner text gets style 'bold'", found_bold)
    local syntax_count = 0
    for _, s in ipairs(spans) do if s.style == "syntax" and s.text == "**" then syntax_count = syntax_count + 1 end end
    check("bold: both ** markers are separate 'syntax'-styled spans", syntax_count == 2)
end

do
    local spans = MD.md_tokenize("This is *italic* text.")[1].spans
    local found
    for _, s in ipairs(spans) do if s.text == "italic" and s.style == "italic" then found = true end end
    check("italic: single-asterisk inner text gets style 'italic'", found)
end

do
    local spans = MD.md_tokenize("Run `code here` now.")[1].spans
    local found
    for _, s in ipairs(spans) do if s.text == "code here" and s.style == "code" then found = true end end
    check("code: backtick inner text gets style 'code', unprocessed for nested markup", found)
end

do
    -- Code spans must NOT recurse into inline parsing (unlike bold/italic) -- a literal
    -- asterisk inside backticks must stay literal text, not be treated as italic markup.
    local spans = MD.md_tokenize("`a*b*c`")[1].spans
    local raw_found
    for _, s in ipairs(spans) do if s.text == "a*b*c" and s.style == "code" then raw_found = true end end
    check("code spans do not recurse into nested inline markup", raw_found)
end

do
    -- Highlight (==...==) recurses so nested bold/italic keep their own style, all carrying hl=true.
    local spans = MD.md_tokenize("==**hi**==")[1].spans
    local hl_bold
    for _, s in ipairs(spans) do if s.text == "hi" and s.style == "bold" and s.hl == true then hl_bold = true end end
    check("highlight: nested bold keeps style 'bold' AND gets hl=true", hl_bold)
end

do
    local spans = MD.md_inline("plain text, no markup")
    check("md_inline: plain text with no markers returns a single normal span",
        #spans == 1 and spans[1].style == "normal" and spans[1].text == "plain text, no markup")
end

do
    check("md_inline: empty string still returns one (empty) span, not zero",
        #MD.md_inline("") == 1 and MD.md_inline("")[1].text == "")
end

-- ---------------------------------------------------------------------------
-- md_tokenize: lists (bullet, ordered, task)
-- ---------------------------------------------------------------------------

do
    local lines = MD.md_tokenize("- item one")
    check("bullet: block is 'bullet'", lines[1].block == "bullet")
    check("bullet: marker span uses the bullet glyph as display", lines[1].spans[1].display == "\226\128\162 ")
    local found
    for _, s in ipairs(lines[1].spans) do if s.text == "item one" then found = true end end
    check("bullet: item text present as an inline span", found)
end

for _, marker in ipairs({ "-", "*", "+" }) do
    local lines = MD.md_tokenize(marker .. " x")
    check("bullet marker '" .. marker .. "' recognized as block 'bullet'", lines[1].block == "bullet")
end

do
    local lines = MD.md_tokenize("1. first item")
    check("ordered: block is 'bullet' (same block kind as unordered)", lines[1].block == "bullet")
    -- display strips LEADING whitespace only (pre:gsub("^%s+","")); the marker's own trailing
    -- space is retained, unlike the fixed bullet-dot glyph used for unordered lists.
    check("ordered: marker display is the number/dot marker with leading indent stripped",
        lines[1].spans[1].display == "1. ")
end

do
    local lines = MD.md_tokenize("12. twelfth")
    check("ordered: multi-digit marker parses", lines[1].block == "bullet" and lines[1].spans[1].display == "12. ")
end

do
    local lines = MD.md_tokenize("- [ ] unchecked task")
    check("task (unchecked): block is 'bullet'", lines[1].block == "bullet")
    local task_span
    for _, s in ipairs(lines[1].spans) do if s.style == "task" then task_span = s end end
    check("task (unchecked): task span uses the empty-box glyph", task_span and task_span.display == "\226\152\144 ")
end

do
    local lines = MD.md_tokenize("- [x] checked task")
    local task_span
    for _, s in ipairs(lines[1].spans) do if s.style == "task" then task_span = s end end
    check("task (checked, lowercase x): task span uses the checked glyph", task_span and task_span.display == "\226\152\145 ")
end

do
    local lines = MD.md_tokenize("- [X] checked task")
    local task_span
    for _, s in ipairs(lines[1].spans) do if s.style == "task" then task_span = s end end
    check("task (checked, uppercase X): also recognized as checked", task_span and task_span.display == "\226\152\145 ")
end

do
    -- A task line NOT under a "- " bullet marker is still detected via the standalone
    -- "%s*%[...%]%s+" branch of md_tokenize.
    local lines = MD.md_tokenize("[ ] bare task, no bullet marker")
    check("bare task line (no leading bullet marker) still recognized as block 'bullet'",
        lines[1].block == "bullet")
end

do
    local lines = MD.md_tokenize("  - nested item")
    check("indented bullet: indent_ws captured on the line", lines[1].indent_ws == "  ")
end

-- ---------------------------------------------------------------------------
-- md_tokenize: blockquotes
-- ---------------------------------------------------------------------------

do
    local lines = MD.md_tokenize("> quoted text")
    check("quote: block is 'quote'", lines[1].block == "quote")
    check("quote: syntax span carries the '> ' prefix", lines[1].spans[1].text == "> " and lines[1].spans[1].style == "syntax")
end

do
    local lines = MD.md_tokenize(">no space after marker")
    check("quote: '>' with no following space is still a quote (pattern is '>%s?')", lines[1].block == "quote")
end

-- ---------------------------------------------------------------------------
-- md_trim
-- ---------------------------------------------------------------------------

check("md_trim: strips leading/trailing whitespace", MD.md_trim("   hello world   ") == "hello world")
check("md_trim: nil input becomes empty string", MD.md_trim(nil) == "")
check("md_trim: all-whitespace input becomes empty string", MD.md_trim("   \t  ") == "")
check("md_trim: preserves internal whitespace", MD.md_trim("  a  b  ") == "a  b")

-- ---------------------------------------------------------------------------
-- Table grammar: md_split_table_row, md_table_separator, md_table_block
-- ---------------------------------------------------------------------------

do
    local cells, prefix = MD.md_split_table_row("| a | b | c |")
    check("split_table_row: three cells parsed", cells and #cells == 3)
    check("split_table_row: no blockquote prefix on a plain row", prefix == "")
    check("split_table_row: cell text trimmed", cells[1].text == "a" and cells[2].text == "b" and cells[3].text == "c")
end

do
    -- No leading/trailing pipes is still a valid row per the grammar.
    local cells = MD.md_split_table_row("a | b")
    check("split_table_row: row without leading/trailing pipes still parses (2 cells)",
        cells and #cells == 2 and cells[1].text == "a" and cells[2].text == "b")
end

check("split_table_row: a line with no pipe at all is not a table row", MD.md_split_table_row("just text") == nil)
check("split_table_row: a single-cell line (one pipe max producing <2 cells) is rejected",
    MD.md_split_table_row("|only one|") == nil)

do
    -- start_col/end_col: cell editing depends on these mapping back to byte offsets in the
    -- ORIGINAL source line, so this is verified by slicing the source at the reported offsets.
    local line = "| alpha | beta |"
    local cells = MD.md_split_table_row(line)
    check("start_col/end_col: cell 1 offsets slice back to its own text",
        line:sub(cells[1].start_col + 1, cells[1].end_col) == "alpha")
    check("start_col/end_col: cell 2 offsets slice back to its own text",
        line:sub(cells[2].start_col + 1, cells[2].end_col) == "beta")
end

do
    -- Blockquote-prefixed table row: the "> " prefix must be excluded from the cell grammar
    -- but its byte width preserved so start_col/end_col still point into the FULL source line.
    local line = "> | x | y |"
    local cells, prefix = MD.md_split_table_row(line)
    check("blockquote-prefixed row: prefix captured as '> '", prefix == "> ")
    check("blockquote-prefixed row: still parses 2 cells", cells and #cells == 2)
    check("blockquote-prefixed row: start_col/end_col account for the prefix's byte width",
        line:sub(cells[1].start_col + 1, cells[1].end_col) == "x"
        and line:sub(cells[2].start_col + 1, cells[2].end_col) == "y")
end

do
    local aligns = MD.md_table_separator(MD.md_split_table_row("| --- | :--- | ---: | :---: |"))
    check("table_separator: 4 columns aligned", aligns and #aligns == 4)
    check("table_separator: plain dashes = left", aligns[1] == "left")
    check("table_separator: leading colon = left", aligns[2] == "left")
    check("table_separator: trailing colon = right", aligns[3] == "right")
    check("table_separator: both colons = center", aligns[4] == "center")
end

check("table_separator: a non-separator row (real text) is rejected",
    MD.md_table_separator(MD.md_split_table_row("| a | b |")) == nil)

do
    local lines = { "| H1 | H2 |", "| --- | --- |", "| a1 | a2 |", "| b1 | b2 |", "not a table row" }
    local tbl = MD.md_table_block(lines, 1)
    check("table_block: parses a full table", tbl ~= nil)
    check("table_block: starts at line 1", tbl.start == 1)
    check("table_block: finishes at line 4 (stops before the non-table line)", tbl.finish == 4)
    check("table_block: 2 columns", tbl.ncols == 2)
    -- rows holds the header plus only the DATA rows that follow the separator; the separator
    -- line itself (line 2) is consumed to derive `aligns` but is never appended to rows.
    check("table_block: 3 rows total (1 header + 2 data rows; separator line is not a row)", #tbl.rows == 3)
    check("table_block: first row marked as header", tbl.rows[1].header == true)
    check("table_block: body row cell text correct", tbl.rows[2].cells[1].text == "a1" and tbl.rows[2].cells[2].text == "a2")
end

do
    -- Blockquote-prefixed TABLE (not just a single row): every row must share the exact
    -- same prefix, and the block must stop consuming rows when the prefix changes.
    local lines = { "> | H1 | H2 |", "> | --- | --- |", "> | a1 | a2 |", "no prefix here | x |" }
    local tbl = MD.md_table_block(lines, 1)
    check("blockquote table: parses with '> ' prefix on every row", tbl ~= nil)
    check("blockquote table: stops when a row's prefix no longer matches", tbl.finish == 3)
end

check("table_block: header without a valid separator on the next line is rejected",
    MD.md_table_block({ "| a | b |", "not a separator" }, 1) == nil)

check("table_block: separator's blockquote prefix must match the header's prefix",
    MD.md_table_block({ "> | a | b |", "| --- | --- |" }, 1) == nil)

-- ---------------------------------------------------------------------------
-- md_split_line_prefix -- PLAN.md §4/§6.3 calls this "the most dangerous symbol in the file"
-- (a nil-tolerant guard in main.lua used to depend on this upvalue resolving). Cover every
-- list/heading/task form the guard's callers (newline/setLinePrefix/fmtTask) rely on.
-- ---------------------------------------------------------------------------

do
    local indent, kind, marker, task, body = MD.md_split_line_prefix("- bullet text")
    check("split_line_prefix: '-' recognized as kind 'bullet'", kind == "bullet")
    check("split_line_prefix: marker captured verbatim", marker == "- ")
    check("split_line_prefix: no task", task == nil)
    check("split_line_prefix: body is the text after the marker", body == "bullet text")
    check("split_line_prefix: indent is empty for a top-level line", indent == "")
end

for _, marker_ch in ipairs({ "-", "*", "+" }) do
    local _, kind = MD.md_split_line_prefix(marker_ch .. " x")
    check("split_line_prefix: marker '" .. marker_ch .. "' also recognized as 'bullet'", kind == "bullet")
end

do
    local indent, kind, marker, task, body = MD.md_split_line_prefix("3. ordered text")
    check("split_line_prefix: digit+dot recognized as kind 'ordered'", kind == "ordered")
    check("split_line_prefix: ordered marker captured verbatim", marker == "3. ")
    check("split_line_prefix: ordered body is the text after the marker", body == "ordered text")
end

do
    local indent, kind, marker, task, body = MD.md_split_line_prefix("- [ ] unchecked")
    check("split_line_prefix: bullet+task combo keeps kind 'bullet'", kind == "bullet")
    check("split_line_prefix: task captured", task == "[ ] ")
    check("split_line_prefix: body excludes both the bullet marker and the task box", body == "unchecked")
end

do
    local indent, kind, marker, task, body = MD.md_split_line_prefix("- [x] done")
    check("split_line_prefix: checked task box captured", task == "[x] ")
    check("split_line_prefix: body after checked task", body == "done")
end

do
    -- A heading is NOT a list/task form: md_split_line_prefix has no heading branch, so
    -- kind/task must stay nil and the whole line (including '#') is the body. This is the
    -- behaviour main.lua's newline() guard relies on to NOT auto-continue a '#' prefix.
    local indent, kind, marker, task, body = MD.md_split_line_prefix("# Heading text")
    check("split_line_prefix: a heading line yields kind == nil (not a list form)", kind == nil)
    check("split_line_prefix: a heading line yields task == nil", task == nil)
    check("split_line_prefix: a heading line's body is the entire original text", body == "# Heading text")
end

do
    local indent, kind, marker, task, body = MD.md_split_line_prefix("  - indented bullet")
    check("split_line_prefix: leading indentation captured separately from the marker", indent == "  ")
    check("split_line_prefix: kind still resolved under indentation", kind == "bullet")
end

do
    local indent, kind, marker, task, body = MD.md_split_line_prefix("plain paragraph, no marker")
    check("split_line_prefix: a plain line has kind == nil", kind == nil)
    check("split_line_prefix: a plain line's body is the whole text", body == "plain paragraph, no marker")
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
