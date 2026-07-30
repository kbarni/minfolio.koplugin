# Minfolio for Kindle: architecture

This is the map a new contributor needs. It describes the plugin as the code in
`minfolio.koplugin/` actually is, at the end of the module-split refactor described in
`PLAN.md`. Where this document and
`PLAN.md` disagree, this document is right and the disagreement is called out explicitly —
`PLAN.md` was a plan, revised twice, and reality drifted from it in a few places during
execution. `PROTOCOL.md` covers the desktop pairing and document-sync wire protocol in
detail; this document only summarises it enough to place `minfolio_pair.lua`,
`minfolio_remote.lua`, and `minfolio_app.lua`'s remote-session code in the module map.

The plugin is 22 Lua files: a 115-line `main.lua` entry point plus 21 `minfolio_*`-prefixed
modules, flat in `minfolio.koplugin/` (no subdirectories), totalling 6,753 lines (`wc -l`,
summed). `minfolio_sync.lua`/`minfolio_sync.sh` is a separate file but not part of this graph — it
is a separate OS process with its own `LUA_PATH`, launched by the desktop over SSH, never
`require`d by anything KOReader loads (see [The kshell launch contract](#the-kshell-launch-contract)
below and `PROTOCOL.md` for what it does). Three more files
(`minfolio_md_test.lua`, `minfolio_text_test.lua`, `minfolio_map_model_test.lua`) are
off-device test suites, not shipped to the device. `_meta.lua` and `config.example.lua`
round out the 28 `*.lua` files `scripts/deploy.sh`'s glob checks find.

## Module map and the dependency graph

The table below is organised the way the code itself is organised: every module's own
header comment cites a `PLAN.md §5 Tier N`, and that tier label is the grouping used here.
The **requires** column, however, was not copied from `PLAN.md` — it is the literal
`require("minfolio_*")` edge list read out of each file with `grep -n 'require(' *.lua`,
current as of this writing. Line counts are `wc -l`.

**Tier 0 — pure, zero KOReader dependencies, off-device testable under plain `luajit`**

| Module | Lines | Role | Requires (minfolio_\*) |
|---|---|---|---|
| `minfolio_md.lua` | 258 | Markdown parsing: `md_inline`, `md_tokenize`, `md_trim`, the table-row/table-block grammar, `md_split_line_prefix`, `MD.heading` | none |
| `minfolio_text.lua` | 92 | UTF-8 movement, word boundaries, path helpers, `split_text_lines`, `is_markdown_file`, `copy_arr` | none |
| `minfolio_map_model.lua` | 126 | `mindmap_node`, `parse_mindmap` (Markdown → tree, and back) | `minfolio_md`, `minfolio_text` |

**Tier 1 — KOReader adapters and app-wide services**

| Module | Lines | Role | Requires (minfolio_\*) |
|---|---|---|---|
| `minfolio_config.lua` | 65 | `plugin_dir`, `load_local_config`/`CONFIG`, `NOTES_DIR`/`STATE_DIR` and every other state path (`MINFOLIO_PAIR_PATH`, `MINFOLIO_REMOTE_DIR`, `FL_STATE_PATH`, `MINFOLIO_STATE_PATH`), `path_parent`, the old-state-dir migration | none |
| `minfolio_io.lua` | 60 | `write_file`/`read_file`/`file_signature`/`same_file_signature`/`now_seconds` | none |
| `minfolio_keys.lua` | 214 | Modifier decoding, key-name aliasing, direction predicates, `makeKeyboardArrowFree`/`disableKeyboardKeyFlash` | none |
| `minfolio_const.lua` | 108 | The 58 `MDEDIT_*`/`MINDMAP_*` layout/timing constants, as `{ EDIT = {...}, MAP = {...} }` | none |
| `minfolio_style.lua` | 48 | `MD_FACES`, `md_face`, `md_color`, `MDEDIT_TABLE_PAD_X`/`_Y` | none |
| `minfolio_state.lua` | 59 | `MINFOLIO_STATE`, scale clamp/save, per-note cursor/scroll positions | `minfolio_config`, `minfolio_io` |
| `minfolio_frontlight.lua` | 160 | The `FL` table, brightness/warmth via `lipc`, suspend/resume capture | `minfolio_config`, `minfolio_io` |
| `minfolio_chrome.lua` | 204 | Battery indicator, the shared controls popup, `notify`, `rotate_screen_ccw`, `trace()` | `minfolio_frontlight` |

**Tier 2 — desktop transport**

| Module | Lines | Role | Requires (minfolio_\*) |
|---|---|---|---|
| `minfolio_remote.lua` | 67 | Pinned-TLS socket connect (`M.socket`) and `M.sendAll` — transport only, no session logic | none |
| `minfolio_pair.lua` | 144 | UDP discovery/beacon on port 42771, the pairing handshake, the per-device secret | `minfolio_remote`, `minfolio_config`, `minfolio_chrome`, `minfolio_io` |

**Tier 3 — the controller**

| Module | Lines | Role | Requires (minfolio_\*) |
|---|---|---|---|
| `minfolio_app.lua` | 120 | The one live-editor singleton (`App.active`/`.setActive`/`.clearActive`/`.activeEditor`); `App.hooks` (`open_note`/`open_picker`/`file_manager`) that the browser registers into at load; `App.remoteEdit`/`App.remoteStop` | `minfolio_config`, `minfolio_io`, `minfolio_chrome` |

**Tier 4 — the editor, `MDEdit`, assembled from four files**

| Module | Lines | Role | Requires (minfolio_\*) |
|---|---|---|---|
| `minfolio_edit_layout.lua` | 358 | Wrapping, the visual-row cache, measurement caches, visual-row coordinate math (18 methods + `free_wrap_entry`) | `minfolio_md`, `minfolio_text`, `minfolio_style`, `minfolio_const` |
| `minfolio_edit_tables.lua` | 401 | The whole table subsystem, kept as one contiguous unit (11 methods) | `minfolio_md`, `minfolio_text`, `minfolio_style`, `minfolio_const`, `minfolio_keys` |
| `minfolio_edit_view.lua` | 838 | `rebuild`/`refresh`, dirty regions, caret blink, top bar, progress bar (28 methods) | `minfolio_text`, `minfolio_io`, `minfolio_style`, `minfolio_const`, `minfolio_chrome` |
| `minfolio_edit.lua` | 1,771 | The `MDEdit` class itself: init, lifecycle, text ops, undo/redo, selection, clipboard, find/outline, input, gestures, save/restorePosition, remote-inbox polling, and the mixin assembly (103 methods) | `minfolio_md`, `minfolio_text`, `minfolio_config`, `minfolio_io`, `minfolio_state`, `minfolio_const`, `minfolio_keys`, `minfolio_frontlight`, `minfolio_chrome`, `minfolio_app`, `minfolio_map_view`, `minfolio_edit_layout`, `minfolio_edit_tables`, `minfolio_edit_view` |

**Tier 5 — shell and entry**

| Module | Lines | Role | Requires (minfolio_\*) |
|---|---|---|---|
| `minfolio_map_canvas.lua` | 109 | The low-level e-ink paint widget for the mindmap (2 methods); split out of `minfolio_map_view.lua` purely to respect the ~900-line guideline | `minfolio_style`, `minfolio_const` |
| `minfolio_map_view.lua` | 904 | `MindmapView`, the native mindmap widget (64 methods); reaches the editor only through the `editor` field injected at construction, never by requiring `minfolio_edit` | `minfolio_md`, `minfolio_text`, `minfolio_map_model`, `minfolio_io`, `minfolio_state`, `minfolio_style`, `minfolio_const`, `minfolio_keys`, `minfolio_chrome`, `minfolio_map_canvas` |
| `minfolio_browser.lua` | 532 | The notes browser: dir listing, dialogs, `edit_note` (constructs `MDEdit`); registers all three `App.hooks` at load | `minfolio_text`, `minfolio_config`, `minfolio_io`, `minfolio_chrome`, `minfolio_frontlight`, `minfolio_app`, `minfolio_edit` |
| `main.lua` | 115 | The plugin entry: launch-flag polling, dispatcher registration, KUAL menu entry | `minfolio_config`, `minfolio_keys`, `minfolio_frontlight`, `minfolio_chrome`, `minfolio_app`, `minfolio_pair`, `minfolio_browser` |

**The rule is: dependencies point downward only.** Nothing in a lower tier requires anything
from a higher one, and this was checked exhaustively above, not sampled — every
`require("minfolio_*")` in the plugin appears in the tables above, and every edge runs from
a higher tier to an equal-or-lower one. There is no automated cycle checker; the rule is
enforced by the controller pattern described below (the one place a cycle would otherwise
form) and by convention. Two things worth knowing before you read "tier" as "measured
dependency depth", because they are not the same axis:

- **`minfolio_map_canvas.lua` is Tier 5 by subject (it's part of the mindmap "shell"), but
  its actual dependency depth is as shallow as `minfolio_state.lua`** — it requires only
  `minfolio_style`/`minfolio_const` (Tier 1). It sits in Tier 5's table because it is
  mindmap-specific code, not because anything forces it to load late.
- **`minfolio_pair.lua` (Tier 2) and `minfolio_app.lua` (Tier 3) do not depend on each
  other.** They are siblings at the same real dependency depth (each pulls in one Tier-1
  module, `minfolio_chrome`), not a chain. The Tier 2 → Tier 3 ordering in `PLAN.md`
  reflects subject grouping (transport, then session control) and migration order, not a
  requires edge.

The one place a cycle was a real risk — the editor needing to open the file picker, and the
browser needing to construct the editor — is exactly what `minfolio_app.lua` exists to
prevent; see [The controller](#the-controller-minfolio_app) below.

## The local-variable ceiling and its history

LuaJIT allows 200 named locals per function scope, and a Lua source file is itself one
function — its top level is that function's body. Before this refactor,
`minfolio.koplugin/main.lua` was 5,755 lines and had exactly 200 top-level local names: 198
`local` statements, one of which (`local open_markdown_picker, rotate_screen_ccw,
show_file_manager`) declared three names at once. The file was confirmed to sit at the
ceiling **exactly**, not near it: appending a single `local __probe = 1` failed to compile
with `main function has more than 200 local variables`, and the correct fix for an unrelated
bug in the file (adding one forward declaration) was itself impossible for the same reason.
KOReader silently drops a plugin whose Lua fails to compile — no dialog, nothing the user
sees — so the failure mode for adding one more top-level local was "Minfolio vanishes from
the menu", with no error visible anywhere.

That ceiling is why the split happened, and it explains two things in the pre-refactor code
that would otherwise look like odd choices. First, `MinfolioPair` (the old pairing table)
hosted `trace()`, `makeKeyboardArrowFree()`, and `disableKeyboardKeyFlash()` — none of which
are pairing concerns — because a **table field** does not consume a local slot the way a
top-level `local function` does; parking unrelated helpers on an existing table was a way to
add functionality without spending the budget. Second, six values (`rapidjson`,
`MINFOLIO_REMOTE_DIR`, `MINFOLIO_PAIR_PATH`, `MinfolioPair`, `MinfolioBattery`,
`MinfolioRemote`) were outright Lua globals, for the identical reason: a global assignment
doesn't declare a local either. Of the 200 names, 60 were constants (`MDEDIT_*`/`MINDMAP_*`).

The split removed the ceiling by giving each module its own 200-name budget. Per-module
local counts today (`grep -c '^local '` per file, a reasonable proxy for top-level locals)
top out at 37 in `minfolio_browser.lua` — comfortably under the ~60 guideline `PLAN.md §13`
set, and nowhere near 200. `main.lua` itself now declares **17** top-level locals, none of
them a forward declaration: the five old forward-declared names
(`open_markdown_picker`/`rotate_screen_ccw`/`show_file_manager`/`active_mdedit`, plus one the
plan didn't count, `FL`) are all gone from `main.lua`, either relocated to the module that
owns them (`rotate_screen_ccw` → `minfolio_chrome`, `FL` → `minfolio_frontlight`) or replaced
by a controller call (`active_mdedit` → `App.active`, `open_markdown_picker`/
`show_file_manager` → `App.openPicker`/`App.openFileManager`, both now owned outright by
`minfolio_browser.lua`, which still forward-declares them locally for its own internal
ordering reasons — see that file's header comment).

**Do not reintroduce this.** A module approaching a few dozen top-level locals is not a
crisis (the budget is 200, not 60 — 60 is a design guideline, not a hard gate) but a module
that starts padding a table with unrelated methods to dodge the local count, the way
`MinfolioPair` once did, is the exact smell that produced the original problem. If a module
is trending toward the ceiling, split it — table fields don't need to be method tables of a
KOReader class; a plain returned module table (`local M = {}; function M.foo() ... end;
return M`) already gets every function for free without spending a local, which is why none
of the 21 modules today are anywhere close to 60, let alone 200 -- the largest is
`minfolio_browser.lua` at 37.

## The `minfolio_*` prefix rule and why

KOReader loads a plugin's directory onto `package.path` and shares one `package.path` and
one `package.loaded` table across **every installed plugin**, not just Minfolio. A bare
`require("util")` or `require("keys")` from inside Minfolio would resolve to whatever module
of that name loaded first — kshell's, kinbox's, or Minfolio's own, depending on load order —
and two plugins defining a same-named module is a live collision, not a hypothetical one.

Every Minfolio module is therefore `minfolio_`-prefixed (`minfolio_md.lua`,
`minfolio_edit.lua`, and so on) and the directory stays flat — no subdirectories, because a
subdirectory changes nothing about the shared-namespace problem and only adds path
complexity. This mirrors the sibling plugins on the same device: kinbox uses a `kinbox_*`
prefix (`kinbox_store`, `kinbox_keys`, ...), and kshell uses `require("restart_flag")`
un-prefixed only because it is the one plugin that owns that specific, singular flag concept
device-wide. Before adding a new module name, grep the sibling plugin checkouts
(kshell, kinbox) for the bare name to confirm it doesn't already exist there — `PLAN.md`'s
own risk register calls this out explicitly, and it is a five-second check against a
multi-plugin collision that would otherwise fail in a very confusing way (the wrong module
silently satisfying the `require`, not an error).

## The mixin mechanism

`MDEdit`, the editor widget class, is assembled from four files at `require` time, not
defined in one. `minfolio_edit.lua` declares the real class
(`local MDEdit = InputContainer:extend{...}`) and, at the very end of the file, folds in the
other three:

```lua
for _, mixin in ipairs({ require("minfolio_edit_layout"),
                         require("minfolio_edit_tables"),
                         require("minfolio_edit_view") }) do
    for name, fn in pairs(mixin.methods) do
        assert(rawget(MDEdit, name) == nil, "duplicate MDEdit method: " .. name)
        MDEdit[name] = fn
    end
end
```

Each of `minfolio_edit_layout.lua`, `minfolio_edit_tables.lua`, and `minfolio_edit_view.lua`
declares its own **local proxy table also named `MDEdit`** (`local MDEdit = {}`, a plain
table, not the real class) purely so every method inside that file can keep its original,
unedited `function MDEdit:name(...)` declaration line. At the bottom of each mixin file,
`return { methods = MDEdit, ... }` hands that proxy table's contents back as
`mixin.methods`, and the loop above copies each `name = fn` pair onto the *real* `MDEdit`.

**The guard must be `rawget`, not plain indexing, and this is load-bearing, not stylistic.**
`InputContainer:extend{}` chains `__index` up to `InputContainer` and further up the widget
hierarchy, so a plain `MDEdit[name] == nil` check would resolve an *inherited* method
(anything `MDEdit` doesn't define itself but `InputContainer` does) as non-`nil`, and reject
it as a false "duplicate". `MDEdit` legitimately overrides at least `onKeyPress` and
`onPhysicalKeyboardDisconnected`, both defined upstream on `InputContainer`. A plain-index
guard would `assert()`-fail on the very first of those at load time, which throws, which
means KOReader silently drops the whole plugin — the exact failure this guard exists to
prevent, caused by the guard itself. `rawget` checks only `MDEdit`'s own table, ignoring the
inherited chain entirely, so a legitimate override passes and a genuine duplicate (the same
method name defined in two mixin files) still fails loudly at load time, which is the
correct behaviour for that case.

**`methods` vs `fns`, and why `fns` exists.** A mixin's `methods` table holds everything
declared `function MDEdit:name(...)` — real colon methods, dispatched as `self:name(...)`
after assembly. But not everything a mixin file defines is a method: `free_wrap_entry` in
`minfolio_edit_layout.lua` is a plain `local function free_wrap_entry(entry)`, called bare
(not through `self:`) from inside `minfolio_edit.lua` at three sites
(`onScreenResize`, `onCloseWidget`, `bumpScale`). If it were folded into `methods` and
assigned onto the class, those three bare call sites — which are not `self:`-prefixed and
never will be, since the callers don't have a `self` of the right shape at that point in the
call — would still compile, but would resolve as a **global read** at runtime (a symbol that
used to be an in-scope upvalue in the pre-split single file, now nothing), silently returning
`nil` forever with no error. `minfolio_edit_layout.lua` avoids this by returning
`{ methods = MDEdit, fns = { freeWrapEntry = free_wrap_entry } }` and documenting the
intended call form in its own header comment: `Layout.freeWrapEntry(entry)`, called on
the module's own table. `free_wrap_entry` is the only helper in the codebase that needs this
second channel; `minfolio_edit_tables.lua` and `minfolio_edit_view.lua` both return
`{ methods = MDEdit }` with no `fns` table at all, because neither has a plain
cross-boundary helper of this shape.

**A real defect this channel produced, found while writing this document and since fixed —
worth keeping as the clearest example of the failure class described below.** The module
returns `{ methods = MDEdit, fns = { freeWrapEntry = free_wrap_entry } }`, so the helper's
access path is `Layout.fns.freeWrapEntry`. But the module's own header comment documented the
flat `Layout.freeWrapEntry(entry)`, and all three call sites in `minfolio_edit.lua`
(`onScreenResize`, `onCloseWidget`, `bumpScale`) were written that way — one level too
shallow, consistent with the documented intent but not with what the module actually
returned. `Layout.freeWrapEntry` was therefore `nil`, and each of those three sites would
have raised `attempt to call a nil value (field 'freeWrapEntry')` the next time it ran with a
non-empty `self._wrap_cache`, which in practice is from the editor's first render onward:
`computeVisualRows` sets that cache on every call, and `init()` triggers one via `rebuild()`.
Closing a note would have been enough to hit it.

The fix binds the function rather than the module:

```lua
local free_wrap_entry = require("minfolio_edit_layout").fns.freeWrapEntry
```

which makes the three call sites `free_wrap_entry(entry)` — byte-identical to the pre-split
code, so there is no qualification left to get wrong. The general lesson: when a `fns` helper
is reached through the module table, the nesting is one more thing that has to agree across
files, and nothing checks it. Bind the function.

**How to find where a given `MDEdit` method is defined**, now that the 160 methods are
spread across four files instead of one: every mixin file preserves the original
`function MDEdit:name(...)` declaration line verbatim (that is the entire point of the local
proxy table), so a single grep finds it in exactly one file:

```sh
grep -n '^function MDEdit:methodName' minfolio.koplugin/minfolio_edit*.lua
```

The grep above is the authoritative answer, because the method declarations are the only
record that cannot drift. The four files divide the 160 methods as: `minfolio_edit_layout`
18 (wrapping, visual rows, measurement), `minfolio_edit_tables` 11 (the table subsystem,
deliberately kept whole), `minfolio_edit_view` 28 (rebuild, refresh, dirty regions, top
bar), and `minfolio_edit` the remaining 103 (the class, text ops, undo, selection, find,
gestures, lifecycle). If the grep comes up empty the method was renamed or removed; if it
finds two hits, that is the `rawget` assert's job to have caught at load time.

## The controller (`minfolio_app`)

Before the split, `MinfolioRemote` (the desktop session-control table) spanned two
architectural tiers at once: its low-level fields (`.socket`, `.sendAll`) were pure
transport, called *by* the pairing code; its high-level fields (`.edit`, `.stop`) were
session control, which called *into* the browser (to open a note) and the editor (to close
one). No single module could hold both without creating an upward dependency somewhere —
either transport would have to know about the browser, or the browser/editor would have to
know about transport, and either way the tier ordering would break.

`minfolio_app.lua` is the fix: a small controller with no rendering, no transport, and no
file-browsing logic of its own. It owns three things — the one live `MDEdit` singleton
(`App.active`, read/written through `App.setActive`/`.clearActive`/`.activeEditor`, never
directly), a hook table (`App.hooks.open_note`/`.open_picker`/`.file_manager`, populated by
`minfolio_browser.lua` at load time, not by `minfolio_app.lua` itself), and the two entry
points a remote desktop session uses (`App.remoteEdit(descriptor_path)`,
`App.remoteStop(session_id)`).

**The cycle it breaks:** `minfolio_browser.lua` constructs `MDEdit` directly (it
`require`s `minfolio_edit`, to build the editor when a note is opened), and `MDEdit` needs to
open the file picker (`saveAndOpenMarkdown` calls it) and return to the file listing when it
closes (`edit_note`'s `on_close` callback does this). If `minfolio_edit.lua` `require`d
`minfolio_browser.lua` directly to reach those, the pair of edges (`browser → edit` to
construct it, `edit → browser` to reach the picker) would form exactly the cycle the tier
rule forbids. Instead, `minfolio_browser.lua` registers its three functions into
`App.hooks` at load, and `minfolio_edit.lua` calls `App.openPicker(...)` /
`App.openFileManager(...)` — it never requires `minfolio_browser` at all (confirmed: no
`require("minfolio_browser")` appears anywhere in `minfolio_edit.lua` or any of its three
mixins). The dependency edge stays one-way in both directions: `browser → app` and
`edit → app`, never the reverse.

## What can and cannot be tested off-device

Only three modules have any automated test coverage: `minfolio_md.lua`,
`minfolio_text.lua`, and `minfolio_map_model.lua` — the Tier 0 modules, and no others. Their
own header comments state the reason plainly: each is "deliberately zero KOReader
dependencies... not a style preference, it is the only way any of this can be checked
off-device." Every other module requires at least one real KOReader module (`Device`,
`Screen`, `Font`, `Blitbuffer`, `UIManager`, a widget class, `libs/libkoreader-lfs`, or
`socket`/`ssl`, none of which resolve under a plain `luajit` outside a KOReader checkout —
verified: `luajit -e 'require("libs/libkoreader-lfs")'` fails in this environment), so those
modules can only be `loadfile`-parsed for a syntax check, never `require`d and executed.
There is no KOReader install in this repository or CI, so "cannot be required off-device"
means "cannot be automatically tested at all here" — everything outside Tier 0 is on-device
smoke-test territory only: widget lifecycle, e-ink repaint correctness, keyboard ownership,
gestures, UI stack transitions, rotation, and desktop pairing.

Running `sh scripts/deploy.sh` locally (parse-check stage) confirms the current state: 28
`*.lua` files parse cleanly, and the three test files together run **187 assertions, 0
failing** (`minfolio_map_model_test.lua`: 39, `minfolio_md_test.lua`: 99,
`minfolio_text_test.lua`: 49).

**The purity discipline that makes this possible has to be preserved deliberately, not
assumed.** It would be easy, while extending `minfolio_md.lua`, to reach for a KOReader
`Font` call to settle some rendering question — at which point the module stops being
`require`-able under plain `luajit` and its test suite stops running, silently, the next
time `scripts/deploy.sh` executes it (an `attempt to call a nil value` or similar from a
missing `Font` global, not a clear "you broke the purity rule" message). The boundary that
keeps this from happening is the one `PLAN.md §4` already drew and the
current module split preserves exactly: `minfolio_md.lua` holds parsing
(`md_inline`/`md_tokenize`/...) and `minfolio_style.lua` holds the render-facing half
(`md_face`/`md_color`, which need `Font`/`Blitbuffer`) as a separate, KOReader-dependent
module. Any change that adds a KOReader `require` to `minfolio_md.lua`,
`minfolio_text.lua`, or `minfolio_map_model.lua` needs to be treated as removing that
module's only test coverage, not as a small addition.

## The GGET lint

`scripts/deploy.sh` runs `luajit -bl <file> | grep GGET` per module and diffs the global
names it reads against an allowlist. `GGET` is LuaJIT's bytecode instruction for reading a
global variable; it appears when the compiler encounters an identifier that isn't a local,
an upvalue, or a table field — i.e. exactly the shape a moved symbol takes when a `move`
commit relocates a `local function foo()` to a new module but leaves some call site's
reference to the bare name `foo` behind. Before the split, this pattern could be silent
forever: several of the moved symbols in the original `main.lua` sat behind a
nil-tolerant guard (`if md_split_line_prefix then ...`, `if open_markdown_picker then ...`),
so a stray global read wouldn't error, it would just make that guard permanently false and
quietly disable a whole feature (smart-newline continuation, the "Open .md file..." picker)
with no error anywhere, ever. The GGET lint catches exactly this shape of mistake, and only
this shape: it flags a global read that isn't on the allowlist, forcing the developer to
either add the missing `require` or justify the read.

`GGET_MINFOLIO`, the allowlist entry for Minfolio's own names, is `""` — empty, deliberately,
and the comment above it in `scripts/deploy.sh` explains why with a concrete example rather
than an abstraction: while `MinfolioBattery` briefly sat in that allowlist during migration,
`minfolio_chrome.lua` took ownership of it and stopped assigning the global — but five call
sites in `minfolio_browser.lua` still read it bare as `MinfolioBattery.infoKey(...)` etc. The
lint stayed green throughout, because those reads were allowlisted, and it masked five
guaranteed nil-index errors on the battery indicator until someone read the code by hand.
Those five call sites are now `Chrome.MinfolioBattery.infoKey(...)` — a table-field read on
the required `minfolio_chrome` module, not a global — and the allowlist entry that would
have hidden a regression of the same kind was removed rather than kept "just in case".

**What GGET structurally cannot catch is any defect of that same shape one level down: a
table-field access, not a global read.** `Chrome.MinfolioBattery.doesNotExist` or
`Layout.freeWrapEntry` (see [The mixin mechanism](#the-mixin-mechanism) above, which is a
real, since-fixed instance of exactly this) both compile to ordinary table indexing — `GETFIELD`
bytecode, not `GGET` — because `Chrome` and `Layout` are real, correctly-`require`d local
variables. The lint has nothing to diff a `GETFIELD` against; it only ever sees the global
namespace. This is why the five `MinfolioBattery` call sites above were a real, live bug that
this exact lint could not have found by construction, and why the `Layout.freeWrapEntry`
mismatch documented above was invisible to it too: both are correctly-scoped reads of a
table that just doesn't have the key being asked for. Catching this class of defect requires
either running the code on a device or reading it by hand — there is no tooling substitute
for it in this codebase today.

## The kshell launch contract

Minfolio's KUAL launcher (`minfolio-kual/bin/notes.sh`) writes the literal text `notes` into
`/tmp/minfolio_launch` and starts (or wakes) KOReader; `main.lua`'s `Minfolio:pollLaunchFlag`
polls that file every 0.5 seconds, consumes and deletes it on read, and dispatches on its
contents: `notes`/`open` opens the notes browser, `edit:<path>` opens a specific file
(`App.openNote`), `remote:<descriptor-path>` starts a desktop editing session
(`App.remoteEdit`), and `remote-stop:<session-id>` ends one (`App.remoteStop`). This
mechanism, and its exact five-form vocabulary, is entirely implemented in this repository
and verified directly from `main.lua`.

What is **not** implemented in this repository, and is recorded here only as external
context (consistent with `minfolio_browser.lua`'s own comment mentioning "a re-send via
kindle-send" as a caller, and `PLAN.md §9.3`): kshell (a separate KOReader plugin, in the
`kindle-mirror` repository) forwards its own `notes`/`edit:PATH` requests by writing this
same `/tmp/minfolio_launch` file in this same format, and `kindle-send` (a CLI in the
`kindle-tools` repository) routes a "send this file to the Kindle" request through the same
flag. Neither of those repositories is checked out alongside this one, so their side of the
contract could not be verified while writing this document — only Minfolio's own read side.
**Minfolio owns this file format.** Changing the flag's location, its five recognised
prefixes, or the polling mechanism is a breaking change to two other repositories that this
repository cannot see and cannot test against; do not change it without updating
`kindle-mirror` and `kindle-tools` in the same change.
