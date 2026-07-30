-- SPDX-License-Identifier: AGPL-3.0-only
-- minfolio_edit_view: the rendering/repaint mixin for MDEdit (PLAN.md §5
-- Tier 4, §10 step 8). `rebuild` (the full widget-tree build), `refresh`
-- and its dirty-region family (lineBand/cursorRowBand/changedLineRegions/
-- the region* helpers), caret blink (caret/scheduleCaretBlink/
-- pauseCaretBlinkForInput), and the top bar (buildTopBar/topBar/toolCell/
-- toolDivider/menuGlyph/runTopAction/openControls) and progress bar.
--
-- Mixin shape (PLAN.md §6.2): `local MDEdit = {}` below is a local proxy
-- table, not the real editor class -- see minfolio_edit_layout.lua's header
-- for the full rationale, which applies identically here. `return` produces
-- `{ methods = MDEdit }`; this mixin has no plain cross-boundary helpers, so
-- unlike minfolio_edit_layout there is no `fns` table to export.
--
-- Ported verbatim from main.lua / minfolio_edit.lua (PLAN.md §5 Tier 4, §10
-- step 8): the 28 methods assigned to this module by INVENTORY.md §1's
-- method map. Method bodies are unedited; only each declaration line's
-- receiver (`MDEdit` -> the local proxy of the same name) changed.
--
-- Required by minfolio_edit.lua as `local View = require("minfolio_edit_view")`.

local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local IconWidget = require("ui/widget/iconwidget")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")

local Text = require("minfolio_text")
local IO = require("minfolio_io")
local Style = require("minfolio_style")
local C = require("minfolio_const")
local Chrome = require("minfolio_chrome")

local MDEdit = {}
-- a thin caret bar that sits between styled spans without disturbing them
function MDEdit:caret(h)
    return LineWidget:new{ background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = 3, h = h or math.floor(32 * self.scale) } }
end
function MDEdit:scheduleCaretBlink(delay)
    if self._caret_blink_pending then
        UIManager:unschedule(self._caret_blink_pending)
        self._caret_blink_pending = nil
    end
    local fn
    fn = function()
        if self._caret_blink_pending == fn then self._caret_blink_pending = nil end
        if not self._caret_blinking then return end
        if self.reader_mode then
            self.caret_on = false
            self:scheduleCaretBlink()
            return
        end
        local prev_vtop = self.vtop
        local prev_caret = self.caret_region
        self.caret_on = not self.caret_on
        self:rebuild()
        local region
        if prev_vtop and self.vtop and prev_vtop ~= self.vtop then
            region = self.editor_body_region
        else
            region = self:unionRegion(prev_caret, self.caret_region)
        end
        local dirty_full = false
        if self._last_dirty_at and IO.now_seconds() - self._last_dirty_at < C.EDIT.MDEDIT_CARET_BLINK then
            if self._last_dirty_full then
                dirty_full = true
                region = nil
            else
                region = self:unionRegion(self._last_dirty_region, region)
            end
        end
        if dirty_full or region then UIManager:setDirty(self, "ui", region) end
        self:scheduleCaretBlink()
    end
    self._caret_blink_pending = fn
    UIManager:scheduleIn(delay or C.EDIT.MDEDIT_CARET_BLINK, fn)
end
-- Keep a solid caret throughout an input burst. Besides being easier to follow,
-- this prevents the blink timer from doing a second full widget rebuild while a
-- typing repaint is already in flight. Each key resets the idle countdown; the
-- first post-input blink happens only after the burst has settled.
function MDEdit:pauseCaretBlinkForInput()
    if not self._caret_blinking or self.reader_mode then return end
    self.caret_on = true
    self:scheduleCaretBlink(C.EDIT.MDEDIT_CARET_RESUME_DELAY)
end
function MDEdit:toolCell(lbl, fnt, sz, w)
    w = w or C.EDIT.MDEDIT_TOOL_MIN_CELL
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = C.EDIT.MDEDIT_TOPBAR_H },
            TextWidget:new{ text = lbl, face = Font:getFace(fnt or "tfont", sz or 24), fgcolor = Blitbuffer.COLOR_BLACK } } }
end
function MDEdit:toolDivider()
    return CenterContainer:new{ dimen = Geom:new{ w = C.EDIT.MDEDIT_TOOL_DIVIDER, h = C.EDIT.MDEDIT_TOPBAR_H },
        LineWidget:new{ background = Blitbuffer.Color8(205), dimen = Geom:new{ w = C.EDIT.MDEDIT_TOOL_DIVIDER, h = math.floor(C.EDIT.MDEDIT_TOPBAR_H * 0.62) } } }
end
function MDEdit:progressBar(width)
    local visual_count = self.visual_count or #self.lines
    local visible = self.visible_vrows or 16
    local w = math.max(1, width or 1)
    local filled = w
    if visual_count > visible then
        local bottom = math.min(visual_count, (self.vtop or 1) + visible - 1)
        filled = math.max(1, math.min(w, math.floor(w * bottom / visual_count)))
    end
    local parts = { align = "top" }
    if filled > 0 then
        parts[#parts+1] = LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = filled, h = C.EDIT.MDEDIT_PROGRESS_H },
        }
    end
    if filled < w then
        parts[#parts+1] = LineWidget:new{
            background = Blitbuffer.Color8(205),
            dimen = Geom:new{ w = w - filled, h = C.EDIT.MDEDIT_PROGRESS_H },
        }
    end
    return HorizontalGroup:new(parts)
end
function MDEdit:menuGlyph()
    -- Same "appbar.menu" icon KOReader's own title bars use, so this matches
    -- the hamburger on the file-listing screen instead of a hand-drawn glyph.
    return CenterContainer:new{ dimen = Geom:new{ w = C.EDIT.MDEDIT_MENU_W, h = C.EDIT.MDEDIT_TOPBAR_H },
        IconWidget:new{ icon = "appbar.menu", width = Screen:scaleBySize(24), height = Screen:scaleBySize(24) } }
end
function MDEdit:buildTopBar(cw)
    local title_face = Font:getFace("cfont", 22)
    local raw_title = self.path:match("[^/]+$") or "note"
    self.top_zones = {}
    -- Find is a temporary mode: its compact controls replace the formatting
    -- toolbar, leaving a persistent query field and touch-sized navigation
    -- targets instead of obscuring the document with a dialog.
    if self._find_bar_visible then
        local action_face = Font:getFace("tfont", 21)
        local prev_w = math.max(C.EDIT.MDEDIT_TOOL_MIN_CELL, self:textw("Previous", action_face) + 18)
        local next_w = math.max(C.EDIT.MDEDIT_TOOL_MIN_CELL, self:textw("Next", action_face) + 18)
        local done_w = math.max(C.EDIT.MDEDIT_TOOL_MIN_CELL, self:textw("Done", action_face) + 18)
        local query_w = math.max(80, cw - prev_w - next_w - done_w)
        local query = self:trimToWidth((self._find_query and self._find_query ~= "")
            and ("Find: " .. self._find_query) or "Find: enter text", query_w - 16, title_face)
        local x = 0
        self.top_zones.find_input = { x0 = x, x1 = x + query_w }; x = x + query_w
        self.top_zones.find_previous = { x0 = x, x1 = x + prev_w }; x = x + prev_w
        self.top_zones.find_next = { x0 = x, x1 = x + next_w }; x = x + next_w
        self.top_zones.find_done = { x0 = x, x1 = x + done_w }
        return HorizontalGroup:new{ align = "center",
            FrameContainer:new{ bordersize = 1, padding = 5, margin = 0, width = query_w, height = C.EDIT.MDEDIT_TOPBAR_H,
                CenterContainer:new{ dimen = Geom:new{ w = query_w - 12, h = C.EDIT.MDEDIT_TOPBAR_H - 2 },
                    TextWidget:new{ text = query, face = title_face, fgcolor = Blitbuffer.COLOR_BLACK } } },
            self:toolCell("Previous", "tfont", 21, prev_w),
            self:toolCell("Next", "tfont", 21, next_w),
            self:toolCell("Done", "tfont", 21, done_w),
        }
    end
    if self.reader_mode then
        -- Reader mode: no formatting toolbar. A single explicit "Edit" button so
        -- the reader never has to guess the double-tap gesture.
        local edit_face = Font:getFace("tfont", 24)
        local edit_w = math.max(C.EDIT.MDEDIT_TOOL_MIN_CELL, self:textw("Edit", edit_face) + 28)
        local max_title_w = math.max(80, cw - C.EDIT.MDEDIT_MENU_W - edit_w - C.EDIT.MDEDIT_TITLE_ACTION_GAP)
        local title = self:trimToWidth(raw_title, max_title_w, title_face)
        local title_w = self:textw(title, title_face)
        local gap_w = math.max(C.EDIT.MDEDIT_TITLE_ACTION_GAP, cw - C.EDIT.MDEDIT_MENU_W - title_w - edit_w)
        local x = C.EDIT.MDEDIT_MENU_W
        self.top_zones.menu = { x0 = 0, x1 = C.EDIT.MDEDIT_MENU_W }
        x = x + title_w + gap_w
        self.top_zones.edit = { x0 = x, x1 = x + edit_w }
        return HorizontalGroup:new{ align = "center",
            self:menuGlyph(),
            CenterContainer:new{ dimen = Geom:new{ w = title_w, h = C.EDIT.MDEDIT_TOPBAR_H },
                TextWidget:new{ text = title, face = title_face, fgcolor = Blitbuffer.Color8(110) } },
            HorizontalSpan:new{ width = gap_w },
            CenterContainer:new{ dimen = Geom:new{ w = edit_w, h = C.EDIT.MDEDIT_TOPBAR_H },
                TextWidget:new{ text = "Edit", face = edit_face, fgcolor = Blitbuffer.COLOR_BLACK } },
        }
    end
    -- Reader glyph is a rectangle split into two columns (◫, vertical bisecting
    -- line) so it reads as a two-column page rather than many thin bars.
    local tools = { "H", "B", "I", "\226\128\162", "1.", "\226\152\144", "\226\151\171" }
    local divider_w = #tools * C.EDIT.MDEDIT_TOOL_DIVIDER
    local min_action_w = ((#tools + 1) * C.EDIT.MDEDIT_TOOL_MIN_CELL) + divider_w
    local max_title_w = math.min(C.EDIT.MDEDIT_TITLE_W, math.max(80, cw - C.EDIT.MDEDIT_MENU_W - min_action_w - C.EDIT.MDEDIT_TITLE_ACTION_GAP))
    local title = self:trimToWidth(raw_title, max_title_w, title_face)
    local title_w = self:textw(title, title_face)
    local gap_w = math.min(C.EDIT.MDEDIT_TITLE_ACTION_GAP, math.max(0, cw - C.EDIT.MDEDIT_MENU_W - title_w - min_action_w))
    local action_w = math.max(min_action_w, cw - C.EDIT.MDEDIT_MENU_W - title_w - gap_w)
    local tool_cell_w = math.max(C.EDIT.MDEDIT_TOOL_MIN_CELL, math.floor((action_w - divider_w) / (#tools + 1)))
    action_w = tool_cell_w * (#tools + 1) + divider_w
    local x = C.EDIT.MDEDIT_MENU_W
    self.top_zones.menu = { x0 = 0, x1 = C.EDIT.MDEDIT_MENU_W }
    local title_widget = CenterContainer:new{ dimen = Geom:new{ w = title_w, h = C.EDIT.MDEDIT_TOPBAR_H },
        TextWidget:new{ text = title, face = title_face, fgcolor = Blitbuffer.Color8(110) } }
    x = x + title_w + gap_w
    local tool_widgets = {}
    local tool_names = { "header", "bold", "italic", "list", "ordered", "task", "reader" }
    for i, lbl in ipairs(tools) do
        if i > 1 then
            tool_widgets[#tool_widgets+1] = self:toolDivider()
            x = x + C.EDIT.MDEDIT_TOOL_DIVIDER
        end
        self.top_zones[tool_names[i]] = { x0 = x, x1 = x + tool_cell_w }
        local glyph_tool = i == 6 or i == 8   -- checkbox + reader glyphs render from cfont
        tool_widgets[#tool_widgets+1] = self:toolCell(lbl, glyph_tool and "cfont" or "tfont", glyph_tool and 24 or 23, tool_cell_w)
        x = x + tool_cell_w
    end
    x = x + C.EDIT.MDEDIT_TOOL_DIVIDER
    self.top_zones.close = { x0 = x, x1 = x + tool_cell_w }
    return HorizontalGroup:new{ align = "center",
        self:menuGlyph(),
        title_widget,
        HorizontalSpan:new{ width = gap_w },
        HorizontalGroup:new(tool_widgets),
        self:toolDivider(),
        self:toolCell("\226\156\149", "cfont", 30, tool_cell_w),
    }
end
-- The toolbar/title subtree is static during typing, yet rebuilding it shapes the
-- same title and eight tool glyphs again for every input flush and caret blink.
-- Reuse it until width or mode changes; keep the matching hit zones with it.
function MDEdit:topBar(cw)
    -- Tag the find component rather than storing the bare query: an empty query
    -- is a real find-bar state ("Find: enter text"), and it must not collide
    -- with the no-find-bar key or the cache serves the wrong bar and hit zones.
    local key = table.concat({ tostring(cw), self.reader_mode and "reader" or "edit",
        self._find_bar_visible and ("find:" .. (self._find_query or "")) or "nofind" }, "|")
    local cached = self._topbar_cache
    if cached and cached.key == key then
        self.top_zones = cached.zones
        return cached.widget
    end
    local widget = self:buildTopBar(cw)
    self._topbar_cache = { key = key, widget = widget, zones = self.top_zones }
    return widget
end
-- Rendering a row shapes glyphs into TextWidgets, which hold native (malloc'ed)
-- buffers that only :free() releases promptly -- Lua's GC won't get to them in
-- time. rebuild() re-renders every visible row on every scroll/cursor-move/caret
-- blink, so without this cache we'd shape fresh glyphs (and leak the old ones)
-- many times a second. A row's identity is stable across those redraws (see the
-- wrap cache in computeVisualRows below); only its own text or a scale change
-- actually needs a re-render.
function MDEdit:renderRow(row)
    if #row.segs == 0 then return VerticalSpan:new{ width = 2 } end
    if row._rendered and row._rendered_scale == self.scale then return row._rendered end
    if row._rendered then row._rendered:free() end
    local hg = HorizontalGroup:new{ align = "top" }
    if row.indent and row.indent > 0 then hg[#hg+1] = HorizontalSpan:new{ width = row.indent } end
    for _, seg in ipairs(row.segs) do
        local display = seg.display
        if display == nil then display = seg.text end
        if display ~= "" then
            hg[#hg+1] = TextWidget:new{ text = display,
                face = Style.md_face(seg.style, self.scale), fgcolor = Style.md_color(seg.style) }
        end
    end
    row._rendered, row._rendered_scale = hg, self.scale
    return hg
end
function MDEdit:rebuild()
    local cw = self.fw - (C.EDIT.MDEDIT_PAD * 2)
    local text_w = self:textWidth()
    local topbar = self:topBar(cw)
    local vg = VerticalGroup:new{ align = "left", topbar, VerticalSpan:new{ width = C.EDIT.MDEDIT_TOPBAR_GAP } }
    local kbd_h = 0
    if self.keyboard then
        kbd_h = self.keyboard.dimen and self.keyboard.dimen.h or math.floor(self.fh * 0.36)
    end
    local editor_top = C.EDIT.MDEDIT_PAD + C.EDIT.MDEDIT_TOPBAR_H + C.EDIT.MDEDIT_TOPBAR_GAP
    local progress_area = C.EDIT.MDEDIT_PROGRESS_GAP + C.EDIT.MDEDIT_PROGRESS_H
    -- The repaint area always runs from the top down to the keyboard's top edge
    -- (or the whole screen when no keyboard is up). Text, though, stops short of
    -- that: with the keyboard up the progress bar and the frame's bottom padding
    -- are hidden behind it and aren't needed, so text may run down to just above
    -- the keyboard (leaving only C.EDIT.MDEDIT_KBD_TEXT_GAP); otherwise it leaves room for
    -- the pinned progress bar and the bottom padding.
    local refresh_bottom = self.fh - kbd_h
    local body_bottom = self.keyboard and (refresh_bottom - C.EDIT.MDEDIT_KBD_TEXT_GAP)
        or (self.fh - C.EDIT.MDEDIT_PAD - progress_area)
    local budget = body_bottom - editor_top
    self.visible_budget = budget
    local body = VerticalGroup:new{ align = "left" }
    local visual_rows = self:visualRows(text_w)
    self.visual_count = #visual_rows
    self.vtop = math.max(1, math.min(self.visual_count, self.vtop or 1))
    local cursor_vi, cursor_cx
    if not self.reader_mode then cursor_vi, cursor_cx = self:cursorVisual(visual_rows) end
    local manual_scroll = self._manual_scroll_cursor
        and self._manual_scroll_cursor.row == self.crow
        and self._manual_scroll_cursor.col == self.ccol
    if self._manual_scroll_cursor and not manual_scroll then self._manual_scroll_cursor = nil end
    if not self.reader_mode and cursor_vi and not manual_scroll then
        if cursor_vi < self.vtop then self.vtop = cursor_vi end
        local used_to_cursor = 0
        for vi = self.vtop, cursor_vi do
            used_to_cursor = used_to_cursor + self:visualRowHeight(visual_rows[vi])
        end
        while self.vtop < cursor_vi and used_to_cursor > budget do
            used_to_cursor = used_to_cursor - self:visualRowHeight(visual_rows[self.vtop])
            self.vtop = self.vtop + 1
        end
    end
    self.row_map = {}
    self.caret_region = nil
    local ytop, used, shown = editor_top, 0, 0
    for vi = self.vtop, #visual_rows do
        local vr = visual_rows[vi]
        if vr.kind == "gap" then
            if used + vr.h > budget then break end
            body[#body+1] = VerticalSpan:new{ width = vr.h }
            used = used + vr.h
            shown = shown + 1
        elseif vr.kind == "table_row" then
            local rowh = vr.h
            if used + rowh > budget then break end
            body[#body+1] = self:renderTableRow(vr)
            self.row_map[#self.row_map+1] = {
                y0 = ytop + used,
                y1 = ytop + used + rowh,
                line = vr.line,
                table = vr.table,
                cells = vr.cells,
                col_widths = vr.col_widths,
            }
            used = used + rowh
            shown = shown + 1
        else
            local i, row = vr.line, vr.row
            local texth = self:rowTextHeight(row)
            local rowh = self:rowHeight(row, vr.block)
            local text_y = math.max(0, math.floor((rowh - texth) / 2))
            if used + rowh > budget then break end
            local slo, shi = self:lineSel(i)
            local args = { dimen = Geom:new{ w = text_w, h = rowh } }
            -- Persistent ==highlight== fill, drawn behind the text in every mode.
            -- Contiguous highlight segments are merged into one bar so word gaps
            -- don't leave hairline seams. (Selection, added next, paints on top.)
            local hx, hstart = row.indent or 0, nil
            local function flush_hl(xend)
                if hstart and xend > hstart then
                    args[#args+1] = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = hstart },
                        LineWidget:new{ background = C.EDIT.MDEDIT_HIGHLIGHT_GRAY, dimen = Geom:new{ w = math.max(2, xend - hstart), h = rowh } } }
                end
                hstart = nil
            end
            for _, seg in ipairs(row.segs) do
                if seg.hl then
                    -- Keep the run open across hidden zero-width inner markers (the
                    -- **/`/* of nested styles) so the fill is one continuous bar.
                    if (seg.w or 0) > 0 and not hstart then hstart = hx end
                else
                    flush_hl(hx)
                end
                hx = hx + (seg.w or 0)
            end
            flush_hl(hx)
            if slo then                                   -- selection highlight, drawn behind the text
                local rb = row.sb
                for _, sg in ipairs(row.segs) do rb = rb + #sg.text end
                local a, b = math.max(slo, row.sb), math.min(shi, rb)
                if a < b then
                    local x0, x1 = self:rowXAt(row, a), self:rowXAt(row, b)
                    args[#args+1] = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = x0 },
                        LineWidget:new{ background = Blitbuffer.Color8(205), dimen = Geom:new{ w = math.max(2, x1 - x0), h = rowh } } }
                end
            end
            args[#args+1] = VerticalGroup:new{ VerticalSpan:new{ width = text_y }, self:renderRow(row) }
            if vi == cursor_vi and cursor_cx and not self.reader_mode then
                local caret_h = math.max(18, math.min(rowh - 2, texth))
                local caret_y = math.max(0, text_y + math.floor((texth - caret_h) / 2))
                if self.caret_on then
                    args[#args+1] = VerticalGroup:new{
                        VerticalSpan:new{ width = caret_y },
                        HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = cursor_cx }, self:caret(caret_h) },
                    }
                end
                self.caret_region = Geom:new{
                    x = C.EDIT.MDEDIT_PAD + cursor_cx - 2, y = ytop + used + caret_y, w = 7, h = caret_h,
                }
            end
            body[#body+1] = OverlapGroup:new(args)
            self.row_map[#self.row_map+1] = { y0 = ytop + used, y1 = ytop + used + rowh, line = i, row = row }
            used = used + rowh
            shown = shown + 1
        end
    end
    self.visible_vrows = math.max(1, shown)   -- visual entries (rows+gaps) on screen
    self.top = self.row_map[1] and self.row_map[1].line or 1
    vg[#vg+1] = body
    self.editor_refresh_region = Geom:new{
        x = 0, y = 0, w = self.fw,
        h = math.max(1, refresh_bottom),
    }
    -- Same as editor_refresh_region but starting below the top bar. The toolbar/
    -- title never change while scrolling, selecting, or reflowing text, so those
    -- repaints should leave it untouched (no e-ink flash of a stable strip).
    self.editor_body_region = Geom:new{
        x = 0, y = editor_top, w = self.fw,
        h = math.max(1, refresh_bottom - editor_top),
    }
    -- The progress bar is pinned to the very bottom of the screen (below the text
    -- frame's padding) so it holds a fixed position regardless of how much text is
    -- on screen, and never crowds the last line. It's dropped entirely while the
    -- keyboard is up -- it would only sit hidden behind the keys, and skipping it
    -- frees that strip for text.
    local layers = OverlapGroup:new{
        dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh },
        FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = C.EDIT.MDEDIT_PAD,
            width = self.fw, height = self.fh, vg },
    }
    if not self.keyboard then
        layers[#layers+1] = BottomContainer:new{ dimen = Geom:new{ w = self.fw, h = self.fh - 5 }, self:progressBar(cw) }
    end
    self[1] = layers
end
-- Bounding bands (full width) of logical-line rows, for narrow e-ink refreshes
-- while typing.
function MDEdit:lineBand(row)
    local y0, y1
    for _, rm in ipairs(self.row_map or {}) do
        if rm.line == row then
            y0 = math.min(y0 or rm.y0, rm.y0)
            y1 = math.max(y1 or rm.y1, rm.y1)
        end
    end
    if not y0 then return nil end
    return Geom:new{ x = 0, y = math.max(0, y0 - 2), w = self.fw, h = (y1 - y0) + 10 }
end
-- Band (full width) from the cursor's own visual row down through the rest of the
-- current logical line. A same-line edit changes the cursor's row AND can rewrap
-- the rows after it within the line (a word crossing the wrap boundary), but never
-- the rows above the cursor -- so this is the tightest region that stays correct.
-- (When the line's height changes, content below shifts too; that's the reflow
-- path, which repaints from here down to the bottom.)
function MDEdit:cursorRowBand()
    local y0, y1
    for _, rm in ipairs(self.row_map or {}) do
        if rm.line == self.crow and rm.row then
            local sb = rm.row.sb or 0
            local rb = sb
            for _, sg in ipairs(rm.row.segs or {}) do rb = rb + #(sg.text or "") end
            if not y0 then
                if self.ccol >= sb and self.ccol <= rb then y0, y1 = rm.y0, rm.y1 end
            else
                y1 = math.max(y1, rm.y1)   -- extend through later rows of the same line
            end
        end
    end
    if not y0 then return self:lineBand(self.crow) end   -- fallback: whole line
    return Geom:new{ x = 0, y = math.max(0, y0 - 2), w = self.fw, h = (y1 - y0) + 10 }
end
-- Stable description of the pixels produced by one wrapped text row. Comparing
-- these before and after a local edit lets us skip wrapped rows whose contents did
-- not actually move. Geometry is compared separately when building the region.
function MDEdit:rowPaintKey(rm)
    if not (rm and rm.row) then return nil end
    local row = rm.row
    local parts = {
        tostring(row.indent or 0), tostring(row.w or 0),
    }
    for _, seg in ipairs(row.segs or {}) do
        local visible = seg.display == nil and (seg.text or "") or seg.display
        parts[#parts+1] = table.concat({
            visible, seg.style or "", seg.hl and "1" or "0", tostring(seg.w or 0),
        }, "\2")
    end
    return table.concat(parts, "\3")
end
-- Rendered prefix before an absolute source column. This catches Markdown edits
-- that restyle text to the left of the insertion point (for example completing a
-- closing ** marker), where starting the refresh at the caret would be incorrect.
function MDEdit:rowPrefixPaintKey(row, col)
    local parts, byte = { tostring(row.indent or 0) }, row.sb or 0
    for _, seg in ipairs(row.segs or {}) do
        local raw = seg.text or ""
        local take = math.max(0, math.min(#raw, (col or byte) - byte))
        if take > 0 then
            local visible
            -- layoutLine stores ordinary text with display == raw. Treat that as
            -- directly sliceable text; only genuinely synthetic/hidden display
            -- values (bullets, task boxes, Markdown markers) need all-or-nothing
            -- handling. Misclassifying display == raw made edits at a word end
            -- look like the rendered prefix changed and widened the dirty row to
            -- x = 0, flashing all text to the left of the cursor.
            if seg.display == nil or seg.display == raw then
                visible = raw:sub(1, take)
            elseif take >= #raw then
                visible = seg.display
            else
                visible = "" -- hidden/synthetic markers have no useful partial glyph prefix
            end
            parts[#parts+1] = table.concat({
                visible, seg.style or "", seg.hl and "1" or "0",
            }, "\2")
        end
        byte = byte + #raw
        if byte >= (col or byte) then break end
    end
    return table.concat(parts, "\3")
end
-- X position of the UTF-8 character immediately before an absolute source
-- column within this visual row. Starting precise refreshes here protects the
-- preceding glyph's edge/kerning pixels from being left white by e-ink updates.
function MDEdit:previousGlyphX(row, col)
    local raw = {}
    for _, seg in ipairs(row.segs or {}) do raw[#raw+1] = seg.text or "" end
    raw = table.concat(raw)
    local local_col = math.max(0, math.min(#raw, (col or row.sb or 0) - (row.sb or 0)))
    local prev_col = Text.utf8_left(raw, local_col)
    return self:rowXAt(row, (row.sb or 0) + prev_col)
end
-- Regions changed by an insertion/deletion within one logical line. The first
-- affected row starts at the earlier old/new edit position; later rows are only
-- included when wrapping actually changed their rendered pixels. Extending each
-- changed tail to the right edge is deliberate: narrower e-ink updates left stale
-- glyph fragments, but there is no reason to repaint unchanged rows below it.
function MDEdit:changedLineRegions(prev_row_map, row_map, row, prev_col, col)
    local old, new = {}, {}
    for _, rm in ipairs(prev_row_map or {}) do
        if rm.line == row and rm.row then old[#old+1] = rm end
    end
    for _, rm in ipairs(row_map or {}) do
        if rm.line == row and rm.row then new[#new+1] = rm end
    end
    if #old == 0 or #old ~= #new then return nil end

    local regions = {}
    for i = 1, #old do
        local before, after = old[i], new[i]
        if self:rowPaintKey(before) ~= self:rowPaintKey(after)
            or before.y0 ~= after.y0 or before.y1 ~= after.y1 then
            local x = 0
            local old_sb = before.row.sb or 0
            local new_sb = after.row.sb or 0
            local old_rb, new_rb = old_sb, new_sb
            for _, seg in ipairs(before.row.segs or {}) do old_rb = old_rb + #(seg.text or "") end
            for _, seg in ipairs(after.row.segs or {}) do new_rb = new_rb + #(seg.text or "") end
            local old_here = prev_col and prev_col >= old_sb and prev_col <= old_rb
            local new_here = col and col >= new_sb and col <= new_rb
            if old_here or new_here then
                local change_col = math.min(prev_col or col or 0, col or prev_col or 0)
                local prefix_changed = self:rowPrefixPaintKey(before.row, change_col)
                    ~= self:rowPrefixPaintKey(after.row, change_col)
                if not prefix_changed then
                    local old_x = change_col >= old_sb and change_col <= old_rb
                        and self:previousGlyphX(before.row, change_col) or nil
                    local new_x = change_col >= new_sb and change_col <= new_rb
                        and self:previousGlyphX(after.row, change_col) or nil
                    local edit_x = old_x and new_x and math.min(old_x, new_x) or old_x or new_x or 0
                    x = math.max(0, C.EDIT.MDEDIT_PAD + edit_x - 2)
                end
            end
            local y0 = math.max(0, math.min(before.y0, after.y0) - 2)
            local y1 = math.max(before.y1, after.y1) + 8
            regions[#regions+1] = Geom:new{
                x = x, y = y0, w = math.max(1, self.fw - x), h = math.max(1, y1 - y0),
            }
        end
    end
    return regions
end
-- The slice from the top of a logical line down to the bottom of the editor.
-- After a reflow (wrap/newline/join) or a line-height change, only this line and
-- everything below it moved; the top bar and lines above are untouched, so this
-- avoids repainting (and flashing) the whole page.
function MDEdit:regionFromLineToBottom(row)
    local band = self:lineBand(row)
    if not band then return nil end
    local bottom = self.editor_refresh_region.y + self.editor_refresh_region.h
    return Geom:new{ x = 0, y = band.y, w = self.fw, h = math.max(1, bottom - band.y) }
end
-- Like regionFromLineToBottom but starting at the cursor's own visual row rather
-- than the top of its (possibly tall, wrapped) paragraph. A same-line reflow -- a
-- word wrapping within the paragraph -- only shifts content from the cursor down,
-- so the rows above the cursor must not be blanked/repainted.
function MDEdit:regionFromCursorRowToBottom()
    local y0
    for _, rm in ipairs(self.row_map or {}) do
        if rm.line == self.crow and rm.row then
            local sb = rm.row.sb or 0
            local rb = sb
            for _, sg in ipairs(rm.row.segs or {}) do rb = rb + #(sg.text or "") end
            if self.ccol >= sb and self.ccol <= rb then y0 = rm.y0; break end
        end
    end
    if not y0 then return nil end
    local top = math.max(0, y0 - 2)
    local bottom = self.editor_refresh_region.y + self.editor_refresh_region.h
    return Geom:new{ x = 0, y = top, w = self.fw, h = math.max(1, bottom - top) }
end
function MDEdit:unionRegion(a, b)
    if not a then return b end
    if not b then return a end
    local x0 = math.min(a.x, b.x)
    local y0 = math.min(a.y, b.y)
    local x1 = math.max(a.x + a.w, b.x + b.w)
    local y1 = math.max(a.y + a.h, b.y + b.h)
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end
function MDEdit:selectionIsMultiline()
    local lr, _, hr = self:selRange()
    return lr ~= nil and hr ~= nil and lr ~= hr
end
function MDEdit:caretRowTop(caret, row_map)
    if not caret then return nil end
    local cy = caret.y + math.floor(caret.h / 2)
    for _, rm in ipairs(row_map or {}) do
        if rm.row and cy >= rm.y0 and cy <= rm.y1 then return rm.y0 end
    end
    return nil
end
function MDEdit:regionFromCaretTransitionToBottom(prev_caret, prev_row_map)
    local old_top = self:caretRowTop(prev_caret, prev_row_map)
    local new_top = self:caretRowTop(self.caret_region, self.row_map)
    local top = old_top and new_top and math.min(old_top, new_top) or old_top or new_top
    if not top then return nil end
    top = math.max(0, top - 2)
    local bottom = self.editor_refresh_region.y + self.editor_refresh_region.h
    return Geom:new{ x = 0, y = top, w = self.fw, h = math.max(1, bottom - top) }
end
-- Full-width band spanning every *visible* row of logical lines [from,to]. Lets a
-- highlight add/remove repaint just the edited line(s) instead of the whole screen.
-- Returns nil if none of those lines are currently on screen.
function MDEdit:linesRegion(from, to)
    if not from or not to then return nil end
    if from > to then from, to = to, from end
    local y0, y1
    for _, rm in ipairs(self.row_map or {}) do
        if rm.line >= from and rm.line <= to then
            y0 = y0 and math.min(y0, rm.y0) or rm.y0
            y1 = y1 and math.max(y1, rm.y1) or rm.y1
        end
    end
    if not y0 then return nil end
    return Geom:new{ x = 0, y = y0, w = self.fw, h = math.max(1, y1 - y0) }
end
function MDEdit:refresh(opts)
    opts = opts or {}
    if opts.layout_dirty ~= false then
        self._vrows_dirty = true          -- content may have changed; rebuild the layout cache
    end
    self.caret_on = true
    local prev_count = self.visual_count
    local prev_vtop = self.vtop
    local prev_crow = self._render_crow or self.crow
    local prev_ccol = self._render_ccol or self.ccol
    local prev_band = self:lineBand(self.crow)
    local prev_caret = self.caret_region
    local prev_row_map = self.row_map
    local prev_sel_multiline = self._render_sel_multiline
    local prev_has_selection = not not self._render_has_selection
    self:rebuild()
    local region = self.keyboard and self.editor_refresh_region or nil
    local regions
    local vtop_changed = prev_vtop and self.vtop and prev_vtop ~= self.vtop
    -- A same-line selection used to disappear from state without repainting:
    -- unlike multi-line selections it had no special dirty hint. Track whether
    -- the previous frame had any visible selection so clearing it always erases
    -- the old highlight.
    local has_selection = self:hasSel()
    local selection_dirty = opts.selection or prev_sel_multiline or self:selectionIsMultiline()
        or prev_has_selection ~= has_selection
    local band = self:lineBand(self.crow)
    local line_geometry_changed = prev_band and band
        and (prev_band.y ~= band.y or prev_band.h ~= band.h)
    -- If the wrapped-row count is unchanged, the edit stayed within one logical
    -- line and nothing below it moved -- refresh only the affected tail of that
    -- line. A reflow (wrap change, newline, line join) or a line-height change
    -- shifts the edited line and everything below it, but leaves the top bar and
    -- the lines above untouched -- repaint only that lower slice.
    -- With the on-screen keyboard visible, keep refreshing the whole editor band;
    -- partial editor redraws above a live keyboard leave mixed e-ink regions.
    local reflow = prev_count and self.visual_count ~= prev_count
    if opts.lines then
        -- Caller knows exactly which logical lines changed (e.g. a highlight edit):
        -- repaint only those, never the whole screen.
        region = self:linesRegion(opts.lines[1], opts.lines[2]) or self.editor_body_region
    elseif opts.full then
        region = self.editor_refresh_region
    elseif selection_dirty or vtop_changed then
        region = self.editor_body_region
    elseif reflow or line_geometry_changed then
        if self.keyboard then
            region = self.editor_refresh_region
        elseif prev_crow == self.crow then
            -- Reflow within the same paragraph (a word wrapped): only content from
            -- the earlier of the old/new cursor rows down moved. Including the old
            -- row clears text that moved onto the new row without repainting above it.
            region = self:regionFromCaretTransitionToBottom(prev_caret, prev_row_map)
                or self:regionFromCursorRowToBottom()
                or self:regionFromLineToBottom(self.crow)
                or self.editor_refresh_region
        else
            -- Line split/join: the edit spans two logical lines; repaint from the
            -- higher of the two down.
            region = self:regionFromLineToBottom(math.min(prev_crow or self.crow, self.crow))
                or self.editor_refresh_region
        end
    elseif prev_count and self.visual_count == prev_count then
        if opts.cursor_move then
            if prev_caret and self.caret_region then
                regions = { prev_caret, self.caret_region }
                band = nil
            elseif prev_caret or self.caret_region then
                band = prev_caret or self.caret_region
            elseif prev_crow and prev_crow ~= self.crow then
                band = self:unionRegion(self:lineBand(prev_crow), band)
            end
        elseif opts.precise_edit and prev_crow == self.crow then
            -- Ordinary typing/backspace: compare the old and new wrapped rows and
            -- invalidate only rows whose pixels changed. In the common case this
            -- is one tail on one row, even near the bottom of the screen.
            regions = self:changedLineRegions(prev_row_map, self.row_map,
                self.crow, prev_ccol, self.ccol)
            if regions then
                -- A zero-width Markdown marker can change the source without
                -- changing row pixels; in that case only the caret moved.
                if #regions == 0 then
                    if prev_caret then regions[#regions+1] = prev_caret end
                    if self.caret_region then regions[#regions+1] = self.caret_region end
                end
                band = nil
            else
                band = self:cursorRowBand()
            end
        else
            -- Broader same-line edits may alter styling without going through the
            -- precise path, so conservatively refresh from the cursor row onward.
            band = self:cursorRowBand()
        end
        if band then region = band end
    end
    self._render_crow = self.crow
    self._render_ccol = self.ccol
    self._render_sel_multiline = self:selectionIsMultiline()
    self._render_has_selection = has_selection
    self._last_dirty_at = IO.now_seconds()
    self._last_dirty_region = regions and self.caret_region or region
    self._last_dirty_full = not regions and region == nil
    if regions then
        for _, dirty_region in ipairs(regions) do
            UIManager:setDirty(self, "ui", dirty_region)
        end
    else
        UIManager:setDirty(self, "ui", region)
    end
end
-- Scroll-only repaint: vtop moved but the text is unchanged, so reuse the
-- cached visual rows instead of re-tokenizing the whole document.
function MDEdit:refreshScroll()
    self.caret_on = true
    self:rebuild()
    UIManager:setDirty(self, "ui", self.editor_body_region)
end
function MDEdit:runTopAction(name)
    if name == "find_input" then self:openFindDialog()
    elseif name == "find_previous" then self:findNext(self._find_query, -1)
    elseif name == "find_next" then self:findNext(self._find_query, 1)
    elseif name == "find_done" then
        self._find_bar_visible = nil
        self._topbar_cache = nil
        self:refresh{ layout_dirty = false, full = true }
    elseif name == "menu" then self:openControls()
    elseif name == "edit" then self:setReaderMode(false)
    elseif self.reader_mode and name == "close" then self:saveAndClose()
    elseif self.reader_mode then return
    elseif name == "header" then self:fmtHeader()
    elseif name == "bold" then self:fmtWrap("**")
    elseif name == "italic" then self:fmtWrap("*")
    elseif name == "list" then self:fmtList()
    elseif name == "ordered" then self:fmtOrdered()
    elseif name == "task" then self:fmtTask()
    elseif name == "mindmap" then self:openMindmap()
    elseif name == "reader" then self:setReaderMode(true)
    elseif name == "table" then self:insertTable()
    elseif name == "smaller" then self:bumpScale(-0.1)
    elseif name == "larger" then self:bumpScale(0.1)
    elseif name == "close" then self:saveAndClose()
    end
end
function MDEdit:openControls()
    if self.reader_mode then
        Chrome.show_controls({
            { text = "Find...", callback = function() self:openFindDialog() end },
            { text = "Outline", sub_item_table_func = function() return self:outlineItems() end },
            { text = "Exit reader mode", callback = function() self:setReaderMode(false) end },
            { text = "⟲ Rotate screen", callback = function() Chrome.rotate_screen_ccw() end },
            { text = "Save & close note", callback = function() self:saveAndClose() end },
        })
        return
    end
    local keyboard_item
    if self.keyboard then
        keyboard_item = { text = "Hide keyboard", callback = function() self:hideKeyboard() end }
    else
        keyboard_item = { text = "Show keyboard", callback = function() self:showKeyboard() end }
    end
    Chrome.show_controls({
        { text = "Find...", callback = function() self:openFindDialog() end },
        { text = "Outline", sub_item_table_func = function() return self:outlineItems() end },
        { text = "Mindmap mode", callback = function() self:openMindmap() end },
        { text = "Reader mode", callback = function() self:setReaderMode(true) end },
        keyboard_item,
        { text = "Heading", callback = function() self:fmtHeader() end },
        { text = "Bold", callback = function() self:fmtWrap("**") end },
        { text = "Italic", callback = function() self:fmtWrap("*") end },
        { text = "List item", callback = function() self:fmtList() end },
        { text = "Numbered list", callback = function() self:fmtOrdered() end },
        { text = "Checkbox", callback = function() self:fmtTask() end },
        { text = "Table", callback = function() self:insertTable() end },
        { text = "Text size +", callback = function() self:bumpScale(0.1) end },
        { text = "Text size -", callback = function() self:bumpScale(-0.1) end },
        { text = "Select all", callback = function() self:selectAll() end },
        { text = "Copy",  callback = function() self:copy() end },
        { text = "Cut",   callback = function() self:cut() end },
        { text = "Paste", callback = function() self:paste() end },
        { text = "Undo",  callback = function() self:undo() end },
        { text = "Redo",  callback = function() self:redo() end },
        { text = "⟲ Rotate screen", callback = function() Chrome.rotate_screen_ccw() end },
        { text = "Open .md file...", callback = function() self:saveAndOpenMarkdown() end },
        { text = "Save & close note", callback = function() self:saveAndClose() end },
    })
end

return { methods = MDEdit }
