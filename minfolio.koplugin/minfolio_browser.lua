-- SPDX-License-Identifier: AGPL-3.0-only
-- The Minfolio notes browser (PLAN.md §5 Tier 5, §10 step 9): the on-device
-- file/folder listing over `Config.NOTES_DIR` (and anywhere else the "Open
-- .md file..." picker is pointed), its new-note/new-folder/rename/delete
-- dialogs, the long-press action sheet, and `edit_note` -- the entry point
-- that constructs `MDEdit` (minfolio_edit.lua) and hands it to the App
-- controller (minfolio_app.lua) as the one live editor. This was the last
-- subsystem still inline in main.lua; after this move main.lua holds only
-- the plugin entry (the `Minfolio` class, launch-flag polling, dispatcher
-- registration).
--
-- Registers itself into `App.hooks.open_note` / `.open_picker` /
-- `.file_manager` at load time (immediately after each hook's
-- implementation, below), so the editor, the remote-session controller
-- (`App.remoteEdit`/`.remoteStop`, minfolio_app.lua), and the plugin entry
-- (main.lua) all reach this module only through `App.*` -- never by
-- requiring it directly. That is the entire point of `minfolio_app.lua`'s
-- hook table (PLAN.md §5 Tier 3): it keeps the dependency edge one-way,
-- browser -> app and edit -> app, so that `minfolio_edit.lua` never requires
-- `minfolio_browser.lua`. `edit_note` constructs `MDEdit` (this module
-- requires `minfolio_edit`), and `MDEdit:saveAndOpenMarkdown` opens the
-- picker via `App.openPicker` (this module registers the picker hook) -- if
-- `minfolio_edit.lua` required this module too, that pair of edges would
-- recreate the exact browser<->editor cycle the controller exists to
-- remove.
--
-- `open_markdown_picker` and `show_file_manager` are still forward-declared
-- locals, same as in main.lua before this move (previously main.lua:49) --
-- not leftover ceremony, but a real, local ordering need:
-- `refresh_file_manager` (defined ahead of `show_file_manager` in source
-- order) calls it, and `open_markdown_picker` calls itself recursively
-- while being assigned rather than declared with `local function`. Both
-- names are used only within this module now; nothing outside it needs to
-- forward-declare them, which is what actually changed by moving them here
-- -- main.lua's own forward declaration is gone entirely, not relocated
-- ceremony re-added at a different address.
--
-- `attach_kbd_swipe` and `refresh_file_manager` are internal helpers, not
-- exported -- everything else in this module reaches them as plain upvalues,
-- same as before the move.
--
-- Requires KOReader throughout (widgets, gestures, `libs/libkoreader-lfs`),
-- so this cannot be `require`d and executed under plain luajit -- only
-- `loadfile`-parsed, exactly like main.lua itself -- so no off-device test
-- suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 5, §10
-- step 9): `clean_entry_name`, `ensure_dir`, `remove_tree`, `dir_entries`,
-- `refresh_file_manager`, `attach_kbd_swipe`, `show_new_entry_dialog`,
-- `show_rename_dialog`, `confirm_delete`, `show_item_actions`, `edit_note`,
-- `open_markdown_picker`, `show_file_manager`, and `open_notes` (exported as
-- `M.open_notes` -- main.lua's launch-flag handler, dispatcher action, and
-- main-menu entry all call it, so it is the one function this module
-- exports rather than keeping as a bare local).
--
-- Required by callers as `local Browser = require("minfolio_browser")`.

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local Text = require("minfolio_text")
local Config = require("minfolio_config")
local IO = require("minfolio_io")
local Chrome = require("minfolio_chrome")
local Frontlight = require("minfolio_frontlight")
local App = require("minfolio_app")
local MDEdit = require("minfolio_edit")

local M = {}

local open_markdown_picker, show_file_manager   -- fwd decls; see header comment

-- Only ever one editor at a time. Opening a note while another editor is live
-- (e.g. a re-send via kindle-send, or a duplicate launch-flag write) must not
-- stack a second MDEdit on the same file: both keep polling the file and each
-- one's autosave looks like an external change to the other, producing a
-- "Reloaded from disk" storm and a half-repainted screen. edit_note() enforces
-- the singleton (via App.setActive/.activeEditor, PLAN.md §5 Tier 3); MDEdit
-- clears it on close (via App.clearActive).
local function edit_note(path, remote)
    Chrome.trace("edit-request", "path=", tostring(path), "remote=", remote and "yes" or "no")
    Frontlight.fl_restore_if_needed()
    local active = App.activeEditor()
    if active and not active._closing then
        -- Already editing this exact file: keep the live editor (with its cursor
        -- and unsaved edits) instead of stacking a duplicate that would fight it.
        if active.path == path then return end
        -- Switching files: flush and close the current editor first so only one
        -- editor (and one file poller) is ever live. Suppress its on_close so we
        -- don't bounce through the listing on the way to the next note.
        active.on_close = nil
        active:saveAndClose()
    end
    -- Closing the document always returns to the Minfolio file listing at the
    -- note's folder -- even when the note was opened by a send from the computer
    -- (launch flag), which otherwise would drop back to KOReader.
    local ed = MDEdit:new{ path = path, remote = remote, on_close = function()
        App.openFileManager(Config.path_parent(path))
    end }
    App.setActive(ed)
    UIManager:show(ed, "full")   -- "full" forces a complete repaint over the menu
    Chrome.trace("editor-shown", "path=", tostring(path))
    -- Closing the file browser and showing the editor each queue their own dirty
    -- updates.  Reassert the editor after that transition has drained so a
    -- browser-region update cannot win and leave a partially blank launch view.
    UIManager:scheduleIn(0.12, function()
        if App.activeEditor() == ed and not ed._closing then
            UIManager:setDirty(ed, "full")
        end
    end)
end
-- Registers this module's entry point into the App controller at load time
-- (PLAN.md §5 Tier 3), so every other subsystem -- the remote-session
-- controller (`App.remoteEdit`, minfolio_app.lua) and the plugin entry
-- (main.lua's `Minfolio:openLaunchTarget` `edit:` handler) -- reaches it via
-- App.openNote(...) instead of requiring this module directly.
App.hooks.open_note = edit_note

local function clean_entry_name(name, add_md_ext)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or name == "." or name == ".." or name:find("/", 1, true) or name:find("%z") then
        return nil
    end
    if add_md_ext and not name:match("%.%w+$") then name = name .. ".md" end
    return name
end

local function ensure_dir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    return lfs.mkdir(path)
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "file" then return os.remove(path) end
    if mode ~= "directory" then return false end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            if not remove_tree(Text.path_join(path, name)) then return false end
        end
    end
    return lfs.rmdir(path)
end

local function dir_entries(dir)
    local dirs, files = {}, {}
    local ok = pcall(function()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." and not name:match("^%.") then
                local path = Text.path_join(dir, name)
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    dirs[#dirs+1] = name
                elseif mode == "file" then
                    files[#files+1] = name
                end
            end
        end
    end)
    table.sort(dirs)
    table.sort(files)
    return dirs, files, ok
end

open_markdown_picker = function(start_dir)
    local dir = start_dir or Config.NOTES_DIR
    if lfs.attributes(dir, "mode") ~= "directory" then dir = Config.NOTES_DIR end
    if lfs.attributes(dir, "mode") ~= "directory" then dir = "/mnt/us" end

    local dirs, all_files, ok = dir_entries(dir)
    local files = {}
    for _, name in ipairs(all_files) do
        if Text.is_markdown_file(name) then files[#files+1] = name end
    end

    local items = {}
    if dir ~= "/" then items[#items+1] = { text = "../", kind = "dir", path = Config.path_parent(dir) } end
    if dir ~= Config.NOTES_DIR and lfs.attributes(Config.NOTES_DIR, "mode") == "directory" then
        items[#items+1] = { text = _("Minfolio folder"), kind = "dir", path = Config.NOTES_DIR }
    end
    for _, name in ipairs(dirs) do
        items[#items+1] = { text = name .. "/", kind = "dir", path = Text.path_join(dir, name) }
    end
    for _, name in ipairs(files) do
        items[#items+1] = { text = name, kind = "file", path = Text.path_join(dir, name) }
    end
    if #items == 0 or not ok then
        items[#items+1] = { text = ok and _("No Markdown files here") or _("Cannot read this folder"), kind = "noop" }
    end

    local menu
    menu = Menu:new{
        title = _("Open .md") .. " - " .. (Text.path_base(dir) ~= "" and dir or "/"),
        item_table = items,
        is_popout = false,
        -- One of Minfolio's own screens; minfolio_chrome looks for this field on
        -- UIManager's window stack before giving the rotation back to KOReader.
        minfolio_screen = true,
        onMenuSelect = function(_self, item)
            if item.kind == "dir" then
                UIManager:close(menu)
                open_markdown_picker(item.path)
            elseif item.kind == "file" then
                UIManager:close(menu)
                edit_note(item.path)
            end
        end,
    }
    UIManager:show(menu)
end
-- Registers this module's picker entry point into the App controller at load
-- time (PLAN.md §5 Tier 3), so `MDEdit:saveAndOpenMarkdown` (minfolio_edit.lua)
-- reaches it via App.openPicker(...) instead of requiring this module.
App.hooks.open_picker = open_markdown_picker

local function refresh_file_manager(menu, dir)
    -- Folder navigation replaces the current Menu's item table. Keeping one
    -- window avoids a growing KOReader widget stack and preserves the current
    -- browser instead of looking like every folder opened a new screen.
    if menu and menu.minfolioNavigate then return menu:minfolioNavigate(dir) end
    show_file_manager(dir)
end

-- Let a name-entry dialog toggle its on-screen keyboard by swiping: up shows it,
-- down hides it. Handy when a Bluetooth keyboard is attached and the on-screen
-- one is just wasting space (swipe down), or you want it back (swipe up).
local function attach_kbd_swipe(dlg)
    dlg.ges_events = dlg.ges_events or {}
    dlg.ges_events.MinfolioKbdSwipe = {
        GestureRange:new{ ges = "swipe",
            range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } },
    }
    function dlg:onMinfolioKbdSwipe(_, ges)
        local d = ges and ges.direction
        if d == "north" then self:onShowKeyboard()
        elseif d == "south" then self:onCloseKeyboard() end
        return true
    end
end
local function show_new_entry_dialog(menu, dir, kind)
    local is_folder = kind == "folder"
    local dlg
    dlg = InputDialog:new{
        title = is_folder and _("New folder") or _("New note"),
        input = "",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Create"), is_enter_default = true, callback = function()
                local name = clean_entry_name(dlg:getInputText(), not is_folder)
                UIManager:close(dlg)
                if not name then Chrome.notify(_("Invalid name")); return end
                local path = Text.path_join(dir, name)
                if lfs.attributes(path, "mode") then Chrome.notify(_("Name already exists")); return end
                if is_folder then
                    if ensure_dir(path) then
                        refresh_file_manager(menu, dir)
                    else
                        Chrome.notify(_("Could not create folder"))
                    end
                else
                    if IO.write_file(path, "") then
                        if menu then UIManager:close(menu) end
                        edit_note(path)
                    else
                        Chrome.notify(_("Could not create note"))
                    end
                end
            end },
        }},
    }
    attach_kbd_swipe(dlg)
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function show_rename_dialog(parent_menu, dir, item)
    local dlg
    dlg = InputDialog:new{
        title = _("Rename"),
        input = item.name,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Rename"), is_enter_default = true, callback = function()
                local name = clean_entry_name(dlg:getInputText(), item.kind == "file" and Text.is_markdown_file(item.name))
                UIManager:close(dlg)
                if not name then Chrome.notify(_("Invalid name")); return end
                if name == item.name then return end
                local dest = Text.path_join(dir, name)
                if lfs.attributes(dest, "mode") then Chrome.notify(_("Name already exists")); return end
                if os.rename(item.path, dest) then
                    refresh_file_manager(parent_menu, dir)
                else
                    Chrome.notify(_("Could not rename"))
                end
            end },
        }},
    }
    attach_kbd_swipe(dlg)
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function confirm_delete(parent_menu, dir, item)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Delete %s?"), item.name),
        ok_text = _("Delete"),
        ok_callback = function()
            if remove_tree(item.path) then
                refresh_file_manager(parent_menu, dir)
            else
                Chrome.notify(_("Could not delete"))
            end
        end,
    })
end

local function show_item_actions(parent_menu, dir, item)
    -- A ButtonDialog is the right widget for a long-press context menu: it sizes
    -- itself to its buttons (big tap targets, no empty filler), unlike a fixed-
    -- height Menu which renders a few tiny rows in a mostly-blank box.
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function act(cb)
        return function() UIManager:close(dialog); UIManager:scheduleIn(0.01, cb) end
    end
    local buttons = {}
    if item.kind == "dir" then
        buttons[#buttons+1] = {{ text = _("Open folder"),
            callback = act(function() refresh_file_manager(parent_menu, item.path) end) }}
    elseif Text.is_markdown_file(item.name) then
        buttons[#buttons+1] = {{ text = _("Open"), callback = act(function()
            if parent_menu then UIManager:close(parent_menu) end
            edit_note(item.path)
        end) }}
    end
    buttons[#buttons+1] = {{ text = _("Rename"),
        callback = act(function() show_rename_dialog(parent_menu, dir, item) end) }}
    buttons[#buttons+1] = {{ text = _("Delete"),
        callback = act(function() confirm_delete(parent_menu, dir, item) end) }}
    dialog = ButtonDialog:new{
        title = item.name,
        title_align = "center",
        width_factor = 0.72,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

show_file_manager = function(start_dir)
    Frontlight.fl_restore_if_needed()
    ensure_dir(Config.NOTES_DIR)
    local dir = start_dir or Config.NOTES_DIR
    if lfs.attributes(dir, "mode") ~= "directory" then dir = Config.NOTES_DIR end

    local dirs, files, ok = dir_entries(dir)
    local menu
    local items = {
        { text = "＋ " .. _("New note"), kind = "new_note" },
        { text = "＋ " .. _("New folder"), kind = "new_folder" },
        { text = _("Open .md file..."), is_open = true },
    }
    if dir ~= Config.NOTES_DIR then items[#items+1] = { text = "../", kind = "dir_nav", path = Config.path_parent(dir) } end
    for _, name in ipairs(dirs) do
        local item = { text = name .. "/", kind = "dir", name = name, path = Text.path_join(dir, name) }
        item.hold_callback = function() show_item_actions(menu, dir, item) end
        items[#items+1] = item
    end
    for _, name in ipairs(files) do
        local item = { text = name, kind = "file", name = name, path = Text.path_join(dir, name) }
        item.hold_callback = function() show_item_actions(menu, dir, item) end
        items[#items+1] = item
    end
    if not ok then items[#items+1] = { text = _("Cannot read this folder"), kind = "noop" } end
    logger.info("minfolio open_notes: showing", #items, "items")
    -- Custom title bar so we can show a Kindle-style battery indicator to the left
    -- of the close (X) icon. TitleBar only exposes a single right icon (the close
    -- button), so the battery is added as an extra right-aligned overlap child.
    local title_text = _("Minfolio") .. " - " .. (dir == Config.NOTES_DIR and Text.path_base(Config.NOTES_DIR) or dir)
    local batt_info = Chrome.battery_info()
    -- TitleBar knows about its close icon but not the extra battery widget we
    -- overlay on the right. Reserve that whole region in its title layout so a
    -- long folder path is ellipsized before it can paint underneath the percent.
    local battery_title_reserve = batt_info and (Chrome.MinfolioBattery.indicatorWidth() + Screen:scaleBySize(44)) or 0
    local title_bar = TitleBar:new{
        width = Screen:getWidth(),
        align = "center",
        title = title_text,
        title_h_padding = Size.padding.large + battery_title_reserve,
        with_bottom_line = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            Chrome.show_controls({ { text = "⟲ " .. _("Rotate screen"), callback = Chrome.rotate_screen_ccw } })
        end,
        close_callback = function() if menu then menu:onClose() end end,
    }
    local batt = Chrome.battery_indicator(batt_info)
    local batt_cell
    if batt then
        -- Vertically centered in the title bar, then nudged up ~8px: shrinking the
        -- centering box's height by 16 raises the centered battery by half that.
        batt_cell = CenterContainer:new{
            dimen = Geom:new{ w = Chrome.MinfolioBattery.indicatorWidth(), h = math.max(1, title_bar:getHeight() - 16) }, batt }
        table.insert(title_bar, HorizontalGroup:new{
            align = "center", overlap_align = "right",
            batt_cell, HorizontalSpan:new{ width = Screen:scaleBySize(44) },
        })
    end
    menu = Menu:new{
        title = title_text,
        item_table = items,
        is_popout = false,
        handle_hold_on_hold_release = true,
        custom_title_bar = title_bar,
        -- See the picker's Menu above: marks this as a Minfolio screen for
        -- minfolio_chrome's rotation hand-back.
        minfolio_screen = true,
        onMenuSelect = function(_self, item)
            local current_dir = _self._minfolio_dir or dir
            -- The editor is fullscreen and returns here via its on_close, so close
            -- this listing rather than leaving it stacked underneath.
            if item.kind == "new_note" then show_new_entry_dialog(menu, current_dir, "note")
            elseif item.kind == "new_folder" then show_new_entry_dialog(menu, current_dir, "folder")
            elseif item.is_open then open_markdown_picker(current_dir)
            elseif item.kind == "dir_nav" then refresh_file_manager(menu, item.path)
            elseif item.kind == "dir" then refresh_file_manager(menu, item.path)
            elseif item.kind == "file" then
                if Text.is_markdown_file(item.name) then UIManager:close(menu); edit_note(item.path) else show_item_actions(menu, dir, item) end
            end
        end,
        onMenuHold = function(_self, item)
            logger.info("minfolio file manager hold:", item and item.name, item and item.kind)
            if item and item.hold_callback then
                item.hold_callback()
            elseif item and (item.kind == "dir" or item.kind == "file") then
                show_item_actions(menu, _self._minfolio_dir or dir, item)
            end
            return true
        end,
    }
    menu._minfolio_dir = dir
    function menu:minfolioNavigate(next_dir)
        if lfs.attributes(next_dir, "mode") ~= "directory" then return end
        local next_dirs, next_files, readable = dir_entries(next_dir)
        local next_items = {
            { text = "＋ " .. _("New note"), kind = "new_note" },
            { text = "＋ " .. _("New folder"), kind = "new_folder" },
            { text = _("Open .md file..."), is_open = true },
        }
        if next_dir ~= Config.NOTES_DIR then next_items[#next_items+1] = { text = "../", kind = "dir_nav", path = Config.path_parent(next_dir) } end
        for _, name in ipairs(next_dirs) do
            local item = { text = name .. "/", kind = "dir", name = name, path = Text.path_join(next_dir, name) }
            item.hold_callback = function() show_item_actions(self, next_dir, item) end
            next_items[#next_items+1] = item
        end
        for _, name in ipairs(next_files) do
            local item = { text = name, kind = "file", name = name, path = Text.path_join(next_dir, name) }
            item.hold_callback = function() show_item_actions(self, next_dir, item) end
            next_items[#next_items+1] = item
        end
        if not readable then next_items[#next_items+1] = { text = _("Cannot read this folder"), kind = "noop" } end
        self._minfolio_dir = next_dir
        local next_title = _("Minfolio") .. " - " .. (next_dir == Config.NOTES_DIR and Text.path_base(Config.NOTES_DIR) or next_dir)
        self:switchItemTable(next_title, next_items)
        logger.info("minfolio file manager navigated:", next_dir)
    end
    if batt_cell then
        menu._battery_key = Chrome.MinfolioBattery.infoKey(batt_info)
        local function schedule_battery_refresh()
            local fn
            fn = function()
                if menu._battery_refresh_pending == fn then menu._battery_refresh_pending = nil end
                if menu._battery_closed then return end
                local info = Chrome.battery_info()
                local key = Chrome.MinfolioBattery.infoKey(info)
                if info and key ~= menu._battery_key then
                    if batt_cell[1] and batt_cell[1].free then batt_cell[1]:free() end
                    batt_cell[1] = Chrome.battery_indicator(info)
                    menu._battery_key = key
                    UIManager:setDirty(menu, "ui")
                end
                schedule_battery_refresh()
            end
            menu._battery_refresh_pending = fn
            UIManager:scheduleIn(Chrome.MinfolioBattery.refresh_interval, fn)
        end
        local original_close = menu.onCloseWidget
        function menu:onCloseWidget()
            self._battery_closed = true
            if self._battery_refresh_pending then
                UIManager:unschedule(self._battery_refresh_pending)
                self._battery_refresh_pending = nil
            end
            if original_close then original_close(self) end
        end
        schedule_battery_refresh()
    end
    title_bar.show_parent = menu
    if title_bar.left_button then title_bar.left_button.show_parent = menu end
    if title_bar.right_button then title_bar.right_button.show_parent = menu end
    -- KOReader's Menu closes on a south swipe, so swiping in the blank space
    -- dismisses the whole browser unexpectedly. Keep only left/right for paging
    -- and ignore vertical/diagonal swipes -- the X in the title bar is the way to
    -- close.
    function menu:onSwipe(_, ges)
        local d = ges and ges.direction
        if d == "west" then self:onNextPage()
        elseif d == "east" then self:onPrevPage() end
        return true
    end
    UIManager:show(menu)
end
-- Registers this module's file-manager entry point into the App controller at
-- load time (PLAN.md §5 Tier 3), so `edit_note`'s on_close (above) reaches it
-- via App.openFileManager(...) instead of a nil-tolerant guard on a
-- forward-declared local.
App.hooks.file_manager = show_file_manager

local function open_notes()
    show_file_manager(Config.NOTES_DIR)
end

M.open_notes = open_notes

return M
