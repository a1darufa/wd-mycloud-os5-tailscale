#!/bin/sh
# simulate-lifecycle.sh <path to .bin> — runs inside a busybox container.
#
# Rough stand-in for the NAS: unpacks a built .bin the way the app manager
# stages it (Nas_Prog/_install/<pkg>), then runs the lifecycle scripts in a
# plausible order: install, init, start, stop, clean, remove. Catches shell
# errors and wrong paths before anything touches the real device. It does not
# prove WD's real call order; the probe app on the NAS does that.
#
# Usage (from WSL, repo root):
#   docker run --rm --network none -v "$PWD:/work:ro" busybox:1.30.1 \
#       sh /work/tests/simulate-lifecycle.sh /work/dist/<file>.bin

set -eu

bin_file=$1
header_bytes=204
nas_prog=/mnt/HD/HD_a2/Nas_Prog
staging=$nas_prog/_install

mkdir -p "$staging" /mnt/HD/HD_a2/.systemfile /var/www/apps
tail -c +$((header_bytes + 1)) "$bin_file" | tar -xzf - -C "$staging"
package=$(ls "$staging")
app_dir=$nas_prog/$package

step() {
    echo "--- $*"
    "$@"
}

expect() {
    if eval "$1"; then
        echo "ok:   $2"
    else
        echo "FAIL: $2"
        failures=$((failures + 1))
    fi
}

failures=0
[ -x "$staging/$package/before_apkg.sh" ] && step "$staging/$package/before_apkg.sh"
step "$staging/$package/install.sh" "$staging/$package" "$nas_prog"
expect "[ -f '$app_dir/apkg.rc' ]" "install.sh copied the package into Nas_Prog"

step "$app_dir/init.sh" "$app_dir"
# CenterType 0 apps: the dashboard serves the page, icon and desc.xml from /<package>/.
expect "[ -f /var/www/$package/desc.xml ]" "init.sh linked the web page into /var/www/$package"

step "$app_dir/start.sh" "$app_dir"
step "$app_dir/stop.sh" "$app_dir"
step "$app_dir/clean.sh" "$app_dir"
step "$app_dir/remove.sh" "$app_dir"
expect "[ ! -d '$app_dir' ]" "remove.sh deleted the app folder"
expect "[ ! -d /var/www/$package ]" "remove.sh deleted the web page"

log=/mnt/HD/HD_a2/.systemfile/$package/probe.log
if [ -f "$log" ]; then
    expect "[ \"\$(grep -c '^=== ' '$log')\" -ge 6 ]" "probe log has an entry per script"
    echo "--- probe log"
    cat "$log"
fi

echo "--- $failures failure(s)"
[ "$failures" -eq 0 ]
