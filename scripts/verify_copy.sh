#!/usr/bin/env bash
# Did every file survive the copy, byte for byte?
#
#   scripts/verify_copy.sh <source-dir> <copy-dir>
#
# Compares each file under <source-dir> with its counterpart under <copy-dir>
# and, for anything that differs, reports the first differing byte offset, its
# block alignment, and whether the wrong bytes are zeros. That is the part a
# checksum cannot tell you, and the part that says which layer is at fault:
# block-aligned zeros point at an extent conversion, a shifted offset at
# mapping, a ragged few bytes at something lower.
#
# Read the copy COLD -- eject and replug the volume first, or the page cache
# answers from the bytes just written and every file looks perfect. This is the
# easiest way to get a verification that cannot fail.
set -uo pipefail

SRC="${1:-}"
DST="${2:-}"
if [ -z "$SRC" ] || [ -z "$DST" ]; then
    echo "usage: $0 <source-dir> <copy-dir>" >&2
    exit 2
fi
[ -d "$SRC" ] || { echo "no such directory: $SRC" >&2; exit 2; }
[ -d "$DST" ] || { echo "no such directory: $DST" >&2; exit 2; }

total=0; same=0; missing=0; sized=0; differ=0

# -print0 / read -d '' so spaces and unicode in names survive; this corpus is
# full of both.
while IFS= read -r -d '' f; do
    rel="${f#"$SRC"/}"
    dst="$DST/$rel"
    total=$((total + 1))

    if [ ! -f "$dst" ]; then
        printf 'MISSING   %s\n' "$rel"
        missing=$((missing + 1))
        continue
    fi

    ssz=$(stat -f %z "$f"   2>/dev/null || echo -1)
    dsz=$(stat -f %z "$dst" 2>/dev/null || echo -2)
    if [ "$ssz" != "$dsz" ]; then
        printf 'SIZE      %s  (%s bytes -> %s)\n' "$rel" "$ssz" "$dsz"
        sized=$((sized + 1))
        continue
    fi

    sh=$(shasum -a 256 "$f"   | cut -d' ' -f1)
    dh=$(shasum -a 256 "$dst" | cut -d' ' -f1)
    if [ "$sh" = "$dh" ]; then
        same=$((same + 1))
        continue
    fi

    differ=$((differ + 1))
    # cmp reports the first difference as "... differ: char N, line M", and
    # char is 1-based, so the byte offset is one less.
    off=$(cmp "$f" "$dst" 2>/dev/null | sed -nE 's/.*char ([0-9]+).*/\1/p')
    if [ -n "$off" ]; then
        off=$((off - 1))
        aligned=$([ $((off % 4096)) -eq 0 ] && echo "4096-aligned" || echo "not block-aligned")
        byte=$(dd if="$dst" bs=1 skip="$off" count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
        shape=$([ "${byte:-1}" = "0" ] && echo "a zero" || echo "non-zero ($byte)")
        printf 'DIFFERS   %s\n          first at byte %s (block %s, %s); that byte is %s\n' \
               "$rel" "$off" "$((off / 4096))" "$aligned" "$shape"
    else
        printf 'DIFFERS   %s  (offset not determined)\n' "$rel"
    fi
done < <(find "$SRC" -type f -print0)

echo
echo "checked $total file(s): $same identical, $differ different, $missing missing, $sized wrong size"
[ $((differ + missing + sized)) -eq 0 ] && { echo "every file survived the copy"; exit 0; }
echo "the copy did not preserve every file"
exit 1
