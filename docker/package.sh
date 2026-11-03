#!/usr/bin/env bash
# package.sh <app folder> <model> — runs inside the wd-os5-builder image.
#
# mksapkg-OS5 writes apkg.xml and apkg.sign into the package folder and puts
# its output next to it, so it never runs on the source tree. Instead we copy
# the app into a scratch staging folder, normalize file modes (the repo may be
# on NTFS, where modes are meaningless), package, verify, and copy the result
# to /work/dist.

set -euo pipefail

app=$1
model=$2
source_dir=/work/$app
dist_dir=/work/dist
# An OS5 .bin is a 204-byte header followed by a tar.gz. The header starts with
# the magic "GrandTeZ" and its last 4 bytes hold the payload length
# (little-endian). Verified against mksapkg-OS5 output; the 200 bytes quoted
# on the wdpksrc wiki apply to OS3 packages.
header_bytes=204
header_magic=GrandTeZ

fail() {
    echo "package.sh: $*" >&2
    exit 1
}

rc_field() {
    awk -F':' -v key="$1" '$1 == key { sub(/^[ \t]+/, "", $2); sub(/[ \t\r]+$/, "", $2); print $2 }' \
        "$source_dir/apkg.rc"
}

check_source() {
    [[ -f $source_dir/apkg.rc ]] || fail "$source_dir/apkg.rc not found"
    [[ $package == "$(basename "$app")" ]] \
        || fail "Package '$package' in apkg.rc must match folder name '$(basename "$app")'"
    [[ -n $version ]] || fail "Version missing in apkg.rc"

    # busybox sh on the NAS chokes on CRLF; catch it here, not on the device.
    local crlf_files
    crlf_files=$(grep -rlI $'\r' "$source_dir" || true)
    [[ -z $crlf_files ]] || fail "CRLF line endings in: $crlf_files"
}

stage_package() {
    cp -r "$source_dir" "$stage_dir/$package"
    find "$stage_dir/$package" -type d -exec chmod 755 {} +
    find "$stage_dir/$package" -type f -exec chmod 644 {} +
    find "$stage_dir/$package" -type f -name '*.sh' -exec chmod 755 {} +
    # Executables without an .sh suffix (daemons, CLIs) live in bin/.
    if [[ -d $stage_dir/$package/bin ]]; then
        find "$stage_dir/$package/bin" -type f -exec chmod 755 {} +
    fi
}

# WD's ARM kernels use large memory pages; a binary or library whose
# segments aren't aligned to them segfaults on the NAS (tools/check-elf-alignment.sh).
check_elf_alignment() {
    local files
    mapfile -t files < <(find "$stage_dir/$package" -type f)
    sh /work/tools/check-elf-alignment.sh "${files[@]}" || fail "ARM binaries the NAS can't load"
}

run_packager() {
    (cd "$stage_dir/$package" && mksapkg-OS5 -s -m "$model") > "$stage_dir/mksapkg.log" 2>&1 \
        || { cat "$stage_dir/mksapkg.log" >&2; fail "mksapkg-OS5 failed"; }

    # mksapkg names its output "<model>_<package>_<version>.bin(<date>)".
    local produced
    produced=$(find "$stage_dir" -maxdepth 1 -name "${model}_${package}_${version}.bin*" | head -1)
    [[ -n $produced ]] || { cat "$stage_dir/mksapkg.log" >&2; fail "no .bin produced"; }
    mv "$produced" "$bin_path"
}

verify_bin() {
    [[ $(head -c ${#header_magic} "$bin_path") == "$header_magic" ]] \
        || fail "header magic '$header_magic' not found"

    local payload_bytes declared_bytes
    payload_bytes=$(( $(stat -c %s "$bin_path") - header_bytes ))
    declared_bytes=$(od -An -t u4 -j $((header_bytes - 4)) -N 4 "$bin_path" | tr -d ' ')
    [[ $declared_bytes == "$payload_bytes" ]] \
        || fail "header declares $declared_bytes payload bytes, file has $payload_bytes"

    tail -c +$((header_bytes + 1)) "$bin_path" | tar -tzvf - > "$contents_path" \
        || fail "payload after the ${header_bytes}-byte header is not a valid tar.gz"

    local required
    for required in apkg.rc apkg.xml apkg.sign install.sh init.sh start.sh stop.sh remove.sh; do
        grep -q " $package/$required\$" "$contents_path" || fail "$required missing from the .bin"
    done

    local not_executable
    not_executable=$(awk -v prefix="$package/" '
        ($6 ~ ("^" prefix ".*\\.sh$") || $6 ~ ("^" prefix "bin/.")) && $1 !~ /^-rwx/ { print $6 }
    ' "$contents_path")
    [[ -z $not_executable ]] || fail "not executable in the .bin: $not_executable"
}

package=$(rc_field Package)
version=$(rc_field Version)
check_source

stage_dir=$(mktemp -d)
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$dist_dir"
bin_name="${model}_${package}_${version}.bin"
bin_path="$dist_dir/$bin_name"
contents_path="$dist_dir/$bin_name.contents.txt"

stage_package
check_elf_alignment
run_packager
verify_bin
(cd "$dist_dir" && sha256sum "$bin_name" > "$bin_name.sha256")

echo "built   dist/$bin_name ($(stat -c %s "$bin_path") bytes)"
echo "sha256  $(cut -d' ' -f1 "$dist_dir/$bin_name.sha256")"
echo "files   $(wc -l < "$contents_path") (listing in dist/$bin_name.contents.txt)"
