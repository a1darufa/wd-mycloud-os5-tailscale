#!/bin/sh
# probe.sh — shared logger for the apkgprobe test app.
#
# Every lifecycle script sources this file and calls `probe "$@"`. Each call
# appends one block to a log kept outside the app folder, so it survives
# upgrades and uninstall:
#     /mnt/HD/HD_a2/.systemfile/apkgprobe/probe.log
#
# Purpose: learn on the real NAS which scripts WD's app manager runs, in what
# order, with which arguments, from where, and what else is running then
# (tailscaled and twonky tell us the boot order).

PROBE_SCRIPT_DIR=$(dirname "$0")
# Read from apkg.rc so the same scripts serve every probe variant
# (apkgprobe, apkgprobe2, ...) installed side by side.
PROBE_PACKAGE=$(awk '$1 == "Package:" { print $2 }' "$PROBE_SCRIPT_DIR/apkg.rc" 2>/dev/null)
PROBE_LOG_DIR=/mnt/HD/HD_a2/.systemfile/$PROBE_PACKAGE
PROBE_LOG=$PROBE_LOG_DIR/probe.log
PROBE_LOG_MAX_BYTES=1048576
PROBE_APP_DIR=/mnt/HD/HD_a2/Nas_Prog/$PROBE_PACKAGE
PROBE_MARKER=$PROBE_APP_DIR/.probe-marker

probe_rotate_log() {
    [ -f "$PROBE_LOG" ] || return 0
    if [ "$(wc -c < "$PROBE_LOG")" -gt "$PROBE_LOG_MAX_BYTES" ]; then
        mv -f "$PROBE_LOG" "$PROBE_LOG.1"
    fi
}

# PID 1's parent is 0, which has no /proc entry; skip quietly.
probe_cmdline() {
    [ -r "/proc/$1/cmdline" ] && tr '\0' ' ' < "/proc/$1/cmdline"
}

probe_parent_of() {
    awk '/^PPid:/ { print $2 }' "/proc/$1/status" 2>/dev/null
}

# Version of the package this script came from; during an upgrade it tells
# old-version scripts apart from new-version ones.
probe_version() {
    awk '$1 == "Version:" { print $2 }' "$PROBE_SCRIPT_DIR/apkg.rc" 2>/dev/null
}

# The Run App state the app manager stores in the installed apkg.xml; shows
# whether it carries over an upgrade.
probe_enable_flag() {
    sed -n 's/.*<enable>\(.*\)<\/enable>.*/\1/p' "$PROBE_APP_DIR/apkg.xml" 2>/dev/null
}

probe_app_folder_state() {
    if [ ! -d "$PROBE_APP_DIR" ]; then
        echo "absent"
    elif [ -f "$PROBE_MARKER" ]; then
        echo "present, marker: $(cat "$PROBE_MARKER")"
    else
        echo "present, no marker"
    fi
}

probe() {
    [ -n "$PROBE_PACKAGE" ] || return 0
    mkdir -p "$PROBE_LOG_DIR" || return 0
    probe_rotate_log
    parent=$(probe_parent_of $$)
    grandparent=$(probe_parent_of "$parent")
    {
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') $(basename "$0") (version $(probe_version))"
        echo "args:        $*"
        echo "script path: $0"
        echo "cwd:         $(pwd)"
        echo "uid:         $(id -u)   uptime: $(cut -d' ' -f1 /proc/uptime)s"
        echo "parent:      $parent $(probe_cmdline "$parent")"
        echo "grandparent: $grandparent $(probe_cmdline "$grandparent")"
        echo "app folder:  $(probe_app_folder_state)"
        echo "enable flag: $(probe_enable_flag)"
        echo "tailscaled:  $(pidof tailscaled || echo 'not running')"
        echo "twonky:      $(pidof twonkyserver || echo 'not running')"
        echo "env names:   $(env | cut -d= -f1 | sort | tr '\n' ' ')"
    } >> "$PROBE_LOG" 2>&1
}
