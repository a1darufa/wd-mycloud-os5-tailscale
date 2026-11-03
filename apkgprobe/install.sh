#!/bin/sh
# install.sh <unpacked package folder> <Nas_Prog folder>
# Copies the package into Nas_Prog, the same way WD's own apps do.

here=$(dirname "$0")
[ -r "$here/probe.sh" ] && . "$here/probe.sh" && probe "$@"

package_dir=$1
nas_prog=$2

if [ ! -d "$package_dir" ] || [ ! -d "$nas_prog" ]; then
    echo "install.sh: expected <package folder> <Nas_Prog folder>, got: $*" >&2
    exit 1
fi

cp -rf "$package_dir" "$nas_prog"
