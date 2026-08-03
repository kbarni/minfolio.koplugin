-- SPDX-License-Identifier: AGPL-3.0-only
-- Off-device unit tests for minfolio_stats.lua (PLAN.md §7.1). Run with plain lua/luajit, no
-- KOReader install required:
--   luajit minfolio_stats_test.lua
-- Exit code is 0 iff every assertion passed.

package.path = (arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or ".") .. "/?.lua;" .. package.path
local Stats = require("minfolio_stats")

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
-- is_word: the punctuation filter that keeps table pipes and separator rows out
-- of the count.
-- ---------------------------------------------------------------------------

check("is_word: an ordinary word is a word", Stats.is_word("hello") == true)
check("is_word: a number is a word", Stats.is_word("42") == true)
check("is_word: a word with attached punctuation is still one word", Stats.is_word("end.") == true)
check("is_word: a bare table pipe is not a word", Stats.is_word("|") == false)
check("is_word: a table separator run is not a word", Stats.is_word("|---|---|") == false)
check("is_word: an ASCII double dash is not a word", Stats.is_word("--") == false)
check("is_word: an ellipsis of dots is not a word", Stats.is_word("...") == false)
check("is_word: the empty string is not a word", Stats.is_word("") == false)
check("is_word: nil is not a word", Stats.is_word(nil) == false)

do
    -- Accented text reaches the ASCII branch via its unaccented letters.
    check("is_word: an accented word counts (café)", Stats.is_word("caf\195\169") == true)
    -- A word made only of multi-byte characters counts via the lead-byte test.
    check("is_word: a non-Latin word with no ASCII letters counts",
        Stats.is_word("\230\151\165\230\156\172") == true)
end

do
    -- The M.UNICODE_PUNCT list exists exactly for these: multi-byte characters
    -- whose lead byte would otherwise be read as evidence of a word.
    check("is_word: a lone em dash is not a word", Stats.is_word("\226\128\148") == false)
    check("is_word: a lone en dash is not a word", Stats.is_word("\226\128\147") == false)
    check("is_word: a lone unicode ellipsis is not a word", Stats.is_word("\226\128\166") == false)
    check("is_word: a lone curly apostrophe is not a word", Stats.is_word("\226\128\153") == false)
    check("is_word: a word in curly quotes is still a word",
        Stats.is_word("\226\128\156word\226\128\157") == true)
    -- Removing the punctuation must not remove the word with it.
    check("is_word: an em-dash-joined pair is a word", Stats.is_word("a\226\128\148b") == true)
end

-- ---------------------------------------------------------------------------
-- count_words / count_chars on plain strings
-- ---------------------------------------------------------------------------

check("count_words: simple sentence", Stats.count_words("one two three") == 3)
check("count_words: runs of whitespace do not create empty words",
    Stats.count_words("one   two\t\tthree") == 3)
check("count_words: leading and trailing whitespace ignored", Stats.count_words("  one two  ") == 2)
check("count_words: the empty string has no words", Stats.count_words("") == 0)
check("count_words: nil has no words", Stats.count_words(nil) == 0)
check("count_words: whitespace only has no words", Stats.count_words("   \t \n ") == 0)
check("count_words: a table row counts its cells, not its pipes",
    Stats.count_words("| alpha | beta |") == 2)

do
    local chars, visible = Stats.count_chars("ab c")
    check("count_chars: counts every character including the space", chars == 4)
    check("count_chars: the no-spaces count excludes the space", visible == 3)
end

do
    -- "café" is 5 BYTES but 4 characters -- the whole reason this is not #str.
    local chars, visible = Stats.count_chars("caf\195\169")
    check("count_chars: a 2-byte character counts as one character, not two", chars == 4)
    check("count_chars: multibyte characters count as visible", visible == 4)
end

do
    -- 4-byte character (emoji U+1F600).
    local chars = Stats.count_chars("\240\159\152\128")
    check("count_chars: a 4-byte character counts as exactly one character", chars == 1)
end

do
    local chars, visible = Stats.count_chars("a\tb\nc")
    check("count_chars: tabs and newlines are characters", chars == 5)
    check("count_chars: tabs and newlines are not visible characters", visible == 3)
end

do
    local chars, visible = Stats.count_chars("")
    check("count_chars: empty string is zero and zero", chars == 0 and visible == 0)
end

-- ---------------------------------------------------------------------------
-- plain_text: Markdown syntax comes out, content stays in. This is what makes
-- the count agree with what is on screen.
-- ---------------------------------------------------------------------------

check("plain_text: heading hashes are dropped, the heading text is kept",
    Stats.plain_text("## Chapter one") == "Chapter one")
check("plain_text: emphasis markers are dropped, the emphasised text is kept",
    Stats.plain_text("a **bold** word") == "a bold word")
check("plain_text: italic markers are dropped", Stats.plain_text("an *italic* word") == "an italic word")
check("plain_text: inline code backticks are dropped, the code is kept",
    Stats.plain_text("call `foo()` now") == "call foo() now")
check("plain_text: highlight markers are dropped, the highlighted text is kept",
    Stats.plain_text("a ==marked== word") == "a marked word")
check("plain_text: a bullet marker is dropped, the item text is kept",
    Stats.plain_text("- an item") == "an item")
check("plain_text: an ordered marker is dropped", Stats.plain_text("1. an item") == "an item")
check("plain_text: a checkbox is dropped, the task text is kept",
    Stats.plain_text("- [ ] a task") == "a task")
check("plain_text: a checked checkbox is dropped too",
    Stats.plain_text("- [x] a done task") == "a done task")
check("plain_text: a blockquote marker is dropped, the quote is kept",
    Stats.plain_text("> quoted words") == "quoted words")

do
    -- Fence lines contribute nothing; the code between them is content.
    local text = "```lua\nlocal x = 1\n```"
    check("plain_text: fence lines become empty and the code survives",
        Stats.plain_text(text) == "\nlocal x = 1\n")
    check("plain_text: an unclosed fence still drops its opening line",
        Stats.plain_text("```\ncode") == "\ncode")
end

check("plain_text: line structure is preserved", Stats.plain_text("a\nb\nc") == "a\nb\nc")
check("plain_text: blank lines are preserved", Stats.plain_text("a\n\nb") == "a\n\nb")
check("plain_text: plain text passes through unchanged", Stats.plain_text("nothing special here") == "nothing special here")
check("plain_text: the empty document is empty", Stats.plain_text("") == "")

-- ---------------------------------------------------------------------------
-- count: the aggregate the word-count dialog displays.
-- ---------------------------------------------------------------------------

do
    local c = Stats.count("# Title\n\nSome **bold** words here.\n")
    -- "Title" + "Some bold words here." = 1 + 4 = 5 words; the ** never counts.
    check("count: markdown syntax does not inflate the word count", c.words == 5)
    check("count: lines counts source lines including the trailing blank", c.lines == 4)
    check("count: paragraphs counts runs of non-blank lines", c.paragraphs == 2)
end

do
    local c = Stats.count("")
    check("count: an empty document has no words", c.words == 0)
    check("count: an empty document has no paragraphs", c.paragraphs == 0)
    check("count: an empty document still has one line", c.lines == 1)
    check("count: an empty document has zero reading minutes", c.minutes == 0)
end

do
    local c = Stats.count("one\ntwo\n\nthree\nfour\n\n\nfive")
    check("count: consecutive blank lines do not start extra paragraphs", c.paragraphs == 3)
    check("count: every source line is counted", c.lines == 8)
end

do
    local c = Stats.count("| alpha | beta |\n|---|---|\n| one | two |")
    -- Pipes and the separator row contribute nothing; four cell words remain.
    check("count: a markdown table counts its cell words only", c.words == 4)
end

do
    local c = Stats.count("word ")
    check("count: chars_no_spaces excludes the trailing space", c.chars_no_spaces == 4)
    check("count: chars includes the trailing space", c.chars == 5)
end

-- ---------------------------------------------------------------------------
-- reading_minutes
-- ---------------------------------------------------------------------------

check("reading_minutes: zero words is zero minutes, not one", Stats.reading_minutes(0) == 0)
check("reading_minutes: a single word rounds up to one minute", Stats.reading_minutes(1) == 1)
check("reading_minutes: exactly one minute's worth is one minute",
    Stats.reading_minutes(Stats.WORDS_PER_MINUTE) == 1)
check("reading_minutes: one word over rounds up to two minutes",
    Stats.reading_minutes(Stats.WORDS_PER_MINUTE + 1) == 2)
check("reading_minutes: nil is treated as zero words", Stats.reading_minutes(nil) == 0)
check("reading_minutes: a negative count cannot produce negative minutes", Stats.reading_minutes(-5) == 0)

-- ---------------------------------------------------------------------------
-- group_digits
-- ---------------------------------------------------------------------------

check("group_digits: under a thousand is unchanged", Stats.group_digits(42) == "42")
check("group_digits: exactly a thousand gets one separator", Stats.group_digits(1000) == "1,000")
check("group_digits: four digits", Stats.group_digits(1234) == "1,234")
check("group_digits: seven digits get two separators", Stats.group_digits(1234567) == "1,234,567")
check("group_digits: zero", Stats.group_digits(0) == "0")
check("group_digits: a negative number keeps its sign outside the grouping",
    Stats.group_digits(-1234) == "-1,234")
check("group_digits: the separator is overridable", Stats.group_digits(1234, " ") == "1 234")
check("group_digits: nil counts as zero", Stats.group_digits(nil) == "0")

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
