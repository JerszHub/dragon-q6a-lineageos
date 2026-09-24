# LineageOS 24 (Android 17) for the Radxa Dragon Q6A

A **LineageOS 24 / Android 17** port for the **Radxa Dragon Q6A** (Qualcomm QCS6490),
built on LineageOS' `device/mainline/generic` tree and an upstream **mainline kernel**.

This is the successor to [dragon-q6a-android](https://github.com/JerszHub/dragon-q6a-android)
(Android 13 / GloDroid). It is a different foundation, not a rebase: the Android 13 port
used a prebuilt RadxaOS kernel, while this one builds its own kernel from
`kernel/mainline/android-mainline`. All the hardware knowledge carries over; the Android
layer and the kernel do not.

> **Status: work in progress — no release yet.**
> The system boots to the LineageOS UI with working display, GPU, Ethernet, Wi-Fi,
> Bluetooth and persistent `/data`. Audio is the main remaining gap. The first image
> will be published on the [Releases](../../releases) page once it is done.
> See [docs/STATUS.md](docs/STATUS.md) for the current state in detail.

## Device specifications

| Component | Specification |
|---|---|
| SoC | Qualcomm QCS6490 (Kodiak) |
| CPU | 4× Cortex-A78 + 4× Cortex-A55 |
| GPU | Adreno 643 |
| Memory | 8 GB LPDDR5 |
| Storage | microSD, M.2 M-key 2230 NVMe (PCIe Gen3 ×2), eMMC |
| Display | HDMI via onboard RA620 DP→HDMI bridge; MIPI-DSI |
| Networking | Gigabit Ethernet (RTL8168h), AIC8800D80 Wi-Fi + Bluetooth |

## What works

Each item below was verified on hardware, not inferred from logs alone.

- **Boot** — LineageOS 24 reaches `sys.boot_completed`, setup wizard, Launcher3QuickStep
- **Display** — HDMI 1024×600@60 through the RA620 DP→HDMI bridge, DP link at HBR2 5.4 Gb/s
- **GPU** — Adreno 643 via Mesa (freedreno / Turnip), `drm_hwcomposer`
- **Ethernet** — Gigabit, RTL8168h (`r8169`)
- **Wi-Fi** — AIC8800D80 on USB, connected to a 5 GHz network
- **Bluetooth** — pairing and OBEX file transfer, using the kernel's generic `btusb`
- **Persistent `/data`** — 231 GB ext4 partition, verified across a reboot
- **adb** — over TCP

## What does not work yet

- **Audio** — not ported yet (it works in the Android 13 port; four fixes are documented there)
- **NVMe** — driver is in the image, untested on this branch
- **Hardware video codecs**
- **I²C / SPI** — the board's `qupv3fw.elf` is missing
- **USB3 SuperSpeed** — the QMP PHY runs in DP-only mode (see below)
- **MIPI-DSI**

## The display fix

The single most reusable finding in this port. The QCS6490 `kodiak.dtsi` gives the USB/DP
combo PHY an `orientation-switch` property. On a board with a USB-C receptacle the
orientation arrives from the Type-C port manager; the Q6A has no USB-C, so nothing ever
supplies it and the driver keeps `TYPEC_ORIENTATION_NORMAL`, which puts DP on lanes {3,2}.
This board wires DP to lanes {0,1}.

`phy-qcom-qmp-combo.c` only reads `data-lanes` from the port endpoint in the `else` branch —
that is, when `orientation-switch` is absent. Deleting the property makes the driver read the
wiring from the device tree:

```dts
&usb_1_qmpphy {
    /delete-property/ orientation-switch;
    status = "okay";
    ports {
        port@0 {
            endpoint {
                data-lanes = <0 1>;
            };
        };
    };
};
```

Result: DP trains at HBR2 5.4 Gb/s at voltage level 1, and the 1024×600@60 mode appears.
Before the fix the link fell back to RBR, hit maximum voltage level and produced no mode.

This misled us for a week because AUX is a separate differential pair and is not affected by
the lane swap — EDID read correctly the whole time, so the panel looked perfectly healthy.

Side effect: the PHY ends up in `QMPPHY_MODE_DP_ONLY`, which costs USB3 SuperSpeed. The
proper fix is a second endpoint with `data-lanes = <2 3>` for USB3; that is not done yet.

## Repository layout

| Path | Contents |
|---|---|
| `patches/` | Changes to upstream LineageOS and kernel repositories |
| `device/radxa/dragon_q6a/` | Board device tree: kernel config, Wi-Fi/BT firmware and modules |
| `device/mainline/generic/` | Files we add to LineageOS' generic device tree |
| `local_manifests/` | `repo` manifests needed to reproduce the source tree |
| `scripts/` | Build, SD card and diagnostic tooling |
| `docs/` | Build instructions, status, technical notes |

## Building

See [docs/BUILD.md](docs/BUILD.md).

## Licence

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
