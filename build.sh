#!/usr/bin/env bash
# build.sh — package an app folder into a .bin you can install from the NAS
# web interface (Apps → Install an app manually).
#
# Usage (from WSL, in the repo root):
#   ./build.sh <app folder> [model]
#   ./build.sh apkgprobe
#   ./build.sh build/apkgprobe2     (generated variants live in build/)
#
# Output: dist/<model>_<package>_<version>.bin, plus .sha256 and a contents
# listing. Packaging runs in the wd-os5-builder Docker image with no network.

set -euo pipefail

app=${1:?usage: ./build.sh <app folder> [model]}
model=${2:-MyCloudEX2Ultra}
repo_dir=$(cd "$(dirname "$0")" && pwd)
image=wd-os5-builder

if [[ ! -f $repo_dir/$app/apkg.rc ]]; then
    echo "build.sh: $app/apkg.rc not found" >&2
    exit 1
fi

# Cached after the first run, so this is quick.
docker build --quiet --tag "$image" "$repo_dir/docker" > /dev/null

docker run --rm --network none \
    --volume "$repo_dir:/work" \
    "$image" bash /work/docker/package.sh "$app" "$model"
