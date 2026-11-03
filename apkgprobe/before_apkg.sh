#!/bin/sh
# before_apkg.sh — run by the upload step before install (WD marks it 'DO NOT REMOVE').
# Probe only: logs the call and changes nothing.

here=$(dirname "$0")
[ -r "$here/probe.sh" ] && . "$here/probe.sh" && probe "$@"
exit 0
