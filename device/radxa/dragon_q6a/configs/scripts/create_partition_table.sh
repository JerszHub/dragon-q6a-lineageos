# Create the partition table of a Radxa Dragon Q6A boot disk (NVMe or SD card).
#
# Do not set an interpreter: this runs on the build host and in recovery.
# Usage: create_partition_table.sh <sgdisk> <disk>
#
# Partitions 1-10 match LineageOS' virt devices, whose GRUB configuration addresses them by
# number. The firmware (SPI NOR) starts GRUB from the EFI system partition. userdata takes
# whatever is left of the disk.

SGDISK_EXEC=$1
TARGET=$2

if [ ! -x "$SGDISK_EXEC" ] || [ ! -w "$TARGET" ]; then
    exit 1
fi

$SGDISK_EXEC --zap-all $TARGET
$SGDISK_EXEC --new=1:0:+256M --typecode=1:ef00 --change-name=1:EFI $TARGET
$SGDISK_EXEC --new=2:0:+12G --change-name=2:super $TARGET
$SGDISK_EXEC --new=3:0:+1M --change-name=3:misc $TARGET
$SGDISK_EXEC --new=4:0:+16M --change-name=4:persist $TARGET
$SGDISK_EXEC --new=5:0:+32M --change-name=5:metadata $TARGET
$SGDISK_EXEC --new=6:0:+128M --change-name=6:firmware $TARGET
$SGDISK_EXEC --new=7:0:+100M --change-name=7:vendor_boot_a $TARGET
$SGDISK_EXEC --new=8:0:+100M --change-name=8:vendor_boot_b $TARGET
$SGDISK_EXEC --new=9:0:+96M --change-name=9:boot_a $TARGET
$SGDISK_EXEC --new=10:0:+96M --change-name=10:boot_b $TARGET
$SGDISK_EXEC --new=12:0:0 --change-name=12:userdata $TARGET

exit 0
