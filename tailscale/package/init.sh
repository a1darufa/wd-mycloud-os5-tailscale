#!/bin/sh
# init.sh <app folder> — runs after install and upgrade, and at every boot
# for this app whether Run App is ON or OFF.
#
# Daemon steps only run after a successful first start (a cutover or a new
# node), so init.sh never touches a hand-started daemon.

. "$(dirname "$0")/lib.sh"

mkdir -p "$TS_LOG_DIR" "$(dirname "$TS_SOCKET")"
ts_link_web

if ts_upgrade_in_progress; then
    rm -f "$TS_UPGRADING"
    if [ -f "$TS_CUTOVER_OK" ] && [ -f "$TS_SHOULD_RUN" ]; then
        ts_log "after upgrade: moving tailscaled to this version"
        ts_spawn_ctl upgrade-restart
        ts_spawn_ctl restore-run-app
    else
        ts_log "after upgrade: no daemon to move (not cut over yet, or Run App was OFF)"
    fi
elif [ -f "$TS_CUTOVER_OK" ] && [ -f "$TS_SHOULD_RUN" ] && ! ts_wd_enabled; then
    # An upgrade left Run App OFF (before 1.104.4-3, or WD dropped the
    # restore), so WD won't call start.sh and the app's own flag decides.
    # With Run App ON, start.sh follows instead.
    ts_log "boot: Run App shows OFF after an upgrade, but should-run is set; starting tailscaled"
    ts_spawn_ctl start
    ts_spawn_ctl dashboard-on
fi
exit 0
