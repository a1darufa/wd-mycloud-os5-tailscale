#!/usr/bin/env bash
# fetch.sh — download the pinned Tailscale ARM tarball and verify it.
#
# Usage (from WSL, repo root):  tailscale/fetch.sh
# Output: downloads/tailscale_<version>_arm.tgz, verified against the SHA256
# pinned in tailscale/upstream.env. A file that doesn't match is deleted and
# the script fails; an already-downloaded file that matches is reused.

set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tailscale/upstream.env
source "$repo_dir/tailscale/upstream.env"

tarball=tailscale_${TAILSCALE_VERSION}_arm.tgz
url=https://pkgs.tailscale.com/stable/$tarball
target=$repo_dir/downloads/$tarball

matches_pin() {
    [[ $(sha256sum "$1" | cut -d' ' -f1) == "$TAILSCALE_SHA256" ]]
}

mkdir -p "$repo_dir/downloads"

if [[ -f $target ]] && matches_pin "$target"; then
    echo "fetch.sh: $tarball already downloaded and verified"
    exit 0
fi

echo "fetch.sh: downloading $url"
curl --fail --location --silent --show-error --output "$target.part" "$url"

if ! matches_pin "$target.part"; then
    echo "fetch.sh: SHA256 mismatch for $tarball" >&2
    echo "  expected $TAILSCALE_SHA256" >&2
    echo "  got      $(sha256sum "$target.part" | cut -d' ' -f1)" >&2
    rm -f "$target.part"
    exit 1
fi

mv -f "$target.part" "$target"
echo "fetch.sh: $tarball verified ($(stat -c %s "$target") bytes)"
