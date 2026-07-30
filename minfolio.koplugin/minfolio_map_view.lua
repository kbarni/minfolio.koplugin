-- SPDX-License-Identifier: AGPL-3.0-only
-- MindmapView: the native, on-device mindmap widget for minfolio.koplugin
-- (PLAN.md §5 Tier 5, §10 step 7). Renders the tree minfolio_map_model.lua
-- parses (PLAN.md §5 Tier 0) as a pannable/zoomable node graph, with
-- in-place node text editing, undo, add/delete/reattach/reorder, and its own
-- top bar and controls menu -- a full alternate view onto the same Markdown
-- document the editor (`MDEdit`, still in main.lua as of this work package)
-- edits as text.
--
-- Instantiated from the editor as `MindmapView:new{ editor = self }`
-- (`MDEdit:openMindmap`, main.lua). That `editor` field is the ONLY channel
-- back to the editor -- every document read/write and every editor action
-- this view triggers goes through `self.editor`, injected at construction.
-- This file never references `MDEdit`, `edit_note`, or `App`/`active_mdedit`
-- by name (confirmed by grep over the whole class body before this move).
-- The editor->mindmap edge is a clean one-way dependency; this module has no
-- back-reference to the editor's class or to any editor-owned global/module
-- state, and none should be added.
--
-- Depends on things that already moved to their own modules in earlier work
-- packages: the keyboard patches (`Keys.makeKeyboardArrowFree`,
-- `Keys.disableKeyboardKeyFlash`, used in `showMapKeyboard`),
-- `Chrome.show_controls`/`Chrome.notify`/`Chrome.rotate_screen_ccw`, and
-- constants from BOTH `C.EDIT.*` and `C.MAP.*` -- `topBar` genuinely reads
-- `MDEDIT_MENU_W`/`MDEDIT_TITLE_ACTION_GAP` (matches editor chrome so mode
-- switches don't shift it) and `scheduleMapCaretBlink` reads
-- `MDEDIT_CARET_BLINK`. Heading detection (`nodeText`, `linePrefix`,
-- `lineKind`) calls the centralised `MD.heading` rather than a local
-- pattern -- Lua patterns have no `{1,6}`-style quantifier, which is why
-- that helper exists; do not reintroduce a local one. `openControls` below
-- is distinct from `Chrome.show_controls`: it builds this view's own
-- controls item list and calls `Chrome.show_controls` to display it, same
-- as every other controls-menu caller in this codebase.
--
-- Requires KOReader throughout (a full widget-tree/gesture/keyboard set), so
-- this cannot be `require`d and executed under plain luajit -- only
-- `loadfile`-parsed, exactly like main.lua itself -- so no off-device test
-- suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 5, §10
-- step 7): the MindmapView class and all 64 of its methods. Requires
-- `minfolio_map_canvas` for `MindmapCanvas`, which `rebuild` instantiates.
--
-- Required by callers as `local MindmapView = require("minfolio_map_view")`.

local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local LineWidget = require("ui/widget/linewidget")
local IconWidget = require("ui/widget/iconwidget")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local MD = require("minfolio_md")
local Text = require("minfolio_text")
local MapModel = require("minfolio_map_model")
local IO = require("minfolio_io")
local State = require("minfolio_state")
local Style = require("minfolio_style")
local C = require("minfolio_const")
local Keys = require("minfolio_keys")
local Chrome = require("minfolio_chrome")
local MindmapCanvas = require("minfolio_map_canvas")

local MindmapView = InputContainer:extend{ editor = nil, is_always_active = true, disable_double_tap = true }
function MindmapView:init()
    self.fw, self.fh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh }
    self.scale = self.editor and self.editor.scale or State.clamp_minfolio_scale(State.MINFOLIO_STATE.scale)
    self.parent = self
    self.path = self.editor and self.editor.path or ""
    self.root = MapModel.parse_mindmap(self.editor and self.editor:currentText() or "", Text.path_base(self.path))
    self.rows, self.selected, self._undo, self.top_zones = {}, 1, {}, {}
    self.zoom, self.pan_x, self.pan_y = 1, 0, 0
    self.caret_on, self._map_caret_blinking = true, true
    self.canvas_y = C.MAP.MINDMAP_TOPBAR_H + C.MAP.MINDMAP_TOPBAR_TOP_PAD + C.MAP.MINDMAP_TOPBAR_GAP
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
            Pan = { GestureRange:new{ ges = "pan", range = self.dimen } },
            PanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
            Pinch = { GestureRange:new{ ges = "pinch", range = self.dimen } },
            Spread = { GestureRange:new{ ges = "spread", range = self.dimen } },
        }
    end
    self:flatten()
    -- Node height depends on the readable font size at the fitted zoom. A few
    -- passes converge the map bounds before its first paint.
    for _ = 1, 3 do
        self:layoutMap()
        self:fitMap()
    end
    self:rebuild()
    self:scheduleMapCaretBlink()
end

function MindmapView:textw(txt, face)
    if txt == "" then return 0 end
    local tw = TextWidget:new{ text = txt, face = face }
    local w = tw:getSize().w; tw:free(); return w
end

function MindmapView:trimToWidth(text, maxw, face)
    if self:textw(text, face) <= maxw then return text end
    local ell, lo, hi, best = "...", 0, #text, "..."
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local s = text:sub(1, mid) .. ell
        if self:textw(s, face) <= maxw then best = s; lo = mid + 1 else hi = mid - 1 end
    end
    return best
end

function MindmapView:flatten()
    local rows = {}
    local function walk(node, depth)
        if node.kind ~= "root" then rows[#rows+1] = { node = node, depth = depth } end
        for _, child in ipairs(node.children or {}) do walk(child, depth + 1) end
    end
    for _, child in ipairs(self.root.children or {}) do walk(child, 0) end
    local text_lines = Text.split_text_lines(self.editor and self.editor:currentText() or "")
    for i, entry in ipairs(rows) do
        local finish = #text_lines
        for j = i + 1, #rows do if rows[j].depth <= entry.depth then finish = math.max(entry.node.line, rows[j].node.line - 1); break end end
        entry.finish, entry.node.finish = finish, finish
    end
    self.rows = rows
    self.selected = math.max(1, math.min(self.selected or 1, math.max(1, #rows)))
end

function MindmapView:nodeStyle(node)
    if node.kind == "heading" then return "h" .. math.min(3, tonumber(node.level) or 3) end
    if node.kind == "code" then return "code" end
    if node.kind == "quote" then return "quote" end
    if node.kind == "list" then return "bullet" end
    return "normal"
end

function MindmapView:nodeText(node)
    local text = MD.md_trim(node.text)
    local _, _, heading_prefix = MD.heading(text)
    if heading_prefix then text = text:sub(#heading_prefix + 1) end
    if node.kind == "list" and node.task then text = (node.task:match("%[[xX]%]") and "[x] " or "[ ] ") .. text end
    if node.kind == "paragraph" then text = text:gsub("%s*\n%s*", " ") end
    local plain = {}
    for _, span in ipairs(MD.md_inline(text)) do
        if span.style ~= "syntax" then plain[#plain+1] = span.display or span.text or "" end
    end
    text = table.concat(plain)
    return text ~= "" and text or (node.kind == "paragraph" and "Paragraph" or "Untitled")
end

function MindmapView:mapRegion()
    return Geom:new{ x = 0, y = self.canvas_y, w = self.fw, h = math.max(1, self.fh - self.canvas_y) }
end

function MindmapView:mapDirtyTarget()
    -- The map itself is full-screen while the keyboard is a separate window
    -- above it. Repainting only the map would erase the keyboard's pixels
    -- without repainting that top layer.
    return self.keyboard and "all" or self
end

function MindmapView:scheduleMapCaretBlink()
    UIManager:scheduleIn(C.EDIT.MDEDIT_CARET_BLINK, function()
        if not self._map_caret_blinking then return end
        if self.editing_index then
            self.caret_on = not self.caret_on
            UIManager:setDirty(self:mapDirtyTarget(), "ui", self.caret_region or self:mapRegion())
        else
            self.caret_on = false
        end
        self:scheduleMapCaretBlink()
    end)
end

function MindmapView:layoutMap()
    local max_width_by_depth, max_depth = {}, 0
    local function measure(node)
        local style = node.kind == "root" and "h1" or self:nodeStyle(node)
        local text = node.kind == "root" and node.text or (node._edit_text or self:nodeText(node))
        local face = Style.md_face(style, self.scale)
        local text_limit = C.MAP.MINDMAP_NODE_MAX_W - C.MAP.MINDMAP_NODE_TAIL
        node.mw = math.max(C.MAP.MINDMAP_NODE_MIN_W, math.min(C.MAP.MINDMAP_NODE_MAX_W, self:textw(text, face) + C.MAP.MINDMAP_NODE_TAIL))
        node.mlines = self:wrapNodeText(text, math.min(text_limit, node.mw - C.MAP.MINDMAP_NODE_TAIL), face)
        -- The canvas keeps type readable at low zoom (rather than scaling it
        -- below 0.45). Measure that exact rendered face here, then convert its
        -- screen height back to map coordinates. This keeps wrapped labels above
        -- their fixed terminator line instead of letting text paint through it.
        local render_scale = math.max(0.45, self.scale * self.zoom)
        local probe = TextWidget:new{ text = "Hg", face = Style.md_face(style, render_scale) }
        local line_h = probe:getSize().h; probe:free()
        local line_step = math.max(1, line_h - C.MAP.MINDMAP_TEXT_LINE_TIGHTEN)
        local text_h = line_h + math.max(0, #node.mlines - 1) * line_step
        node.mh = math.max(C.MAP.MINDMAP_NODE_H, math.ceil((text_h + C.MAP.MINDMAP_TEXT_BOTTOM_PAD) / self.zoom))
        node._map_depth = node._map_depth or 0
        max_depth = math.max(max_depth, node._map_depth)
        max_width_by_depth[node._map_depth] = math.max(max_width_by_depth[node._map_depth] or 0, node.mw)
        for _, child in ipairs(node.children or {}) do child._map_depth = node._map_depth + 1; measure(child) end
    end
    self.root._map_depth = 0
    measure(self.root)
    local column_x, x = {}, 0
    for depth = 0, max_depth do
        column_x[depth] = x
        x = x + (max_width_by_depth[depth] or C.MAP.MINDMAP_NODE_MIN_W) + C.MAP.MINDMAP_COLUMN_GAP
    end
    local leaf_count, last_leaf_baseline = 0, nil
    local function place(node, depth)
        node.mx = column_x[depth] or 0
        if #node.children == 0 then
            local nominal = C.MAP.MINDMAP_WORLD_TOP + leaf_count * C.MAP.MINDMAP_WORLD_ROW
            -- Labels are bottom-aligned to their terminator line. Expand only
            -- the following branch's gap when its upward-growing label needs it.
            node.baseline = last_leaf_baseline and math.max(
                nominal, last_leaf_baseline + node.mh + C.MAP.MINDMAP_LABEL_GAP
            ) or nominal
            node.my = node.baseline - node.mh
            last_leaf_baseline = node.baseline
            leaf_count = leaf_count + 1
        else
            for _, child in ipairs(node.children) do place(child, depth + 1) end
            node.baseline = (node.children[1].baseline + node.children[#node.children].baseline) / 2
            node.my = node.baseline - node.mh
        end
    end
    place(self.root, 0)

    -- Long parent labels can still collide with a neighbouring parent despite
    -- their children being clear. Resolve those collisions per depth, moving an
    -- entire branch so its internal connector geometry stays intact.
    local by_depth = {}
    local function collect(node)
        local nodes = by_depth[node._map_depth] or {}
        nodes[#nodes + 1] = node
        by_depth[node._map_depth] = nodes
        for _, child in ipairs(node.children) do collect(child) end
    end
    local function shift_branch(node, delta)
        node.baseline, node.my = node.baseline + delta, node.my + delta
        for _, child in ipairs(node.children) do shift_branch(child, delta) end
    end
    local function settle_parents(node)
        if #node.children > 0 then
            for _, child in ipairs(node.children) do settle_parents(child) end
            node.baseline = (node.children[1].baseline + node.children[#node.children].baseline) / 2
            node.my = node.baseline - node.mh
        end
    end
    collect(self.root)
    for depth = max_depth, 1, -1 do
        local previous
        for _, node in ipairs(by_depth[depth] or {}) do
            if previous then
                local delta = previous.baseline + C.MAP.MINDMAP_LABEL_GAP - node.my
                if delta > 0 then shift_branch(node, delta) end
            end
            previous = node
        end
        settle_parents(self.root)
    end
    self.visual_nodes = { { index = 0, node = self.root } }
    for i, entry in ipairs(self.rows) do self.visual_nodes[#self.visual_nodes+1] = { index = i, node = entry.node } end
    self.world_w = math.max(C.MAP.MINDMAP_NODE_MIN_W, x - C.MAP.MINDMAP_COLUMN_GAP)
    local bottom = C.MAP.MINDMAP_WORLD_TOP
    for _, entry in ipairs(self.visual_nodes) do bottom = math.max(bottom, entry.node.baseline) end
    self.world_h = math.max(C.MAP.MINDMAP_NODE_H, bottom + C.MAP.MINDMAP_WORLD_ROW)
end

function MindmapView:wrapNodeText(text, maxw, face)
    local lines, line = {}, ""
    for word in tostring(text or ""):gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if line ~= "" and self:textw(candidate, face) > maxw then
            lines[#lines+1], line = line, word
        else
            line = candidate
        end
    end
    if line ~= "" then lines[#lines+1] = line end
    return #lines > 0 and lines or { "Untitled" }
end

function MindmapView:nodeAt(pos)
    if not pos then return nil end
    local wx = (pos.x - C.MAP.MINDMAP_PAD - self.pan_x) / self.zoom
    local wy = (pos.y - self.canvas_y - self.pan_y) / self.zoom
    local root = self.root
    if root and wx >= root.mx and wx <= root.mx + root.mw and wy >= root.my and wy <= root.my + root.mh then return 0 end
    for i, entry in ipairs(self.rows or {}) do
        local n = entry.node
        if wx >= n.mx and wx <= n.mx + n.mw and wy >= n.my and wy <= n.my + n.mh then return i end
    end
end

function MindmapView:linePrefix(line)
    local _, _, heading_prefix = MD.heading(line)
    local prefix = heading_prefix or line:match("^(%s*>%s?)")
    if prefix then return prefix end
    local indent, marker, body = line:match("^(%s*)([-*+]%s+)(.*)$")
    if not marker then indent, marker, body = line:match("^(%s*)(%d+[.)]%s+)(.*)$") end
    if marker then return (indent or "") .. marker .. ((body or ""):match("^(%[[ xX]%]%s+)") or "") end
    return ""
end

function MindmapView:showMapKeyboard()
    if self.keyboard or not Device:isTouchDevice() then return end
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local keyboard = VirtualKeyboard:new{ inputbox = self }
    Keys.makeKeyboardArrowFree(keyboard)
    Keys.disableKeyboardKeyFlash(keyboard)
    keyboard.modal = false
    self.keyboard = keyboard
    local map, original_close = self, keyboard.onCloseWidget
    function keyboard:onCloseWidget()
        if original_close then original_close(self) end
        if map.keyboard == self then map.keyboard = nil; map:refresh() end
    end
    UIManager:show(keyboard)
end

function MindmapView:hideMapKeyboard()
    if not self.keyboard then return end
    local keyboard = self.keyboard
    self.keyboard = nil
    UIManager:close(keyboard)
end

function MindmapView:beginNodeEdit(index)
    local entry = self.rows and self.rows[index]
    if not entry or not self.editor then return end
    self.selected = index
    local line = (Text.split_text_lines(self.editor:currentText()))[entry.node.line] or ""
    self.editing_index, self.edit_line = index, entry.node.line
    self.caret_on = true
    self.edit_prefix = self:linePrefix(line)
    self.edit_text, self.edit_col = line:sub(#self.edit_prefix + 1), #line - #self.edit_prefix
    entry.node._edit_text = self.edit_text
    self.edit_lines = self:wrapNodeText(self.edit_text, C.MAP.MINDMAP_NODE_MAX_W - C.MAP.MINDMAP_NODE_TAIL, Style.md_face(self:nodeStyle(entry.node), self.scale))
    self:layoutMap()
    self:showMapKeyboard()
    self:refresh()
end

function MindmapView:updateEditLayout()
    local entry = self:selectedEntry()
    if entry then
        entry.node._edit_text = self.edit_text
        self.edit_lines = self:wrapNodeText(self.edit_text, C.MAP.MINDMAP_NODE_MAX_W - C.MAP.MINDMAP_NODE_TAIL, Style.md_face(self:nodeStyle(entry.node), self.scale))
        self:layoutMap()
    end
    self:refresh()
end

function MindmapView:commitNodeEdit()
    if not self.editing_index or not self.editor then return false end
    local line, prefix = self.edit_line, self.edit_prefix
    local text = tostring(self.edit_text or ""):gsub("[\r\n]+", " ")
    local lines = Text.split_text_lines(self.editor:currentText())
    local changed = lines[line] ~= (prefix .. text)
    local entry = self.rows and self.rows[self.editing_index]
    if entry then entry.node._edit_text = nil end
    self.editing_index, self.edit_line, self.edit_prefix, self.edit_text, self.edit_lines = nil, nil, nil, nil, nil
    self.caret_on, self.caret_region = false, nil
    self:hideMapKeyboard()
    if changed then
        self:snapshot()
        lines[line] = prefix .. text
        self:applyLines(lines, line)
    else
        self:refresh()
    end
    return true
end

function MindmapView:cancelNodeEdit()
    if not self.editing_index then return end
    local entry = self.rows and self.rows[self.editing_index]
    if entry then entry.node._edit_text = nil end
    self.editing_index, self.edit_line, self.edit_prefix, self.edit_text, self.edit_lines = nil, nil, nil, nil, nil
    self.caret_on, self.caret_region = false, nil
    self:layoutMap()
    self:hideMapKeyboard()
    self:refresh()
end

-- VirtualKeyboard inputbox interface for the in-place node editor.
function MindmapView:addChars(chars)
    if not self.editing_index then return end
    local before, after = self.edit_text:sub(1, self.edit_col), self.edit_text:sub(self.edit_col + 1)
    self.edit_text = before .. tostring(chars or "") .. after
    self.edit_col = #before + #(tostring(chars or ""))
    self:updateEditLayout()
end
function MindmapView:delChar()
    if self.editing_index and self.edit_col > 0 then
        local start = Text.utf8_left(self.edit_text, self.edit_col)
        self.edit_text, self.edit_col = self.edit_text:sub(1, start) .. self.edit_text:sub(self.edit_col + 1), start
        self:updateEditLayout()
    end
end
function MindmapView:delWord()
    if not self.editing_index then return end
    local start, old = Text.prev_word_col(self.edit_text, self.edit_col), self.edit_col
    self.edit_text, self.edit_col = self.edit_text:sub(1, start) .. self.edit_text:sub(old + 1), start
    self:updateEditLayout()
end
function MindmapView:delToStartOfLine() if self.editing_index then self.edit_text = self.edit_text:sub(self.edit_col + 1); self.edit_col = 0; self:updateEditLayout() end end
function MindmapView:leftChar() if self.editing_index then self.edit_col = Text.utf8_left(self.edit_text, self.edit_col); self:updateEditLayout() end end
function MindmapView:rightChar() if self.editing_index then self.edit_col = Text.utf8_right(self.edit_text, self.edit_col); self:updateEditLayout() end end
function MindmapView:goToStartOfLine() if self.editing_index then self.edit_col = 0; self:updateEditLayout() end end
function MindmapView:goToEndOfLine() if self.editing_index then self.edit_col = #self.edit_text; self:updateEditLayout() end end
function MindmapView:upLine() end
function MindmapView:downLine() end
function MindmapView:scrollUp() end
function MindmapView:scrollDown() end
function MindmapView:onSwitchingKeyboardLayout() end

function MindmapView:fitMap()
    local vw, vh = self.fw - (C.MAP.MINDMAP_PAD * 2), self.fh - self.canvas_y - C.MAP.MINDMAP_PAD
    self.zoom = math.max(C.MAP.MINDMAP_MIN_ZOOM, math.min(1.0, vw / (self.world_w + 40), vh / (self.world_h + 40)))
    self.pan_x = math.floor((vw - self.world_w * self.zoom) / 2)
    self.pan_y = math.floor((vh - self.world_h * self.zoom) / 2)
end

function MindmapView:clampPan()
    local vw, vh = self.fw - (C.MAP.MINDMAP_PAD * 2), self.fh - self.canvas_y - C.MAP.MINDMAP_PAD
    local map_w, map_h = self.world_w * self.zoom, self.world_h * self.zoom
    -- Fitted maps must still be movable. The bounds retain a small visible
    -- slice of content instead of re-centering a map merely because it fits.
    local visible_w = math.min(C.MAP.MINDMAP_PAN_MIN_VISIBLE, map_w)
    local visible_h = math.min(C.MAP.MINDMAP_PAN_MIN_VISIBLE, map_h)
    self.pan_x = math.max(visible_w - map_w, math.min(vw - visible_w, self.pan_x))
    self.pan_y = math.max(visible_h - map_h, math.min(vh - visible_h, self.pan_y))
end

function MindmapView:topBar(cw)
    local title_face = Font:getFace("cfont", 22)
    local action_face = Font:getFace("cfont", 19)
    local raw_title = (Text.path_base(self.path) ~= "" and Text.path_base(self.path) or "Mindmap")
    local labels = {
        { name = "add", text = "Add" },
        { name = "delete", text = "Del" },
        { name = "undo", text = "Undo" },
        { name = "edit", text = "Edit" },
        { name = "close", icon = "close" },
    }
    local action_total = 0
    for _, item in ipairs(labels) do
        item.w = item.icon and C.MAP.MINDMAP_CLOSE_W or math.max(C.MAP.MINDMAP_ACTION_MIN_W, self:textw(item.text, action_face) + 28)
        action_total = action_total + item.w
    end
    action_total = action_total + ((#labels - 1) * C.MAP.MINDMAP_ACTION_DIVIDER)
    local max_title_w = math.max(60, cw - C.EDIT.MDEDIT_MENU_W - C.MAP.MINDMAP_MENU_TITLE_GAP - action_total - C.EDIT.MDEDIT_TITLE_ACTION_GAP)
    local title = self:trimToWidth(raw_title, max_title_w, title_face)
    local title_w = self:textw(title, title_face)
    local gap_w = math.max(C.EDIT.MDEDIT_TITLE_ACTION_GAP, cw - C.EDIT.MDEDIT_MENU_W - C.MAP.MINDMAP_MENU_TITLE_GAP - title_w - action_total)
    local x = C.EDIT.MDEDIT_MENU_W + C.MAP.MINDMAP_MENU_TITLE_GAP
    self.top_zones.menu = { x0 = 0, x1 = C.EDIT.MDEDIT_MENU_W }
    x = x + title_w + gap_w
    local actions = {}
    for i, item in ipairs(labels) do
        if i > 1 then
            actions[#actions+1] = CenterContainer:new{ dimen = Geom:new{ w = C.MAP.MINDMAP_ACTION_DIVIDER, h = C.MAP.MINDMAP_TOPBAR_H },
                LineWidget:new{ background = Blitbuffer.Color8(210), dimen = Geom:new{ w = C.MAP.MINDMAP_ACTION_DIVIDER, h = math.floor(C.MAP.MINDMAP_TOPBAR_H * 0.46) } }
            }
            x = x + C.MAP.MINDMAP_ACTION_DIVIDER
        end
        self.top_zones[item.name] = { x0 = x, x1 = x + item.w }
        actions[#actions+1] = CenterContainer:new{ dimen = Geom:new{ w = item.w, h = C.MAP.MINDMAP_TOPBAR_H },
            item.icon and IconWidget:new{ icon = item.icon, width = Screen:scaleBySize(29), height = Screen:scaleBySize(29) }
                or TextWidget:new{ text = item.text, face = action_face, fgcolor = Blitbuffer.COLOR_BLACK } }
        x = x + item.w
    end
    local content = HorizontalGroup:new{ align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = C.EDIT.MDEDIT_MENU_W, h = C.MAP.MINDMAP_TOPBAR_H },
            IconWidget:new{ icon = "appbar.menu", width = Screen:scaleBySize(24), height = Screen:scaleBySize(24) } },
        HorizontalSpan:new{ width = C.MAP.MINDMAP_MENU_TITLE_GAP },
        CenterContainer:new{ dimen = Geom:new{ w = title_w, h = C.MAP.MINDMAP_TOPBAR_H },
            TextWidget:new{ text = title, face = title_face, fgcolor = Blitbuffer.Color8(110) } },
        HorizontalSpan:new{ width = gap_w },
        HorizontalGroup:new(actions),
    }
    local padded = HorizontalGroup:new{ align = "center",
        HorizontalSpan:new{ width = C.MAP.MINDMAP_TOPBAR_PAD_X }, content,
        HorizontalSpan:new{ width = C.MAP.MINDMAP_TOPBAR_PAD_RIGHT } }
    return CenterContainer:new{ dimen = Geom:new{ w = cw + C.MAP.MINDMAP_TOPBAR_PAD_X + C.MAP.MINDMAP_TOPBAR_PAD_RIGHT, h = C.MAP.MINDMAP_TOPBAR_H + C.MAP.MINDMAP_TOPBAR_TOP_PAD }, padded }
end

function MindmapView:rebuild()
    local cw = self.fw - (C.MAP.MINDMAP_PAD * 2)
    local topbar = self:topBar(self.fw - C.MAP.MINDMAP_TOPBAR_PAD_X - C.MAP.MINDMAP_TOPBAR_PAD_RIGHT)
    local canvas_h = self.fh - self.canvas_y - C.MAP.MINDMAP_PAD
    local canvas = MindmapCanvas:new{ map = self, dimen = Geom:new{ w = cw, h = canvas_h } }
    local vg = VerticalGroup:new{ align = "left", topbar, VerticalSpan:new{ width = C.MAP.MINDMAP_TOPBAR_GAP },
        CenterContainer:new{ dimen = Geom:new{ w = self.fw, h = canvas_h }, canvas } }
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0,
        width = self.fw, height = self.fh, vg }
end

function MindmapView:refresh(region)
    self:rebuild()
    UIManager:setDirty(self:mapDirtyTarget(), "ui", region or self:mapRegion())
end

function MindmapView:selectedEntry()
    return self.rows and self.rows[self.selected or 1] or nil
end

function MindmapView:reloadFromEditor(keep_line)
    self.root = MapModel.parse_mindmap(self.editor and self.editor:currentText() or "", Text.path_base(self.path))
    self:flatten()
    self:layoutMap()
    if keep_line then
        for i, entry in ipairs(self.rows) do
            if entry.node.line and entry.node.line >= keep_line then
                self.selected = i
                break
            end
        end
    end
end

function MindmapView:snapshot()
    if not self.editor then return end
    self._undo[#self._undo+1] = {
        text = self.editor:currentText(),
        selected = self.selected,
        pan_x = self.pan_x, pan_y = self.pan_y, zoom = self.zoom,
    }
    if #self._undo > 80 then table.remove(self._undo, 1) end
end

function MindmapView:applyLines(lines, keep_line)
    if not self.editor then return false end
    local text = table.concat(lines, "\n")
    self.editor.lines = Text.split_text_lines(text)
    self.editor.crow = math.max(1, math.min(keep_line or self.editor.crow or 1, #self.editor.lines))
    self.editor.ccol = math.max(0, math.min(self.editor.ccol or 0, #(self.editor.lines[self.editor.crow] or "")))
    self.editor.sel = nil
    self.editor._vrows_dirty = true
    self.editor:save()
    self:reloadFromEditor(keep_line)
    self:refresh()
    return true
end

function MindmapView:undo()
    local snap = self._undo and table.remove(self._undo)
    if not snap or not self.editor then return Chrome.notify(_("Nothing to undo")) end
    self.editor.lines = Text.split_text_lines(snap.text or "")
    self.editor._vrows_dirty = true
    self.editor:save()
    self.selected = snap.selected or 1
    self.pan_x, self.pan_y, self.zoom = snap.pan_x or 0, snap.pan_y or 0, snap.zoom or self.zoom
    self:reloadFromEditor()
    self:refresh()
end

function MindmapView:rangeFor(index)
    local entry = self.rows and self.rows[index]
    if not entry then return nil end
    return entry.node.line, entry.finish or entry.node.finish or entry.node.line
end

function MindmapView:siblingRange(index, dir)
    local entry = self.rows and self.rows[index]
    if not entry then return nil end
    local parent = entry.node.parent
    local candidate
    for i, row in ipairs(self.rows) do
        if i ~= index and row.node.parent == parent and (row.depth or 0) == (entry.depth or 0) then
            if dir < 0 and i < index then candidate = i
            elseif dir > 0 and i > index then return i end
        end
    end
    return candidate
end

function MindmapView:lineKind(line)
    local hashes = MD.heading(line)
    if hashes then return "heading", #hashes end
    local indent, marker = line:match("^(%s*)([-*+]%s+)")
    if not marker then indent, marker = line:match("^(%s*)(%d+[.)]%s+)") end
    if marker then return "list", #(indent or "") end
    return "paragraph", 0
end

function MindmapView:adjustRangeDepth(lines, first, finish, dir)
    for i = first, finish do
        local line = lines[i] or ""
        local kind = self:lineKind(line)
        if kind == "heading" then
            if dir > 0 then
                lines[i] = "#" .. line
            else
                lines[i] = line:gsub("^#", "", 1)
            end
        elseif kind == "list" then
            if dir > 0 then
                lines[i] = "  " .. line
            else
                lines[i] = line:gsub("^  ", "", 1)
                if lines[i] == line then lines[i] = line:gsub("^%s", "", 1) end
            end
        end
    end
end

function MindmapView:addChild()
    if self.selected == 0 and self.editor then
        local lines = Text.split_text_lines(self.editor:currentText())
        self:snapshot()
        if #lines > 0 and MD.md_trim(lines[#lines] or "") ~= "" then table.insert(lines, "") end
        table.insert(lines, "# New node")
        return self:applyLines(lines, #lines)
    end
    local entry = self:selectedEntry()
    if not entry or not self.editor then return end
    local first, finish = self:rangeFor(self.selected)
    local lines = Text.split_text_lines(self.editor:currentText())
    local line = lines[first] or ""
    local kind, level = self:lineKind(line)
    local new_line
    if kind == "heading" then
        new_line = string.rep("#", math.min(6, level + 1)) .. " New node"
    elseif kind == "list" then
        new_line = string.rep(" ", level + 2) .. "- New node"
    else
        new_line = "- New node"
    end
    self:snapshot()
    table.insert(lines, finish + 1, new_line)
    self:applyLines(lines, finish + 1)
end

function MindmapView:deleteSelected()
    local first, finish = self:rangeFor(self.selected)
    if not first or not self.editor then return end
    local lines = Text.split_text_lines(self.editor:currentText())
    self:snapshot()
    for _ = first, finish do table.remove(lines, first) end
    if #lines == 0 then lines[1] = "" end
    self.selected = math.max(1, math.min(self.selected, math.max(1, #self.rows - 1)))
    self:applyLines(lines, first)
end

function MindmapView:moveSibling(dir)
    local other = self:siblingRange(self.selected, dir)
    if not other or not self.editor then return Chrome.notify(_("No sibling there")) end
    local a1, a2 = self:rangeFor(self.selected)
    local b1, b2 = self:rangeFor(other)
    local lines = Text.split_text_lines(self.editor:currentText())
    self:snapshot()
    if dir < 0 then
        local block_a, block_b = {}, {}
        for i = b1, b2 do block_b[#block_b+1] = lines[i] end
        for i = a1, a2 do block_a[#block_a+1] = lines[i] end
        for _ = b1, a2 do table.remove(lines, b1) end
        for i = #block_a, 1, -1 do table.insert(lines, b1, block_a[i]) end
        for i = #block_b, 1, -1 do table.insert(lines, b1 + #block_a, block_b[i]) end
        self.selected = other
        self:applyLines(lines, b1)
    else
        local block_a, block_b = {}, {}
        for i = a1, a2 do block_a[#block_a+1] = lines[i] end
        for i = b1, b2 do block_b[#block_b+1] = lines[i] end
        for _ = a1, b2 do table.remove(lines, a1) end
        for i = #block_b, 1, -1 do table.insert(lines, a1, block_b[i]) end
        for i = #block_a, 1, -1 do table.insert(lines, a1 + #block_b, block_a[i]) end
        self.selected = other
        self:applyLines(lines, a1 + #block_b)
    end
end

function MindmapView:reattach(dir)
    local first, finish = self:rangeFor(self.selected)
    if not first or not self.editor then return end
    local lines = Text.split_text_lines(self.editor:currentText())
    local line = lines[first] or ""
    local kind, level = self:lineKind(line)
    if dir < 0 and ((kind == "heading" and level <= 1) or (kind == "list" and level <= 0) or kind == "paragraph") then
        return Chrome.notify(_("Cannot outdent this node"))
    end
    if dir > 0 and kind == "heading" and level >= 6 then return Chrome.notify(_("Heading is already deepest")) end
    self:snapshot()
    self:adjustRangeDepth(lines, first, finish, dir)
    self:applyLines(lines, first)
end

function MindmapView:close()
    if self.editing_index then self:commitNodeEdit() end
    self._map_caret_blinking = false
    UIManager:close(self)
    if self.editor then self.editor:refresh{ layout_dirty = false, full = true } end
end

function MindmapView:saveAndClose()
    if self.editing_index then self:commitNodeEdit() end
    self._map_caret_blinking = false
    UIManager:close(self)
    if self.editor then self.editor:saveAndClose() end
end

function MindmapView:openControls()
    Chrome.show_controls({
        { text = "Back to editor", callback = function() self:close() end },
        { text = "Edit selected node", callback = function()
            local entry = self:selectedEntry()
            self:jumpTo(entry and entry.node.line)
        end },
        { text = "Add child node", keep = true, callback = function() self:addChild() end },
        { text = "Delete selected branch", keep = true, callback = function() self:deleteSelected() end },
        { text = "Undo map edit", keep = true, callback = function() self:undo() end },
        { text = "Move branch up", keep = true, callback = function() self:moveSibling(-1) end },
        { text = "Move branch down", keep = true, callback = function() self:moveSibling(1) end },
        { text = "Attach under previous branch", keep = true, callback = function() self:reattach(1) end },
        { text = "Attach to parent branch", keep = true, callback = function() self:reattach(-1) end },
        { text = "Zoom in", keep = true, callback = function() self:zoomAt(nil, 1.25) end },
        { text = "Zoom out", keep = true, callback = function() self:zoomAt(nil, 0.8) end },
        { text = "Fit map to screen", keep = true, callback = function() self:fitMap(); self:refresh() end },
        { text = "Text size +", keep = true, callback = function()
            if self.editor then self.editor:bumpScale(0.1); self.scale = self.editor.scale end
            self:refresh()
        end },
        { text = "Text size -", keep = true, callback = function()
            if self.editor then self.editor:bumpScale(-0.1); self.scale = self.editor.scale end
            self:refresh()
        end },
        { text = "⟲ Rotate screen", callback = function() Chrome.rotate_screen_ccw() end },
    }, function() self:refresh() end)
end

function MindmapView:jumpTo(line)
    if self.editor and line then
        self.editor:setReaderMode(false, line, 0)
    end
    self:close()
end

function MindmapView:onTap(_, ges)
    local p = ges and ges.pos
    if not p then return true end
    if self.editing_index then self:commitNodeEdit() end
    if p.y < 95 then
        local x = p.x - C.MAP.MINDMAP_TOPBAR_PAD_X
        for name, z in pairs(self.top_zones or {}) do
            if x >= z.x0 and x < z.x1 then
                if name == "menu" then self:openControls()
                elseif name == "add" then self:addChild()
                elseif name == "delete" then self:deleteSelected()
                elseif name == "undo" then self:undo()
                elseif name == "edit" then self:close()
                elseif name == "close" then self:saveAndClose() end
                return true
            end
        end
        return true
    end
    local hit = self:nodeAt(p)
    if hit ~= nil then
        local now = IO.now_seconds()
        local last = self._last_node_tap
        if hit > 0 and last and last.index == hit and now - last.t < C.MAP.MINDMAP_EDIT_DTAP
            and math.abs(p.x - last.x) < C.MAP.MINDMAP_EDIT_DTAP_MOVE and math.abs(p.y - last.y) < C.MAP.MINDMAP_EDIT_DTAP_MOVE then
            self._last_node_tap = nil
            self:beginNodeEdit(hit)
        else
            self.selected = hit
            self._last_node_tap = { index = hit, x = p.x, y = p.y, t = now }
            self:refresh()
        end
        return true
    end
    return true
end

function MindmapView:onDoubleTap(_, ges)
    local hit = self:nodeAt(ges and ges.pos)
    if hit then self:beginNodeEdit(hit) end
    return true
end

function MindmapView:onPan(_, ges)
    local p, sp = ges and ges.pos, ges and ges.start_pos
    if not p or not sp then return true end
    local dx, dy = p.x - sp.x, p.y - sp.y
    local horizontal = math.abs(dx) >= math.abs(dy)
    local distance = horizontal and dx or dy
    local steps = math.floor(math.abs(distance) / C.MAP.MINDMAP_PAN_GESTURE)
    local direction = distance < 0 and -1 or 1
    local signature = (horizontal and "x" or "y") .. direction
    if self._pan_signature ~= signature then self._pan_signature, self._pan_moved = signature, false end
    -- Panning is intentionally coarse, like zoom: one small, predictable move
    -- per swipe rather than a viewport-sized jump for every gesture update.
    if steps > 0 and not self._pan_moved then
        if horizontal then self.pan_x = self.pan_x + direction * C.MAP.MINDMAP_PAN_STEP
        else self.pan_y = self.pan_y + direction * C.MAP.MINDMAP_PAN_STEP end
        self:clampPan()
        self._pan_moved = true
        self:refresh()
    end
    return true
end

function MindmapView:onPanRelease()
    self._pan_signature, self._pan_moved = nil, nil
    return true
end

function MindmapView:zoomAt(pos, factor)
    local old = self.zoom
    local new = math.max(C.MAP.MINDMAP_MIN_ZOOM, math.min(C.MAP.MINDMAP_MAX_ZOOM, old * factor))
    if new == old then return end
    local cx = pos and (pos.x - C.MAP.MINDMAP_PAD) or (self.fw - C.MAP.MINDMAP_PAD * 2) / 2
    local cy = pos and (pos.y - self.canvas_y) or (self.fh - self.canvas_y - C.MAP.MINDMAP_PAD) / 2
    local wx, wy = (cx - self.pan_x) / old, (cy - self.pan_y) / old
    self.zoom = new
    self.pan_x, self.pan_y = cx - wx * new, cy - wy * new
    self:layoutMap()
    self:clampPan()
    self:refresh()
end

function MindmapView:onPinch(_, ges)
    self:zoomAt(ges and ges.pos, 1 - math.min(0.35, (ges and ges.distance or 0) / 700))
    return true
end

function MindmapView:onSpread(_, ges)
    self:zoomAt(ges and ges.pos, 1 + math.min(0.5, (ges and ges.distance or 0) / 500))
    return true
end

function MindmapView:centerSelected()
    local entry = self:selectedEntry()
    if not entry then return end
    local n = entry.node
    local vw, vh = self.fw - C.MAP.MINDMAP_PAD * 2, self.fh - self.canvas_y - C.MAP.MINDMAP_PAD
    self.pan_x = vw / 2 - (n.mx + n.mw / 2) * self.zoom
    self.pan_y = vh / 2 - (n.my + C.MAP.MINDMAP_NODE_H / 2) * self.zoom
    self:clampPan()
end

function MindmapView:onKeyPress(key)
    local name = key and key.key
    if not name then return true end
    local mods = Keys.key_mods(key)
    if self.editing_index then
        if name == "Backspace" or name == "BackSpace" then self:delChar()
        elseif name == "Left" then self:leftChar()
        elseif name == "Right" then self:rightChar()
        elseif name == "Home" then self:goToStartOfLine()
        elseif name == "End" then self:goToEndOfLine()
        elseif name == "Press" or name == "Return" or name == "Enter" then self:commitNodeEdit()
        elseif name == "Back" or name == "Esc" or name == "Escape" then self:cancelNodeEdit()
        elseif not Keys.shortcut_mod(mods) and #tostring(name) == 1 then self:addChars(name) end
        return true
    end
    if Keys.up_key(name) then
        self.selected = math.max(1, (self.selected or 1) - 1); self:centerSelected(); self:refresh()
    elseif Keys.down_key(name) then
        self.selected = math.min(#self.rows, (self.selected or 1) + 1); self:centerSelected(); self:refresh()
    elseif Keys.left_key(name) then self:reattach(-1)
    elseif Keys.right_key(name) then self:reattach(1)
    elseif Keys.page_up_key(name) then self:zoomAt(nil, 0.8)
    elseif Keys.page_down_key(name) or name == "Space" or name == "space" or name == " " then self:zoomAt(nil, 1.25)
    elseif name == "+" or name == "=" then self:zoomAt(nil, 1.25)
    elseif name == "-" then self:zoomAt(nil, 0.8)
    elseif tostring(name):lower() == "a" then self:addChild()
    elseif name == "Backspace" or name == "BackSpace" or name == "Del" or name == "Delete" then self:deleteSelected()
    elseif Keys.shortcut_mod(mods) and tostring(name):lower() == "z" then self:undo()
    elseif name == "Press" or name == "Return" or name == "Enter" or name == "KP_Enter" then
        local entry = self:selectedEntry()
        self:jumpTo(entry and entry.node.line)
    elseif name == "Back" or name == "Esc" or name == "Escape" then self:close() end
    return true
end

function MindmapView:onScreenResize()
    self.fw, self.fh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.fw, h = self.fh }
    if self.ges_events then
        for _, ev in pairs(self.ges_events) do
            for _, range in ipairs(ev) do range.range = self.dimen end
        end
    end
    self.canvas_y = C.MAP.MINDMAP_TOPBAR_H + C.MAP.MINDMAP_TOPBAR_TOP_PAD + C.MAP.MINDMAP_TOPBAR_GAP
    self:refresh()
    return true
end

return MindmapView
