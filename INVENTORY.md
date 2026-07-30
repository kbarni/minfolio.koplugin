# Minfolio main.lua — Inventory (Work Package A, step 0)

Target file: `minfolio.koplugin/main.lua`, 5,755 lines. All line numbers below are
absolute, taken with `grep -n` / mechanical extraction against the **whole
file**, never against an extracted region, per the instruction that caused
v1's line-number errors. Method start/end ranges were derived from
`luajit -bl main.lua` bytecode-prototype listings (`-- BYTECODE --
main.lua:START-END`), which LuaJIT emits from the actual parse — this is
exact, not a diff-of-consecutive-starts heuristic, and was spot-checked by
reading the real source at several boundaries (confirmed exact, e.g.
`MDEdit:init` 2043–2093, ending at the literal `end` on line 2093).

`main.lua` was confirmed to `loadfile`-parse cleanly under
`/opt/homebrew/bin/luajit`. It was not executed (KOReader is not installed
locally, and the file eagerly `require`s ~30 KOReader modules at load).

## Corrections to PLAN.md

Five factual corrections and one internal inconsistency, found by mechanical
re-derivation against the whole file:

1. **The plan's own "five forward-declared locals" table misattributes line
   5225.** §4/§6.3/§11 all cite "5211/5225" as the two `active_mdedit`
   nil-tolerant guards. Line 5211 is correct
   (`if active_mdedit and not active_mdedit._closing then`, in `edit_note`).
   **Line 5225 is not an `active_mdedit` guard at all** — it reads
   `if show_file_manager then show_file_manager(path_parent(path)) end`, a
   guard on the *different* forward-declared symbol `show_file_manager`. The
   second genuine `active_mdedit` guard is at **line 5265**
   (`if active_mdedit and active_mdedit.remote and active_mdedit.remote.session_id == session_id then`,
   in `MinfolioRemote.stop`). This is exactly the class of error the plan
   itself was written to stop repeating (v1's `awk`-relative-read-as-absolute
   mistake) — see §6 below for the corrected guard inventory.

2. **The "nine computed constants" claim undercounts by one.** §4/§11 state
   "Nine are computed at load time from KOReader" and then list line numbers
   972, 976, 977, 980, 982, 983, 994, 995, 999, 1000 — **that is ten distinct
   line numbers**, not nine. Mechanically re-verified: there are exactly 10
   KOReader-computed constants (1 `Blitbuffer.Color8`, 2 `Size.padding.*`, 7
   `Screen:scaleBySize(...)`). See §7.

3. **§9.2's `checkRemoteInbox` undo/redo-clear citation is off by one line.**
   The plan says the method "clears undo/redo when it does apply (3608)".
   The actual assignment `self._undo, self._redo = {}, {}` is on **line
   3607**; line 3608 is the following statement
   (`self._file_text, self._file_signature = text, file_signature(self.path)`).
   Minor, but the same category of error as (1).

4. **The "198 top-level local variables / zero headroom" claim is imprecise
   in a way that changes the story slightly.** Mechanically re-verified with
   the probe the plan itself describes (`local __probe = 1` appended
   immediately before the final `return Minfolio`, not after it — appending
   *after* a chunk's `return` is itself a syntax error and must not be
   mistaken for the local-limit error): the file fails to compile with
   `main function has more than 200 local variables`, confirming "zero
   headroom" is correct. But **the true count is exactly 200 local
   variable *names*, not 198**: there are 198 top-level `local` *statements*,
   but one of them (line 917) declares three names in a single statement
   (`local open_markdown_picker, rotate_screen_ccw, show_file_manager`), so
   198 statements yield 200 names. The file is not "198 used, 2 free before
   the wall appears at 201" — it is compiled at *exactly* the 200-name
   ceiling already. Conclusion is unchanged (zero headroom), but "198" should
   read "200" everywhere the plan uses it as a variable count (§1, §3, §6.4).

5. **New nil-tolerant guard not in the plan's risk register: line 154.**
   `MinfolioPair.post` reads `local sock = MinfolioRemote and
   MinfolioRemote.socket(cfg, 2)` — a guard on the **`MinfolioRemote`
   global itself**, not on any of the five symbols the plan's §6.3/§11 list
   names. See §6 for what silently breaks. This one is architecturally
   informative beyond being a missed inventory item: `MinfolioPair.post`
   (defined at line 153, inside the pairing code near the top of the file)
   reads the global `MinfolioRemote` **1,854 lines before `MinfolioRemote =
   {}` is assigned at line 2007**. This only works today because
   `MinfolioRemote` is a global — a forward reference through a global
   resolves at *call* time, not parse time. It is direct evidence for the
   plan's own §1 rationale (globals exist here specifically to dodge
   ordering/local-budget constraints) and for why `minfolio_pair.lua` must
   `require("minfolio_remote")` explicitly once `MinfolioRemote` becomes a
   module return — the current code has no such explicit dependency
   declaration; it relies on global load order (pairing code runs its
   `MinfolioPair.start()` tick only after the whole file, including line
   2007, has executed).

6. **Internal inconsistency: the plan's own §5 tier tables enumerate 22
   modules, not "~14".** §5's opening line says "~14 modules, flat,
   `minfolio_`-prefixed", and §14's review-response table again says
   "adjudicated... in favour of... ~14 modules; editor 8 → 4". Counting the
   actual rows in §5's own Tier 0–5 tables: Tier 0 = 3 (`minfolio_md`,
   `minfolio_text`, `minfolio_map_model`), Tier 1 = 8 (`minfolio_config`,
   `minfolio_io`, `minfolio_state`, `minfolio_style`, `minfolio_const`,
   `minfolio_keys`, `minfolio_frontlight`, `minfolio_chrome`), Tier 2 = 2
   (`minfolio_remote`, `minfolio_pair`), Tier 3 = 1 (`minfolio_app`), Tier 4
   = 4 (`minfolio_edit_layout`, `minfolio_edit_tables`, `minfolio_edit_view`,
   `minfolio_edit`), Tier 5 = 4 (`minfolio_map_view`, `minfolio_map_canvas`,
   `minfolio_browser`, `main.lua`). **3+8+2+1+4+4 = 22**, not 14 (23 if
   `minfolio_sync.lua` — explicitly "unchanged, separate process" — were
   counted too, which it should not be). This matters concretely for this
   deliverable's §8: the budget projection below is done for all 22 real
   modules, and for the migration sequence (§10/§12), since a work package
   sized for "~14 modules" understates the number of deploy/parse-check/test
   units by more than half.

Additionally, two things worth flagging though they are not contradictions of
a specific plan claim:

- **Suspected dead code**: `status_date_text` (221), `status_time_text`
  (224), and `battery_status_text` (229) are defined but have **zero call
  sites anywhere in the file** (verified by exhaustive grep). They look like
  an earlier or alternate status-bar implementation superseded by
  `battery_info`/`battery_indicator` (261, which *is* used, extensively, by
  `show_file_manager`). Worth a decision (drop, or confirm truly dead) before
  they get carried into `minfolio_chrome.lua` as live-looking code.
- Section 3 below is much larger than the plan's two named examples
  (`free_wrap_entry`, `md_clipboard`) because most of Tier 0/1 (`minfolio_md`,
  `minfolio_text`, `minfolio_keys`, `minfolio_io`, `minfolio_chrome`, …) is,
  by design, a shared-utility layer called from nearly every other tier —
  that fan-out is normal and expected (it just becomes `require()` edges),
  not a hazard in the same sense as `free_wrap_entry`/`md_clipboard`. The
  write-up below distinguishes the two categories explicitly.

## 1. MDEdit method assignment map

All 160 `function MDEdit:` methods (confirmed: `grep -c "^function MDEdit:" main.lua` = 160), 2043–5205.
Target modules per §5 Tier 4: `minfolio_edit_layout` (18), `minfolio_edit_tables`
(11), `minfolio_edit_view` (28), `minfolio_edit` (103). 18+11+28+103 = 160.

"Basis" is `explicit` when the plan's §5 Tier-4 text names the method or its
family by name; `JUDGEMENT` when I assigned it myself, with the one-line
rationale in the next column. 79 of 160 rows are JUDGEMENT calls (the
remaining 81 are explicit or directly implied by an explicit family name) —
the plan itself warned that v1 had assigned "roughly a third" of the 160 and
left the rest to judgement; this inventory assigns the other two-thirds, and
about half of *those* required genuine judgement rather than a literal name
match, concentrated in three families: the dirty-region/caret-blink internals
of `minfolio_edit_view` (15 of its 28 rows), the visual-row coordinate math
split between `minfolio_edit_layout` and `minfolio_edit` (`pointToCursor`,
`colAtX`, `cursorInRows`, `rowXAt` and neighbours), and the general
lifecycle/input-handling residue of `minfolio_edit` itself.

Two mixin-assembly notes from reading every method body (§6.2 of the plan):
confirmed **no method body references the `MDEdit` class table by name** and
**all 160 are `function MDEdit:` (colon/self) form**, so verbatim moves plus
class-table assignment dispatch correctly, as the plan claims. The "Override?"
column flags every method whose name matches KOReader's `onXxx`
event-dispatch convention (or `getSize`/`paintTo`, the `Widget` base
interface) — these are exactly the methods the `rawget` guard in §6.2 exists
to protect, because `InputContainer`/`Widget` may already define a
same-named method upstream. Only two are **confirmed** overrides (per the
plan, verified against KOReader source the plan's authors apparently had
access to at some point): `onKeyPress` (4533) and
`onPhysicalKeyboardDisconnected` (4472). All other `onXxx`/`getSize`/`paintTo`
methods are marked **unconfirmed** per the task instructions — I have no
local KOReader checkout to verify against, and `luajit -bl` on a
`loadfile`-only parse cannot resolve inherited-class membership.

| Start | End | Lines | Method | Target module | Basis | Rationale | Override? |
|---|---|---|---|---|---|---|---|
| 2043 | 2093 | 51 | `init` | `minfolio_edit` | explicit | lifecycle, explicit | no (not a KOReader-convention callback name) |
| 2097 | 2122 | 26 | `restorePosition` | `minfolio_edit` | explicit | explicit: savePosition/restorePosition | no (not a KOReader-convention callback name) |
| 2123 | 2136 | 14 | `savePosition` | `minfolio_edit` | explicit | explicit: savePosition/restorePosition | no (not a KOReader-convention callback name) |
| 2138 | 2141 | 4 | `caret` | `minfolio_edit_view` | JUDGEMENT | builds the caret LineWidget; sole caller is rebuild() (view) - part of caret-blink rendering family | no (not a KOReader-convention callback name) |
| 2142 | 2180 | 39 | `scheduleCaretBlink` | `minfolio_edit_view` | explicit | explicit: caret blink | no (not a KOReader-convention callback name) |
| 2185 | 2189 | 5 | `pauseCaretBlinkForInput` | `minfolio_edit_view` | explicit | explicit: caret blink | no (not a KOReader-convention callback name) |
| 2190 | 2194 | 5 | `textw` | `minfolio_edit_layout` | explicit | explicit: textw/texth/wordw | no (not a KOReader-convention callback name) |
| 2195 | 2202 | 8 | `texth` | `minfolio_edit_layout` | explicit | explicit: textw/texth/wordw | no (not a KOReader-convention callback name) |
| 2203 | 2210 | 8 | `wordw` | `minfolio_edit_layout` | explicit | explicit: textw/texth/wordw | no (not a KOReader-convention callback name) |
| 2211 | 2216 | 6 | `rowTextHeight` | `minfolio_edit_layout` | JUDGEMENT | measurement-cache family built directly on texth; same domain as explicit textw/texth/wordw | no (not a KOReader-convention callback name) |
| 2217 | 2220 | 4 | `rowHeight` | `minfolio_edit_layout` | JUDGEMENT | measurement-cache family built directly on rowTextHeight | no (not a KOReader-convention callback name) |
| 2221 | 2231 | 11 | `trimToWidth` | `minfolio_edit_layout` | JUDGEMENT | measurement family built directly on textw (title truncation uses it, but the computation itself is pure text measurement) | no (not a KOReader-convention callback name) |
| 2232 | 2237 | 6 | `toolCell` | `minfolio_edit_view` | explicit | explicit: top bar (toolCell named) | no (not a KOReader-convention callback name) |
| 2238 | 2241 | 4 | `toolDivider` | `minfolio_edit_view` | JUDGEMENT | top-bar rendering helper, adjacent to/used only by toolCell/buildTopBar | no (not a KOReader-convention callback name) |
| 2242 | 2265 | 24 | `progressBar` | `minfolio_edit_view` | explicit | explicit: progress bar | no (not a KOReader-convention callback name) |
| 2266 | 2271 | 6 | `menuGlyph` | `minfolio_edit_view` | JUDGEMENT | top-bar rendering helper used only by buildTopBar | no (not a KOReader-convention callback name) |
| 2272 | 2362 | 91 | `buildTopBar` | `minfolio_edit_view` | explicit | explicit: top bar | no (not a KOReader-convention callback name) |
| 2366 | 2380 | 15 | `topBar` | `minfolio_edit_view` | explicit | explicit: top bar | no (not a KOReader-convention callback name) |
| 2381 | 2409 | 29 | `pointToCursor` | `minfolio_edit` | JUDGEMENT | screen-tap-to-cursor translation; all callers are gesture handlers (onTap/onDoubleTap/onPan/onPanRelease) in the input-handling family; reads row_map built by rebuild() (view) and calls colAtX/tableColAtX (layout/tables) via self: dispatch | no (not a KOReader-convention callback name) |
| 2410 | 2443 | 34 | `visibleWordRange` | `minfolio_edit` | JUDGEMENT | word-boundary support for selectWordAt; selection family | no (not a KOReader-convention callback name) |
| 2444 | 2454 | 11 | `selectWordAt` | `minfolio_edit` | explicit | explicit: selection | no (not a KOReader-convention callback name) |
| 2455 | 2463 | 9 | `currentWordRange` | `minfolio_edit` | JUDGEMENT | word-boundary support used by fmtWrap (text ops); selection family | no (not a KOReader-convention callback name) |
| 2465 | 2512 | 48 | `layoutLine` | `minfolio_edit_layout` | explicit | explicit: wrapping | no (not a KOReader-convention callback name) |
| 2520 | 2536 | 17 | `renderRow` | `minfolio_edit_view` | JUDGEMENT | shapes/caches TextWidgets for painting; primary caller is rebuild() (view); tables' tableCell also calls it via self: dispatch (safe, mixin methods) | no (not a KOReader-convention callback name) |
| 2537 | 2549 | 13 | `tableInlineSpans` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2550 | 2556 | 7 | `tableInlineWidth` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2560 | 2603 | 44 | `wrapTableCell` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2604 | 2682 | 79 | `layoutTable` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2683 | 2728 | 46 | `tableCell` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2729 | 2735 | 7 | `renderTableRow` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2736 | 2752 | 17 | `tableColAtX` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2753 | 2776 | 24 | `tableCellAtX` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2777 | 2785 | 9 | `tableCellAtPos` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2786 | 2799 | 14 | `replaceTableCell` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2800 | 2893 | 94 | `openTableCellEditor` | `minfolio_edit_tables` | explicit | explicit: contiguous 2537-2893 | no (not a KOReader-convention callback name) |
| 2894 | 2901 | 8 | `cursorInRows` | `minfolio_edit_layout` | JUDGEMENT | visual-row/x coordinate math; used by cursorVisual (explicit layout) | no (not a KOReader-convention callback name) |
| 2902 | 2925 | 24 | `colAtX` | `minfolio_edit_layout` | JUDGEMENT | visual-row byte-column math; used by pointToCursor and moveCursorVisual (layout) | no (not a KOReader-convention callback name) |
| 2937 | 2988 | 52 | `computeVisualRows` | `minfolio_edit_layout` | explicit | explicit: computeVisualRows | no (not a KOReader-convention callback name) |
| 2991 | 3007 | 17 | `visualRows` | `minfolio_edit_layout` | explicit | explicit: visualRows | no (not a KOReader-convention callback name) |
| 3008 | 3018 | 11 | `reindexVisualRows` | `minfolio_edit_layout` | explicit | explicit: reindexVisualRows | no (not a KOReader-convention callback name) |
| 3021 | 3052 | 32 | `updateVisualLine` | `minfolio_edit_layout` | JUDGEMENT | incremental visual-row rebuild; same family as computeVisualRows/visualRows | no (not a KOReader-convention callback name) |
| 3055 | 3067 | 13 | `cursorVisual` | `minfolio_edit_layout` | JUDGEMENT | locates caret within cached visual rows; visual-row family | no (not a KOReader-convention callback name) |
| 3068 | 3070 | 3 | `textWidth` | `minfolio_edit_layout` | explicit | explicit: textWidth | no (not a KOReader-convention callback name) |
| 3071 | 3091 | 21 | `moveCursorVisual` | `minfolio_edit_layout` | JUDGEMENT | visual-row cursor navigation; same family as cursorVisual | no (not a KOReader-convention callback name) |
| 3092 | 3096 | 5 | `visualRowHeight` | `minfolio_edit_layout` | explicit | explicit: visualRowHeight | no (not a KOReader-convention callback name) |
| 3097 | 3252 | 156 | `rebuild` | `minfolio_edit_view` | explicit | explicit: rebuild | no (not a KOReader-convention callback name) |
| 3255 | 3265 | 11 | `lineBand` | `minfolio_edit_view` | explicit | explicit: dirty regions, lineBand | no (not a KOReader-convention callback name) |
| 3272 | 3288 | 17 | `cursorRowBand` | `minfolio_edit_view` | explicit | explicit: dirty regions, cursorRowBand | no (not a KOReader-convention callback name) |
| 3292 | 3305 | 14 | `rowPaintKey` | `minfolio_edit_view` | JUDGEMENT | dirty-region diffing helper used by changedLineRegions (explicit view) | no (not a KOReader-convention callback name) |
| 3309 | 3337 | 29 | `rowPrefixPaintKey` | `minfolio_edit_view` | JUDGEMENT | dirty-region diffing helper used by changedLineRegions (explicit view) | no (not a KOReader-convention callback name) |
| 3341 | 3348 | 8 | `previousGlyphX` | `minfolio_edit_view` | JUDGEMENT | dirty-region pixel-boundary helper used by changedLineRegions (explicit view) | no (not a KOReader-convention callback name) |
| 3354 | 3398 | 45 | `changedLineRegions` | `minfolio_edit_view` | explicit | explicit: changedLineRegions | no (not a KOReader-convention callback name) |
| 3403 | 3408 | 6 | `regionFromLineToBottom` | `minfolio_edit_view` | JUDGEMENT | dirty-region family, used by refresh() | no (not a KOReader-convention callback name) |
| 3413 | 3427 | 15 | `regionFromCursorRowToBottom` | `minfolio_edit_view` | JUDGEMENT | dirty-region family, used by refresh() | no (not a KOReader-convention callback name) |
| 3428 | 3436 | 9 | `unionRegion` | `minfolio_edit_view` | JUDGEMENT | dirty-region family, used by refresh()/scheduleCaretBlink | no (not a KOReader-convention callback name) |
| 3437 | 3440 | 4 | `selectionIsMultiline` | `minfolio_edit_view` | JUDGEMENT | used only by refresh()'s dirty-region decision logic | no (not a KOReader-convention callback name) |
| 3441 | 3448 | 8 | `caretRowTop` | `minfolio_edit_view` | JUDGEMENT | dirty-region family, used by regionFromCaretTransitionToBottom | no (not a KOReader-convention callback name) |
| 3449 | 3457 | 9 | `regionFromCaretTransitionToBottom` | `minfolio_edit_view` | JUDGEMENT | dirty-region family, used by refresh() | no (not a KOReader-convention callback name) |
| 3461 | 3473 | 13 | `linesRegion` | `minfolio_edit_view` | JUDGEMENT | dirty-region family, used by refresh()/commitHighlightFromSelection | no (not a KOReader-convention callback name) |
| 3474 | 3584 | 111 | `refresh` | `minfolio_edit_view` | explicit | explicit: refresh | no (not a KOReader-convention callback name) |
| 3587 | 3591 | 5 | `refreshScroll` | `minfolio_edit_view` | JUDGEMENT | refresh family (scroll-only repaint variant) | no (not a KOReader-convention callback name) |
| 3592 | 3610 | 19 | `checkRemoteInbox` | `minfolio_edit` | JUDGEMENT | remote-snapshot text ops (mutates self.lines/_undo directly); §9.2 documents it as editor-owned remote-sync logic | no (not a KOReader-convention callback name) |
| 3611 | 3622 | 12 | `scheduleAutosave` | `minfolio_edit` | JUDGEMENT | persistence scheduling, tightly coupled to save()/text ops | no (not a KOReader-convention callback name) |
| 3623 | 3628 | 6 | `flushAutosave` | `minfolio_edit` | JUDGEMENT | persistence scheduling, tightly coupled to save()/text ops | no (not a KOReader-convention callback name) |
| 3629 | 3632 | 4 | `currentText` | `minfolio_edit` | JUDGEMENT | text accessor used pervasively by text ops/undo/find | no (not a KOReader-convention callback name) |
| 3633 | 3652 | 20 | `reloadFromDisk` | `minfolio_edit` | JUDGEMENT | external-file sync / text ops | no (not a KOReader-convention callback name) |
| 3653 | 3663 | 11 | `promptExternalReload` | `minfolio_edit` | JUDGEMENT | external-file sync | no (not a KOReader-convention callback name) |
| 3664 | 3688 | 25 | `checkExternalFile` | `minfolio_edit` | JUDGEMENT | external-file sync | no (not a KOReader-convention callback name) |
| 3689 | 3701 | 13 | `scheduleFilePoll` | `minfolio_edit` | JUDGEMENT | external-file sync / lifecycle polling | no (not a KOReader-convention callback name) |
| 3705 | 3724 | 20 | `scheduleHeartbeat` | `minfolio_edit` | JUDGEMENT | diagnostic lifecycle polling; plan calls this family out as unassigned in v1 | no (not a KOReader-convention callback name) |
| 3725 | 3731 | 7 | `snapshot` | `minfolio_edit` | explicit | explicit: undo/redo | no (not a KOReader-convention callback name) |
| 3732 | 3741 | 10 | `snapshotLine` | `minfolio_edit` | explicit | explicit: undo/redo | no (not a KOReader-convention callback name) |
| 3742 | 3749 | 8 | `edit` | `minfolio_edit` | explicit | explicit: undo/redo (snapshot burst trigger) | no (not a KOReader-convention callback name) |
| 3750 | 3765 | 16 | `_restore` | `minfolio_edit` | explicit | explicit: undo/redo | no (not a KOReader-convention callback name) |
| 3766 | 3766 | 1 | `undo` | `minfolio_edit` | explicit | explicit: undo/redo | no (not a KOReader-convention callback name) |
| 3767 | 3767 | 1 | `redo` | `minfolio_edit` | explicit | explicit: undo/redo | no (not a KOReader-convention callback name) |
| 3769 | 3773 | 5 | `selRange` | `minfolio_edit` | explicit | explicit: selection | no (not a KOReader-convention callback name) |
| 3774 | 3777 | 4 | `hasSel` | `minfolio_edit` | explicit | explicit: selection | no (not a KOReader-convention callback name) |
| 3778 | 3785 | 8 | `lineSel` | `minfolio_edit` | explicit | explicit: selection | no (not a KOReader-convention callback name) |
| 3786 | 3794 | 9 | `selText` | `minfolio_edit` | explicit | explicit: selection | no (not a KOReader-convention callback name) |
| 3795 | 3807 | 13 | `deleteSelection` | `minfolio_edit` | explicit | explicit: selection/text ops | no (not a KOReader-convention callback name) |
| 3808 | 3808 | 1 | `copy` | `minfolio_edit` | explicit | explicit: clipboard | no (not a KOReader-convention callback name) |
| 3809 | 3814 | 6 | `cut` | `minfolio_edit` | explicit | explicit: clipboard | no (not a KOReader-convention callback name) |
| 3815 | 3836 | 22 | `paste` | `minfolio_edit` | explicit | explicit: clipboard | no (not a KOReader-convention callback name) |
| 3837 | 3842 | 6 | `selectAll` | `minfolio_edit` | explicit | explicit: selection | no (not a KOReader-convention callback name) |
| 3843 | 3859 | 17 | `rowXAt` | `minfolio_edit_layout` | JUDGEMENT | visual-row pixel math, same family as colAtX/cursorInRows | no (not a KOReader-convention callback name) |
| 3860 | 3867 | 8 | `arrow` | `minfolio_edit` | JUDGEMENT | arrow-key input dispatch (calls moveCursor); input-handling family | no (not a KOReader-convention callback name) |
| 3869 | 3890 | 22 | `insertTypedText` | `minfolio_edit` | explicit | explicit: text ops | no (not a KOReader-convention callback name) |
| 3891 | 3899 | 9 | `flushTypeBuffer` | `minfolio_edit` | JUDGEMENT | input-handling/text-ops buffering, tightly coupled to insertTypedText | no (not a KOReader-convention callback name) |
| 3900 | 3921 | 22 | `queueTypedChar` | `minfolio_edit` | JUDGEMENT | input-handling: keyboard typing buffer | no (not a KOReader-convention callback name) |
| 3922 | 3944 | 23 | `queueVirtualChars` | `minfolio_edit` | JUDGEMENT | input-handling: on-screen keyboard typing buffer | no (not a KOReader-convention callback name) |
| 3945 | 3953 | 9 | `addChars` | `minfolio_edit` | JUDGEMENT | input-handling: VirtualKeyboard inputbox interface | no (not a KOReader-convention callback name) |
| 3954 | 3983 | 30 | `newline` | `minfolio_edit` | explicit | explicit: text ops | no (not a KOReader-convention callback name) |
| 3984 | 4002 | 19 | `delChar` | `minfolio_edit` | explicit | explicit: text ops | no (not a KOReader-convention callback name) |
| 4003 | 4025 | 23 | `moveCursor` | `minfolio_edit` | JUDGEMENT | cursor-movement dispatch/state; calls moveCursorVisual (layout) via self: | no (not a KOReader-convention callback name) |
| 4027 | 4027 | 1 | `leftChar` | `minfolio_edit` | JUDGEMENT | VirtualKeyboard inputbox interface, cursor movement | no (not a KOReader-convention callback name) |
| 4028 | 4028 | 1 | `rightChar` | `minfolio_edit` | JUDGEMENT | VirtualKeyboard inputbox interface, cursor movement | no (not a KOReader-convention callback name) |
| 4029 | 4029 | 1 | `upLine` | `minfolio_edit` | JUDGEMENT | VirtualKeyboard inputbox interface, cursor movement | no (not a KOReader-convention callback name) |
| 4030 | 4030 | 1 | `downLine` | `minfolio_edit` | JUDGEMENT | VirtualKeyboard inputbox interface, cursor movement | no (not a KOReader-convention callback name) |
| 4031 | 4031 | 1 | `goToStartOfLine` | `minfolio_edit` | JUDGEMENT | VirtualKeyboard inputbox interface, cursor movement | no (not a KOReader-convention callback name) |
| 4032 | 4032 | 1 | `goToEndOfLine` | `minfolio_edit` | JUDGEMENT | VirtualKeyboard inputbox interface, cursor movement | no (not a KOReader-convention callback name) |
| 4033 | 4037 | 5 | `delToStartOfLine` | `minfolio_edit` | JUDGEMENT | VirtualKeyboard inputbox interface, text ops | no (not a KOReader-convention callback name) |
| 4038 | 4049 | 12 | `delWord` | `minfolio_edit` | JUDGEMENT | text ops / word deletion | no (not a KOReader-convention callback name) |
| 4050 | 4054 | 5 | `wordLeft` | `minfolio_edit` | JUDGEMENT | cursor movement, word granularity | no (not a KOReader-convention callback name) |
| 4055 | 4059 | 5 | `wordRight` | `minfolio_edit` | JUDGEMENT | cursor movement, word granularity | no (not a KOReader-convention callback name) |
| 4060 | 4068 | 9 | `scrollBy` | `minfolio_edit` | JUDGEMENT | scroll/paging navigation action (calls refreshScroll, a view method, via self:) | no (not a KOReader-convention callback name) |
| 4069 | 4084 | 16 | `pageBy` | `minfolio_edit` | JUDGEMENT | scroll/paging navigation action | no (not a KOReader-convention callback name) |
| 4088 | 4106 | 19 | `pageStep` | `minfolio_edit` | JUDGEMENT | paging distance policy (uses visualRowHeight, a layout method, via self:) | no (not a KOReader-convention callback name) |
| 4107 | 4107 | 1 | `pageUp` | `minfolio_edit` | JUDGEMENT | paging navigation action | no (not a KOReader-convention callback name) |
| 4108 | 4108 | 1 | `pageDown` | `minfolio_edit` | JUDGEMENT | paging navigation action | no (not a KOReader-convention callback name) |
| 4109 | 4109 | 1 | `pageLeft` | `minfolio_edit` | JUDGEMENT | paging navigation action | no (not a KOReader-convention callback name) |
| 4110 | 4110 | 1 | `pageRight` | `minfolio_edit` | JUDGEMENT | paging navigation action | no (not a KOReader-convention callback name) |
| 4111 | 4113 | 3 | `pageFromTap` | `minfolio_edit` | JUDGEMENT | gesture-driven paging navigation action | no (not a KOReader-convention callback name) |
| 4114 | 4135 | 22 | `outlineItems` | `minfolio_edit` | explicit | explicit: find/outline | no (not a KOReader-convention callback name) |
| 4136 | 4149 | 14 | `jumpToLine` | `minfolio_edit` | JUDGEMENT | outline navigation | no (not a KOReader-convention callback name) |
| 4154 | 4169 | 16 | `findMatches` | `minfolio_edit` | explicit | explicit: find | no (not a KOReader-convention callback name) |
| 4170 | 4192 | 23 | `showFindMatch` | `minfolio_edit` | explicit | explicit: find | no (not a KOReader-convention callback name) |
| 4193 | 4236 | 44 | `findNext` | `minfolio_edit` | explicit | explicit: find | no (not a KOReader-convention callback name) |
| 4237 | 4242 | 6 | `goToFindMatch` | `minfolio_edit` | explicit | explicit: find | no (not a KOReader-convention callback name) |
| 4243 | 4289 | 47 | `openFindDialog` | `minfolio_edit` | explicit | explicit: find | no (not a KOReader-convention callback name) |
| 4290 | 4313 | 24 | `setReaderMode` | `minfolio_edit` | JUDGEMENT | mode toggle; editor lifecycle/navigation | no (not a KOReader-convention callback name) |
| 4314 | 4314 | 1 | `onSwitchingKeyboardLayout` | `minfolio_edit` | JUDGEMENT | keyboard lifecycle no-op override; input-handling family | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 4315 | 4337 | 23 | `showKeyboard` | `minfolio_edit` | JUDGEMENT | keyboard lifecycle; input-handling family | no (not a KOReader-convention callback name) |
| 4339 | 4344 | 6 | `isPointInKeyboard` | `minfolio_edit` | JUDGEMENT | gesture/input-handling helper | no (not a KOReader-convention callback name) |
| 4345 | 4351 | 7 | `hideKeyboard` | `minfolio_edit` | JUDGEMENT | keyboard lifecycle; input-handling family | no (not a KOReader-convention callback name) |
| 4352 | 4364 | 13 | `isKeyboardRevealGesture` | `minfolio_edit` | explicit | explicit: gestures | no (not a KOReader-convention callback name) |
| 4369 | 4386 | 18 | `isKeyboardHideGesture` | `minfolio_edit` | explicit | explicit: gestures | no (not a KOReader-convention callback name) |
| 4387 | 4404 | 18 | `save` | `minfolio_edit` | JUDGEMENT | core persistence; general editor lifecycle | no (not a KOReader-convention callback name) |
| 4408 | 4423 | 16 | `onScreenResize` | `minfolio_edit` | JUDGEMENT | lifecycle event handler; calls free_wrap_entry (cross-boundary, see section 3) | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 4424 | 4431 | 8 | `onResume` | `minfolio_edit` | JUDGEMENT | lifecycle event handler | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 4432 | 4435 | 4 | `onSuspend` | `minfolio_edit` | JUDGEMENT | lifecycle event handler | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 4436 | 4454 | 19 | `schedulePhysicalKeyboardRepaint` | `minfolio_edit` | JUDGEMENT | input/lifecycle event handling | no (not a KOReader-convention callback name) |
| 4460 | 4471 | 12 | `onPhysicalKeyboardConnected` | `minfolio_edit` | JUDGEMENT | input/lifecycle event handling; overrides InputContainer/Device broadcast handler | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 4472 | 4475 | 4 | `onPhysicalKeyboardDisconnected` | `minfolio_edit` | explicit | explicit override noted in plan (4472); input/lifecycle event handling | CONFIRMED override (InputContainer, plan-verified) |
| 4476 | 4483 | 8 | `saveAndClose` | `minfolio_edit` | JUDGEMENT | lifecycle: persistence + close | no (not a KOReader-convention callback name) |
| 4484 | 4491 | 8 | `saveAndOpenMarkdown` | `minfolio_edit` | JUDGEMENT | lifecycle: persistence + close; uses open_markdown_picker forward decl (cross-boundary, see section 4) | no (not a KOReader-convention callback name) |
| 4492 | 4532 | 41 | `onCloseWidget` | `minfolio_edit` | explicit | explicit override noted in plan (no direct family listed, but lifecycle teardown fits 'init, lifecycle') | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 4533 | 4592 | 60 | `onKeyPress` | `minfolio_edit` | explicit | explicit override noted in plan (4533); input handling | CONFIRMED override (InputContainer, plan-verified) |
| 4593 | 4599 | 7 | `onHold` | `minfolio_edit` | explicit | explicit: gestures | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 4600 | 4648 | 49 | `onSwipe` | `minfolio_edit` | explicit | explicit: gestures | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 4649 | 4659 | 11 | `bumpScale` | `minfolio_edit` | JUDGEMENT | general editor action (text size); calls free_wrap_entry (cross-boundary, see section 3) | no (not a KOReader-convention callback name) |
| 4660 | 4681 | 22 | `fmtWrap` | `minfolio_edit` | explicit | formatting family, now explicitly assigned (was unassigned in v1) | no (not a KOReader-convention callback name) |
| 4695 | 4712 | 18 | `setLinePrefix` | `minfolio_edit` | explicit | formatting family | no (not a KOReader-convention callback name) |
| 4716 | 4736 | 21 | `indentLine` | `minfolio_edit` | explicit | formatting family | no (not a KOReader-convention callback name) |
| 4737 | 4744 | 8 | `fmtToggle` | `minfolio_edit` | explicit | formatting family | no (not a KOReader-convention callback name) |
| 4745 | 4745 | 1 | `fmtHeader` | `minfolio_edit` | explicit | formatting family | no (not a KOReader-convention callback name) |
| 4746 | 4746 | 1 | `fmtList` | `minfolio_edit` | explicit | formatting family | no (not a KOReader-convention callback name) |
| 4747 | 4747 | 1 | `fmtOrdered` | `minfolio_edit` | explicit | formatting family | no (not a KOReader-convention callback name) |
| 4748 | 4755 | 8 | `fmtTask` | `minfolio_edit` | explicit | formatting family | no (not a KOReader-convention callback name) |
| 4756 | 4780 | 25 | `insertTable` | `minfolio_edit` | explicit | formatting family (inserts markdown table skeleton text; distinct from the minfolio_edit_tables render/hit-test subsystem) | no (not a KOReader-convention callback name) |
| 4781 | 4786 | 6 | `openMindmap` | `minfolio_edit` | JUDGEMENT | general editor action: launches MindmapView | no (not a KOReader-convention callback name) |
| 4787 | 4812 | 26 | `runTopAction` | `minfolio_edit_view` | explicit | explicit: top bar (runTopAction named) | no (not a KOReader-convention callback name) |
| 4813 | 4855 | 43 | `openControls` | `minfolio_edit_view` | explicit | explicit: top bar (openControls named) | no (not a KOReader-convention callback name) |
| 4856 | 4954 | 99 | `onTap` | `minfolio_edit` | explicit | explicit: gestures | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 4955 | 4975 | 21 | `onDoubleTap` | `minfolio_edit` | explicit | explicit: gestures | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 4976 | 5103 | 128 | `onPan` | `minfolio_edit` | explicit | explicit: gestures | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 5107 | 5119 | 13 | `onPanRelease` | `minfolio_edit` | explicit | explicit: gestures | unconfirmed - likely override (KOReader onXxx event-dispatch convention); not verified, no local KOReader source |
| 5124 | 5178 | 55 | `commitHighlightFromSelection` | `minfolio_edit` | JUDGEMENT | highlights family (plan v1 left unassigned, 5124-5206); text ops on selection | no (not a KOReader-convention callback name) |
| 5181 | 5195 | 15 | `highlightRangeAt` | `minfolio_edit` | JUDGEMENT | highlights family | no (not a KOReader-convention callback name) |
| 5197 | 5205 | 9 | `removeHighlightAt` | `minfolio_edit` | JUDGEMENT | highlights family | no (not a KOReader-convention callback name) |

## 2. MindmapView / MindmapCanvas method map

`MindmapCanvas` (`Widget:extend{}`, 1108–1177): 2 methods, both trivially
`minfolio_map_canvas` (the plan names this split explicitly: "split out to
respect the size rule"). `MindmapView` (`InputContainer:extend{...}`,
1178–2002): 64 methods, all `minfolio_map_view` — the plan does not propose
any sub-split of `MindmapView` (~830 lines is under the plan's own ~900-line
module guideline), so there is no ambiguity to adjudicate here; every row is
"explicit" in the sense that the plan's Tier-5 table assigns the whole class
to one module by name. 64 + 2 = 66, confirmed against
`grep -c "^function MindmapView:" main.lua` = 64 and
`grep -c "^function MindmapCanvas:" main.lua` = 2.

Same override-detection method and caveat as §1.

| Class | Start | End | Lines | Method | Target module | Override? |
|---|---|---|---|---|---|---|
| MindmapView | 1179 | 1208 | 30 | `init` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1210 | 1214 | 5 | `textw` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1216 | 1225 | 10 | `trimToWidth` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1227 | 1242 | 16 | `flatten` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1244 | 1250 | 7 | `nodeStyle` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1252 | 1263 | 12 | `nodeText` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1265 | 1267 | 3 | `mapRegion` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1269 | 1274 | 6 | `mapDirtyTarget` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1276 | 1287 | 12 | `scheduleMapCaretBlink` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1289 | 1380 | 92 | `layoutMap` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1382 | 1394 | 13 | `wrapNodeText` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1396 | 1406 | 11 | `nodeAt` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1408 | 1415 | 8 | `linePrefix` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1417 | 1431 | 15 | `showMapKeyboard` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1433 | 1438 | 6 | `hideMapKeyboard` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1440 | 1454 | 15 | `beginNodeEdit` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1456 | 1464 | 9 | `updateEditLayout` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1466 | 1485 | 20 | `commitNodeEdit` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1487 | 1496 | 10 | `cancelNodeEdit` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1499 | 1505 | 7 | `addChars` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1506 | 1512 | 7 | `delChar` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1513 | 1518 | 6 | `delWord` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1519 | 1519 | 1 | `delToStartOfLine` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1520 | 1520 | 1 | `leftChar` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1521 | 1521 | 1 | `rightChar` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1522 | 1522 | 1 | `goToStartOfLine` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1523 | 1523 | 1 | `goToEndOfLine` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1524 | 1524 | 1 | `upLine` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1525 | 1525 | 1 | `downLine` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1526 | 1526 | 1 | `scrollUp` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1527 | 1527 | 1 | `scrollDown` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1528 | 1528 | 1 | `onSwitchingKeyboardLayout` | `minfolio_map_view` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |
| MindmapView | 1530 | 1535 | 6 | `fitMap` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1537 | 1546 | 10 | `clampPan` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1548 | 1599 | 52 | `topBar` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1601 | 1610 | 10 | `rebuild` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1612 | 1615 | 4 | `refresh` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1617 | 1619 | 3 | `selectedEntry` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1621 | 1633 | 13 | `reloadFromEditor` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1635 | 1643 | 9 | `snapshot` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1645 | 1657 | 13 | `applyLines` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1659 | 1669 | 11 | `undo` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1671 | 1675 | 5 | `rangeFor` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1677 | 1689 | 13 | `siblingRange` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1691 | 1698 | 8 | `lineKind` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1700 | 1719 | 20 | `adjustRangeDepth` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1721 | 1746 | 26 | `addChild` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1748 | 1757 | 10 | `deleteSelected` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1759 | 1785 | 27 | `moveSibling` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1787 | 1800 | 14 | `reattach` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1802 | 1807 | 6 | `close` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1809 | 1814 | 6 | `saveAndClose` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1816 | 1843 | 28 | `openControls` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1845 | 1850 | 6 | `jumpTo` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1852 | 1887 | 36 | `onTap` | `minfolio_map_view` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |
| MindmapView | 1889 | 1893 | 5 | `onDoubleTap` | `minfolio_map_view` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |
| MindmapView | 1895 | 1915 | 21 | `onPan` | `minfolio_map_view` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |
| MindmapView | 1917 | 1920 | 4 | `onPanRelease` | `minfolio_map_view` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |
| MindmapView | 1922 | 1934 | 13 | `zoomAt` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1936 | 1939 | 4 | `onPinch` | `minfolio_map_view` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |
| MindmapView | 1941 | 1944 | 4 | `onSpread` | `minfolio_map_view` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |
| MindmapView | 1946 | 1954 | 9 | `centerSelected` | `minfolio_map_view` | no (not a KOReader-convention callback name) |
| MindmapView | 1956 | 1989 | 34 | `onKeyPress` | `minfolio_map_view` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |
| MindmapView | 1991 | 2002 | 12 | `onScreenResize` | `minfolio_map_view` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |
| MindmapCanvas | 1109 | 1109 | 1 | `getSize` | `minfolio_map_canvas` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |
| MindmapCanvas | 1110 | 1176 | 67 | `paintTo` | `minfolio_map_canvas` | unconfirmed - likely override (KOReader onXxx event-dispatch convention / Widget base); not verified, no local KOReader source |

## 3. Cross-boundary plain helpers

Method: for every top-level `local function` (or forward-declared function
local), every call site in the file was located by regex over the
comment-stripped source (`--` to end-of-line removed before matching, since
two false positives came directly from comments mentioning a function name
followed by `()` — `edit_note()` in a comment at line 922, `rotate_screen_ccw()`
in a comment at line 4406; both excluded). Each call site's line was mapped to
its **enclosing top-level definition** (using the same bytecode-derived
start/end ranges as §1/§2 — for every one of the 332 top-level definitions in
the file, not just methods), and that enclosing definition's target module
compared against the helper's own target module. 106 plain top-level helpers
were checked (this excludes the ~213 class methods, which don't need this
treatment — see below); **63 of them are called from at least one other
target module**, 267 cross-boundary call sites in total.

That 63/106 figure is much larger than the plan's two seed examples
(`free_wrap_entry`, `md_clipboard`) suggest, and it needs unpacking rather
than presenting as 63 equally-risky items:

- **The great majority (≈55) are Tier 0/1 shared-utility functions**
  (`minfolio_text`, `minfolio_md`, `minfolio_keys`, `minfolio_io`,
  `minfolio_chrome`, `minfolio_style`, `minfolio_state`, `minfolio_map_model`)
  called from Tier 4/5 consumers. This is **not a hazard** — it is the normal
  shape of a shared-utility layer, and after the split it becomes an ordinary
  `require("minfolio_text")` (etc.) edge at the top of the consuming module.
  I list every one of them below (full call-site lines, per the task's
  instruction) because the instruction asks for it and because the list *is*
  the require-graph the migration needs — but treat this part of the table as
  a **dependency manifest**, not a defect list.
- **A handful are genuinely the `free_wrap_entry` pattern**: a plain (not a
  method) helper whose home tier is one of the *editor's own four mixin
  modules*, called bare (not via `self:`) from **sibling editor modules that
  will be separate files after the split**, with no natural `require`-based
  home because the call sites are today just upvalue reads within the same
  chunk. Only `free_wrap_entry` (2932) fits this exactly, confirmed at
  exactly the plan's four call sites (2982, 4418, 4529, 4655) — no others
  found. `md_split_line_prefix` is architecturally similar but is a Tier 0
  (`minfolio_md`) helper called from Tier 4 (`minfolio_edit`), so it resolves
  like any other Tier 0/1 utility, not like `free_wrap_entry`.
- **Three are a distinct, higher-severity hazard the plan's cross-boundary
  section does not call out**: `MinfolioPair.trace`, `.makeKeyboardArrowFree`,
  and `.disableKeyboardKeyFlash` are all being **relocated off an existing
  global table** (`MinfolioPair`) to different new modules
  (`minfolio_chrome`, `minfolio_keys`). Every one of their 17 combined call
  sites across the file uses the **qualified name `MinfolioPair.xxx(...)`**
  today. Unlike a Tier 0/1 utility (where the move is "add one `require` at
  the top of each consumer, call sites unchanged"), this move requires
  **rewriting every call site's prefix** (`MinfolioPair.trace(...)` →
  `Chrome.trace(...)`, etc.) — a rename-everywhere across 4 different target
  modules (`main.lua`, `minfolio_browser`, `minfolio_edit`, `minfolio_pair`
  for `.trace` alone), not just a new `require`. `MinfolioRemote.edit`/`.stop`
  are the same pattern one tier down: both are being moved into
  `minfolio_app` as `App.remoteEdit`/`App.remoteStop`, but `main.lua`'s
  `Minfolio:openLaunchTarget` (5695, 5698) calls them today as
  `MinfolioRemote.edit(...)` / `MinfolioRemote.stop(...)` — those two call
  sites must be rewritten, not just re-required.
- **`edit_note`** is its own small case: its body moves to `minfolio_browser`
  (registered as the `App` hook per §5 Tier 3/5), but it is called today from
  two different places that land in two different future modules —
  `MinfolioRemote.edit` (→ `minfolio_app`, line 5261) and
  `Minfolio:openLaunchTarget` (→ `main.lua`, line 5692). Both call sites will,
  per the plan's Tier 3 design, become `App.openNote(...)` calls instead of
  direct `edit_note(...)` calls — i.e. the fix already designed for
  `active_mdedit` (route through `App`) is exactly what resolves this one
  too, and the table below is evidence that design decision is necessary, not
  optional.

The full table (helper, definition line/module, every call-site line, every
caller module) follows. Sort order is by definition line, matching source
order.

| Helper | Def line | Def module | Call-site lines | Caller modules |
|---|---|---|---|---|
| `now_seconds` | 40 | `minfolio_io` | 201, 1873, 2167, 3574, 3714, 3887, 3908, 4907, 4937 | `minfolio_edit`, `minfolio_edit_view`, `minfolio_map_view`, `minfolio_pair` |
| `MinfolioPair.trace` | 76 | `minfolio_chrome` | 217, 2090, 3716, 4425, 4433, 4493, 5209, 5229, 5687, 5705, 5713, 5719, 5729 | `main.lua`, `minfolio_browser`, `minfolio_edit`, `minfolio_pair` |
| `MinfolioPair.makeKeyboardArrowFree` | 85 | `minfolio_keys` | 1421, 4320 | `minfolio_edit`, `minfolio_map_view` |
| `MinfolioPair.disableKeyboardKeyFlash` | 125 | `minfolio_keys` | 1422, 4321 | `minfolio_edit`, `minfolio_map_view` |
| `MinfolioPair.start` | 213 | `minfolio_pair` | 5731 | `main.lua` |
| `battery_info` | 237 | `minfolio_chrome` | 5539, 5630 | `minfolio_browser` |
| `MinfolioBattery.infoKey` | 247 | `minfolio_chrome` | 5624, 5631 | `minfolio_browser` |
| `MinfolioBattery.indicatorWidth` | 251 | `minfolio_chrome` | 5543, 5562 | `minfolio_browser` |
| `battery_indicator` | 261 | `minfolio_chrome` | 5556, 5634 | `minfolio_browser` |
| `write_file` | 284 | `minfolio_io` | 333, 340, 3602, 4397, 4501, 5260, 5421 | `minfolio_app`, `minfolio_browser`, `minfolio_edit`, `minfolio_frontlight`, `minfolio_state` |
| `read_file` | 291 | `minfolio_io` | 2057, 3594, 3598, 3634, 3667, 5260 | `minfolio_app`, `minfolio_edit` |
| `split_text_lines` | 298 | `minfolio_text` | 1020, 1234, 1444, 1470, 1648, 1662, 1723, 1732, 1751, 1764, 1790, 2058, 3603, 3636 | `minfolio_edit`, `minfolio_map_model`, `minfolio_map_view` |
| `clamp_minfolio_scale` | 308 | `minfolio_state` | 1182, 2048, 4650 | `minfolio_edit`, `minfolio_map_view` |
| `save_minfolio_state` | 318 | `minfolio_state` | 2135, 4652 | `minfolio_edit` |
| `fl_restore_if_needed` | 389 | `minfolio_frontlight` | 5210, 5510 | `minfolio_browser` |
| `FL.captureBeforeSuspend` | 394 | `minfolio_frontlight` | 4434, 5720 | `main.lua`, `minfolio_edit` |
| `FL.scheduleWakeSync` | 407 | `minfolio_frontlight` | 4429, 5715 | `main.lua`, `minfolio_edit` |
| `fl_adjust` | 432 | `minfolio_frontlight` | 454, 455, 459, 460 | `minfolio_chrome` |
| `show_controls` | 452 | `minfolio_chrome` | 1817, 4815, 4830, 5552 | `minfolio_browser`, `minfolio_edit_view`, `minfolio_map_view` |
| `md_face` | 502 | `minfolio_style` | 1145, 1294, 1303, 1450, 1460, 2199, 2208, 2531 | `minfolio_edit_layout`, `minfolio_edit_view`, `minfolio_map_canvas`, `minfolio_map_view` |
| `md_color` | 506 | `minfolio_style` | 1150, 2531 | `minfolio_edit_view`, `minfolio_map_canvas` |
| `md_inline` | 516 | `minfolio_md` | 1258, 2539 | `minfolio_edit_tables`, `minfolio_map_view` |
| `md_tokenize` | 560 | `minfolio_md` | 2412, 2950, 3032, 5128 | `minfolio_edit`, `minfolio_edit_layout` |
| `md_trim` | 615 | `minfolio_md` | 1010, 1036, 1058, 1066, 1089, 1253, 1725, 4122 | `minfolio_edit`, `minfolio_map_model`, `minfolio_map_view` |
| `md_table_block` | 690 | `minfolio_md` | 2966 | `minfolio_edit_layout` |
| `utf8_left` | 743 | `minfolio_text` | 1508, 1520, 2439, 2459, 3346, 3990, 4009 | `minfolio_edit`, `minfolio_edit_view`, `minfolio_map_view` |
| `utf8_right` | 749 | `minfolio_text` | 1521, 2449, 2460, 2585, 2590, 4013 | `minfolio_edit`, `minfolio_edit_tables`, `minfolio_map_view` |
| `utf8_snap` | 755 | `minfolio_text` | 2389, 2401, 3089 | `minfolio_edit`, `minfolio_edit_layout` |
| `char_is_space` | 759 | `minfolio_text` | 2845, 2846, 2851, 2852 | `minfolio_edit_tables` |
| `prev_word_col` | 762 | `minfolio_text` | 1515, 2436, 2439, 2448, 2458, 2459, 4047, 4053, 5139 | `minfolio_edit`, `minfolio_map_view` |
| `next_word_col` | 776 | `minfolio_text` | 2436, 2438, 2448, 2458, 2460, 4058, 5140 | `minfolio_edit` |
| `keymod` | 790 | `minfolio_keys` | 3862, 4552, 4571, 4575, 4584, 4586 | `minfolio_edit` |
| `shortcut_mod` | 805 | `minfolio_keys` | 1968, 1983, 4537, 4550 | `minfolio_edit`, `minfolio_map_view` |
| `word_key_mod` | 809 | `minfolio_keys` | 2864, 2867, 2870, 3865, 4561 | `minfolio_edit`, `minfolio_edit_tables` |
| `fn_key_mod` | 812 | `minfolio_keys` | 4563, 4564 | `minfolio_edit` |
| `key_mods` | 815 | `minfolio_keys` | 1959, 2863, 4536 | `minfolio_edit`, `minfolio_edit_tables`, `minfolio_map_view` |
| `install_keyboard_aliases` | 837 | `minfolio_keys` | 2044, 4464, 5730 | `main.lua`, `minfolio_edit` |
| `page_up_key` | 865 | `minfolio_keys` | 1977, 4542, 4569 | `minfolio_edit`, `minfolio_map_view` |
| `page_down_key` | 868 | `minfolio_keys` | 1978, 4545, 4570 | `minfolio_edit`, `minfolio_map_view` |
| `left_key` | 871 | `minfolio_keys` | 1975, 2864, 4542, 4565 | `minfolio_edit`, `minfolio_edit_tables`, `minfolio_map_view` |
| `right_key` | 874 | `minfolio_keys` | 1976, 2867, 4543, 4566 | `minfolio_edit`, `minfolio_edit_tables`, `minfolio_map_view` |
| `up_key` | 877 | `minfolio_keys` | 1971, 4542, 4563, 4567 | `minfolio_edit`, `minfolio_map_view` |
| `down_key` | 880 | `minfolio_keys` | 1973, 4543, 4564, 4568 | `minfolio_edit`, `minfolio_map_view` |
| `copy_arr` | 883 | `minfolio_text` | 3728, 3758 | `minfolio_edit` |
| `path_join` | 885 | `minfolio_text` | 5306, 5317, 5349, 5352, 5412, 5448, 5524, 5529, 5608, 5613 | `minfolio_browser` |
| `path_parent` | 889 | `minfolio_config` | 4490, 5225, 5344, 5522, 5606 | `minfolio_browser`, `minfolio_edit` |
| `path_base` | 896 | `minfolio_text` | 1185, 1551, 1622, 5360, 5538, 5619 | `minfolio_browser`, `minfolio_map_view` |
| `is_markdown_file` | 900 | `minfolio_text` | 5340, 5444, 5490, 5584 | `minfolio_browser` |
| `file_signature` | 903 | `minfolio_io` | 2062, 3608, 3645, 3665, 4396 | `minfolio_edit` |
| `same_file_signature` | 912 | `minfolio_io` | 3666 | `minfolio_edit` |
| `notify` | 925 | `minfolio_chrome` | 170, 171, 1661, 1761, 1794, 1796, 3650, 3671, 4190, 4196, 4203, 4301, 4307, 5243, 5247, 5251, 5411, 5413, 5418, 5425, 5446, 5449, 5453, 5471 | `minfolio_app`, `minfolio_browser`, `minfolio_edit`, `minfolio_map_view`, `minfolio_pair` |
| `schedule_wake_repaint` | 929 | `minfolio_chrome` | 4430, 5716 | `main.lua`, `minfolio_edit` |
| `parse_mindmap` | 1019 | `minfolio_map_model` | 1185, 1622 | `minfolio_map_view` |
| `MinfolioRemote.socket` | 2008 | `minfolio_remote` | 154 | `minfolio_pair` |
| `MinfolioRemote.sendAll` | 2032 | `minfolio_remote` | 158 | `minfolio_pair` |
| `free_wrap_entry` | 2932 | `minfolio_edit_layout` | 4418, 4529, 4655 | `minfolio_edit` |
| `md_split_line_prefix` | 4682 | `minfolio_md` | 3963, 4577, 4698, 4749 | `minfolio_edit` |
| `edit_note` | 5208 | `minfolio_browser` | 5261, 5692 | `main.lua`, `minfolio_app` |
| `MinfolioRemote.edit` | 5240 | `minfolio_app` | 5695 | `main.lua` |
| `MinfolioRemote.stop` | 5264 | `minfolio_app` | 5698 | `main.lua` |
| `rotate_screen_ccw` | 5273 | `minfolio_chrome` | 1841, 4819, 4851 | `minfolio_edit_view`, `minfolio_map_view` |
| `open_markdown_picker` | 5332 | `minfolio_browser` | 4490 | `minfolio_edit` |
| `open_notes` | 5670 | `minfolio_browser` | 5745, 5751 | `main.lua` |

## 4. Forward declarations

The plan's five, all confirmed exactly:

| Declared | Assigned | Every use site (line, enclosing scope, target module) |
|---|---|---|
| `open_markdown_picker` (917) | 5332 | 4490 `MDEdit:saveAndOpenMarkdown` → `minfolio_edit` (**guarded**, `if open_markdown_picker then`); 5366 `open_markdown_picker` itself (self-recursive, same module); 5580 `show_file_manager`'s `onMenuSelect` → `minfolio_browser` (same module as the eventual home, unguarded) |
| `rotate_screen_ccw` (917) | 5273 | 1841 `MindmapView:openControls` → `minfolio_map_view` (unguarded, wrapped in a closure `function() rotate_screen_ccw() end`); 4819/4851 `MDEdit:openControls` → `minfolio_edit_view` (unguarded, same closure pattern); 5552 `show_file_manager` → `minfolio_browser` (unguarded, passed as a **bare function value** `callback = rotate_screen_ccw`, not a wrapping closure — see note below) |
| `show_file_manager` (917) | 5509 | 5225 `edit_note` → `minfolio_browser` (**guarded**, `if show_file_manager then`); 5381 `refresh_file_manager` → `minfolio_browser` (same module, unguarded); 5671 `open_notes` → `minfolio_browser` (same module, unguarded) |
| `active_mdedit` (924) | 5227, cleared 4508 | 4508 `MDEdit:onCloseWidget` → `minfolio_edit` (clears it, unguarded write); 5211/5214/5218/5219/5227/5234 `edit_note` → `minfolio_browser` (singleton-enforcement read/write, **5211 guarded**); 5265/5266 `MinfolioRemote.stop` → `minfolio_app` (**5265 guarded**) |
| `md_split_line_prefix` (3868) | 4682 | 3963 `MDEdit:newline` → `minfolio_edit` (**guarded**, the guard is at 3962); 4577 `MDEdit:onKeyPress` → `minfolio_edit` (unguarded); 4698 `MDEdit:setLinePrefix` → `minfolio_edit` (unguarded); 4749 `MDEdit:fmtTask` → `minfolio_edit` (unguarded) |

All five confirmed at the plan's cited declaration/assignment lines.

**`rotate_screen_ccw` capture-style note** (not in the plan): three of its four
call sites wrap it in a closure — `callback = function() rotate_screen_ccw()
end` — which defers resolution of the upvalue to call time. The fourth
(5552, in `show_file_manager`) does **not**: `callback = rotate_screen_ccw`
copies the function *value* at the moment the enclosing table literal is
built (menu-construction time), not a live reference to the variable. Both
patterns work today because `rotate_screen_ccw` is fully assigned (5273) long
before any menu can be opened, but they are not the same mechanism, and a
future refactor that changes *when* `show_file_manager`'s controls table is
constructed relative to module load order should not assume the two patterns
are interchangeable.

**Additional forward declaration not counted in the plan's "five": `FL`**
(declared `local FL` at line 337, assigned `FL = { ... }` at line 371).
Structurally this is the identical pattern (`local NAME` with no initializer,
later bare `NAME = ...`), and two small functions between the declaration and
assignment (`save_frontlight_state` at 338, and the `lipc_get`/`lipc_set`
helpers at 354/360) close over `FL` as an upvalue before it holds a value —
same mechanism as the other five. The plan's §6.4 is correct to exclude `FL`
from the **globals** list (it is not one — confirmed no bare `FL = ` outside
the `local FL` scope), but §4's forward-declaration table doesn't mention it
either, and the task instructions ask specifically to "find any others." I
judge its risk profile to be materially lower than the other five: it
resolves fully within one 34-line, single-module (`minfolio_frontlight`)
load-time block, never crosses a module boundary while unresolved, and (per
§6 below) is **never guarded** with `if FL then` anywhere in the file — so
losing its upvalue in a bad move would be a **loud** `attempt to index a nil
value` on the first `FL.bright`/`FL.on` read, not a silent no-op. Still worth
carrying into `ARCHITECTURE.md`'s local-limit history as a second instance of
the pattern.

## 5. Globals

Confirmed mechanically: every top-level assignment with no `local` anywhere
in the file for that name (`grep -n "^[A-Za-z_][A-Za-z0-9_]*\s*=[^=]" main.lua`
filtered to non-`local` lines), cross-checked one by one against a `local`
declaration search. Exactly the plan's six, no more, no fewer:

| Global | Line | Every read site |
|---|---|---|
| `rapidjson` | 35 (`rapidjson = require("rapidjson")`) | 156, 192, 194, 210 — all inside `MinfolioPair.*` (Tier 2 `minfolio_pair`) |
| `MINFOLIO_REMOTE_DIR` | 61 | 180 (`MinfolioPair.pollRequest`, `minfolio_pair`), 5250/5252 (`MinfolioRemote.edit` → `minfolio_app`) |
| `MINFOLIO_PAIR_PATH` | 64 | 168 (`MinfolioPair.showPrompt`, `minfolio_pair`) |
| `MinfolioPair` | 71 | pervasive — own table methods (76–220), plus read from `minfolio_map_view` (1421/1422), `minfolio_edit` (2090, 3716, 4425, 4433, 4493, 4320/4321), `minfolio_browser` (5209, 5229), `main.lua` (5687, 5705, 5713, 5719, 5729, 5731) — full call-site list is the `MinfolioPair.*` rows of §3's table |
| `MinfolioBattery` | 227 (`MinfolioBattery = MinfolioBattery or {}` — an idempotent-reinit guard, itself worth noting: this line assumes `MinfolioBattery` may already be a table from a *previous* load of this same global, i.e. it defends against KOReader re-running the chunk without a full Lua-state restart) | 228 (own field init), 247/251 (own methods), 5543/5562/5624/5631 (`show_file_manager` → `minfolio_browser`) |
| `MinfolioRemote` | 2007 | 154/158 (`MinfolioPair.post`, `minfolio_pair` — **note: this read is lexically *before* the assignment**, see Correction 5 above), own methods 2008–2267, 5695/5698 (`main.lua`) |

Plus the seventh global-adjacent item the plan tracks separately:
`_G.__minfolio_launch_polling` (read+written at 5734/5735, both inside
`Minfolio:init` → `main.lua`; it is a load-once guard against a duplicate
launch-flag polling loop if `init` runs again without a full KOReader
restart). Only these two lines touch it anywhere in the file.

**`FL` is not a global** — verified per the task's explicit warning: `local
FL` is declared at line 337, and the later bare `FL = { ... }` at 371
assigns that same local, not a new global. (Full mechanical check: every
bare, non-`local`, top-level `NAME = ` assignment in the file was enumerated
and cross-referenced against `^local NAME\b` declarations; `FL`,
`md_split_line_prefix`, `rotate_screen_ccw`, `open_markdown_picker`, and
`show_file_manager` are the five that have a matching earlier `local`
declaration and are therefore *not* globals — only the six above have no such
declaration anywhere.)

These six (plus the `_G` flag) are exactly the GGET allowlist baseline §6.3
calls for: once each becomes `local M = {}; ... return M`, every read site
above becomes a `require` in its own consuming module, and the GGET diff gate
should start from a baseline where these six names' reads are already
accounted for (i.e. the *pre-migration* GGET count already includes them as
global reads — the gate is about not *adding* new ones, not about these six
specifically).

## 6. Nil-tolerant guards (silent-failure risk register)

Method: every one of the 106 plain top-level helpers (§3), the 6 globals
(§5), `FL`, and the 5 official forward declarations plus `md_clipboard` (118
tracked symbols total) was swept for three guard shapes in the
comment-stripped source: `if <symbol> then` / `if not <symbol> then`,
`<symbol> and ...` (bare, not a call result), and `not <symbol>` used bare
(not `not <symbol>(...)`, which tests a *call result*, not the symbol's own
nilness — an early, cruder pass produced false positives here, e.g. `if not
char_is_space(...) then` and `if not remove_tree(...) then`, which are
completely ordinary boolean logic on a function's return value, not a hazard;
these are excluded from the table below). Confirmed against the actual source
after the sweep.

**Six distinct symbols, seven guard sites:**

| Line | Symbol | Guard | Confirmed? | What silently breaks if the symbol becomes a stray nil-global read |
|---|---|---|---|---|
| 154 | `MinfolioRemote` | `MinfolioRemote and MinfolioRemote.socket(cfg, 2)` | **New — not in plan** | `MinfolioPair.post` returns `false`. `MinfolioPair.showPrompt`'s pairing confirm callback shows `notify(_("Could not complete secure pairing"))` — the user *does* see a message, but it looks exactly like a legitimate TLS/network pairing failure. A missing `require("minfolio_remote")` in `minfolio_pair.lua` would masquerade as a flaky desktop connection forever, with no log line pointing at the real cause. |
| 3816 | `md_clipboard` | `if not md_clipboard or md_clipboard == "" then return end` | Plan-confirmed | `paste()` becomes a permanent, silent no-op — matches plan's own characterisation exactly. |
| 3962 | `md_split_line_prefix` | `if md_split_line_prefix then` | Plan-confirmed | `newline()`'s auto-continuation of bullet/ordered/task-list prefixes on Enter silently stops working; every other `newline()` behaviour is unaffected, so this would likely ship unnoticed until a user reports "lists stopped continuing." |
| 4490 | `open_markdown_picker` | `if open_markdown_picker then open_markdown_picker(...) end` | Plan-confirmed | "Open .md file..." from the editor's controls menu, reached via `saveAndOpenMarkdown`, silently does nothing after the current note saves and closes — the user is left on whatever was underneath, with no picker and no error. |
| 5211 | `active_mdedit` | `if active_mdedit and not active_mdedit._closing then` | Plan-confirmed | `edit_note`'s singleton enforcement silently stops working: opening a second note while one is already open would stack a second live `MDEdit` against the same on-disk file and file-poller instead of reusing/closing the first — reproducing exactly the "Reloaded from disk storm and a half-repainted screen" failure mode the code comment at 918–923 explains this guard exists to prevent. |
| 5225 | `show_file_manager` | `if show_file_manager then show_file_manager(...) end` | **New — plan miscited this as `active_mdedit`** (see Correction 1) | `edit_note`'s `on_close` callback silently does nothing: closing a note (e.g. after a remote/desktop edit session) would no longer return the user to the Minfolio file listing — they'd be dropped back to whatever KOReader screen was underneath instead. |
| 5265 | `active_mdedit` | `if active_mdedit and active_mdedit.remote and active_mdedit.remote.session_id == session_id then` | **The plan's real second `active_mdedit` guard — plan cited 5225 instead** | `MinfolioRemote.stop` silently does nothing: a desktop "stop editing" command over the pairing channel would never find (and therefore never close) the corresponding Kindle-side editor. The Kindle-side session stays open indefinitely while the desktop believes it stopped it. |

**Contrast — symbols that are *never* guarded**, so losing them would fail
loud (an immediate `attempt to call/index a nil value`), not silent, if a
move forgets a `require`: `FL` (indexed unconditionally everywhere, e.g.
`FL.bright` at 379), `MinfolioPair` (called unconditionally, e.g.
`MinfolioPair.trace(...)` at dozens of sites), `MinfolioBattery`, `rapidjson`,
`rotate_screen_ccw` (all 4 call sites are unconditional), `open_markdown_picker`
at its two non-`edit_note` call sites (5366, 5580 — only the `MDEdit`
call site at 4490 is guarded). This distinction is exactly the plan's own
§6.3 "loud vs silent" framing; the table above is the complete silent-failure
set, mechanically swept rather than hand-picked.

## 7. Constants

Counted mechanically: `grep -n "^local MDEDIT_"` = 33, `grep -n "^local MINDMAP_"`
= 27. **60 total, confirmed** (plan's corrected v2 figure, not v1's 57).

**Two live outside the 937–1000 block**, as the plan notes: `MDEDIT_TABLE_PAD_X`
(500, = `8`) and `MDEDIT_TABLE_PAD_Y` (501, = `5`), used only inside
`minfolio_edit_tables`'s range at 2605, 2652, 2684, 2744, 2762 (all confirmed,
all within 2537–2893). The plan assigns these two to `minfolio_style.lua`
rather than `minfolio_const.lua` specifically because of this physical
separation — i.e. they are constants but not part of the constant *table*,
they're grouped with the style module instead. This is a real, if slightly
odd, split: two of the "60 constants" are homed in a different module from
the other 58.

**Computed-at-load-time vs. plain literal** (mechanically checked against
every one of the 60 right-hand sides):

| Count | Kind | Lines |
|---|---|---|
| 10 | Computed from KOReader (**corrected from the plan's "nine" — see Correction 2**) | `Blitbuffer.Color8(190)` (972); `Size.padding.large`/`Size.padding.small` (976, 977); `Screen:scaleBySize(...)` ×7 (980, 982, 983, 994, 995, 999, 1000) |
| 1 | Derived from a sibling constant, not KOReader | `MINDMAP_TOPBAR_TOP_PAD = MDEDIT_PAD` (979) |
| 49 | Plain literal | the remaining 32 `MDEDIT_*` + 17 `MINDMAP_*` |

The 1 "derived from a sibling constant" row (979) is the plan's own example
of why `minfolio_const.lua` has to be a single table with both `EDIT` and
`MAP` groups rather than two separate modules — a genuine constraint,
confirmed correct.

**Constants used by a module other than their name prefix suggests** — swept
mechanically (every constant's every use site classified into
`MindmapCanvas` / `MindmapView` / `MDEdit` / pre-class / browser / main
regions and flagged if the region didn't match the constant's own
`MDEDIT_`/`MINDMAP_` prefix). Exactly **4 cases, all already known to the
plan, no others found**:

1. `MINDMAP_TOPBAR_TOP_PAD = MDEDIT_PAD` (979) — cross-reference at
   *definition* time, resolved by keeping both groups in one table.
2. `MDEDIT_MENU_W` used by `MindmapView:topBar` at 1565, 1569, 1587.
3. `MDEDIT_TITLE_ACTION_GAP` used by `MindmapView:topBar` at 1565, 1568.
4. `MDEDIT_CARET_BLINK` used by `MindmapView:scheduleMapCaretBlink` at 1277.

No `MINDMAP_*` constant is used outside `MindmapView`/`MindmapCanvas` code,
and no other `MDEDIT_*` constant leaks into mindmap code beyond the three
above. The EDIT/MAP split inside `minfolio_const.lua` is not clean, but it is
*exactly as unclean as the plan already found* — this section is a
confirmation, not a new correction.

## 8. Per-module top-level local budget projection

This section applies to **all 22 real modules** from the plan's own §5 tier
tables (see Correction 6 — the "~14 modules" figure undercounts the plan's
own design by 8). §12's work packages and §10's migration sequence should be
read against 22 deploy/test units, not 14.

### The methodology question this section turns on

A method (`function MDEdit:name()`) compiles to a **table-field assignment**
(`MDEdit.name = function(self, ...) ... end`), not a local — this is true
today and stays true after the mixin split, *provided* the split modules
define their methods the same way (e.g.
`function M.methods.textw(self, txt, face) ... end` directly, mirroring the
colon-method convention already used everywhere in this file). Table fields
do not consume the 200-local budget; the plan's own §1 makes this exact point
about why `MinfolioPair.trace` etc. are globals today ("table fields do not
consume local slots"). **§6.2 of the plan shows the mixin *assembly* loop but
never states the *authoring* convention for a mixin module's own methods
table.** That gap matters: if a mixin module were instead written as
`local function textw(...) ... end` (one `local` per method) and *then*
collected into `methods = { textw = textw, ... }`, `minfolio_edit.lua` alone
would need **103 top-level locals just for its own methods** — before a
single `require`. `minfolio_map_view.lua` would need 64. Both would then
comfortably clear the plan's own "~60" acceptance target (§13.2) while
staying safely under the 200 hard ceiling — i.e. the *hard* limit would not
be at risk, but the *stated goal* of the refactor would be quietly missed for
exactly the two modules where it matters most.

**All projections below assume the colon/table-field method style** (methods
and `free_wrap_entry`/`.freeWrapEntry` defined directly as table fields, not
as intermediate `local function` values). This should be stated explicitly
as an authoring rule in `ARCHITECTURE.md`, not left implicit.

### Projections

Counts are: own top-level functions/data that must be plain `local`s (methods
excluded, per the above), estimated KOReader `require`s, estimated sibling
`minfolio_*` `require`s (derived from §3/§4/§5/§7's actual call/use-site
data, not guessed), and the resulting projected total. "Own" content and
sibling `require`s are traceable to specific lines already cited above;
KOReader-require counts are reasoned from which widgets/APIs each module's
assigned code actually touches (traced while reading, not enumerated
mechanically — flagged as estimate, not measurement).

| Module | Methods (table fields, ~0 cost) | Own locals (fns/data) | Est. KOReader requires | Est. sibling requires | **Projected total** | Flag |
|---|---|---|---|---|---|---|
| `minfolio_md` | – | 8 | 0 | 0 | **~9** | – |
| `minfolio_text` | – | 11 | 0 | 0 | **~12** | – |
| `minfolio_map_model` | – | 2 | 0 | 2 (`md`, `text`) | **~5** | – |
| `minfolio_config` | – | 3 fns + 7 paths/config | 1 (`lfs`) | 0 | **~11** | – |
| `minfolio_io` | – | 5 | 2 (`lfs`, `socket`) | 0 | **~7** | – |
| `minfolio_state` | – | 3 fns + 1 (`MINFOLIO_STATE`) | 0 | 2 (`config`, `io`) | **~6** | – |
| `minfolio_style` | – | 2 fns + 4 data (`MD_FACES`/`MD_LH`/pad×2) | 2 (`Font`, `Blitbuffer`) | 0 | **~8** | – |
| `minfolio_const` | – | ~1 (table root; 58 constants are fields of it) | 3 (`Screen`,`Size`,`Blitbuffer`) | 0 | **~4** | Looks scariest (60 constants), is actually one of the smallest — the whole point |
| `minfolio_keys` | – | 14 fns + 3 data (`SHIFT_SYM` etc.) | 1 (`Device`) | 0 | **~18** | – |
| `minfolio_frontlight` | 2 (`FL.captureBeforeSuspend/.scheduleWakeSync`) | 8 fns + `FL` + 8 load-time locals (`FL_MAX` etc.) | 1 (`UIManager`) | 2 (`config`, `io`) | **~21** | Highest local *count* of Tier 1, driven by the many small `FL_*` load-time scalars |
| `minfolio_chrome` | – | 9 fns + 1 (`wake_repaint_pending`) | ~11 (battery widget composition: `Device`,`Screen`,`TextWidget`,`Font`,`Blitbuffer`,`HorizontalGroup`,`HorizontalSpan`,`LineWidget`,`FrameContainer`,`CenterContainer`,`Menu`) | 1 (`frontlight`) | **~22** | – |
| `minfolio_remote` | 2 | ~1 (module table) | 1 (`socket`; `ssl` stays a function-local `pcall(require,...)`, 0 top-level cost, as it is today at line 2014) | 0 | **~3** | – |
| `minfolio_pair` | up to 8 (if table-field) | 0–8 depending on style | 5 (`socket`,`UIManager`,`ConfirmBox`,`rapidjson`,`lfs`) | 3 (`remote`,`chrome`,`config`) | **~16–24** | – |
| `minfolio_app` | up to 8 | 0–8 + 2 data (`active`,`hooks`) | ~0–1 | 3 (`config`,`io`,`chrome`) | **~14** | Mostly new code; smallest-evidence estimate |
| `minfolio_edit_layout` | 18 | `free_wrap_entry` as `.freeWrapEntry` field (0) + module table (1) | 1 (`TextWidget`) | 3 (`md`,`style`,`const`) | **~6** | – |
| `minfolio_edit_tables` | 11 | module table (1) | 9 (`FrameContainer`,`LeftContainer`,`VerticalGroup`,`HorizontalGroup`,`HorizontalSpan`,`OverlapGroup`,`LineWidget`,`InputDialog`,`UIManager`) | 5 (`md`,`text`,`keys`,`style`,`const`) | **~15** | – |
| `minfolio_edit_view` | 28 | module table (1) | 13 (`Geom`,`UIManager`,`FrameContainer`,`HorizontalGroup`,`HorizontalSpan`,`VerticalGroup`,`VerticalSpan`,`CenterContainer`,`TextWidget`,`LineWidget`,`IconWidget`,`Font`,`Blitbuffer`) | 4 (`style`,`text`,`chrome`,`const`) | **~18** | – |
| `minfolio_edit` | 103 | `md_clipboard` (1, new file-local per plan) + class table (1) | 8 (`Device`,`Geom`,`GestureRange`,`InputContainer`,`UIManager`,`Screen`,`ConfirmBox`,`InputDialog`) | 9 (`md`,`text`,`io`,`state`,`keys`,`frontlight`,`chrome`,`app`,`edit_layout` for `free_wrap_entry`) | **~19** | The biggest module by method count is *not* the biggest by local budget — confirms the plan's design bet |
| `minfolio_map_view` | 64 | class table (1) | 17 (widget-heavy: `InputContainer`,`GestureRange`,`Geom`,`Device`,`Screen`,`UIManager`,`TextWidget`,`Font`,`Blitbuffer`,`HorizontalGroup`,`HorizontalSpan`,`VerticalGroup`,`VerticalSpan`,`CenterContainer`,`FrameContainer`,`LineWidget`,`IconWidget`) | 6 (`map_model`,`text`,`style`,`const`,`keys`,`chrome`) | **~24** | – |
| `minfolio_map_canvas` | 2 | class table (1) | 4 (`Widget`,`Blitbuffer`,`TextWidget`,`Geom`) | 2 (`style`,`const`) | **~7** | – |
| `minfolio_browser` | – | 14 (`dir_entries` … `edit_note`, mutually-recursive, realistically kept as plain locals) | 15 (`lfs`,`InputDialog`,`ConfirmBox`,`Menu`,`TitleBar`,`CenterContainer`,`HorizontalGroup`,`HorizontalSpan`,`GestureRange`,`Geom`,`Screen`,`Size`,`UIManager`,`logger`,`_`) | 7 (`text`,`config`,`chrome`,`io`,`app`,`edit`,`frontlight`) | **~36** | **Highest projection of the 22** — still well under 60, but the one to re-measure first once real code exists, since it constructs the most distinct KOReader widget types |
| `main.lua` | – | `read_launch_target` (1) + `Minfolio` class table (1) + `LAUNCH_FLAG` (1) | 5 (`WidgetContainer`,`Dispatcher`,`UIManager`,`logger`,`_`) | 6 (`pair`,`app`,`browser`,`keys`,`frontlight`,`chrome`) | **~14** | Consistent with the plan's own "~8 KOReader requires... under 120 lines" target |

**No module is projected anywhere near 60**, let alone 200, under the
table-field method convention. `minfolio_browser.lua` is the module to watch
(highest estimate, ~36, and the only one built substantially from
mutually-recursive plain-local dialog helpers rather than table-field
methods) — it is also the module that most needs the authoring-convention
rule above stated explicitly, since it's the one Tier 5 module where "just
keep writing `local function`" is the natural (and here, safe) default, and
someone could plausibly copy that same instinct into `minfolio_edit.lua`
without noticing the difference in consequence.
