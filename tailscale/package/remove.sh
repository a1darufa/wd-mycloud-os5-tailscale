#!/bin/sh
# remove.sh <app folder> — run from the OLD version on upgrade, and on
# uninstall.
#
# The app folder is always deleted, even during an upgrade: otherwise the new
# install.sh would copy over the running bin/tailscaled and fail with "text
# file busy". Deleting only unlinks the file; the running daemon keeps
# working. On uninstall the daemon is stopped too, and the state is kept.

. "$(dirname "$0")/lib.sh"

app_dir=$1

ts_unlink_web

if ts_upgrade_in_progress; then
    ts_log "upgrade: removing the old app folder; tailscaled keeps running"
else
    rm -f "$TS_SHOULD_RUN"
    for pid in $(ts_our_pids); do
        ts_stop_pid "$pid"
    done
    ts_log "uninstalled; state, flags and logs are kept in $TS_HOME"
fi

if [ "$app_dir" = "$TS_APP_DIR" ]; then
    rm -rf "$app_dir"
else
    ts_log "refusing to delete unexpected path: $app_dir"
    exit 1
fi
exit 0
