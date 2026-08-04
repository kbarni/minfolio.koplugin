-- SPDX-License-Identifier: AGPL-3.0-only
-- Layout/timing constants for the editor (MDEDIT_*) and mindmap (MINDMAP_*) for
-- minfolio.koplugin (PLAN.md §5 Tier 1, §4). Requires KOReader: ten of these are
-- computed at load time from real widget/DPI state (`Blitbuffer.Color8(190)`,
-- `Size.padding.large`/`.small`, and seven `Screen:scaleBySize(...)` calls), so
-- this module requires `device` (for `Screen`), `ui/size`, and `ffi/blitbuffer`,
-- and bakes DPI at require time exactly as main.lua baked it at chunk-load time
-- before this move. Do not defer these into a function or make the require lazy
-- -- that would change *when* DPI gets baked, which is out of scope for this
-- move (PLAN.md §11). Because it requires real KOReader modules, this cannot be
-- `require`d and executed under plain luajit -- only `loadfile`-parsed, exactly
-- like main.lua itself -- so no off-device test suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 1, §10 step 4):
-- all 58 MDEDIT_*/MINDMAP_* constants that lived in the single load-time block,
-- returned here as `{ EDIT = {...}, MAP = {...} }`.
--
-- The EDIT/MAP split is not clean (PLAN.md §4/§11):
-- MINDMAP_TOPBAR_TOP_PAD is defined as MDEDIT_PAD (a definition-time
-- cross-reference, resolved below by reading EDIT.MDEDIT_PAD while building MAP),
-- and mindmap code elsewhere in main.lua reads MDEDIT_MENU_W, MDEDIT_TITLE_ACTION_GAP,
-- and MDEDIT_CARET_BLINK directly (ordinary C.EDIT.* lookups at their call sites,
-- same as any other cross-tier constant use -- no special handling needed there).
--
-- Deliberately EXCLUDES MDEDIT_TABLE_PAD_X/MDEDIT_TABLE_PAD_Y: despite the
-- MDEDIT_ prefix, they live outside this constant block in main.lua and are
-- grouped with the render-facing minfolio_style.lua module instead (PLAN.md §4).
--
-- Required by callers as `local C = require("minfolio_const")`.

local Screen = require("device").screen
local Size = require("ui/size")
local Blitbuffer = require("ffi/blitbuffer")

local M = {}

M.EDIT = {
    MDEDIT_PAD = 24,
    MDEDIT_TOPBAR_H = 56,
    MDEDIT_TOPBAR_GAP = 14,
    MDEDIT_TOOL_MIN_CELL = 72,
    MDEDIT_TOOL_DIVIDER = 1,
    MDEDIT_TITLE_ACTION_GAP = 18,
    MDEDIT_MENU_W = 52,
    MDEDIT_TITLE_W = 360,
    MDEDIT_PROGRESS_H = 2,
    MDEDIT_PROGRESS_GAP = 10,
    MDEDIT_LINE_HEIGHT = 0.80,
    MDEDIT_LINE_GAP = 0,
    MDEDIT_PARA_GAP = 12,
    MDEDIT_CARET_BLINK = 0.55,
    MDEDIT_CARET_RESUME_DELAY = 0.70,
    MDEDIT_SELECT_PAN_MIN = 18,
    MDEDIT_EDIT_SCROLL_PAN_MIN = 42,
    MDEDIT_PAGE_PAN_MIN = 24,   -- min vertical drag (px) that triggers a page turn
    MDEDIT_EDIT_DTAP = 0.22,    -- edit-mode double-tap must be deliberate; same cursor cell prevents reposition taps selecting
    MDEDIT_EDIT_DTAP_MOVE = 18,
    MDEDIT_READER_DTAP = 0.25,  -- reader double-tap must land within this fast window (also the single-tap page delay)
    MDEDIT_READER_EDGE = 130,   -- reader taps within this many px of the L/R/bottom edge are page-turns, never an exit
    MDEDIT_AUTOSAVE_DELAY = 1.0,
    MDEDIT_TYPE_FIRST_FLUSH_DELAY = 0.02,
    MDEDIT_TYPE_FLUSH_DELAY = 0.045,
    MDEDIT_TYPE_BURST_IDLE = 0.30,
    MDEDIT_FILE_RELOAD_INTERVAL = 2.0,
    MDEDIT_KEYBOARD_SWIPE_EDGE = 90,
    MDEDIT_KEYBOARD_SWIPE_DY = 35,
    -- Hairline gap kept between the last text row and the keyboard's top edge, so the
    -- text can run down into the strip that catches the swipe-to-hide gesture without
    -- sitting flush against the keys.
    MDEDIT_KBD_TEXT_GAP = 8,
    -- Light-gray fill drawn behind ==highlighted== text (distinct from the darker
    -- selection gray, and light enough to keep black text legible on e-ink).
    MDEDIT_HIGHLIGHT_GRAY = Blitbuffer.Color8(190),
    -- Band drawn behind a fenced code block, full text width, every row of the
    -- block plus MDEDIT_CODE_PAD above and below. Much lighter than the
    -- highlight gray: it covers whole paragraphs rather than a few words, and
    -- has to stay quiet under monospace text on e-ink.
    MDEDIT_CODE_GRAY = Blitbuffer.Color8(228),
    MDEDIT_CODE_PAD = 8,
}

M.MAP = {
    MINDMAP_PAD = 34,
    MINDMAP_TOPBAR_H = 56,
    MINDMAP_TOPBAR_GAP = 16,
    MINDMAP_TOPBAR_PAD_X = Size.padding.large,
    MINDMAP_TOPBAR_PAD_RIGHT = Size.padding.small,
    -- Match the editor's top framing so mode switches do not shift the chrome.
    MINDMAP_TOPBAR_TOP_PAD = M.EDIT.MDEDIT_PAD,
    MINDMAP_CLOSE_W = Screen:scaleBySize(50),
    MINDMAP_ACTION_DIVIDER = 1,
    MINDMAP_MENU_TITLE_GAP = Screen:scaleBySize(18),
    MINDMAP_ACTION_MIN_W = Screen:scaleBySize(64),
    MINDMAP_EDIT_DTAP = 0.30,
    MINDMAP_EDIT_DTAP_MOVE = 28,
    MINDMAP_WORLD_TOP = 80,
    MINDMAP_WORLD_ROW = 54,
    MINDMAP_LABEL_GAP = 8,
    MINDMAP_NODE_MIN_W = 200,
    MINDMAP_NODE_MAX_W = 560,
    MINDMAP_NODE_TAIL = 110,
    MINDMAP_COLUMN_GAP = 90,
    MINDMAP_NODE_H = 30,
    MINDMAP_TEXT_BOTTOM_PAD = Screen:scaleBySize(5),
    MINDMAP_TEXT_LINE_TIGHTEN = Screen:scaleBySize(7),
    MINDMAP_MIN_ZOOM = 0.38,
    MINDMAP_MAX_ZOOM = 2.2,
    MINDMAP_PAN_GESTURE = 70,
    MINDMAP_PAN_STEP = Screen:scaleBySize(100),
    MINDMAP_PAN_MIN_VISIBLE = Screen:scaleBySize(80),
}

M.PALETTE = {
    -- How long the command palette waits after the last keystroke before it
    -- re-filters and repaints (PALETTE_PLAN.md §5.4). Filtering per character
    -- would cost one partial e-ink refresh per character, which no Kindle keeps
    -- up with; the editor's own type buffer exists for exactly this reason. Long
    -- enough to coalesce a burst of typing, short enough that a deliberate pause
    -- feels answered.
    FILTER_DEBOUNCE = 0.35,
}

return M
