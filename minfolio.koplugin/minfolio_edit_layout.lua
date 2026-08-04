-- SPDX-License-Identifier: AGPL-3.0-only
-- minfolio_edit_layout: text measurement and wrapping mixin for MDEdit
-- (PLAN.md §5 Tier 4, §10 step 8). Wrapping (layoutLine), the visual-row
-- cache (computeVisualRows/visualRows/reindexVisualRows/updateVisualLine),
-- measurement caches (textw/texth/wordw/rowTextHeight/rowHeight/
-- trimToWidth), visual-row coordinate math (cursorInRows/colAtX/
-- cursorVisual/moveCursorVisual/rowXAt/visualRowHeight/textWidth), and
-- free_wrap_entry (a plain helper, not a method -- see below).
--
-- Mixin shape (PLAN.md §6.2): `local MDEdit = {}` below is a local proxy
-- table, NOT the real editor class -- it exists only so every method can
-- keep its original `function MDEdit:name(...)` declaration line verbatim,
-- unedited. `pairs()` over it at `return` time produces exactly the
-- `{ name = fn, ... }` shape `mixin.methods` needs; the real MDEdit class
-- (minfolio_edit.lua) assigns these into itself with `MDEdit[name] = fn`
-- (guarded by `rawget` to catch a genuine duplicate without rejecting an
-- intended `InputContainer` override -- irrelevant here since none of this
-- mixin's 18 methods override anything, but the mechanism is shared).
--
-- free_wrap_entry is exported via `fns`, not `methods`: it is a plain
-- function (not `function MDEdit:...`), called bare -- not via `self:` --
-- from three call sites in minfolio_edit.lua itself (onScreenResize,
-- onCloseWidget, bumpScale). Exporting it as a method would make those bare
-- calls resolve as nil-global reads; the `fns` channel exists precisely for
-- this (PLAN.md §6.2, §4 cross-boundary helpers), and it is the ONLY method
-- in this codebase that needs it -- confirmed at exactly its four call
-- sites (one internal to this file, in computeVisualRows; three in
-- minfolio_edit.lua). Call sites there use `Layout.freeWrapEntry(entry)`.
--
-- Ported verbatim from main.lua / minfolio_edit.lua (PLAN.md §5 Tier 4, §10
-- step 8): the 18 layout methods (wrapping, visual rows, measurement caches)
-- plus the free_wrap_entry helper. ARCHITECTURE.md explains how to locate any
-- MDEdit method across the four files. Method bodies are unedited; only
-- each declaration line's receiver (`MDEdit` -> the local proxy of the same
-- name) and the free_wrap_entry call sites in minfolio_edit.lua changed.
--
-- Required by minfolio_edit.lua as `local Layout = require("minfolio_edit_layout")`.

local TextWidget = require("ui/widget/textwidget")

local MD = require("minfolio_md")
local Text = require("minfolio_text")
local Style = require("minfolio_style")
local C = require("minfolio_const")

local MDEdit = {}
function MDEdit:textw(txt, face)        -- measured rendered width of a string
    if txt == "" then return 0 end
    local tw = TextWidget:new{ text = txt, face = face }
    local w = tw:getSize().w; tw:free(); return w
end
function MDEdit:texth(style)
    local key = style .. "|" .. self.scale
    local c = self._hcache[key]
    if c then return c end
    local tw = TextWidget:new{ text = "Hg", face = Style.md_face(style, self.scale) }
    local h = tw:getSize().h; tw:free()
    self._hcache[key] = h; return h
end
function MDEdit:wordw(txt, style)        -- cached measured width (keyed by style + scale)
    if txt == "" then return 0 end
    local key = style .. "|" .. self.scale .. "|" .. txt
    local c = self._wcache[key]
    if c then return c end
    local w = self:textw(txt, Style.md_face(style, self.scale))
    self._wcache[key] = w; return w
end
function MDEdit:rowTextHeight(row)
    if not row.segs or #row.segs == 0 then return self:texth("normal") end
    local h = 0
    for _, seg in ipairs(row.segs) do h = math.max(h, self:texth(seg.style)) end
    return math.max(1, h)
end
function MDEdit:rowHeight(row, block)
    local measured = self:rowTextHeight(row)
    return math.max(1, math.ceil(measured * C.EDIT.MDEDIT_LINE_HEIGHT)) + math.max(0, math.floor(C.EDIT.MDEDIT_LINE_GAP * self.scale))
end
function MDEdit:trimToWidth(text, maxw, face)
    if self:textw(text, face) <= maxw then return text end
    local ell = "..."
    local lo, hi, best = 0, #text, ell
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local s = text:sub(1, mid) .. ell
        if self:textw(s, face) <= maxw then best = s; lo = mid + 1 else hi = mid - 1 end
    end
    return best
end
-- word-wrap a logical line into visual rows that fit availw; each row/seg tracks its start byte
-- Left inset of a blockquote at `depth` levels, rule included (see the constants'
-- comment). Scaled by the text scale so the quote keeps its proportions when the
-- reader changes text size -- bumpScale drops the wrap cache, so a scaled indent
-- can be baked into cached rows safely.
function MDEdit:quoteIndent(depth)
    local levels = math.min(math.max(1, math.floor(depth or 1)), C.EDIT.MDEDIT_QUOTE_MAX_DEPTH)
    return math.floor(levels * C.EDIT.MDEDIT_QUOTE_INDENT * (self.scale or 1))
end
function MDEdit:layoutLine(toks, availw)
    local rows, byte = {}, 0
    local hanging = 0
    local base_indent = 0
    if toks.block == "quote" then
        -- Continuation rows hang at the same inset, not under the first word: a
        -- wrapped quote is still inside the same rule, so its left edge has to
        -- stay flush with the line above it.
        base_indent = self:quoteIndent(toks.quote_depth)
        hanging = base_indent
    elseif toks.block == "bullet" then
        -- Nesting depth: leading whitespace becomes real horizontal indent (the
        -- marker glyph itself carries no indent). Continuation rows hang under the
        -- text, so they start at base_indent + marker width.
        if toks.indent_ws and toks.indent_ws ~= "" then
            base_indent = self:wordw(toks.indent_ws, "bullet")
        end
        hanging = base_indent
        for _, span in ipairs(toks.spans) do
            local raw = span.text or ""
            local display = span.display
            if display == nil or display == raw then break end
            if display ~= "" then hanging = hanging + self:wordw(display, span.style) end
        end
    end
    local function newRow(indent, sb)
        indent = indent or 0
        return { segs = {}, w = indent, sb = sb or 0, indent = indent }
    end
    local row = newRow(base_indent, 0)
    for _, span in ipairs(toks.spans) do
        local raw = span.text or ""
        local display = span.display
        if display == nil then display = raw end
        if display ~= raw then
            local uw = display ~= "" and self:wordw(display, span.style) or 0
            row.segs[#row.segs+1] = { text = raw, display = display, style = span.style, hl = span.hl, w = uw, sb = byte }
            row.w = row.w + uw; byte = byte + #raw
        else
            local pos = 1
            while pos <= #raw do
                local unit = raw:match("^%s+", pos) or raw:match("^%S+", pos) or raw:sub(pos)
                local uw = self:wordw(unit, span.style)
                if not unit:match("^%s") and #row.segs > 0 and row.w + uw > availw then
                    rows[#rows+1] = row; row = newRow(hanging, byte)
                end
                row.segs[#row.segs+1] = { text = unit, display = unit, style = span.style, hl = span.hl, w = uw, sb = byte }
                row.w = row.w + uw; byte = byte + #unit; pos = pos + #unit
            end
        end
    end
    rows[#rows+1] = row
    return rows
end
function MDEdit:cursorInRows(rows)       -- (visual row index, x within row) for the cursor
    for ri = #rows, 1, -1 do
        if self.ccol >= rows[ri].sb then
            return ri, self:rowXAt(rows[ri], self.ccol)
        end
    end
    return 1, 0
end
function MDEdit:colAtX(row, x)           -- byte column nearest x within a visual row (for tap-to-place)
    local b, accx = row.sb, row.indent or 0
    if x < accx then return b end
    for _, seg in ipairs(row.segs) do
        if x < accx + seg.w then
            local display = seg.display
            if display == nil then display = seg.text end
            if display ~= seg.text then
                return b + ((x - accx) < (seg.w / 2) and 0 or #seg.text)
            end
            local prev = 0
            for ci = 1, #seg.text do
                local w = self:wordw(seg.text:sub(1, ci), seg.style)
                if accx + w >= x then
                    if (x - accx - prev) < (accx + w - x) then return b + ci - 1 else return b + ci end
                end
                prev = w
            end
            return b + #seg.text
        end
        accx = accx + seg.w; b = b + #seg.text
    end
    return b
end
-- Tokenize + word-wrap the whole document into visual rows. This is the
-- expensive step (md_tokenize + font-width measurement per line), so its
-- result is cached (see :visualRows) and only recomputed when the text or the
-- available width changes -- never on a plain scroll.
-- Releases the native TextWidget buffers (see renderRow) cached on a wrap-cache
-- entry's rows. Call this only for entries that are actually being dropped.
local function free_wrap_entry(entry)
    for _, row in ipairs(entry.rows) do
        if row._rendered then row._rendered:free(); row._rendered = nil end
    end
end
function MDEdit:computeVisualRows(text_w)
    -- Per-logical-line wrap cache keyed by the line's exact text. Editing one
    -- line is a single cache miss (the tokenize + word-wrap for that line);
    -- every other line is reused untouched, so a keystroke re-wraps one line
    -- instead of the whole document. The cache is rebuilt from the live lines
    -- each pass, so it can never grow past the current document.
    local prev = (self._wrap_cache_w == text_w) and self._wrap_cache or nil
    local old_cache = self._wrap_cache
    local cache, out = {}, {}
    local code_map = {}
    local function emit(i, key, entry)
        cache[key] = entry
        for ri, row in ipairs(entry.rows) do
            out[#out+1] = { kind = "row", line = i, row = row, block = entry.block, ri = ri,
                quote = entry.quote }
        end
    end
    local function build(toks)
        return { rows = self:layoutLine(toks, text_w), block = toks.block, quote = toks.quote_depth }
    end
    local function appendLine(i)
        local text = self.lines[i]
        -- `or` short-circuits, so a cache hit never reaches md_tokenize.
        local entry = cache[text] or (prev and prev[text]) or build(MD.md_tokenize(text)[1])
        emit(i, text, entry)
        if i < #self.lines then
            out[#out+1] = { kind = "gap", line = i, h = C.EDIT.MDEDIT_PARA_GAP }
        end
    end
    -- One line of a fenced code block. The wrap cache is keyed by line text and
    -- shared with ordinary lines, so the key has to record that this line was
    -- tokenized as code: "**x**" renders two different ways inside and outside a
    -- fence, and the bare text as a key would hand one of them the other's rows.
    local function appendCodeLine(i, is_fence)
        local text = self.lines[i]
        local key = "\1code\1" .. tostring(is_fence) .. "\1" .. text
        emit(i, key, cache[key] or (prev and prev[key]) or build(MD.md_code_token(text, is_fence)))
    end
    local i = 1
    while i <= #self.lines do
        -- Fenced code blocks come first: inside one, nothing else parses -- not
        -- the table grammar below (a shell pipeline is not a table row), not
        -- headings, not bullets. Rows are emitted with no MDEDIT_PARA_GAP
        -- between them so the block's background band is continuous; the pad
        -- rows at either end are gaps that carry the band themselves.
        local code = MD.md_code_block(self.lines, i)
        -- Tables render as tables in every mode (edit and reader). Cells are
        -- edited by tapping them (openTableCellEditor); the raw pipe syntax is
        -- never shown as plain text.
        local tbl = not code and MD.md_table_block(self.lines, i)
        if code then
            for li = code.start, code.finish do code_map[li] = true end
            out[#out+1] = { kind = "gap", line = code.start, h = C.EDIT.MDEDIT_CODE_PAD, code = true }
            for li = code.start, code.finish do
                appendCodeLine(li, li == code.start or (code.closed and li == code.finish))
            end
            out[#out+1] = { kind = "gap", line = code.finish, h = C.EDIT.MDEDIT_CODE_PAD, code = true }
            if code.finish < #self.lines then
                out[#out+1] = { kind = "gap", line = code.finish, h = C.EDIT.MDEDIT_PARA_GAP }
            end
            i = code.finish + 1
        elseif tbl then
            for _, entry in ipairs(self:layoutTable(tbl, text_w)) do
                out[#out+1] = entry
            end
            if tbl.finish < #self.lines then
                out[#out+1] = { kind = "gap", line = tbl.finish, h = C.EDIT.MDEDIT_PARA_GAP }
            end
            i = tbl.finish + 1
        else
            appendLine(i)
            i = i + 1
        end
    end
    -- Join a blockquote's vertical rule across the paragraph gaps inside it.
    -- Without this the rule is a column of dashes with a MDEDIT_PARA_GAP-sized
    -- hole at every line break -- the same problem fenced code blocks solve with
    -- their `code = true` gaps.
    --
    -- Decided from what was actually emitted rather than by looking ahead at the
    -- next source line: a quoted TABLE row ("> | a | b |") is laid out by the
    -- table branch above and carries no quote depth, so a lookahead reading the
    -- raw text would see "> " and leave a rule stub dangling above a table that
    -- draws none. Reading the neighbouring rows cannot disagree with them.
    local pending_gap, prev_quote = nil, nil
    for idx, entry in ipairs(out) do
        if entry.kind == "gap" then
            if not entry.code then pending_gap = idx end
        else
            if pending_gap then
                local through = math.min(prev_quote or 0, entry.quote or 0)
                if through > 0 then out[pending_gap].quote = through end
                pending_gap = nil
            end
            prev_quote = entry.quote
        end
    end
    if old_cache then
        for text, entry in pairs(old_cache) do
            if cache[text] ~= entry then free_wrap_entry(entry) end
        end
    end
    self._wrap_cache, self._wrap_cache_w = cache, text_w
    -- Which lines this layout treated as code, for updateVisualLine to refuse.
    self._code_lines = code_map
    if #out == 0 then out[1] = { kind = "row", line = 1, row = { segs = {}, w = 0, sb = 0 }, block = "normal", ri = 1 } end
    return out
end
-- Cached accessor: recompute only when the content is marked dirty (any edit
-- calls :refresh, which sets _vrows_dirty) or the text width changed (rotation).
function MDEdit:visualRows(text_w)
    if self._vrows and self._vrows_w == text_w and not self._vrows_dirty then
        return self._vrows
    end
    if self._vrows then
        local seen = {}
        for _, vr in ipairs(self._vrows) do
            local row = vr.row
            if row and row._rendered and not seen[row] then row._rendered:free(); row._rendered = nil; seen[row] = true end
        end
    end
    self._vrows = self:computeVisualRows(text_w)
    self._vrows_w = text_w
    self._vrows_dirty = false
    self:reindexVisualRows()
    return self._vrows
end
function MDEdit:reindexVisualRows()
    local ranges = {}
    for vi, vr in ipairs(self._vrows or {}) do
        if vr.kind == "row" and vr.line then
            local r = ranges[vr.line]
            if not r then ranges[vr.line] = { first = vi, last = vi }
            else r.last = vi end
        end
    end
    self._vrow_line_ranges = ranges
end
-- Fast path for ordinary single-line typing/backspace. It deliberately bails
-- out around tables and structural changes, where a full layout is safer.
function MDEdit:updateVisualLine(line)
    local vrows, text_w = self._vrows, self._vrows_w
    if not vrows or text_w ~= self:textWidth() or self._vrows_dirty then return false end
    local text = self.lines[line] or ""
    if text:find("|", 1, true) or ((self.lines[line - 1] or ""):find("|", 1, true))
        or ((self.lines[line + 1] or ""):find("|", 1, true)) then return false end
    -- Code blocks are structural in the same way tables are, but with a longer
    -- reach: a fence changes how every line below it reads, so a single-line
    -- relayout is only safe well away from one. Bail if the last full layout put
    -- this line inside a block, or if the edit just produced a fence line.
    if (self._code_lines and self._code_lines[line]) or MD.md_fence(text) then return false end
    local range = self._vrow_line_ranges and self._vrow_line_ranges[line]
    if not range then return false end
    for vi = range.first, range.last do
        if vrows[vi].kind ~= "row" then return false end
    end
    local toks = MD.md_tokenize(text)[1]
    -- A change in blockquote depth is structural in the same way a fence is,
    -- just over a shorter reach: the rule drawn in the paragraph gaps either
    -- side of this line is the minimum of its depth and its neighbour's, and
    -- only the full computeVisualRows pass recomputes those. Editing a line into
    -- or out of a quote here would leave a rule stub hanging above or below it,
    -- so hand that case back to the full relayout.
    if (toks.quote_depth or 0) ~= (vrows[range.first].quote or 0) then return false end
    local replacement = {}
    for ri, row in ipairs(self:layoutLine(toks, text_w)) do
        replacement[#replacement+1] = { kind = "row", line = line, row = row, block = toks.block, ri = ri,
            quote = toks.quote_depth }
    end
    -- Release native glyph buffers for only the superseded rows. These rows are
    -- not stored in the content-keyed wrap cache on this incremental path.
    for vi = range.first, range.last do
        local row = vrows[vi].row
        if row and row._rendered then row._rendered:free(); row._rendered = nil end
    end
    local remove = range.last - range.first + 1
    for _ = 1, remove do table.remove(vrows, range.first) end
    for i = #replacement, 1, -1 do table.insert(vrows, range.first, replacement[i]) end
    self:reindexVisualRows()
    self._incremental_vrow_edits = (self._incremental_vrow_edits or 0) + 1
    -- Periodically rebuild the content-keyed cache, which bounds memory from
    -- unique words typed over a long session without taxing each keystroke.
    if self._incremental_vrow_edits >= 32 then self._vrows_dirty = true; self._incremental_vrow_edits = 0 end
    return true
end
-- Locate the caret within the cached rows. Cheap: only scans row metadata and
-- measures within the single logical line that holds the cursor.
function MDEdit:cursorVisual(vrows)
    local crow_rows, map = {}, {}
    for vi = 1, #vrows do
        local vr = vrows[vi]
        if vr.kind == "row" and vr.line == self.crow then
            crow_rows[#crow_rows+1] = vr.row
            map[#crow_rows] = vi
        end
    end
    if #crow_rows == 0 then return nil, nil end
    local cri, cx = self:cursorInRows(crow_rows)
    return map[cri], cx
end
function MDEdit:textWidth()
    return self.fw - (C.EDIT.MDEDIT_PAD * 2)
end
function MDEdit:moveCursorVisual(drow)
    local vrows = self:visualRows(self:textWidth())
    local vi, cx = self:cursorVisual(vrows)
    if not vi then return false end
    local target_x = self._desired_x or cx or 0
    local text_rows, current_idx = {}, nil
    for i, vr in ipairs(vrows) do
        if vr.kind == "row" then
            text_rows[#text_rows+1] = { vi = i, vr = vr }
            if i == vi then current_idx = #text_rows end
        end
    end
    if not current_idx then return false end
    local target = text_rows[current_idx + (drow < 0 and -1 or 1)]
    local vr = target and target.vr
    if not vr or vr.kind ~= "row" then return true end
    self._desired_x = target_x
    self.crow = vr.line
    self.ccol = Text.utf8_snap(self.lines[self.crow], self:colAtX(vr.row, target_x))
    return true
end
function MDEdit:visualRowHeight(vr)
    if vr.kind == "gap" then return vr.h or 0 end
    if vr.kind == "table_row" then return vr.h or 0 end
    return self:rowHeight(vr.row, vr.block)
end
function MDEdit:rowXAt(row, p)        -- x of absolute byte col p within a visual row
    local b, x = row.sb, row.indent or 0
    for _, seg in ipairs(row.segs) do
        if p <= b + #seg.text then
            local display = seg.display
            if display == nil then display = seg.text end
            if display == "" then return x end
            if display ~= seg.text then
                local raw_len = math.max(1, #seg.text)
                return x + math.floor(seg.w * math.max(0, p - b) / raw_len)
            end
            return x + self:wordw(seg.text:sub(1, p - b), seg.style)
        end
        x = x + seg.w; b = b + #seg.text
    end
    return x
end

return { methods = MDEdit, fns = { freeWrapEntry = free_wrap_entry } }
