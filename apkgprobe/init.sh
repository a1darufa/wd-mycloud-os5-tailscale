#!/bin/sh
# init.sh <app folder>
# Links the app's web page into the dashboard and leaves a marker in the app
# folder. If the marker is still there after an upgrade, upgrades keep the
# folder; if it is gone, they wipe it.

here=$(dirname "$0")
[ -r "$here/probe.sh" ] && . "$here/probe.sh" && probe "$@"

app_dir=$1

if [ -z "${PROBE_PACKAGE:-}" ] || [ ! -d "$app_dir" ]; then
    echo "init.sh: probe.sh not loaded or app folder not found: $app_dir" >&2
    exit 1
fi

# With CenterType 0 the dashboard loads the icon, desc.xml and AddonIndexPage
# from /<package>/ (= /var/www/<package>/); /apps/ is only used for CenterType 1.
web_dir=/var/www/$PROBE_PACKAGE

mkdir -p "$web_dir"
ln -sf "$app_dir"/web/* "$web_dir"/
# Lets the dashboard page link straight to the log.
ln -sf "$PROBE_LOG" "$web_dir/probe.txt"

if [ ! -f "$app_dir/.probe-marker" ]; then
    echo "created $(date '+%Y-%m-%d %H:%M:%S') by version $(probe_version)" > "$app_dir/.probe-marker"
fi
