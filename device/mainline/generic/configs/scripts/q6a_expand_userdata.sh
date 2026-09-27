#!/system/bin/sh
# Q6A: grow userdata to fill the medium on first boot.
#
# WHY: the release image is deliberately small (a few GB) so that it can be written with
# Balena Etcher or dd on any operating system, with no partitioning step afterwards.
# Everything past the image is unused until this runs.
#
# HOW: two stages, each idempotent, so it self-corrects whatever state it finds.
#   1. The partition ends before the end of the disk -> move the backup GPT to the real
#      end, recreate the partition at full size, then reboot. The kernel cannot re-read a
#      partition table while one of its partitions is mounted, hence the reboot.
#   2. The filesystem is smaller than the partition -> grow it with resize2fs. ext4 can do
#      this while mounted, so no second reboot is needed.
# On every later boot both checks are false and the script exits immediately.
set -x
LOG=/data/local/tmp/q6a_expand.log
# Records that stage 1 has already asked for a reboot. See the guard in stage 1.
STAMP=/data/local/tmp/q6a_expand.rebooted
exec >>"$LOG" 2>&1
echo "=== $(date) expand check ==="

DEV=$(/system/bin/grep " /data " /proc/mounts | /system/bin/cut -d' ' -f1)
case "$DEV" in
  /dev/block/*) ;;
  *) echo "no block device for /data ($DEV) — nothing to do"; exit 0 ;;
esac

# Split the partition node into its parent disk and partition number.
case "$DEV" in
  *p[0-9]|*p[0-9][0-9]) PART=${DEV##*p}; DISK=${DEV%p*} ;;   # nvme0n1p3, mmcblk1p3
  *[0-9])               PART=$(echo "$DEV" | /system/bin/sed 's/.*[^0-9]//')
                        DISK=$(echo "$DEV" | /system/bin/sed 's/[0-9]*$//') ;;   # sda3
  *) echo "cannot parse $DEV"; exit 0 ;;
esac
echo "disk=$DISK part=$PART"

# Reads one field of the partition entry, e.g. part_field "Last sector".
#
# LONG OPTIONS ONLY. Android's sgdisk is built from external/gptfdisk without the short
# forms: -i, -e, -d and -n all come back as "sgdisk: invalid option". A script using them
# does nothing at all, and because an empty PART_END makes the stage 1 test below succeed,
# it then asks for a reboot on every single boot. That is exactly how the v2 release
# bricked itself, so the numeric guard underneath is as important as the option names.
part_field() {
    /system/bin/sgdisk --info="$PART" "$DISK" | /system/bin/grep "$1" | \
        /system/bin/sed 's/[^0-9]*\([0-9]*\).*/\1/'
}

# True only for a non-empty string of digits.
is_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

DISK_SECT=$(/vendor/bin/blockdev --getsz "$DISK") || exit 0
PART_END=$(part_field "Last sector")
if ! is_number "$DISK_SECT" || ! is_number "$PART_END"; then
    echo "cannot read geometry (disk_sectors='$DISK_SECT' part_end='$PART_END') - giving up"
    exit 0
fi
LAST_USABLE=$((DISK_SECT - 34))
echo "disk_sectors=$DISK_SECT part_end=$PART_END last_usable=$LAST_USABLE"

# Stage 1: the partition does not reach the end of the medium.
# The 64 MiB margin keeps us from churning on a partition that is already effectively full.
if [ "$PART_END" -lt $((LAST_USABLE - 131072)) ]; then
    # An unconditional reboot here would be dangerous: if writing the table fails for any
    # reason, every boot would request another reboot and the board would loop forever,
    # which is the worst failure mode a release image can have. Two guards prevent that.
    # First guard: a stamp file, so a reboot is never requested twice on the same medium.
    if [ -e "$STAMP" ]; then
        echo "partition still short, but $STAMP exists - refusing to reboot again"
        exit 0
    fi

    echo "growing partition $PART"
    NAME=$(/system/bin/sgdisk --info="$PART" "$DISK" | /system/bin/grep "Partition name" | \
        /system/bin/sed "s/.*'\(.*\)'.*/\1/")
    # Recreating the partition resets its type and unique GUID to sgdisk's defaults, so
    # both are carried over explicitly: the type because nothing should silently change a
    # partition's purpose, the unique GUID because a PARTUUID= reference to it (an fstab
    # entry, a kernel parameter) would otherwise stop resolving.
    TYPE=$(/system/bin/sgdisk --info="$PART" "$DISK" | /system/bin/grep "Partition GUID code" | \
        /system/bin/sed 's/[^:]*: *\([0-9A-Fa-f-]*\).*/\1/')
    UUID=$(/system/bin/sgdisk --info="$PART" "$DISK" | /system/bin/grep "Partition unique GUID" | \
        /system/bin/sed 's/[^:]*: *\([0-9A-Fa-f-]*\).*/\1/')
    echo "name=$NAME type=$TYPE uuid=$UUID"

    /system/bin/touch "$STAMP"
    /system/bin/sync
    /system/bin/sgdisk --move-second-header "$DISK"
    /system/bin/sgdisk --delete="$PART" "$DISK"
    # --largest-new rather than --new with an explicit range: after the delete above, the
    # free block this partition used to sit in runs to the end of the medium and is by far
    # the largest one, so there is no start sector to compute and get wrong.
    /system/bin/sgdisk --largest-new="$PART" --typecode="$PART:$TYPE" \
        --partition-guid="$PART:$UUID" --change-name="$PART:$NAME" "$DISK"
    /system/bin/sync

    # Second guard: only reboot once the table really changed on the medium. sgdisk cannot
    # make the kernel re-read a table whose partitions are mounted, so this reads the
    # partition entry back from the disk rather than trusting the exit status.
    NEW_END=$(part_field "Last sector")
    echo "part_end after write: $NEW_END (was $PART_END)"
    if [ "$NEW_END" -le "$PART_END" ]; then
        echo "sgdisk did not move the end of the partition - NOT rebooting"
        exit 0
    fi
    echo "partition grown, rebooting so the kernel re-reads the table"
    /system/bin/setprop sys.powerctl reboot
    exit 0
fi

# Stage 2: the filesystem is smaller than the partition it lives in.
PART_SECT=$(/vendor/bin/blockdev --getsz "$DEV")
BS=$(/system/bin/tune2fs -l "$DEV" 2>/dev/null | /system/bin/grep "Block size" | /system/bin/sed 's/[^0-9]*//')
FS_BLOCKS=$(/system/bin/tune2fs -l "$DEV" 2>/dev/null | /system/bin/grep "^Block count" | /system/bin/sed 's/[^0-9]*//')
[ -n "$BS" ] && [ -n "$FS_BLOCKS" ] || { echo "cannot read ext4 geometry"; exit 0; }
FS_SECT=$((FS_BLOCKS * (BS / 512)))
echo "part_sectors=$PART_SECT fs_sectors=$FS_SECT"
if [ "$FS_SECT" -lt $((PART_SECT - 131072)) ]; then
    echo "growing filesystem online"
    /system/bin/resize2fs "$DEV"
    echo "done: $(/system/bin/df -h /data | /system/bin/tail -1)"
else
    echo "nothing to do"
fi
