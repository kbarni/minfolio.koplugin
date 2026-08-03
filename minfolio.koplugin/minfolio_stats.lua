-- SPDX-License-Identifier: AGPL-3.0-only
-- Document statistics (word/character/line counts) for minfolio.koplugin
-- (PLAN.md §5 Tier 0). Deliberately zero KOReader dependencies: no
-- `require("ui/...")`, no Font, nothing that only exists inside a running
-- KOReader process. That is not a style preference, it is the only way any of
-- this can be checked off-device -- see minfolio_stats_test.lua, runnable with
-- plain lua/luajit, no KOReader install required:
--   luajit minfolio_stats_test.lua
--
-- Counting is done on the document as READ, not as typed: `plain_text` runs the
-- text through MD.md_tokenize and keeps only the spans a reader would see, so
-- "## Heading" is one word and not two, "**bold**" is one word and not one word
-- plus four asterisks, and a fenced block's ``` lines contribute nothing. That
-- is the whole reason this module depends on minfolio_md rather than splitting
-- on whitespace: a word count that disagrees with what is on the screen is
-- worse than no word count.
--
-- Deliberately EXCLUDES any display formatting beyond `group_digits`: the
-- human-readable summary needs gettext for translation, gettext is a KOReader
-- module, and requiring it here would silently delete this module's test
-- coverage (see ARCHITECTURE.md on Tier 0 purity). The editor builds the
-- summary string from these numbers; this module only produces numbers.
--
-- Required by callers as `local Stats = require("minfolio_stats")`.

local MD = require("minfolio_md")

local M = {}

-- Reading speed used by `count`'s `minutes`. 200 wpm is the conventional
-- silent-reading figure and the one most Markdown editors quote.
M.WORDS_PER_MINUTE = 200

-- Multi-byte characters that are punctuation, not letters. Needed because the
-- word test below treats any non-ASCII lead byte as evidence of a real word
-- (that is what makes accented and non-Latin text count at all), and without
-- this list a lone em dash between two spaces would count as a word.
-- Every byte here is >= 0x80, so none of them is a Lua pattern magic
-- character and all of them are safe to pass to gsub unescaped.
M.UNICODE_PUNCT = {
    "\226\128\148",  -- U+2014 em dash
    "\226\128\147",  -- U+2013 en dash
    "\226\128\166",  -- U+2026 horizontal ellipsis
    "\226\128\152",  -- U+2018 left single quote
    "\226\128\153",  -- U+2019 right single quote
    "\226\128\156",  -- U+201C left double quote
    "\226\128\157",  -- U+201D right double quote
    "\226\128\162",  -- U+2022 bullet
}

-- Is this whitespace-delimited token a word rather than stray punctuation?
--
-- Table rows and separator lines are the reason this is not simply "any run of
-- non-space characters": counting `| a | b |` as five words (three of them
-- pipes) and `|---|---|` as one is exactly the kind of wrong number that makes
-- a word count untrustworthy. A token counts when something remains after the
-- punctuation is taken out: an ASCII letter or digit, or any multi-byte
-- character not on the M.UNICODE_PUNCT list.
--
-- KNOWN LIMIT, accepted deliberately: scripts written without spaces (Chinese,
-- Japanese) count as one word per run, not per character. Doing better needs
-- per-script segmentation rules, which is a great deal of machinery for a
-- feature whose job is to tell an English-language writer roughly how much they
-- have written.
function M.is_word(token)
    local t = tostring(token or "")
    for _, punct in ipairs(M.UNICODE_PUNCT) do t = t:gsub(punct, "") end
    if t:match("[%a%d]") then return true end
    for i = 1, #t do
        -- 0x80..0xBF are continuation bytes; a lead byte is >= 0xC0.
        if t:byte(i) >= 0xC0 then return true end
    end
    return false
end

function M.count_words(str)
    local words = 0
    for token in tostring(str or ""):gmatch("%S+") do
        if M.is_word(token) then words = words + 1 end
    end
    return words
end

-- Characters, not bytes: a count in bytes would report "café" as five
-- characters. Returns total characters and characters excluding whitespace.
function M.count_chars(str)
    str = tostring(str or "")
    local chars, visible = 0, 0
    for i = 1, #str do
        local b = str:byte(i)
        if b < 0x80 or b >= 0xC0 then      -- skip UTF-8 continuation bytes
            chars = chars + 1
            -- A multi-byte character's lead byte is never ASCII whitespace, so
            -- this single-byte test is safe for the visible count too.
            if not str:sub(i, i):match("%s") then visible = visible + 1 end
        end
    end
    return chars, visible
end

-- The document as a reader sees it: Markdown syntax removed, line structure
-- kept (so line and paragraph counts stay meaningful). Syntax spans (heading
-- hashes, emphasis markers, blockquote markers, highlight markers), list
-- bullets and task checkboxes are dropped; their text content is kept. A
-- fenced block's opening and closing lines become empty, while the code inside
-- is kept -- it is content the writer typed and can see.
function M.plain_text(text)
    local out = {}
    for _, token in ipairs(MD.md_tokenize(text)) do
        if token.block == "code_fence" then
            out[#out+1] = ""
        else
            local parts = {}
            for _, span in ipairs(token.spans or {}) do
                local style = span.style
                if style ~= "syntax" and style ~= "bullet" and style ~= "task" then
                    parts[#parts+1] = span.text or ""
                end
            end
            out[#out+1] = table.concat(parts)
        end
    end
    return table.concat(out, "\n")
end

-- Every number the word-count display needs, from one pass over the text:
--   words, chars, chars_no_spaces, lines, paragraphs, minutes
-- `lines` counts lines of source (matching what the editor's row numbers mean);
-- `paragraphs` counts runs of non-blank lines in the rendered text.
function M.count(text)
    local plain = M.plain_text(text)
    local lines, paragraphs, in_paragraph = 0, 0, false
    for line in (plain .. "\n"):gmatch("(.-)\n") do
        lines = lines + 1
        if line:match("^%s*$") then
            in_paragraph = false
        elseif not in_paragraph then
            in_paragraph = true
            paragraphs = paragraphs + 1
        end
    end
    local words = M.count_words(plain)
    local chars, chars_no_spaces = M.count_chars(plain)
    return {
        words = words,
        chars = chars,
        chars_no_spaces = chars_no_spaces,
        lines = lines,
        paragraphs = paragraphs,
        minutes = M.reading_minutes(words),
    }
end

-- Whole minutes at M.WORDS_PER_MINUTE, rounded up, because "0 min" reads as
-- broken rather than as short. An empty document is the one honest zero.
function M.reading_minutes(words)
    words = tonumber(words) or 0
    if words <= 0 then return 0 end
    return math.max(1, math.ceil(words / M.WORDS_PER_MINUTE))
end

-- 12345 -> "12,345". A five-digit word count is unreadable on a small screen
-- without this, and Lua has no locale-aware number formatting to lean on.
function M.group_digits(n, sep)
    sep = sep or ","
    local digits = tostring(math.floor(tonumber(n) or 0))
    local sign = ""
    if digits:sub(1, 1) == "-" then sign, digits = "-", digits:sub(2) end
    while true do
        local grouped, replaced = digits:gsub("^(%d+)(%d%d%d)", "%1" .. sep .. "%2")
        digits = grouped
        if replaced == 0 then break end
    end
    return sign .. digits
end

return M
