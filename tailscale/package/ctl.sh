#!/bin/sh
# ctl.sh <command> — the app's long-running operations. The lifecycle scripts
# run it detached (ts_spawn_ctl), so neither the web UI nor WD's app manager
# waits for it.
#
#   start            start the daemon unless one is running (boot, Run App ON)
#   upgrade-restart  move the running daemon to this version's binary
#   cutover          first start: take over a hand-started Tailscale, with
#                    revert, or start a new node if there is none
#   log-keeper       cap tailscaled.log while the daemon runs
#   restore-run-app  after an upgrade, put WD's Run App switch back ON, and
#                    end WD's "Updating" dialog if it's stuck
#   dashboard-on     at boot, ask WD to show Run App ON if should-run says so
#
# The Configure page's api.php runs these, with key=value lines on stdin:
#
#   web-status       the app's state and the daemon's status and prefs, as
#                    one JSON object (api.php passes on only what it needs)
#   web-login        log in: with auth_key=..., at once; without, start an
#                    interactive login whose link web-status shows. switch=1
#                    moves a logged-in node to another tailnet.
#   web-switch-back  return to the tailnet the last switch left
#   web-set          hostname=, routes=, exit_node=, auto_update=
#   web-disconnect   "tailscale down": offline, still logged in
#   web-connect      "tailscale up" again, with hostname=, routes=, exit_node=
#   web-logout       "tailscale logout": leave the tailnet
#
# Their output is key=value lines: "ok=1", or "error=<message>" with exit
# status 1. Messages never hold line breaks or the auth key.

. "$(dirname "$0")/lib.sh"
TS_LOG_TAG="ctl $1"

cmd_start() {
    if [ -n "$(ts_our_pids)" ]; then
        ts_log "tailscaled already running (pid $(ts_our_pids))"
        return 0
    fi
    foreign=$(ts_foreign_pids)
    if [ -n "$foreign" ]; then
        ts_log "a tailscaled this app didn't start is running (pid $foreign); leaving it alone"
        return 0
    fi
    ts_launch_best alive
}

cmd_upgrade_restart() {
    old_pids=$(ts_our_pids)
    if [ -z "$old_pids" ]; then
        if [ -n "$(ts_foreign_pids)" ]; then
            ts_log "only a tailscaled this app didn't start is running; leaving it alone"
            return 0
        fi
        ts_log "no tailscaled running; starting this version"
        ts_launch_best running
        return
    fi
    # A connected daemon must come back Running on the new binary, or it falls
    # back to the last-known-good one. One that wasn't connected (disconnected
    # on purpose, logged out, or never logged in) can't get there; for it,
    # answering on its socket is enough.
    old_state=$(ts_backend_state "$(ts_cli_dir)")
    goal=running
    [ "$old_state" = Running ] || goal=alive
    ts_log "moving tailscaled (pid $old_pids, ${old_state:-no answer}) to this version's binary"
    for pid in $old_pids; do
        ts_stop_pid "$pid"
    done
    ts_launch_best "$goal"
}

# Wait for proof that the NAS is reachable through daemon <pid>: the confirm
# file (created over SSH through the new daemon) or traffic received from a
# peer, such as an open dashboard tab polling the NAS.
await_reachability() {
    rm -f "$TS_CONFIRM"
    rx_start=$(ts_rx_bytes "$TS_APP_DIR/bin")
    waited=0
    while [ "$waited" -lt "$TS_PROOF_TIMEOUT" ]; do
        kill -0 "$1" 2> /dev/null || { ts_log "new tailscaled exited while waiting for proof"; return 1; }
        if [ ! -f "$TS_SHOULD_RUN" ]; then
            ts_log "Run App was switched OFF during the cutover"
            return 1
        fi
        if [ -f "$TS_CONFIRM" ]; then
            ts_log "reachability confirmed through $TS_CONFIRM"
            return 0
        fi
        rx_gain=$(($(ts_rx_bytes "$TS_APP_DIR/bin") - rx_start))
        if [ "$rx_gain" -ge "$TS_PROOF_MIN_RX_BYTES" ]; then
            ts_log "reachability shown by peer traffic (+$rx_gain bytes received)"
            return 0
        fi
        sleep "$TS_POLL_INTERVAL"
        waited=$((waited + TS_POLL_INTERVAL))
    done
    ts_log "no proof of reachability within ${TS_PROOF_TIMEOUT}s"
    return 1
}

# Put the twonky-hook daemon back exactly as it ran before, record why, and
# check that it comes up.
revert_cutover() {
    new_pid=$1
    reason=$2
    [ -n "$new_pid" ] && ts_stop_pid "$new_pid"
    hook_cmd=$(cat "$TS_HOOK_CMDLINE")
    ts_log "cutover failed: $reason"
    ts_log "restarting the hook daemon: $hook_cmd"
    # The recorded command line is split on purpose: it holds the binary and
    # its flags, all paths without spaces.
    # shellcheck disable=SC2086
    (nohup $hook_cmd >> "$TS_HOOK_DIR/tailscaled.log" 2>&1 < /dev/null 9>&- &)
    echo "$(date '+%Y-%m-%d %H:%M:%S') $reason" > "$TS_CUTOVER_FAILED"

    sleep 1   # let the detached start reach exec before looking it up
    hook_pid=$(pidof tailscaled | awk '{ print $1 }')
    if [ -n "$hook_pid" ] && ts_await "$hook_pid" "$TS_HOOK_DIR" running; then
        ts_log "hook daemon is Running again (pid $hook_pid)"
    else
        ts_log "hook daemon not Running yet after ${TS_START_TIMEOUT}s; it keeps trying on its own"
    fi
}

# No earlier Tailscale on this NAS: start a new node. There is no connection
# to protect yet, so no proof is needed; the node stays logged out until
# someone logs it in on the Configure page (or runs "tailscale up").
start_new_node() {
    ts_log "no earlier Tailscale at $TS_HOOK_DIR to take over; starting a new node"
    # An address recorded by an earlier takeover attempt isn't this node's.
    rm -f "$TS_NODE_IP"
    if ! ts_launch_best alive; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') a new node's tailscaled didn't start" > "$TS_CUTOVER_FAILED"
        return 1
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$TS_CUTOVER_OK"
    ts_save_lkg
    ts_log "new node started; log it in once on the Configure page, or over SSH: $TS_APP_DIR/bin/tailscale up"
}

cmd_cutover() {
    if [ -f "$TS_CUTOVER_OK" ]; then
        ts_log "cutover already done"
        cmd_start
        return
    fi
    if [ ! -f "$TS_HOOK_STATE_DIR/tailscaled.state" ]; then
        foreign=$(ts_foreign_pids)
        if [ -n "$foreign" ]; then
            # Started some other way (Entware, Docker, a different folder):
            # this app can't take it over, and a second daemon would fight it.
            ts_log "a tailscaled this app didn't start is running (pid $foreign), with no state at $TS_HOOK_STATE_DIR to take over; not starting"
            echo "$(date '+%Y-%m-%d %H:%M:%S') another tailscaled runs (pid $foreign); stop it first" > "$TS_CUTOVER_FAILED"
            return 1
        fi
        start_new_node
        return
    fi

    # 1. Record how the hook daemon runs, so a failure can restore it exactly.
    hook_pid=$(ts_foreign_pids | head -n 1)
    if [ -n "$hook_pid" ]; then
        ts_daemon_cmdline "$hook_pid" > "$TS_HOOK_CMDLINE"
        hook_bin_dir=$(dirname "$(ts_daemon_path "$hook_pid")")
        ts_node_ip "$hook_bin_dir" > "$TS_NODE_IP"
        ts_log "hook daemon: pid $hook_pid, IP $(cat "$TS_NODE_IP"), command: $(cat "$TS_HOOK_CMDLINE")"
    else
        echo "$TS_HOOK_DIR/tailscaled --state=$TS_HOOK_STATE_DIR/tailscaled.state --statedir=$TS_HOOK_STATE_DIR" \
            > "$TS_HOOK_CMDLINE"
        rm -f "$TS_NODE_IP"
        ts_log "no hook daemon running; a failure will start: $(cat "$TS_HOOK_CMDLINE")"
    fi

    # 2. Stop it, then 3. copy its state: copying after the stop captures the
    # latest state, and the original is never modified.
    [ -n "$hook_pid" ] && ts_stop_pid "$hook_pid"
    rm -rf "$TS_STATE_DIR.prev"
    [ -d "$TS_STATE_DIR" ] && mv "$TS_STATE_DIR" "$TS_STATE_DIR.prev"
    if ! cp -a "$TS_HOOK_STATE_DIR" "$TS_STATE_DIR"; then
        revert_cutover "" "copying $TS_HOOK_STATE_DIR failed"
        return 1
    fi
    ts_log "copied the hook's state to $TS_STATE_DIR"

    # 4. The new daemon must reach Running with the same IP.
    new_pid=$(ts_spawn_daemon "$TS_APP_DIR/bin")
    ts_log "started the new tailscaled (pid $new_pid)"
    if ! ts_await "$new_pid" "$TS_APP_DIR/bin" running; then
        revert_cutover "$new_pid" "the new tailscaled didn't reach Running with the same IP within ${TS_START_TIMEOUT}s"
        return 1
    fi

    # 5. And someone must actually be able to reach the NAS through it.
    ts_log "new tailscaled is Running; waiting up to ${TS_PROOF_TIMEOUT}s for proof of reachability"
    if ! await_reachability "$new_pid"; then
        revert_cutover "$new_pid" "no proof that the NAS is reachable through the new tailscaled"
        return 1
    fi

    # 6. Done: remember it, and keep these binaries as the known-good fallback.
    date '+%Y-%m-%d %H:%M:%S' > "$TS_CUTOVER_OK"
    ts_save_lkg
    rm -f "$TS_CONFIRM"
    ts_log "cutover complete; remove the old start lines (for example from twonky's start.sh) by hand"
    ts_spawn_log_keeper
}

# WD's re-install stores the new package's apkg.xml, which says Run App OFF,
# although init.sh moves tailscaled to the new version: should-run kept the
# old state through the upgrade. Once WD's installer has exited, store the
# switch the way it was. The dashboard page rebuilds its app list from
# apkg.xml when it loads, so the page shown after "App installed" already
# says ON.
#
# WD's "Updating" dialog sometimes never hears that the installer finished;
# then it gets WD's result from here.
cmd_restore_run_app() {
    ts_wait_for_wd_installer
    if [ ! -f "$TS_SHOULD_RUN" ]; then
        ts_log "Run App was switched OFF meanwhile; leaving it OFF"
    elif ! ts_wd_enabled; then
        ts_set_wd_enabled
        ts_log "after upgrade: Run App back ON, as it was before"
    fi
    # Only now, so the page that the dialog's OK reloads shows Run App ON.
    if ts_wd_dialog_stuck; then
        ts_finish_wd_dialog
        ts_log "WD's installer had finished, but its Updating dialog still said installing; passed WD's result on"
    fi
    if [ -f "$TS_SHOULD_RUN" ]; then
        make_dashboard_agree
    fi
}

# A boot found should-run set but Run App OFF (an upgrade before 1.104.4-3
# left it so). Let the boot settle first.
cmd_dashboard_on() {
    sleep "$TS_BOOT_DASHBOARD_DELAY"
    make_dashboard_agree
}

# Until the dashboard's app list shows Run App ON, ask WD for it the way the
# dashboard's own switch does; WD then runs start.sh, which finds the daemon
# running, or an upgrade-restart holding the lock, and leaves it alone. WD
# drops such a request while it's busy, so check and retry.
make_dashboard_agree() {
    for attempt in 1 2 3; do
        sleep "$TS_DASHBOARD_DELAY"
        if [ ! -f "$TS_SHOULD_RUN" ]; then
            ts_log "Run App was switched OFF meanwhile; leaving it OFF"
            return 0
        fi
        if ts_dashboard_shows_on; then
            ts_log "Run App shows ON in the dashboard again"
            return 0
        fi
        ts_log "asking WD to show Run App ON again (attempt $attempt)"
        curl -s --max-time 20 -d "cmd=cgi_apps_set&f_module_name=$TS_PACKAGE&f_enable=1" \
            "$TS_WD_APPS_CGI" > /dev/null 2>&1
    done
    sleep 2
    if ts_dashboard_shows_on; then
        ts_log "Run App shows ON in the dashboard again"
    else
        ts_log "couldn't switch Run App back ON in the dashboard; Tailscale runs anyway, so switch it ON yourself to match"
    fi
}

cmd_log_keeper() {
    exec 8> "$TS_KEEPER_LOCK"
    flock -n 8 || exit 0
    while [ -n "$(ts_our_pids)" ]; do
        ts_truncate_if_large "$TS_LOG_DIR/tailscaled.log"
        sleep "$TS_KEEPER_INTERVAL"
    done
}

# --- the Configure page ----------------------------------------------------------

# <text> as the inside of a JSON string, on one line.
json_text() {
    printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# The first line of <text>, cleaned up for a key=value message, with
# anything shaped like an auth key blanked out.
one_line() {
    printf '%s\n' "$1" | tr -d '\r' | grep -v '^[[:space:]]*$' | head -n 1 | cut -c 1-300 \
        | sed 's/tskey-[A-Za-z0-9_?=&.-]*/[key]/g'
}

# The tailscale CLI of the running daemon, on this app's socket.
cli() {
    "$(ts_cli_dir)/tailscale" --socket="$TS_SOCKET" "$@"
}

# <command> as JSON from the running daemon, or null.
cli_json() {
    if [ -n "$(ts_our_pids)" ] && cli_output=$(cli "$@" 2> /dev/null) && [ -n "$cli_output" ]; then
        printf '%s' "$cli_output"
    else
        printf null
    fi
}

cmd_web_status() {
    if [ -n "$(ts_our_pids)" ]; then
        daemon=running
    elif [ -n "$(ts_foreign_pids)" ]; then
        daemon=foreign
    else
        daemon=stopped
    fi
    if [ -f "$TS_CUTOVER_OK" ]; then
        first_start="done"
    elif [ -f "$TS_CUTOVER_FAILED" ]; then
        first_start=failed
    else
        first_start=pending
    fi
    should_run=false
    [ -f "$TS_SHOULD_RUN" ] && should_run=true
    printf '{"app":{"daemon":"%s","should_run":%s,"first_start":"%s","first_start_message":"%s","switched_from":"%s"},' \
        "$daemon" "$should_run" "$first_start" "$(json_text "$(cat "$TS_CUTOVER_FAILED" 2> /dev/null)")" \
        "$(json_text "$(cat "$TS_SWITCHED_FROM" 2> /dev/null)")"
    printf '"status":%s,' "$(cli_json status --json --peers=false)"
    printf '"prefs":%s}\n' "$(cli_json debug prefs)"
}

# A top-level text field of the daemon's status, such as BackendState.
status_field() {
    cli status --json --peers=false 2> /dev/null \
        | sed -n "s/^  \"$1\": *\"\([^\"]*\)\".*/\1/p" | head -n 1
}

# A top-level true/false field of the daemon's status, such as HaveNodeKey.
status_flag() {
    cli status --json --peers=false 2> /dev/null \
        | sed -n "s/^  \"$1\": *\([a-z]*\).*/\1/p" | head -n 1
}

# Start, restart and cutover replace the daemon while holding the app lock;
# the page's changes wait for them rather than talk to a daemon on its way out.
lock_or_busy() {
    ts_try_lock && return 0
    echo "error=Tailscale is starting or restarting. Try again in a minute."
    return 1
}

# The lines of <file> that <other file> doesn't have; either may be missing
# or empty. (BusyBox's grep -f with an empty file matches every line.)
lines_only_in() {
    [ -f "$1" ] || return 0
    if [ -s "$2" ]; then
        grep -vxF -f "$2" "$1"
    else
        cat "$1"
    fi
}

# The name of the tailnet the daemon is on, such as example.com.
current_tailnet() {
    cli status --json --peers=false 2> /dev/null \
        | sed -n '/^  "CurrentTailnet": {/,/^  }/s/^    "Name": *"\([^"]*\)".*/\1/p' | head -n 1
}

# Forwarding this app turned on for the current tailnet's routes, and the
# address recorded at cutover, don't apply to a different login.
forget_this_login() {
    ts_write_forwarding 0 "$TS_FORWARDING"
    rm -f "$TS_FORWARDING" "$TS_NODE_IP"
}

require_daemon() {
    [ -n "$(ts_our_pids)" ] && return 0
    echo "error=Tailscale isn't running. Switch the app ON first."
    return 1
}

# Log in. "tailscale login" always starts a new profile, so:
# - without switch=1, only a node that has never logged in is logged in from
#   here. On one whose key expired, or that was removed from the tailnet, a
#   new profile would mean a new identity and address; "tailscale up" over
#   SSH keeps them.
# - with switch=1 (the page's "connect to another tailnet"), a logged-in node
#   gets a new profile for the other tailnet. The current one stays saved,
#   and its name goes to $TS_SWITCHED_FROM for web-switch-back.
cmd_web_login() {
    lock_or_busy || return 1
    require_daemon || return 1
    auth_key="" switch=0
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            auth_key=*) auth_key=${line#*=} ;;
            switch=*) switch=${line#*=} ;;
        esac
    done
    if [ -n "$auth_key" ] && ! ts_valid_auth_key "$auth_key"; then
        echo "error=That doesn't look like an auth key from the Tailscale admin console."
        return 1
    fi
    state=$(status_field BackendState)

    # A login link already handed out stays valid; a second login would
    # replace it.
    if [ -z "$auth_key" ] && [ "$state" = NeedsLogin ] && [ -n "$(status_field AuthURL)" ]; then
        echo ok=1
        return 0
    fi
    if [ "$switch" = 1 ]; then
        previous=$(current_tailnet)
        [ -n "$previous" ] && echo "$previous" > "$TS_SWITCHED_FROM"
        forget_this_login
        ts_log "Configure page: switching away from tailnet '${previous:-none}'"
    elif [ "$state" != NeedsLogin ]; then
        echo "error=This NAS is already logged in (state: ${state:-unknown})."
        return 1
    elif [ "$(status_flag HaveNodeKey)" != false ]; then
        echo "error=This NAS was logged in before: its login expired, or it was removed from the tailnet. Log it in again over SSH with \"tailscale up\", which keeps its identity."
        return 1
    fi

    if [ -z "$auth_key" ]; then
        # The CLI waits for the login to finish, so it runs detached; the
        # login link shows up in web-status as AuthURL.
        cli_dir=$(ts_cli_dir)
        (nohup "$cli_dir/tailscale" --socket="$TS_SOCKET" login --timeout=600s \
            >> "$TS_LOG_DIR/app.log" 2>&1 < /dev/null 9>&- &)
        ts_log "Configure page: interactive login started"
        echo ok=1
        return 0
    fi

    # The key reaches the CLI on its stdin, read as /proc/self/fd/0 (the NAS
    # has no /dev/stdin). It's never on a command line, where other
    # processes could read it, and never in a file.
    if output=$(printf '%s' "$auth_key" | cli login --auth-key=file:/proc/self/fd/0 --timeout=45s 2>&1); then
        ts_log "Configure page: logged in with an auth key, to tailnet '$(current_tailnet)'"
        echo ok=1
        return 0
    fi
    ts_log "Configure page: login with an auth key failed: $(one_line "$output")"
    if [ "$(status_field BackendState)" = NeedsMachineAuth ]; then
        echo "error=Logged in; now approve this NAS in the Tailscale admin console."
        return 1
    fi
    # A failed switch would leave the NAS on no tailnet at all.
    if [ "$switch" = 1 ] && [ -n "$previous" ] && cli switch "$previous" > /dev/null 2>&1; then
        rm -f "$TS_SWITCHED_FROM"
        ts_log "Configure page: switched back to tailnet '$previous'"
        echo "error=Tailscale refused the key: $(one_line "$output") This NAS is back on $previous."
        return 1
    fi
    echo "error=Tailscale refused the key: $(one_line "$output")"
    return 1
}

cmd_web_switch_back() {
    lock_or_busy || return 1
    require_daemon || return 1
    previous=$(cat "$TS_SWITCHED_FROM" 2> /dev/null)
    if [ -z "$previous" ]; then
        echo "error=There's no earlier tailnet to go back to."
        return 1
    fi
    if ! output=$(cli switch "$previous" 2>&1); then
        echo "error=Tailscale couldn't switch back: $(one_line "$output")"
        return 1
    fi
    rm -f "$TS_SWITCHED_FROM"
    ts_log "Configure page: switched back to tailnet '$previous'"
    echo ok=1
}

cmd_web_disconnect() {
    lock_or_busy || return 1
    require_daemon || return 1
    if ! output=$(cli down 2>&1); then
        echo "error=Tailscale couldn't disconnect: $(one_line "$output")"
        return 1
    fi
    ts_log "Configure page: disconnected (tailscale down); still logged in"
    echo ok=1
}

# "tailscale up" resets every setting it isn't given, so it gets the page's
# ones; if other settings were changed over SSH, it refuses rather than reset
# them, and says which.
cmd_web_connect() {
    lock_or_busy || return 1
    require_daemon || return 1
    hostname="" routes="" exit_node=false
    while IFS= read -r line || [ -n "$line" ]; do
        value=${line#*=}
        case $line in
            hostname=*) hostname=$value ;;
            routes=*) routes=$value ;;
            exit_node=*) exit_node=$value ;;
        esac
    done
    if ! ts_valid_hostname "$hostname" || ! ts_valid_routes "$routes" || ! ts_valid_bool "$exit_node"; then
        echo "error=The current settings couldn't be read back; connect over SSH with \"tailscale up\"."
        return 1
    fi
    if ! output=$(cli up --hostname="$hostname" --advertise-routes="$routes" \
        --advertise-exit-node="$exit_node" --timeout=30s 2>&1); then
        ts_log "Configure page: tailscale up failed: $(one_line "$output")"
        echo "error=Tailscale didn't reconnect: $(one_line "$output") Over SSH, \"tailscale up\" shows the full command it needs."
        return 1
    fi
    ts_log "Configure page: connected again (tailscale up)"
    echo ok=1
}

cmd_web_logout() {
    lock_or_busy || return 1
    require_daemon || return 1
    tailnet=$(current_tailnet)
    if ! output=$(cli logout 2>&1); then
        echo "error=Tailscale couldn't log out: $(one_line "$output")"
        return 1
    fi
    forget_this_login
    ts_log "Configure page: logged out of tailnet '${tailnet:-unknown}'"
    echo ok=1
}

cmd_web_set() {
    lock_or_busy || return 1
    require_daemon || return 1
    hostname="" routes="" exit_node="" auto_update=""
    while IFS= read -r line || [ -n "$line" ]; do
        value=${line#*=}
        case $line in
            hostname=*) hostname=$value ;;
            routes=*) routes=$value ;;
            exit_node=*) exit_node=$value ;;
            auto_update=*) auto_update=$value ;;
        esac
    done
    if ! ts_valid_hostname "$hostname"; then
        echo "error=The name may only hold letters, digits and dashes (not first or last), up to 63."
        return 1
    elif ! ts_valid_routes "$routes"; then
        echo "error=Routes must be address ranges such as 192.168.1.0/24."
        return 1
    elif ! ts_valid_bool "$exit_node" || ! ts_valid_bool "$auto_update"; then
        echo "error=Unexpected value for the exit node or automatic updates."
        return 1
    fi

    # Routes and an exit node need forwarding. IPv6 forwarding is only for
    # IPv6 routes: it stops the NAS from taking its own IPv6 address from
    # router advertisements. Newly needed switches go on before "tailscale
    # set", which checks them; the list is kept only once Tailscale accepts
    # the change, and switches no longer needed go back off.
    wanted=$TS_FORWARDING.wanted
    newly=$TS_FORWARDING.newly
    if [ -n "$routes" ] || [ "$exit_node" = true ]; then
        echo net/ipv4/ip_forward
        case $routes in *:*) echo net/ipv6/conf/all/forwarding ;; esac
    fi > "$wanted"
    lines_only_in "$wanted" "$TS_FORWARDING" > "$newly"
    ts_write_forwarding 1 "$newly"

    if ! output=$(cli set --hostname="$hostname" --advertise-routes="$routes" \
        --advertise-exit-node="$exit_node" --auto-update="$auto_update" 2>&1); then
        ts_write_forwarding 0 "$newly"
        rm -f "$wanted" "$newly"
        ts_log "Configure page: tailscale set failed: $(one_line "$output")"
        echo "error=Tailscale refused the settings: $(one_line "$output")"
        return 1
    fi
    lines_only_in "$TS_FORWARDING" "$wanted" > "$newly"
    ts_write_forwarding 0 "$newly"
    if [ -s "$wanted" ]; then
        mv -f "$wanted" "$TS_FORWARDING"
    else
        rm -f "$wanted" "$TS_FORWARDING"
    fi
    rm -f "$newly"
    ts_log "Configure page: hostname '${hostname}', routes '${routes}', exit node $exit_node, auto-update $auto_update"
    echo ok=1
}

case "$1" in
    start)
        ts_take_lock_or_exit
        cmd_start
        ;;
    upgrade-restart)
        ts_take_lock_or_exit
        cmd_upgrade_restart
        ;;
    cutover)
        ts_take_lock_or_exit
        cmd_cutover
        ;;
    log-keeper)
        cmd_log_keeper
        ;;
    restore-run-app)
        cmd_restore_run_app
        ;;
    dashboard-on)
        cmd_dashboard_on
        ;;
    web-status)
        cmd_web_status
        ;;
    web-login)
        cmd_web_login
        ;;
    web-switch-back)
        cmd_web_switch_back
        ;;
    web-set)
        cmd_web_set
        ;;
    web-disconnect)
        cmd_web_disconnect
        ;;
    web-connect)
        cmd_web_connect
        ;;
    web-logout)
        cmd_web_logout
        ;;
    *)
        echo "usage: ctl.sh start|upgrade-restart|cutover|log-keeper|restore-run-app|dashboard-on|web-<command> (see the header)" >&2
        exit 2
        ;;
esac
