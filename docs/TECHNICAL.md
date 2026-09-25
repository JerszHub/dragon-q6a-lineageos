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

## Boot time

Android's init did not start until 36 seconds into boot. The cause was a missing firmware
file, and the chain is worth recording because nothing in it points at the real culprit.

1. `cfg80211.ko` loads at 2.43 s — before `/vendor` is mounted.
2. It looks for `regulatory.db` under `firmware_class.path=/mnt/vendor/firmware/` (the ESP)
   and gets `-2` (ENOENT), even though the file *is* in the image, at
   `/vendor/firmware/regulatory.db`:
   `faux_driver regulatory: Direct firmware load for regulatory.db failed with error -2`
3. Having failed, cfg80211 emits a uevent on `/devices/faux/regulatory` **every 3.33 s**,
   indefinitely.
4. `generic_init`'s second `ueventd` pass calls `Poll(callback, 5s, true)` — it waits for
   **five seconds of silence**. With an event every 3.33 s that silence never comes, so
   `Poll` never returns and the loop's exit condition,
   `while (!CanQuitUeventd(true))`, is never evaluated. The intent is stated in
   `first_stage_init.cpp:641`: *"Run ueventd with normal boot configuration, until there's
   no new uevents"*.
5. What finally breaks the deadlock is the unrelated 30-second cap added in Gerrit
   [#501523](https://review.lineageos.org/c/501523) — `Deadline reached` at 35.81 s.

Copying `regulatory.db` and `regulatory.db.p7s` into `::/Android/firmware/` on the ESP
fixes it. `scripts/add_a17_firmware.sh` does this.

| | before | after |
|---|---|---|
| `apexd-bootstrap` | 36.64 s | 9.64 s |
| `adbd` | 41.62 s | 14.50 s |
| `bootanim` | 42.13 s | 15.03 s |
| ueventd exit | 35.81 s (deadline) | 9.01 s (naturally) |
| `faux/regulatory` uevents | dozens | 0 |

This is also an upstream problem in its own right, with no Gerrit report: the
"until there's no new uevents" condition cannot be satisfied on any board with a periodic
uevent source faster than the 5 s poll timeout, which makes #501523's 30-second cap a
fixed boot cost for everyone. The readiness check inside the poll callback is guarded by
`first_run &&` (`ueventd.cpp:179`), so on the second pass it never runs at all.

### Do not remove `console=tty0`

It looks like an obvious saving and it is the opposite. With **no** `console=` argument at
all, the kernel enables every console that registers — including the UART:

```
with console=tty0:  [0.000282] printk: legacy console [tty0] enabled
without:            [0.000282] printk: legacy console [tty0] enabled
                    [0.163816] printk: legacy console [ttyMSM0] enabled
```

The serial console on this board is blocking and runs at roughly 11 KB/s, and the log is
about 6100 lines. Removing the argument does not disable logging — it moves it from the
framebuffer to the UART. Measured, three runs each: 9.64 / 9.69 / 9.81 s with
`console=tty0` against 52.93 / 53.80 s without. The divergence starts inside the kernel:
`Freeing unused kernel memory` at 0.20 s versus 4.29 s.

To actually reduce console output, keep `console=tty0` and add `quiet loglevel=3`. Measured,
that is worth about a quarter of a second — `apexd-bootstrap` 9.43 s against 9.64–9.81 s.
The framebuffer console is cheap; the expense was the UART. It is worth having on a release
image for the clean screen rather than for the time.

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
- **Measure before assuming.** The boot was suspected of being slowed by logging. Logging
  was not the cause; timing the gaps in `dmesg` pointed somewhere else entirely, and the
  one change that looked like an obvious saving made things five times worse.
- **When generating a boot entry, touch only the `options` line.** `sed 's/$/ .../'`
  appends to *every* line, including `linux`, `initrd` and `devicetree`, which produces an
  entry that systemd-boot cannot load. With `timeout 0` and no keyboard, that means the
  card has to come out. Verify the generated file before rebooting: the three path lines
  must still have exactly two fields each.

## Audio bring-up

The board came up with no sound card at all — `/proc/asound/cards` said
`--- no soundcards ---`. Unlike the Android 13 port, everything else was already in
place: the kernel builds the whole audio stack as modules, 314 of them ship in
`vendor_dlkm`, and `remoteproc0`/`remoteproc1` exist.

Two firmware files were missing, and **they go to different paths**, which is the part
that is easy to get wrong:

| File | Path under `firmware_class.path` | Why |
|---|---|---|
| `adsp.mbn` | `qcom/qcs6490/radxa/dragon-q6a/` | from the remoteproc node's `firmware-name` |
| `QCS6490-Radxa-Dragon-Q6A-tplg.bin` | `qcom/qcs6490/` | named after the card's `model`, no subdirectory |

Without the first, `remoteproc0` (named `adsp`) stays `offline`, so q6apm and GPR never
come up. Without the second:

```
qcom-apm gprsvc:service:2:1: tplg firmware loading .../QCS6490-Radxa-Dragon-Q6A-tplg.bin failed -2
snd-sc8280xp sound: ASoC: failed to instantiate card -2
```

With both staged on the ESP, the ADSP boots by itself at about 3.8 s and the card
instantiates. `scripts/add_a17_firmware.sh` does this.

Nothing else was needed on the userspace side: upstream `alsa-ucm-conf` already carries a
profile for this exact board at
`Qualcomm/qcs6490/QCS6490-Radxa-Dragon-Q6A/`, including a `BootSequence` that sets the
headphone and ADC volumes. That is a marked improvement on the Android 13 port, where the
missing `audio.dragon_q6a.xml` was the root cause of silence.

### HDMI audio

The mainline device tree declares only the two WCD links, so there is no DisplayPort
backend. Adding one follows the pattern used by other Qualcomm boards:

```dts
displayport-dai-link {
	link-name = "DisplayPort Playback";
	codec    { sound-dai = <&mdss_dp>; };
	cpu      { sound-dai = <&q6apmbedai DISPLAY_PORT_RX_0>; };
	platform { sound-dai = <&q6apm>; };
};
```

`mdss_dp` already has `#sound-dai-cells = <0>` in `kodiak.dtsi`, so no SoC-level change is
needed. With this in place the card still instantiates, no ASoC errors appear, and
`hdmi-audio-codec.1.auto` shows up as a component in `/sys/kernel/debug/asoc/`. Note that
this is a *backend* link, so it adds no new PCM device — the frontends (`MultiMedia1`,
`MultiMedia2`) route to it.

Audio actually reaching an HDMI sink has **not** been verified; that needs routing
configuration and hardware to listen on.
