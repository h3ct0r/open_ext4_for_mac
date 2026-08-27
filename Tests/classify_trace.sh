#!/usr/bin/env bash
# What did the crash actually tear? Turn an EXT4DUMP_TRACE into a diagnosis.
#
# A damaged volume says almost nothing about its cause: e2fsck reports what is
# inconsistent, not which write landed out of order to make it so. The trace
# from the write-cache model says exactly which writes were applied and which
# were dropped at the cut -- but as raw offsets. This maps every offset to what
# lives there:
#
#   FSSB   the filesystem superblock (bytes 1024-3072)
#   JSB    the journal's own superblock (the journal file's first block)
#   JLOG   the rest of the journal file -- descriptors, data, commit blocks
#   HOME   everything else: metadata and data at their home locations
#
# and prints, per class, what was applied and what was dropped, plus the two
# diagnoses this project actually needs to tell apart:
#
#   * the journal superblock (tail advance) applied while checkpoint HOME
#     writes were dropped -- the log no longer covers a change the filesystem
#     never received
#   * JLOG applied while the JSB was dropped -- new records overwrote live log
#     space before the tail advance that freed it landed
#
# Usage: classify_trace.sh <pristine-image> <trace-file>
# The image must be the fixture the torn run STARTED from -- the journal's
# physical location is what is being read, and the journal does not move.
set -uo pipefail
export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

IMG="${1:?usage: classify_trace.sh <pristine-image> <trace-file>}"
TRACE="${2:?usage: classify_trace.sh <pristine-image> <trace-file>}"
[ -f "$IMG" ]   || { echo "no such image: $IMG" >&2; exit 1; }
[ -f "$TRACE" ] || { echo "no such trace: $TRACE" >&2; exit 1; }

BS=$(dumpe2fs -h "$IMG" 2>/dev/null | sed -n 's/^Block size: *//p')
[ -n "$BS" ] || { echo "cannot read block size from $IMG" >&2; exit 1; }

# The journal's physical blocks, from its extent tree. Logical block 0 is the
# journal superblock; everything after is log space.
# mke2fs journals are extent-mapped; our own mkfs lays the journal down with
# indirect blocks, so both listing shapes have to parse. They look alike --
# "(0-11):521-532, (IND):534, (12):533" -- except BLOCKS: has non-numeric
# logical parts like (IND), which are the mapping blocks themselves.
EXTENTS=$(debugfs -R "stat <8>" "$IMG" 2>/dev/null \
          | sed -n '/^EXTENTS:$/,$p;/^BLOCKS:$/,$p' | tail -n +2 | tr '\n' ' ')
[ -n "$EXTENTS" ] || { echo "cannot read journal block map from $IMG" >&2; exit 1; }

awk -v bs="$BS" -v extents="$EXTENTS" '
BEGIN {
    nrange = 0; jsb_block = -1
    # "(0-9):15-24, (10-24):26-40, ..."  -- logical range : physical range
    # BSD awk: no match-with-captures, so split by hand.
    # Each part looks like "(0-9):15-24" or "(25):2064".
    n = split(extents, parts, /,[ \t]*/)
    for (i = 1; i <= n; i++) {
        part = parts[i]
        gsub(/[()\n]/, "", part)
        if (split(part, halves, ":") != 2) continue
        nl = split(halves[1], lparts, "-")
        # (IND)/(DIND) entries are the indirect mapping blocks: inside the
        # journal file, not log space, but close enough to count as JLOG.
        numeric = (lparts[1] ~ /^[0-9]+$/)
        lo_l = numeric ? lparts[1] + 0 : -1
        np = split(halves[2], pparts, "-")
        p1 = pparts[1] + 0
        p2 = (np == 2) ? pparts[2] + 0 : p1
        if (p1 <= 0) continue
        nrange++; rlo[nrange] = p1; rhi[nrange] = p2
        if (lo_l == 0) jsb_block = p1
    }
    if (nrange == 0) { print "could not parse journal extents" > "/dev/stderr"; exit 1 }
}
function class_of(off, len,   blk) {
    # The fs superblock is written by byte offset, not block.
    if (off < 1024 + 2048 && off + len > 1024) return "FSSB"
    blk = int(off / bs)
    if (blk == jsb_block) return "JSB"
    for (i = 1; i <= nrange; i++)
        if (blk >= rlo[i] && blk <= rhi[i]) return "JLOG"
    return "HOME"
}
/^TRC BARRIER/        { barriers++ ; next }
/^TRC CRASH /         { crash_line = $0; next }
/^TRC (CRASH-APPLY|CRASH-DROP|EVICT) seq=/ {
    ev = substr($2, 1, 99); sub(/^TRC /, "", $0)
    split($2, a, "="); seq = a[2]
    split($3, a, "="); off = a[2] + 0
    split($4, a, "="); len = a[2] + 0
    cls = class_of(off, len)
    if ($1 == "CRASH-APPLY")     { applied[cls]++; if (cls != "HOME") detail_a[cls] = detail_a[cls] " " seq }
    else if ($1 == "CRASH-DROP") { dropped[cls]++; if (cls != "HOME") detail_d[cls] = detail_d[cls] " " seq }
    else                         { evicted[cls]++ }
    next
}
END {
    if (crash_line != "") print crash_line
    printf "barriers observed: %d\n\n", barriers
    printf "%-6s %10s %10s %10s\n", "class", "applied", "dropped", "evicted"
    split("FSSB JSB JLOG HOME", order, " ")
    for (i = 1; i <= 4; i++) {
        c = order[i]
        printf "%-6s %10d %10d %10d\n", c, applied[c]+0, dropped[c]+0, evicted[c]+0
    }
    print ""
    if (applied["JSB"] > 0 && (dropped["HOME"] > 0 || dropped["JLOG"] > 0))
        printf "DIAGNOSIS: JSB applied (seq%s) while %d HOME + %d JLOG writes dropped\n" \
               "  -> the tail advance landed; the checkpoint (or log) it vouches for did not.\n",
               detail_a["JSB"], dropped["HOME"]+0, dropped["JLOG"]+0
    if (dropped["JSB"] > 0 && applied["HOME"] > 0 && applied["JSB"] == 0)
        printf "DIAGNOSIS: JSB dropped (seq%s) while %d HOME writes landed\n" \
               "  -> the tail advance was lost; recovery starts from a stale tail,\n" \
               "     which is safe only while the old log range has not been reused --\n" \
               "     and a log that wrapped since has reused it.\n",
               detail_d["JSB"], applied["HOME"]+0
    if (applied["JLOG"] > 0 && dropped["JSB"] > 0)
        printf "DIAGNOSIS: JLOG applied while JSB dropped (seq%s)\n" \
               "  -> new log records landed in space whose freeing was never published.\n",
               detail_d["JSB"]
    if (applied["JSB"] == 0 && dropped["JSB"] == 0 && applied["JLOG"] + dropped["JLOG"] == 0)
        print "note: no journal-region writes were pending at the cut."
}' "$TRACE"
