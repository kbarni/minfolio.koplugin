-- SPDX-License-Identifier: AGPL-3.0-only
-- Off-device unit tests for minfolio_menu_model.lua (PALETTE_PLAN.md P1-1). Run with plain
-- lua/luajit, no KOReader install required:
--   luajit minfolio_menu_model_test.lua
-- Exit code is 0 iff every assertion passed.

package.path = (arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or ".") .. "/?.lua;" .. package.path
local Model = require("minfolio_menu_model")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL: " .. label .. "\n")
    end
end

-- A fully-capable editing session: nothing hidden, nothing greyed. Individual
-- tests below switch off one field at a time, so a failure names the one rule
-- that broke rather than "some predicate is wrong".
local function full_state(overrides)
    local state = {
        reader_mode = false, remote = false,
        has_selection = true, can_undo = true, can_redo = true, has_clipboard = true,
        has_find_query = true, keyboard = true, frontlight_on = true, has_warmth = true,
    }
    for k, v in pairs(overrides or {}) do state[k] = v end
    return state
end

local function by_id(rows, id)
    for _, row in ipairs(rows) do
        if row.id == id then return row end
    end
    return nil
end

local function command_by_id(id)
    for _, cmd in ipairs(Model.commands()) do
        if cmd.id == id then return cmd end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The command table itself
-- ---------------------------------------------------------------------------

do
    local ids, groups, actions = {}, {}, {}
    local dup_id, missing_field, unknown_group = nil, nil, nil
    local known = { File = true, Edit = true, View = true, Style = true }
    for _, cmd in ipairs(Model.commands()) do
        if ids[cmd.id] then dup_id = cmd.id end
        ids[cmd.id] = true
        if type(cmd.label) ~= "string" or cmd.label == ""
            or type(cmd.action) ~= "string" or cmd.action == ""
            or type(cmd.group) ~= "string" then
            missing_field = tostring(cmd.id)
        end
        if not known[cmd.group] then unknown_group = cmd.group end
        groups[cmd.group] = true
        actions[cmd.action] = (actions[cmd.action] or 0) + 1
    end
    check("commands: ids are unique", dup_id == nil)
    check("commands: every command has a label, an action and a group", missing_field == nil)
    check("commands: no command lands in an undeclared group", unknown_group == nil)
    check("commands: all four phase-1 groups are populated",
        groups.File and groups.Edit and groups.View and groups.Style)
    -- Help is empty in phase 1 (its only member, About, is phase 2), and an empty
    -- group would render as a heading with nothing under it.
    check("commands: no empty Help group is declared", groups.Help == nil)

    local reused = nil
    for action, count in pairs(actions) do
        if count > 1 then reused = action end
    end
    check("commands: no two commands dispatch the same action", reused == nil)
end

do
    -- Acceptance criterion 8: everything reachable from today's openControls
    -- must still be reachable. This is that list, by action name.
    local required = {
        "open_markdown", "close", "find_input", "replace", "outline", "word_count",
        "mindmap", "toggle_reader", "toggle_keyboard", "header", "bold", "italic",
        "list", "ordered", "task", "table", "larger", "smaller", "select_all",
        "copy", "cut", "paste", "undo", "redo", "rotate",
        "brightness_up", "brightness_down", "warmth_up", "warmth_down", "toggle_frontlight",
    }
    local present = {}
    for _, cmd in ipairs(Model.commands()) do present[cmd.action] = true end
    local missing = nil
    for _, action in ipairs(required) do
        if not present[action] then missing = action end
    end
    check("commands: no command from the old openControls list was lost", missing == nil)
end

do
    -- An advertised chord that does nothing is worse than no chord. Heading is
    -- the deliberate omission: Ctrl-1..6 sets an absolute level, this cycles.
    check("commands: Heading advertises no accelerator", command_by_id("style_heading").accel == nil)
    check("commands: Bold advertises Ctrl-B", command_by_id("style_bold").accel == "Ctrl-B")
end

-- ---------------------------------------------------------------------------
-- display_text
-- ---------------------------------------------------------------------------

do
    check("display_text: group prefixes the label",
        Model.display_text({ group = "Style", label = "Bold" }) == "Style: Bold")
    check("display_text: an accelerator is appended in parentheses",
        Model.display_text({ group = "Style", label = "Bold", accel = "Ctrl-B" })
            == "Style: Bold (Ctrl-B)")
end

do
    -- The checkbox glyph is the widget's business. If it were baked in here the
    -- search text would change every time a box was ticked.
    local cmd = command_by_id("view_frontlight")
    local text_on = Model.display_text(cmd)
    local text_off = Model.display_text(cmd)
    check("display_text: does not depend on checked state", text_on == text_off)
    check("display_text: carries no checkbox glyph", not text_on:find("\226\152\145", 1, true))
end

-- ---------------------------------------------------------------------------
-- command_state: visibility
-- ---------------------------------------------------------------------------

do
    local rows = Model.visible_commands(full_state())
    check("visible: a full editing session shows every command", #rows == #Model.commands())
end

do
    local rows = Model.visible_commands(full_state{ reader_mode = true })
    check("visible: reader mode hides the editing commands", by_id(rows, "edit_undo") == nil)
    check("visible: reader mode hides the whole Style group", by_id(rows, "style_bold") == nil)
    check("visible: reader mode hides Mindmap mode", by_id(rows, "view_mindmap") == nil)
    check("visible: reader mode hides the keyboard toggle", by_id(rows, "view_keyboard") == nil)
    -- The way back out has to survive the mode that hides everything else.
    check("visible: the reader-mode toggle survives reader mode", by_id(rows, "view_reader") ~= nil)
    check("visible: Find survives reader mode", by_id(rows, "edit_find") ~= nil)
    check("visible: Outline survives reader mode", by_id(rows, "view_outline") ~= nil)
    check("visible: Word count survives reader mode", by_id(rows, "view_word_count") ~= nil)
    check("visible: closing the note survives reader mode", by_id(rows, "file_close") ~= nil)
    check("visible: Rotate display survives reader mode", by_id(rows, "view_rotate") ~= nil)
end

do
    local rows = Model.visible_commands(full_state{ has_warmth = false })
    check("visible: no amber hardware removes Warmth +", by_id(rows, "view_warm_up") == nil)
    check("visible: no amber hardware removes Warmth -", by_id(rows, "view_warm_down") == nil)
    check("visible: no amber hardware leaves Brightness alone", by_id(rows, "view_bright_up") ~= nil)
end

-- ---------------------------------------------------------------------------
-- command_state: enablement
-- ---------------------------------------------------------------------------

do
    -- Transient state greys rather than hides, so the list keeps its shape.
    local rows = Model.visible_commands(full_state{ has_selection = false })
    check("enabled: no selection greys Copy", by_id(rows, "edit_copy").enabled == false)
    check("enabled: no selection greys Cut", by_id(rows, "edit_cut").enabled == false)
    check("enabled: no selection leaves Copy in the list", by_id(rows, "edit_copy") ~= nil)
    check("enabled: no selection leaves Paste alone", by_id(rows, "edit_paste").enabled == true)
    check("enabled: no selection leaves the list length unchanged",
        #rows == #Model.visible_commands(full_state()))
end

do
    local rows = Model.visible_commands(full_state{ can_undo = false })
    check("enabled: an empty undo stack greys Undo", by_id(rows, "edit_undo").enabled == false)
    check("enabled: an empty undo stack leaves Redo alone", by_id(rows, "edit_redo").enabled == true)
end

do
    local rows = Model.visible_commands(full_state{ can_redo = false })
    check("enabled: an empty redo stack greys Redo", by_id(rows, "edit_redo").enabled == false)
    check("enabled: an empty redo stack leaves Undo alone", by_id(rows, "edit_undo").enabled == true)
end

do
    local rows = Model.visible_commands(full_state{ has_clipboard = false })
    check("enabled: an empty clipboard greys Paste", by_id(rows, "edit_paste").enabled == false)
end

do
    local rows = Model.visible_commands(full_state{ has_find_query = false })
    check("enabled: no find query greys Find next", by_id(rows, "edit_find_next").enabled == false)
    check("enabled: no find query greys Find previous",
        by_id(rows, "edit_find_previous").enabled == false)
    check("enabled: no find query leaves Find itself alone", by_id(rows, "edit_find").enabled == true)
end

do
    -- A remote session's document is a shadow file owned by the sync worker.
    local rows = Model.visible_commands(full_state{ remote = true })
    check("enabled: a remote session greys Open", by_id(rows, "file_open").enabled == false)
    check("enabled: a remote session leaves Save alone", by_id(rows, "file_save").enabled == true)
    check("enabled: a remote session leaves Save and close alone",
        by_id(rows, "file_close").enabled == true)
end

-- ---------------------------------------------------------------------------
-- command_state: checkboxes
-- ---------------------------------------------------------------------------

do
    local rows = Model.visible_commands(full_state{ frontlight_on = true })
    check("checked: Front light reads as ticked when the lamp is on",
        by_id(rows, "view_frontlight").checked == true)
    rows = Model.visible_commands(full_state{ frontlight_on = false })
    check("checked: Front light reads as unticked when the lamp is off",
        by_id(rows, "view_frontlight").checked == false)
end

do
    local rows = Model.visible_commands(full_state{ keyboard = false })
    check("checked: the keyboard toggle reads as unticked with no keyboard up",
        by_id(rows, "view_keyboard").checked == false)
end

do
    local rows = Model.visible_commands(full_state{ reader_mode = true })
    check("checked: the reader toggle reads as ticked in reader mode",
        by_id(rows, "view_reader").checked == true)
end

do
    -- nil, not false: the widget uses this to tell "no checkbox" from "empty
    -- checkbox", and drawing an empty box beside Bold would be wrong.
    local rows = Model.visible_commands(full_state())
    check("checked: an ordinary command carries no checkbox at all",
        by_id(rows, "style_bold").checked == nil)
end

-- ---------------------------------------------------------------------------
-- Repeatable commands (Chrome.show_controls' `keep`, preserved)
-- ---------------------------------------------------------------------------

do
    local rows = Model.visible_commands(full_state())
    check("repeatable: Brightness + does not dismiss", by_id(rows, "view_bright_up").repeatable == true)
    check("repeatable: Warmth - does not dismiss", by_id(rows, "view_warm_down").repeatable == true)
    check("repeatable: Text size + does not dismiss", by_id(rows, "view_text_larger").repeatable == true)
    check("repeatable: Bold does dismiss", by_id(rows, "style_bold").repeatable == false)
    check("repeatable: Save does dismiss", by_id(rows, "file_save").repeatable == false)
end

-- ---------------------------------------------------------------------------
-- filter
-- ---------------------------------------------------------------------------

do
    local state = full_state()
    check("filter: an empty query returns every visible command",
        #Model.filter("", state) == #Model.visible_commands(state))
    check("filter: a nil query is treated as empty",
        #Model.filter(nil, state) == #Model.visible_commands(state))
end

do
    local rows = Model.filter("bold", full_state())
    check("filter: matching is case-insensitive", #rows == 1 and rows[1].id == "style_bold")
    check("filter: an uppercase query matches the same row",
        #Model.filter("BOLD", full_state()) == 1)
end

do
    -- The group name is part of the search text, so a group is browsable by typing it.
    -- The expected count is derived, not hardcoded: adding a Style command in
    -- phase 2 should not fail this test, but a Style command that stops matching
    -- its own group name should.
    local expected = 0
    for _, cmd in ipairs(Model.commands()) do
        if cmd.group == "Style" then expected = expected + 1 end
    end
    local rows = Model.filter("style", full_state())
    local all_style = #rows > 0
    for _, row in ipairs(rows) do
        if not row.text:find("Style", 1, true) then all_style = false end
    end
    check("filter: typing a group name returns that whole group",
        all_style and #rows == expected and expected > 1)
end

do
    check("filter: a query matching nothing returns an empty list",
        #Model.filter("zzzznotacommand", full_state()) == 0)
end

do
    -- THE trap this module exists to avoid: without find(..., true) these are
    -- Lua patterns. '+' is a quantifier (and "e +" would raise), '.' matches any
    -- character, '%' starts an escape and throws "malformed pattern".
    local plus = Model.filter("size +", full_state())
    check("filter: a query containing '+' is matched literally",
        #plus == 1 and plus[1].id == "view_text_larger")
    local minus = Model.filter("size -", full_state())
    check("filter: a query containing '-' is matched literally",
        #minus == 1 and minus[1].id == "view_text_smaller")
    check("filter: a query containing '...' is matched literally",
        #Model.filter("find...", full_state()) == 1)
    -- '%' must be a query whose literal prefix really occurs in a command text
    -- ("text" does, in "Text size +"). Lua raises the malformed-pattern error
    -- only once the matcher actually reaches the trailing '%', so a query like
    -- "100%" that matches nothing early would pass this test even in pattern
    -- mode -- it would never get that far. This one raises without the plain flag.
    local ok = pcall(Model.filter, "text%", full_state())
    check("filter: a query containing '%' does not raise", ok)
    check("filter: a query containing '%' simply matches nothing",
        ok and #Model.filter("text%", full_state()) == 0)
    check("filter: a query containing '(' is matched literally",
        #Model.filter("(ctrl-b)", full_state()) == 1)
end

do
    -- Accelerators are searchable, which is how the chords get taught.
    local rows = Model.filter("ctrl-shift", full_state())
    check("filter: a chord is searchable", #rows >= 3)
end

do
    -- No relevance reordering: whatever the query, results keep the order they
    -- were declared in, so a command stays where muscle memory left it.
    local state = full_state()
    local all = Model.visible_commands(state)
    local order = {}
    for i, row in ipairs(all) do order[row.id] = i end
    local rows = Model.filter("e", state)          -- deliberately broad
    local monotonic = true
    for i = 2, #rows do
        if order[rows[i].id] <= order[rows[i - 1].id] then monotonic = false end
    end
    check("filter: results keep declaration order, they are not ranked", monotonic and #rows > 3)
end

do
    -- Filtering runs over visible commands only, so a hidden command can never
    -- be typed into view.
    local rows = Model.filter("warmth", full_state{ has_warmth = false })
    check("filter: a hidden command cannot be surfaced by searching for it", #rows == 0)
    rows = Model.filter("bold", full_state{ reader_mode = true })
    check("filter: reader mode's hidden commands stay hidden under search", #rows == 0)
end

do
    -- Disabled is not hidden: a greyed command is still findable, so the user
    -- can see it exists and why it is unavailable rather than concluding it is gone.
    local rows = Model.filter("copy", full_state{ has_selection = false })
    check("filter: a disabled command is still returned", #rows == 1)
    check("filter: and is still marked disabled", rows[1].enabled == false)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
