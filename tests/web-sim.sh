#!/bin/sh
# web-sim.sh <stub .bin>... [--serve] — runs in the wd-os5-web-test image
# (docker/web-test: PHP 7.4 as on the NAS, and busybox).
#
# Installs the given stub packages (Tailscale's, Transmission 4's, or both)
# on a NAS-like tree and serves /var/www with PHP's built-in web server, as
# root like WD's php-fpm. Then it calls the settings pages' api.php the way
# their scripts do: first the request guards, then every action end to end,
# through ctl.sh to the stub daemons. Each app's own checks are in
# web-sim-<app>.sh.
#
# Usage (from WSL, repo root):
#   docker build --quiet --tag wd-os5-web-test docker/web-test
#   tailscale/build.sh --stub running && transmission4/build.sh --stub
#   docker run --rm --init --network none -v "$PWD:/work:ro" wd-os5-web-test \
#       sh /work/tests/web-sim.sh /work/dist/<tailscale stub>.bin /work/dist/<transmission4 stub>.bin
#
# --serve skips the checks and keeps serving on port 8080, to try the pages
# in a browser (tests/web-preview.sh).

set -u

TS_BIN="" TR_BIN="" SERVE=""
for arg; do
    case $arg in
        --serve) SERVE=--serve ;;
        *_tailscale_*.bin) TS_BIN=$arg ;;
        *_transmission4_*.bin) TR_BIN=$arg ;;
        *)
            echo "web-sim.sh: not a stub package of either app: $arg" >&2
            exit 2
            ;;
    esac
done
if [ -z "$TS_BIN$TR_BIN" ]; then
    echo "usage: web-sim.sh <stub .bin>... [--serve]" >&2
    exit 2
fi
# The apps to check, in the order they're installed.
apps=""
[ -n "$TR_BIN" ] && apps="$apps transmission4"
[ -n "$TS_BIN" ] && apps="$apps tailscale"
CLIENT=/work/tests/web-client.php
NAS_PROG=/mnt/HD/HD_a2/Nas_Prog
TS_HOME=/mnt/HD/HD_a2/.systemfile/tailscale
TR_HOME=/mnt/HD/HD_a2/.transmission4
SOCKET=/var/run/tailscale/tailscaled.sock
HEADER_BYTES=204
ORIGIN=http://127.0.0.1:8080

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

# Install a stub package the way WD's app manager does, and switch it ON.
install_app() { # <.bin> <package>
    rm -rf "$NAS_PROG/_install"
    mkdir -p "$NAS_PROG/_install"
    tail -c +$((HEADER_BYTES + 1)) "$1" | tar -xzf - -C "$NAS_PROG/_install"
    staged=$NAS_PROG/_install/$2
    # A NAS without Tailscale: a new node that nobody has logged in yet.
    [ "$2" = tailscale ] && echo needs-login > "$staged/bin/stub-mode"
    "$staged/before_apkg.sh"
    mkdir -p "$NAS_PROG/$2"
    "$staged/install.sh" "$staged" "$NAS_PROG"
    "$NAS_PROG/$2/init.sh" "$NAS_PROG/$2"
    "$NAS_PROG/$2/start.sh" "$NAS_PROG/$2"
}

# A request built by hand: <method> <path> <body> [header ...]. Sets $code
# and $body.
raw() {
    reply=$(php "$CLIENT" request "$@")
    code=$(echo "$reply" | head -n 1)
    body=$(echo "$reply" | tail -n +2)
}

# POST <json> to <app>'s api.php the way its settings page does.
api() {
    raw POST "/apps/$1/api.php" "$2" \
        "Content-Type: application/json" "X-Settings-Request: 1" "Origin: $ORIGIN"
}

# A value from the last reply's body, by key path (see web-client.php).
field() { php "$CLIENT" field "$body" "$1"; }

listening() { netstat -ltn 2> /dev/null | grep -q ":$1 "; }

# --- setup: the apps installed and ON ---------------------------------------------

mkdir -p "$NAS_PROG" /mnt/HD/HD_a2/.systemfile /mnt/HD/HD_a2/Transmission /var/www/apps
grep -q '^share:' /etc/group || echo 'share:x:1000:nobody' >> /etc/group
for app in $apps; do
    # Where versions up to 1.104.2-2 and 4.1.4-2 linked their pages, outside
    # the dashboard login.
    mkdir -p "/var/www/$app"
    touch "/var/www/$app/index.html"
done

if [ -n "$TR_BIN" ]; then
    install_app "$TR_BIN" transmission4
    wait_for "listening 9091" 15
fi
if [ -n "$TS_BIN" ]; then
    install_app "$TS_BIN" tailscale
    wait_for "grep -q NeedsLogin '$SOCKET' 2> /dev/null" 15
fi

if [ "$SERVE" = --serve ]; then
    echo "Serving on port 8080:"
    for app in $apps; do echo "  /apps/$app/settings.html"; done
    echo "(stub auth keys: anything ending in 'good' is accepted)"
    PHP_CLI_SERVER_WORKERS=4 exec php -S 0.0.0.0:8080 -t /var/www
fi
PHP_CLI_SERVER_WORKERS=4 php -S 127.0.0.1:8080 -t /var/www > /tmp/php-server.log 2>&1 &
server_pid=$!
wait_for "listening 8080" 10

section "1. The pages live under /apps, behind the dashboard login"
for app in $apps; do
    expect "[ -L /var/www/apps/$app/api.php ]" "$app: api.php linked under /var/www/apps"
    expect "[ -e /var/www/apps/$app/app-api.php ] && [ -e /var/www/apps/$app/settings-common.js ]" "$app: with the shared files next to it"
    expect "[ ! -e /var/www/$app ]" "$app: the old open folder is gone"
done

section "2. Request guards"
# common/web/app-api.php guards every app's api.php the same way; one app shows it.
if [ -n "$TR_BIN" ]; then guard_app=transmission4; else guard_app=tailscale; fi
raw GET "/apps/$guard_app/api.php" ""
expect "[ '$code' = 405 ]" "GET is refused"
raw POST "/apps/$guard_app/api.php" '{"action":"status"}' "Content-Type: application/json" "Origin: $ORIGIN"
expect "[ '$code' = 403 ] && echo \"\$body\" | grep -q X-Settings-Request" "a POST without the custom header (as a cross-site form sends) is refused"
raw POST "/apps/$guard_app/api.php" '{"action":"status"}' "Content-Type: application/json" "X-Settings-Request: 1" "Origin: http://evil.example"
expect "[ '$code' = 403 ] && echo \"\$body\" | grep -q 'other websites'" "another site's Origin is refused"
raw POST "/apps/$guard_app/api.php" '{"action":"status"}' "Content-Type: application/json" "X-Settings-Request: 1" "Referer: http://evil.example/page"
expect "[ '$code' = 403 ]" "another site's Referer is refused"
raw POST "/apps/$guard_app/api.php" '{"action":"status"}' "Content-Type: text/plain" "X-Settings-Request: 1" "Origin: $ORIGIN"
expect "[ '$code' = 415 ]" "a body that isn't JSON is refused"
padding=$(head -c 20000 /dev/zero | tr '\0' a)
api "$guard_app" "{\"action\":\"status\",\"padding\":\"$padding\"}"
expect "[ '$code' = 413 ]" "an oversized body is refused"
raw POST "/apps/$guard_app/./api.php" '{"action":"status"}' "Content-Type: application/json" "X-Settings-Request: 1" "Origin: $ORIGIN"
expect "[ '$code' = 403 ]" "a path with /./ in it is refused"
raw POST "//./apps/$guard_app/api.php" '{"action":"status"}' "Content-Type: application/json" "X-Settings-Request: 1" "Origin: $ORIGIN"
expect "[ '$code' = 403 ]" "so is //./apps/..., which a URL parser reads as a host and /apps/..."
mkdir -p "/var/www/$guard_app"
ln -s "$NAS_PROG/$guard_app/web/api.php" "/var/www/$guard_app/api.php"
raw POST "/$guard_app/api.php" '{"action":"status"}' "Content-Type: application/json" "X-Settings-Request: 1" "Origin: $ORIGIN"
expect "[ '$code' = 403 ] && echo \"\$body\" | grep -q 'through the dashboard'" "a copy outside /apps (no login there) refuses to work"
rm -rf "/var/www/$guard_app"
api "$guard_app" '{"action":"nope"}'
expect "[ '$code' = 400 ]" "an unknown action is refused"

# Each app's own checks. A public repository holds only its app's file.
for app in $apps; do
    # shellcheck source=/dev/null
    . "$(dirname "$0")/web-sim-$app.sh"
done

kill "$server_pid" 2> /dev/null
if [ "$failures" -ne 0 ]; then
    section "logs"
    tail -n 20 "$TR_HOME/log/app.log" "$TS_HOME/log/app.log" /tmp/php-server.log 2> /dev/null
fi
section "$failures failure(s)"
[ "$failures" -eq 0 ]
