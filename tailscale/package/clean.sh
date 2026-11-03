#!/bin/sh
# clean.sh <app folder> — before remove.sh, and at shutdown. Removes the
# dashboard page links only; never touches the daemon.

. "$(dirname "$0")/lib.sh"

ts_unlink_web
exit 0
