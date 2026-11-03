#!/bin/sh
# clean.sh <app folder>
# Removes the dashboard page links, as WD's own clean.sh scripts do.

here=$(dirname "$0")
[ -r "$here/probe.sh" ] && . "$here/probe.sh" && probe "$@"

[ -n "${PROBE_PACKAGE:-}" ] || exit 1

# /var/www/apps/<package> is where version 0.1.0 linked the page by mistake.
rm -rf "/var/www/$PROBE_PACKAGE" "/var/www/apps/$PROBE_PACKAGE"
