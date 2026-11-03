#!/bin/sh
# start.sh — Run App: ON, and at boot for enabled apps.
# Probe only: logs the call and changes nothing.

here=$(dirname "$0")
[ -r "$here/probe.sh" ] && . "$here/probe.sh" && probe "$@"
exit 0
