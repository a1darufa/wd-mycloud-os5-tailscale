#!/bin/sh
# tailscale-sim.sh <stub .bin> — runs inside a busybox container.
#
# Drives the Tailscale app through WD's measured script sequences
# (docs/os5-app-lifecycle.md) on a NAS-like file tree, with stub daemons
# (tests/stubs) standing in for tailscaled. A twonky-style hook daemon runs
# from /mnt/HD/HD_a2/tailscale for scenarios 1-13; the last ones cover a NAS
# with Tailscale started some other way, one without Tailscale, the Configure
# page's commands on that new node, an upgrade of a node that was
# disconnected on purpose, and WD alerts about the login. iptables has no NAT
# table, as on the NAS.
#
# Usage (from WSL, repo root):
#   tailscale/build.sh --stub running
#   docker run --rm --init --network none -v "$PWD:/work:ro" busybox:1.30.1 \
#       sh /work/tests/tailscale-sim.sh /work/dist/MyCloudEX2Ultra_tailscale_<version>-stub-running.bin
#
# --init matters: daemons are reparented to PID 1, and like init on the NAS
# it must reap them, or stopped daemons linger as zombies.

set -u

BIN=$1
STUBS=/work/tests/stubs
NAS_PROG=/mnt/HD/HD_a2/Nas_Prog
STAGED=$NAS_PROG/_install/tailscale
APP=$NAS_PROG/tailscale
APP_HOME=/mnt/HD/HD_a2/.systemfile/tailscale
HOOK=/mnt/HD/HD_a2/tailscale
HEADER_BYTES=204

# Short timings so the whole run takes a couple of minutes.
export TS_START_TIMEOUT=6 TS_PROOF_TIMEOUT=6 TS_STOP_TIMEOUT=3 TS_POLL_INTERVAL=1 TS_KEEPER_INTERVAL=1 TS_DASHBOARD_DELAY=1 TS_BOOT_DASHBOARD_DELAY=1 TS_CHECK_ROUNDS=2
# Stand-ins for the kernel's forwarding switches (/proc/sys is read-only here).
export TS_PROC_SYS=/tmp/proc-sys

failures=0

# --- helpers -------------------------------------------------------------------

section() { printf '\n=== %s\n' "$*"; }

expect() {
    if eval "$1"; then
        echo "ok:   $2"
    else
        echo "FAIL: $2"
        failures=$((failures + 1))
    fi
}

wait_for() { # <condition> <seconds>
    remaining=$2
    until eval "$1"; do
        [ "$remaining" -le 0 ] && return 1
        sleep 1
        remaining=$((remaining - 1))
    done
}

# PIDs of the tailscaled daemons. The stubs are shell scripts, and a child
# they fork (for sleep or cat) shows up in pidof under the same name for a
# moment; a tailscaled whose parent is a tailscaled is such a child.
daemon_pids() {
    all=" $(pidof tailscaled) "
    for pid in $all; do
        ppid=$(awk '{ print $4 }' "/proc/$pid/stat" 2> /dev/null) || continue
        case "$all" in
            *" $ppid "*) ;;
            *) echo "$pid" ;;
        esac
    done
}
daemons() {
    for pid in $(daemon_pids); do
        echo "$pid $(tr '\0' ' ' 2> /dev/null < "/proc/$pid/cmdline")"
    done
}
daemon_count() { daemon_pids | wc -l; }
ours_running() { daemons | grep -q -- "--statedir=$APP_HOME/state "; }
hook_running() { daemons | grep -q -- "--statedir=$HOOK/state "; }
our_pid() { daemons | grep -- "--statedir=$APP_HOME/state " | awk '{ print $1 }' | head -n 1; }
our_binary_is() { daemons | grep -- "--statedir=$APP_HOME/state " | grep -q -- "$1/tailscaled "; }
# As the Configure page's api.php runs it: as root, input on stdin.
ctl() { sh "$APP/ctl.sh" "$@"; }

ctl_busy() {
    for proc in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2> /dev/null < "$proc/cmdline")" in
            *"ctl.sh start"* | *"ctl.sh upgrade-restart"* | *"ctl.sh cutover"* | *"ctl.sh restore-run-app"* | *"ctl.sh dashboard-on"*) return 0 ;;
        esac
    done
    return 1
}
wait_idle() { wait_for "! ctl_busy" 60; }

# Running log keepers, and those still running a deleted (earlier) ctl.sh.
# A keeper's subshells share its command line; those are left out.
keeper_procs() {
    all=" "
    for proc in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2> /dev/null < "$proc/cmdline")" in
            *"ctl.sh log-keeper"*) all="$all${proc#/proc/} " ;;
        esac
    done
    for pid in $all; do
        case "$all" in
            *" $(awk '{ print $4 }' "/proc/$pid/stat" 2> /dev/null) "*) ;;
            *) echo "/proc/$pid" ;;
        esac
    done
}
keepers() { keeper_procs | wc -l; }
stale_keepers() {
    for proc in $(keeper_procs); do
        for fd in "$proc"/fd/*; do
            case "$(readlink "$fd" 2> /dev/null)" in
                *"ctl.sh (deleted)")
                    echo "$proc"
                    break
                    ;;
            esac
        done
    done | wc -l
}

# Log checks only look at lines written since the last mark_log.
mark_log() { log_mark=$(wc -l < "$APP_HOME/log/app.log" 2> /dev/null || echo 0); }
logged() { tail -n +$((log_mark + 1)) "$APP_HOME/log/app.log" 2> /dev/null | grep -q -- "$1"; }

# WD alerts, as the stub fireAlert keeps them: one file per alert in
# /tmp/alerts (code, then text), every call in /tmp/alerts.log.
alerted() { grep -qF -- "$1" /tmp/alerts/* 2> /dev/null; }
tailscale_alerts() { grep -lF ' Tailscale: ' /tmp/alerts/* 2> /dev/null | wc -l; }
alerts_sent() { cat /tmp/alerts.log 2> /dev/null | grep -cF -- "$1"; }
# Texts WD would drop or split: too long, or holding < > & or commas.
bad_alert_texts() {
    for alert in /tmp/alerts/*; do
        [ -f "$alert" ] && sed -n 2p "$alert"
    done | awk 'length > 121 || /[,<>&]/'
}
clear_alerts() { rm -rf /tmp/alerts /tmp/alerts.seq /tmp/alerts.log "$APP_HOME/alerts"; }

enabled() { grep -q '<enable>1</enable>' "$APP/apkg.xml"; }
set_enable() { sed -i "s#<enable>[0-9]*</enable>#<enable>$1</enable>#" "$APP/apkg.xml"; }

# The twonky hook: start the old daemon unless any tailscaled runs.
start_hook() {
    pidof tailscaled > /dev/null && return 0
    (nohup "$HOOK/tailscaled" --state="$HOOK/state/tailscaled.state" --statedir="$HOOK/state" \
        >> "$HOOK/tailscaled.log" 2>&1 < /dev/null &)
}

stage_package() { # <stub mode for the new version's tailscaled>
    rm -rf "$NAS_PROG/_install"
    mkdir -p "$NAS_PROG/_install"
    tail -c +$((HEADER_BYTES + 1)) "$BIN" | tar -xzf - -C "$NAS_PROG/_install"
    echo "$1" > "$STAGED/bin/stub-mode"
}

# --- WD's sequences, as measured ---------------------------------------------

wd_install() { # <stub mode>: fresh install; the app ends OFF
    stage_package "$1"
    "$STAGED/before_apkg.sh"
    mkdir -p "$APP"
    "$STAGED/install.sh" "$STAGED" "$NAS_PROG"
    "$APP/init.sh" "$APP"
    set_enable 0
}

wd_switch_on() { set_enable 1; "$APP/start.sh" "$APP"; }
wd_switch_off() { set_enable 0; "$APP/stop.sh" "$APP"; }

wd_upgrade_begin() { # <stub mode>: new before_apkg, then the old stop/clean/preinst/remove
    stage_package "$1"
    "$STAGED/before_apkg.sh"
    enabled && "$APP/stop.sh" "$APP"
    "$APP/clean.sh" "$APP"
    "$APP/preinst.sh" "$APP"
    "$APP/remove.sh" "$APP"
}

# New install and init. WD's installer process runs throughout; it stores the
# new package's switch (OFF) last, after init.sh, the worst case for the
# app's restore. Then it records its result and copies it into the dialog's
# install record, which OK has set to 100 (installing). <outcome>:
# "installed" (the default) or "lost-copy" (the record stays at 100, as in
# WD's dialog hangs).
wd_upgrade_finish() {
    write_install_record 100 tailscale
    echo 100 > /tmp/upload_apkg_status
    touch /tmp/wd-installing
    (upload_apkg &)
    mkdir -p "$APP"
    "$STAGED/install.sh" "$STAGED" "$NAS_PROG"
    "$APP/init.sh" "$APP"
    sleep 1
    set_enable 0
    case ${1:-installed} in
        installed) echo 1 > /tmp/upload_apkg_status && write_install_record 1 tailscale ;;
        lost-copy) echo 1 > /tmp/upload_apkg_status ;;
    esac
    rm -f /tmp/wd-installing
}

# The install record the "Updating" dialog polls, as WD writes it: <status>, <app>.
write_install_record() {
    mkdir -p /var/www/xml
    printf '<?xml version="1.0" encoding="UTF-8" ?>\n<config>\n<install_type>1</install_type>\n<install_status>%s</install_status>\n<install_filename>MyCloudEX2Ultra_%s.bin</install_filename>\n<name>%s</name>\n<dep_apps></dep_apps>\n</config>\n' \
        "$1" "$2" "$2" > /var/www/xml/apkg_state.xml
    chmod 666 /var/www/xml/apkg_state.xml
}
dialog_status() { sed -n 's#<install_status>\(.*\)</install_status>#\1#p' /var/www/xml/apkg_state.xml; }

power_off() {
    for proc in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2> /dev/null < "$proc/cmdline")" in
            *tailscaled* | *ctl.sh*) kill -9 "${proc#/proc/}" 2> /dev/null ;;
        esac
    done
    sleep 1
    rm -f /var/run/tailscale/tailscaled.sock # /var/run is tmpfs on the NAS
}

wd_shutdown() { # enabled apps: stop+clean, disabled: clean; twice; then power off
    for round in 1 2; do
        enabled && "$APP/stop.sh" "$APP"
        "$APP/clean.sh" "$APP"
        : "$round"
    done
    power_off
}

wd_boot() { # init, then stop+start if enabled; the twonky hook ~4 s later
    "$APP/init.sh" "$APP"
    if enabled; then
        "$APP/stop.sh" "$APP"
        "$APP/start.sh" "$APP"
    fi
    sleep 4
    start_hook
}

wd_uninstall() {
    enabled && "$APP/stop.sh" "$APP"
    "$APP/clean.sh" "$APP"
    "$APP/remove.sh" "$APP"
}

# --- setup: a NAS with Tailscale running from the twonky hook ------------------

mkdir -p "$NAS_PROG" /mnt/HD/HD_a2/.systemfile /var/www "$HOOK/state" \
    "$TS_PROC_SYS/net/ipv4" "$TS_PROC_SYS/net/ipv6/conf/all"
echo 0 > "$TS_PROC_SYS/net/ipv4/ip_forward"
echo 0 > "$TS_PROC_SYS/net/ipv6/conf/all/forwarding"
# WD's Run App switch, as the apps call it after an upgrade, WD's installer
# process, which they wait for, WD's alerts, and iptables without a NAT
# table, as on the NAS.
mkdir -p /usr/local/bin
cp "$STUBS/curl" "$STUBS/upload_apkg" "$STUBS/fireAlert" "$STUBS/iptables" /usr/local/bin/
chmod 755 /usr/local/bin/curl /usr/local/bin/upload_apkg /usr/local/bin/fireAlert /usr/local/bin/iptables
cp "$STUBS/tailscaled" "$STUBS/tailscale" "$HOOK/"
chmod 755 "$HOOK/tailscaled" "$HOOK/tailscale"
echo hook-identity > "$HOOK/state/tailscaled.state"
start_hook
wait_for hook_running 5
hook_pid=$(daemon_pids)
mark_log

section "1. Fresh install, Run App OFF"
# Where 1.104.2-2 and earlier linked the page, outside the dashboard login.
mkdir -p /var/www/tailscale && touch /var/www/tailscale/index.html
wd_install running
expect "[ \"\$(daemon_pids)\" = '$hook_pid' ]" "the hook daemon is untouched (same PID)"
expect "! ours_running" "install starts nothing"
expect "[ -f /var/www/apps/tailscale/index.html ] && [ -f /var/www/apps/tailscale/api.php ]" "dashboard pages linked into /var/www/apps/tailscale"
expect "[ ! -e /var/www/tailscale ]" "the old open page folder is gone"

section "2. Forced failure: the new binary never reaches Running"
echo starting > "$APP/bin/stub-mode"
mark_log
wd_switch_on
wait_for "[ -f '$APP_HOME/cutover-failed' ]" 40
wait_idle
expect "[ -f '$APP_HOME/cutover-failed' ]" "the cutover is marked failed"
expect hook_running "the hook daemon is restored"
expect "! ours_running" "the new daemon is stopped"
expect "[ \$(daemon_count) -eq 1 ]" "exactly one tailscaled"
expect "grep -q hook-identity '$APP_HOME/state/tailscaled.state'" "the state was copied"
expect "grep -q hook-identity '$HOOK/state/tailscaled.state'" "the hook's state is untouched"
expect "logged 'hook daemon is Running again'" "the restored daemon was verified"
expect "alerted 'taking over the Tailscale started by hand' && [ \"\$(bad_alert_texts)\" = '' ]" "a WD alert says so, in a text WD shows whole"

section "3. A failed cutover is not retried on its own"
wd_switch_off
mark_log
wd_switch_on
sleep 2
expect "logged 'not taking over'" "start.sh refuses to retry"
expect hook_running "the hook daemon keeps running"

section "4. Running but no proof of reachability: revert"
rm -f "$APP_HOME/cutover-failed"
echo quiet > "$APP/bin/stub-mode"
wd_switch_off
wd_switch_on
wait_for "[ -f '$APP_HOME/cutover-failed' ]" 40
wait_idle
expect "grep -q 'no proof' '$APP_HOME/cutover-failed'" "reverted for lack of proof"
expect "hook_running && ! ours_running" "back on the hook daemon"
expect "[ \$(daemon_count) -eq 1 ]" "exactly one tailscaled"

section "5. Cutover proven by the confirm file"
rm -f "$APP_HOME/cutover-failed"
wd_switch_off
mark_log
wd_switch_on
wait_for "logged 'waiting up to'" 20
touch "$APP_HOME/confirm"
wait_for "[ -f '$APP_HOME/cutover-ok' ]" 20
wait_idle
expect "[ -f '$APP_HOME/cutover-ok' ]" "cutover-ok written"
expect "logged 'confirmed through'" "proof came from the confirm file"
expect "ours_running && ! hook_running" "the app's daemon replaced the hook's"
expect "[ \$(daemon_count) -eq 1 ]" "exactly one tailscaled"
expect "[ -x '$APP_HOME/lkg/tailscaled' ]" "binaries saved as last-known-good"
expect "[ \"\$(cat '$APP_HOME/node-ip')\" = 100.101.102.103 ]" "the node's IP was recorded"

section "6. Cutover proven by peer traffic (fresh takeover)"
wd_switch_off
rm -f "$APP_HOME/cutover-ok"
start_hook
wait_for hook_running 5
echo running > "$APP/bin/stub-mode"
mark_log
wd_switch_on
wait_for "[ -f '$APP_HOME/cutover-ok' ]" 30
wait_idle
expect "logged 'peer traffic'" "proof came from received bytes"
expect "ours_running && ! hook_running" "the app's daemon runs"

section "7. Upgrade while ON"
# On the NAS the log keeper sleeps a minute between rounds, so unlike the
# one-second keepers here, it outlives the moment the upgrade restarts the
# daemon. One like it:
for proc in $(keeper_procs); do
    kill "${proc#/proc/}"
done
wait_for "[ \"\$(keepers)\" = 0 ]" 5
(TS_KEEPER_INTERVAL=30 nohup sh "$APP/ctl.sh" log-keeper > /dev/null 2>&1 < /dev/null &)
wait_for "[ \"\$(keepers)\" = 1 ]" 5
old_pid=$(our_pid)
mark_log
: > /tmp/curl.log
wd_upgrade_begin running
expect "kill -0 '$old_pid' 2> /dev/null" "the daemon survives the old stop.sh and remove.sh"
expect "[ ! -d '$APP' ]" "the old app folder is gone (no 'text file busy' on install)"
wd_upgrade_finish
wait_for "ours_running && [ \"\$(our_pid)\" != '$old_pid' ]" 20
wait_idle
expect "[ \"\$(our_pid)\" != '$old_pid' ] && our_binary_is '$APP/bin'" "restarted on the new version's binary"
expect "[ ! -f '$APP_HOME/upgrading' ] && [ -f '$APP_HOME/should-run' ]" "upgrade flag cleared, should-run kept"
expect "[ \$(daemon_count) -eq 1 ]" "exactly one tailscaled"
expect "enabled && logged 'Run App back ON, as it was before'" "WD's switch is put back ON after WD's installer stored OFF"
expect "[ \"\$(stat -c %a:%U '$APP/apkg.xml')\" = \"\$(stat -c %a:%U '$STAGED/apkg.xml')\" ]" "apkg.xml keeps its mode and owner"
expect "[ ! -s /tmp/curl.log ] && logged 'shows ON in the dashboard again'" "nothing to ask WD for: the dashboard's list follows apkg.xml"
expect "[ \"\$(dialog_status)\" = 1 ] && ! logged 'Updating dialog'" "WD's dialog got WD's result; the app left it alone"
wait_for "logged 'stopping the log keeper an earlier version started'" 10
wait_for "[ \"\$(keepers)\" = 1 ]" 10
expect "logged 'stopping the log keeper an earlier version started' && [ \"\$(keepers)\" = 1 ] && [ \"\$(stale_keepers)\" = 0 ]" "the earlier version's log keeper makes way for this version's"

# WD records "installed", but the dialog's copy stays at 100.
old_pid=$(our_pid)
mark_log
wd_upgrade_begin running
wd_upgrade_finish lost-copy
wait_for "ours_running && [ \"\$(our_pid)\" != '$old_pid' ]" 20
wait_idle
expect "[ \"\$(dialog_status)\" = 1 ] && logged 'passed WD.s result on'" "a dialog stuck on installing gets WD's result once the installer exits"
expect "[ \"\$(stat -c %a /var/www/xml/apkg_state.xml)\" = 666 ]" "the record keeps WD's mode"
expect "enabled && our_binary_is '$APP/bin'" "Run App is back ON, on the new binary"

# The app never reports a result WD didn't record, nor touches another app's record.
write_install_record 100 tailscale
echo 100 > /tmp/upload_apkg_status
ctl restore-run-app
expect "[ \"\$(dialog_status)\" = 100 ]" "no result recorded by WD: the dialog is left as it is"
write_install_record 100 transmission4
echo 1 > /tmp/upload_apkg_status
ctl restore-run-app
expect "[ \"\$(dialog_status)\" = 100 ]" "another app's install record is left alone"

section "8. Upgrade to a new binary that crashes: last-known-good takes over"
wd_switch_on
wait_idle
# The dashboard's list, as its page reads it, still says OFF: the app asks WD.
mkdir -p /var/www/xml
printf '<config>\n<item>\n<name>tailscale</name>\n<enable>0</enable>\n</item>\n</config>\n' \
    > /var/www/xml/apkg_all.xml
mark_log
wd_upgrade_begin crash
wd_upgrade_finish
wait_for "our_binary_is '$APP_HOME/lkg'" 30
wait_idle
expect "our_binary_is '$APP_HOME/lkg'" "running from lkg/"
expect "[ \$(daemon_count) -eq 1 ]" "exactly one tailscaled"
expect "logged 'asking WD to show Run App ON' && grep -q '<enable>1</enable>' /var/www/xml/apkg_all.xml" "a list that still says OFF: it asks WD, and the list agrees"
expect "[ \$(daemon_count) -eq 1 ] && our_binary_is '$APP_HOME/lkg'" "WD's start.sh left the lkg/ daemon alone"
expect "alerted 'An earlier version runs instead' && [ \"\$(tailscale_alerts)\" = 1 ]" "a WD alert says so, replacing the app's earlier one"
rm -f /var/www/xml/apkg_all.xml

section "9. Reboot after an upgrade left Run App OFF"
echo running > "$APP/bin/stub-mode"
# As if WD had dropped the request to switch it back ON.
set_enable 0
mark_log
wd_shutdown
wd_boot
wait_for ours_running 20
wait_idle
expect "logged 'should-run is set'" "init.sh restored the daemon from the app's own flag"
expect "enabled" "and switched WD's Run App back ON"
expect "ours_running && ! hook_running" "the app's daemon runs; the hook stood down"
expect "[ \$(daemon_count) -eq 1 ]" "exactly one tailscaled"

section "10. Reboot with Run App ON"
wd_switch_on
wait_idle
wd_shutdown
wd_boot
wait_for ours_running 20
wait_idle
expect "ours_running && ! hook_running" "the app's daemon runs; the hook stood down"
expect "[ \$(daemon_count) -eq 1 ]" "exactly one tailscaled"

section "11. Run App OFF"
wd_switch_off
expect "! ours_running" "the daemon is stopped"
expect "[ ! -f '$APP_HOME/should-run' ]" "should-run cleared"

section "12. A stale upgrade flag doesn't block stopping"
wd_switch_on
wait_for ours_running 20
wait_idle
touch -d "2000-01-01 00:00:00" "$APP_HOME/upgrading"
wd_switch_off
expect "! ours_running" "stop.sh ignores an expired upgrade flag"

section "13. Uninstall while ON"
rm -f "$APP_HOME/upgrading"
wd_switch_on
wait_for ours_running 20
wait_idle
wd_uninstall
expect "[ ! -d '$APP' ] && [ ! -d /var/www/apps/tailscale ]" "app folder and page removed"
expect "! ours_running" "the daemon is stopped"
expect "[ -f '$APP_HOME/state/tailscaled.state' ]" "the state is kept"

section "14. A Tailscale started some other way: left alone"
power_off
rm -rf "$APP_HOME" "$HOOK"
mkdir -p /opt/other
cp "$STUBS/tailscaled" "$STUBS/tailscale" /opt/other/
chmod 755 /opt/other/tailscaled /opt/other/tailscale
nohup /opt/other/tailscaled --statedir=/opt/other/state --socket=/var/run/other.sock \
    > /dev/null 2>&1 < /dev/null &
other_pid=$!
wait_for "[ -f /var/run/other.sock ]" 5
wd_install running
mark_log
wd_switch_on
wait_for "[ -f '$APP_HOME/cutover-failed' ]" 20
wait_idle
expect "logged 'not starting' && grep -q 'another tailscaled' '$APP_HOME/cutover-failed'" "refused, with the reason recorded"
expect "kill -0 '$other_pid' 2> /dev/null && ! ours_running" "the other daemon is untouched, and no second one started"
kill "$other_pid"
wait_for "! kill -0 '$other_pid' 2> /dev/null" 5
wd_uninstall

section "15. A NAS without Tailscale: a new node"
rm -rf "$APP_HOME"
rm -f /var/run/tailscale/tailscaled.sock.*
wd_install needs-login
mark_log
wd_switch_on
wait_for "[ -f '$APP_HOME/cutover-ok' ]" 20
wait_idle
expect "logged 'starting a new node' && logged 'tailscale up'" "a new node was started, and the login step logged"
expect "ours_running && [ \$(daemon_count) -eq 1 ]" "exactly one tailscaled, the app's"
expect "[ ! -f '$APP_HOME/cutover-failed' ] && [ -x '$APP_HOME/lkg/tailscaled' ]" "no failure recorded; binaries saved as last-known-good"
wait_for "ctl web-status | grep -q '\"NetfilterMode\": 0,'" 10
expect "ctl web-status | grep -q '\"NetfilterMode\": 0,' && ctl web-status | grep -q '\"NoSNAT\": true,' && logged 'no NAT in this kernel'" "no NAT table: the log keeper tells tailscaled to leave the firewall alone"
expect "ctl web-status | grep -q '\"nat\":false'" "and web-status says the kernel has no NAT"

section "16. The Configure page's commands, as api.php runs them"
# shellcheck disable=SC2034 # read in expect's eval
status=$(ctl web-status)
expect "echo \"\$status\" | grep -q '\"daemon\":\"running\"' && echo \"\$status\" | grep -q '\"BackendState\": \"NeedsLogin\"'" "web-status: the app's daemon, waiting for a login"
# shellcheck disable=SC2034 # read in expect's eval
refused=$(echo 'hostname=-bad' | ctl web-set)
expect "echo \"\$refused\" | grep -q '^error=The name'" "web-set refuses a bad name"
# Split in two so the public export's check for real keys doesn't flag it.
key="tskey""-auth-stub-good"
mark_log
result=$(echo "auth_key=$key" | ctl web-login)
expect "[ \"\$result\" = ok=1 ] && [ \"\$(cat /var/run/tailscale/tailscaled.sock.key-source)\" = /proc/self/fd/0 ]" "web-login with a key logs in, handing the key over on stdin"
expect "logged 'logged in with an auth key' && ! grep -qF '$key' '$APP_HOME/log/app.log'" "the login is logged, the key isn't"
expect "grep -qF -- '--netfilter-mode=off --snat-subnet-routes=false' /var/run/tailscale/tailscaled.sock.login-args" "the new login profile gets the NAT flags from the start"
wait_for "ctl web-status | grep -q '\"BackendState\": \"Running\"'" 5
flock "$APP_HOME/lock" sleep 3 &
wait_for "! flock -n '$APP_HOME/lock' true" 3
# shellcheck disable=SC2034 # read in expect's eval
refused=$(printf 'hostname=nas\nroutes=\nexit_node=false\nauto_update=true\n' | ctl web-set)
expect "echo \"\$refused\" | grep -q 'starting or restarting'" "web-set waits for a start or restart that holds the lock"
wait
# shellcheck disable=SC2034 # read in expect's eval
result=$(printf 'hostname=nas\nroutes=192.168.1.0/24\nexit_node=false\nauto_update=true\n' | ctl web-set)
expect "[ \"\$result\" = ok=1 ] && [ \"\$(cat '$TS_PROC_SYS/net/ipv4/ip_forward')\" = 1 ] && [ \"\$(cat '$TS_PROC_SYS/net/ipv6/conf/all/forwarding')\" = 0 ]" "web-set with an IPv4 route turns on IPv4 forwarding only"
expect "grep -qF -- '--auto-update=true --netfilter-mode=off --snat-subnet-routes=false' /var/run/tailscale/tailscaled.sock.set-args" "and passes the NAT flags along"
touch /tmp/kernel-has-nat
# shellcheck disable=SC2034 # read in expect's eval
result=$(printf 'hostname=nas\nroutes=192.168.1.0/24\nexit_node=false\nauto_update=true\n' | ctl web-set)
expect "[ \"\$result\" = ok=1 ] && ! grep -q netfilter /var/run/tailscale/tailscaled.sock.set-args && ctl web-status | grep -q '\"nat\":true'" "a kernel with NAT: no NAT flags"
rm -f /tmp/kernel-has-nat
echo 0 > "$TS_PROC_SYS/net/ipv4/ip_forward"
wd_switch_off
mark_log
wd_switch_on
wait_for ours_running 20
wait_idle
expect "ours_running && ! logged 'starting a new node'" "the next switch-on just starts it"
expect "[ \"\$(cat '$TS_PROC_SYS/net/ipv4/ip_forward')\" = 1 ]" "and turns IPv4 forwarding on again (it resets at boot)"
# shellcheck disable=SC2034 # read in expect's eval
result=$(printf 'hostname=nas\nroutes=\nexit_node=false\nauto_update=true\n' | ctl web-set)
expect "[ \"\$result\" = ok=1 ] && [ \"\$(cat '$TS_PROC_SYS/net/ipv4/ip_forward')\" = 0 ] && [ ! -e '$APP_HOME/ip-forwarding' ]" "removing the route turns forwarding off again"
wd_uninstall

section "17. An upgrade of a node that's disconnected on purpose"
# A connected new node, then "tailscale down" from the Configure page.
power_off
rm -rf "$APP_HOME"
rm -f /var/run/tailscale/tailscaled.sock.*
wd_install running
wd_switch_on
wait_for "[ -f '$APP_HOME/cutover-ok' ]" 20
wait_idle
# shellcheck disable=SC2034 # read in expect's eval
result=$(ctl web-disconnect)
wait_for "ctl web-status | grep -q '\"BackendState\": \"Stopped\"'" 5
expect "[ \"\$result\" = ok=1 ] && ctl web-status | grep -q '\"BackendState\": \"Stopped\"'" "web-disconnect takes the node offline"
mark_log
wd_upgrade_begin running
wd_upgrade_finish
wait_for ours_running 20
wait_idle
expect "logged 'Stopped) to this version' && our_binary_is '$APP/bin' && ! logged 'not running after'" "it moves to the new binary without falling back: Stopped can't become Running"
expect "ctl web-status | grep -q '\"BackendState\": \"Stopped\"'" "and stays disconnected, as chosen"
rm -f /var/run/tailscale/tailscaled.sock.down
wd_uninstall

section "18. WD alerts about the login"
SOCK=/var/run/tailscale/tailscaled.sock
power_off
rm -rf "$APP_HOME"
rm -f "$SOCK".*
clear_alerts
wd_install running
wd_switch_on
wait_for "[ -f '$APP_HOME/cutover-ok' ]" 20
wait_idle
wait_for "ctl web-status | grep -q '\"BackendState\": \"Running\"'" 5
sleep 3
expect "[ \"\$(tailscale_alerts)\" = 0 ]" "a connected node without key expiry raises nothing"
# Another app's update alert, which shares WD's code 1501.
fireAlert -a 1501 -p " Plex Media Server" -f
date -u -d "@$(($(date +%s) + 3 * 86400 + 3600))" +%Y-%m-%dT%H:%M:%SZ > "$SOCK.key-expiry"
wait_for "alerted 'login expires in 3 days'" 10
expect "alerted 'login expires in 3 days' && [ \"\$(bad_alert_texts)\" = '' ]" "a login expiring within a week raises an alert"
rm -f "$SOCK.key-expiry"
touch "$SOCK.node-key" "$SOCK.logged-out"
wait_for "alerted 'logged out of its tailnet'" 10
expect "alerted 'logged out of its tailnet' && [ \"\$(tailscale_alerts)\" = 1 ]" "logged out without being asked (key kept): an alert, replacing the app's earlier one"
expect "alerted 'Plex Media Server'" "another app's update alert stays"
sleep 5
expect "[ \"\$(alerts_sent 'logged out of its tailnet')\" = 1 ]" "the same alert goes out at most once a day"
rm -f "$SOCK.node-key" "$SOCK.logged-out" "$APP_HOME/alerts/logged-out"
wait_for "ctl web-status | grep -q '\"BackendState\": \"Running\"'" 5
# shellcheck disable=SC2034 # read in expect's eval
result=$(ctl web-logout)
sleep 5
expect "[ \"\$result\" = ok=1 ] && [ \"\$(alerts_sent 'logged out of its tailnet')\" = 1 ]" "logging out on the Configure page raises nothing"
wd_uninstall

if [ "$failures" -ne 0 ]; then
    section "app.log (last 60 lines)"
    tail -n 60 "$APP_HOME/log/app.log"
fi
section "$failures failure(s)"
[ "$failures" -eq 0 ]
