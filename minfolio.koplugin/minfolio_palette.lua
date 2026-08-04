-- SPDX-License-Identifier: AGPL-3.0-only
-- The command palette widget for minfolio.koplugin (PALETTE_PLAN.md §5, work
-- packages P1-2 and P1-3): a centred, searchable list of every command the
-- editor can run. Replaces the flat 25-item popup that MDEdit:openControls used
-- to build by hand. Opened by the hamburger button or Ctrl-P; driven by touch or
-- by an external keyboard (arrows, Enter, Esc, and type-to-filter).
--
-- Requires KOReader (`Menu`, `TitleBar`, `InputDialog`, `FocusManager`,
-- `UIManager`), so this
-- cannot be `require`d and executed under plain luajit -- only `loadfile`-parsed,
-- exactly like main.lua itself -- so no off-device test suite is included. What
-- IS testable (the command set, the enable/hide/check rules, the filter) lives in
-- minfolio_menu_model.lua, which this module renders and does not second-guess.
--
-- NOT an MDEdit mixin, and deliberately so (PALETTE_PLAN.md §5.1). It takes a
-- state snapshot and two callbacks and knows nothing about the editor, which
-- keeps MDEdit's four-file assembly at four files, keeps this reusable by the
-- browser or mindmap later without recreating the cycle minfolio_app exists to
-- break, and lets it be exercised on a desktop KOReader in isolation. Tier 1,
-- alongside minfolio_chrome.
--
-- Chrome.show_controls is deliberately NOT reused or modified: it is shared with
-- the browser, the mindmap and the pairing menu, and its item list always leads
-- with the frontlight controls. This module borrows two conventions from it --
-- the `is_popout` Menu shape, and deferring a selected action by 0.01s so the
-- menu is fully closed before an action that opens another widget runs -- but
-- nothing else.
--
-- On `_()`: the command labels arriving from the model are composed strings
-- ("Style: Bold (Ctrl-B)"), and the same string is what the filter matches
-- against. Translating the composed form would put display and search key in
-- different languages, and translating the parts would need the model to hand
-- them over separately. The plugin ships no translation catalogues, so the
-- composed text is rendered as-is; this module's OWN chrome (title, buttons,
-- hints) goes through _() normally. Revisit if catalogues ever arrive.
--
-- Required by callers as `local Palette = require("minfolio_palette")`.

local Device = require("device")
local Screen = Device.screen
local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local InputDialog = require("ui/widget/inputdialog")
local FocusManager = require("ui/widget/focusmanager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Model = require("minfolio_menu_model")
local Keys = require("minfolio_keys")
local Text = require("minfolio_text")
local C = require("minfolio_const")

local M = {}

-- U+2611 / U+2610. The unticked box is the same glyph the editor already renders
-- for a "[ ] " task marker, so a checkbox reads the same in both places.
local CHECKED = "\226\152\145 "
local UNCHECKED = "\226\152\144 "

local function build_items(rows)
    local items = {}
    for _, row in ipairs(rows) do
        local text = row.text
        -- nil means "not a checkbox at all" -- drawing an empty box beside Bold
        -- would claim a state it does not have. See the model's command_state.
        if row.checked ~= nil then
            text = (row.checked and CHECKED or UNCHECKED) .. text
        end
        items[#items + 1] = {
            text = text,
            dim = not row.enabled,
            palette_row = row,
        }
    end
    if #items == 0 then
        items[1] = { text = _("No matching command"), dim = true, select_enabled = false }
    end
    return items
end

-- opts.state       the snapshot from MDEdit:paletteState()
-- opts.max_height  optional cap, so the palette fits above an open keyboard (§5.3)
-- opts.on_select   function(action) -- an action string from the model
-- opts.on_close    function() -- called exactly once, however the palette goes away
function M.show(opts)
    opts = opts or {}
    local state = opts.state or {}
    local query = ""
    local menu, title_bar, focus_row, focus_first, select_row

    -- on_close must fire exactly once, on EVERY route out. `close_callback` is
    -- not that route: Menu only invokes it from onCloseAllMenus, i.e. the Back
    -- button and the close icon. Closing the palette any other way -- the editor
    -- going away underneath it, a teardown, UIManager closing the stack -- skips
    -- it entirely, and the caller's is_always_active handover would never be
    -- undone, leaving the editor unable to take a keystroke for the rest of the
    -- session. CloseWidget is broadcast by UIManager:close itself, so hooking
    -- onCloseWidget catches all of them; the guard makes the duplicate harmless.
    local closed = false
    local function finish()
        if closed then return end
        closed = true
        if opts.on_close then opts.on_close() end
    end

    local function subtitle_text()
        if query ~= "" then return _("Filter") .. ": " .. query end
        return _("Type to filter, or tap the search icon")
    end

    local function apply_query(new_query)
        query = tostring(new_query or "")
        menu:switchItemTable(nil, build_items(Model.filter(query, state)), nil, nil, subtitle_text())
        -- switchItemTable rebuilds the page and therefore self.layout, so any
        -- previous focus points at a MenuItem that is no longer on screen.
        focus_first()
    end

    -- Live typing coalesced into one filter pass per idle window: filtering per
    -- character would cost a partial e-ink repaint per character, and a Kindle
    -- does not keep up. Same reasoning, and the same shape, as the editor's own
    -- queueTypedChar/flushTypeBuffer pair (PALETTE_PLAN.md §5.4).
    --
    -- The pending query is applied by whichever flush is already scheduled, so a
    -- burst of keystrokes costs exactly one repaint, and the last character
    -- typed is always the one that lands.
    local pending_query, flush_scheduled = nil, false
    local function flush_query()
        flush_scheduled = false
        if pending_query ~= nil then
            local q = pending_query
            pending_query = nil
            apply_query(q)
        end
    end
    local function queue_query(new_query)
        pending_query = new_query
        -- Keep the typed text visible immediately even though the list itself
        -- waits for the debounce -- a query field that lags behind the keys
        -- reads as dropped input.
        if title_bar then title_bar:setSubTitle(_("Filter") .. ": " .. new_query) end
        if flush_scheduled then return end
        flush_scheduled = true
        UIManager:scheduleIn(C.PALETTE.FILTER_DEBOUNCE, flush_query)
    end

    -- The dialog path hands over a complete string, so it skips the debounce
    -- entirely: one filter pass, one repaint.
    local function open_query_dialog()
        local dlg
        dlg = InputDialog:new{
            title = _("Filter commands"),
            input = query,
            buttons = {{
                { text = _("Clear"), callback = function()
                    UIManager:close(dlg)
                    apply_query("")
                end },
                { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
                { text = _("Filter"), is_enter_default = true, callback = function()
                    local entered = dlg:getInputText() or ""
                    UIManager:close(dlg)
                    apply_query(entered)
                end },
            }},
        }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    end

    -- The palette is a dialog sitting over the editor, so it is deliberately
    -- smaller than the screen -- which means it also has to be told where to go
    -- (see the show() call at the bottom). `avail_height` is the room the palette
    -- is ALLOWED, which is not the screen height when an on-screen keyboard is up.
    local width = math.floor(Screen:getWidth() * 0.9)
    local avail_height = math.min(opts.max_height or math.huge, Screen:getHeight())
    local height = math.min(avail_height, math.floor(Screen:getHeight() * 0.8))

    -- Constructed with a non-empty subtitle on purpose: TitleBar:setSubTitle is a
    -- no-op unless a subtitle widget already exists, so a palette built with an
    -- empty one could never show a query afterwards.
    --
    -- Sized to the menu, not the screen: Menu builds its own title bar at
    -- `self.dimen.w`, and a custom one left at full screen width would paint out
    -- past the right border of a menu that is only 90% as wide.
    title_bar = TitleBar:new{
        width = width,
        align = "center",
        title = _("Commands"),
        subtitle = subtitle_text(),
        with_bottom_line = true,
        left_icon = "appbar.search",
        left_icon_tap_callback = function() open_query_dialog() end,
        close_callback = function() if menu then menu:onClose() end end,
    }

    menu = Menu:new{
        title = _("Commands"),
        item_table = build_items(Model.filter("", state)),
        is_popout = true,
        custom_title_bar = title_bar,
        width = width,
        height = height,
        -- Deliberately NOT marked `minfolio_screen`: this is a dialog shown over
        -- a Minfolio screen that is still stacked underneath, and minfolio_chrome
        -- only asks that question of full-screen views (see its comment on
        -- minfolio_screen_shown).
        onMenuSelect = function(_self, item) return select_row(item) end,
    }
    local original_close_widget = menu.onCloseWidget
    function menu:onCloseWidget()
        if original_close_widget then original_close_widget(self) end
        if flush_scheduled then UIManager:unschedule(flush_query) end
        finish()
    end
    title_bar.show_parent = menu
    if title_bar.left_button then title_bar.left_button.show_parent = menu end
    if title_bar.right_button then title_bar.right_button.show_parent = menu end

    -- One selection path for touch and keyboard alike. Driving the keyboard
    -- through FocusManager:onPress would round-trip a synthetic tap gesture
    -- through the focused MenuItem's dimen, which is nil until the widget has
    -- been painted once; reading the focused item's `entry` and calling this is
    -- both simpler and free of that ordering hazard.
    select_row = function(item)
        local row = item and item.palette_row
        if not row then return true end
        -- A greyed command stays in the list so it can be found and read, but
        -- running it would do nothing useful -- swallow the input rather than
        -- dismissing the palette as if something had happened.
        if not row.enabled then return true end
        if row.repeatable then
            if opts.on_select then opts.on_select(row.action) end
            return true
        end
        UIManager:close(menu)   -- fires onCloseWidget above, hence finish()
        if opts.on_select then
            UIManager:scheduleIn(0.01, function() opts.on_select(row.action) end)
        end
        return true
    end

    -- FocusManager only dispatches the Focus/Unfocus events that make a
    -- selection VISIBLE when Device:hasDPad() -- or when FORCED_FOCUS is asked
    -- for (focusmanager.lua's moveFocusTo). The target here is a touch-only
    -- Kindle driving the palette from a Bluetooth keyboard, where hasDPad is
    -- false, so without the flag the arrows would move an invisible cursor.
    focus_row = function(y)
        if not (menu and menu.layout and menu.layout[y]) then return false end
        return menu:moveFocusTo(1, y, FocusManager.FORCED_FOCUS)
    end

    -- self.layout is NOT one row per command. Menu:mergeTitleBarIntoLayout
    -- inserts the title bar's own buttons as extra rows at the top of it, so
    -- focusing row 1 lands on the search icon, not the first command -- and it
    -- skips that merge entirely on hasSymKey/hasScreenKB Kindles, so the offset
    -- is device-dependent and cannot be hardcoded. Only a MenuItem carries
    -- `entry`, which is what makes a row a command row.
    local function item_row_range()
        local first, last
        for i, row in ipairs(menu.layout or {}) do
            local widget = row and row[1]
            if widget and widget.entry then
                if not first then first = i end
                last = i
            end
        end
        return first, last
    end

    focus_first = function()
        local first = item_row_range()
        if first then return focus_row(first) end
        return false
    end

    -- Menu rebuilds self.layout per page, so it only ever holds the rows
    -- currently on screen -- stepping past either end has to turn the page and
    -- re-read the layout before it can focus anything.
    local function step_focus(dy)
        local first, last = item_row_range()
        if not first then return true end
        local y = (menu.selected and menu.selected.y) or first
        if y < first or y > last then y = first - dy end   -- focus was on the title bar
        local target = y + dy
        if target < first then
            if menu.page > 1 then
                menu:onPrevPage()
                local _, new_last = item_row_range()
                focus_row(new_last)
            else
                focus_row(first)
            end
        elseif target > last then
            if menu.page < (menu.page_num or 1) then
                menu:onNextPage()
                focus_first()
            else
                focus_row(last)
            end
        else
            focus_row(target)
        end
        return true
    end

    -- The palette handles keys itself rather than declaring key_events, for two
    -- reasons. Menu only registers ITS bindings behind `if Device:hasKeys()`
    -- (menu.lua) and FocusManager only populates its own behind
    -- `if Device:hasDPad()` (focusmanager.lua) -- both false on a touch-only
    -- Kindle, so on the very device this feature is for, none of the built-in
    -- navigation exists. And a query cannot be typed through key_events anyway:
    -- that would need one binding per printable character.
    --
    -- Unhandled keys fall through to the original handler so that Menu's own
    -- bindings still work on hardware that does have them.
    local original_key_press = menu.onKeyPress
    function menu:onKeyPress(key)
        local name = key and key.key
        if not name then return true end
        local mods = Keys.key_mods(key)

        if name == "Back" or name == "Esc" or name == "Escape" then
            UIManager:close(menu)
            return true
        end
        if name == "Press" or name == "Return" or name == "Enter" or name == "KP_Enter" then
            local focused = menu:getFocusItem()
            return select_row(focused and focused.entry)
        end
        if Keys.up_key(name) then return step_focus(-1) end
        if Keys.down_key(name) then return step_focus(1) end
        if Keys.page_up_key(name) then menu:onPrevPage(); focus_first(); return true end
        if Keys.page_down_key(name) then menu:onNextPage(); focus_first(); return true end
        if name == "Backspace" or name == "BackSpace" or name == "Del" or name == "Delete" then
            local current = pending_query or query
            if current ~= "" then
                -- Step back one UTF-8 character, not one byte: the command
                -- labels are ASCII today, but a half-deleted multibyte
                -- character would make the filter match nothing at all.
                queue_query(current:sub(1, Text.utf8_left(current, #current)))
            end
            return true
        end
        -- Ctrl-anything is a chord, not text: never let it reach the query.
        -- Ctrl-P in particular is what opened this palette.
        if Keys.shortcut_mod(mods) then
            if original_key_press then return original_key_press(menu, key) end
            return true
        end
        local ch
        if name == "Space" or name == "space" or name == " " then
            ch = " "
        elseif Keys.KEYPAD_CHAR[name] then
            ch = Keys.KEYPAD_CHAR[name]
        elseif #name == 1 then
            ch = name:lower()
            if Keys.keymod(mods, "Shift") then
                if Keys.SHIFT_SYM[ch] then ch = Keys.SHIFT_SYM[ch]
                elseif ch:match("%a") then ch = ch:upper() end
            end
        end
        if ch then
            queue_query((pending_query or query) .. ch)
            return true
        end
        if original_key_press then return original_key_press(menu, key) end
        return true
    end

    -- A top-level widget is painted at the origin UIManager was given, and Menu
    -- positions nothing itself -- so a Menu shown the usual way, `show(menu)`,
    -- lands in the top-left corner however small it is.
    --
    -- Wrapping it in a CenterContainer would centre it once and then break every
    -- repaint after that: setDirty only flags widgets that are IN the window
    -- stack, so the container would be the stacked widget while the menu's own
    -- setDirty calls -- one per filter pass, page turn and focus move -- named a
    -- widget that isn't there and never reached the screen. Passing the origin to
    -- show() keeps the Menu itself as the stacked widget, and InputContainer's
    -- paintTo writes that origin back into self.dimen: the same table every
    -- gesture range and dirty region in the menu is built from, so touch targets
    -- and refresh regions follow it for free.
    --
    -- Centred in the space it was allowed rather than in the screen: with a
    -- keyboard up, avail_height is what fits above it, and centring in the full
    -- screen would push the bottom of the list back under the keyboard that the
    -- max_height cap exists to clear.
    UIManager:show(menu, nil, nil,
        math.floor((Screen:getWidth() - menu.dimen.w) / 2),
        math.floor((avail_height - menu.dimen.h) / 2))
    focus_first()
    return menu
end

return M
