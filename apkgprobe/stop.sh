#!/bin/sh
# stop.sh — Run App: OFF.
# Probe only: logs the call and changes nothing.

here=$(dirname "$0")
[ -r "$here/probe.sh" ] && . "$here/probe.sh" && probe "$@"
exit 0
