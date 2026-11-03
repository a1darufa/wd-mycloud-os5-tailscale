#!/usr/bin/env bash
# run-all.sh — the checks to run before every commit or release: stub
# packages of the apps in this checkout (Tailscale, Transmission 4, or both),
# their lifecycle simulations on BusyBox 1.30.1 (the NAS's own version: newer
# ones accept things it doesn't), the settings pages' web simulation (PHP
# 7.4, as on the NAS), PHP and JavaScript syntax, and ShellCheck. Needs
# Docker; no ARM emulation and no network (beyond pulling and building the
# images).
#
# Usage (from WSL, repo root):
#   tests/run-all.sh

set -uo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_dir" || exit 1
failed=()

package_version() {
    awk '$1 == "Version:" { print $2 }' "$1/package/apkg.rc"
}

# <name> <image> <simulation> <stub .bin>...: run a simulation in a container
# without network, and report its checks.
simulate() {
    local name=$1 image=$2 script=$3 output bin
    shift 3
    local bins=()
    for bin in "$@"; do
        bins+=("/work/dist/$bin")
    done
    output=$(docker run --rm --init --network none -v "$repo_dir:/work:ro" "$image" \
        sh "/work/tests/$script" "${bins[@]}" 2>&1)
    echo "$output" | grep -E '^FAIL'
    echo "$name: $(echo "$output" | grep -c '^ok:') checks passed, $(echo "$output" | tail -n 1 | sed 's/^=== //')"
    echo "$output" | tail -n 1 | grep -q '^=== 0 failure' || failed+=("$name simulation")
}

# Files of the repo (tracked or new) whose names match <regex>.
repo_files() {
    git ls-files --cached --others --exclude-standard | grep -E "$1" | grep -v '^apkgprobe/'
}

echo "== stub packages"
stubs=()
if [[ -d tailscale ]]; then
    tailscale/build.sh --stub running > /dev/null || failed+=("tailscale stub build")
    tailscale_stub="MyCloudEX2Ultra_tailscale_$(package_version tailscale)-stub-running.bin"
    stubs+=("$tailscale_stub")
fi
if [[ -d transmission4 ]]; then
    transmission4/build.sh --stub > /dev/null || failed+=("transmission4 stub build")
    transmission_stub="MyCloudEX2Ultra_transmission4_$(package_version transmission4)-stub.bin"
    stubs+=("$transmission_stub")
fi
[[ ${#stubs[@]} -gt 0 ]] || { echo "no app folder (tailscale/, transmission4/) here"; exit 1; }
docker build --quiet --tag wd-os5-web-test docker/web-test > /dev/null || failed+=("web test image")

echo "== simulations"
if [[ -d tailscale ]]; then
    simulate tailscale busybox:1.30.1 tailscale-sim.sh "$tailscale_stub"
fi
if [[ -d transmission4 ]]; then
    simulate transmission4 busybox:1.30.1 transmission-sim.sh "$transmission_stub"
fi
simulate "settings pages" wd-os5-web-test web-sim.sh "${stubs[@]}"

echo "== php and javascript syntax"
mapfile -t php_files < <(repo_files '\.php$')
if docker run --rm -v "$repo_dir:/work:ro" -w /work wd-os5-web-test \
    sh -c 'for file; do php -l "$file" > /dev/null || exit 1; done' lint "${php_files[@]}"; then
    echo "php -l: ${#php_files[@]} files clean"
else
    failed+=("php syntax")
fi
mapfile -t js_files < <(repo_files '\.js$')
if docker run --rm -v "$repo_dir:/work:ro" -w /work node:22-alpine \
    sh -c 'for file; do node --check "$file" || exit 1; done' check "${js_files[@]}"; then
    echo "node --check: ${#js_files[@]} files clean"
else
    failed+=("javascript syntax")
fi

echo "== shellcheck"
mapfile -t scripts < <(repo_files '\.sh$|^tests/stubs/')
if docker run --rm -v "$repo_dir:/mnt:ro" -w /mnt koalaman/shellcheck:stable -x -P SCRIPTDIR "${scripts[@]}"; then
    echo "shellcheck: ${#scripts[@]} scripts clean"
else
    failed+=(shellcheck)
fi

if [[ ${#failed[@]} -gt 0 ]]; then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "all checks passed"
