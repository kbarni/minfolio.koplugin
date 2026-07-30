# Release Checklist

Run these before publishing or tagging a release.

`scripts/deploy.sh [ssh-host]` is the canonical gate chain and should be run against a real
device before every release: it glob-parse-checks every `minfolio.koplugin/*.lua`, runs the
GGET lint (catches a moved/renamed symbol left behind as a silent global read — see
`ARCHITECTURE.md` for what it does and does not catch), runs the off-device test suite
(`*_test.lua`, currently the three Tier 0 modules — 187 assertions), then transfers the
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

- Confirm `minfolio.koplugin/config.lua` is not tracked.
- Confirm Dropbear/screensaver watchdog files are not tracked unless intentionally added as documented utilities.
- Run `sh scripts/deploy.sh <host>` against a real Kindle and confirm every gate passes, including the on-device parse check and the load-assertion restart.
- Smoke-test on-device: launch, note creation, edit/save, reader mode, mindmap mode, and KUAL relaunch. `deploy.sh`'s load assertion confirms the plugin loaded; it does not exercise any of these features.
- If releasing desktop editing, pair with Minfolio Desktop, verify an edit reaches each device, and stop the session to confirm the remote cache is removed.
