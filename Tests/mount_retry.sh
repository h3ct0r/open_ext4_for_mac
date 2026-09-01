# Mounting an ext4 volume, allowing for the one transient that is not ours.
#
# Sourced rather than folded into lib.sh because the two suites that most need
# it -- run_mount_crash_tests.sh and run_mount_luks_tests.sh -- carry their own
# ok/bad/note and cannot take all of lib.sh without a rewrite. One function,
# no globals, no collisions.
#
# The transient: unmounting prods DiskArbitration into re-examining the device,
# and a mount issued into that re-probe loses. It is not a driver fault, and
# run_newfs_tests.sh has said so, and retried, since it first hit it. The
# mounted crash suite never learned the same lesson, and it cost a soak round
# eight rounds in -- "could not remount after setting the flags", with nothing
# in any log because the mount never reached the extension.
#
# Anything that unmounts and then mounts the same device again should use this.
# A first attach of a fresh device does not need it, and passing through here
# costs nothing when the first attempt succeeds.
#
#   mount_ext4_retry <bsd-name-without-/dev> <mountpoint> [attempts] [gap-secs]
#
# Echoes the last error text (empty on success), returns 0 on success, and
# sets MOUNT_RETRY_ATTEMPTS to how many tries it took.
#
# The attempt count is a global rather than part of the output because callers
# capture stdout to get the error text, and a "needed two goes" note written
# to stderr is a note nobody reads -- which is the same swallowing this whole
# file exists to stop. A mount that needed a retry is worth printing: one is
# the documented transient, three in a row is something else.

mount_ext4_retry() {
    local dev="$1" mnt="$2" attempts="${3:-5}" gap="${4:-2}"
    local out="" i
    MOUNT_RETRY_ATTEMPTS=0

    for (( i = 1; i <= attempts; i++ )); do
        MOUNT_RETRY_ATTEMPTS=$i
        if out=$(mount -F -t ext4 "$dev" "$mnt" 2>&1); then
            return 0
        fi
        # A disabled module never becomes enabled by waiting, and retrying it
        # five times turns one clear message into ten seconds of silence.
        case "$out" in
            *"is disabled"*) break ;;
        esac
        [ "$i" -lt "$attempts" ] && sleep "$gap"
    done

    printf '%s' "$out"
    return 1
}
