# Release Checklist

Run these before publishing or tagging a release.

`scripts/deploy.sh [ssh-host]` is the canonical gate chain and should be run against a real
device before every release: it glob-parse-checks every `minfolio.koplugin/*.lua`, runs the
GGET lint (catches a moved/renamed symbol left behind as a silent global read — see
`ARCHITECTURE.md` for what it does and does not catch), runs the off-device test suite
(`*_test.lua`, currently the eight Tier 0 modules — 667 assertions), then transfers the
plugin as one atomic operation, parse-checks it again on the device, and attempts a restart
with a load-assertion check. Do not hand-duplicate that chain here; the two commands below
are only for a quick, network-free local check of the same parse/test gates:

```sh
for f in minfolio.koplugin/*.lua; do
    luajit -e "local fn,e=loadfile('$f'); if not fn then print('$f: '..tostring(e)); os.exit(1) end"
done && echo "PARSE OK"
for t in minfolio.koplugin/*_test.lua; do
    (cd minfolio.koplugin && luajit "$(basename "$t")") || exit 1
done
jq empty minfolio-kual/menu.json
sh -n scripts/deploy.sh minfolio-kual/bin/notes.sh minfolio.koplugin/minfolio_sync.sh
rg -n '\b(TOKEN|SERVER_DROP|192\.168|tandemic)\b|/Users/|password|secret|apikey|api_key|bearer' -g '!LICENSE' -g '!RELEASE_CHECKLIST.md' -g '!*node_modules*' .
git status --short --ignored
```

Before release:

- Bump `M.VERSION` in `minfolio.koplugin/minfolio_const.lua` to the version being tagged, and
  confirm `Help: About` in the palette shows it. Nothing derives this from the git tag, and
  About is the only place a user can see which build they are running — a stale value there is
  worse than none, because it is the first thing a bug report will quote.
- Confirm `minfolio.koplugin/config.lua` is not tracked.
- Confirm Dropbear/screensaver watchdog files are not tracked unless intentionally added as documented utilities.
- Run `sh scripts/deploy.sh <host>` against a real Kindle and confirm every gate passes, including the on-device parse check and the load-assertion restart.
- Smoke-test on-device: launch, note creation, edit/save, reader mode, mindmap mode, and KUAL relaunch. `deploy.sh`'s load assertion confirms the plugin loaded; it does not exercise any of these features.
- Smoke-test the command palette on-device. Its command set is covered by
  `minfolio_menu_model_test.lua`, but everything below is widget behaviour that no automated
  gate here can reach (see `ARCHITECTURE.md`, "What can and cannot be tested off-device"):
    - Opens from the hamburger button and, with a Bluetooth keyboard, from `Ctrl-P` — in
      both editing and reader mode.
    - Opens **centred**, with equal margins left/right. With the on-screen keyboard already
      up it shrinks and stays entirely above the keyboard rather than centring behind it.
    - Opens with **no on-screen keyboard summoned** and the full list scrollable. This is the
      one behaviour a touch-only user depends on entirely; a regression makes the palette
      unusable without a Bluetooth keyboard rather than merely worse.
    - Arrows move a **visible** selection, Enter runs it, Esc/Back closes without running
      anything. The highlight depends on passing `FORCED_FOCUS`, and on a device whose
      `hasDPad` is false it disappears silently if that is lost.
    - Selection lands on the first *command*, not on the title bar's search icon — KOReader
      inserts title-bar rows at the top of the focus layout on some devices and not others.
    - Typing filters after a brief pause while the query text updates immediately; a burst
      of typing must not repaint the list per character.
    - A greyed command (e.g. Copy with nothing selected) neither runs nor dismisses.
    - Brightness ± and Text size ± keep the palette open; everything else dismisses it.
    - After the palette closes by *any* route, the editor still accepts typing. This is the
      `is_always_active` handover; losing it makes the editor silently ignore the keyboard
      for the rest of the session.
- If releasing desktop editing, pair with Minfolio Desktop, verify an edit reaches each device, and stop the session to confirm the remote cache is removed.
