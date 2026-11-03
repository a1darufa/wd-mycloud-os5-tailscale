#!/bin/sh
# stop.sh <app folder> — Run App OFF; also right before start.sh at boot,
# twice during shutdown, and before an upgrade or uninstall of a running app.
#
# During an upgrade it does nothing: the old daemon keeps the NAS reachable
# until the new version's init.sh restarts it.

. "$(dirname "$0")/lib.sh"

if ts_upgrade_in_progress; then
    ts_log "upgrade in progress; leaving tailscaled running"
    exit 0
fi

rm -f "$TS_SHOULD_RUN"
pids=$(ts_our_pids)
if [ -z "$pids" ]; then
    ts_log "no tailscaled of this app running; nothing to stop"
    exit 0
fi

ts_log "stopping tailscaled (pid $pids)"
for pid in $pids; do
    ts_stop_pid "$pid"
done
exit 0
