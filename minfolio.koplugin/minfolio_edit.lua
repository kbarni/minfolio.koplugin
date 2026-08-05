-- SPDX-License-Identifier: AGPL-3.0-only
-- MDEdit: the native, on-device Markdown editor widget for minfolio.koplugin
-- (PLAN.md §5 Tier 4, §10 step 8). This is the editor class itself: fields,
-- init, lifecycle, text ops, undo/redo, selection, clipboard, find/outline,
-- input handling, gestures, savePosition/restorePosition, and the mixin
-- assembly below. Layout/wrapping, the table subsystem, and the
-- rebuild/refresh/top-bar view logic live in three sibling mixin modules
-- (minfolio_edit_layout, minfolio_edit_tables, minfolio_edit_view) and are
-- folded into this class's own method table at load time -- see the
-- assembly loop at the end of this file, and PLAN.md §6.1/§6.2 for why the
-- split is done this way (verbatim `function MDEdit:` bodies plus a
-- rawget-guarded assignment loop, not a metatable/inheritance chain).
--
-- md_clipboard is a file-local here, deliberately shared across editor
-- instances (opening a second note after copying text in the first must
-- still be able to paste it) -- all its uses (copy/cut/paste) are in this
-- file's text-ops group, per PLAN.md §4/§6.4.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 4, §10
-- step 8): the MDEdit class and all of its methods not assigned to one of
-- the three mixin modules above (see ARCHITECTURE.md for how to locate any
-- given method across the four files).
--
-- Required by callers as `local MDEdit = require("minfolio_edit")`.

local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local MD = require("minfolio_md")
local Text = require("minfolio_text")
local Find = require("minfolio_find")
local Stats = require("minfolio_stats")
local Config = require("minfolio_config")
local IO = require("minfolio_io")
local State = require("minfolio_state")
local C = require("minfolio_const")
local Keys = require("minfolio_keys")
local Frontlight = require("minfolio_frontlight")
local FL = Frontlight.FL
local Chrome = require("minfolio_chrome")
local App = require("minfolio_app")
local MindmapView = require("minfolio_map_view")
-- free_wrap_entry lives in minfolio_edit_layout's `fns` channel rather than
-- its `methods` table, because it is a plain helper and not an MDEdit method.
-- Bind the function itself, not the module: it is called bare from three sites
-- below (onScreenResize, onCloseWidget, bumpScale), and binding it keeps those
-- call sites byte-identical to the pre-split code. Reaching it as
-- `Layout.freeWrapEntry` is the mistake to avoid -- that path is nil, since the
-- function sits under `fns`, and it throws only when one of those three paths
-- actually runs. minfolio_edit_tables/minfolio_edit_view expose no plain fns,
-- so the assembly loop below requires them inline.
local free_wrap_entry = require("minfolio_edit_layout").fns.freeWrapEntry
-- Assert at load rather than discovering it at close time. Binding a wrong
-- path yields nil silently, which is exactly how the original defect here
-- survived a deploy; a load-time failure is at least caught by deploy.sh's
-- plugin-init check instead of waiting for a user to close a note.
assert(free_wrap_entry, "minfolio_edit_layout.fns.freeWrapEntry missing")

local md_clipboard = ""               -- shared across notes
-- `minfolio_screen` marks this as one of Minfolio's own full-screen views:
-- minfolio_chrome scans UIManager's window stack for that field to tell whether
-- the app still has a screen up, and hands the device's rotation back to
-- KOReader once none is left.
local MDEdit = InputContainer:extend{ path = nil, remote = nil, on_close = nil, is_always_active = true,
    minfolio_screen = true }
function MDEdit:init()
    Keys.install_keyboard_aliases()
    self.fw, self.fh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh }
    self.covers_fullscreen = true
    self.scale = State.clamp_minfolio_scale(State.MINFOLIO_STATE.scale)
    self.parent = self            -- VirtualKeyboard reads inputbox.parent
    self.keyboard = nil
    self._wcache = {}             -- measured word widths (style|scale|text -> px)
    self._hcache = {}             -- measured text heights (style|scale -> px)
    self.sel = nil                -- selection anchor {row,col} (cursor is the other end)
    self.caret_on = true
    self._caret_blinking = true
    self.reader_mode = false
    local text = IO.read_file(self.path) or ""
    self.lines = Text.split_text_lines(text)
    -- Writing-session baseline for the word count. Only the text itself is kept
    -- here (a second reference to a string that already exists -- no copy, no
    -- parse); counting it costs a full md_tokenize pass, which is not something
    -- to spend on every note that gets opened. sessionWords does it once, the
    -- first time the user actually asks for a count, and caches the number.
    self._session_text = text
    self._session_start = IO.now_seconds()
    -- The editor never owns a socket. A separate process does TLS and leaves
    -- only local, atomically-written files for this widget to consume.
    self.remote_revision = self.remote and tonumber(self.remote.revision) or 0
    self._file_signature = IO.file_signature(self.path)
    self._file_text = text
    self.crow, self.ccol, self.top, self.vtop = 1, 0, 1, 1
    self:restorePosition()
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap       = { GestureRange:new{ ges = "tap",        range = self.dimen } },
            DoubleTap = { GestureRange:new{ ges = "double_tap", range = self.dimen } },
            Pan       = { GestureRange:new{ ges = "pan",        range = self.dimen } },
            PanRelease= { GestureRange:new{ ges = "pan_release", range = self.dimen } },
            Swipe     = { GestureRange:new{ ges = "swipe",      range = self.dimen } },
            Hold      = { GestureRange:new{ ges = "hold",       range = self.dimen } },
        }
        if Device.input then
            -- Disable KOReader's own double-tap so taps arrive immediately; we
            -- detect double-taps ourselves (edit: word-select, reader: exit) via
            -- timestamps, which is reliable and gives us the tap position.
            self._old_disable_double_tap = Device.input.disable_double_tap
            Device.input.disable_double_tap = true
        end
    end
    self:rebuild()
    -- A first full draw is still settling when this widget is opened from the
    -- file browser.  Do not let the caret's tiny partial redraw race it: on an
    -- e-ink screen that can preserve a blank patch from the browser instead of
    -- the newly-built editor beneath it.
    self:scheduleCaretBlink(C.EDIT.MDEDIT_CARET_RESUME_DELAY)
    self:scheduleFilePoll()
    Chrome.trace("editor-open", "path=", tostring(self.path), "lines=", #self.lines,
        "remote=", self.remote and "yes" or "no")
    self:scheduleHeartbeat(C.EDIT.MDEDIT_HEARTBEAT_FIRST)
end
-- Store a logical visual-row anchor, not a raw visual row number. This lets a
-- note reopen at the same passage after a rotation or a font-size change has
-- changed how many screen rows the preceding text occupies.
function MDEdit:restorePosition()
    if self.remote then return end -- remote documents are short-lived session shadows
    local position = State.MINFOLIO_STATE.positions[self.path]
    if type(position) ~= "table" then return end

    self.crow = math.max(1, math.min(#self.lines, math.floor(tonumber(position.crow) or 1)))
    self.ccol = math.max(0, math.min(#(self.lines[self.crow] or ""), math.floor(tonumber(position.ccol) or 0)))
    self.reader_mode = not not position.reader_mode

    local target_line = math.max(1, math.floor(tonumber(position.line) or self.crow))
    local target_ri = math.max(1, math.floor(tonumber(position.ri) or 1))
    local target_kind = type(position.kind) == "string" and position.kind or nil
    local rows = self:visualRows(self:textWidth())
    for vi, row in ipairs(rows) do
        if row.line == target_line and (not target_kind or row.kind == target_kind)
            and (row.ri or 1) >= target_ri then
            self.vtop = vi
            break
        end
    end
    -- In edit mode, rebuilding normally scrolls to the caret. Mark this as a
    -- deliberate restored scroll position so the saved passage takes priority.
    if not self.reader_mode then
        self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    end
end
function MDEdit:savePosition()
    if self.remote then return end
    local rows = self:visualRows(self:textWidth())
    local top = rows[math.max(1, math.min(#rows, self.vtop or 1))] or {}
    State.MINFOLIO_STATE.positions[self.path] = {
        line = top.line or self.crow or 1,
        ri = top.ri or 1,
        kind = top.kind or "row",
        crow = self.crow or 1,
        ccol = self.ccol or 0,
        reader_mode = self.reader_mode,
    }
    State.save_minfolio_state()
end
function MDEdit:pointToCursor(pos)
    if not pos then return self.crow, self.ccol end
    local nearest, nearest_dist
    for _, rm in ipairs(self.row_map or {}) do
        if pos.y >= rm.y0 and pos.y < rm.y1 then
            local raw_col
            if rm.table then raw_col = self:tableColAtX(rm, pos.x - C.EDIT.MDEDIT_PAD)
            else raw_col = self:colAtX(rm.row, pos.x - C.EDIT.MDEDIT_PAD) end
            local col = Text.utf8_snap(self.lines[rm.line], raw_col)
            return rm.line, col
        end
        local dist = pos.y < rm.y0 and (rm.y0 - pos.y) or (pos.y - rm.y1)
        if not nearest_dist or dist < nearest_dist then
            nearest, nearest_dist = rm, dist
        end
    end
    if nearest then
        local raw_col
        if nearest.table then raw_col = self:tableColAtX(nearest, pos.x - C.EDIT.MDEDIT_PAD)
        else raw_col = self:colAtX(nearest.row, pos.x - C.EDIT.MDEDIT_PAD) end
        return nearest.line, Text.utf8_snap(self.lines[nearest.line], raw_col)
    end
    if pos.y < (self.row_map and self.row_map[1] and self.row_map[1].y0 or self.fh) then
        return self.row_map and self.row_map[1] and self.row_map[1].line or self.top, 0
    end
    local last = self.row_map and self.row_map[#self.row_map]
    if last then return last.line, #self.lines[last.line] end
    return self.crow, self.ccol
end
-- Which line's checkbox did this tap land on, if any?
--
-- A checkbox is not text on screen: md_tokenize gives the source "[ ] " a span
-- with style "task" and a `display` of "\226\152\144 " (an unticked box glyph),
-- and layoutLine turns that into one seg whose width is the GLYPH's. So the tap
-- cannot be resolved by column -- colAtX deliberately collapses a display seg to
-- its two edges, which would make a tap on the box indistinguishable from one
-- just before the text. Walking the segs the way colAtX does, and asking which
-- seg the x fell inside, is the only way to tell the two apart. Same shape as
-- tableCellAtPos, for the same reason: rendered content, not raw text.
--
-- The hit zone runs from the row's left edge to the right edge of the glyph,
-- not the glyph alone. A box is around 20px wide, well under a fingertip;
-- everything to its left is the line's indent and the list marker, which
-- md_tokenize renders as zero-width on a task line, so widening leftwards
-- costs no other tap target. It stops dead at the glyph's right edge, so a tap
-- on the text still places the caret.
--
-- Nothing here needs to exclude fenced code: inside a fence md_code_token
-- styles the whole line "code", so a literal "- [ ] x" in a code block never
-- produces a "task" seg and can never be hit.
function MDEdit:taskBoxAtPos(pos)
    if not pos then return nil end
    for _, rm in ipairs(self.row_map or {}) do
        if pos.y >= rm.y0 and pos.y < rm.y1 then
            if rm.table then return nil end
            local x = pos.x - C.EDIT.MDEDIT_PAD
            if x < 0 then return nil end
            local accx = (rm.row and rm.row.indent) or 0
            for _, seg in ipairs((rm.row and rm.row.segs) or {}) do
                accx = accx + (seg.w or 0)
                -- A wrapped line's continuation rows carry no task seg, so only
                -- the row the box is actually drawn on can match.
                if seg.style == "task" then return x < accx and rm.line or nil end
            end
            return nil
        end
    end
    return nil
end
-- Tick/untick the checkbox on `row`. Returns false when that line has none, so
-- the caller can fall through to whatever a tap normally does there.
function MDEdit:toggleTaskAt(row)
    local line = self.lines[row]
    if not line then return false end
    local toggled = MD.md_toggle_task(line)
    if not toggled then return false end
    self:flushTypeBuffer()
    -- One line changes, and only three bytes of it: snapshotLine is the cheap
    -- undo entry for exactly this shape, and it schedules the autosave too.
    self:snapshotLine(row)
    self._burst = nil
    self.lines[row] = toggled
    -- The caret deliberately stays where it was. Ticking a box in a checklist
    -- while writing a paragraph somewhere else must not move the insertion
    -- point out from under the next keystroke.
    self:refresh{ lines = { row, row } }
    return true
end
function MDEdit:visibleWordRange(row, col)
    local line = self.lines[row] or ""
    local toks = MD.md_tokenize(line)[1]
    local byte, target, prev_visible = 0, nil, nil
    for _, span in ipairs(toks.spans or {}) do
        local raw = span.text or ""
        local display = span.display
        if display == nil then display = raw end
        local start_col, end_col = byte, byte + #raw
        if display ~= "" and span.style ~= "syntax" and span.style ~= "bullet" and span.style ~= "task" then
            local candidate = { start_col, end_col, raw }
            if col >= start_col and col <= end_col then
                target = candidate
                break
            elseif col < start_col then
                target = candidate
                break
            end
            prev_visible = candidate
        end
        byte = end_col
    end
    target = target or prev_visible
    if not target then return nil end
    local start_col, end_col, raw = target[1], target[2], target[3]
    local local_col = math.max(0, math.min(#raw, col - start_col))
    local lo, hi = Text.prev_word_col(raw, local_col), Text.next_word_col(raw, local_col)
    if lo == hi and #raw > 0 then
        if local_col <= 0 then hi = Text.next_word_col(raw, 0)
        else lo = Text.prev_word_col(raw, Text.utf8_left(raw, local_col)) end
    end
    if lo == hi then return start_col, end_col end
    return start_col + lo, start_col + hi
end
function MDEdit:selectWordAt(pos)
    local row, col = self:pointToCursor(pos)
    local line = self.lines[row] or ""
    local lo, hi = self:visibleWordRange(row, col)
    if not lo then lo, hi = Text.prev_word_col(line, col), Text.next_word_col(line, col) end
    if lo == hi and #line > 0 then hi = Text.utf8_right(line, lo) end
    self._desired_x = nil
    self.sel = { row = row, col = lo }
    self.crow, self.ccol = row, hi
    self:refresh{ layout_dirty = false, selection = true }
end
function MDEdit:currentWordRange()
    local line = self.lines[self.crow] or ""
    if line == "" then return nil end
    local lo, hi = Text.prev_word_col(line, self.ccol), Text.next_word_col(line, self.ccol)
    if lo == hi and self.ccol > 0 then lo = Text.prev_word_col(line, Text.utf8_left(line, self.ccol)) end
    if lo == hi and self.ccol < #line then hi = Text.next_word_col(line, Text.utf8_right(line, self.ccol)) end
    if lo ~= hi then return lo, hi end
    return nil
end
function MDEdit:checkRemoteInbox()
    if not self.remote then return end
    local revision = tonumber(IO.read_file(self.remote.revision_path) or "")
    if not revision or revision <= (self.remote_revision or 0) then return end
    -- Preserve local Kindle changes until the worker has handed them off.
    if self._dirty or lfs.attributes(self.remote.outbox_path, "mode") then return end
    local text = IO.read_file(self.remote.inbox_path)
    if text == nil then return end
    self.remote_revision = revision
    if text == self:currentText() then return end
    IO.write_file(self.path, text)
    self.lines = Text.split_text_lines(text)
    self.crow = math.max(1, math.min(self.crow or 1, #self.lines))
    self.ccol = math.max(0, math.min(self.ccol or 0, #(self.lines[self.crow] or "")))
    self.sel, self._desired_x, self._burst = nil, nil, nil
    self._undo, self._redo = {}, {}
    self._file_text, self._file_signature = text, IO.file_signature(self.path)
    self:refresh{ layout_dirty = true, full = true }
end
function MDEdit:scheduleAutosave()
    self._dirty = true
    if self._autosave_paused_for_external then return end
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    local fn
    fn = function()
        if self._autosave_pending == fn then self._autosave_pending = nil end
        if self._dirty and not self._autosave_paused_for_external then self:save() end
    end
    self._autosave_pending = fn
    UIManager:scheduleIn(C.EDIT.MDEDIT_AUTOSAVE_DELAY, fn)
end
function MDEdit:flushAutosave()
    self:flushTypeBuffer()
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    if self._autosave_paused_for_external then return end
    if self._dirty then self:save() end
end
function MDEdit:currentText()
    self:flushTypeBuffer()
    return table.concat(self.lines, "\n")
end
function MDEdit:reloadFromDisk(text, sig)
    if text == nil then text = IO.read_file(self.path) end
    if text == nil then return false end
    self.lines = Text.split_text_lines(text)
    self.crow = math.max(1, math.min(self.crow or 1, #self.lines))
    self.ccol = math.max(0, math.min(self.ccol or 0, #(self.lines[self.crow] or "")))
    self.sel = nil
    self._desired_x = nil
    self._burst = nil
    self._undo, self._redo = {}, {}
    self._dirty = false
    self._file_text = text
    self._file_signature = sig or IO.file_signature(self.path)
    self._external_change_prompted = nil
    self._autosave_paused_for_external = nil
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    self:refresh{ layout_dirty = true, full = true }
    Chrome.notify(_("Reloaded from disk"))
    return true
end
function MDEdit:promptExternalReload(text, sig)
    if self._external_change_prompted then return end
    self._external_change_prompted = true
    self._autosave_paused_for_external = true
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    UIManager:show(ConfirmBox:new{
        text = _("File changed on disk. Reload and discard unsaved edits?\nAutosave is paused until you reload or save."),
        ok_text = _("Reload"),
        ok_callback = function() self:reloadFromDisk(text, sig) end,
    })
end
function MDEdit:checkExternalFile()
    local sig = IO.file_signature(self.path)
    if IO.same_file_signature(sig, self._file_signature) then return end
    local text = IO.read_file(self.path)
    if text == nil then
        if not self._external_missing_notified then
            self._external_missing_notified = true
            Chrome.notify(_("File is unavailable on disk"))
        end
        return
    end
    self._external_missing_notified = nil
    if text == self:currentText() then
        self._file_text = text
        self._file_signature = sig
        self._dirty = false
        self._autosave_paused_for_external = nil
        return
    end
    if self._dirty then
        self:promptExternalReload(text, sig)
    else
        self:reloadFromDisk(text, sig)
    end
end
function MDEdit:scheduleFilePoll()
    if self._file_poll_pending then UIManager:unschedule(self._file_poll_pending); self._file_poll_pending = nil end
    local fn
    fn = function()
        if self._file_poll_pending == fn then self._file_poll_pending = nil end
        if self._closing then return end
        self:checkExternalFile()
        self:checkRemoteInbox()
        self:scheduleFilePoll()
    end
    self._file_poll_pending = fn
    UIManager:scheduleIn(C.EDIT.MDEDIT_FILE_RELOAD_INTERVAL, fn)
end
-- A heartbeat is intentionally infrequent.  If the UI loop is delayed, the
-- next entry records the gap; if KOReader dies, the last marker identifies the
-- last known healthy editor state without materially affecting battery life.
--
-- `gap` is wall clock (IO.now_seconds is socket.gettime), and a scheduled task
-- does not run while the device is suspended, so an overnight sleep produces
-- the same enormous gap a stalled UI loop would -- which made the number
-- useless as the stall signal it exists to be.  onSuspend sets
-- `_heartbeat_slept`, and a beat that finds it set reports `gap=suspended`
-- instead of a duration and clears it, so a numeric gap now means the loop
-- really was awake for that long.  The flag is cleared here rather than in
-- onResume because it has to survive until the *next* beat reads it.
function MDEdit:scheduleHeartbeat(delay)
    if self._heartbeat_pending then
        UIManager:unschedule(self._heartbeat_pending)
        self._heartbeat_pending = nil
    end
    local fn
    fn = function()
        if self._heartbeat_pending == fn then self._heartbeat_pending = nil end
        if self._closing then return end
        local now = IO.now_seconds()
        local gap
        if self._heartbeat_slept then
            gap = "suspended"
            self._heartbeat_slept = nil
        else
            gap = string.format("%.2f", self._heartbeat_at and (now - self._heartbeat_at) or 0)
        end
        Chrome.trace("editor-heartbeat", "path=", tostring(self.path),
            "gap=", gap, "row=", self.crow or 0,
            "vtop=", self.vtop or 0, "dirty=", self._dirty and "yes" or "no")
        self._heartbeat_at = now
        self:scheduleHeartbeat(C.EDIT.MDEDIT_HEARTBEAT_INTERVAL)
    end
    self._heartbeat_pending = fn
    UIManager:scheduleIn(delay or C.EDIT.MDEDIT_HEARTBEAT_INTERVAL, fn)
end
function MDEdit:snapshot()
    self:scheduleAutosave()
    self._undo = self._undo or {}
    self._undo[#self._undo+1] = { lines = Text.copy_arr(self.lines), crow = self.crow, ccol = self.ccol }
    if #self._undo > 80 then table.remove(self._undo, 1) end
    self._redo = {}
end
-- `row` defaults to the cursor's line, which is every caller but the checkbox
-- toggle -- that one changes a line the cursor is not on (a tap on a box does
-- not move the caret). The recorded crow/ccol stay the CURSOR's, not the
-- changed line's, so undoing restores the text there and leaves the caret where
-- the user actually is.
function MDEdit:snapshotLine(row)
    row = row or self.crow
    self:scheduleAutosave()
    self._undo = self._undo or {}
    self._undo[#self._undo+1] = {
        kind = "line", line = row, text = self.lines[row] or "",
        crow = self.crow, ccol = self.ccol,
    }
    if #self._undo > 80 then table.remove(self._undo, 1) end
    self._redo = {}
end
function MDEdit:edit(tag)             -- snapshot once per edit "burst" (typing vs deleting)
    if self._burst ~= tag then
        -- The sustained typing/backspace path changes one logical line. Keeping
        -- just that line avoids copying every line of a large note for undo.
        if tag == "type" or (tag == "del" and self.ccol > 0) then self:snapshotLine() else self:snapshot() end
    else self:scheduleAutosave() end
    self._burst = tag
end
function MDEdit:_restore(stack, other)
    if not (stack and #stack > 0) then return end
    local s = table.remove(stack)
    if s.kind == "line" then
        other[#other+1] = { kind = "line", line = s.line, text = self.lines[s.line] or "", crow = self.crow, ccol = self.ccol }
        self.lines[s.line] = s.text
        self.crow, self.ccol = s.crow, s.ccol
    else
        other[#other+1] = { lines = Text.copy_arr(self.lines), crow = self.crow, ccol = self.ccol }
        self.lines, self.crow, self.ccol = s.lines, s.crow, s.ccol
    end
    self._burst = nil
    self._desired_x = nil
    self:scheduleAutosave()
    self:refresh()
end
function MDEdit:undo() self._redo = self._redo or {}; self:_restore(self._undo, self._redo) end
function MDEdit:redo() self._undo = self._undo or {}; self:_restore(self._redo, self._undo) end
-- ---- selection + clipboard (anchor in self.sel, cursor at crow/ccol) ----
function MDEdit:selRange()
    if not self.sel then return nil end
    local ar, ac, br, bc = self.sel.row, self.sel.col, self.crow, self.ccol
    if ar < br or (ar == br and ac <= bc) then return ar, ac, br, bc else return br, bc, ar, ac end
end
function MDEdit:hasSel()
    local lr, lc, hr, hc = self:selRange()
    return lr ~= nil and not (lr == hr and lc == hc)
end
function MDEdit:lineSel(i)            -- selected byte range [lo,hi] within line i, or nil
    local lr, lc, hr, hc = self:selRange()
    if not lr or i < lr or i > hr then return nil end
    if lr == hr then if lc == hc then return nil end; return lc, hc end
    if i == lr then return lc, #self.lines[i]
    elseif i == hr then return 0, hc
    else return 0, #self.lines[i] end
end
function MDEdit:selText()
    local lr, lc, hr, hc = self:selRange()
    if not lr then return "" end
    if lr == hr then return self.lines[lr]:sub(lc+1, hc) end
    local parts = { self.lines[lr]:sub(lc+1) }
    for k = lr+1, hr-1 do parts[#parts+1] = self.lines[k] end
    parts[#parts+1] = self.lines[hr]:sub(1, hc)
    return table.concat(parts, "\n")
end
function MDEdit:deleteSelection()
    local lr, lc, hr, hc = self:selRange()
    if not lr then return false end
    self._desired_x = nil
    if lr == hr then
        self.lines[lr] = self.lines[lr]:sub(1, lc) .. self.lines[lr]:sub(hc+1)
    else
        self.lines[lr] = self.lines[lr]:sub(1, lc) .. self.lines[hr]:sub(hc+1)
        for k = hr, lr+1, -1 do table.remove(self.lines, k) end
    end
    self.crow, self.ccol, self.sel = lr, lc, nil
    return true
end
function MDEdit:copy() if self:hasSel() then md_clipboard = self:selText() end end
function MDEdit:cut()
    if not self:hasSel() then return end
    md_clipboard = self:selText(); self:snapshot(); self._burst = nil
    self._desired_x = nil
    self:deleteSelection(); self:refresh()
end
function MDEdit:paste()
    if not md_clipboard or md_clipboard == "" then return end
    self:snapshot(); self._burst = nil
    self._desired_x = nil
    if self:hasSel() then self:deleteSelection() end
    local cl = {}
    for line in (md_clipboard .. "\n"):gmatch("(.-)\n") do cl[#cl+1] = line end
    local l = self.lines[self.crow]
    if #cl <= 1 then
        local one = cl[1] or ""
        self.lines[self.crow] = l:sub(1, self.ccol) .. one .. l:sub(self.ccol+1)
        self.ccol = self.ccol + #one
    else
        local tail = l:sub(self.ccol+1)
        self.lines[self.crow] = l:sub(1, self.ccol) .. cl[1]
        for k = 2, #cl do table.insert(self.lines, self.crow + k - 1, cl[k]) end
        self.crow = self.crow + #cl - 1
        self.ccol = #cl[#cl]
        self.lines[self.crow] = self.lines[self.crow] .. tail
    end
    self:refresh()
end
function MDEdit:selectAll()
    self._desired_x = nil
    self.sel = { row = 1, col = 0 }
    self.crow = #self.lines; self.ccol = #self.lines[#self.lines]
    self:refresh{ layout_dirty = false, selection = true, full = true }
end
-- Drops the selection, leaving the caret where the selection ended (which is
-- where self.crow/ccol already point -- self.sel holds the other end). The early
-- return keeps a no-op from costing a full-screen e-ink repaint; the palette
-- greys the command in that state, but a chord or a future caller need not know
-- that. PALETTE_PLAN.md P2-1.
function MDEdit:selectNone()
    if not self:hasSel() then return end
    self.sel = nil
    self:refresh{ layout_dirty = false, selection = true, full = true }
end
-- The snapshot minfolio_menu_model's predicates run against (PALETTE_PLAN.md
-- §4.2). Plain values only -- no methods, no widgets -- because that is what
-- keeps every enable/hide/check rule a pure function the off-device suite can
-- cover. It lives in this file rather than beside openPalette in
-- minfolio_edit_view because md_clipboard is a file-local here.
function MDEdit:paletteState()
    return {
        reader_mode = not not self.reader_mode,
        remote = self.remote ~= nil,
        has_selection = not not self:hasSel(),
        can_undo = self._undo ~= nil and #self._undo > 0,
        can_redo = self._redo ~= nil and #self._redo > 0,
        has_clipboard = md_clipboard ~= nil and md_clipboard ~= "",
        has_find_query = self._find_query ~= nil and self._find_query ~= "",
        keyboard = self.keyboard ~= nil,
        frontlight_on = (FL.bright or 0) > 0,
        has_warmth = not not Frontlight.FL_HAS_AMBER,
    }
end
function MDEdit:arrow(drow, dcol, m)  -- arrow key with optional Shift (select) / Alt-or-Command (word)
    self:flushTypeBuffer()
    local selecting = Keys.keymod(m, "Shift")
    if selecting then if not self.sel then self.sel = { row = self.crow, col = self.ccol } end
    else self.sel = nil end
    if Keys.word_key_mod(m) and dcol ~= 0 then if dcol < 0 then self:wordLeft(selecting) else self:wordRight(selecting) end
    else self:moveCursor(drow, dcol, { selection = selecting }) end
end
function MDEdit:insertTypedText(s)
    if not s or s == "" then return end
    self:pauseCaretBlinkForInput()
    self._desired_x = nil
    local had_sel = self:hasSel()
    if had_sel then self:snapshot(); self._burst = nil; self:deleteSelection() else self:edit("type") end
    for i = 1, #s do
        local ch = s:sub(i, i)
        local l = self.lines[self.crow]
        if ch == " " and self.ccol >= 1 and l:sub(self.ccol, self.ccol) == " "
           and (self.ccol < 2 or l:sub(self.ccol-1, self.ccol-1) ~= " ") then
            self.lines[self.crow] = l:sub(1, self.ccol-1) .. ". " .. l:sub(self.ccol+1)
            self.ccol = self.ccol + 1
        else
            self.lines[self.crow] = l:sub(1, self.ccol) .. ch .. l:sub(self.ccol+1)
            self.ccol = self.ccol + #ch
        end
    end
    self._last_type_flush_at = IO.now_seconds()
    local incremental = not had_sel and self:updateVisualLine(self.crow)
    self:refresh{ layout_dirty = not incremental, precise_edit = not had_sel }
end
function MDEdit:flushTypeBuffer()
    if self._type_flush_pending then
        UIManager:unschedule(self._type_flush_pending)
        self._type_flush_pending = nil
    end
    local s = self._type_buffer
    self._type_buffer = nil
    if s and s ~= "" then self:insertTypedText(s) end
end
function MDEdit:queueTypedChar(ch)
    self:pauseCaretBlinkForInput()
    self._type_buffer = (self._type_buffer or "") .. ch
    -- Give the first key after an idle pause near-immediate feedback, then settle
    -- into a slightly wider cadence that batches sustained typing efficiently.
    -- The pending callback is never rescheduled by later keys, so fast input
    -- cannot defer rendering indefinitely.
    if self._type_flush_pending then return end
    local now = IO.now_seconds()
    local first_in_burst = not self._last_type_flush_at
        or now - self._last_type_flush_at >= C.EDIT.MDEDIT_TYPE_BURST_IDLE
    local delay = first_in_burst and C.EDIT.MDEDIT_TYPE_FIRST_FLUSH_DELAY or C.EDIT.MDEDIT_TYPE_FLUSH_DELAY
    local fn
    fn = function()
        if self._type_flush_pending == fn then self._type_flush_pending = nil end
        local s = self._type_buffer
        self._type_buffer = nil
        if s and s ~= "" then self:insertTypedText(s) end
    end
    self._type_flush_pending = fn
    UIManager:scheduleIn(delay, fn)
end
function MDEdit:queueVirtualChars(s)
    self:pauseCaretBlinkForInput()
    self._type_buffer = (self._type_buffer or "") .. s
    self._virtual_key_count = (self._virtual_key_count or 0) + #s
    -- On-screen input has no hardware repeat to keep responsive.  More
    -- importantly, rebuilding the Markdown view every 45 ms can monopolize the
    -- Kindle's UI loop long enough for subsequent touch contacts to be dropped.
    -- Debounce the visual update instead: taps only append a short Lua string,
    -- then the complete burst is rendered once the finger cadence pauses.
    if self._type_flush_pending then
        UIManager:unschedule(self._type_flush_pending)
        self._type_flush_pending = nil
    end
    local fn
    fn = function()
        if self._type_flush_pending == fn then self._type_flush_pending = nil end
        local text = self._type_buffer
        self._type_buffer = nil
        if text and text ~= "" then self:insertTypedText(text) end
    end
    self._type_flush_pending = fn
    UIManager:scheduleIn(0.18, fn)
end
function MDEdit:addChars(s)
    -- Newline remains an immediate structural edit, after flushing any pending
    -- virtual text. Regular on-screen keys use the debounce above.
    if s == "\n" then
        self:flushTypeBuffer()
        return self:newline()
    end
    self:queueVirtualChars(s)
end
-- Is a logical line inside a fenced code block (its fences included)? Computed
-- from the live lines rather than read off the last layout: this answers an
-- editing question, and the caller may be mid-keystroke on text the layout has
-- not seen yet. It is one pass over the document, on Enter and on opening the
-- Outline only -- both already do more work than that.
function MDEdit:inCodeBlock(row)
    return MD.md_code_map(self.lines)[row] ~= nil
end
function MDEdit:newline()
    self:flushTypeBuffer()
    self:snapshot(); self._burst = nil
    self._desired_x = nil
    if self:hasSel() then self:deleteSelection() end
    local l = self.lines[self.crow]
    local before, after = l:sub(1, self.ccol), l:sub(self.ccol+1)
    local prefix = ""
    -- Inside a fenced code block none of this applies: nothing there is Markdown,
    -- so Enter after `- rm -rf /tmp/x` in a shell block owes the next line a bare
    -- newline, not a bullet it would then have to be deleted out of.
    if not self:inCodeBlock(self.crow) then
        -- Every rule about what the next line inherits -- list markers, task
        -- boxes, blockquote markers, and which of them an Enter on an empty one
        -- ends -- lives in MD.md_line_continuation, which is pure and tested.
        -- It used to be spelled out here, where nothing could check it.
        --
        -- `reset` is a REPLACEMENT for the current line and is very often the
        -- empty string, which is truthy in Lua. `if reset then` is therefore the
        -- correct test and `reset ~= ""` would be a bug: ending a quote is
        -- exactly the case that resets to "".
        local continuation, reset = MD.md_line_continuation(l, self.ccol)
        if reset then
            self.lines[self.crow] = reset
            self.ccol = #reset
            return self:refresh()
        end
        prefix = continuation or ""
    end
    table.insert(self.lines, self.crow+1, prefix .. after)
    self.lines[self.crow] = before
    self.crow = self.crow + 1; self.ccol = #prefix
    self:refresh()
end
function MDEdit:delChar()
    self._desired_x = nil
    if self:hasSel() then self:snapshot(); self._burst = nil; self:deleteSelection(); return self:refresh() end
    self:edit("del")
    if self.ccol > 0 then
        local l = self.lines[self.crow]
        local prev = Text.utf8_left(l, self.ccol)          -- delete the whole UTF-8 char to the left
        self.lines[self.crow] = l:sub(1, prev) .. l:sub(self.ccol+1)
        self.ccol = prev
        local incremental = self:updateVisualLine(self.crow)
        return self:refresh{ layout_dirty = not incremental, precise_edit = true }
    elseif self.crow > 1 then
        local prev = self.lines[self.crow-1]
        self.ccol = #prev
        self.lines[self.crow-1] = prev .. self.lines[self.crow]
        table.remove(self.lines, self.crow); self.crow = self.crow - 1
    end
    self:refresh()
end
function MDEdit:moveCursor(drow, dcol, opts)
    self._burst = nil
    if dcol ~= 0 then self._desired_x = nil end
    if dcol < 0 then
        if self.ccol <= 0 then
            if self.crow > 1 then self.crow = self.crow - 1; self.ccol = #self.lines[self.crow] end
        else self.ccol = Text.utf8_left(self.lines[self.crow], self.ccol) end
    elseif dcol > 0 then
        if self.ccol >= #self.lines[self.crow] then
            if self.crow < #self.lines then self.crow = self.crow + 1; self.ccol = 0 end
        else self.ccol = Text.utf8_right(self.lines[self.crow], self.ccol) end
    end
    if drow ~= 0 then
        if not self:moveCursorVisual(drow) then
            self.crow = math.max(1, math.min(#self.lines, self.crow + drow))
            self.ccol = math.min(self.ccol, #self.lines[self.crow])
        end
    end
    opts = opts or {}
    opts.layout_dirty = false
    opts.cursor_move = true
    self:refresh(opts)
end
-- VirtualKeyboard inputbox interface
function MDEdit:leftChar()  self.sel = nil; self:moveCursor(0, -1) end
function MDEdit:rightChar() self.sel = nil; self:moveCursor(0, 1) end
function MDEdit:upLine()    self.sel = nil; self:moveCursor(-1, 0) end
function MDEdit:downLine()  self.sel = nil; self:moveCursor(1, 0) end
-- VirtualKeyboard's inputbox contract, not optional extras: holding the on-screen
-- ↑/↓ key calls keyboard:scrollUp()/scrollDown(), which forward to
-- self.inputbox:scrollUp()/scrollDown() UNGUARDED (frontend/ui/widget/
-- virtualkeyboard.lua -- unlike onSwitchingKeyboardLayout, which that file does
-- guard with an `if`). Nothing in MDEdit's base chain (InputContainer →
-- WidgetContainer → Widget → EventListener) defines them, so their absence was a
-- hard crash on hold-↑: "attempt to call method 'scrollUp' (a nil value)".
-- MindmapView already carried both as no-op stubs; the editor has real paging, so
-- page granularity is used here to match KOReader's own semantics (InputText
-- delegates to TextBoxWidget:scrollUp, which moves by lines_per_page, not one line).
function MDEdit:scrollUp()   self:pageUp() end
function MDEdit:scrollDown() self:pageDown() end
function MDEdit:goToStartOfLine() self._desired_x = nil; self.ccol = 0; self:refresh{ layout_dirty = false, cursor_move = true } end
function MDEdit:goToEndOfLine()   self._desired_x = nil; self.ccol = #self.lines[self.crow]; self:refresh{ layout_dirty = false, cursor_move = true } end
function MDEdit:delToStartOfLine()
    self:snapshot(); self._burst = nil
    self._desired_x = nil
    local l = self.lines[self.crow]; self.lines[self.crow] = l:sub(self.ccol+1); self.ccol = 0; self:refresh()
end
function MDEdit:delWord()
    self._desired_x = nil
    if self:hasSel() then self:snapshot(); self._burst = nil; self:deleteSelection(); return self:refresh() end
    -- At the start of a line there is no word to delete on this line; fall back to
    -- delChar so a word-delete still joins with the previous line (matches every
    -- editor, and is the path the Bluetooth keyboard's backspace takes).
    if self.ccol <= 0 then return self:delChar() end
    self:snapshot(); self._burst = nil
    local l = self.lines[self.crow]
    local before = l:sub(1, Text.prev_word_col(l, self.ccol))
    self.lines[self.crow] = before .. l:sub(self.ccol+1); self.ccol = #before; self:refresh{ precise_edit = true }
end
function MDEdit:wordLeft(selecting)
    self._burst = nil
    self._desired_x = nil
    self.ccol = Text.prev_word_col(self.lines[self.crow], self.ccol); self:refresh{ layout_dirty = false, selection = selecting, cursor_move = true }
end
function MDEdit:wordRight(selecting)
    self._burst = nil
    self._desired_x = nil
    self.ccol = Text.next_word_col(self.lines[self.crow], self.ccol); self:refresh{ layout_dirty = false, selection = selecting, cursor_move = true }
end
function MDEdit:scrollBy(lines)
    local old = self.vtop or 1
    local max_top = math.max(1, self.visual_count or #self.lines)
    self.vtop = math.max(1, math.min(max_top, old + lines))
    if self.vtop ~= old then
        self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    end
    self:refreshScroll()
end
function MDEdit:pageBy(direction)
    local old = self.vtop or 1
    local last = self._last_page_scroll
    local step
    if last and last.from ~= last.to and last.to == old and last.dir == -direction then
        step = math.abs(last.to - last.from)
    else
        step = self:pageStep(direction)
    end
    self:scrollBy(direction * step)
    if self.vtop ~= old then
        self._last_page_scroll = { dir = direction, from = old, to = self.vtop or old }
    else
        self._last_page_scroll = nil
    end
end
-- Page turns advance by roughly 3/4 of the visible editor height. Count
-- rendered row heights instead of visible row count so headings, gaps, and
-- tables don't distort physical scroll distance.
function MDEdit:pageStep(direction)
    local rows = self._vrows
    local start = self.vtop or 1
    if not rows or #rows == 0 then return math.max(1, math.floor((self.visible_vrows or 12) * 0.75)) end
    local target = math.max(1, math.floor((self.visible_budget or math.floor(self.fh / 2)) * 0.75))
    local step, used = 0, 0
    if (direction or 1) < 0 then
        while start - step > 1 and used < target do
            step = step + 1
            used = used + self:visualRowHeight(rows[start - step])
        end
    else
        while start + step <= #rows and used < target do
            step = step + 1
            used = used + self:visualRowHeight(rows[start + step - 1])
        end
    end
    return math.max(1, step)
end
function MDEdit:pageUp()   self:pageBy(-1) end
function MDEdit:pageDown() self:pageBy(1) end
function MDEdit:pageLeft()  self:pageUp() end
function MDEdit:pageRight() self:pageDown() end
function MDEdit:pageFromTap(pos)
    if pos and pos.x < (self.fw / 2) then self:pageLeft() else self:pageRight() end
end
function MDEdit:outlineItems()
    self:flushTypeBuffer()
    local items = {}
    -- A '#' inside a fenced block is a comment in half the languages people
    -- paste here, not a heading -- listing those would bury the real outline of
    -- any document with a shell or Python block in it.
    local code = MD.md_code_map(self.lines or {})
    for i, line in ipairs(self.lines or {}) do
        local hashes, text = MD.heading(line)
        if hashes and not code[i] then
            local level = #hashes
            local indent = string.rep("  ", math.max(0, level - 1))
            local label = MD.md_trim(text)
            if label ~= "" then
                items[#items+1] = {
                    text = string.format("%s%s", indent, label),
                    callback = function() self:jumpToLine(i) end,
                }
            end
        end
    end
    if #items == 0 then
        items[1] = { text = _("No headings"), select_enabled = false, dim = true }
    end
    return items
end
function MDEdit:jumpToLine(line)
    self:flushTypeBuffer()
    local target = math.max(1, math.min(tonumber(line) or 1, #self.lines))
    self.crow, self.ccol = target, 0
    self.sel, self._desired_x, self._burst = nil, nil, nil
    local vrows = self:visualRows(self:textWidth())
    local target_vi = 1
    for vi, vr in ipairs(vrows or {}) do
        if vr.line and vr.line >= target then target_vi = vi; break end
    end
    self.vtop = target_vi
    self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    self:refreshScroll()
end
-- ---- find ---------------------------------------------------------------
-- Find deliberately uses the editor selection for the active result. This
-- makes the match visible in both the styled editor and reader mode, and keeps
-- copy/keyboard behaviour consistent with a normal text selection.
-- The matching itself lives in minfolio_find (Tier 0) so that Find and Replace
-- cannot drift apart in what they consider a match, and so the rules -- literal
-- not pattern, case-insensitive, non-overlapping, byte columns -- are covered by
-- minfolio_find_test.lua rather than only by trying it on a device.
function MDEdit:findMatches(query)
    return Find.matches(self.lines, query)
end
function MDEdit:showFindMatch(match, index, total)
    if not match then return false end
    self._find_match = match
    self._find_match_index = index
    self.sel = { row = match.row, col = match.start_col }
    self.crow, self.ccol = match.row, match.end_col
    self._desired_x, self._burst = nil, nil
    local target_vi = 1
    for vi, row in ipairs(self:visualRows(self:textWidth()) or {}) do
        local text_row = row.row or {}
        local row_end = text_row.sb or 0
        for _, seg in ipairs(text_row.segs or {}) do row_end = math.max(row_end, (seg.sb or 0) + #(seg.text or "")) end
        if row.line == match.row and (text_row.sb or 0) <= match.start_col and row_end >= match.start_col then
            target_vi = vi
            break
        end
    end
    self.vtop = target_vi
    self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    self:refresh{ layout_dirty = false, selection = true }
    Chrome.notify(string.format(_("Match %d of %d"), index, total))
    return true
end
function MDEdit:findNext(query, direction)
    self:flushTypeBuffer()
    query = query or self._find_query or ""
    if query == "" then Chrome.notify(_("Enter text to find")); return false end
    self._find_query = query
    self._find_bar_visible = true
    local matches = self:findMatches(query)
    if #matches == 0 then
        self._find_match, self._find_match_index = nil, nil
        self:refresh{ layout_dirty = false, full = true }
        Chrome.notify(_("No matches"))
        return false
    end
    direction = direction or 1
    local current = self._find_match_index
    local active = self._find_match
    if not (active and active.row == self.crow and active.end_col == self.ccol
        and self.sel and self.sel.row == active.row and self.sel.col == active.start_col) then
        current = nil
    end
    if current and matches[current]
        and matches[current].row == active.row and matches[current].start_col == active.start_col then
        current = ((current - 1 + direction) % #matches) + 1
    elseif direction > 0 then
        current = 1
        for i, match in ipairs(matches) do
            if match.row > self.crow or (match.row == self.crow and match.start_col >= self.ccol) then
                current = i
                break
            end
        end
    else
        current = #matches
        for i = #matches, 1, -1 do
            local match = matches[i]
            if match.row < self.crow or (match.row == self.crow and match.end_col <= self.ccol) then
                current = i
                break
            end
        end
    end
    local index = current
    return self:showFindMatch(matches[index], index, #matches)
end
function MDEdit:goToFindMatch()
    local matches = self:findMatches(self._find_query)
    local index = self._find_match_index
    if index and matches[index] then return self:showFindMatch(matches[index], index, #matches) end
    return self:findNext(self._find_query, 1)
end
function MDEdit:openFindDialog()
    self:flushTypeBuffer()
    if self._find_dialog then return end
    if self.keyboard then self:hideKeyboard() end
    local initial = self._find_query or (self:hasSel() and self:selText()) or ""
    local dlg
    local restored = false
    local function restore_focus()
        if restored then return end
        restored = true
        self._find_dialog = nil
        self.is_always_active = true
        self:refresh{ layout_dirty = false, full = true }
    end
    local function close_then(action)
        local query = dlg:getInputText() or ""
        UIManager:close(dlg)
        if action then action(query) end
    end
    local buttons = {
        {
            { text = _("Cancel"), callback = function() close_then() end },
            { text = _("Previous"), callback = function() close_then(function(q) self:findNext(q, -1) end) end },
        },
        {
            { text = _("Next"), is_enter_default = true, callback = function() close_then(function(q) self:findNext(q, 1) end) end },
            { text = _("Go to match"), callback = function() close_then(function(q)
                self._find_query = q
                self._find_bar_visible = true
                self:goToFindMatch()
            end) end },
        },
    }
    -- Replace is an editing action, so it is offered only in editing mode --
    -- reader mode has no caret to leave behind and no keyboard to correct with.
    -- Handing the query over means switching dialogs never costs a retype.
    if not self.reader_mode then
        buttons[#buttons+1] = {
            { text = _("Replace..."), callback = function() close_then(function(q) self:openReplaceDialog(q) end) end },
        }
    end
    dlg = InputDialog:new{
        title = _("Find"),
        input = initial,
        buttons = buttons,
    }
    self._find_dialog = dlg
    self.is_always_active = false
    local original_close = dlg.onCloseWidget
    function dlg:onCloseWidget()
        if original_close then original_close(self) end
        restore_focus()
    end
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end
-- ---- replace ------------------------------------------------------------
-- Replace reuses Find's selection-as-active-match convention (see the note
-- above findMatches): the match to be replaced is the one currently selected,
-- which is the one the user can see highlighted. That is why "Replace" on a
-- document with no active match only advances to the next hit -- the first tap
-- shows what will change, the second changes it. Replacing something the user
-- has not been shown is how a find/replace loses someone's work.
function MDEdit:replaceCurrent(query, replacement)
    if self.reader_mode then Chrome.notify(_("Switch to editing mode to replace")); return false end
    self:flushTypeBuffer()
    query = query or self._find_query or ""
    if query == "" then Chrome.notify(_("Enter text to find")); return false end
    replacement = Find.sanitize_replacement(replacement)
    self._find_query, self._replace_with = query, replacement
    self._find_bar_visible = true
    local active = self._find_match
    -- Same staleness test as findNext: the recorded match is only the active one
    -- while the selection still sits exactly on it. Any cursor move since then
    -- (or an edit that shifted the text) makes it stale.
    local is_active = active and active.row == self.crow and active.end_col == self.ccol
        and self.sel and self.sel.row == active.row and self.sel.col == active.start_col
    if not is_active then return self:findNext(query, 1) end
    self:snapshot(); self._burst = nil
    local lines, col = Find.replace_one(self.lines, active, replacement)
    self.lines = lines
    self.sel = nil
    self.crow, self.ccol = active.row, col or active.start_col
    self._find_match, self._find_match_index = nil, nil
    self._desired_x = nil
    self:refresh()
    -- Land on the next occurrence so a repeated Replace walks the document.
    -- The cursor sits just past the text just inserted, so a replacement that
    -- contains the query ("a" -> "aa") advances past its own output rather than
    -- finding it again.
    self:findNext(query, 1)
    return true
end
function MDEdit:replaceAll(query, replacement)
    if self.reader_mode then Chrome.notify(_("Switch to editing mode to replace")); return false end
    self:flushTypeBuffer()
    query = query or self._find_query or ""
    if query == "" then Chrome.notify(_("Enter text to find")); return false end
    replacement = Find.sanitize_replacement(replacement)
    self._find_query, self._replace_with = query, replacement
    local lines, count = Find.replace_all(self.lines, query, replacement)
    if count == 0 then
        self._find_match, self._find_match_index = nil, nil
        Chrome.notify(_("No matches"))
        return false
    end
    -- Snapshot BEFORE the swap: snapshot() copies the array as it is now, which
    -- is what undo has to come back to. One snapshot for the whole run, so a
    -- single undo puts every replaced occurrence back.
    self:snapshot(); self._burst = nil
    self.lines = lines
    self.sel = nil
    self._find_match, self._find_match_index = nil, nil
    self._desired_x = nil
    -- The line under the cursor may have got shorter (or, at the end of the
    -- document, gone entirely out from under it).
    self.crow = math.max(1, math.min(#self.lines, self.crow))
    self.ccol = math.max(0, math.min(self.ccol, #(self.lines[self.crow] or "")))
    self:refresh{ full = true }
    Chrome.notify(count == 1 and _("Replaced 1 occurrence")
        or string.format(_("Replaced %d occurrences"), count))
    return true
end
function MDEdit:openReplaceDialog(query)
    self:flushTypeBuffer()
    if self._find_dialog then return end
    if self.reader_mode then Chrome.notify(_("Switch to editing mode to replace")); return end
    if self.keyboard then self:hideKeyboard() end
    local initial = query or self._find_query or (self:hasSel() and self:selText()) or ""
    local dlg
    local restored = false
    local function restore_focus()
        if restored then return end
        restored = true
        self._find_dialog = nil
        self.is_always_active = true
        self:refresh{ layout_dirty = false, full = true }
    end
    local function close_then(action)
        local fields = dlg:getFields() or {}
        local find_text, replacement = fields[1] or "", fields[2] or ""
        UIManager:close(dlg)
        if action then action(find_text, replacement) end
    end
    dlg = MultiInputDialog:new{
        title = _("Find and replace"),
        fields = {
            { description = _("Find"), text = initial, hint = _("Text to find") },
            { description = _("Replace with"), text = self._replace_with or "", hint = _("Replacement text") },
        },
        buttons = {
            {
                { text = _("Cancel"), callback = function() close_then() end },
                -- No is_enter_default anywhere in this dialog: Enter while
                -- typing a replacement must not commit a whole-document change.
                { text = _("Replace"), callback = function() close_then(function(q, r) self:replaceCurrent(q, r) end) end },
                { text = _("Replace all"), callback = function() close_then(function(q, r) self:replaceAll(q, r) end) end },
            },
        },
    }
    self._find_dialog = dlg
    self.is_always_active = false
    local original_close = dlg.onCloseWidget
    function dlg:onCloseWidget()
        if original_close then original_close(self) end
        restore_focus()
    end
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end
-- ---- word count ---------------------------------------------------------
-- The baseline for "this session", computed once and kept. init only stashes
-- the opening text; the md_tokenize pass to count it happens here, the first
-- time anyone asks, so opening a note never pays for a number nobody looked at.
function MDEdit:sessionWords()
    if not self._session_words then
        self._session_words = Stats.count(self._session_text or "").words
    end
    return self._session_words
end
function MDEdit:showWordCount()
    self:flushTypeBuffer()
    local counts = Stats.count(self:currentText())
    local n = Stats.group_digits
    local parts = {
        string.format(_("Words: %s"), n(counts.words)),
        string.format(_("Characters: %s (%s without spaces)"), n(counts.chars), n(counts.chars_no_spaces)),
        string.format(_("Paragraphs: %s   Lines: %s"), n(counts.paragraphs), n(counts.lines)),
        string.format(_("Reading time: about %s min"), n(counts.minutes)),
    }
    if self:hasSel() then
        local selected = Stats.count(self:selText())
        parts[#parts+1] = ""
        parts[#parts+1] = string.format(_("Selected: %s words, %s characters"),
            n(selected.words), n(selected.chars))
    end
    local written = counts.words - self:sessionWords()
    local minutes = math.floor(((IO.now_seconds() or 0) - (self._session_start or 0)) / 60)
    parts[#parts+1] = ""
    parts[#parts+1] = string.format(_("This session: %s%s words in %s min"),
        written > 0 and "+" or "", n(written), n(math.max(0, minutes)))
    self:showInfo(table.concat(parts, "\n"))
end
-- An InfoMessage is modal, but this editor is is_always_active -- without
-- handing that flag over for the lifetime of the message, every key pressed to
-- dismiss it would also be typed into the document underneath. Same trade the
-- find dialog makes, same restore-on-close.
function MDEdit:showInfo(text)
    local msg
    local restored = false
    local function restore_focus()
        if restored then return end
        restored = true
        self.is_always_active = true
    end
    msg = InfoMessage:new{ text = text, alignment = "left" }
    self.is_always_active = false
    local original_close = msg.onCloseWidget
    function msg:onCloseWidget()
        if original_close then original_close(self) end
        restore_focus()
    end
    UIManager:show(msg)
end
-- The showInfo handover above, as something a caller can apply to a widget it did
-- not build. `MDEdit:newNote` needs it for a dialog the BROWSER constructs, which
-- rules out doing the handover inside the constructor the way showInfo does.
--
-- CloseWidget, not the dialog's own buttons: UIManager broadcasts it on every
-- teardown route, whereas a Cancel callback only covers the routes someone
-- remembered. Missing one leaves is_always_active false for the rest of the
-- session, and the editor then ignores the keyboard entirely -- the same defect
-- the palette shipped with in P1-2 and the same fix.
function MDEdit:handKeyboardTo(widget)
    if not widget then return widget end
    local restored = false
    local function restore_focus()
        if restored then return end
        restored = true
        self.is_always_active = true
    end
    self.is_always_active = false
    local original_close = widget.onCloseWidget
    function widget:onCloseWidget()
        if original_close then original_close(self) end
        restore_focus()
    end
    return widget
end
function MDEdit:setReaderMode(enabled, target_row, target_col)
    enabled = not not enabled
    if self.reader_mode == enabled then return end
    self.reader_mode = enabled
    self._pan_mode = nil
    self._last_tap = nil
    self._desired_x = nil
    self.sel = nil
    if enabled then
        if self.keyboard then self:hideKeyboard() end
        self.caret_on = false
        Chrome.notify(_("Reader mode: tap Edit to return"))
    else
        local trow = target_row or self.top
        self.crow = math.max(1, math.min(#self.lines, trow))
        self.ccol = math.max(0, math.min(target_col or self.ccol or 0, #(self.lines[self.crow] or "")))
        self.caret_on = true
        Chrome.notify(_("Editing mode"))
    end
    -- The top bar itself changes on a mode switch (formatting tools <-> "Edit"),
    -- so force a full repaint; the partial-region paths only cover the text body
    -- and would leave a stale toolbar when the keyboard is hidden.
    self:refresh{ full = true }
end
function MDEdit:onSwitchingKeyboardLayout() end
function MDEdit:showKeyboard()
    if self.reader_mode then return end
    if self.keyboard then return end
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local keyboard = VirtualKeyboard:new{ inputbox = self }
    Keys.makeKeyboardArrowFree(keyboard)
    Keys.disableKeyboardKeyFlash(keyboard)
    keyboard.modal = false
    self.keyboard = keyboard
    local editor = self
    local original_close = keyboard.onCloseWidget
    function keyboard:onCloseWidget()
        if original_close then original_close(self) end
        if editor.keyboard == self then
            editor.keyboard = nil
            if editor._caret_blinking then
                editor:refresh{ layout_dirty = false, full = true }
            end
        end
    end
    self:refresh{ layout_dirty = false, full = true }
    UIManager:show(keyboard)
end

function MDEdit:isPointInKeyboard(pos)
    if not self.keyboard or not pos then return false end
    local dimen = self.keyboard.dimen
    local top = dimen and dimen.y or (self.fh - ((dimen and dimen.h) or math.floor(self.fh * 0.36)))
    return pos.y >= top
end
function MDEdit:hideKeyboard()
    if not self.keyboard then return end
    local keyboard = self.keyboard
    self.keyboard = nil
    UIManager:close(keyboard)
    self:refresh{ layout_dirty = false, full = true }
end
function MDEdit:isKeyboardRevealGesture(ges)
    if self.reader_mode or self.keyboard then return false end
    local p = ges and ges.pos
    local sp = ges and ges.start_pos or p
    if not p or not sp then return false end
    local x = sp.x or p.x
    local bottom_y = math.max(sp.y or 0, p.y or 0)
    local dy = (p.y or 0) - (sp.y or 0)
    local center = x >= self.fw * 0.36 and x <= self.fw * 0.64
    local from_bottom = bottom_y >= self.fh - C.EDIT.MDEDIT_KEYBOARD_SWIPE_EDGE
    local upward = (ges.direction == "north") or dy <= -C.EDIT.MDEDIT_KEYBOARD_SWIPE_DY
    return center and from_bottom and upward
end
-- Inverse of the reveal gesture: a downward swipe that STARTS just above the
-- keyboard's top edge hides it. The keyboard's own keys swallow swipes, so the
-- gesture has to begin in the text area (which the editor reliably receives),
-- right where the text meets the keyboard -- a deliberate "push it down" motion.
function MDEdit:isKeyboardHideGesture(ges)
    if not self.keyboard then return false end
    local p = ges and ges.pos
    local sp = ges and ges.start_pos or p
    if not p or not sp then return false end
    local kbd_h = (self.keyboard.dimen and self.keyboard.dimen.h) or math.floor(self.fh * 0.36)
    local kbd_top = self.fh - kbd_h
    local start_y = sp.y or p.y or 0
    local dx = (p.x or 0) - (sp.x or 0)
    local dy = (p.y or 0) - (sp.y or 0)
    -- Start within the strip just above the keyboard (in the text area, so we get
    -- the event), then move clearly downward.  KOReader can label a diagonal or
    -- even mostly horizontal select-drag as "south", so do not trust its
    -- direction field without checking the actual displacement.
    local near_kbd_top = start_y >= kbd_top - C.EDIT.MDEDIT_KEYBOARD_SWIPE_EDGE and start_y <= kbd_top
    local downward = dy >= C.EDIT.MDEDIT_KEYBOARD_SWIPE_DY and math.abs(dy) >= math.abs(dx) * 1.25
    return near_kbd_top and downward
end
-- Writes through IO.write_file_atomic, and -- the part that matters -- only
-- clears self._dirty when the write actually reported success. The previous
-- version opened the path with "w" (truncating the note immediately), ignored
-- what write/close returned, and cleared _dirty unconditionally, so a failed
-- save left a truncated file that the editor believed was safely on disk. From
-- there the in-memory text was one close away from being gone for good. Keeping
-- _dirty true instead means the buffer is intact, autosave keeps retrying, and
-- onCloseWidget's flush still has something to flush.
function MDEdit:save()
    self:flushTypeBuffer()
    local text = self:currentText()
    local ok, err = IO.write_file_atomic(self.path, text)
    if not ok then
        -- Notify on the ok->failing edge only. Autosave retries on a timer, so
        -- notifying every attempt would bury the screen in identical toasts
        -- while the volume is unmounted -- which is exactly when the user needs
        -- to be able to read one.
        Chrome.trace("editor-save-failed", "path=", tostring(self.path), "err=", tostring(err))
        if not self._save_failed then
            self._save_failed = true
            Chrome.notify(_("Could not save: ") .. tostring(err or "unknown error"))
        end
        return false
    end
    self._save_failed = nil
    self._dirty = false
    self._file_text = text
    self._file_signature = IO.file_signature(self.path)
    -- The worker polls this file and uploads whatever it finds, so a torn read
    -- here would ship a truncated document to the desktop.
    if self.remote then IO.write_file_atomic(self.remote.outbox_path, text) end
    self._external_change_prompted = nil
    self._autosave_paused_for_external = nil
    if self._autosave_pending then UIManager:unschedule(self._autosave_pending); self._autosave_pending = nil end
    return true
end
-- Handles both the app's own Rotate screen action and any generic resize;
-- Chrome.rotate_screen_ccw() has already applied Screen:setRotationMode by the time
-- this runs, so this only needs to reflow the editor at the new dimensions.
function MDEdit:onScreenResize()
    self.fw, self.fh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh }
    if self.ges_events then
        for _, ev in pairs(self.ges_events) do
            for _, range in ipairs(ev) do range.range = self.dimen end
        end
    end
    self._wcache, self._hcache = {}, {}
    if self._wrap_cache then
        for _, entry in pairs(self._wrap_cache) do free_wrap_entry(entry) end
    end
    self._wrap_cache = nil
    self:refresh{ layout_dirty = true, full = true }
    return true
end
function MDEdit:onResume()
    Chrome.trace("editor-resume", "path=", tostring(self.path))
    self:checkExternalFile()
    self.caret_on = true
    self:refresh{ layout_dirty = false, full = true }
    FL.scheduleWakeSync()
    Chrome.schedule_wake_repaint()
end
function MDEdit:onSuspend()
    Chrome.trace("editor-suspend", "path=", tostring(self.path))
    -- Read and cleared by the next heartbeat, which is why this is not undone
    -- in onResume -- see MDEdit:scheduleHeartbeat.
    self._heartbeat_slept = true
    FL.captureBeforeSuspend()
end
function MDEdit:schedulePhysicalKeyboardRepaint()
    if self._physical_keyboard_repaint_pending then
        UIManager:unschedule(self._physical_keyboard_repaint_pending)
        self._physical_keyboard_repaint_pending = nil
    end
    local fn
    fn = function()
        if self._physical_keyboard_repaint_pending == fn then
            self._physical_keyboard_repaint_pending = nil
        end
        if self._closing then return end
        -- externalkeyboard shows a one-second modal notice, then broadcasts this
        -- event halfway through its lifetime. Repaint after that notice is gone;
        -- an arrow key in the meantime must not be the final, caret-only refresh.
        self:refresh{ layout_dirty = false, full = true }
    end
    self._physical_keyboard_repaint_pending = fn
    UIManager:scheduleIn(0.65, fn)
end
-- A Bluetooth/USB keyboard attaching or detaching repaints chrome (and can close
-- the on-screen keyboard) outside our control, leaving the screen half-blank.
-- With a physical keyboard there is no need for the on-screen one, so hide it;
-- either way force a full repaint so nothing is left stale. Return nothing so the
-- broadcast keeps propagating to other widgets.
function MDEdit:onPhysicalKeyboardConnected()
    -- The external-keyboard plugin rebuilds Device.input.event_map from scratch on
    -- attach (and re-inits input events), wiping our key aliases -- Fn/page keys,
    -- symbol keys, modifier flags. Re-apply them so e.g. Fn+Down keeps paging.
    Keys.install_keyboard_aliases()
    if self.keyboard then
        self:hideKeyboard()             -- hideKeyboard already does a full repaint
    else
        self:refresh{ layout_dirty = false, full = true }
    end
    self:schedulePhysicalKeyboardRepaint()
end
function MDEdit:onPhysicalKeyboardDisconnected()
    self:refresh{ layout_dirty = false, full = true }
    self:schedulePhysicalKeyboardRepaint()
end
function MDEdit:saveAndClose()
    self:save()
    local keyboard = self.keyboard
    self.keyboard = nil
    if keyboard then UIManager:close(keyboard) end
    UIManager:close(self)
    if self.on_close then self.on_close() end
end
function MDEdit:saveAndOpenMarkdown()
    self:save()
    local keyboard = self.keyboard
    self.keyboard = nil
    if keyboard then UIManager:close(keyboard) end
    UIManager:close(self)
    App.openPicker(Config.path_parent(self.path))
end
-- File: New (PALETTE_PLAN.md P2-1). The name prompt, the validation and the
-- creation all belong to the browser; this only asks for them, in the folder the
-- current note lives in.
--
-- Nothing is closed here. The browser's edit_note already closes a live editor
-- before opening the next note, so closing first would leave a blank screen for
-- as long as the dialog is up -- and would throw away the current note for
-- nothing if the user cancelled.
function MDEdit:newNote()
    self:flushTypeBuffer()
    self:save()   -- edit_note will close this editor without asking again
    self:handKeyboardTo(App.newNote(Config.path_parent(self.path)))
end
-- File: Save as (PALETTE_PLAN.md P2-1). Writes the document under a new name in
-- the same folder and keeps editing it there, leaving the original on disk as it
-- was at its last save.
function MDEdit:saveAs()
    self:flushTypeBuffer()
    local dlg
    dlg = InputDialog:new{
        title = _("Save as"),
        input = Text.path_base(self.path),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = Text.clean_entry_name(dlg:getInputText(), true)
                UIManager:close(dlg)
                if not name then Chrome.notify(_("Invalid name")); return end
                local path = Text.path_join(Config.path_parent(self.path), name)
                -- Saving under the name it already has is a plain Save, not a
                -- rename onto itself -- and must not trip the exists check below.
                if path == self.path then
                    if self:save() then Chrome.notify(_("Saved")) end
                    return
                end
                -- Refused rather than confirmed. The browser refuses a colliding
                -- name too, and silently overwriting another note from a text
                -- field with no undo is the wrong default for a destructive act.
                if lfs.attributes(path, "mode") then Chrome.notify(_("Name already exists")); return end
                self:saveToNewPath(path)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
    self:handKeyboardTo(dlg)
end
-- Retarget this editor at `new_path` and write there. Split out of saveAs so the
-- retarget-and-roll-back-on-failure sequence is readable on its own.
function MDEdit:saveToNewPath(new_path)
    local old_path = self.path
    self.path = new_path
    -- The old file's signature says nothing about a file that does not exist
    -- yet; leaving it would make the external-change poller compare the new
    -- path against the old file's mtime/size and announce a phantom edit.
    self._file_signature = nil
    if not self:save() then
        self.path = old_path
        self._file_signature = IO.file_signature(old_path)
        return false
    end
    -- The position entry is keyed by path, so the new file needs its own. The
    -- old key is deliberately left in place: that note still exists on disk with
    -- the content it had, and its remembered position is still true of it.
    self:savePosition()
    -- The title bar shows the basename, and topBar's cache key is built from
    -- width and mode only -- it does not notice a renamed document. Without this
    -- the note would keep its old name on screen until something else happened
    -- to change the width or the mode. (PALETTE_PLAN.md §6.2 fixes the key
    -- itself; until then, every path that renames the document owes this line.)
    self._topbar_cache = nil
    -- on_close still returns to the folder captured when the note was opened,
    -- which is the same folder: Save as cannot move a note between directories,
    -- because clean_entry_name rejects anything containing a slash.
    self:refresh{ layout_dirty = false, full = true }
    Chrome.notify(_("Saved as ") .. Text.path_base(new_path))
    return true
end
-- Help: About (PALETTE_PLAN.md P2-1). The version is minfolio_const's, not
-- _meta.lua's -- see the comment on C.VERSION for why the plan's original home
-- for it would have collided with every other plugin's _meta.
function MDEdit:showAbout()
    self:showInfo(table.concat({
        _("Minfolio") .. "  " .. C.VERSION,
        "",
        _("A live-styled Markdown editor for KOReader."),
        "",
        _("https://github.com/kbarni/minfolio.koplugin"),
        "",
        _("Default documents folder") .. ": " .. tostring(Config.NOTES_DIR),
        _("License") .. ": AGPL-3.0-only",
    }, "\n"))
end
function MDEdit:onCloseWidget()
    Chrome.trace("editor-close", "path=", tostring(self.path), "dirty=", self._dirty and "yes" or "no")
    self._closing = true
    -- Flush before signalling the worker. The old ordering removed the shadow
    -- first, then autosave recreated it, leaving an orphaned remote session.
    self:flushTypeBuffer()
    self:flushAutosave()
    self:savePosition()
    if self.remote then
        IO.write_file(self.remote.closing_path, "1")
        -- `remote-session.lua` is a shared handoff owned by the desktop
        -- launcher.  A successor session may already have replaced it while
        -- this editor is closing; deleting it here races that launch and can
        -- leave the new worker/editor with no descriptor. The per-session
        -- `closing` marker is the only state this editor owns.
    end
    App.clearActive(self)
    self._caret_blinking = false
    if self._caret_blink_pending then
        UIManager:unschedule(self._caret_blink_pending)
        self._caret_blink_pending = nil
    end
    if self._file_poll_pending then UIManager:unschedule(self._file_poll_pending); self._file_poll_pending = nil end
    if self._heartbeat_pending then UIManager:unschedule(self._heartbeat_pending); self._heartbeat_pending = nil end
    if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
    if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
    if self._physical_keyboard_repaint_pending then
        UIManager:unschedule(self._physical_keyboard_repaint_pending)
        self._physical_keyboard_repaint_pending = nil
    end
    if Device.input and self._old_disable_double_tap ~= nil then
        Device.input.disable_double_tap = self._old_disable_double_tap
    end
    -- Free every cached row's native TextWidget buffers, not just the ones
    -- currently on screen (UIManager's own close-time free only reaches the
    -- visible tree); off-screen rows are only reachable through this cache.
    if self._wrap_cache then
        for _, entry in pairs(self._wrap_cache) do free_wrap_entry(entry) end
        self._wrap_cache = nil
    end
end
function MDEdit:onKeyPress(key)
    local name = key and key.key
    if not name then return true end
    local m = Keys.key_mods(key)
    local lname = name:lower()
    -- Shortcuts that only READ the document are handled before the reader-mode
    -- branch below, because they are just as useful there. Everything that
    -- edits has to wait until after it (there is no caret in reader mode).
    if Keys.shortcut_mod(m) and #name == 1 then
        if lname == "f" then self:openFindDialog(); return true
        elseif lname == "g" then self:findNext(self._find_query, Keys.keymod(m, "Shift") and -1 or 1); return true
        elseif lname == "w" then self:showWordCount(); return true
        -- The palette is deliberately in this read-only group rather than the
        -- editing one below: it is the way to reach every command, and reader
        -- mode needs it at least as much as editing mode does. The model hides
        -- the commands that reader mode cannot run.
        elseif lname == "p" then self:openPalette(); return true
        end
    end
    if self.reader_mode then
        if Keys.left_key(name) or Keys.up_key(name) or Keys.page_up_key(name) then self:pageLeft()
        elseif Keys.right_key(name) or Keys.down_key(name) or name == "Space" or name == "space" or name == " "
            or name == "Press" or name == "Return" or name == "Enter" or name == "KP_Enter"
            or Keys.page_down_key(name) then self:pageRight()
        end
        return true
    end
    -- Editing shortcuts. An external keyboard is the recommended way to write
    -- on this thing, and reaching for the touchscreen to bold a word is the
    -- wrong shape -- every formatting action on the toolbar has a chord here.
    -- Shifted variants are tested inside their letter's branch (the Ctrl-Z /
    -- Ctrl-Shift-Z pattern already in place), so no letter needs two branches.
    if Keys.shortcut_mod(m) and #name == 1 then
        self:flushTypeBuffer()
        local shifted = Keys.keymod(m, "Shift")
        if lname == "z" then if shifted then self:redo() else self:undo() end; return true
        elseif lname == "y" then self:redo(); return true
        elseif lname == "c" then self:copy(); return true
        elseif lname == "x" then self:cut(); return true
        elseif lname == "v" then self:paste(); return true
        elseif lname == "a" then self:selectAll(); return true
        elseif lname == "b" then self:fmtWrap("**"); return true
        elseif lname == "i" then self:fmtWrap("*"); return true
        elseif lname == "e" then self:fmtWrap("`"); return true
        elseif lname == "h" then self:openReplaceDialog(); return true
        elseif lname == "s" then if self:save() then Chrome.notify(_("Saved")) end; return true
        elseif lname == "l" and shifted then self:fmtList(); return true
        elseif lname == "o" and shifted then self:fmtOrdered(); return true
        elseif lname == "t" and shifted then self:fmtTask(); return true
        elseif lname:match("^[0-6]$") then self:fmtHeadingLevel(tonumber(lname)); return true
        end
    end
    if name == "Backspace" or name == "BackSpace" or name == "Del" or name == "Delete" then
        self:flushTypeBuffer()
        if Keys.word_key_mod(m) then self:delWord() else self:delChar() end
    elseif name == "Press" or name == "Return" or name == "Enter" or name == "KP_Enter" then self:newline()
    elseif Keys.fn_key_mod(m) and Keys.up_key(name) then self:flushTypeBuffer(); self.sel = nil; self:pageUp()
    elseif Keys.fn_key_mod(m) and Keys.down_key(name) then self:flushTypeBuffer(); self.sel = nil; self:pageDown()
    elseif Keys.left_key(name)  then self:arrow(0, -1, m)
    elseif Keys.right_key(name) then self:arrow(0, 1, m)
    elseif Keys.up_key(name)    then self:arrow(-1, 0, m)
    elseif Keys.down_key(name)  then self:arrow(1, 0, m)
    elseif Keys.page_up_key(name) then self:flushTypeBuffer(); self.sel = nil; self:pageUp()
    elseif Keys.page_down_key(name) then self:flushTypeBuffer(); self.sel = nil; self:pageDown()
    elseif name == "Space" or name == "space" or name == " " then if Keys.keymod(m, "Alt") then self:flushTypeBuffer(); self.sel = nil; self:wordRight() else self:queueTypedChar(" ") end
    elseif name == "ISO_Left_Tab" or name == "BackTab" then self:flushTypeBuffer(); self:indentLine(-1)
    elseif name == "Tab" then
        self:flushTypeBuffer()
        if Keys.keymod(m, "Shift") then self:indentLine(-1)
        else
            local _, kind, _, task = MD.md_split_line_prefix(self.lines[self.crow])
            if kind or task then self:indentLine(1) else self:addChars("  ") end
        end
    elseif name == "Home" then self:flushTypeBuffer(); self:goToStartOfLine()
    elseif name == "End" then self:flushTypeBuffer(); self:goToEndOfLine()
    elseif Keys.KEYPAD_CHAR[name] then self:queueTypedChar(Keys.KEYPAD_CHAR[name])
    elseif #name == 1 then
        if Keys.keymod(m, "Alt") then return true end
        local ch = lname
        if Keys.keymod(m, "Shift") then
            if Keys.SHIFT_SYM[ch] then ch = Keys.SHIFT_SYM[ch] elseif ch:match("%a") then ch = ch:upper() end
        end
        self:queueTypedChar(ch)
    end
    return true
end
function MDEdit:onHold()
    if self.reader_mode then return true end
    -- A text-selection drag can briefly be classified as a hold before its pan
    -- events arrive. Keyboard visibility must not change during that gesture;
    -- use the deliberate downward swipe or the menu action to hide it instead.
    return true
end
function MDEdit:onSwipe(_, ges)
    -- A fast finger-lift after a reader-mode select comes through as a swipe
    -- rather than pan_release; commit the highlight here too so a quick drag works.
    if self._pan_mode == "rselect" then
        self._pan_mode = nil
        self:commitHighlightFromSelection()
        return true
    end
    -- Do not create or close the keyboard until this swipe has ended. Showing it
    -- from onPan places a new keyboard underneath the finger still performing
    -- the gesture, so its trailing touch-up can be interpreted as a key press.
    if self._pan_mode == "keyboard_reveal" then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active, self._pan_paged, self._pan_mode = nil, nil, nil
        self:showKeyboard()
        return true
    end
    if self._pan_mode == "keyboard_hide" then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active, self._pan_paged, self._pan_mode = nil, nil, nil
        self:hideKeyboard()
        return true
    end
    if self._pan_mode == "select" then self._pan_mode = nil; return true end
    if self:isKeyboardRevealGesture(ges) then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active = nil
        self._pan_paged = nil
        self._pan_mode = nil
        self:showKeyboard()
        return true
    end
    if self:isKeyboardHideGesture(ges) then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active = nil
        self._pan_paged = nil
        self._pan_mode = nil
        self:hideKeyboard()
        return true
    end
    -- Paging is handled in onPan, so swipes only clear the current gesture mode.
    -- Do not hide the keyboard on arbitrary south swipes (accidental ones are
    -- common while editing); the deliberate hide gesture above handles it.
    if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
    self._pan_active = nil
    self._pan_paged = nil
    self._pan_mode = nil
    return true
end
function MDEdit:bumpScale(d)
    self.scale = State.clamp_minfolio_scale(self.scale + d)
    State.MINFOLIO_STATE.scale = self.scale
    State.save_minfolio_state()
    self._wcache = {}; self._hcache = {}
    if self._wrap_cache then
        for _, entry in pairs(self._wrap_cache) do free_wrap_entry(entry) end
    end
    self._wrap_cache = nil          -- scale changes wrapping/heights; drop the per-line cache
    self:refresh()
end
function MDEdit:fmtWrap(mk)          -- wrap selection (or the cursor) in markers
    self:snapshot(); self._burst = nil
    if self:hasSel() then
        local lr, lc, hr, hc = self:selRange()
        if lr == hr then                -- wrap a single-line selection
            local l = self.lines[lr]
            self.lines[lr] = l:sub(1, lc) .. mk .. l:sub(lc+1, hc) .. mk .. l:sub(hc+1)
            self.crow = lr; self.ccol = hc + 2*#mk; self.sel = nil
            return self:refresh()
        end
    end
    local wl, wh = self:currentWordRange()
    if wl and wh then
        local l = self.lines[self.crow]
        self.lines[self.crow] = l:sub(1, wl) .. mk .. l:sub(wl+1, wh) .. mk .. l:sub(wh+1)
        self.ccol = wh + 2 * #mk
        return self:refresh()
    end
    local l = self.lines[self.crow]
    self.lines[self.crow] = l:sub(1, self.ccol) .. mk .. mk .. l:sub(self.ccol+1)
    self.ccol = self.ccol + #mk; self:refresh()
end
function MDEdit:setLinePrefix(kind, want_task)
    self:snapshot(); self._burst = nil
    local line = self.lines[self.crow]
    local indent, old_kind, marker, task, body = MD.md_split_line_prefix(line)
    local old_prefix = indent .. (marker or "") .. (task or "")
    local new_marker = marker or ""
    if kind == "bullet" then
        new_marker = old_kind == "bullet" and "" or "- "
    elseif kind == "ordered" then
        new_marker = old_kind == "ordered" and "" or "1. "
    end
    local new_task = task or ""
    if want_task ~= nil then new_task = want_task and "[ ] " or "" end
    local new_prefix = indent .. new_marker .. new_task
    self.lines[self.crow] = new_prefix .. body
    self.ccol = math.max(0, self.ccol + #new_prefix - #old_prefix)
    self:refresh()
end
-- Indent (dir > 0) or outdent (dir < 0) the current logical line by one level
-- (INDENT_UNIT). Nesting is stored as leading whitespace; layoutLine turns it
-- into visual indent. Returns true if the line changed.
function MDEdit:indentLine(dir)
    local INDENT_UNIT = "  "
    local line = self.lines[self.crow]
    local indent, rest = line:match("^(%s*)(.*)$")
    local new_indent
    if dir > 0 then
        new_indent = INDENT_UNIT .. indent
    elseif indent:sub(1, #INDENT_UNIT) == INDENT_UNIT then
        new_indent = indent:sub(#INDENT_UNIT + 1)
    elseif #indent > 0 then
        new_indent = ""                       -- collapse a stray partial indent
    else
        return false                          -- already at column 0, nothing to do
    end
    self:snapshot(); self._burst = nil
    local newline = new_indent .. rest
    self.lines[self.crow] = newline
    self.ccol = math.max(0, math.min(#newline, self.ccol + (#newline - #line)))
    self:refresh()
    return true
end
function MDEdit:fmtToggle(findpat, prefix)  -- remove existing line prefix, else add it
    self:snapshot(); self._burst = nil
    local l = self.lines[self.crow]
    local pre = l:match(findpat)
    if pre then self.lines[self.crow] = l:sub(#pre+1); self.ccol = math.max(0, self.ccol - #pre)
    else self.lines[self.crow] = prefix .. l; self.ccol = self.ccol + #prefix end
    self:refresh()
end
function MDEdit:fmtHeader() self:fmtToggle("^(#+%s)", "# ") end
-- Set the current line's heading level outright (Ctrl-1 .. Ctrl-6), rather than
-- toggling one level like fmtHeader: going from "## " to "### " by toolbar
-- means removing the heading and re-adding it. Level 0 -- and asking for the
-- level the line already has -- makes it an ordinary paragraph again, which is
-- what makes Ctrl-1 on an H1 behave like every other toggle in the editor.
--
-- Reads the prefix through MD.heading so the "#{1,6}" trap documented there
-- cannot be reintroduced here.
function MDEdit:fmtHeadingLevel(level)
    level = tonumber(level) or 0
    if level < 0 or level > 6 then return end
    local line = self.lines[self.crow] or ""
    local hashes, _unused, prefix = MD.heading(line)
    local old_len = (hashes and prefix) and #prefix or 0
    local body = line:sub(old_len + 1)
    local new_prefix = ""
    if level > 0 and not (hashes and #hashes == level) then
        new_prefix = string.rep("#", level) .. " "
    end
    if new_prefix == "" and old_len == 0 then return end   -- nothing to change
    self:snapshot(); self._burst = nil
    local newline = new_prefix .. body
    self.lines[self.crow] = newline
    self.ccol = math.max(0, math.min(#newline, self.ccol + #new_prefix - old_len))
    self._desired_x = nil
    self:refresh()
end
function MDEdit:fmtList()   self:setLinePrefix("bullet") end
function MDEdit:fmtOrdered() self:setLinePrefix("ordered") end
function MDEdit:fmtTask()
    local _, kind, _, task = MD.md_split_line_prefix(self.lines[self.crow])
    if task then
        self:setLinePrefix(nil, false)
    else
        self:setLinePrefix(kind and nil or "bullet", true)
    end
end
function MDEdit:insertTable()
    self:snapshot(); self._burst = nil
    if self:hasSel() then self:deleteSelection() end
    local rows = { "| Column 1 | Column 2 |", "|---|---|", "|  |  |" }
    local l = self.lines[self.crow] or ""
    local before, after = l:sub(1, self.ccol), l:sub(self.ccol + 1)
    local body_row
    if before == "" and after == "" then
        self.lines[self.crow] = rows[1]
        for i = 2, #rows do table.insert(self.lines, self.crow + i - 1, rows[i]) end
        body_row = self.crow + 2
    else
        self.lines[self.crow] = before
        local insert_at = self.crow
        for _, row in ipairs(rows) do
            insert_at = insert_at + 1
            table.insert(self.lines, insert_at, row)
        end
        if after ~= "" then table.insert(self.lines, insert_at + 1, after) end
        body_row = self.crow + 3
    end
    self.crow = math.min(#self.lines, body_row)
    self.ccol = math.min(2, #(self.lines[self.crow] or ""))
    self:refresh()
end
-- Style: Code block (PALETTE_PLAN.md P2-1). Fenced blocks have rendered since
-- 80c2943 but nothing inserted one; this mirrors insertTable above, including
-- its two cases -- an empty line is replaced in place, a line with text on it is
-- split around the block so nothing is swallowed.
--
-- The caret lands on the blank middle line, inside the fence. Landing it on the
-- opening ``` would put the next keystroke into the info string (the language
-- tag), which is not where anyone means to start typing code.
function MDEdit:insertCodeBlock()
    self:snapshot(); self._burst = nil
    if self:hasSel() then self:deleteSelection() end
    local rows = { "```", "", "```" }
    local l = self.lines[self.crow] or ""
    local before, after = l:sub(1, self.ccol), l:sub(self.ccol + 1)
    local body_row
    if before == "" and after == "" then
        self.lines[self.crow] = rows[1]
        for i = 2, #rows do table.insert(self.lines, self.crow + i - 1, rows[i]) end
        body_row = self.crow + 1
    else
        self.lines[self.crow] = before
        local insert_at = self.crow
        for _, row in ipairs(rows) do
            insert_at = insert_at + 1
            table.insert(self.lines, insert_at, row)
        end
        if after ~= "" then table.insert(self.lines, insert_at + 1, after) end
        body_row = self.crow + 2
    end
    self.crow = math.min(#self.lines, body_row)
    self.ccol = 0
    self:refresh()
end
function MDEdit:openMindmap()
    self:save()
    if self.keyboard then self:hideKeyboard() end
    local map = MindmapView:new{ editor = self }
    UIManager:show(map, "full")
end
function MDEdit:onTap(_, ges)
    local p = ges.pos
    if not p then return true end
    if self._pan_mode or self._pan_paged then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active = nil
        self._pan_paged = nil
        self._pan_mode = nil
        self._last_tap = nil
        return true
    end
    self._pan_mode = nil
    -- The native keyboard is non-modal so editor controls remain reachable.
    -- Never let a key tap also fall through to the document underneath it.
    if self:isPointInKeyboard(p) then return true end
    if p.y < 95 then                                          -- top bar
        local x = p.x - C.EDIT.MDEDIT_PAD
        for name, z in pairs(self.top_zones or {}) do
            if x >= z.x0 and x < z.x1 then self:runTopAction(name); return true end
        end
        return true
    end
    if self.reader_mode then
        -- Tapping on an existing highlight removes it (checked before the edge
        -- page-turn zones, so a highlight near a screen edge still deletes).
        if p.y >= 95 then
            local hrow, hcol = self:pointToCursor(p)
            if self:highlightRangeAt(hrow, hcol) then
                if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
                self._rtap = nil
                self:snapshot(); self._burst = nil
                self:removeHighlightAt(hrow, hcol)
                self:save()
                self:refresh{ lines = { hrow, hrow } }
                return true
            end
        end
        -- A tap on a checkbox ticks it in reader mode too -- reading down a list
        -- and ticking things off is most of what a task list is for. Checked
        -- BEFORE the edge page-turn zones for the same reason the highlight
        -- check above is: the box sits at the left margin, inside the left
        -- page-turn strip, so anywhere later and it could never be hit.
        local reader_task_row = self:taskBoxAtPos(p)
        if reader_task_row and self:toggleTaskAt(reader_task_row) then
            self._rtap = nil
            if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
            self:save()
            return true
        end
        -- Taps near the L/R/bottom edge are page-turns (likely scrolling), never
        -- an exit gesture -- page immediately, no double-tap delay.
        if p.x < C.EDIT.MDEDIT_READER_EDGE or p.x > self.fw - C.EDIT.MDEDIT_READER_EDGE
            or p.y > self.fh - C.EDIT.MDEDIT_READER_EDGE then
            self._rtap = nil
            if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
            self:pageFromTap(p)
            return true
        end
        local table_hit = self:tableCellAtPos(p)
        if table_hit then
            self:openTableCellEditor(table_hit)
            return true
        end
        local now = IO.now_seconds()
        if self._rtap and now - self._rtap.t < C.EDIT.MDEDIT_READER_DTAP
            and math.abs(p.x - self._rtap.x) < 40 and math.abs(p.y - self._rtap.y) < 40 then
            -- fast double tap: cancel the pending page turn, drop into edit mode
            -- with the cursor placed where the user tapped.
            self._rtap = nil
            if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
            local row, col = self:pointToCursor(p)
            self:setReaderMode(false, row, col)
            return true
        end
        self._rtap = { t = now, x = p.x, y = p.y }
        if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
        local pos = { x = p.x, y = p.y }
        local fn
        fn = function()
            if self._page_pending == fn then self._page_pending = nil end
            self:pageFromTap(pos)
        end
        self._page_pending = fn
        UIManager:scheduleIn(C.EDIT.MDEDIT_READER_DTAP, fn)
        return true
    end
    -- Checkboxes render as boxes in edit mode too, so a tap on one ticks it
    -- rather than dropping a caret into the "[ ]" behind the glyph. Clearing
    -- _last_tap keeps the toggle from counting as half of a double-tap, which
    -- would otherwise select a word on the second tick.
    local task_row = self:taskBoxAtPos(p)
    if task_row and self:toggleTaskAt(task_row) then
        self._last_tap = nil
        return true
    end
    -- Tables render as tables in edit mode too, so a tap on a cell edits that
    -- cell (rather than trying to drop a text caret into a rendered table).
    local table_hit = self:tableCellAtPos(p)
    if table_hit then
        self:openTableCellEditor(table_hit)
        return true
    end
    local now = IO.now_seconds()
    local tap_row, tap_col = self:pointToCursor(p)
    if self._last_tap and now - self._last_tap.t < C.EDIT.MDEDIT_EDIT_DTAP
        and math.abs(p.x - self._last_tap.x) < C.EDIT.MDEDIT_EDIT_DTAP_MOVE
        and math.abs(p.y - self._last_tap.y) < C.EDIT.MDEDIT_EDIT_DTAP_MOVE
        and tap_row == self._last_tap.row
        and tap_col == self._last_tap.col then
        self._last_tap = nil
        self:selectWordAt(p)
        return true
    end
    self._last_tap = { t = now, x = p.x, y = p.y, row = tap_row, col = tap_col }
    self.crow, self.ccol = tap_row, tap_col
    self._desired_x = nil
    self._manual_scroll_cursor = { row = self.crow, col = self.ccol }
    self.sel = nil; self:refresh{ layout_dirty = false, cursor_move = true }
    return true
end
function MDEdit:onDoubleTap(_, ges)
    -- Backup path: only reached if KOReader's double_tap is somehow active
    -- (we normally disable it and detect double-taps in onTap).
    self._pan_mode = nil
    if self.reader_mode then
        local p = ges.pos
        if p and p.y >= 95 and p.x >= C.EDIT.MDEDIT_READER_EDGE and p.x <= self.fw - C.EDIT.MDEDIT_READER_EDGE
            and p.y <= self.fh - C.EDIT.MDEDIT_READER_EDGE then
            local table_hit = self:tableCellAtPos(p)
            if table_hit then
                self:openTableCellEditor(table_hit)
                return true
            end
            local row, col = self:pointToCursor(p)
            self:setReaderMode(false, row, col)
        end
        return true
    end
    if ges.pos and ges.pos.y >= 95 then self:selectWordAt(ges.pos) end
    return true
end
function MDEdit:onPan(_, ges)
    local p = ges.pos
    local sp = ges.start_pos
    if not sp and p then
        if self._pan_active and self._pan_start_x and self._pan_start_y then
            sp = { x = self._pan_start_x, y = self._pan_start_y }
        else
            sp = p
        end
    end
    if not p or not sp or sp.y < 95 then return true end
    if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
    local reset
    reset = function()
        if self._pan_reset == reset then
            self._pan_reset = nil
            if self.reader_mode and self._pan_mode == "rselect" then
                self._pan_active = nil
                self._pan_paged = nil
                self._pan_mode = nil
                self:commitHighlightFromSelection()
                return
            end
            -- Keep a selection mode latched until the finger is released:
            -- otherwise a later pan update can be reclassified as vertical and
            -- turn the selection gesture into a page scroll.
            if not self.reader_mode and self._pan_mode == "select" then return end
            self._pan_active = nil
            self._pan_paged = nil
            self._pan_mode = nil
        end
    end
    self._pan_reset = reset
    UIManager:scheduleIn(self.reader_mode and 1.25 or 0.35, reset)
    local is_new_pan = not self._pan_active
        or (ges.start_pos and self._pan_start_x
            and (math.abs(sp.x - self._pan_start_x) > 2 or math.abs(sp.y - self._pan_start_y) > 2))
    -- KOReader occasionally reports a slightly different start_pos while the
    -- same finger is still dragging. Once a drag has become a text selection,
    -- that must never reset its mode until release: a reset lets the next
    -- vertical sample take the scroll branch.
    if is_new_pan and self._pan_mode ~= "select" then
        self._pan_active = true
        self._pan_start_x, self._pan_start_y = sp.x, sp.y
        self._pan_mode, self._pan_last_y, self._pan_paged = nil, sp.y, false
    end
    if self.reader_mode then
        local dx, dy = p.x - sp.x, p.y - sp.y
        local adx, ady = math.abs(dx), math.abs(dy)
        -- Already committed this drag to selecting: extend the selection to the
        -- finger, following it across lines. Vertical motion no longer pages here
        -- (the mode is latched), which is what lets a highlight span multiple lines.
        if self._pan_mode == "rselect" then
            local row, col = self:pointToCursor(p)
            self.crow, self.ccol = row, col
            self._manual_scroll_cursor = { row = row, col = col }
            self:refresh{ layout_dirty = false, selection = true }
            return true
        end
        if self._pan_mode == "rpage" then return true end
        if not self._pan_mode then
            if math.max(adx, ady) < C.EDIT.MDEDIT_SELECT_PAN_MIN then return true end
            if adx >= ady * 1.2 then
                -- Horizontal-dominant start -> select text (to become a highlight).
                self._pan_mode = "rselect"
                local sr, sc = self:pointToCursor(sp)
                self.sel = { row = sr, col = sc }
                local row, col = self:pointToCursor(p)
                self.crow, self.ccol = row, col
                self._manual_scroll_cursor = { row = row, col = col }
                self:refresh{ layout_dirty = false, selection = true }
            else
                -- Vertical-dominant start -> page (one turn per drag, then latch).
                self._pan_mode = "rpage"
                self.sel = nil
                if not self._pan_paged and ady >= C.EDIT.MDEDIT_PAGE_PAN_MIN then
                    self._pan_paged = true
                    if dy < 0 then self:pageDown() else self:pageUp() end
                end
            end
        end
        return true
    end
    local dx, dy = p.x - sp.x, p.y - sp.y
    local adx, ady = math.abs(dx), math.abs(dy)
    if self._pan_mode == "keyboard" then return true end
    if self:isKeyboardRevealGesture(ges) then
        self._pan_mode = "keyboard_reveal"
        self._pan_paged = true
        return true
    end
    if self:isKeyboardHideGesture(ges) then
        self._pan_mode = "keyboard_hide"
        self._pan_paged = true
        return true
    end
    if not self._pan_mode then
        if math.max(adx, ady) < C.EDIT.MDEDIT_SELECT_PAN_MIN then return true end
        if adx >= ady * 1.2 then
            self._pan_mode = "select"
            local sr, sc = self:pointToCursor(sp)
            self.sel = { row = sr, col = sc }
        elseif ady >= C.EDIT.MDEDIT_EDIT_SCROLL_PAN_MIN then
            self._pan_mode = "scroll"
            self.sel = nil
        else
            return true
        end
    end
    if self._pan_mode == "scroll" then
        -- One page turn per drag, then latch until the finger lifts.
        if not self._pan_paged then
            self._pan_paged = true
            if dy < 0 then self:pageDown() else self:pageUp() end
        end
        return true
    end
    local row, col = self:pointToCursor(p)
    self.crow, self.ccol = row, col
    -- The finger is placing the cursor, so pin the viewport to it (same as a tap):
    -- without this, rebuild() auto-scrolls to chase the cursor whenever the drag
    -- crosses onto an off-screen or partially-visible line. Next to a tall table
    -- that scroll is a full page jump, so a select-drag near a table reads as the
    -- page navigating up or down depending on which side of the fold the line sits.
    self._manual_scroll_cursor = { row = row, col = col }
    self:refresh{ layout_dirty = false, selection = true }
    return true
end
-- Finger lifted after a (slow) pan. In reader mode this ends a text selection, so
-- turn whatever was selected into a ==highlight==. Edit-mode selections persist
-- (cleared by the next tap), matching the previous behaviour.
function MDEdit:onPanRelease(_, ges)
    if self.reader_mode and self._pan_mode == "rselect" then
        self._pan_mode = nil
        self:commitHighlightFromSelection()
        return true
    end
    if self._pan_mode == "select" then
        if self._pan_reset then UIManager:unschedule(self._pan_reset); self._pan_reset = nil end
        self._pan_active, self._pan_paged, self._pan_mode = nil, nil, nil
        return true
    end
    return false   -- let other handlers (movable dialogs, etc.) see non-select releases
end
-- Wrap the current selection in == == markers, one span per logical line so a
-- multi-line selection produces valid per-line highlights. Whitespace at the ends
-- of each wrapped slice is left outside the markers, then the saved highlight is
-- expanded to the touched word boundaries so it never starts/stops mid-word.
function MDEdit:commitHighlightFromSelection()
    if not self:hasSel() then self.sel = nil; return self:refresh{ layout_dirty = false, selection = true } end
    local lr, lc, hr, hc = self:selRange()
    local function highlight_ranges(line, a, b)
        local toks = MD.md_tokenize(line)[1]
        local byte, ranges = 0, {}
        for _, span in ipairs(toks.spans or {}) do
            local raw = span.text or ""
            local display = span.display
            if display == nil then display = raw end
            local start_col, end_col = byte, byte + #raw
            if display ~= "" and span.style ~= "syntax" and span.style ~= "bullet" and span.style ~= "task" then
                if end_col > a and start_col < b then
                    local from = math.max(0, math.min(#raw, a - start_col))
                    local to = math.max(0, math.min(#raw, b - start_col))
                    local lo = Text.prev_word_col(raw, from)
                    local hi = Text.next_word_col(raw, to)
                    if lo == hi and #raw > 0 then lo, hi = 0, #raw end
                    if hi == 0 and #raw > 0 then hi = #raw end
                    if hi > lo then ranges[#ranges+1] = { start_col + lo, start_col + hi } end
                end
            end
            byte = end_col
        end
        return ranges
    end
    local function wrap_range(li, a, b)
        local line = self.lines[li]
        if not line then return end
        a = math.max(0, math.min(a, #line)); b = math.max(a, math.min(b, #line))
        local ranges = highlight_ranges(line, a, b)
        for k = #ranges, 1, -1 do
            local ra, rb = ranges[k][1], ranges[k][2]
            local slice = line:sub(ra + 1, rb)
            if not slice:find("==", 1, true) then         -- avoid nesting/doubling markers
                line = line:sub(1, ra) .. "==" .. slice .. "==" .. line:sub(rb + 1)
            end
        end
        self.lines[li] = line
    end
    self:snapshot(); self._burst = nil
    if lr == hr then
        wrap_range(lr, lc, hc)
    else
        -- Back-to-front so each edit leaves earlier lines' byte offsets intact.
        wrap_range(hr, 0, hc)
        for k = hr - 1, lr + 1, -1 do wrap_range(k, 0, #self.lines[k]) end
        wrap_range(lr, lc, #self.lines[lr])
    end
    self.sel = nil
    self:save()
    -- Only the wrapped lines changed (== is zero-width, so wrapping is unaffected);
    -- repaint just those rows rather than flashing the whole screen.
    self:refresh{ lines = { lr, hr } }
end
-- If byte column `col` on line `line_i` falls inside a ==...== region, return the
-- 1-based byte indices of the opening and closing '==' markers; else nil.
function MDEdit:highlightRangeAt(line_i, col)
    local line = self.lines[line_i]
    if not line then return nil end
    local pos = 1
    while true do
        local s = line:find("==", pos, true)
        if not s then return nil end
        local e = line:find("==", s + 2, true)
        if not e then return nil end
        -- Hit if the cursor byte offset lands anywhere from the opening marker
        -- through the closing marker (inclusive of both == pairs).
        if col >= s - 1 and col <= e + 1 then return s, e end
        pos = e + 2
    end
end
-- Strip the ==...== markers of the highlight containing `col`, keeping the text.
function MDEdit:removeHighlightAt(line_i, col)
    local s, e = self:highlightRangeAt(line_i, col)
    if not s then return false end
    local line = self.lines[line_i]
    line = line:sub(1, e - 1) .. line:sub(e + 2)          -- drop closing == first (higher index)
    line = line:sub(1, s - 1) .. line:sub(s + 2)          -- then the opening ==
    self.lines[line_i] = line
    return true
end

-- Mixin assembly (PLAN.md §6.2): fold each mixin's methods into this class's
-- own table. `rawget` (not plain indexing) is essential here -- `InputContainer
-- :extend{}` chains `__index`, so plain `MDEdit[name] == nil` would resolve
-- *inherited* methods as non-nil and reject a legitimate override (MDEdit
-- overrides at least `onKeyPress` and `onPhysicalKeyboardDisconnected`, both
-- defined upstream on InputContainer); `rawget` checks only this class's own
-- table, so an override passes and a genuine duplicate still fails loudly.
for _, mixin in ipairs({ require("minfolio_edit_layout"),
                         require("minfolio_edit_tables"),
                         require("minfolio_edit_view") }) do
    for name, fn in pairs(mixin.methods) do
        assert(rawget(MDEdit, name) == nil, "duplicate MDEdit method: " .. name)
        MDEdit[name] = fn
    end
end

return MDEdit
