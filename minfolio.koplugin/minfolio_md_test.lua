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

-- Regression: "1)" is an ordered-list delimiter in CommonMark exactly like "1.".
-- md_tokenize used to accept only "%d+%.", while parse_mindmap and
-- MindmapView:lineKind both accepted "%d+[.)]" -- so the same document read as a
-- list in the mindmap and as plain paragraphs in the editor.
do
    local lines = MD.md_tokenize("1) first item")
    check("ordered: ')' delimiter is a list, not a paragraph", lines[1].block == "bullet")
    check("ordered: ')' marker display keeps its own delimiter", lines[1].spans[1].display == "1) ")
end

do
    local lines = MD.md_tokenize("  2) indented")
    check("ordered: ')' marker parses with leading indent", lines[1].block == "bullet")
    check("ordered: ')' indent is retained for layout", lines[1].indent_ws == "  ")
end

-- A bare number must NOT become a list: "1.5 metres" and "2024" are prose.
do
    check("ordered: number without a delimiter+space stays normal",
        MD.md_tokenize("1.5 metres")[1].block == "normal")
    check("ordered: bare number stays normal", MD.md_tokenize("2024")[1].block == "normal")
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
-- Fenced code blocks: md_fence, md_fence_closes, md_code_block, md_code_map,
-- md_code_token, and md_tokenize's fence state
-- ---------------------------------------------------------------------------

do
    local marker, info = MD.md_fence("```python")
    check("fence: three backticks open a fence, info string is the language", marker == "```" and info == "python")

    marker, info = MD.md_fence("```")
    check("fence: a bare ``` is a fence with an empty info string", marker == "```" and info == "")

    marker = MD.md_fence("~~~~")
    check("fence: tildes are a fence marker too, and the run length is kept", marker == "~~~~")

    marker, info = MD.md_fence("`````lua")
    check("fence: more than three backticks is still a fence ('```+' is 3-or-more, not a {n,m} bound)",
        marker == "`````" and info == "lua")

    check("fence: two backticks are not a fence", MD.md_fence("``x``") == nil)
    check("fence: a line of inline code is not a fence (backtick in the info string)",
        MD.md_fence("a `b` c and ```d") == nil)
    check("fence: ordinary prose is not a fence", MD.md_fence("not a fence") == nil)
    check("fence: nil input is handled without error", MD.md_fence(nil) == nil)

    local _, _, indent = MD.md_fence("   ```sh")
    check("fence: leading indentation is reported, not rejected", indent == "   ")
end

do
    check("fence_closes: same marker, no info string, closes", MD.md_fence_closes("```", "```", ""))
    check("fence_closes: a longer closer closes a shorter opener", MD.md_fence_closes("```", "````", ""))
    check("fence_closes: a shorter closer does NOT close a longer opener", not MD.md_fence_closes("````", "```", ""))
    check("fence_closes: a closer may not carry an info string", not MD.md_fence_closes("```", "```", "lua"))
    check("fence_closes: ``` does not close a ~~~ block", not MD.md_fence_closes("~~~", "```", ""))
    check("fence_closes: nil marker is not a closer", not MD.md_fence_closes("```", nil, nil))
end

do
    local lines = { "intro", "```python", "print(1)", "```", "after" }
    local blk = MD.md_code_block(lines, 2)
    check("code_block: spans the opener through the closer", blk.start == 2 and blk.finish == 4)
    check("code_block: reports the info string as lang", blk.lang == "python")
    check("code_block: reports a matched pair as closed", blk.closed == true)
    check("code_block: a non-fence line opens nothing", MD.md_code_block(lines, 1) == nil)
    check("code_block: the closer itself opens nothing further (it has no info string, but is a fence)",
        MD.md_code_block(lines, 4).finish == 5)
end

do
    -- CommonMark 4.5: an unclosed fence runs to the end of the document. This is
    -- also what makes typing one feel right in the editor -- the block exists as
    -- soon as the opener does, instead of appearing only once a pair is complete.
    local blk = MD.md_code_block({ "```", "one", "two" }, 1)
    check("code_block: an unclosed fence runs to the last line", blk.finish == 3)
    check("code_block: an unclosed fence reports closed == false", blk.closed == false)
end

do
    -- A fence of the other character, and a fence carrying an info string, are
    -- both content: neither may end the block early.
    local blk = MD.md_code_block({ "~~~", "```", "x", "```lua", "~~~", "after" }, 1)
    check("code_block: only a matching closer ends the block", blk.finish == 5)
end

do
    local lines = { "para", "```sh", "ls | wc", "```", "tail" }
    local map = MD.md_code_map(lines)
    check("code_map: lines outside a block are absent", map[1] == nil and map[5] == nil)
    check("code_map: both fence lines are marked 'fence'", map[2] == "fence" and map[4] == "fence")
    check("code_map: content lines are marked 'code'", map[3] == "code")

    local open = MD.md_code_map({ "```", "a", "b" })
    check("code_map: an unclosed block covers every line to the end", open[1] == "fence" and open[2] == "code" and open[3] == "code")

    local two = MD.md_code_map({ "```", "a", "```", "middle", "```", "b", "```" })
    check("code_map: two blocks are found, and the text between them is not code",
        two[2] == "code" and two[4] == nil and two[6] == "code")
    local empty_n = 0
    for _ in pairs(MD.md_code_map({})) do empty_n = empty_n + 1 end
    check("code_map: empty input is handled without error", empty_n == 0)
end

do
    local tok = MD.md_code_token("  x = **not bold**", false)
    check("code_token: block is 'code'", tok.block == "code")
    check("code_token: the line is one verbatim span -- no inline parsing, indentation kept",
        #tok.spans == 1 and tok.spans[1].text == "  x = **not bold**" and tok.spans[1].style == "code")

    local fence_tok = MD.md_code_token("```python", true)
    check("code_token: a fence line gets block 'code_fence' and the 'fence' style", fence_tok.block == "code_fence"
        and fence_tok.spans[1].style == "fence")
    check("code_token: the fence's own backticks stay visible, unlike every other marker",
        fence_tok.spans[1].text == "```python")
end

do
    -- The whole point of the fence state in md_tokenize: a construct inside a
    -- block must not be read as the construct it looks like.
    local lines = MD.md_tokenize("intro\n```python\n# a comment\n- not a bullet\n| a | b |\n```\n# Real Heading")
    check("tokenize: text before the fence still parses normally", lines[1].block == "normal")
    check("tokenize: the opening fence is a code_fence line", lines[2].block == "code_fence")
    check("tokenize: a '#' comment inside a block is code, not a heading", lines[3].block == "code")
    check("tokenize: a '-' line inside a block is code, not a bullet", lines[4].block == "code")
    check("tokenize: a pipe line inside a block is code", lines[5].block == "code")
    check("tokenize: the closing fence is a code_fence line", lines[6].block == "code_fence")
    check("tokenize: parsing resumes after the closer", lines[7].block == "h1")
end

do
    local lines = MD.md_tokenize("```\n**verbatim**\n")
    check("tokenize: an unclosed fence keeps every following line as code", lines[2].block == "code"
        and lines[2].spans[1].text == "**verbatim**")
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

-- The marker is captured verbatim (delimiter included) because MDEdit:newline
-- builds the next item's prefix from it: hardcoding "." there turned "1) first"
-- into "2. " on Enter, switching delimiter mid-list.
do
    local _, kind, marker, _, body = MD.md_split_line_prefix("3) ordered text")
    check("split_line_prefix: digit+paren recognized as kind 'ordered'", kind == "ordered")
    check("split_line_prefix: ')' marker captured verbatim", marker == "3) ")
    check("split_line_prefix: ')' body is the text after the marker", body == "ordered text")
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

-- ---------------------------------------------------------------------------
-- MD.heading
--
-- Regression fence for a real bug: every heading site used `"^(#{1,6})%s+"`, but
-- Lua patterns have no {n,m} quantifier, so that matched only the literal text
-- "#{1,6} ...". Headings were never detected anywhere -- the mindmap rendered
-- flat with '#' markers attached, and the editor's Outline always said "No
-- headings". The 1-6 bound cannot be expressed as a Lua pattern at all, so it is
-- a length check, and these tests pin both ends of it.
-- ---------------------------------------------------------------------------

do
    local h, t = MD.heading("# One")
    check("heading: one hash is level 1", h == "#" and t == "One")

    h, t = MD.heading("###### Six")
    check("heading: six hashes is level 6 (CommonMark maximum)", h == "######" and t == "Six")

    check("heading: seven hashes is NOT a heading", MD.heading("####### Seven") == nil)
    check("heading: a hash with no following space is not a heading", MD.heading("#NoSpace") == nil)
    check("heading: ordinary prose is not a heading", MD.heading("not a heading") == nil)
    check("heading: a literal '#{1,6}' line is not a heading either (the old pattern's only match)",
        MD.heading("#{1,6} literal") == nil)

    h, t = MD.heading("##   Padded   ")
    check("heading: surrounding whitespace is trimmed from the text", h == "##" and t == "Padded")

    h, t = MD.heading("# ")
    check("heading: a marker with an empty title still reports its level", h == "#" and t == "")

    local _, _, prefix = MD.heading("###   Spaced")
    check("heading: the returned prefix spans the markers and all following whitespace",
        prefix == "###   ")
    check("heading: nil input is handled without error", MD.heading(nil) == nil)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
