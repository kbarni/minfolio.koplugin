# Minfolio Markdown Editor for Koreader

**A simple, distraction-free Markdown editor and note taking app for Koreader.**

Minfolio turns your e-reader into a comfortable writing device: weeks of battery, a glare-free
e-ink screen, and nothing on it but your words. You type in plain Markdown and watch it style itself
as you go, with headings, bold, italic, code, and lists rendered live while you write. Your work saves
automatically as ordinary `.md` files you can sync anywhere.

## Why write on a Kindle

- **No distractions.** No browser, no notifications, no feed. Just the page.
- **Easy on the eyes.** E-ink is paper-like and readable in bright sun, with no backlight fatigue.
- **All-day (all-week) battery.** Write for hours; charge rarely.
- **Light and pocketable.** Pair a Bluetooth keyboard and you have a featherweight writing setup.
- **Plain files you own.** Everything is Markdown on disk, not locked in an app.

## Features

- **Live styling as you type** — headings, **bold**, *italic*, `code`, and lists render inline while you write.
- **Tables** — write pipe tables and edit cells directly in a rendered reader view.
- **Tap-to-tick checkboxes** — tap the box on a `- [ ]` line to check or uncheck it, while editing or while reading. Only the box changes, and the cursor stays where you left it.
- **Reader mode** — flip from editing to a clean, fully rendered view of your document.
- **Mindmap mode** — view the same `.md` as a native Kindle tree, select branches, zoom, add/delete nodes, undo, reorder siblings, and reattach branches.
- **Find and replace** — search the document from a compact find bar (or Ctrl-F) with Previous/Next and a match counter, then replace one match at a time or all at once (Ctrl-H). A whole Replace all is a single undo.
- **Word count** — words, characters, paragraphs, reading time, the size of your selection, and how much you have written this session (Ctrl-W). Markdown syntax never inflates the number: `## Heading` is one word.
- **Outline** — jump straight to any heading from a nested list of the document's structure.
- **Picks up where you left off** — reopening a note restores the passage you were reading, your cursor, and whether you were in reader mode.
- **Real editing** — overlay caret, word wrap, undo/redo, selection, and copy/paste.
- **Type your way** — on-screen keyboard or a paired Bluetooth keyboard.
- **Adjustable text size** — A−/A+ zoom for comfortable writing.
- **Autosaves to Markdown** — notes are stored as `.md` in `/mnt/us/notes`, ready to sync.
- **Built-in notes browser** — open, create, and switch between notes without leaving the app.
- **Edit with desktop** — pair with Minfolio Desktop on your local network for encrypted, Kindle-priority simultaneous editing.

## Usage

Minfolio is built and tested on a **jailbroken Kindle Paperwhite 5**. It runs as a
[KOReader](https://github.com/koreader/koreader) plugin, launched fron the *Tools* menu.

To install the plugin, unzip the Release file in the Koreader plugins folder.

For an optimal typing experience, it is recommended to use it with an external keyboard.
On Kindle, use the excellent [Bluetooth-HID-Passthrough](https://github.com/zampierilucas/kindle-hid-passthrough) library to pair Bluetooth keyboards.

To continue editing on the desktop, use the *Minfolio Desktop* companion app (see below). Alternatively you can synchronize the notes folder with your computer using the [Syncthing](https://github.com/arthurrump/syncthing.koplugin) plugin.

### Keyboard shortcuts

Every formatting action on the toolbar has a chord, so writing never needs the touchscreen.
Ctrl is Command on a Mac keyboard.

| Shortcut | Action |
|---|---|
| `Ctrl-B` / `Ctrl-I` / `Ctrl-E` | Bold / italic / inline code |
| `Ctrl-1` … `Ctrl-6` | Heading level (again on the same level, or `Ctrl-0`, makes it a paragraph) |
| `Ctrl-Shift-L` / `Ctrl-Shift-O` / `Ctrl-Shift-T` | Bullet list / numbered list / checkbox |
| `Tab` / `Shift-Tab` | Indent / outdent a list item |
| `Ctrl-F` / `Ctrl-G` / `Ctrl-Shift-G` | Find / next match / previous match |
| `Ctrl-H` | Find and replace |
| `Ctrl-W` | Word count |
| `Ctrl-S` | Save now (notes autosave anyway) |
| `Ctrl-Z` / `Ctrl-Shift-Z` or `Ctrl-Y` | Undo / redo |
| `Ctrl-A` / `Ctrl-C` / `Ctrl-X` / `Ctrl-V` | Select all / copy / cut / paste |

Find, next/previous match and word count also work in reader mode.

## Config

Minfolio works with no configuration. The defaults are:

```lua
notes_dir      = "/mnt/us/notes"     -- where your .md files live
state_dir      = "/mnt/us/.minfolio" -- where app state is stored
minfolio_scale = 1.0                 -- text zoom level
```

To change them, copy `minfolio.koplugin/config.example.lua` to
`/mnt/us/koreader/plugins/minfolio.koplugin/config.lua` and edit it on the device. Your `config.lua`
is gitignored, so device-specific paths stay local.

## Desktop editing

With Minfolio Desktop, choose **Edit with Kindle** from a desktop tab. The desktop discovers a running
Minfolio instance, asks for confirmation on both devices during first pairing, then opens the same file
on the Kindle. No connection is made merely because Minfolio is open.

This feature requires the desktop to have passwordless SSH access to the Kindle (for example, an SSH
host named `kindle`). The document channel uses TLS with certificate pinning and per-session bearer
tokens; the Kindle editor itself never performs network I/O, keeping typing and rendering on the
KOReader UI loop.

## Project layout

`minfolio.koplugin/` is a flat directory of over 20 `minfolio_*`-prefixed Lua modules plus a
slim `main.lua` entry point, organised in tiers with dependencies pointing downward only:
pure Markdown/text/mindmap-model parsing with no KOReader dependency and its own off-device
tests; KOReader adapters (config, I/O, state, style, constants, keyboard, frontlight, screen
chrome); the desktop transport and pairing handshake; a small controller that owns the live
editor singleton and the desktop remote-session entry points; the `MDEdit` editor itself,
assembled at load time from four files; and the mindmap view, the notes browser, and
`main.lua` on top. `minfolio_sync.lua`/`minfolio_sync.sh` is a separate, isolated,
pinned-TLS worker process used only during an active desktop editing session — never loaded
by KOReader. **See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full module map, the real
dependency graph, and the mechanisms (the mixin assembly, the app controller, the
local-variable-limit history) a contributor needs before changing any of it.**
[`PROTOCOL.md`](PROTOCOL.md) specifies the desktop pairing and document-sync wire protocol
in full.

| Path | Role |
|---|---|
| `minfolio.koplugin/` | The plugin. See `ARCHITECTURE.md`. |
| `minfolio-kual/` | KUAL launcher: `config.xml`, `menu.json`, `bin/notes.sh`. |
| `scripts/deploy.sh` | Developer helper: parse-check, lint, test, and deploy the plugin to a Kindle over SSH. |

## Development

A Lua syntax error makes KOReader silently skip the whole plugin, so `scripts/deploy.sh
[ssh-host]` runs a full local gate before it ever touches the device: parse-check every
`minfolio.koplugin/*.lua` by glob, a lint for global reads that a moved/renamed symbol can
leave behind (see `ARCHITECTURE.md`), and the off-device test suite. Only then does it
transfer the plugin as one atomic operation, parse-check it again on the device, and attempt
a restart with a load confirmation. The argument is an ssh(1) host, so a plain `Host kindle`
block in `~/.ssh/config` is all the setup required (it defaults to `kindle`). See
`RELEASE_CHECKLIST.md` for the pre-release checklist and `ARCHITECTURE.md`/`PROTOCOL.md` for
the module map and the desktop wire protocol.

## Sister app

**[Minfolio](https://github.com/kal-kaliper/minfolio)** is the desktop and mobile counterpart: a clean,
minimalist WYSIWYG Markdown editor and mind-mapping app for macOS, Android, and Meta Quest, built to
work alongside LLMs. Both apps edit plain `.md` files, so notes you write on the Kindle open right up in
Minfolio on your other devices.

## License

Minfolio is licensed under AGPL-3.0-only, matching KOReader's strong copyleft license family. See
[`LICENSE`](LICENSE).

## Trademark

Kindle is a trademark of Amazon. Minfolio is an independent project and is not affiliated with,
endorsed by, or sponsored by Amazon. "for Kindle" describes compatibility only.
