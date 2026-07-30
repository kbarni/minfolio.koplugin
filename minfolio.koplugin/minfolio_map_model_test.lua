-- SPDX-License-Identifier: AGPL-3.0-only
-- Off-device unit tests for minfolio_map_model.lua (PLAN.md §7.1). Run with plain lua/luajit,
-- no KOReader install required:
--   luajit minfolio_map_model_test.lua
-- Exit code is 0 iff every assertion passed.

package.path = (arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or ".") .. "/?.lua;" .. package.path
local MapModel = require("minfolio_map_model")

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
-- mindmap_node
-- ---------------------------------------------------------------------------

do
    local node = MapModel.mindmap_node("heading", "  Some Title  ", 5, 2)
    check("mindmap_node: text is trimmed via md_trim", node.text == "Some Title")
    check("mindmap_node: kind stored", node.kind == "heading")
    check("mindmap_node: line stored", node.line == 5)
    check("mindmap_node: depth stored", node.depth == 2)
    check("mindmap_node: children starts as an empty table", type(node.children) == "table" and #node.children == 0)
end

check("mindmap_node: depth defaults to 1 when omitted", MapModel.mindmap_node("root", "x", 1).depth == 1)

do
    local node = MapModel.mindmap_node("list", "item", 1, 1, { marker = "- ", ordered = false })
    check("mindmap_node: extra fields merged onto the node", node.marker == "- " and node.ordered == false)
end

-- ---------------------------------------------------------------------------
-- KNOWN PRE-EXISTING BUG, characterized (not fixed -- verbatim move, PLAN.md §2/§7.2): the
-- heading-detection pattern used at three points inside parse_mindmap (main.lua's original
-- pre-move lines 1039 and 1090, both moved into this module) is `"^(#{1,6})%s+(.*)$"` /
-- `"^(#{1,6})%s+"`. `{1,6}` is regex repetition syntax; Lua patterns have NO `{n,m}`
-- quantifier, so `{`, `1`, `,`, `6`, `}` are matched as five LITERAL characters. This pattern
-- can therefore never match a real `#`-prefixed heading line, only the literal text
-- "#{1,6} ..." -- confirmed against `git show HEAD:minfolio.koplugin/main.lua`, so this
-- predates this refactor and was not introduced by the Tier 0 move. The practical effect: NO
-- line starting with `#` is ever recognized as a heading by parse_mindmap. It falls through to
-- the paragraph branch instead, `heading_level` never advances past 0, and every non-paragraph
-- node (list/quote/code) ends up a direct child of root at depth 1, never nested under a
-- heading. This is flagged in the work-package report as a real, user-visible defect (mindmap
-- structure is flat, headings never group anything) -- out of scope to fix here per the task's
-- verbatim-move constraint. The test below documents the ACTUAL behaviour so a future fix has
-- a clear "before" baseline and this suite doesn't silently start failing when someone corrects
-- the pattern to `"^(#+)%s+(.*)$"`.
-- ---------------------------------------------------------------------------

do
    local root = MapModel.parse_mindmap("# A\n## B\n# C\n", "Doc")
    check("KNOWN BUG: '#{1,6}' is not a valid Lua pattern quantifier, so heading lines are "
        .. "never recognized -- three consecutive heading lines collapse into ONE paragraph "
        .. "node (the paragraph-continuation scan doesn't break on them either, same broken "
        .. "pattern), not three heading nodes",
        #root.children == 1 and root.children[1].kind == "paragraph"
        and root.children[1].text == "# A\n## B\n# C")
end

-- ---------------------------------------------------------------------------
-- parse_mindmap: structural parsing of the parts that DO work (independent of the heading
-- bug above -- lists, tasks, quotes, code fences, and blank-line paragraph breaks all use
-- their own, valid patterns).
-- ---------------------------------------------------------------------------

do
    local root = MapModel.parse_mindmap("Intro paragraph.\n\nSecond paragraph.\n", "Doc")
    check("parse_mindmap: root kind is 'root'", root.kind == "root")
    check("parse_mindmap: a blank line splits two paragraphs into separate nodes",
        #root.children == 2 and root.children[1].kind == "paragraph" and root.children[2].kind == "paragraph")
    check("parse_mindmap: first paragraph text captured", root.children[1].text == "Intro paragraph.")
    check("parse_mindmap: second paragraph text captured", root.children[2].text == "Second paragraph.")
end

do
    local root = MapModel.parse_mindmap("- item one\n- item two\n", "Doc")
    check("parse_mindmap: two list items, both top-level siblings (no heading to nest under)",
        #root.children == 2 and root.children[1].kind == "list" and root.children[2].kind == "list")
    check("parse_mindmap: list item text excludes the marker", root.children[1].text == "item one")
    check("parse_mindmap: list item ordered field is false for a '-' marker", root.children[1].ordered == false)
end

do
    local root = MapModel.parse_mindmap("- [ ] todo one\n- [x] todo two\n", "Doc")
    check("parse_mindmap: unchecked task item marks task field", root.children[1].task ~= nil)
    check("parse_mindmap: task item's text excludes the checkbox", root.children[1].text == "todo one")
    check("parse_mindmap: checked task item recognized (task field set)", root.children[2].task ~= nil)
end

do
    local root = MapModel.parse_mindmap("> quoted line one\n> quoted line two\n", "Doc")
    check("parse_mindmap: consecutive blockquote lines merge into ONE quote node",
        #root.children == 1 and root.children[1].kind == "quote")
    check("parse_mindmap: quote node text joins the lines with a space",
        root.children[1].text == "quoted line one quoted line two")
end

do
    local root = MapModel.parse_mindmap("```lua\nlocal x = 1\n```\n", "Doc")
    check("parse_mindmap: fenced code block becomes a 'code' node",
        #root.children == 1 and root.children[1].kind == "code")
    check("parse_mindmap: code node captures the raw fenced lines (including the fences)",
        #root.children[1].raw == 3 and root.children[1].raw[2] == "local x = 1")
end

do
    -- Even though "# H" is never recognized as a heading, it IS still recognized as a
    -- paragraph-break boundary against what follows: the paragraph-continuation loop breaks
    -- when the NEXT line matches the (valid) list-marker pattern, so "# H" ends up alone as
    -- its own single-line paragraph, and the list item that follows is a separate, sibling
    -- top-level node -- not nested under it (since heading_level never advanced).
    local root = MapModel.parse_mindmap("# H\n- item one\n", "Doc")
    check("parse_mindmap: a '#'-line followed by a list item ends up as two SIBLING nodes, not parent/child",
        #root.children == 2 and root.children[1].kind == "paragraph" and root.children[1].text == "# H"
        and root.children[2].kind == "list" and root.children[2].text == "item one")
end

do
    -- Indentation-based nesting (independent of the heading bug): depth = heading_level + 1 +
    -- floor(nindent/2), so a 2-space-indented item nests one level under its predecessor.
    local root = MapModel.parse_mindmap("- parent\n  - child\n", "Doc")
    check("parse_mindmap: unindented list item is top-level", #root.children == 1 and root.children[1].text == "parent")
    check("parse_mindmap: indented list item nests under its parent, not as a root sibling",
        #root.children[1].children == 1 and root.children[1].children[1].text == "child")
    check("parse_mindmap: nested item's depth is one more than its parent's",
        root.children[1].children[1].depth == root.children[1].depth + 1)
end

do
    -- A document with NO headings and no list/quote/code content at all still gets a
    -- synthetic child so the map always has something to show (main.lua's fallback branch).
    local root = MapModel.parse_mindmap("", "Empty Doc")
    check("parse_mindmap: an empty document still produces one synthetic heading child",
        #root.children == 1 and root.children[1].kind == "heading" and root.children[1].text == "Mindmap")
end

-- ---------------------------------------------------------------------------
-- parse_mindmap: round-trip (markdown -> tree -> markdown)
--
-- There is no serializer function in this module (main.lua edits Markdown ranges directly
-- rather than re-serializing a tree, per PLAN.md §5's description of the mindmap view). The
-- round-trip property this module DOES guarantee, and that main.lua's mindmap editing depends
-- on, is: every node's `line` field is the exact 1-based index into the ORIGINAL split-line
-- array where that content started, so re-joining lines[node.line] (or the node's own
-- raw/text) reconstructs the original source. Verified directly against split_text_lines'
-- output, not assumed.
-- ---------------------------------------------------------------------------

do
    local Text = require("minfolio_text")
    local source = "Intro paragraph.\n\n- point one\n- point two\n\n> a quote\n"
    local lines = Text.split_text_lines(source)
    local root = MapModel.parse_mindmap(source, "Doc")
    check("round-trip: source produces exactly 4 top-level nodes", #root.children == 4)

    local intro = root.children[1]
    check("round-trip: paragraph node's line field indexes its exact source line",
        lines[intro.line] == "Intro paragraph.")
    check("round-trip: paragraph node's text reconstructs the source line exactly",
        intro.text == "Intro paragraph.")

    local p1 = root.children[2]
    check("round-trip: first list item's line field indexes its exact source line (byte-identical after stripping the marker)",
        lines[p1.line] == "- point one" and lines[p1.line]:sub(3) == p1.text)
    local p2 = root.children[3]
    check("round-trip: second list item's line field indexes its exact source line",
        lines[p2.line] == "- point two" and lines[p2.line]:sub(3) == p2.text)

    local q = root.children[4]
    check("round-trip: quote node's line field indexes the FIRST of its (possibly merged) source lines",
        lines[q.line] == "> a quote")
end

do
    -- CRLF normalization: parse_mindmap gsubs \r\n -> \n before splitting, so a
    -- Windows-line-ended document must parse identically to its \n-only equivalent.
    local root_crlf = MapModel.parse_mindmap("- item one\r\n- item two\r\n", "Doc")
    local root_lf = MapModel.parse_mindmap("- item one\n- item two\n", "Doc")
    check("round-trip: CRLF input parses to the same structure as LF-only input",
        #root_crlf.children == #root_lf.children
        and root_crlf.children[1].text == root_lf.children[1].text
        and root_crlf.children[2].text == root_lf.children[2].text)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
