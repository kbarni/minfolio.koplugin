-- SPDX-License-Identifier: AGPL-3.0-only
-- Render-facing markdown style helpers for minfolio.koplugin (PLAN.md §5 Tier 1):
-- the half of the original single-file markdown renderer that needs real KOReader
-- widgets, deliberately left behind when the pure parsing half (md_inline,
-- md_tokenize, ...) was extracted to minfolio_md.lua in a previous work package.
-- Requires KOReader: `md_face` needs `Font` (`Font:getFace`), `md_color` needs
-- `Blitbuffer`. Because it requires real KOReader modules, this cannot be
-- `require`d and executed under plain luajit -- only `loadfile`-parsed, exactly
-- like main.lua itself -- so no off-device test suite is included.
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 1, §10 step 4):
-- MD_FACES, md_face, md_color, MDEDIT_TABLE_PAD_X, MDEDIT_TABLE_PAD_Y.
-- The last two carry the MDEDIT_ prefix but lived outside main.lua's main
-- MDEDIT_*/MINDMAP_* constant block and are grouped here rather than in
-- minfolio_const.lua, matching PLAN.md §4/§11 and INVENTORY.md §7.
--
-- MD_LH was moved here and then DELETED: it had no call site anywhere, in
-- main.lua or any module. Removed at the repo owner's request.
--
-- Required by callers as `local Style = require("minfolio_style")`.

local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")

local M = {}

-- tokenize text -> array of lines, each {block=<style>, spans={{text,style},...}}
M.MD_FACES = {
    normal = {"cfont", 22}, h1 = {"tfont", 34}, h2 = {"tfont", 29}, h3 = {"tfont", 25},
    bullet = {"cfont", 22}, task = {"cfont", 22}, quote = {"cfont", 22}, bold = {"tfont", 22}, italic = {"ifont", 22},
    code = {"infont", 20}, syntax = {"cfont", 22},
}
M.MDEDIT_TABLE_PAD_X = 8
M.MDEDIT_TABLE_PAD_Y = 5

function M.md_face(style, scale)
    local f = M.MD_FACES[style] or M.MD_FACES.normal
    return Font:getFace(f[1], math.floor(f[2] * (scale or 1)))
end

function M.md_color(style)
    if style == "syntax" then return Blitbuffer.COLOR_WHITE end
    if style == "code" then return Blitbuffer.Color8(55) end
    if style == "quote" then return Blitbuffer.Color8(95) end
    return Blitbuffer.COLOR_BLACK
end

return M
