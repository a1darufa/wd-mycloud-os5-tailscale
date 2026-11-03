#!/bin/sh
# start.sh <app folder> — Run App ON, and at boot when Run App is ON.
# WD already runs it in the background; the work happens in ctl.sh.

. "$(dirname "$0")/lib.sh"

mkdir -p "$TS_HOME"
date '+%Y-%m-%d %H:%M:%S' > "$TS_SHOULD_RUN"

if [ -f "$TS_CUTOVER_OK" ]; then
    ts_spawn_ctl start
elif [ -f "$TS_CUTOVER_FAILED" ]; then
    ts_log "not taking over: the last cutover failed ($(cat "$TS_CUTOVER_FAILED")). Install a new build, or delete $TS_CUTOVER_FAILED, to retry."
else
    ts_log "first start: taking over the hand-started Tailscale, or starting a new node"
    ts_spawn_ctl cutover
fi
exit 0
