#!/bin/sh
# remove.sh <app folder>
# Uninstall: removes the dashboard page and the app folder. The probe log in
# .systemfile stays on purpose, so it can be read after uninstall.

here=$(dirname "$0")
[ -r "$here/probe.sh" ] && . "$here/probe.sh" && probe "$@"

app_dir=$1

[ -n "${PROBE_PACKAGE:-}" ] || exit 1

# /var/www/apps/<package> is where version 0.1.0 linked the page by mistake.
rm -rf "/var/www/$PROBE_PACKAGE" "/var/www/apps/$PROBE_PACKAGE"

# Only ever delete a folder that is really ours.
case "$app_dir" in
    */Nas_Prog/"$PROBE_PACKAGE")
        rm -rf "$app_dir"
        ;;
    *)
        echo "remove.sh: refusing to delete unexpected path: $app_dir" >&2
        exit 1
        ;;
esac
