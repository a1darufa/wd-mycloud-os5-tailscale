#!/usr/bin/env bash
# render-icons.sh — render each app's icon.svg to the 96x96 PNGs its package
# ships (the dashboard tile and the app list). Run it after editing an
# icon.svg and commit both. Uses rsvg-convert in a throwaway Alpine container.
#
# Usage (from WSL, repo root):
#   tools/render-icons.sh

set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)

docker run --rm -v "$repo_dir:/work" -w /work alpine:3.24 sh -euc '
    apk add --no-cache -q rsvg-convert
    for app in tailscale transmission4; do
        [ -d "$app" ] || continue
        rsvg-convert --width 96 --height 96 "$app/icon.svg" -o "$app/package/$app.png"
        cp "$app/package/$app.png" "$app/package/web/$app.png"
        echo "rendered $app/package/$app.png and web/$app.png"
    done
'
