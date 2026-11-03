#!/bin/sh
# check-elf-alignment.sh <file>... — fail unless every ARM ELF file given can
# be loaded by WD's ARM kernels. Files that aren't ELF, or are built for
# another CPU, are skipped.
#
# The EX2 Ultra's kernel uses 32 KB memory pages (README.md). A
# binary or library loads only if each LOAD segment starts on a page: its
# alignment is a multiple of the page size, and its address and file offset
# are equal modulo the page size. Otherwise it segfaults before main(), which
# qemu on a 4 KB-page PC can't show. This requires 64 KB, as in WD's own
# binaries, so it holds on 32 KB and 64 KB kernels alike.

required=65536
checked=0
failed=0

for file in "$@"; do
    machine=$(readelf -h "$file" 2> /dev/null | sed -n 's/^ *Machine: *//p')
    case $machine in
        ARM | AArch64) ;;
        *) continue ;;
    esac
    checked=$((checked + 1))
    misaligned=$(readelf -lW "$file" | awk '$1 == "LOAD" { print $2, $3, $NF }' \
        | while read -r offset vaddr align; do
            if [ $((align % required)) -ne 0 ] || [ $(((vaddr - offset) % required)) -ne 0 ]; then
                echo "    LOAD offset $offset, address $vaddr, alignment $align"
            fi
        done)
    if [ -n "$misaligned" ]; then
        echo "check-elf-alignment.sh: $file has segments that aren't 64 KB-aligned:" >&2
        echo "$misaligned" >&2
        failed=$((failed + 1))
    fi
done

if [ "$failed" -ne 0 ]; then
    echo "check-elf-alignment.sh: $failed of $checked ARM ELF files would segfault on the NAS" >&2
    exit 1
fi
echo "check-elf-alignment.sh: $checked ARM ELF files, every LOAD segment 64 KB-aligned"
