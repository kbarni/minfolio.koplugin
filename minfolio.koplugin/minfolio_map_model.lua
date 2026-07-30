-- SPDX-License-Identifier: AGPL-3.0-only
-- Pure mindmap tree model for minfolio.koplugin (PLAN.md §5 Tier 0). Deliberately zero
-- KOReader dependencies: no `require("ui/...")`, nothing that only exists inside a running
-- KOReader process. That is not a style preference, it is the only way any of this can be
-- checked off-device -- see minfolio_map_model_test.lua, runnable with plain lua/luajit, no
-- KOReader install required:
--   luajit minfolio_map_model_test.lua
--
-- Ported verbatim from minfolio.koplugin/main.lua (PLAN.md §5 Tier 0, §10 step 2):
-- mindmap_node, parse_mindmap. Mirrors the desktop mindmap's forgiving parser: headings,
-- lists, paragraphs, blockquotes and fenced code blocks all become nodes in one depth stack.
-- The Kindle view stays native and edits Markdown ranges directly, so the editor and map share
-- one source of truth and one interpretation.
--
-- Depends on the other two Tier 0 modules only (both KOReader-free): minfolio_md (md_trim) and
-- minfolio_text (split_text_lines).
--
-- Required by callers as `local MapModel = require("minfolio_map_model")`.

local MD = require("minfolio_md")
local Text = require("minfolio_text")

local M = {}

function M.mindmap_node(kind, text, line, depth, extra)
    local node = {
        kind = kind,
        text = MD.md_trim(text),
        line = line,
        depth = depth or 1,
        children = {},
    }
    if extra then for k, v in pairs(extra) do node[k] = v end end
    return node
end

function M.parse_mindmap(markdown, title)
    local lines = Text.split_text_lines(tostring(markdown or ""):gsub("\r\n", "\n"))
    local root = M.mindmap_node("root", title or "Mindmap", 1, 0)
    local stack = { { depth = 0, node = root } }
    local heading_level = 0
    local i = 1

    local function attach(depth, node)
        while #stack > 1 and stack[#stack].depth >= depth do table.remove(stack) end
        local parent = stack[#stack].node
        node.parent = parent
        parent.children[#parent.children+1] = node
        stack[#stack+1] = { depth = depth, node = node }
    end

    while i <= #lines do
        local line = lines[i] or ""
        if MD.md_trim(line) == "" then
            i = i + 1
        else
            local hashes, htext = line:match("^(#{1,6})%s+(.*)$")
            if hashes then
                local level = #hashes
                heading_level = level
                attach(level, M.mindmap_node("heading", htext, i, level, { level = level }))
                i = i + 1
            else
                local fence, info = line:match("^%s*(```)(.*)$")
                if not fence then fence, info = line:match("^%s*(~~~)(.*)$") end
                if fence then
                    local marker = fence
                    local start_line = i
                    local raw = { line }
                    i = i + 1
                    while i <= #lines do
                        raw[#raw+1] = lines[i]
                        if lines[i]:match("^%s*" .. marker) then i = i + 1; break end
                        i = i + 1
                    end
                    attach(heading_level + 1, M.mindmap_node("code", (MD.md_trim(info) ~= "" and ("``` " .. MD.md_trim(info)) or "``` code"), start_line, heading_level + 1, { raw = raw }))
                elseif line:match("^%s*>") then
                    local start_line = i
                    local parts = {}
                    while i <= #lines and (lines[i] or ""):match("^%s*>") do
                        parts[#parts+1] = (lines[i] or ""):gsub("^%s*>%s?", "")
                        i = i + 1
                    end
                    attach(heading_level + 1, M.mindmap_node("quote", MD.md_trim(table.concat(parts, " ")) ~= "" and table.concat(parts, " ") or "Quote", start_line, heading_level + 1))
                else
                    local indent, marker, rest = line:match("^(%s*)([-*+]%s+)(.*)$")
                    local ordered = false
                    if not marker then
                        indent, marker, rest = line:match("^(%s*)(%d+[.)]%s+)(.*)$")
                        ordered = marker ~= nil
                    end
                    if marker then
                        local nindent = #(tostring(indent or ""):gsub("\t", "  "))
                        local depth = heading_level + 1 + math.floor(nindent / 2)
                        local task, body = rest:match("^(%[[ xX]%]%s+)(.*)$")
                        attach(depth, M.mindmap_node("list", task and body or rest, i, depth, {
                            marker = marker,
                            ordered = ordered,
                            task = task,
                        }))
                        i = i + 1
                    else
                        local start_line = i
                        local parts = {}
                        while i <= #lines do
                            local l = lines[i] or ""
                            if MD.md_trim(l) == "" then break end
                            if l:match("^(#{1,6})%s+") or l:match("^%s*[-*+]%s+") or l:match("^%s*%d+[.)]%s+")
                                or l:match("^%s*>") or l:match("^%s*```") or l:match("^%s*~~~") then break end
                            parts[#parts+1] = l
                            i = i + 1
                        end
                        attach(heading_level + 1, M.mindmap_node("paragraph", table.concat(parts, "\n"), start_line, heading_level + 1))
                    end
                end
            end
        end
    end

    if #root.children == 0 then
        root.children[1] = M.mindmap_node("heading", "Mindmap", 1, 1, { level = 1, parent = root })
    end
    return root
end

return M
