#!/system/bin/sh
# Q6A: turn a MindTheGapps package the user supplied into the two images the boot flow
# mounts, then wipe /data.
#
# NOTHING FROM GOOGLE SHIPS WITH THIS DEVICE. LineageOS may not redistribute Google Apps,
# so the user downloads the package themselves and drops it in Download. This builds
# product.img and system_ext.img on the device, using mke2fs and e2fsdroid, which are both
# already present.
#
# WHY IT WIPES /data: Google Apps have to be in place before the framework's first run, or
# GMS crashes and the only cure is a factory reset (wiki.lineageos.org/gapps). Here they
# necessarily arrive after a boot, so the wipe is part of the procedure, not a mishap.
#
# WHY TWO IMAGES: the package installs into both system/product and system/system_ext, and
# GoogleServicesFramework and SetupWizard live in the latter. One image is not enough.
#
# WHY WHOLE IMAGES RATHER THAN JUST THE PACKAGE: mounting an image at /product replaces the
# directory, so the image has to carry the platform's own product content as well.
set -x
LOG=/data/local/tmp/q6a_gapps.log
WORK=/data/local/tmp/q6a_gapps
FC=/system/etc/selinux/plat_file_contexts
# On /metadata, not /data: it has to outlive the wipe below, otherwise the next boot would
# find the package again and start over.
STAMP=/metadata/q6a_gapps.sha256
exec >>"$LOG" 2>&1
echo "=== $(/system/bin/date) gapps check ==="

ZIP=
for c in /data/media/0/Download/MindTheGapps-*.zip /sdcard/Download/MindTheGapps-*.zip; do
    [ -f "$c" ] && ZIP="$c"
done
[ -n "$ZIP" ] || { echo "no MindTheGapps package in Download - nothing to do"; exit 0; }
echo "package: $ZIP"

# Locate the directory the boot flow reads its images from, rather than assuming the path.
ESP=
for d in /mnt/vendor/generic_init/*/Android /mnt/vendor/generic_init/android/Android; do
    [ -f "$d/system.img" ] && ESP="$d"
done
[ -n "$ESP" ] || { echo "cannot find the boot image directory - giving up"; exit 0; }
echo "boot image directory: $ESP"

# generic_init decides the mount flags for this partition, so do not assume it is writable;
# probe, and try a remount before giving up.
if ! : >"$ESP/.q6a_write_test" 2>/dev/null; then
    /system/bin/mount -o remount,rw "$ESP" 2>/dev/null
    if ! : >"$ESP/.q6a_write_test" 2>/dev/null; then
        echo "boot image directory is read-only - cannot install"
        exit 0
    fi
fi
/system/bin/rm -f "$ESP/.q6a_write_test"

SUM=$(/system/bin/sha256sum "$ZIP" | /system/bin/cut -d' ' -f1)
if [ -f "$STAMP" ] && [ "$(/system/bin/cat "$STAMP")" = "$SUM" ] && [ -f "$ESP/product.img" ]; then
    echo "this package is already installed - nothing to do"
    exit 0
fi

# The package states which platform it is for; refuse anything else rather than produce an
# image that boots into crash loops.
WANT_SDK=$(/system/bin/getprop ro.build.version.sdk)
WANT_ARCH=$(/system/bin/getprop ro.product.cpu.abi)
GOT_SDK=$(/system/bin/unzip -p "$ZIP" build.prop 2>/dev/null | /system/bin/sed -n 's/^version=//p')
GOT_ARCH=$(/system/bin/unzip -p "$ZIP" build.prop 2>/dev/null | /system/bin/sed -n 's/^arch=//p')
echo "package sdk=$GOT_SDK arch=$GOT_ARCH, device sdk=$WANT_SDK arch=$WANT_ARCH"
[ "$GOT_SDK" = "$WANT_SDK" ] || { echo "wrong platform version - refusing"; exit 0; }
case "$WANT_ARCH" in "$GOT_ARCH"*) ;; *) echo "wrong architecture - refusing"; exit 0 ;; esac

/system/bin/rm -rf "$WORK"; /system/bin/mkdir -p "$WORK/mtg" || exit 0
/system/bin/unzip -q -o "$ZIP" 'system/product/*' 'system/system_ext/*' -d "$WORK/mtg" || {
    echo "cannot unpack the package"; /system/bin/rm -rf "$WORK"; exit 0; }

build_one() {
    part=$1; mp=/$1; stage=$WORK/stage_$1; img=$WORK/$1.img
    /system/bin/rm -rf "$stage"; /system/bin/mkdir -p "$stage"
    /system/bin/cp -a "/system/$part/." "$stage/" || return 1
    [ -d "$WORK/mtg/system/$part" ] && /system/bin/cp -a "$WORK/mtg/system/$part/." "$stage/"
    bytes=$(/system/bin/du -sb "$stage" | /system/bin/cut -f1)
    files=$(/system/bin/find "$stage" | /system/bin/wc -l)
    # 15% over the payload covers ext4 metadata for this kind of content, which is almost
    # entirely already-compressed APKs. The floor keeps mke2fs from being handed a size it
    # refuses to format at all when the payload is unexpectedly small.
    blocks=$(( bytes * 115 / 100 / 4096 ))
    [ "$blocks" -lt 4096 ] && blocks=4096
    /system/bin/mke2fs -q -F -t ext4 -b 4096 -N $(( files * 2 )) -L "$part" -M "$mp" -m 0 \
        "$img" "$blocks" || return 1
    /system/bin/e2fsdroid -e -T 0 -S "$FC" -f "$stage" -a "$mp" "$img" || return 1
    /system/bin/rm -rf "$stage"
    echo "built $img ($(( $(/system/bin/stat -c%s "$img") / 1048576 )) MB)"
}
build_one product    || { echo "product.img failed";    /system/bin/rm -rf "$WORK"; exit 0; }
build_one system_ext || { echo "system_ext.img failed"; /system/bin/rm -rf "$WORK"; exit 0; }

# The boot partition is a fixed 4 GB and the platform images already fill most of it, so
# check before copying rather than leaving a half-written image behind.
NEED=$(( $(/system/bin/stat -c%s "$WORK/product.img") + $(/system/bin/stat -c%s "$WORK/system_ext.img") ))
HAVE=$(( $(/system/bin/df "$ESP" | /system/bin/tail -1 | /system/bin/awk '{print $4}') * 1024 ))
echo "need $(( NEED/1048576 )) MB, free on boot partition $(( HAVE/1048576 )) MB"
if [ "$HAVE" -lt "$NEED" ]; then
    echo "not enough room on the boot partition - nothing changed"
    /system/bin/rm -rf "$WORK"; exit 0
fi

/system/bin/cp "$WORK/product.img"    "$ESP/product.img.part"    || { echo "copy failed"; /system/bin/rm -f "$ESP/product.img.part"; /system/bin/rm -rf "$WORK"; exit 0; }
/system/bin/cp "$WORK/system_ext.img" "$ESP/system_ext.img.part" || { echo "copy failed"; /system/bin/rm -f "$ESP"/*.part; /system/bin/rm -rf "$WORK"; exit 0; }
# Rename only once both are complete, so an interrupted run cannot leave the boot flow with
# one of the two images and a mismatched platform.
/system/bin/mv "$ESP/product.img.part"    "$ESP/product.img"    || exit 0
/system/bin/mv "$ESP/system_ext.img.part" "$ESP/system_ext.img" || exit 0
/system/bin/sync
echo "$SUM" > "$STAMP"
/system/bin/sync
echo "images in place"

echo "wiping /data so the first run of Google Apps is a clean one"
for e in /data/* /data/.[!.]* /data/..?*; do /system/bin/rm -rf "$e"; done
/system/bin/sync
/system/bin/setprop sys.powerctl reboot
