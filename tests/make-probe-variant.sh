#!/usr/bin/env bash
# make-probe-variant.sh <package name> <dashboard name>
#
# Creates build/<package>/, a copy of the apkgprobe test app under another
# package name, so two probes can be installed side by side (for example one
# ON and one OFF across a reboot). The probe scripts read their package name
# from apkg.rc, so only metadata, icon names and page text change here.
#
# Usage (from WSL, repo root):
#   tests/make-probe-variant.sh apkgprobe2 "APKG Probe 2"
#   ./build.sh build/apkgprobe2

set -euo pipefail

name=${1:?usage: tests/make-probe-variant.sh <package name> <dashboard name>}
show_name=${2:?usage: tests/make-probe-variant.sh <package name> <dashboard name>}
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
target=$repo_dir/build/$name

if [[ ! $name =~ ^[a-z][a-z0-9]*$ || $name == apkgprobe ]]; then
    echo "make-probe-variant.sh: package name must be lowercase letters/digits and not 'apkgprobe'" >&2
    exit 1
fi

rm -rf "$target"
mkdir -p "$repo_dir/build"
cp -r "$repo_dir/apkgprobe" "$target"

mv "$target/apkgprobe.png" "$target/$name.png"
mv "$target/web/apkgprobe.png" "$target/web/$name.png"

sed -i \
    -e "s/^Package:.*/Package:\t$name/" \
    -e "s/^AddonShowName:.*/AddonShowName:\t$show_name/" \
    -e "s/^Icon:.*/Icon:\t$name.png/" \
    -e "s#\.systemfile/apkgprobe#.systemfile/$name#" \
    "$target/apkg.rc"
sed -i \
    -e "s#<title>APKG Probe</title>#<title>$show_name</title>#" \
    -e "s#<h1>APKG Probe</h1>#<h1>$show_name</h1>#" \
    -e "s#\.systemfile/apkgprobe/#.systemfile/$name/#" \
    "$target/web/index.html"

echo "created build/$name (build it with: ./build.sh build/$name)"
