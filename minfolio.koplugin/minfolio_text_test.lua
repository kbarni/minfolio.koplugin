-- SPDX-License-Identifier: AGPL-3.0-only
-- Off-device unit tests for minfolio_text.lua (PLAN.md §7.1). Run with plain lua/luajit, no
-- KOReader install required:
--   luajit minfolio_text_test.lua
-- Exit code is 0 iff every assertion passed.

package.path = (arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or ".") .. "/?.lua;" .. package.path
local Text = require("minfolio_text")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL: " .. label .. "\n")
    end
end

-- ---------------------------------------------------------------------------
-- utf8_left / utf8_right / utf8_snap: movement across multibyte characters.
-- Continuation bytes are 0x80..0xBF; a lead byte for a 2/3/4-byte sequence is >= 0xC0.
-- ---------------------------------------------------------------------------

do
    -- "café" = c(1) a(1) f(1) é(2 bytes: 0xC3 0xA9) -> byte length 5.
    local s = "caf\195\169"
    check("utf8_left: from end of string steps back over the whole 2-byte char, not 1 byte",
        Text.utf8_left(s, #s) == 3)
    check("utf8_right: from before the 2-byte char steps forward over the whole char",
        Text.utf8_right(s, 3) == #s)
    check("utf8_left: from col 0 clamps to 0 (does not go negative)", Text.utf8_left(s, 0) == 0)
    check("utf8_right: from end of string clamps to end (does not overrun)", Text.utf8_right(s, #s) == #s)
end

do
    -- Em-dash is 3 bytes (0xE2 0x80 0x94, per kinbox_wrap_test.lua's identical fixture).
    local em = "\226\128\148"
    local s = "before " .. em .. " after"
    local lead = #"before "
    check("utf8_left: single call from just after a 3-byte char lands on its lead byte",
        Text.utf8_left(s, lead + #em) == lead)
    check("utf8_right: single call from the lead byte lands just past the whole 3-byte char",
        Text.utf8_right(s, lead) == lead + #em)
end

do
    -- utf8_snap: a byte index INSIDE a multibyte char's continuation bytes must walk back to
    -- the char's lead byte, matching kinbox_wrap_test.lua's identical convention for the same
    -- primitive (kinbox_wrap.lua's utf8_snap, ported from this same codebase).
    local em = "\226\128\148"  -- 3-byte em-dash
    local s = "Framework " .. em .. " Final"
    local lead = #"Framework "
    check("utf8_snap: offset 1 into a 3-byte char walks back to the lead byte", Text.utf8_snap(s, lead + 1) == lead)
    check("utf8_snap: offset 2 into a 3-byte char walks back to the lead byte", Text.utf8_snap(s, lead + 2) == lead)
    check("utf8_snap: exactly on the lead byte boundary is unchanged", Text.utf8_snap(s, lead) == lead)
    -- NOTE (verified against the actual source, not assumed): unlike kinbox_wrap.lua's
    -- similarly-named utf8_snap, minfolio_md's utf8_snap does NOT clamp an out-of-range index
    -- -- its loop guard is `c > 0 and c < #s`, which is simply false for c <= 0 or c >= #s, so
    -- the input is returned completely unchanged rather than clamped into [0, #s]. This is a
    -- pre-existing behavioural difference in the moved code, preserved verbatim; every call
    -- site in main.lua happens to pass an already in-range column, so this is latent, not a
    -- bug being introduced by the move -- flagged here so it isn't mistaken for a test bug.
    check("utf8_snap: an index past the end is returned UNCHANGED, not clamped (real behaviour)",
        Text.utf8_snap(s, #s + 5) == #s + 5)
    check("utf8_snap: a negative index is returned UNCHANGED, not clamped to 0 (real behaviour)",
        Text.utf8_snap(s, -3) == -3)
    check("utf8_snap: exactly zero is returned as zero (0 > 0 is false, loop never runs)",
        Text.utf8_snap(s, 0) == 0)
    check("utf8_snap: pure ASCII input is the identity function", Text.utf8_snap("plain text", 5) == 5)
end

do
    -- 4-byte character (an emoji, U+1F600 = 0xF0 0x9F 0x98 0x80).
    local emoji = "\240\159\152\128"
    local s = "hi " .. emoji .. " there"
    local lead = #"hi "
    check("utf8_left: steps back over a full 4-byte character", Text.utf8_left(s, lead + #emoji) == lead)
    check("utf8_right: steps forward over a full 4-byte character", Text.utf8_right(s, lead) == lead + #emoji)
end

-- ---------------------------------------------------------------------------
-- char_is_space
-- ---------------------------------------------------------------------------

check("char_is_space: a single space is a space", Text.char_is_space(" ") == true)
check("char_is_space: a tab is a space", Text.char_is_space("\t") == true)
check("char_is_space: an empty string is NOT a space (explicit s ~= \"\" guard)", Text.char_is_space("") == false)
check("char_is_space: a letter is not a space", Text.char_is_space("a") == false)
check("char_is_space: a multi-char string never matches (pattern is anchored ^%s$)", Text.char_is_space("  ") == false)

-- ---------------------------------------------------------------------------
-- prev_word_col / next_word_col: word-boundary movement.
-- ---------------------------------------------------------------------------

do
    local s = "hello world foo"
    -- Column convention throughout main.lua is a BYTE offset where the cursor sits BEFORE
    -- position c+1 (0 = start of string). From the end, prev_word_col must land at the start
    -- of the last word ("foo" starts at byte 13, 0-indexed col 12).
    check("prev_word_col: from end of string, lands at the start of the last word",
        Text.prev_word_col(s, #s) == 12)
    check("next_word_col: from start of string, lands at the end of the first word",
        Text.next_word_col(s, 0) == 5)
end

do
    local s = "one  two"  -- two spaces between words
    check("prev_word_col: skips over multiple consecutive spaces, not just one",
        Text.prev_word_col(s, #s) == 5)
    check("next_word_col: skips over multiple consecutive spaces, not just one",
        Text.next_word_col(s, 0) == 3)
end

do
    local s = "word"
    check("prev_word_col: a single word with no spaces goes straight to column 0",
        Text.prev_word_col(s, #s) == 0)
    check("next_word_col: a single word with no spaces goes straight to the end",
        Text.next_word_col(s, 0) == #s)
end

do
    check("prev_word_col: already at column 0 stays at 0 (no underflow)",
        Text.prev_word_col("hello", 0) == 0)
    check("next_word_col: already at the end stays there (no overflow)",
        Text.next_word_col("hello", 5) == 5)
end

do
    -- Word motion must not split a multibyte character: verified against the same 2-byte
    -- "café" fixture used for utf8_left/right above, landing exactly on the char boundary.
    local s = "caf\195\169 word"
    local lead = #"caf\195\169"  -- 5 bytes
    check("next_word_col: from inside the first word, lands after the multibyte char intact",
        Text.next_word_col(s, 0) == lead)
end

do
    -- Starting in the MIDDLE of a word (not at a boundary) must walk to the start of that
    -- same word, not skip past it -- this is the two-phase walk (skip non-space, then skip
    -- space) that both functions implement.
    local s = "hello world"
    check("prev_word_col: from mid-word, lands at the start of the CURRENT word", Text.prev_word_col(s, 8) == 6)
    check("next_word_col: from mid-word, lands at the end of the CURRENT word", Text.next_word_col(s, 2) == 5)
end

-- ---------------------------------------------------------------------------
-- split_text_lines
-- ---------------------------------------------------------------------------

do
    local lines = Text.split_text_lines("a\nb\nc")
    check("split_text_lines: three lines split correctly", #lines == 3 and lines[1] == "a" and lines[2] == "b" and lines[3] == "c")
end

check("split_text_lines: empty string still returns one (empty) line, not zero",
    #Text.split_text_lines("") == 1 and Text.split_text_lines("")[1] == "")

do
    local lines = Text.split_text_lines("a\n\nb")
    check("split_text_lines: a blank line in the middle is preserved as an empty string entry",
        #lines == 3 and lines[2] == "")
end

check("split_text_lines: nil input treated as empty text (one empty line)",
    #Text.split_text_lines(nil) == 1 and Text.split_text_lines(nil)[1] == "")

do
    local lines = Text.split_text_lines("trailing newline\n")
    check("split_text_lines: a trailing newline does not create a spurious extra empty final line beyond the blank",
        #lines == 2 and lines[1] == "trailing newline" and lines[2] == "")
end

-- ---------------------------------------------------------------------------
-- path_join / path_base / is_markdown_file
-- ---------------------------------------------------------------------------

check("path_join: ordinary directory + name", Text.path_join("/mnt/us/notes", "todo.md") == "/mnt/us/notes/todo.md")
check("path_join: root directory does not get a doubled slash", Text.path_join("/", "todo.md") == "/todo.md")

check("path_base: strips directory, keeps filename", Text.path_base("/mnt/us/notes/todo.md") == "todo.md")
check("path_base: a bare filename with no slash is returned unchanged", Text.path_base("todo.md") == "todo.md")
check("path_base: trailing slash(es) stripped before taking the base name", Text.path_base("/mnt/us/notes/") == "notes")
check("path_base: root path collapses to root itself (no basename below it)", Text.path_base("/") == "")

check("is_markdown_file: lowercase .md extension matches", Text.is_markdown_file("note.md") == true)
check("is_markdown_file: matching is case-insensitive (.MD)", Text.is_markdown_file("NOTE.MD") == true)
check("is_markdown_file: a non-markdown extension does not match", Text.is_markdown_file("note.txt") == false)
check("is_markdown_file: a bare directory name with no extension does not match", Text.is_markdown_file("notes") == false)

-- ---------------------------------------------------------------------------
-- copy_arr
-- ---------------------------------------------------------------------------

do
    local original = { "a", "b", "c" }
    local copy = Text.copy_arr(original)
    check("copy_arr: produces an array with the same contents", #copy == 3 and copy[1] == "a" and copy[2] == "b" and copy[3] == "c")
    copy[1] = "changed"
    check("copy_arr: is a real copy, not a reference (mutating the copy leaves the original untouched)",
        original[1] == "a")
end

check("copy_arr: an empty array copies to an empty array", #Text.copy_arr({}) == 0)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
