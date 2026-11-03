#!/usr/bin/env bash
# bump.sh — propose a new pin for tailscale/upstream.env.
#
# Usage (from WSL, repo root):
#   tailscale/bump.sh            show the latest stable release and its SHA256
#   tailscale/bump.sh --write    also rewrite upstream.env with them
#
# The hash comes from the .sha256 file Tailscale publishes next to the tarball.
# That only proves integrity against the same server, which is why the pin is
# a reviewed, committed value rather than something the build fetches.
# Remember to update the Version in tailscale/package/apkg.rc to match.

set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
env_file=$repo_dir/tailscale/upstream.env

latest=$(curl --fail --silent --show-error 'https://pkgs.tailscale.com/stable/?mode=json' \
    | grep -o '"TarballsVersion": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
if [[ -z $latest ]]; then
    echo "bump.sh: could not read the latest version" >&2
    exit 1
fi

sha256=$(curl --fail --silent --show-error \
    "https://pkgs.tailscale.com/stable/tailscale_${latest}_arm.tgz.sha256" | tr -d '[:space:]')
if [[ ! $sha256 =~ ^[0-9a-f]{64}$ ]]; then
    echo "bump.sh: unexpected .sha256 content: $sha256" >&2
    exit 1
fi

echo "latest stable: $latest"
echo "sha256:        $sha256"

if [[ ${1:-} == --write ]]; then
    sed -i \
        -e "s/^TAILSCALE_VERSION=.*/TAILSCALE_VERSION=$latest/" \
        -e "s/^TAILSCALE_SHA256=.*/TAILSCALE_SHA256=$sha256/" \
        "$env_file"
    echo "updated $env_file; now set Version in tailscale/package/apkg.rc to $latest-1"
fi
