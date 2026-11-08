#!/bin/sh
# Constants defined here are used by the scripts that source this file.
# shellcheck disable=SC2034
#
# lib.sh — shared by every script of the Tailscale app (sourced; POSIX sh,
# runs under the NAS's busybox).
#
# Design (README.md, docs/os5-app-lifecycle.md):
# - The app folder is replaced on every upgrade, so everything that must
#   survive lives in $TS_HOME on the data volume.
# - WD resets Run App to OFF on every upgrade, so the app keeps its own
#   should-run flag and init.sh restores the daemon at boot.
# - The first start takes over a Tailscale started by hand from
#   $TS_HOOK_DIR (often from twonky's start.sh: the "hook") and switches back
#   to it unless the new daemon proves the NAS is reachable ("cutover").
#   Without one, it starts a new node.
# - The NAS is reachable only through Tailscale: whenever starting fails, the
#   last daemon that might still connect is left running rather than none.
# - The Configure page (web/settings.html) logs the NAS in, changes a few
#   settings, and can disconnect, log out or switch tailnets through ctl.sh,
#   which checks every value again. Those last three can cut a remote NAS
#   off, so the page asks twice; Tailscale SSH and other nodes' routes aren't
#   offered at all.
# - What needs the owner (logged out, login expiring, a version that didn't
#   start, a takeover that switched back) raises a WD alert, which reaches the
#   dashboard's bell icon and the owner's mailbox.

TS_PACKAGE=tailscale
TS_VOLUME=/mnt/HD/HD_a2
TS_APP_DIR=$TS_VOLUME/Nas_Prog/$TS_PACKAGE
TS_HOME=$TS_VOLUME/.systemfile/$TS_PACKAGE
TS_STATE_DIR=$TS_HOME/state
TS_LKG_DIR=$TS_HOME/lkg
TS_LOG_DIR=$TS_HOME/log
TS_SHOULD_RUN=$TS_HOME/should-run
TS_UPGRADING=$TS_HOME/upgrading
TS_CUTOVER_OK=$TS_HOME/cutover-ok
TS_CUTOVER_FAILED=$TS_HOME/cutover-failed
TS_CONFIRM=$TS_HOME/confirm
TS_NODE_IP=$TS_HOME/node-ip
TS_HOOK_CMDLINE=$TS_HOME/hook-cmdline
TS_LOCK=$TS_HOME/lock
TS_KEEPER_LOCK=$TS_HOME/log-keeper.lock
TS_FORWARDING=$TS_HOME/ip-forwarding
TS_SWITCHED_FROM=$TS_HOME/switched-from
TS_SOCKET=/var/run/tailscale/tailscaled.sock

# Dashboard pages: /var/www/apps/<package> is the only place behind the
# dashboard login (CenterType 1). Up to 1.104.2-2 they were in the open
# /var/www/<package>, which is cleaned up.
TS_WEB_DIR=/var/www/apps/$TS_PACKAGE
TS_OLD_WEB_DIR=/var/www/$TS_PACKAGE

# The install this app replaces: binaries and state started by twonky's start.sh.
TS_HOOK_DIR=$TS_VOLUME/tailscale
TS_HOOK_STATE_DIR=$TS_HOOK_DIR/state

# Timings in seconds. The environment overrides exist only so tests run fast;
# WD's app manager passes none of these.
TS_START_TIMEOUT=${TS_START_TIMEOUT:-90}
TS_PROOF_TIMEOUT=${TS_PROOF_TIMEOUT:-600}
TS_STOP_TIMEOUT=${TS_STOP_TIMEOUT:-15}
TS_POLL_INTERVAL=${TS_POLL_INTERVAL:-2}
TS_KEEPER_INTERVAL=${TS_KEEPER_INTERVAL:-60}
TS_UPGRADE_FLAG_MAX_AGE=900
TS_LOG_MAX_BYTES=1048576
TS_PROOF_MIN_RX_BYTES=1024

# Where the kernel's forwarding switches are; tests point this elsewhere.
TS_PROC_SYS=${TS_PROC_SYS:-/proc/sys}

# WD's app manager, as the dashboard's Run App switch calls it (Apache, for
# local requests only), and the list of installed apps the dashboard page
# reads. WD rebuilds that list from each app's apkg.xml.
TS_WD_APPS_CGI=http://127.0.0.1:8000/cgi-bin/apkg_mgr.cgi
TS_WD_APP_LIST=${TS_WD_APP_LIST:-/var/www/xml/apkg_all.xml}

# WD's installer records its result here (1: installed), then copies it into
# the install record that the dashboard's "Updating" dialog polls.
TS_WD_INSTALL_RESULT=/tmp/upload_apkg_status
TS_WD_INSTALL_RECORD=/var/www/xml/apkg_state.xml

# WD's alerts (the dashboard's bell icon, and e-mail when alert e-mails are
# set up). An app can only use code 1501, which WD titles "App Update
# Available" and opens with a fixed sentence about a new app version; the
# app's text follows it. Each kind of alert goes out at most once a day; the
# files in TS_ALERT_DIR say when it last did.
TS_WD_ALERT_CODE=1501
TS_ALERT_DIR=$TS_HOME/alerts
TS_ALERT_INTERVAL=86400
# Warn this many days before the node's login (its key) expires.
TS_EXPIRY_WARN_DAYS=7
# The log keeper checks the login and the NAT prefs every this many rounds.
TS_CHECK_ROUNDS=${TS_CHECK_ROUNDS:-10}

# How long to wait at most for WD's installer to exit; how long to let a
# boot settle, and how far apart to check, before asking WD to show Run App ON.
TS_WD_INSTALL_TIMEOUT=${TS_WD_INSTALL_TIMEOUT:-120}
TS_BOOT_DASHBOARD_DELAY=${TS_BOOT_DASHBOARD_DELAY:-20}
TS_DASHBOARD_DELAY=${TS_DASHBOARD_DELAY:-5}

TS_LOG_TAG=${TS_LOG_TAG:-$(basename "$0")}

# --- logging ---------------------------------------------------------------

# Logs that the writer reopens each time: rotate by renaming.
ts_rotate_if_large() {
    [ -f "$1" ] || return 0
    [ "$(wc -c < "$1")" -gt "$TS_LOG_MAX_BYTES" ] || return 0
    mv -f "$1" "$1.1"
}

# Logs held open by a running process (tailscaled appends with >>): rotate by
# copying and truncating, because a rename would keep the process writing to
# the old file.
ts_truncate_if_large() {
    [ -f "$1" ] || return 0
    [ "$(wc -c < "$1")" -gt "$TS_LOG_MAX_BYTES" ] || return 0
    cp -f "$1" "$1.1" && : > "$1"
}

ts_log() {
    mkdir -p "$TS_LOG_DIR" 2> /dev/null || return 0
    ts_rotate_if_large "$TS_LOG_DIR/app.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${TS_LOG_TAG}[$$]: $*" >> "$TS_LOG_DIR/app.log"
}

# --- WD alerts ---------------------------------------------------------------

# Raise a WD alert of <kind> (a file name, such as logged-out) saying
# "Tailscale: <text>", unless that kind went out within TS_ALERT_INTERVAL.
# WD drops a text longer than about 124 characters or holding < > &, and
# splits it at commas, so those go. The leading space keeps it apart from
# WD's sentence, which ends in a full stop.
ts_alert() {
    command -v fireAlert > /dev/null 2>&1 || return 0
    mkdir -p "$TS_ALERT_DIR"
    ts_alert_stamp=$TS_ALERT_DIR/$1
    if [ -f "$ts_alert_stamp" ]; then
        ts_alert_age=$(($(date +%s) - $(stat -c %Y "$ts_alert_stamp")))
        [ "$ts_alert_age" -ge "$TS_ALERT_INTERVAL" ] || return 0
    fi
    ts_alert_text=$(printf ' Tailscale: %s' "$2" | tr -d '<>&,\n' | cut -c 1-120)
    ts_clear_alerts
    if fireAlert -a "$TS_WD_ALERT_CODE" -p "$ts_alert_text" -f > /dev/null 2>&1; then
        touch "$ts_alert_stamp"
        ts_log "WD alert sent:$ts_alert_text"
    else
        ts_log "WD alert couldn't be sent:$ts_alert_text"
    fi
}

# Remove this app's earlier alerts, so the newest text shows: WD counts a
# repeat of the same code instead of showing it. Other apps' update alerts
# share the code, so only those holding " Tailscale: " go.
ts_clear_alerts() {
    for ts_seq in $(fireAlert -g 2> /dev/null | awk -v code="$TS_WD_ALERT_CODE" '
        /^---->/ { this_code = ""; seq = "" }
        /^alertCode = / { this_code = $3 }
        /^alertSeqNum = / { seq = $3 }
        /^alertDesc:/ && this_code == code && index($0, " Tailscale: ") { print seq }'); do
        fireAlert -s "$ts_seq" -r > /dev/null 2>&1
    done
}

# --- the kernel's NAT ----------------------------------------------------------

# The EX2 Ultra's kernel has no iptables nat table, so tailscaled can't set up
# its firewall and NAT rules, and says so in a health warning. Without one,
# it's told not to try: forwarded traffic goes out unchanged, as it did
# anyway, so routes and the exit node need the router to send replies for
# 100.64.0.0/10 back through the NAS.
ts_kernel_has_nat() {
    iptables -t nat -L -n > /dev/null 2>&1
}

# The flags that say so, for "tailscale up", "set" and "login"; none if the
# kernel has NAT. Two words without spaces in them, for word splitting.
ts_nat_flags() {
    ts_kernel_has_nat || echo "--netfilter-mode=off --snat-subnet-routes=false"
}

# --- processes ---------------------------------------------------------------

ts_cmdline() {
    tr '\0' ' ' 2> /dev/null < "/proc/$1/cmdline"
}

# Path of the tailscaled binary process <pid> runs: the first argument, or
# the second when a shell runs it as a script (test stubs).
ts_daemon_path() {
    tr '\0' '\n' 2> /dev/null < "/proc/$1/cmdline" \
        | awk 'NR <= 2 && /(^|\/)tailscaled$/ { print; found = 1; exit } END { exit !found }'
}

# The daemon path and its arguments, without an interpreter in front (a stub
# script shows up as "/bin/sh .../tailscaled ..."). Re-running this keeps the
# process named tailscaled, which the twonky hook's pidof guard relies on.
ts_daemon_cmdline() {
    tr '\0' '\n' 2> /dev/null < "/proc/$1/cmdline" \
        | awk 'found || /(^|\/)tailscaled$/ { found = 1; printf "%s ", $0 }'
}

# A daemon is "ours" when it runs on this app's state folder, whichever
# binary it uses. Anything else (the twonky hook's daemon) is foreign.
ts_is_ours() {
    case " $(ts_cmdline "$1") " in
        *" --statedir=$TS_STATE_DIR "*) return 0 ;;
    esac
    return 1
}

ts_our_pids() {
    for ts_pid in $(pidof tailscaled); do
        ts_is_ours "$ts_pid" && echo "$ts_pid"
    done
}

ts_foreign_pids() {
    for ts_pid in $(pidof tailscaled); do
        ts_is_ours "$ts_pid" || echo "$ts_pid"
    done
}

# SIGTERM, then SIGKILL if <pid> is still alive after TS_STOP_TIMEOUT.
ts_stop_pid() {
    kill "$1" 2> /dev/null || return 0
    ts_waited=0
    while kill -0 "$1" 2> /dev/null; do
        if [ "$ts_waited" -ge "$TS_STOP_TIMEOUT" ]; then
            ts_log "pid $1 ignored SIGTERM for ${TS_STOP_TIMEOUT}s; sending SIGKILL"
            kill -9 "$1" 2> /dev/null
            return 0
        fi
        sleep 1
        ts_waited=$((ts_waited + 1))
    done
}

# Set the kernel's forwarding switches listed in <file> (one per line, such
# as net/ipv4/ip_forward) to <value>, 1 or 0.
ts_write_forwarding() {
    [ -f "$2" ] || return 0
    while read -r ts_switch; do
        case $ts_switch in
            net/ipv4/ip_forward | net/ipv6/conf/all/forwarding) ;;
            *) continue ;;
        esac
        if ! { echo "$1" > "$TS_PROC_SYS/$ts_switch"; } 2> /dev/null; then
            ts_log "couldn't set $ts_switch to $1; subnet routes and the exit node need it on"
        fi
    done < "$2"
}

# Subnet routes and an exit node need the kernel to forward packets. The
# switches reset at every boot, so each daemon start turns on the ones listed
# in $TS_FORWARDING, which the Configure page writes.
ts_apply_forwarding() {
    ts_write_forwarding 1 "$TS_FORWARDING"
}

# Start tailscaled from <bin dir> on this app's state and print its PID.
# The double fork reparents it to init, so it outlives the calling script and
# never lingers as a zombie of it; fd 9 (the app lock) is not inherited.
ts_spawn_daemon() {
    mkdir -p "$TS_LOG_DIR" "$(dirname "$TS_SOCKET")"
    ts_rotate_if_large "$TS_LOG_DIR/tailscaled.log"
    ts_apply_forwarding
    (
        nohup "$1/tailscaled" \
            --state="$TS_STATE_DIR/tailscaled.state" \
            --statedir="$TS_STATE_DIR" \
            --socket="$TS_SOCKET" \
            >> "$TS_LOG_DIR/tailscaled.log" 2>&1 < /dev/null 9>&- &
        echo $!
    )
}

# Run "ctl.sh <command>" detached, so neither the web UI nor WD's app manager
# waits for it.
ts_spawn_ctl() {
    mkdir -p "$TS_LOG_DIR"
    (nohup sh "$TS_APP_DIR/ctl.sh" "$1" >> "$TS_LOG_DIR/app.log" 2>&1 < /dev/null 9>&- &)
}

ts_spawn_log_keeper() {
    ts_spawn_ctl log-keeper
}

# --- talking to a daemon -------------------------------------------------------

# <bin dir> is the folder whose tailscale CLI matches the daemon being asked.
ts_status_json() {
    "$1/tailscale" --socket="$TS_SOCKET" status --json 2> /dev/null
}

ts_backend_state() {
    ts_status_json "$1" | sed -n 's/^ *"BackendState": *"\([^"]*\)".*/\1/p' | head -n 1
}

ts_node_ip() {
    "$1/tailscale" --socket="$TS_SOCKET" ip -4 2> /dev/null | head -n 1
}

# The folder whose tailscale CLI matches this app's running daemon, which may
# run from lkg/; this version's bin/ if none runs.
ts_cli_dir() {
    ts_cli_pid=$(ts_our_pids | head -n 1)
    if [ -n "$ts_cli_pid" ] && ts_cli_path=$(ts_daemon_path "$ts_cli_pid"); then
        dirname "$ts_cli_path"
    else
        echo "$TS_APP_DIR/bin"
    fi
}

# Total bytes received from all peers; growth means someone reaches us.
ts_rx_bytes() {
    ts_status_json "$1" | sed -n 's/.*"RxBytes": *\([0-9]*\).*/\1/p' | awk '{ s += $1 } END { print s + 0 }'
}

# True if no IP was recorded at cutover, or the node still has it.
ts_ip_as_recorded() {
    [ -s "$TS_NODE_IP" ] || return 0
    [ "$(ts_node_ip "$1")" = "$(cat "$TS_NODE_IP")" ]
}

# Wait for daemon <pid>, started from <bin dir>, to reach <goal>:
#   running  BackendState is Running and the node keeps its recorded IP
#   alive    it answers on its socket (it may still be connecting)
# Returns 0 when reached, 1 on timeout, 2 if the process died.
ts_await() {
    ts_await_pid=$1
    ts_await_dir=$2
    ts_await_goal=$3
    ts_waited=0
    while [ "$ts_waited" -lt "$TS_START_TIMEOUT" ]; do
        kill -0 "$ts_await_pid" 2> /dev/null || return 2
        case "$ts_await_goal" in
            running)
                [ "$(ts_backend_state "$ts_await_dir")" = Running ] \
                    && ts_ip_as_recorded "$ts_await_dir" && return 0
                ;;
            alive)
                ts_status_json "$ts_await_dir" > /dev/null && return 0
                ;;
        esac
        sleep "$TS_POLL_INTERVAL"
        ts_waited=$((ts_waited + TS_POLL_INTERVAL))
    done
    return 1
}

# --- starting with fallbacks ---------------------------------------------------

# Start the daemon on this app's state, trying in order: this version's
# binaries, the last-known-good copy, then the hook's binaries as a last
# resort. A candidate that misses <goal> (see ts_await) is stopped before the
# next is tried, except the last, which is left running if it is alive.
# Returns 0 if <goal> was reached.
ts_launch_best() {
    ts_launch_goal=$1
    ts_candidates=""
    for ts_dir in "$TS_APP_DIR/bin" "$TS_LKG_DIR" "$TS_HOOK_DIR"; do
        if [ -x "$ts_dir/tailscaled" ] && [ -x "$ts_dir/tailscale" ]; then
            ts_candidates="$ts_candidates $ts_dir"
        fi
    done
    ts_last_candidate=${ts_candidates##* }

    for ts_dir in $ts_candidates; do
        ts_launch_pid=$(ts_spawn_daemon "$ts_dir")
        ts_log "started tailscaled from $ts_dir (pid $ts_launch_pid); waiting until $ts_launch_goal"
        ts_await "$ts_launch_pid" "$ts_dir" "$ts_launch_goal"
        case $? in
            0)
                ts_log "tailscaled from $ts_dir is $ts_launch_goal"
                if [ "$ts_dir" != "$TS_APP_DIR/bin" ]; then
                    ts_alert fallback "this version didn't start or connect. An earlier version runs instead; see the app's log."
                fi
                ts_spawn_log_keeper
                return 0
                ;;
            2)
                ts_log "tailscaled from $ts_dir exited"
                ;;
            *)
                ts_log "tailscaled from $ts_dir is not $ts_launch_goal after ${TS_START_TIMEOUT}s"
                if [ "$ts_dir" = "$ts_last_candidate" ]; then
                    ts_log "no candidates left; keeping it running in case it connects later"
                    ts_alert start "no version reached the tailnet after starting. It keeps trying; see the app's log."
                    ts_spawn_log_keeper
                    return 1
                fi
                ts_stop_pid "$ts_launch_pid"
                ;;
        esac
    done
    ts_log "no tailscaled could be started"
    ts_alert start "tailscaled couldn't be started at all. The NAS is off its tailnet; see the app's log."
    return 1
}

# --- flags and WD state --------------------------------------------------------

# "upgrading" counts only while fresh, so a failed upload can never leave the
# app unable to stop its daemon.
ts_upgrade_in_progress() {
    [ -f "$TS_UPGRADING" ] || return 1
    ts_flag_age=$(($(date +%s) - $(stat -c %Y "$TS_UPGRADING")))
    [ "$ts_flag_age" -lt "$TS_UPGRADE_FLAG_MAX_AGE" ]
}

# WD's Run App state, as stored in the installed apkg.xml.
ts_wd_enabled() {
    [ "$(sed -n 's/.*<enable>\(.*\)<\/enable>.*/\1/p' "$TS_APP_DIR/apkg.xml" 2> /dev/null)" = 1 ]
}

# Store Run App ON the way WD itself does, in the installed apkg.xml.
ts_set_wd_enabled() {
    sed -i 's#<enable>0</enable>#<enable>1</enable>#' "$TS_APP_DIR/apkg.xml"
}

# Whether the dashboard's app list shows Run App ON. Without that list, the
# stored switch is all there is.
ts_dashboard_shows_on() {
    if [ ! -f "$TS_WD_APP_LIST" ]; then
        ts_wd_enabled
        return
    fi
    ts_listed=$(awk -v name="<name>$TS_PACKAGE</name>" '
        index($0, name) { found = 1 }
        found && /<enable>/ { gsub(/[^0-9]/, ""); print; exit }' "$TS_WD_APP_LIST")
    [ "$ts_listed" = 1 ]
}

# WD's installer, upload_apkg, runs a whole install or upgrade, init.sh last,
# and stores the new package's apkg.xml along the way. Wait until it exits.
ts_wait_for_wd_installer() {
    ts_waited=0
    while pidof upload_apkg > /dev/null 2>&1 && [ "$ts_waited" -lt "$TS_WD_INSTALL_TIMEOUT" ]; do
        sleep 1
        ts_waited=$((ts_waited + 1))
    done
}

# Whether WD's installer recorded "installed", but the dialog's record for
# this app still says 100 (installing): the copy stayed behind, and the
# dialog would wait for good.
ts_wd_dialog_stuck() {
    [ "$(cat "$TS_WD_INSTALL_RESULT" 2> /dev/null)" = 1 ] \
        && grep -q "<name>$TS_PACKAGE</name>" "$TS_WD_INSTALL_RECORD" 2> /dev/null \
        && grep -q '<install_status>100</install_status>' "$TS_WD_INSTALL_RECORD" 2> /dev/null
}

# Give the dialog WD's own result, as WD's copy would have.
ts_finish_wd_dialog() {
    sed -i 's#<install_status>100</install_status>#<install_status>1</install_status>#' "$TS_WD_INSTALL_RECORD"
}

# Copy this version's binaries to lkg/. Written to a temporary name and
# renamed, so a running lkg binary is never overwritten in place.
ts_save_lkg() {
    mkdir -p "$TS_LKG_DIR"
    for ts_binary in tailscaled tailscale; do
        cp -f "$TS_APP_DIR/bin/$ts_binary" "$TS_LKG_DIR/$ts_binary.new" \
            && mv -f "$TS_LKG_DIR/$ts_binary.new" "$TS_LKG_DIR/$ts_binary"
    done
}

# Hold the app lock for the rest of the calling script if it's free; return
# 1 if a start, restart or cutover holds it.
ts_try_lock() {
    mkdir -p "$TS_HOME"
    exec 9> "$TS_LOCK"
    flock -n 9
}

# Hold the app lock for the rest of the calling script, or exit quietly if
# another start, restart or cutover holds it.
ts_take_lock_or_exit() {
    mkdir -p "$TS_HOME"
    exec 9> "$TS_LOCK"
    if ! flock -n 9; then
        ts_log "another operation holds the lock; nothing to do"
        exit 0
    fi
}

ts_link_web() {
    rm -rf "$TS_OLD_WEB_DIR"
    mkdir -p "$TS_WEB_DIR"
    ln -sf "$TS_APP_DIR"/web/* "$TS_WEB_DIR"/
}

ts_unlink_web() {
    rm -rf "$TS_WEB_DIR" "$TS_OLD_WEB_DIR"
}

# --- checking values ---------------------------------------------------------
# The Configure page checks these too; ctl.sh checks again before using them.

# Empty (use the NAS's own name) or a DNS label: letters, digits, dashes.
ts_valid_hostname() {
    case $1 in
        -* | *- | *[!A-Za-z0-9-]*) return 1 ;;
    esac
    [ "${#1}" -le 63 ]
}

# Empty, or comma-separated IPv4/IPv6 prefixes; the CLI checks them fully.
ts_valid_routes() {
    case $1 in
        *[!0-9A-Fa-f:./,]*) return 1 ;;
    esac
    [ "${#1}" -le 1024 ]
}

ts_valid_bool() {
    [ "$1" = true ] || [ "$1" = false ]
}

# A key from the admin console, optionally with ?options (OAuth secrets).
ts_valid_auth_key() {
    case $1 in
        tskey-*) ;;
        *) return 1 ;;
    esac
    case $1 in
        *[!A-Za-z0-9_?=\&.-]*) return 1 ;;
    esac
    [ "${#1}" -le 512 ]
}
