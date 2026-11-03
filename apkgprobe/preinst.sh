#!/bin/sh
# preinst.sh — before install or upgrade (WD's apps back up their config here).
# Probe only: logs the call and changes nothing.

here=$(dirname "$0")
[ -r "$here/probe.sh" ] && . "$here/probe.sh" && probe "$@"
exit 0
