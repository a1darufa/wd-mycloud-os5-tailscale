#!/bin/sh
# pre_inst.sh — named in WD's app manager; when it runs is unknown.
# Probe only: logs the call and changes nothing.

here=$(dirname "$0")
[ -r "$here/probe.sh" ] && . "$here/probe.sh" && probe "$@"
exit 0
