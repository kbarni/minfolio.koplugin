# Minfolio for Kindle: module split and re-architecture plan

Status: **v2**, revised 2026-07-30 after adversarial review by Fable and Codex.
v1's dependency graph, test strategy, and migration order were wrong; see §14 for
the finding-by-finding response.

## 1. Why

`minfolio.koplugin/main.lua` is 5,755 lines and contains 198 top-level `local`
*statements* declaring **200 local names** — line 917 declares three names in one
statement. LuaJIT allows 200 named locals per function scope, and a Lua file is
itself a function, so the file's top level is at the ceiling **exactly**, not two
short of it.

Verified twice: appending a single `local __probe = 1` fails with `main function
has more than 200 local variables`, and the idiomatic fix for the `notify` bug
below — adding one forward declaration — was itself impossible for the same
reason. The codebase can no longer accept the correct fix to its own defects.

KOReader silently skips a plugin whose Lua fails to compile — no dialog, nothing
the user sees. So the failure mode for adding one top-level `local` is "Minfolio
vanished from the menu".

The limit is already distorting the design, and the source says so. The comment at
main.lua:72–75 explains that `MinfolioPair` hosts `trace()`,
`makeKeyboardArrowFree()`, and `disableKeyboardKeyFlash()` — none of which are
pairing concerns — because table fields do not consume local slots. Six values are
outright globals (§6.4) for the same reason. 60 of the 200 names are constants.

## 2. Goals and non-goals

**Goals**

1. Remove the local ceiling permanently; each module gets its own budget of 200.
2. Make the subsystems separable and the *pure* logic testable off-device.
3. Make failure loud: a broken module must fail the deploy, not silently disable
   the plugin.
4. Preserve behaviour exactly. No feature, rendering, or gesture changes.

**Non-goals**

- No new editor features.
- No change to the note format or `/mnt/us/notes` layout.
- No change to the desktop wire protocol. Documenting it is in scope; changing it
  is not.
- No rewrite of the renderer or wrapping engine.
- **Not** a purity rewrite. Splitting pure logic from KOReader adapters is a
  distinct, later commit class (§7.3), not smuggled into the move commits.

## 3. Verified constraints

| Constraint | Evidence |
|---|---|
| 200 locals/scope; 200 names used (198 statements); zero headroom | probe compile fails at +1; a one-name forward decl also fails |
| KOReader puts a plugin's dir on `package.path`; bare `require("sibling")` works | `kinbox.koplugin` (~18 non-test modules, 8,131 lines, same device) uses `require("kinbox_store")`; `kshell` uses `require("restart_flag")` |
| The Lua module namespace is shared across all installed plugins | one `package.path`/`package.loaded`; hence kinbox's `kinbox_*` prefix |
| A compile failure silently disables the whole plugin | `README.md`, `RELEASE_CHECKLIST.md` |
| Per-file `scp` breaks at ~20 files, *partially* | `kindle-inbox/scripts/deploy.sh`: "scp silently failing on 2 of 19 files (SSH throttles under rapid reconnects)" |
| Off-device tests work **only for KOReader-free modules** | `kinbox_keys.lua` header: "Deliberately zero KOReader dependencies… the only way any of this can be checked". `kinbox_keys/wrap/editfield/undo/time` have zero KOReader requires and have tests; `kinbox_md` requires `ui/*` and has **no test** |
| kinbox has **no** mixin-assembled class | one class per module + pure logic modules. The mixin approach here is novel in this stack, not precedented |
| `luacheck` is not installed | `which luacheck` → not found |
| `luajit -bl` exposes global reads, but noisily | 749 `GGET` instructions in current main.lua; a lint must diff against a baseline, not target zero |

Two consequences carried forward from v1, still correct:

- **Modules stay `minfolio_*`-prefixed and the directory stays flat.** The
  namespace is shared with kshell, kinbox, and anything else installed. A module
  named `util.lua` is a live collision.
- **The light-restart path (`/tmp/koreader_restart`) lives in kshell.** Minfolio's
  deploy may use it but must degrade when kshell is absent. No dependency.

## 4. Corrected dependency facts

v1 asserted "exactly one back-edge, verified by inspection". That was false, and it
was false because I read `grep -n` output from an `awk`-extracted region as absolute
line numbers. The real picture:

**`MinfolioRemote` spans two tiers and is the central tangle.**

| Symbol | Line | Depends on |
|---|---|---|
| `MinfolioRemote.socket` | 2008 | transport only |
| `MinfolioRemote.sendAll` | 2032 | transport only |
| `MinfolioRemote.edit` | 5240 | calls `edit_note` (5261) — the browser |
| `MinfolioRemote.stop` | 5264 | reads `active_mdedit`, calls `saveAndClose` (5265–5267) — the editor |

and pairing calls `MinfolioRemote.socket`/`sendAll` at 154/158, while the plugin
entry calls `.edit`/`.stop` at 5695/5698. So low-level transport is used *by*
pairing, and high-level session control uses the *browser and editor*. One module
cannot hold both without an upward dependency.

**Five forward-declared locals, not two.**

| Declared | Assigned | Used from |
|---|---|---|
| `open_markdown_picker` (917) | 5332 | editor 4490 |
| `rotate_screen_ccw` (917) | 5273 | mindmap 1841, editor 4819/4851, browser 5552 |
| `show_file_manager` (917) | 5509 | browser |
| `active_mdedit` (924) | 5227, cleared 4508 | editor, browser, remote |
| `md_split_line_prefix` (3868) | 4682 | 3963, 4577, 4698, 4749 |

`md_split_line_prefix` was absent from v1 entirely, and it is the most dangerous
symbol in the file: line 3962 reads `if md_split_line_prefix then`. It is a
**nil-tolerant guard**. Lose that upvalue in a move and smart-newline silently
stops working forever, with no error anywhere.

**Cross-boundary plain helpers** (not methods, so they have no mixin channel):

- `free_wrap_entry` (2932) — called from 2982 (layout), 4418 (`onScreenResize`),
  4529 (`onCloseWidget`), 4655 (`bumpScale`): three or four different proposed
  modules.
- `md_clipboard` (884) — deliberately shared across editor instances; all uses at
  3808–3821.

**Other corrections to v1's inventory:**

- Constants are **60** (`MDEDIT_*` ×33, `MINDMAP_*` ×27), not 57.
- Ten are **computed at load time** from KOReader: `Blitbuffer.Color8(190)` (972),
  `Size.padding.*` (976–977), `Screen:scaleBySize(...)` (980, 982, 983, 994, 995,
  999, 1000). A "pure constants module" is impossible; it requires KOReader and
  bakes DPI at require time.
- The EDIT/MAP split is not clean: `MINDMAP_TOPBAR_TOP_PAD = MDEDIT_PAD` (979), and
  the mindmap uses `MDEDIT_MENU_W`, `MDEDIT_TITLE_ACTION_GAP` (1565–1589), and
  `MDEDIT_CARET_BLINK` (1277).
- `MDEDIT_TABLE_PAD_X/Y` live at 500–501, outside the 937–1000 constant block, and
  are used at 2605–2762.
- `MDEdit` defines **no `paintTo`**; painting is inherited over the widget tree
  `rebuild` constructs. v1 listed it.
- `read_frontlight_state` (304) is frontlight, not state.
- The lfs migration block (65–70) and `MINFOLIO_PAIR_PATH` (64) had no assigned home.

## 5. Target architecture

22 modules (21 plus a slim `main.lua`), flat and `minfolio_`-prefixed. The editor drops from
8 sub-modules to 4, and thin ceremony modules are merged.

**Tier 0 — KOReader-free (testable off-device)**

| Module | Contents |
|---|---|
| `minfolio_md.lua` | `md_inline`, `md_tokenize`, `md_trim`, `md_table_row_prefix`, `md_split_table_row`, `md_table_separator`, `md_table_block`, **`md_split_line_prefix`** (its natural home — pure line-prefix parsing). **Not** `md_face`/`md_color`. |
| `minfolio_text.lua` | `utf8_left/right/snap`, `char_is_space`, `prev_word_col`, `next_word_col`, `split_text_lines`, `path_join/base`, `is_markdown_file`, `copy_arr` |
| `minfolio_map_model.lua` | `mindmap_node`, `parse_mindmap` |

These three carry the kinbox discipline explicitly: a header comment stating zero
KOReader dependencies, enforced by their tests importing them under plain `luajit`.

**Tier 1 — KOReader adapters and app services**

| Module | Contents |
|---|---|
| `minfolio_config.lua` | `plugin_dir`, `load_local_config`, `CONFIG`, `NOTES_DIR`, `STATE_DIR`, state paths, `MINFOLIO_PAIR_PATH`, `MINFOLIO_REMOTE_DIR`, the lfs migration block (65–70), `path_parent` (reads `NOTES_DIR`) |
| `minfolio_io.lua` | `write_file`, `read_file`, `file_signature`, `same_file_signature`, `now_seconds` (needs `socket`) |
| `minfolio_state.lua` | `MINFOLIO_STATE`, scale/position read+save+clamp |
| `minfolio_style.lua` | `MD_FACES`, `MD_LH`, `md_face` (`Font`), `md_color` (`Blitbuffer`), `MDEDIT_TABLE_PAD_X/Y` — the render-facing half of v1's `minfolio_md` |
| `minfolio_const.lua` | the 60 constants as `{ EDIT = ..., MAP = ... }`, with a header noting it requires `Screen`/`Size`/`Blitbuffer` and bakes DPI at require time. Cross-group references (979, 1277, 1565–1589) resolve within the single table. |
| `minfolio_keys.lua` | modifier decoding (`Device`), `install_keyboard_aliases`, `SHIFT_SYM`, `KEYPAD_CHAR`, `KEYBOARD_EVENT_MAP`, direction predicates, **plus `makeKeyboardArrowFree` and `disableKeyboardKeyFlash`** relocated off `MinfolioPair` (used by mindmap 1421 and editor) |
| `minfolio_frontlight.lua` | `FL`, `lipc_get/set`, `read_frontlight_state`, `fl_apply`, `fl_restore_if_needed`, `fl_adjust`, `toggle_light` |
| `minfolio_chrome.lua` | battery/status text, `battery_indicator`, `show_controls`, `notify`, `schedule_wake_repaint`, **`rotate_screen_ccw` (body at 5273)**, `trace` (relocated off `MinfolioPair`) |

**Tier 2 — transport**

| Module | Contents |
|---|---|
| `minfolio_remote.lua` | **transport only**: `socket` (2008), `sendAll` (2032) |
| `minfolio_pair.lua` | UDP discovery/beacon/pairing, `deviceId`, `secret`, `poll`, `pollRequest`, `showPrompt`, `start` → depends on `minfolio_remote` |

**Tier 3 — the controller (this is the fix for the tangle)**

`minfolio_app.lua` owns everything that was ownerless:

```lua
local App = { active = nil, hooks = {} }   -- hooks: open_note, open_picker, file_manager
function App.setActive(ed) / clearActive(ed) / activeEditor()
function App.openNote(path, remote)        -- was edit_note's entry point
function App.openPicker(dir) / openFileManager(dir)
function App.remoteEdit(descriptor_path)   -- was MinfolioRemote.edit (5240)
function App.remoteStop(session_id)        -- was MinfolioRemote.stop (5264)
return App
```

`minfolio_browser` registers `hooks.open_note`/`open_picker`/`file_manager` at
load. Editor, mindmap, browser, pairing, and the plugin entry all call `App`.
Dependency direction becomes strictly downward: `browser → app`, `edit → app`,
`main → app`. This is both reviewers' recommended fix, and it is what makes the
module a controller rather than the ceremony Codex correctly called out in v1.

**Tier 4 — editor** (4 modules, not 8; boundaries follow verified seams)

| Module | Contents |
|---|---|
| `minfolio_edit_layout.lua` | wrapping, `computeVisualRows`/`visualRows`, `reindexVisualRows`, measurement caches, `textw`/`texth`/`wordw`, `visualRowHeight`, `textWidth`, and **`free_wrap_entry` exported as `Layout.freeWrapEntry`** with its four call sites updated (a named, deliberate exception to verbatim) |
| `minfolio_edit_tables.lua` | **all of 2537–2893** — the table subsystem is one contiguous interleaved unit (spans, wrap, layout, widget build, render, hit-test, cell replace, cell editor). v1 cut it three ways; that was a cut across a seam, not along one. |
| `minfolio_edit_view.lua` | `rebuild`, `refresh`, dirty regions, `lineBand`, `cursorRowBand`, `changedLineRegions`, caret blink, top bar (`buildTopBar`/`topBar`/`toolCell`/`runTopAction`/`openControls`), progress bar |
| `minfolio_edit.lua` | the `MDEdit` class, `init`, lifecycle, text ops, undo/redo, selection, clipboard (`md_clipboard` becomes a file-local here — all uses at 3808–3821), find/outline, input handling, gestures, `savePosition`/`restorePosition`, and the mixin assembly |

`minfolio_edit.lua` stays large (~1,400 lines). That is deliberate: further
subdivision is what produced v1's leaky boundaries, and both reviewers flagged it.
Subdivide later only where the method map (§6.1) shows a clean seam.

**Tier 5 — shell**

| Module | Contents |
|---|---|
| `minfolio_map_view.lua` | `MindmapView` (~830 lines) |
| `minfolio_map_canvas.lua` | `MindmapCanvas` (1108–1177) — split out to respect the size rule |
| `minfolio_browser.lua` | `dir_entries`, `clean_entry_name`, `ensure_dir`, `remove_tree`, dialogs, `show_item_actions`, `open_notes`, `show_file_manager`, and the `edit_note` body (registered as an `App` hook) |
| `main.lua` | `Minfolio` class, launch-flag polling, dispatcher registration. ~8 KOReader requires, not v1's claimed ~30. Target under 120 lines. |

`minfolio_sync.lua` / `.sh` unchanged — separate process, own `LUA_PATH`.

## 6. Mechanisms

### 6.1 The method-assignment map is a prerequisite, not a detail

v1 assigned homes to roughly a third of `MDEdit`'s 160 methods and left the rest to
mid-refactor judgement. Unassigned families included all formatting
(`fmtWrap`/`setLinePrefix`/`indentLine`/`fmtToggle`/`fmtHeader`/`fmtList`/
`fmtOrdered`/`fmtTask`/`insertTable`, 4660–4780), highlights (5124–5206),
`checkRemoteInbox`/`scheduleHeartbeat` (3592–3724), `savePosition`/`restorePosition`
(2097–2137), and hit-testing (`pointToCursor`/`selectWordAt`, 2381–2464).

**Step 0 of the migration produces the complete inventory** — all 160 methods with
assigned module, every cross-boundary plain helper, every forward declaration,
every global, every computed constant. No extraction starts until it exists and is
reviewed. Both reviewers independently identified this as the gap that made v1
unexecutable. Delivered as `INVENTORY.md` (226 methods, 63 cross-boundary helpers,
7 nil-tolerant guard sites, 22 module budget projections).

**`INVENTORY.md`'s line numbers are a snapshot; its assignments are durable.** They
were derived against `main.lua` at 5,755 lines, before any extraction. The moment
step 3 moves Tier 0 out, every subsequent line number shifts. Later steps must use
the inventory for *what goes where* and re-derive line numbers from the current
file — never carry a line number forward across an extraction. Reading stale line
numbers as current is the specific error that broke plan v1 twice, and it is the
easiest way to reintroduce it.

### 6.2 Mixin assembly, corrected

Verified in the mixins' favour: all 160 methods are `function MDEdit:` (no
`.`-style statics), no method body references the `MDEdit` class table itself, and
`ges_events` is wired in `init` (2067–2074) so gesture dispatch resolves by name at
runtime. Verbatim moves plus class-table assignment will dispatch correctly.

The v1 guard was **actively dangerous**:

```lua
assert(MDEdit[name] == nil, ...)   -- WRONG
```

`InputContainer:extend{}` chains `__index`, so this resolves *inherited* methods as
non-nil. `MDEdit` legitimately overrides at least `onKeyPress` (4533) and
`onPhysicalKeyboardDisconnected` (4472), both defined upstream on
`InputContainer`. The assert would fire at load, throw, and KOReader would silently
drop the plugin — precisely the failure the guard exists to prevent, caused by the
guard.

```lua
local MDEdit = InputContainer:extend{ ... }
for _, mixin in ipairs({ require("minfolio_edit_layout"), require("minfolio_edit_tables"),
                         require("minfolio_edit_view") }) do
    for name, fn in pairs(mixin.methods) do
        assert(rawget(MDEdit, name) == nil, "duplicate MDEdit method: " .. name)
        MDEdit[name] = fn
    end
end
```

`rawget` checks only the class's own table, so intended overrides pass and genuine
duplicates still fail loudly. Assemble immediately after `extend`, before the class
is exported or any widget is constructed.

Mixin modules return `{ methods = {...}, fns = {...} }`. The `fns` channel exists
because plain shared helpers (`free_wrap_entry`) are *not* methods: exported onto
the class they would become methods and the bare call sites in other files would
become nil-global calls.

### 6.3 The upvalue hazard, correctly characterised

v1 said a moved function "loses an upvalue". That is imprecise. In the new chunk an
undeclared identifier compiles fine as a **global read**. It fails only when that
path runs, or binds to an unrelated global.

The severity is not uniform, and the lint should concentrate where it is worst:

- **Loud** — a lost constant or function gives `attempt to call a nil value` or
  arithmetic-on-nil at first use. Annoying, but self-announcing.
- **Silent and permanent** — a lost symbol behind a nil-tolerant guard. Every one
  of these must be inventoried before moving: 3962 (`md_split_line_prefix`), 4490
  (`open_markdown_picker`), 5211/5265 (`active_mdedit`), 5225
  (`show_file_manager`), 3816 (`md_clipboard`), and **154
  (`MinfolioRemote`)** — `local sock = MinfolioRemote and MinfolioRemote.socket(...)`,
  a global read 1,854 lines before its assignment at 2007. Step 2 must not leave
  that guard reading nil, or desktop pairing silently stops posting.
  These degrade a feature to a no-op with no error, ever.

Gate: per-module `luajit -bl <file> | grep GGET`, diffed against a per-module
allowlist of expected globals (`string`, `table`, `math`, `ipairs`, `pairs`,
`require`, `os`, `io`, `tostring`, `tonumber`, `type`, `pcall`, `assert`, `select`,
`unpack`, `debug`). Current main.lua has 749 GGETs, so absolute counts are
meaningless — only the diff is. Wire it into `deploy.sh`. `luacheck` is not
installed and is not required for this.

### 6.4 The six globals

`rapidjson` (35), `MINFOLIO_REMOTE_DIR` (61), `MINFOLIO_PAIR_PATH` (64),
`MinfolioPair` (71), `MinfolioBattery` (227), `MinfolioRemote` (2007), plus
`_G.__minfolio_launch_polling` (5734). The comment at 72–75 states they are globals
*because of the local limit* — the constraint this refactor removes. They also sit
in KOReader's shared Lua state, so the collision argument from §3 applies to them
as much as to filenames.

All six become module returns (`local M = {} … return M`). This must also establish
the GGET allowlist baseline, since they are currently legitimate global reads
throughout the file.

## 7. Testing

### 7.1 What can and cannot be tested off-device

v1 claimed five test suites. Three were impossible as specified, because the
modules it specced require KOReader: `md_face` needs `Font` (504), `md_color` needs
`Blitbuffer` (507–509), `key_mods`/`install_keyboard_aliases` need `Device.input`
(817, 838), and `textw`/`texth` instantiate a real `TextWidget` (2192, 2199).

This is exactly the discipline kinbox already encodes and v1 failed to copy:
`kinbox_keys`, `wrap`, `editfield`, `undo`, `time` have zero KOReader requires and
have tests; `kinbox_md` requires `ui/*` and has no test.

Testable, because Tier 0 is now KOReader-free by construction:

1. `minfolio_md_test.lua` — `md_tokenize`, the table grammar (including
   blockquote-prefixed tables and the `start_col`/`end_col` source offsets cell
   editing depends on), and `md_split_line_prefix`.
2. `minfolio_text_test.lua` — utf8 movement, word boundaries, path helpers.
3. `minfolio_map_model_test.lua` — `parse_mindmap` round-trip: markdown → tree →
   markdown.
4. `minfolio_edit_layout_test.lua` — **only after** §7.3 extracts a measurer-injected
   wrapping core, mirroring `kinbox_wrap_test.lua`'s synthetic 10px/char measurer.
   Not possible against `MDEdit:textw` as it stands.

Not testable off-device, and therefore on-device smoke only: widget lifecycle,
e-ink repaint correctness, keyboard ownership, gestures, UI stack transitions,
rotation, pairing.

### 7.2 Characterisation without loading main.lua

v1's "write the test against the current implementation first, in `main.lua`" is
impossible: the targets are file-locals of a chunk that eagerly requires ~30
KOReader modules at lines 4–37, and KOReader is not installed locally.

Workable substitute: copy the function text verbatim into a test scratch file, get
the test green against the copy, then move the original and re-point the test at
the new module. `diff` the moved text against the characterised copy to prove the
move was verbatim. This keeps the property that matters — the test predates the
move and was never written against the refactored code — without requiring the
impossible.

### 7.3 Purity extraction is a separate commit class

Splitting a measurer-injected wrapping core out of `MDEdit:computeVisualRows` is
genuinely valuable and genuinely *not* a verbatim move. It therefore does not
belong in the move commits. Sequence: verbatim mixin split first (behaviour
preserved, reviewable as line moves), then purity extraction as clearly-labelled
follow-up commits with tests. v1 conflated the two.

## 8. Tooling and documentation

`scripts/deploy.sh` currently parse-checks exactly two named files (line 65) and
does one `scp` per file (53–59). Both break at ~20 modules. **This lands before the
first multi-file extraction**, not at the end — v1 scheduled it as step 10, leaving
many opportunities for a partial deploy.

- Parse-check every `*.lua` by glob, locally and on device.
- Single transfer (tar over ssh) or per-file retry. A partial `scp` is the worst
  outcome: it parses but runs mixed versions.
- Run the off-device test suite as a gate.
- GGET diff gate per §6.3.
- Post-restart load assertion: confirm a `trace()` marker appears in the log rather
  than inferring success from a clean `scp`.
- Optional kshell light restart, degrading gracefully.

`RELEASE_CHECKLIST.md`: glob the parse check, add tests and the GGET gate.
`README.md`: replace the 6-row layout table with a tier summary pointing at
`ARCHITECTURE.md`.
**New `ARCHITECTURE.md`**: module map, tier rule, the mixin mechanism and how to
find a given `MDEdit` method, the `minfolio_*` naming rule and why, and the
local-limit history so nobody reintroduces it.
**New `PROTOCOL.md`**: §9.

## 9. Minfolio as a whole

**9.1 The desktop pairing and document channel.** `minfolio_pair`,
`minfolio_remote`, and `minfolio_sync.lua` implement one half of a protocol whose
other half is TypeScript in `kal-kaliper/minfolio`. It is documented only by its
implementations. Specify: UDP discovery on 42771, the pairing handshake and
per-device secret, TLS with certificate pinning, per-session bearer tokens, the
snapshot/outbox/revision file contract, and the `closing`/`stopped` teardown.
`kindle-inbox/PROTOCOL.md` is the model.

**9.2 A real divergence in concurrent-edit semantics.** Verified on the Kindle
side: `minfolio_sync.lua:114–116` submits before it fetches, by design ("Sending
first gives Kindle edits priority over any remote snapshot"), and `fetch` applies a
snapshot only when `next_revision > revision` (85–89). There is a **second**
mechanism v1 missed: `MDEdit:checkRemoteInbox` (main.lua:3597) refuses to apply an
arrived desktop snapshot while the editor is dirty or an outbox exists, and clears
undo/redo when it does apply (3607).

The desktop side reportedly does a three-way diff3 merge, prompting only on
same-line conflicts. **Correction to v1:** I stated that a desktop edit "can be
discarded without a prompt". That is *not verified from this repository* — it
depends on how the desktop server handles a stale `baseRevision`, which the worker
does send (`minfolio_sync.lua:95`), and that repo is not checked out here. Recorded
as an open question, not a finding. Note also that unsent Kindle content is
preserved to `/mnt/us/.minfolio-recovery` (104–112).

Scope: document the Kindle-side rules in `PROTOCOL.md` and **confirm the desktop's
stale-`baseRevision` semantics** as part of that work. Any behaviour change is a
separate product decision, explicitly out of scope here.

**9.3 The kshell launch contract.** kshell forwards `notes` and `edit:PATH` via
`/tmp/minfolio_launch`; `kindle-send` routes to the same flag. Minfolio owns that
format and must not change it without updating kindle-mirror and kindle-tools.
One paragraph in `ARCHITECTURE.md`, cross-referenced from kshell.

**9.4 The markdown subset.** The two halves render different subsets and share no
code (Lua vs TypeScript), so the shared artifact is a spec. `minfolio_md_test.lua`
becomes the executable statement of the Kindle subset.

## 10. Migration sequence

| # | Step | Gate |
|---|---|---|
| 0 | **Inventory** (§6.1): 160-method assignment map, cross-boundary helpers, 5 forward decls, 6 globals, computed constants, nil-tolerant-guard list | reviewed before any extraction |
| 1 | **Harden `deploy.sh`** (§8): glob parse check, single transfer, GGET gate, load assertion | deploy still works on current single-file plugin |
| 2 | Extract Tier 0 (`minfolio_md` incl. `md_split_line_prefix`, `minfolio_text`, `minfolio_map_model`) + their tests. **Must precede step 3** — see below | tests green off-device |
| 3 | Convert the 6 globals to module-locals; establish GGET allowlist baseline. **Distributed, not standalone** — see below | parse + on-device load |
| 4 | Extract Tier 1 (`config`, `io`, `state`, `style`, `const`, `keys` + relocated keyboard helpers, `frontlight`, `chrome` incl. `rotate_screen_ccw`) | parse + load + smoke |
| 5 | Stand up `minfolio_app.lua`; convert all 5 forward decls and `active_mdedit` to it **in place**, still inside main.lua | smoke: open note, remote edit/stop, picker, rotate |
| 6 | Extract Tier 2 (`remote` transport, `pair`); move `MinfolioRemote.edit`/`.stop` bodies into `App` | smoke: desktop pairing |
| 7 | Extract `minfolio_map_canvas`, then `minfolio_map_view` | smoke: mindmap |
| 8 | Editor: mixin loader, then `layout` → `tables` → `view`, **one at a time, deploying between each** | smoke after each |
| 9 | Extract `minfolio_browser`; reduce `main.lua` to the entry | full smoke |
| 10 | `ARCHITECTURE.md`, `PROTOCOL.md`, README, RELEASE_CHECKLIST | — |

**The globals conversion is distributed across steps 3–6, not done in one pass.**
Each of the six belongs to the module that will own it, so converting it *is* part
of extracting that module: `MINFOLIO_REMOTE_DIR` and `MINFOLIO_PAIR_PATH` go to
`minfolio_config` and `MinfolioBattery` to `minfolio_chrome` (step 4);
`MinfolioPair` to `minfolio_pair` and `MinfolioRemote`'s transport half to
`minfolio_remote` (step 6); `MinfolioRemote.edit`/`.stop` to `minfolio_app`
(step 5). Only `rapidjson` is a standalone one-line change, and it is cheap to do
with step 4. Doing them as a separate up-front pass would mean inventing temporary
homes and then moving them again.

As each global disappears, remove its name from `GGET_MINFOLIO` in
`scripts/deploy.sh`, so the lint starts enforcing its absence instead of
permitting it. The list should be empty by the end of step 6.

**Why Tier 0 must precede the globals conversion.** Converting a global to a
top-level local *adds* a local name, and the file is at exactly 200 of 200. So
converting the six globals first needs 206 slots and cannot compile — verified: even
one added local fails today. Tier 0 is the only step that is net-negative on the
budget: it removes 21 top-level locals (8 markdown, 11 text/path, 2 map-model) and
adds 3 `require` locals, netting −18 to about 182 names. That headroom is what makes
every later step possible. Any step that adds a local before Tier 0 lands will fail
to compile, and KOReader will silently drop the plugin.

For the same reason the *first* extraction cannot be a module that only moves table
fields out. Moving `MinfolioPair` alone, for instance, frees no locals — its methods
are table fields — while adding one `require` local, so it is net +1 and fails.

Changes from v1's order, per review: inventory added as step 0; tooling moved from
last to step 1; globals conversion added; the controller seam (step 5) now precedes
*both* the remote extraction and the editor split, because remote orchestration
depends on it.

Rollback is per-step, one commit each.

## 11. Risks

| Risk | Mitigation |
|---|---|
| A moved function's file-local reference becomes a silent global read | §6.3 GGET diff gate; the nil-tolerant-guard inventory (154, 3816, 3962, 4490, 5211, 5225, 5265) gets manual verification, not just lint |
| Partial `scp` leaves mixed-version modules that parse but misbehave | step 1, before any split |
| Module name collides in the shared plugin namespace | mandatory `minfolio_` prefix; grep kshell/kinbox/hidpassthrough before adding a name |
| Mixin assembly rejects a legitimate inherited override | `rawget`, §6.2 |
| Table subsystem or formatting family split across modules mid-refactor | step 0 map; `minfolio_edit_tables` takes all of 2537–2893 |
| DPI baked at `minfolio_const` require time changes behaviour on rotation | constants are already computed once at load today; preserve load order, verify with the rotation smoke test |
| Scope creep into feature or purity work | §2 non-goals; §7.3 keeps purity separate; reviewers reject behaviour changes in move commits |

## 12. Work packages

| WP | Steps | Depends on |
|---|---|---|
| A | 0 (inventory) | — must land and be reviewed first |
| B | 1 (deploy hardening) | none; parallel with A |
| C | 2, 3 (globals, Tier 0 + tests) | A, B |
| D | 4 (Tier 1) | C |
| E | 5, 6 (controller, then transport) | D |
| F | 7 (mindmap) | E |
| G | 8 (editor, three serial moves) | E, F |
| H | 9, 10 (browser, main.lua, docs) | G |

## 13. Acceptance criteria

1. `main.lua` under 120 lines; no module over ~900 lines
   (`minfolio_edit.lua` ~1,400 is an accepted, documented exception).
2. No module declares more than ~60 top-level locals.
3. Every `*.lua` parses locally and on device, checked by glob.
4. Tier 0 modules have zero KOReader requires, enforced by their tests running
   under plain `luajit`.
5. GGET diff is empty against the per-module allowlist.
6. All six globals eliminated.
7. Move commits are verbatim and separable from behaviour changes; `diff` against
   the characterisation copies proves it.
8. On-device smoke: launch, note create, edit/save, reader, mindmap, find, outline,
   resume-position, rotate, KUAL relaunch, desktop pairing edit + stop.
9. `deploy.sh` fails loudly on partial transfer and confirms the plugin loaded.
10. `ARCHITECTURE.md` and `PROTOCOL.md` exist; README and RELEASE_CHECKLIST consistent.

## 14. Review response

Both reviewers verified independently; I re-verified every finding against source
before accepting it. Codex: **rework**. Fable: **proceed with changes**.

| Finding | Source | Verified | Resolution |
|---|---|---|---|
| `assert(MDEdit[name] == nil)` rejects inherited overrides and would disable the plugin | both | yes (4533, 4472 override `InputContainer`) | `rawget`, §6.2 |
| Characterisation-first against main.lua is impossible | both | yes (~30 KOReader requires at 4–37; KOReader not installed) | §7.2 snapshot-copy method |
| `MinfolioRemote` spans two tiers; dependency graph wrong | both | yes (2008/2032 vs 5240/5264) | `minfolio_app` controller, §5 Tier 3 |
| Five forward decls, not two; `md_split_line_prefix` absent from plan | Fable | yes (917, 924, 3868) | §4 table; assigned to `minfolio_md` |
| `md_split_line_prefix` sits behind a nil-tolerant guard | Fable | yes (3962) | §6.3 silent-failure inventory |
| `free_wrap_entry` crosses 3–4 proposed modules | both | yes (2932 → 2982, 4418, 4529, 4655) | `fns` channel + named exception, §6.2 |
| Tier 0 as specced requires KOReader; test plan self-contradictory | both | yes (504, 507–509, 817, 838, 2192, 2199) | pure/adapter split: `minfolio_md` vs `minfolio_style`, `minfolio_text` vs `minfolio_keys` |
| Six deliberate globals unaddressed; `luacheck` absent; 749 baseline GGETs | Fable | yes | §6.4, step 2; diff-based GGET gate |
| ~2/3 of 160 methods unassigned; table subsystem cut across a seam | Fable | yes (2537–2893 contiguous) | step 0 inventory is now a gate; tables kept whole |
| `rotate_screen_ccw` body at 5273 stranded in browser range | Fable | yes | assigned to `minfolio_chrome` |
| Constants are 60 not 57; 9 computed from KOReader; EDIT/MAP not clean | Fable | yes (972, 976–977, 980–1000; 979, 1277, 1565–1589) | §4, §5 `minfolio_const` |
| `MDEdit` has no `paintTo` | Fable | yes | removed |
| Migration order unsafe: tooling last, remote before controller | both | yes | reordered, §10 |
| ~20 modules / 8-way editor split is over-engineered | Codex | partly — Fable measured kinbox at 8,131 lines / ~18 modules, so the *count* is calibrated; both agree the *editor* split was the problem | 22 modules enumerated below; editor 8 → 4 |
| `minfolio_session` is ceremony | Codex | agreed as specced in v1 | promoted to a real controller (`minfolio_app`), which is also Fable's fix for the tangle |
| kinbox has no mixin-assembled class; precedent overstated | Fable | yes | §3 states the mixin approach is novel here |
| §9.2 desktop-discard claim unverified; second mechanism missed | Fable | yes (3597, 3607) | softened to an open question; `checkRemoteInbox` documented |
| Reviewer disagreement on module count | — | — | adjudicated above in favour of Fable's measured precedent, with Codex's editor critique adopted in full |
