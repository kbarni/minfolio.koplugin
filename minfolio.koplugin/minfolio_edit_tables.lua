-- SPDX-License-Identifier: AGPL-3.0-only
-- minfolio_edit_tables: the Markdown table subsystem mixin for MDEdit
-- (PLAN.md §5 Tier 4, §10 step 8). Kept as ONE contiguous unit deliberately
-- -- both reviewers of PLAN.md independently found this is one interleaved
-- whole (inline spans, wrap, layout, widget build, render, hit-test, cell
-- replace, cell editor) and that splitting it further cuts across a real
-- seam rather than along one (PLAN.md §5, §11). All 11 methods below were
-- exactly contiguous in the source before this move (confirmed at move
-- time), consistent with that finding.
--
-- Mixin shape (PLAN.md §6.2): `local MDEdit = {}` below is a local proxy
-- table, not the real editor class -- see minfolio_edit_layout.lua's header
-- for the full rationale, which applies identically here. `return` produces
-- `{ methods = MDEdit }`; this mixin has no plain cross-boundary helpers, so
-- unlike minfolio_edit_layout there is no `fns` table to export.
--
-- Ported verbatim from main.lua / minfolio_edit.lua (PLAN.md §5 Tier 4, §10
-- step 8): the 11 methods of the table subsystem, kept together as one unit.
-- ARCHITECTURE.md explains how to locate any MDEdit method across the four
-- files. Method bodies are unedited; only each declaration line's
-- receiver (`MDEdit` -> the local proxy of the same name) changed.
--
-- Required by minfolio_edit.lua as `local Tables = require("minfolio_edit_tables")`.

local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local _ = require("gettext")

local MD = require("minfolio_md")
local Text = require("minfolio_text")
local Style = require("minfolio_style")
local C = require("minfolio_const")
local Keys = require("minfolio_keys")

local MDEdit = {}
function MDEdit:tableInlineSpans(text, base_style)
    local spans = {}
    for _, span in ipairs(MD.md_inline(tostring(text or ""))) do
        if span.style ~= "syntax" then
            local style = span.style == "normal" and base_style or span.style
            local display = span.display == nil and span.text or span.display
            if display ~= "" then
                spans[#spans+1] = { text = display, display = display, style = style, hl = span.hl }
            end
        end
    end
    return spans
end
function MDEdit:tableInlineWidth(text, base_style)
    local width = 0
    for _, span in ipairs(self:tableInlineSpans(text, base_style)) do
        width = width + self:wordw(span.display or span.text or "", span.style)
    end
    return width
end
-- Inline-aware greedy wrapping for table cells. Markdown markers have already
-- been removed by tableInlineSpans, while each visible run retains its face and
-- highlight flag. Over-long words are still hard-broken on UTF-8 boundaries.
function MDEdit:wrapTableCell(text, base_style, maxw)
    local rows = {}
    local function new_row() return { segs = {}, w = 0, sb = 0, indent = 0 } end
    local row = new_row()
    local function finish_row()
        rows[#rows+1] = row
        row = new_row()
    end
    local function append(piece, style, hl)
        if piece == "" then return end
        local width = self:wordw(piece, style)
        row.segs[#row.segs+1] = { text = piece, display = piece, style = style, hl = hl, w = width }
        row.w = row.w + width
    end
    for _, span in ipairs(self:tableInlineSpans(text, base_style)) do
        local raw, pos = span.display or span.text or "", 1
        while pos <= #raw do
            local unit = raw:match("^%s+", pos) or raw:match("^%S+", pos) or raw:sub(pos)
            local width = self:wordw(unit, span.style)
            if not unit:match("^%s") and #row.segs > 0 and row.w + width > maxw then finish_row() end
            if not unit:match("^%s") and width > maxw then
                local rest = unit
                while rest ~= "" do
                    local i, piece = 0, ""
                    while true do
                        local nxt = Text.utf8_right(rest, i)
                        if nxt == i then break end
                        local candidate = rest:sub(1, nxt)
                        if self:wordw(candidate, span.style) <= maxw then piece, i = candidate, nxt else break end
                    end
                    if piece == "" then piece = rest:sub(1, math.max(1, Text.utf8_right(rest, 0))) end
                    append(piece, span.style, span.hl)
                    rest = rest:sub(#piece + 1)
                    if rest ~= "" then finish_row() end
                end
            else
                append(unit, span.style, span.hl)
            end
            pos = pos + #unit
        end
    end
    if #row.segs > 0 or #rows == 0 then rows[#rows+1] = row end
    return rows
end
function MDEdit:layoutTable(tbl, availw)
    local pad_x = math.floor(Style.MDEDIT_TABLE_PAD_X * self.scale)
    local pad_x2 = 2 * pad_x
    local minw = math.max(34, math.floor(42 * self.scale))
    -- Natural single-line width each column would like, so short columns can stay
    -- compact while long ones absorb the wrapping.
    local nat = {}
    for c = 1, tbl.ncols do nat[c] = minw end
    for _, tr in ipairs(tbl.rows) do
        local style = tr.header and "bold" or "normal"
        for c = 1, tbl.ncols do
            local cell = tr.cells[c]
            -- Reserve padding + the cell's 1px left/right borders (the same 2px the
            -- wrap width subtracts below) + a little rounding slack, so a column
            -- sized to its own text never wraps that text mid-word.
            nat[c] = math.max(nat[c], self:tableInlineWidth(cell and cell.text or "", style) + pad_x2 + 4)
        end
    end
    local natsum = 0
    for c = 1, tbl.ncols do natsum = natsum + nat[c] end
    local widths = {}
    if natsum <= availw then
        for c = 1, tbl.ncols do widths[c] = nat[c] end
    else
        -- Water-filling: columns narrower than an even share keep their natural
        -- width; the remaining space is split evenly among the wide columns, which
        -- then wrap. Repeats until the wide set is stable.
        local remaining, count, avail = {}, tbl.ncols, availw
        for c = 1, tbl.ncols do remaining[c] = true end
        while true do
            local share = math.floor(avail / math.max(1, count))
            local changed = false
            for c = 1, tbl.ncols do
                if remaining[c] and nat[c] <= share then
                    widths[c] = nat[c]; remaining[c] = false
                    avail = avail - nat[c]; count = count - 1; changed = true
                end
            end
            if not changed or count == 0 then break end
        end
        if count > 0 then
            local share = math.max(minw, math.floor(avail / count))
            for c = 1, tbl.ncols do if remaining[c] then widths[c] = share end end
        end
    end
    local total = 0
    for c = 1, tbl.ncols do widths[c] = math.max(minw, widths[c]); total = total + widths[c] end

    local pad_y = math.floor(Style.MDEDIT_TABLE_PAD_Y * self.scale)
    local entries = {}
    for ri, tr in ipairs(tbl.rows) do
        local style = tr.header and "bold" or "normal"
        local wrapped, content_h = {}, 0
        for c = 1, tbl.ncols do
            local cell = tr.cells[c]
            local inner = math.max(1, widths[c] - pad_x2 - 2)
            local wl = self:wrapTableCell(cell and cell.text or "", style, inner)
            wrapped[c] = wl
            local cell_h = 0
            for _, line in ipairs(wl) do cell_h = cell_h + self:rowTextHeight(line) end
            content_h = math.max(content_h, cell_h)
        end
        local rowh = math.max(24, content_h + 2 * pad_y + 2)
        entries[#entries+1] = {
            kind = "table_row",
            line = tr.line,
            table = tbl,
            cells = tr.cells,
            header = tr.header,
            ri = ri,
            h = rowh,
            w = total,
            col_widths = widths,
            aligns = tbl.aligns,
            wrapped = wrapped,
        }
    end
    return entries
end
function MDEdit:tableCell(lines, colw, rowh, align)
    local pad_x = math.floor(Style.MDEDIT_TABLE_PAD_X * self.scale)
    local border = 1
    -- FrameContainer:getSize() ignores its own `width`/`height` and measures its
    -- content, so passing width=colw does NOT make a cell occupy the column -- the
    -- row then packs cells at their text width and columns drift out of alignment.
    -- Wrap the content in a fixed-`dimen` LeftContainer so every cell in a column
    -- is exactly colw x rowh and the columns line up across rows.
    local inner_w = math.max(1, colw - 2 * border)
    local inner_h = math.max(1, rowh - 2 * border)
    local vg = VerticalGroup:new{ align = "left" }
    for _, line in ipairs(lines or {}) do
        local lineh = self:rowTextHeight(line)
        local tw = line.w or 0
        local left = pad_x
        if align == "right" then left = math.max(pad_x, inner_w - pad_x - tw)
        elseif align == "center" then left = math.max(pad_x, math.floor((inner_w - tw) / 2)) end
        local layers = { dimen = Geom:new{ w = math.max(1, tw), h = lineh } }
        local hx, hstart = 0, nil
        local function flush_highlight(xend)
            if hstart and xend > hstart then
                layers[#layers+1] = HorizontalGroup:new{ align = "top",
                    HorizontalSpan:new{ width = hstart },
                    LineWidget:new{ background = C.EDIT.MDEDIT_HIGHLIGHT_GRAY,
                        dimen = Geom:new{ w = math.max(2, xend - hstart), h = lineh } },
                }
            end
            hstart = nil
        end
        for _, seg in ipairs(line.segs or {}) do
            if seg.hl then
                if (seg.w or 0) > 0 and not hstart then hstart = hx end
            else
                flush_highlight(hx)
            end
            hx = hx + (seg.w or 0)
        end
        flush_highlight(hx)
        layers[#layers+1] = self:renderRow(line)
        vg[#vg+1] = HorizontalGroup:new{
            HorizontalSpan:new{ width = left }, OverlapGroup:new(layers),
        }
    end
    return FrameContainer:new{ bordersize = border, padding = 0, margin = 0,
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, vg } }
end
function MDEdit:renderTableRow(vr)
    local hg = HorizontalGroup:new{ align = "top" }
    for c = 1, #vr.col_widths do
        hg[#hg+1] = self:tableCell(vr.wrapped and vr.wrapped[c], vr.col_widths[c], vr.h, vr.aligns[c])
    end
    return hg
end
function MDEdit:tableColAtX(rm, x)
    if x < 0 then
        local first = rm.cells and rm.cells[1]
        return first and (first.start_col or 0) or 0
    end
    local hit = self:tableCellAtX(rm, x)
    if hit then
        local cell, w = hit.cell, hit.width
        local pad_x = math.floor(Style.MDEDIT_TABLE_PAD_X * self.scale)
        local inner_x = math.max(0, math.min(w - (2 * pad_x), hit.inner_x))
        local span = math.max(0, (cell.end_col or 0) - (cell.start_col or 0))
        if span <= 0 then return cell.start_col or 0 end
        return math.floor((cell.start_col or 0) + (span * inner_x / math.max(1, w - (2 * pad_x))))
    end
    local last = rm.cells and rm.cells[#rm.cells]
    return last and (last.end_col or last.start_col or 0) or 0
end
function MDEdit:tableCellAtX(rm, x)
    if x < 0 then return nil end
    local acc = 0
    local widths = rm.col_widths or {}
    for c = 1, #widths do
        local w = widths[c]
        if x < acc + w then
            local cell = rm.cells and rm.cells[c]
            if not cell then return nil end
            local pad_x = math.floor(Style.MDEDIT_TABLE_PAD_X * self.scale)
            return {
                line = rm.line,
                col = c,
                cell = cell,
                x0 = acc,
                x1 = acc + w,
                width = w,
                inner_x = x - acc - pad_x,
            }
        end
        acc = acc + w
    end
    return nil
end
function MDEdit:tableCellAtPos(pos)
    if not pos then return nil end
    for _, rm in ipairs(self.row_map or {}) do
        if rm.table and pos.y >= rm.y0 and pos.y < rm.y1 then
            return self:tableCellAtX(rm, pos.x - C.EDIT.MDEDIT_PAD)
        end
    end
    return nil
end
function MDEdit:replaceTableCell(hit, value)
    if not hit or not hit.line or not hit.cell then return false end
    local line = self.lines[hit.line]
    if not line then return false end
    local cell = hit.cell
    local clean = tostring(value or ""):gsub("[\r\n]+", " "):gsub("|", "/")
    local before = line:sub(1, cell.start_col)
    local after = line:sub((cell.end_col or cell.start_col) + 1)
    self.lines[hit.line] = before .. clean .. after
    self.crow = hit.line
    self.ccol = #before + #clean
    self._vrows_dirty = true
    return true
end
function MDEdit:openTableCellEditor(hit)
    if not hit or not hit.cell then return false end
    self:flushTypeBuffer()
    if self._page_pending then UIManager:unschedule(self._page_pending); self._page_pending = nil end
    self._rtap = nil
    -- The editor's own non-modal keyboard targets MDEdit directly. Leaving it on
    -- the stack under an InputDialog makes its keys continue editing the document,
    -- even though the table-cell field is visibly on top.
    if self.keyboard then self:hideKeyboard() end
    local dlg
    local restored = false
    local function restore_editor_focus()
        if restored then return false end
        restored = true
        self._table_cell_dialog = nil
        self.is_always_active = true
        return true
    end
    -- The dialog and its on-screen keyboard cover a large slice of the screen;
    -- closing them only repaints that dialog region, leaving the editor beneath
    -- half-blank. Force a full editor repaint on either exit.
    local function dismiss(layout_dirty)
        restore_editor_focus()
        UIManager:close(dlg)
        self:refresh{ layout_dirty = layout_dirty and true or false, full = true }
    end
    dlg = InputDialog:new{
        title = string.format(_("Table cell %d"), hit.col or 1),
        input = hit.cell.text or "",
        buttons = {{
            { text = _("Cancel"), callback = function() dismiss(false) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = dlg:getInputText() or ""
                self:snapshot()
                self._burst = nil
                self:replaceTableCell(hit, value)
                self:save()
                dismiss(true)
            end },
        }},
    }
    local input = dlg._input_widget
    if input then
        local function input_prev_word_pos()
            local p = math.max(1, math.min(input.charpos or 1, #(input.charlist or {}) + 1))
            while p > 1 and Text.char_is_space(input.charlist[p - 1] or "") do p = p - 1 end
            while p > 1 and not Text.char_is_space(input.charlist[p - 1] or "") do p = p - 1 end
            return p
        end
        local function input_next_word_pos()
            local p = math.max(1, math.min(input.charpos or 1, #(input.charlist or {}) + 1))
            while p <= #(input.charlist or {}) and Text.char_is_space(input.charlist[p] or "") do p = p + 1 end
            while p <= #(input.charlist or {}) and not Text.char_is_space(input.charlist[p] or "") do p = p + 1 end
            return p
        end
        local function input_del_word_left()
            local p = input.charpos or 1
            local start = input_prev_word_pos()
            if start < p then input:delSelection(start, p - 1) else input:delChar() end
        end
        local original_on_key_press = input.onKeyPress
        function input:onKeyPress(key)
            local name = key and key.key
            local mods = Keys.key_mods(key)
            if name and Keys.word_key_mod(mods) and Keys.left_key(name) then
                self:moveCursorToCharPos(input_prev_word_pos())
                return true
            elseif name and Keys.word_key_mod(mods) and Keys.right_key(name) then
                self:moveCursorToCharPos(input_next_word_pos())
                return true
            elseif name and Keys.word_key_mod(mods)
                and (name == "Backspace" or name == "BackSpace" or name == "Del" or name == "Delete") then
                input_del_word_left()
                return true
            end
            return original_on_key_press(self, key)
        end
    end
    -- MDEdit is normally always active so external keyboards work reliably. A
    -- modal input field is the exception: suspend the document's key handler so
    -- physical keystrokes are delivered exclusively to InputDialog.
    self._table_cell_dialog = dlg
    self.is_always_active = false
    local editor, original_close = self, dlg.onCloseWidget
    function dlg:onCloseWidget()
        if original_close then original_close(self) end
        if restore_editor_focus() and editor._caret_blinking then
            editor:refresh{ layout_dirty = false, full = true }
        end
    end
    UIManager:show(dlg)
    dlg:onShowKeyboard()
    return true
end

return { methods = MDEdit }
