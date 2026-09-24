# Technical notes

Findings from the port that are not obvious from the code, recorded so they do not have
to be rediscovered.

## How this system boots

There is no boot image in the usual Android sense. The board's UEFI firmware loads
`systemd-boot`, which reads `/loader/entries/*.conf` from the ESP and starts the kernel
with `rdinit=/system/bin/generic_init`.

`generic_init` replaces AOSP's first-stage init. It loads modules from the ramdisk, runs
its own `ueventd`, decides what to mount from `androidboot.*` parameters, and only then
hands over to the normal Android init. The relevant parameters are:

- `androidboot.mount_system` — `imgs` mounts `system.img`, `vendor.img` and friends as
  loop devices out of a directory on the ESP
- `androidboot.mount_userdata` — `std_parts`, `imgs`, `bind_mount_dir` or `tmpfs`
- `androidboot.mount_firmware` — `only_android_dir` mounts the ESP at `/mnt/vendor/firmware`
- `androidboot.android_dir` — the directory on the ESP holding the images

Because the ESP is mounted read-write at `/mnt/vendor/generic_init/android` on the running
system, boot entries and images can be changed over adb without taking the card out.

## The MDSS reset

For a long time the board reset itself a few seconds after `Console: switching to colour
dummy device`, with `PM: Reset by PSHOLD` — a watchdog reset, not a panic, which means a
register access without a clock or power rather than a software fault.

The cause is a race between two subsystems with no ordering between them: `genpd` powers
down the MDSS domain and its clocks about 3 s into boot as "unused", while the `msm`
driver is loaded roughly 48 s later and reads a DPU register. `pd_ignore_unused
clk_ignore_unused` on the command line prevents the power-down and the board boots.

This is a workaround, not a fix, and it also explains why the failure looked
non-deterministic and why several earlier hypotheses "proved" and then "disproved"
themselves.

### Diagnostic constraint

The serial console on this board is blocking and runs at roughly 11 KB/s. Any extra
logging changes the timing of what is being measured — the GPU and GMU bring-up sequence
has hard timeouts, and flooding the UART during `msm_gpu_init` is by itself enough to
cause `PM: Reset by PSHOLD`. This applies to `drm.debug`, `initcall_debug` and
`keep_bootcon` alike. Pick diagnostics as narrowly as possible: `drm.debug=0x100` selects
only the DP category and produces nothing from the GPU. Per-file `dyndbg=` does not work
because `CONFIG_DRM_USE_DYNAMIC_DEBUG` is off.

`modprobe.blacklist=` also does not work here — `generic_init` loads modules through
`finit_module`, bypassing it. Disable hardware in the DTS instead.

## FAT larger than its partition

`mformat -i file@@OFFSET` does not know the partition size. It computes the filesystem as
`(file size - offset) / 512`, i.e. to the end of the *file* — but GPT reserves the last
33 sectors for the backup table. The filesystem came out 33 sectors larger than the
partition, and files landing at the end of the FAT fell outside it:

```
mmcblk1p1: attempt to access beyond end of device, sector=6289390 limit=6289375
erofs (device loop0): read error
```

`vendor.img` was unreadable at its tail and SurfaceFlinger looped. `fsck.vfat` does not
catch this. The fix is to pass the size explicitly with `-T`, computed from the partition
table, and to assert afterwards that the filesystem is not larger than the partition.

## Wi-Fi and Bluetooth (AIC8800D80)

The chip sits on USB and enumerates in two stages: `a69c:8d80` in ROM mode, then
`a69c:8d81` once firmware is loaded. The LineageOS image contains nothing for it — there
are no `*aic*` files anywhere in `system/` or `vendor/` — so the driver, the firmware and
the HAL configuration are all work from scratch rather than a port.

The modules are built from source (`radxa-pkg/aic8800` plus its Debian patches) against
this kernel; see `scripts/build_aic8800.sh`.

Only two of the three modules are loaded: `aic_load_fw` and `aic8800_fdrv`.
**`aic_btusb` must not be loaded** — see the note in [STATUS.md](STATUS.md).

## Lessons

- **Check reproducibility of the baseline before comparing configurations.** One lucky
  boot was treated as the baseline and three hypotheses were built on it; all three were
  wrong because the baseline was not reproducible. A reproducibility test costs one boot.
- **Check Gerrit for every finding.** Three "our" Mesa bugs had been fixed upstream two
  days earlier; the tree was simply behind.
- **Do not generalise from one sample.** A driver filter was dropped after checking a
  single name, costing a 3.5 hour build, and then one further build per driver.
- **Change one variable at a time.** Combining a `/data` change with the removal of serial
  logging produced a board that neither booted nor could be observed.
- **Compare against a manifest, not against the source.** Sources get rebuilt; a manifest
  of what was written to the card is what detects media corruption.
