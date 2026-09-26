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

DISK_SECT=$(/vendor/bin/blockdev --getsz "$DISK") || exit 0
PART_END=$(/system/bin/sgdisk -i "$PART" "$DISK" | /system/bin/grep "Last sector" | /system/bin/sed 's/[^0-9]*\([0-9]*\).*/\1/')
LAST_USABLE=$((DISK_SECT - 34))
echo "disk_sectors=$DISK_SECT part_end=$PART_END last_usable=$LAST_USABLE"

# Stage 1: the partition does not reach the end of the medium.
# The 64 MiB margin keeps us from churning on a partition that is already effectively full.
if [ "$PART_END" -lt $((LAST_USABLE - 131072)) ]; then
    echo "growing partition $PART"
    START=$(/system/bin/sgdisk -i "$PART" "$DISK" | /system/bin/grep "First sector" | /system/bin/sed 's/[^0-9]*\([0-9]*\).*/\1/')
    NAME=$(/system/bin/sgdisk -i "$PART" "$DISK" | /system/bin/grep "Partition name" | /system/bin/sed "s/.*'\(.*\)'.*/\1/")
    /system/bin/sgdisk -e "$DISK"
    /system/bin/sgdisk -d "$PART" "$DISK"
    /system/bin/sgdisk -n "$PART:$START:0" -t "$PART:8300" -c "$PART:$NAME" "$DISK"
    /system/bin/sync
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
