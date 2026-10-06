# Google Apps

Nothing from Google ships with this device, and nothing ever will. LineageOS may not
redistribute Google Apps, and neither may this project. You download the package yourself
and the board turns it into what it needs.

The upstream guidance this follows is
[wiki.lineageos.org/gapps](https://wiki.lineageos.org/gapps/): the packages are independent
of LineageOS, unsupported by it, and they have to be in place before the framework's first
run or GMS crashes.

## What you need

`MindTheGapps` for **Android 17, arm64**, from
[MindTheGapps/17.0.0-arm64](https://github.com/MindTheGapps/17.0.0-arm64/releases/latest).
Nothing else is tested. The package states the platform it is built for, and the board
refuses any package whose `version` is not this device's SDK level or whose `arch` does not
match.

## Procedure

1. Boot the board normally and let it finish the first-run wizard, or skip it.
2. Download the `MindTheGapps-17.0.0-arm64-*.zip` into **Download** — with the browser on
   the board, or over `adb push <file> /sdcard/Download/`.
3. Reboot.

That is all. On the next boot the board unpacks the package, builds `product.img` and
`system_ext.img` next to the platform images, and reboots once more. Google Apps are part of
the system from then on.

## It wipes your data, and it has to

**The third step erases everything on the device.** Google Apps must be present before the
framework runs for the first time; here they necessarily arrive after a boot, so the board
performs the wipe that upstream tells you to perform manually in that situation. Install
Google Apps before you set the device up, not after.

## Why two images

The package installs into both `system/product` and `system/system_ext`, and
`GoogleServicesFramework` and `SetupWizard` live in the second one — one image is not
enough. Mounting an image over `/product` replaces that directory rather than adding to it,
so each image also carries the platform's own content for that partition. Together they come
to roughly 2.2 GB, against about 2.4 GB free on the 4 GB boot partition. The board checks
before it copies anything and changes nothing if the room is not there.

## If something goes wrong

The whole run is logged to `/data/local/tmp/q6a_gapps.log`, which survives until the wipe,
so read it before rebooting if the result is not what you expected. Every failure path
leaves the boot partition untouched; the images are written under temporary names and only
renamed once both are complete, so an interrupted run cannot leave the board with one image
and a mismatched platform.

To go back to a device without Google Apps, delete `product.img` and `system_ext.img` from
the `Android` directory of the boot partition and wipe data again.

## What is not done yet

Installation currently replaces the two partitions wholesale, which means that rebuilding
`system.img` requires rebuilding these images too or the platform content in them goes
stale. Layering the package over the platform with overlayfs instead would avoid that and
cut the space needed by more than half; the mechanism exists in this tree already, for the
init overlay, but it is not wired up for this yet.
