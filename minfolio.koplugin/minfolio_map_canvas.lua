-- SPDX-License-Identifier: AGPL-3.0-only
-- MindmapCanvas: the low-level e-ink paint widget for the native mindmap view
-- (PLAN.md §5 Tier 5, §10 step 7). Split out from minfolio_map_view.lua
-- specifically to respect the ~900-line module-size rule -- PLAN.md §5's own
-- Tier 5 table calls this out by name: "MindmapCanvas (1108-1177) -- split
-- out to respect the size rule" -- even though MindmapView itself (~830
-- lines) is under that limit on its own.
--
-- A plain `Widget:extend{}`, not an InputContainer: it never receives
-- gestures or key events directly. MindmapView (minfolio_map_view.lua) owns
-- the surrounding InputContainer, handles all input, and reconstructs a
-- fresh canvas on every `rebuild` (`MindmapCanvas:new{ map = self, dimen =
-- ... }`). `paintTo` below reads `self.map` and calls methods on it
-- (`map:nodeStyle(n)`, `map:textw(...)`, `map:nodeText(n)`) -- this is a
-- duck-typed read of whatever live object was passed in as `map` at
-- construction time, not a static reference to the MindmapView class, so
-- this module does NOT require minfolio_map_view. The dependency runs one
-- way only: minfolio_map_view requires minfolio_map_canvas, never the
-- reverse.
--
-- Requires KOReader (`ui/widget/widget`, `ui/geometry`, `ui/widget/textwidget`,
-- `ffi/blitbuffer`), so this cannot be `require`d and executed under plain
-- luajit -- only `loadfile`-parsed, exactly like main.lua itself -- so no
-- off-device test suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 5, §10
-- step 7): the MindmapCanvas class and both its methods (`getSize`,
-- `paintTo`).
--
-- Required by callers as `local MindmapCanvas = require("minfolio_map_canvas")`.

local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local Blitbuffer = require("ffi/blitbuffer")
local Style = require("minfolio_style")
local C = require("minfolio_const")

local MindmapCanvas = Widget:extend{}
function MindmapCanvas:getSize() return self.dimen end
function MindmapCanvas:paintTo(bb, x, y)
    local map = self.map
    local w, h = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    local function px(v) return math.floor(x + map.pan_x + v * map.zoom) end
    local function py(v) return math.floor(y + map.pan_y + v * map.zoom) end
    local function rect(rx, ry, rw, rh, color)
        local x0, y0, x1, y1 = math.max(x, rx), math.max(y, ry), math.min(x + w, rx + rw), math.min(y + h, ry + rh)
        if x1 > x0 and y1 > y0 then bb:paintRect(x0, y0, x1 - x0, y1 - y0, color) end
    end
    -- E-ink has no inexpensive anti-aliased path primitive. Clean elbows aligned
    -- to each node's visible rule read better than a stepped faux curve.
    for _, entry in ipairs(map.visual_nodes or {}) do
        local node = entry.node
        if node.parent and node.parent.mx then
            local p, n = node.parent, node
            local x1, y1 = px(p.mx + p.mw), py(p.my + p.mh)
            local x2, y2 = px(n.mx), py(n.my + n.mh)
            if not (math.max(x1, x2) < x or math.min(x1, x2) > x + w or math.max(y1, y2) < y or math.min(y1, y2) > y + h) then
                local stroke = math.max(1, math.floor(map.zoom))
                local mid = math.floor((x1 + x2) / 2)
                local color = Blitbuffer.Color8(105)
                rect(math.min(x1, mid), y1 - stroke, math.abs(mid - x1) + stroke, stroke, color)
                rect(mid - stroke, math.min(y1, y2), stroke, math.abs(y2 - y1) + stroke, color)
                rect(math.min(mid, x2), y2 - stroke, math.abs(x2 - mid) + stroke, stroke, color)
            end
        end
    end
    for _, entry in ipairs(map.visual_nodes or {}) do
        local n = entry.node
        local nx, ny = px(n.mx), py(n.my)
        local nw, nh = math.max(2, math.floor(n.mw * map.zoom)), math.max(2, math.floor(n.mh * map.zoom))
        local selected = entry.index == map.selected
        local style = n.kind == "root" and "h1" or map:nodeStyle(n)
        if nx + nw >= x and nx <= x + w and ny + nh >= y and ny <= y + h and nw > 22 and nh > 12 then
            local face = Style.md_face(style, math.max(0.45, map.scale * map.zoom))
            local lines = (selected and map.editing_index == entry.index and map.edit_lines) or n.mlines or { map:nodeText(n) }
            local ty = ny + 1
            local edit_cursor, chars_before, cursor_drawn = selected and map.editing_index == entry.index and map.edit_col, 0, false
            for line_i, text in ipairs(lines) do
                local tw = TextWidget:new{ text = text, face = face, fgcolor = Style.md_color(style) }
                local ts = tw:getSize()
                -- TextWidget paints directly into the BlitBuffer and does not
                -- safely clip negative/off-edge coordinates. Nodes can straddle
                -- the viewport while panning, so only paint fully visible text.
                if nx >= x and nx + ts.w <= x + w and ty >= y and ty + ts.h <= y + h then
                    tw:paintTo(bb, nx, ty)
                end
                if edit_cursor and map.caret_on and not cursor_drawn and (edit_cursor <= chars_before + #text or line_i == #lines) then
                    local col = math.max(0, math.min(#text, edit_cursor - chars_before))
                    local caret_x = nx + map:textw(text:sub(1, col), face)
                    rect(caret_x, ty, math.max(2, math.floor(map.zoom * 2)), ts.h, Blitbuffer.COLOR_BLACK)
                    map.caret_region = Geom:new{ x = caret_x, y = ty, w = math.max(2, math.floor(map.zoom * 2)), h = ts.h }
                    cursor_drawn = true
                end
                chars_before = chars_before + #text + 1
                if line_i < #lines then
                    ty = ty + math.max(1, ts.h - C.MAP.MINDMAP_TEXT_LINE_TIGHTEN)
                end
                tw:free()
            end
        end
        -- The only node chrome is its terminator line, matching Minfolio's map.
        local line_y = ny + nh - math.max(1, math.floor(map.zoom))
        rect(nx, line_y, nw, selected and math.max(4, math.floor(map.zoom * 3)) or math.max(1, math.floor(map.zoom)), selected and Blitbuffer.COLOR_BLACK or Blitbuffer.Color8(105))
    end
end

return MindmapCanvas
