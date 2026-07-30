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
-- Heading detection. This was a real, user-visible bug, fixed in the commit that
-- introduced MD.heading: every site used `"^(#{1,6})%s+"`, but Lua patterns have no
-- {n,m} quantifier -- `{`, `1`, `,`, `6`, `}` are five literal characters, so the
-- pattern only ever matched the literal text "#{1,6} ...". No `#`-prefixed line was
-- ever recognized as a heading, `heading_level` never advanced past 0, and the whole
-- mindmap came out flat with '#' markers still attached to the labels.
--
-- These tests assert the CORRECTED behaviour: headings nest, and CommonMark's limit
-- of six is respected. Keep them -- they are the regression fence for a bug that was
-- duplicated at six call sites before the rule was centralised in MD.heading.
-- ---------------------------------------------------------------------------

do
    local root = MapModel.parse_mindmap("# A\n## B\n# C\n", "Doc")
    check("three heading lines produce heading nodes, not one collapsed paragraph",
        #root.children == 2
        and root.children[1].kind == "heading" and root.children[1].text == "A"
        and root.children[2].kind == "heading" and root.children[2].text == "C")
    check("a deeper heading nests under the shallower one before it",
        #root.children[1].children == 1
        and root.children[1].children[1].kind == "heading"
        and root.children[1].children[1].text == "B")
end

do
    local root = MapModel.parse_mindmap("# Top\n\n## Mid\n\n- leaf\n", "Doc")
    check("a list item nests under the heading that precedes it",
        #root.children == 1
        and root.children[1].children[1].text == "Mid"
        and root.children[1].children[1].children[1].kind == "list"
        and root.children[1].children[1].children[1].text == "leaf")
end

do
    -- CommonMark: seven or more '#' is not a heading. The old pattern could not
    -- express the 1-6 bound at all; MD.heading enforces it with a length check.
    local root = MapModel.parse_mindmap("####### Seven\n", "Doc")
    check("seven hashes is not a heading (falls through to paragraph)",
        #root.children == 1 and root.children[1].kind == "paragraph")
    local six = MapModel.parse_mindmap("###### Six\n", "Doc")
    check("six hashes IS a heading, at level 6",
        #six.children == 1 and six.children[1].kind == "heading"
        and six.children[1].text == "Six" and six.children[1].level == 6)
end

do
    -- The paragraph-continuation scan used the same broken pattern, so it did not
    -- break on a following heading either. That is what merged A/B/C into one node.
    local root = MapModel.parse_mindmap("para text\n# Heading\n", "Doc")
    check("a paragraph stops at a following heading rather than absorbing it",
        #root.children == 2
        and root.children[1].kind == "paragraph" and root.children[1].text == "para text"
        and root.children[2].kind == "heading" and root.children[2].text == "Heading")
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
    -- Previously "# H" was not recognized as a heading, so the list item that followed
    -- became its SIBLING at top level rather than its child. With MD.heading in place
    -- the heading is recognized, heading_level advances, and the item nests under it.
    local root = MapModel.parse_mindmap("# H\n- item one\n", "Doc")
    check("a '#'-line followed by a list item nests the item under the heading",
        #root.children == 1
        and root.children[1].kind == "heading" and root.children[1].text == "H"
        and #root.children[1].children == 1
        and root.children[1].children[1].kind == "list"
        and root.children[1].children[1].text == "item one")
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
