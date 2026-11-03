#!/bin/sh
# install.sh <unpacked package folder> <Nas_Prog folder>
# Copies the package into Nas_Prog, the same way WD's own apps do. Nothing
# else: state lives outside the app folder and is handled at cutover.

. "$(dirname "$0")/lib.sh"

package_dir=$1
nas_prog=$2

if [ ! -d "$package_dir" ] || [ ! -d "$nas_prog" ]; then
    ts_log "expected <package folder> <Nas_Prog folder>, got: $*"
    exit 1
fi

cp -rf "$package_dir" "$nas_prog"
ts_log "installed version $(awk '$1 == "Version:" { print $2 }' "$package_dir/apkg.rc")"
