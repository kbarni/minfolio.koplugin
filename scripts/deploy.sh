#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Deploy Minfolio to the Kindle: copy the plugin, then parse-check it with the
# device's own LuaJIT. Restart KOReader manually.
# Usage: scripts/deploy.sh [ssh-host]
#
# The argument is an ssh(1) host, so a plain `Host kindle` block in
# ~/.ssh/config is all that is required. If the optional kindle-utils resolver
# happens to be installed alongside this checkout it is used instead, which
# also finds a Kindle whose address has changed since the config was written.
# Set KINDLE_TOOLS_DIR to point at it, or KINDLE_NO_RESOLVE=1 to force plain SSH.
set -e
TARGET="${1:-kindle}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
KINDLE_TOOLS_DIR="${KINDLE_TOOLS_DIR:-$DIR/../kindle-utils/kindle-tools}"
RESOLVER="$KINDLE_TOOLS_DIR/kindle-mcp"
PLUGIN_DIR="/mnt/us/koreader/plugins/minfolio.koplugin"

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

DEST="$SSH_TARGET:$PLUGIN_DIR"
echo "Deploying via $TRANSPORT ($DESCRIPTION) ..."
ssh_k "mkdir -p $PLUGIN_DIR"
scp_k "$DIR/minfolio.koplugin/_meta.lua" "$DEST/_meta.lua"
scp_k "$DIR/minfolio.koplugin/main.lua" "$DEST/main.lua"
scp_k "$DIR/minfolio.koplugin/minfolio_sync.lua" "$DEST/minfolio_sync.lua"
scp_k "$DIR/minfolio.koplugin/minfolio_sync.sh" "$DEST/minfolio_sync.sh"
ssh_k "chmod 755 $PLUGIN_DIR/minfolio_sync.sh"
if [ -f "$DIR/minfolio.koplugin/config.lua" ]; then
    scp_k "$DIR/minfolio.koplugin/config.lua" "$DEST/config.lua"
fi

# A Lua syntax error makes KOReader silently skip the whole plugin, so always
# confirm both files load on the device before restarting it.
echo "Parse-checking on device ..."
for lua in main.lua minfolio_sync.lua; do
    ssh_k "KO=/mnt/us/koreader; LD_LIBRARY_PATH=\$KO/libs:\$KO \$KO/luajit -e '
        local f, e = loadfile(\"$PLUGIN_DIR/$lua\")
        if not f then io.stderr:write(e .. \"\n\"); os.exit(1) end
        print(\"PARSE OK: $lua\")'"
done
echo "Deployed. Restart KOReader manually when you are ready."
