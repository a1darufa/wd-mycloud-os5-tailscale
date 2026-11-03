#!/bin/sh
# preinst.sh <app folder> — run from the OLD version, only on upgrade.
#
# Refreshes the upgrade flag and keeps the binaries being upgraded from as
# the last-known-good fallback, but only if they are what is running right
# now and the daemon is healthy.

. "$(dirname "$0")/lib.sh"

mkdir -p "$TS_HOME"
date '+%Y-%m-%d %H:%M:%S' > "$TS_UPGRADING"

for pid in $(ts_our_pids); do
    case " $(ts_cmdline "$pid") " in
        *" $TS_APP_DIR/bin/tailscaled "*)
            if [ "$(ts_backend_state "$TS_APP_DIR/bin")" = Running ]; then
                ts_save_lkg
                ts_log "saved the running version as last-known-good"
            fi
            ;;
    esac
done
exit 0
