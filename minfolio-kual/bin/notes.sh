#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
set -eu

echo notes > /tmp/minfolio_launch

# KUAL's document/action runner pipes a script's stdout through FBInk. KOReader
# is long-lived, so `exec` would keep that second framebuffer client alive for
# the whole session and contend with KOReader's own display updates. Detach all
# standard streams before returning to KUAL so its FBInk helper can exit.
LOG=/mnt/us/.minfolio/koreader-launch.log
mkdir -p /mnt/us/.minfolio
# The whole KOReader session writes here, so retain one previous generation and
# start fresh past 1 MB instead of letting the log grow without bound.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
    mv "$LOG" "$LOG.old"
fi
nohup /mnt/us/koreader/koreader.sh --kual --framework_stop \
    </dev/null >>"$LOG" 2>&1 &
