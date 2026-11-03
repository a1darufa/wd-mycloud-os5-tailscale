#!/usr/bin/env bash
# web-preview.sh — try the settings pages in a browser against stub daemons.
# Builds the stub packages of the apps in this checkout, installs them in the
# web test container, and serves it on http://localhost:8080 until you stop
# it (Ctrl+C). Tailscale starts as a new node; any auth key ending in "good"
# logs it in.
#
# Usage (from WSL, repo root):
#   tests/web-preview.sh
# then open http://localhost:8080/apps/transmission4/settings.html
#       or http://localhost:8080/apps/tailscale/settings.html

set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_dir"

package_version() {
    awk '$1 == "Version:" { print $2 }' "$1/package/apkg.rc"
}

docker build --quiet --tag wd-os5-web-test docker/web-test > /dev/null
stubs=()
if [[ -d tailscale ]]; then
    tailscale/build.sh --stub running > /dev/null
    stubs+=("/work/dist/MyCloudEX2Ultra_tailscale_$(package_version tailscale)-stub-running.bin")
fi
if [[ -d transmission4 ]]; then
    transmission4/build.sh --stub > /dev/null
    stubs+=("/work/dist/MyCloudEX2Ultra_transmission4_$(package_version transmission4)-stub.bin")
fi
exec docker run --rm --init --publish 127.0.0.1:8080:8080 --volume "$repo_dir:/work:ro" wd-os5-web-test \
    sh /work/tests/web-sim.sh "${stubs[@]}" --serve
