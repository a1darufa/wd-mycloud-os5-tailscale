#!/bin/sh
# before_apkg.sh — run by WD's upload step from the NEW package, before any
# other script, on install and upgrade (no arguments, CGI context).
#
# On an upgrade it marks "upgrade in progress", so the old version's stop.sh
# and remove.sh leave tailscaled running: the NAS is reachable only through
# Tailscale. Installing a new build also counts as a deliberate retry of a
# failed cutover.

. "$(dirname "$0")/lib.sh"

if [ -d "$TS_APP_DIR" ]; then
    mkdir -p "$TS_HOME"
    date '+%Y-%m-%d %H:%M:%S' > "$TS_UPGRADING"
    ts_log "upgrade starting; tailscaled stays up until the new version restarts it"
fi

if [ -f "$TS_CUTOVER_FAILED" ]; then
    mv -f "$TS_CUTOVER_FAILED" "$TS_CUTOVER_FAILED.prev"
    ts_log "new build installed; cleared the failed-cutover marker (kept as $TS_CUTOVER_FAILED.prev)"
fi

exit 0
