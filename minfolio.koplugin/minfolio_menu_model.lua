-- SPDX-License-Identifier: AGPL-3.0-only
-- The editor's command set as data, for minfolio.koplugin (PALETTE_PLAN.md §4.1,
-- work package P1-1). Deliberately zero KOReader dependencies: no
-- `require("ui/...")`, no `gettext`, nothing that only exists inside a running
-- KOReader process. That is not a style preference, it is the only way any of
-- this can be checked off-device -- see minfolio_menu_model_test.lua, runnable
-- with plain lua/luajit, no KOReader install required:
--   luajit minfolio_menu_model_test.lua
--
-- This module replaces the hand-written 25-item list inside MDEdit:openControls
-- (minfolio_edit_view.lua) with one declarative table, so that the command set,
-- its grouping, and the rules for when each command is available all live in a
-- place the test suite can reach. minfolio_palette.lua (P1-2) renders whatever
-- this returns and knows nothing about individual commands.
--
-- Three constraints follow from Tier 0 purity and are load-bearing:
--
--   * LABELS ARE RAW ENGLISH, not `_("...")`. gettext is a KOReader require, and
--     taking it here would delete this module's test coverage. The widget
--     applies _() at render time.
--   * ACTIONS ARE STRINGS, not closures. Each command names an action that the
--     widget hands to MDEdit:runTopAction. Strings keep this module free of the
--     editor, keep it comparable in tests, and keep the command count off the
--     200-local ceiling (ARCHITECTURE.md).
--   * PREDICATES READ A SNAPSHOT, not the editor. `command_state` is a pure
--     function of the plain table MDEdit:paletteState() builds, so every
--     enable/hide/check rule is testable without a device.
--
-- VISIBLE vs ENABLED is a real distinction here, not a synonym (PALETTE_PLAN.md
-- §4.3 vs its acceptance criterion 5, which is why this comment exists):
--
--   * Transient state greys a command but leaves it in place. "Copy" with no
--     selection stays where it was, so the list does not reshuffle under the
--     user's finger as a selection comes and goes.
--   * A mode or missing hardware removes it entirely. Reader mode has no caret,
--     so ~15 editing commands there would be permanent dead weight; a device
--     with no amber LED can never use Warmth. Neither of those flickers, so
--     hiding costs no stability.
--
-- Phase 1 declared only commands that already existed in the editor. P2-1 added
-- five (New, Save as, Select none, Code block, About) -- `Quit` turned out to
-- need no row, because PALETTE_PLAN.md §7.1 resolves it to what `file_close`
-- already does. The two display toggles (toolbar, line numbers) are still to
-- come, in P2-2 and P2-4. Everything reachable from the old openControls is
-- present, which is acceptance criterion 8; do not drop a row without checking
-- that list.
--
-- Required by callers as `local Model = require("minfolio_menu_model")`.

local M = {}

-- Command fields:
--   id         stable identifier, used by tests and by nothing else
--   group      display group; also part of the search text ("Style: Bold")
--   label      raw English, translated at render time
--   action     passed to MDEdit:runTopAction
--   accel      keyboard chord to display, or nil. Must match a chord that really
--              exists in MDEdit:onKeyPress -- an advertised chord that does
--              nothing is worse than none. `Heading` deliberately has none:
--              Ctrl-1..6 sets an absolute level (fmtHeadingLevel), whereas this
--              command cycles (fmtHeader), and they are not the same thing.
--   mode       "edit" to hide the command in reader mode; nil for always
--   needs      hardware requirement ("warmth"); nil for always
--   enable     transient-state predicate name (see command_state); nil for always
--   check      checkbox state name; nil for an ordinary command
--   repeatable true to keep the palette open after running it, so a value can be
--              nudged several times. Carried over from Chrome.show_controls'
--              `keep` flag (minfolio_chrome.lua), whose behaviour this preserves.
local COMMANDS = {
    -- File ------------------------------------------------------------------
    -- New and Save as are both `local_file`: a remote document is a session
    -- shadow the desktop owns, with nowhere on this device for a sibling note to
    -- go and no way to tell the desktop the file was renamed.
    { id = "file_new",    group = "File", label = "New note...", action = "new_note",
      enable = "local_file" },
    { id = "file_open",   group = "File", label = "Open .md file...", action = "open_markdown",
      enable = "local_file" },
    { id = "file_save",   group = "File", label = "Save", action = "save", accel = "Ctrl-S" },
    { id = "file_save_as", group = "File", label = "Save as...", action = "save_as",
      enable = "local_file" },
    -- This IS PALETTE_PLAN.md §7.1's `File: Quit`, resolved. "Quit" next to
    -- "Open" reads as leaving Minfolio for KOReader, which nothing implements;
    -- the label states what actually happens instead of promising that.
    { id = "file_close",  group = "File", label = "Save and close note", action = "close" },

    -- Edit ------------------------------------------------------------------
    { id = "edit_undo",   group = "Edit", label = "Undo", action = "undo", accel = "Ctrl-Z",
      mode = "edit", enable = "undo" },
    { id = "edit_redo",   group = "Edit", label = "Redo", action = "redo", accel = "Ctrl-Shift-Z",
      mode = "edit", enable = "redo" },
    { id = "edit_copy",   group = "Edit", label = "Copy", action = "copy", accel = "Ctrl-C",
      mode = "edit", enable = "selection" },
    { id = "edit_cut",    group = "Edit", label = "Cut", action = "cut", accel = "Ctrl-X",
      mode = "edit", enable = "selection" },
    { id = "edit_paste",  group = "Edit", label = "Paste", action = "paste", accel = "Ctrl-V",
      mode = "edit", enable = "clipboard" },
    { id = "edit_select_all", group = "Edit", label = "Select all", action = "select_all",
      accel = "Ctrl-A", mode = "edit" },
    { id = "edit_select_none", group = "Edit", label = "Select none", action = "select_none",
      mode = "edit", enable = "selection" },
    { id = "edit_find",   group = "Edit", label = "Find...", action = "find_input", accel = "Ctrl-F" },
    { id = "edit_find_next", group = "Edit", label = "Find next", action = "find_next",
      accel = "Ctrl-G", enable = "find_query" },
    { id = "edit_find_previous", group = "Edit", label = "Find previous", action = "find_previous",
      accel = "Ctrl-Shift-G", enable = "find_query" },
    { id = "edit_replace", group = "Edit", label = "Find and replace...", action = "replace",
      accel = "Ctrl-H", mode = "edit" },

    -- View ------------------------------------------------------------------
    -- Reader mode is one checkbox rather than the separate "Reader mode" /
    -- "Exit reader mode" entries openControls used, so it stays in one place in
    -- the list across the switch. It must NOT carry mode = "edit": it is the way
    -- back out of reader mode.
    { id = "view_reader", group = "View", label = "Reader mode", action = "toggle_reader",
      check = "reader_mode" },
    { id = "view_outline", group = "View", label = "Outline", action = "outline" },
    { id = "view_word_count", group = "View", label = "Word count", action = "word_count",
      accel = "Ctrl-W" },
    { id = "view_mindmap", group = "View", label = "Mindmap mode", action = "mindmap", mode = "edit" },
    { id = "view_keyboard", group = "View", label = "Show keyboard", action = "toggle_keyboard",
      mode = "edit", check = "keyboard" },
    { id = "view_rotate", group = "View", label = "Rotate display", action = "rotate" },
    { id = "view_text_larger", group = "View", label = "Text size +", action = "larger",
      repeatable = true },
    { id = "view_text_smaller", group = "View", label = "Text size -", action = "smaller",
      repeatable = true },
    { id = "view_bright_up", group = "View", label = "Brightness +", action = "brightness_up",
      repeatable = true },
    { id = "view_bright_down", group = "View", label = "Brightness -", action = "brightness_down",
      repeatable = true },
    { id = "view_warm_up", group = "View", label = "Warmth +", action = "warmth_up",
      needs = "warmth", repeatable = true },
    { id = "view_warm_down", group = "View", label = "Warmth -", action = "warmth_down",
      needs = "warmth", repeatable = true },
    { id = "view_frontlight", group = "View", label = "Front light", action = "toggle_frontlight",
      check = "frontlight" },

    -- Style -----------------------------------------------------------------
    { id = "style_heading", group = "Style", label = "Heading", action = "header", mode = "edit" },
    { id = "style_bold",    group = "Style", label = "Bold", action = "bold", accel = "Ctrl-B",
      mode = "edit" },
    { id = "style_italic",  group = "Style", label = "Italic", action = "italic", accel = "Ctrl-I",
      mode = "edit" },
    { id = "style_code",    group = "Style", label = "Code", action = "code", accel = "Ctrl-E",
      mode = "edit" },
    { id = "style_bullet",  group = "Style", label = "Bullet list", action = "list",
      accel = "Ctrl-Shift-L", mode = "edit" },
    { id = "style_numbered", group = "Style", label = "Numbered list", action = "ordered",
      accel = "Ctrl-Shift-O", mode = "edit" },
    { id = "style_check",   group = "Style", label = "Check list", action = "task",
      accel = "Ctrl-Shift-T", mode = "edit" },
    -- "Code" wraps a selection in single backticks (inline); "Code block" opens a
    -- fenced region. Both labels contain "code", so a "code" query offers the
    -- pair rather than silently picking one.
    { id = "style_code_block", group = "Style", label = "Code block", action = "code_block",
      mode = "edit" },
    { id = "style_table",   group = "Style", label = "Table", action = "table", mode = "edit" },

    -- Help ------------------------------------------------------------------
    { id = "help_about",  group = "Help", label = "About Minfolio", action = "about" },
}

function M.commands()
    return COMMANDS
end

-- The text a command shows AND the text a query is matched against -- one
-- string, so that anything readable is findable. Deliberately independent of
-- state: the checkbox glyph is prepended by the widget, not baked in here, or
-- the search text would change every time a box is ticked.
function M.display_text(cmd)
    local text = cmd.group .. ": " .. cmd.label
    if cmd.accel then text = text .. " (" .. cmd.accel .. ")" end
    return text
end

-- Pure function of the snapshot MDEdit:paletteState() builds. Returns
-- visible, enabled, checked -- see the visible/enabled note in the header.
-- `checked` is nil for an ordinary command and a boolean for a checkbox one, so
-- the widget can tell "no box" from "empty box".
function M.command_state(cmd, state)
    state = state or {}

    local visible = true
    if cmd.mode == "edit" and state.reader_mode then visible = false end
    if cmd.needs == "warmth" and not state.has_warmth then visible = false end

    local enabled = true
    local rule = cmd.enable
    if rule == "selection" then enabled = not not state.has_selection
    elseif rule == "undo" then enabled = not not state.can_undo
    elseif rule == "redo" then enabled = not not state.can_redo
    elseif rule == "clipboard" then enabled = not not state.has_clipboard
    elseif rule == "find_query" then enabled = not not state.has_find_query
    elseif rule == "local_file" then enabled = not state.remote
    end

    local checked
    if cmd.check == "reader_mode" then checked = not not state.reader_mode
    elseif cmd.check == "keyboard" then checked = not not state.keyboard
    elseif cmd.check == "frontlight" then checked = not not state.frontlight_on
    end

    return visible, enabled, checked
end

-- One render-ready row per visible command, in declaration order. The widget
-- renders these without consulting COMMANDS again.
function M.visible_commands(state)
    local out = {}
    for _, cmd in ipairs(COMMANDS) do
        local visible, enabled, checked = M.command_state(cmd, state)
        if visible then
            out[#out + 1] = {
                id = cmd.id,
                action = cmd.action,
                text = M.display_text(cmd),
                enabled = enabled,
                checked = checked,
                repeatable = not not cmd.repeatable,
            }
        end
    end
    return out
end

-- Case-insensitive PLAIN substring match -- `find(..., true)`, never a Lua
-- pattern. Without the plain flag a query containing '+', '-', '.', '(' or '%'
-- is compiled as a pattern, so "Text size +" and "Find..." become unsearchable
-- and a lone '%' raises an error inside the search box. Same reasoning, and the
-- same fix, as minfolio_find.lua's M.matches.
--
-- Declaration order is preserved and disabled commands are kept (greyed by the
-- widget): a list that reorders itself by relevance, or that drops entries as
-- state changes, cannot be hit from muscle memory. PALETTE_PLAN.md §4.3.
function M.filter(query, state)
    local rows = M.visible_commands(state)
    query = tostring(query or "")
    if query == "" then return rows end
    local needle = query:lower()
    local out = {}
    for _, row in ipairs(rows) do
        if row.text:lower():find(needle, 1, true) then out[#out + 1] = row end
    end
    return out
end

return M
