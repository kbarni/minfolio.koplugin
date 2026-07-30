#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Deploy Minfolio to the Kindle.
#
# Gates, in order: parse-check every *.lua in the plugin dir (glob, not a
# named list), lint each one for global reads that aren't on the allowlist,
# run any off-device test suite, THEN transfer as a single atomic operation,
# parse-check again on the device, and finally attempt a light restart and
# look for evidence the plugin actually loaded.
#
# Why glob instead of a fixed file list: a Lua syntax error makes KOReader
# silently skip the WHOLE plugin -- no dialog, nothing the user sees -- and
# the module split took this plugin from 4 files to over 20. A hardcoded file
# list is exactly the kind of check a new module can silently escape.
# See PLAN.md section 8 and section 6.3.
#
# Usage: scripts/deploy.sh [ssh-host]
#
# The argument is an ssh(1) host, so a plain `Host kindle` block in
# ~/.ssh/config is all that is required. If the optional kindle-utils resolver
# happens to be installed alongside this checkout it is used instead, which
# also finds a Kindle whose address has changed since the config was written.
# Set KINDLE_TOOLS_DIR to point at it, or KINDLE_NO_RESOLVE=1 to force plain SSH.
set -eu
TARGET="${1:-kindle}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_LOCAL="$DIR/minfolio.koplugin"
KINDLE_TOOLS_DIR="${KINDLE_TOOLS_DIR:-$DIR/../kindle-utils/kindle-tools}"
RESOLVER="$KINDLE_TOOLS_DIR/kindle-mcp"
PLUGIN_DIR="/mnt/us/koreader/plugins/minfolio.koplugin"

say() { printf '%s\n' "$*"; }
die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

# ---- 1. Local gates (no network) ------------------------------------------
# Fail fast: a broken module should never even try to resolve the device.

LUAJIT_LOCAL="${LUAJIT_LOCAL:-/opt/homebrew/bin/luajit}"
if ! command -v "$LUAJIT_LOCAL" >/dev/null 2>&1; then
    LUAJIT_LOCAL="$(command -v luajit 2>/dev/null || true)"
fi
[ -n "$LUAJIT_LOCAL" ] || die "no local luajit found (tried \$LUAJIT_LOCAL and PATH); set LUAJIT_LOCAL=/path/to/luajit"

say "== local parse check =="
n=0
for f in "$PLUGIN_LOCAL"/*.lua; do
    [ -e "$f" ] || continue
    "$LUAJIT_LOCAL" -e "local fn,e=loadfile('$f'); if not fn then io.stderr:write(tostring(e)..'\n'); os.exit(1) end" \
        || die "local parse failed: $(basename "$f")"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || die "no *.lua files found under $PLUGIN_LOCAL -- wrong directory?"
say "   $n file(s) OK"

# GGET lint (PLAN.md section 6.3): a symbol moved between modules during the
# refactor compiles fine as a bare global read if its declaration is left
# behind -- loudly if something calls it, silently forever if it sits behind
# a nil-tolerant guard (e.g. `if md_split_line_prefix then`). `luajit -bl`
# dumps bytecode including GGET (global-read) instructions; diffing the
# global names actually read against an allowlist catches an unintentional
# new one without requiring luacheck (not installed, see PLAN.md section 3).
# This runs against the LOCAL luajit only -- it is a source-level lint for
# the developer, not a device runtime check.
say "== GGET global-read lint =="

# Standard-library globals actually read across the CURRENT plugin files,
# verified empirically with `luajit -bl <file> | grep GGET` (do not extend
# this by guessing -- if a future module needs another stdlib global, add it
# here with the same evidence). Covers main.lua, minfolio_sync.lua, _meta.lua.
GGET_STDLIB="_G arg assert debug dofile io ipairs math os pairs pcall rawget require select string table tonumber tostring type unpack"

# The lint globs *.lua, which includes the *_test.lua files arriving with the
# Tier 0 modules in work package C. Off-device tests legitimately read two more
# stdlib globals that no shipping module does: `print` for the pass/fail summary
# and `package` for the `package.path` bootstrap that lets a test require its
# module by name. Evidence, not guesswork -- both appear in the precedent this
# convention is copied from:
#   luajit -bl kindle-inbox/kinbox.koplugin/kinbox_wrap_test.lua | grep GGET
#     -> arg io ipairs os package print require string table
# Without these the first test file added would fail the lint, not the tests.
GGET_TESTS="print package"

# All six deliberate Minfolio globals (PLAN.md section 6.4) are gone -- each was
# a global only because of the 200-local ceiling this refactor removed. They now
# belong to minfolio_config (rapidjson, MINFOLIO_REMOTE_DIR, MINFOLIO_PAIR_PATH),
# minfolio_chrome (MinfolioBattery), minfolio_pair and minfolio_remote. This list
# is deliberately EMPTY: any Minfolio-looking global read is now a lint failure.
#
# Do not add a name back here without a written justification. While
# MinfolioBattery sat in this list, minfolio_chrome took ownership of it and
# stopped assigning the global, yet five call sites still read it bare -- the
# lint stayed green and masked five guaranteed nil-index errors on the battery
# indicator. Allowlisting a name disables the only check that catches exactly
# that, which is why the list is empty rather than merely short.
GGET_MINFOLIO=""

# Empty, and it should stay that way. This lint found a real bug on its very
# first run against existing code: notify() was called from a callback written
# 755 lines before `local function notify`, so it compiled to a nil global
# read and desktop pairing threw on its success path. Add a name here only
# with a written justification and a plan to remove it.
GGET_KNOWN_BUGS=""

GGET_ALLOWLIST="$GGET_STDLIB $GGET_TESTS $GGET_MINFOLIO $GGET_KNOWN_BUGS"

gget_bad=0
for f in "$PLUGIN_LOCAL"/*.lua; do
    [ -e "$f" ] || continue
    names="$("$LUAJIT_LOCAL" -bl "$f" 2>/dev/null | grep GGET | sed -E 's/.*"([^"]+)".*/\1/' | sort -u)"
    for gname in $names; do
        case " $GGET_ALLOWLIST " in
            *" $gname "*) : ;;
            *)
                say "   $(basename "$f"): unexpected global read: $gname"
                gget_bad=1
                ;;
        esac
    done
done
[ "$gget_bad" -eq 0 ] || die "GGET lint failed -- a moved/renamed symbol may have become a silent global read (PLAN.md section 6.3)"
say "   OK ($(printf '%s\n' $GGET_ALLOWLIST | wc -l | tr -d ' ') names allowlisted)"

# Off-device test suite (PLAN.md section 7). Only the KOReader-free Tier 0
# modules can be tested this way; everything else needs a device. The
# empty-glob case is still handled, so removing every test file degrades to a
# skip rather than trying to run a literal "*_test.lua".
say "== off-device tests =="
t_count=0
for t in "$PLUGIN_LOCAL"/*_test.lua; do
    [ -e "$t" ] || continue
    t_count=$((t_count + 1))
    printf '   %-30s ' "$(basename "$t")"
    (cd "$PLUGIN_LOCAL" && "$LUAJIT_LOCAL" "$t") || die "test failed: $(basename "$t")"
done
if [ "$t_count" -eq 0 ]; then
    say "   (none yet)"
else
    say "   $t_count test file(s) OK"
fi

# Deploy manifest: every *.lua file except dev-only ones, plus the sync
# shell wrapper. This is glob-derived like the checks above it, so a future
# minfolio_*.lua module is transferred automatically -- no deploy.sh edit
# needed. config.lua is included precisely when it exists locally, which
# reproduces the old script's `[ -f config.lua ]` special case for free.
DEPLOY_FILES=""
DEPLOY_COUNT=0
for f in "$PLUGIN_LOCAL"/*.lua; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
        *_test.lua | config.example.lua) continue ;;
    esac
    DEPLOY_FILES="$DEPLOY_FILES $base"
    DEPLOY_COUNT=$((DEPLOY_COUNT + 1))
done
if [ -f "$PLUGIN_LOCAL/minfolio_sync.sh" ]; then
    DEPLOY_FILES="$DEPLOY_FILES minfolio_sync.sh"
    DEPLOY_COUNT=$((DEPLOY_COUNT + 1))
fi
[ "$DEPLOY_COUNT" -gt 0 ] || die "nothing to deploy"

# ---- 2. Resolve the device -------------------------------------------------
# Default transport: ssh/scp straight to the named host.
SSH_TARGET="$TARGET"
TRANSPORT="ssh"
DESCRIPTION="$TARGET"
ssh_k() { ssh "$SSH_TARGET" "$@"; }
scp_k() { scp -O "$@"; }

if [ -z "${KINDLE_NO_RESOLVE:-}" ] && [ -x "$RESOLVER" ]; then
    RESOLUTION="$("$RESOLVER" --resolve "$TARGET")" || {
        echo "Could not locate Kindle profile '$TARGET'. Wake it or check its relay." >&2
        echo "To bypass the resolver and use ssh directly: KINDLE_NO_RESOLVE=1 $0 $TARGET" >&2
        exit 1
    }
    TAB="$(printf '\t')"
    RESOLVED_HOST="${RESOLUTION%%"$TAB"*}"
    TRANSPORT="${RESOLUTION#*"$TAB"}"
    [ -n "$RESOLVED_HOST" ] && [ "$TRANSPORT" != "$RESOLUTION" ] || {
        echo "Invalid Kindle resolver response: $RESOLUTION" >&2
        exit 1
    }
    DESCRIPTION="$RESOLVED_HOST"
    if [ "$TRANSPORT" = "secure-relay" ]; then
        SSH_TARGET="$RESOLVED_HOST"
    else
        # Keep the profile's SSH user/key settings while replacing only its
        # stale HostName with the address discovered by kindle-utils.
        ssh_k() { ssh -o "HostName=$RESOLVED_HOST" "$SSH_TARGET" "$@"; }
        scp_k() { scp -O -o "HostName=$RESOLVED_HOST" "$@"; }
    fi
fi

echo "Deploying via $TRANSPORT ($DESCRIPTION) ..."

# Preflight: prove we can actually authenticate before starting the transfer.
# Without this, an auth failure surfaces from inside the tar pipeline and gets
# reported as "connection dropped or remote extraction failed", which sends you
# looking for a network fault instead of an ssh config problem.
#
# The specific trap: on the LAN path the resolver supplies only an address, and
# the script keeps "$TARGET" as the ssh destination so the host's own User and
# IdentityFile still apply. That means $TARGET must be a real ssh_config Host.
# kindle-utils profile names (pw5, pw2) are NOT ssh hosts, so `deploy.sh pw5`
# resolves the address fine and then authenticates as the local user with no
# key. Fail here, loudly, naming the cause.
if ! ssh_k 'true' >/dev/null 2>&1; then
    echo "deploy: cannot authenticate to '$SSH_TARGET' (resolved $DESCRIPTION)." >&2
    echo "  '$SSH_TARGET' must be a Host in ~/.ssh/config with the right User and" >&2
    echo "  IdentityFile. kindle-utils profile names such as pw5/pw2 are not ssh" >&2
    echo "  hosts -- try the ssh host name instead (e.g. 'kindle')." >&2
    exit 1
fi

# ---- 3. Transfer ------------------------------------------------------------
# Single archive over one SSH connection, staged then swapped into place.
#
# Why tar-over-ssh instead of the old per-file scp loop: the one documented
# failure in this exact class of script -- see kindle-inbox/scripts/deploy.sh's
# header comment -- was scp silently failing on 2 of 19 files because Dropbear
# throttles rapid reconnects. A per-file loop opens one NEW connection per
# file; tar-over-ssh opens exactly one for the whole payload, so there is no
# rapid reconnect for Dropbear to throttle in the first place. This is the
# "single transfer" option PLAN.md section 8 lists as preferred, and is
# stronger than a per-file-loop-with-retry (kinbox's approach) because it
# removes the failure mode instead of just retrying into it.
#
# Why stage-then-swap instead of extracting straight into the live plugin
# directory: a single streamed `tar -xf -` is still only one connection, but
# a connection that drops mid-stream would leave the LIVE directory with some
# files updated and others not -- exactly the "parses but runs mixed
# versions" failure this work package exists to prevent, just with fewer
# opportunities for it. Extracting into a sibling staging directory first,
# verifying the file count landed intact, and only then moving each file into
# place (a same-filesystem rename: effectively instantaneous local metadata
# work, not subject to a dropped network connection) means a failure anywhere
# before the swap leaves the live plugin completely untouched. The swap only
# moves files that are part of THIS deploy, so a device-only file that isn't
# in the checkout (e.g. a config.lua hand-edited on the Kindle, when none
# exists locally) is left alone, matching the old script's behaviour.
#
# NOT VERIFIED ON A REAL DEVICE (no Kindle reachable from this session): that
# busybox tar on this firmware accepts `-C`. It is a long-standing, near-
# universal busybox applet flag and kinbox's own docs describe Kindle
# firmware updates as tar-based, so this is a reasoned choice, not a blind
# guess -- but if the very first real deploy fails at the extraction step,
# the fallback is a per-file loop with retry (see kinbox's `push()`), not
# more tar flags.
TMPTAR="$(mktemp "${TMPDIR:-/tmp}/minfolio-deploy.XXXXXX")" || die "mktemp failed"
trap 'rm -f "$TMPTAR"' EXIT
tar -cf "$TMPTAR" -C "$PLUGIN_LOCAL" $DEPLOY_FILES || die "local tar creation failed"

say "== transferring $DEPLOY_COUNT file(s) as one archive over a single SSH connection =="
STAGE="$PLUGIN_DIR.new"
ssh_k "rm -rf '$STAGE' && mkdir -p '$PLUGIN_DIR' '$STAGE' && tar -xf - -C '$STAGE'" <"$TMPTAR" \
    || die "transfer failed (connection dropped or remote extraction failed) -- live plugin NOT touched, safe to re-run"

ssh_k "cd '$STAGE' && got=\$(ls -1 | wc -l | tr -d ' ')
if [ \"\$got\" != '$DEPLOY_COUNT' ]; then echo \"partial transfer: staged \$got of $DEPLOY_COUNT files\" >&2; exit 1; fi
for f in $DEPLOY_FILES; do mv \"\$f\" '$PLUGIN_DIR'/\"\$f\"; done
rm -rf '$STAGE'
chmod 755 '$PLUGIN_DIR/minfolio_sync.sh'" \
    || die "verified transfer could not be swapped into place -- device may be in a mixed state, re-run deploy immediately"
say "   $DEPLOY_COUNT file(s) live"

# ---- 4. Parse-check on the device ------------------------------------------
# Glob evaluated ON THE DEVICE over whatever was actually deployed, so a
# future module is covered with zero deploy.sh changes -- the same reason
# the local check above is a glob and not a named list.
say "== device parse check =="
ssh_k 'KO=/mnt/us/koreader; cd '"$PLUGIN_DIR"' && bad=0
for f in *.lua; do
    LD_LIBRARY_PATH=$KO/libs:$KO $KO/luajit -e "local fn,e=loadfile(\"$f\"); if not fn then print(\"FAIL \"..\"$f\"..\": \"..tostring(e)); os.exit(1) end" || bad=1
done
if [ $bad -eq 0 ]; then echo "   all OK on device"; else exit 1; fi' \
    || die "device parse check failed"

# ---- 5. Restart and confirm the plugin actually loaded ---------------------
# A clean transfer and a clean parse are necessary but not sufficient: KOReader
# also has to actually load the plugin without erroring during init. Rather
# than inferring success from "nothing above failed", trigger a restart and
# look for the plugin's own load marker in the log.
#
# Restart mechanism: touch the light-restart flag kshell.koplugin polls
# (PLAN.md section 3: "the light-restart path lives in kshell ... must
# degrade when kshell is absent, no dependency"). Touching this file is
# always safe and always succeeds regardless of whether kshell is installed
# to consume it -- if it isn't, this is a no-op flag file kshell auto-expires
# once it IS installed, and everything below just warns instead of confirming.
# This deliberately never kills reader.lua directly (the heavy path, which
# reloads the whole KOReader framework); exit code 85 via this flag is the
# reviewed-safe path in this toolchain (see kindle_koreader_restart notes).
#
# Load assertion: MinfolioPair.trace (main.lua:76) logs through
# logger.info("minfolio trace", event, ...), and Minfolio:init (main.lua:5729)
# fires MinfolioPair.trace("plugin-init", ...) on every load. main.lua's own
# comment at line 72 says this trace exists to leave "lifecycle evidence in
# KOReader's crash log", which is corroborated by two sibling projects in
# this same toolchain (kindle-mirror/AGENTS.md, kinbox's DEPLOY.md) that both
# document logger.info(...) output as landing in /mnt/us/koreader/crash.log.
#
# THIS IS NOT VERIFIED AGAINST A RUNNING MINFOLIO INSTANCE (no Kindle
# reachable from this session) -- it is strong indirect evidence (the
# plugin's own source comment plus two sibling projects' documented
# convention), not a first-hand confirmation. Per the brief for this work
# package, that means this whole section is advisory: it can only warn, it
# can never fail the deploy, and every message says so explicitly.
say "== light restart + load check (best effort; warnings only, never fails the deploy) =="
LOG="/mnt/us/koreader/crash.log"
BEFORE_BYTES="$(ssh_k "wc -c <'$LOG' 2>/dev/null" 2>/dev/null || echo 0)"
# wc -c pads its output with leading whitespace on some platforms (BSD wc
# does; busybox wc may not) -- strip it before validating, or a perfectly
# good byte count gets rejected as "non-numeric" and silently zeroed.
BEFORE_BYTES="$(printf '%s' "$BEFORE_BYTES" | tr -d '[:space:]')"
case "$BEFORE_BYTES" in *[!0-9]* | "") BEFORE_BYTES=0 ;; esac

BEFORE_PID="$(ssh_k "pgrep -f '[.]/luajit ./reader.lua' 2>/dev/null | head -1" 2>/dev/null || true)"
if ! ssh_k "touch /tmp/koreader_restart" 2>/dev/null; then
    say "   WARNING: could not touch the restart flag; restart KOReader manually to verify the load."
else
    i=0
    AFTER_PID=""
    while [ "$i" -lt 15 ]; do
        sleep 2
        i=$((i + 1))
        AFTER_PID="$(ssh_k "pgrep -f '[.]/luajit ./reader.lua' 2>/dev/null | head -1" 2>/dev/null || true)"
        if [ -n "$AFTER_PID" ] && [ "$AFTER_PID" != "$BEFORE_PID" ]; then
            say "   restarted (pid ${BEFORE_PID:-none} -> $AFTER_PID)"
            break
        fi
    done

    if [ -z "$AFTER_PID" ] || [ "$AFTER_PID" = "$BEFORE_PID" ]; then
        say "   WARNING: no restart observed within 30s. Either kshell is not installed to"
        say "   consume the flag, or KOReader was not running. Restart KOReader manually and"
        say "   check $LOG yourself for a fresh 'plugin-init' trace line."
    else
        sleep 3
        MARKER_COUNT="$(ssh_k "tail -c +$((BEFORE_BYTES + 1)) '$LOG' 2>/dev/null | grep -c plugin-init" 2>/dev/null || echo 0)"
        MARKER_COUNT="$(printf '%s' "$MARKER_COUNT" | tr -d '[:space:]')"
        case "$MARKER_COUNT" in *[!0-9]* | "") MARKER_COUNT=0 ;; esac
        if [ "$MARKER_COUNT" -gt 0 ]; then
            say "   plugin load CONFIRMED: found a fresh 'plugin-init' trace marker in $LOG"
        else
            say "   WARNING: restart observed but no fresh 'plugin-init' marker found in $LOG."
            say "   The log path/format is a documented convention, not verified on this"
            say "   device this session -- absence here is a reason to check manually, not"
            say "   proof of a failed load."
        fi
    fi
fi

say "== done =="
