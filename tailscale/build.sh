#!/usr/bin/env bash
# build.sh — build the Tailscale app .bin.
#
# Usage (from WSL, repo root):
#   tailscale/build.sh                 real package with the pinned Tailscale binaries
#   tailscale/build.sh --stub <mode>   test package whose binaries are the stubs in
#                                      tests/stubs (modes: running, quiet, starting,
#                                      crash, hang; see tests/stubs/tailscaled)
#
# Assembles build/<variant>/tailscale/ from tailscale/package/ plus bin/, then
# packages it with the repo's build.sh. Output lands in dist/.

set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tailscale/upstream.env
source "$repo_dir/tailscale/upstream.env"

fail() {
    echo "tailscale/build.sh: $*" >&2
    exit 1
}

stub_mode=""
if [[ ${1:-} == --stub ]]; then
    stub_mode=${2:?usage: tailscale/build.sh [--stub <mode>]}
    [[ $stub_mode =~ ^(running|quiet|starting|crash|hang)$ ]] || fail "unknown stub mode: $stub_mode"
fi

# The package ships a neutral icon (tailscale/icon.svg). A private icon in
# reference/, which never enters git history, replaces it when present: one
# drawn in the style of Tailscale's mark, pinned by SHA256. It's Tailscale's
# trademark, so builds with it are for your own NAS only.
private_icon=$repo_dir/reference/icons/tailscale.png
private_icon_sha256=820f6062cba7ef9165e1114954c0b29e12fbf700fc4f2292936346b5474a66e5

apply_private_icon() {
    [[ -f $private_icon ]] || return 0
    if [[ $(sha256sum < "$private_icon" | cut -d' ' -f1) != "$private_icon_sha256" ]]; then
        echo "tailscale/build.sh: $private_icon changed; keeping the neutral icon" >&2
        return 0
    fi
    cp "$private_icon" "$app_dir/tailscale.png"
    cp "$private_icon" "$app_dir/web/tailscale.png"
}

package_version=$(awk '$1 == "Version:" { print $2 }' "$repo_dir/tailscale/package/apkg.rc")
[[ $package_version == "$TAILSCALE_VERSION"-* ]] \
    || fail "apkg.rc Version '$package_version' must be '$TAILSCALE_VERSION-<revision>'"

variant=${stub_mode:+stub-$stub_mode}
variant=${variant:-release}
assembly_dir=$repo_dir/build/$variant
app_dir=$assembly_dir/tailscale

rm -rf "$assembly_dir"
mkdir -p "$assembly_dir"
cp -r "$repo_dir/tailscale/package" "$app_dir"
# The settings page's shared files (common/web) go next to the app's own.
cp "$repo_dir"/common/web/* "$app_dir/web/"
mkdir -p "$app_dir/bin"

if [[ -n $stub_mode ]]; then
    cp "$repo_dir/tests/stubs/tailscaled" "$repo_dir/tests/stubs/tailscale" "$app_dir/bin/"
    echo "$stub_mode" > "$app_dir/bin/stub-mode"
    # A distinct version and name, so a stub build can never be mistaken for
    # the real app in dist/ or in the dashboard.
    sed -i \
        -e "s/^Version:.*/Version:\t$package_version-stub-$stub_mode/" \
        -e "s/^AddonShowName:.*/AddonShowName:\tTailscale (TEST STUB: $stub_mode)/" \
        "$app_dir/apkg.rc"
else
    "$repo_dir/tailscale/fetch.sh"
    extract_dir=$(mktemp -d)
    trap 'rm -rf "$extract_dir"' EXIT
    tar -xzf "$repo_dir/downloads/tailscale_${TAILSCALE_VERSION}_arm.tgz" -C "$extract_dir"
    for binary in tailscale tailscaled; do
        source_binary=$extract_dir/tailscale_${TAILSCALE_VERSION}_arm/$binary
        file "$source_binary" | grep -q 'ELF 32-bit.*ARM' || fail "$binary is not a 32-bit ARM executable"
        cp "$source_binary" "$app_dir/bin/"
    done
fi

apply_private_icon
mkdir -p "$app_dir/licenses/app"
cp "$repo_dir/LICENSE" "$app_dir/licenses/app/"
"$repo_dir/build.sh" "${app_dir#"$repo_dir"/}"
