# NCM Tethering Fix

Makes Android USB tethering use **CDC-NCM** instead of **RNDIS**, so macOS can use it
without a driver.

macOS has no RNDIS driver. Android's USB tethering defaults to RNDIS
(`config_tether_usb_functions = 0`), which leaves a Mac with no network interface at all.
CDC-NCM is natively supported by macOS, so switching the function is enough.

This is a KernelSU/Magisk module. It sets one preference and, on firmwares that need it,
renames the NCM gadget interface so Tethering recognises it. **It does not turn tethering
on** — tethering still starts when you enable it in Settings, and ADB keeps working
(tethering then applies `ncm,adb`).

## Install

1. Download the `ncm-tethering-fix-*.zip` from Releases (verify against `SHA256SUMS.txt`).
2. Install it in the KernelSU (or Magisk) app, then reboot.
3. Enable **USB tethering** in Settings → Network → Hotspot & tethering.
4. On the Mac the phone appears as an Ethernet interface and gets a DHCP lease.

Uninstalling runs `uninstall.sh`, which deletes the preference, so stock RNDIS behaviour
returns immediately.

**Disabling is the awkward case.** KernelSU runs no module script for a disabled module, so
`tether_force_usb_functions` stays at `1` while the interface reverts to `usb0`. On a firmware
with the NCM overlay that is the one state where USB tethering matches nothing. Either
uninstall (which cleans up), or press the module's Action button once after disabling: it
detects the mismatch and reverts the preference to RNDIS.

## What it actually changes

| Change | Where | Why |
| --- | --- | --- |
| `settings put global tether_force_usb_functions 1` | `boot-completed.sh` | `TetheringConfiguration` reads this from `Settings.Global`; `1` makes `setUsbTethering()` call `setCurrentFunctions(FUNCTION_NCM)` instead of `FUNCTION_RNDIS`. Tethering watches the key with a `ContentObserver`, so the new function is used on the next tethering start — no reboot needed. (If tethering is already running when the key flips, Tethering stops it once, because the USB function changes underneath it.) |
| `ifname` → `ncm%d` on the NCM gadget, **only when the firmware expects `ncm\d`** | `ncm-ifname.sh` | The kernel names every `f_ncm` instance `usb%d`. Firmwares shipping the `config_tether_ncm_regexs = ["ncm\d"]` RRO replace `tetherableUsbRegexs` with it, so `usb0` matches nothing and no DHCP/NAT starts. |

Nothing else runs. There is no background process, and nothing here enables tethering: the
preference is only consulted when you turn USB tethering on, and turning it off leaves USB
in its normal `mtp,adb` state.

### Why the rename is conditional

The rename is not universally safe. On firmwares **without** the NCM overlay,
`config_tether_ncm_regexs` is empty and `tetherableUsbRegexs` stays `["usb\d", "rndis\d"]`,
where the kernel's default `usb0` already matches — renaming there would break a working
setup.

So `boot-completed.sh` reads the arrays Tethering actually resolved, and looks at **both**
of them:

```sh
dumpsys tethering | grep -E 'tetherable(Usb|Ncm)Regexs: '
```

Checking only `tetherableUsbRegexs` would be self-referential: `TetheringConfiguration`
swaps the arrays *because* the setting is 1, so with the setting still at 0 it always
reports `["usb\d", "rndis\d"]`. The overlay is visible in `tetherableNcmRegexs` at that
point instead:

| `tether_force_usb_functions` | `tetherableUsbRegexs` | `tetherableNcmRegexs` |
| --- | --- | --- |
| `0` (first boot, before the module writes) | `[usb\d, rndis\d]` | `[ncm\d]` — overlay present |
| `1` (later boots) | `[ncm\d]` | `[]` |

Either line mentioning `ncm` means the firmware wants an `ncm*` interface, which makes the
check idempotent across boots.

* `ncm` in either array → rename, verify, then select NCM;
* `ncm` in neither → select NCM, leave the interface alone;
* no `ncm` gadget directory at all → **skip entirely**: the firmware has no `sys.usb.config=ncm`
  composition, so selecting NCM would leave USB with no working configuration;
* arrays unreadable and no NCM overlay found → **skip entirely**, so stock RNDIS tethering
  keeps working on unknown hardware.

If the rename fails, the preference is deliberately *not* set: leaving RNDIS selected is
better than selecting an NCM function whose interface Tethering cannot match.

## Compatibility

Verified statically against **OnePlus Open (CPH2551 / OP5973L1), Android 16,
CPH2551_16.0.5.1301(EX01)**:

* kernel: `CONFIG_USB_F_NCM=y`, `CONFIG_USB_CONFIGFS_NCM=y`, `# CONFIG_USB_CONFIGFS_RNDIS is not set`
* `init.qcom.usb.rc` defines `sys.usb.config=ncm` and `ncm,adb` compositions
* `vendor.usb.use_gadget_hal=0`, so the legacy configfs path is used
* `product/overlay/NcmTetheringResCommonGMS_Sys.apk` sets
  `config_tether_ncm_regexs = ["ncm\d"]` for `com.google.android.networkstack.tethering`
* the kernel exposes a writable `functions/ncm.0/ifname` (`0644`), and its validator
  accepts `ncm%d` while rejecting `ncm0`

Other devices are untested. The script's runtime probe is what makes that safe: unknown
firmware is left untouched rather than configured wrongly.

No `sepolicy.rule` is shipped. KernelSU puts the module scripts in the `ksu` domain, which
it declares permissive and grants `allow ksu * * *`, so writing configfs and Settings needs
no extra policy. On Magisk the scripts run in `su`, which is likewise unrestricted. Adding
rules would only risk conflicts on kernels with a different policy layout.

The `ifname` write must happen before tethering is enabled: `ifname_store` returns `EBUSY`
while the function is bound into a configuration (`opts->refcnt != 0`). `boot-completed.sh`
runs after `sys.boot_completed`, long before a user can flip the tethering switch, and
retries for about 8s if it loses that race. The name only takes effect when the function is
bound, at which point the kernel expands `ncm%d` to `ncm0` via `__dev_alloc_name()`.

### The Action button

Tapping Action prints the preferred function, the live `ncm` interface name and the last
boot log. It also repairs the disabled-module state described above by reverting the
preference to RNDIS when it finds NCM selected with no `ncm*` interface. It then opens the
tethering settings screen.

### Troubleshooting

The module writes a log, readable from the Action button or directly:

```sh
adb shell cat /data/adb/modules/ncm-tethering-fix/ncm-tethering.log
adb shell dumpsys tethering | grep -E 'tetherable(Usb|Ncm)Regexs'
adb shell cat /config/usb_gadget/g1/functions/ncm.0/ifname
```

If the log ends with `result: failed`, the gadget refused the rename (usually `EBUSY`
because it was already bound). Reboot and check again; if it persists, open an issue with
the log.

## Build

Requires JDK 17+ (Gradle 9.4.1). No Android SDK, no NDK, no `zip` binary — the module is
shell only and the archive is produced by Gradle.

```sh
./gradlew packageModule        # -> build/ncm-tethering-fix-<version>.zip
```

`just package` does the same and prints the checksum. The zip is reproducible: same commit,
same bytes.

Version comes from `module/module.prop`.

## CI

`.github/workflows/build.yml` builds on every push and PR as a gate, and on a `v*` tag it
publishes a GitHub Release containing the zip and `SHA256SUMS.txt`. The release reuses the
artifact the build job produced, so the published file is the one that was verified.

To release: bump `version`/`versionCode` in `module/module.prop`, then push a matching tag.

## License

No license file is included, matching the upstream project this is forked from. Add one
before redistributing.
