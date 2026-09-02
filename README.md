# recovery_itel_S666LN

PitchBlack Recovery Project (PBRP 3.7.1, Android 13) for the **itel RS4
(S666LN)** — MediaTek MT6789 (Helio G99), A/B, Virtual A/B, FBE + metadata
encryption.

Boots, decrypts `/data` **completely** — metadata *and* FBE — and brings up MTP
and adb together from boot. Verified on hardware:

```
/data on /dev/block/dm-12 f2fs · /data/media/0 lists Alarms Android Audiobooks DCIM
    in PLAINTEXT, not ciphertext
UDC=musb-hdrc  state=mtp,adb  f1->ffs.mtp  f2->ffs.adb
mcDriverDaemon · keymint · keystore2 · boot-hal all registered
```

This tree is authored for this device from its own measurements. It is not a
fork of an existing recovery tree; every fstab entry, offset and flag was derived
from the hardware or from stock firmware and checked against the running device.

---

## Building

```sh
# minimal manifest, PBRP 3.7.1 / android-13
tools/build-pbrp.sh
tools/package-pbrp.sh <recovery.cpio.lz4> <out.zip>
```

`ALLOW_MISSING_DEPENDENCIES=true` is **mandatory** — the minimal manifest drops
826 of 1061 projects and the survivors still reference them.

### 🔴 FIVE patches are NOT in the build tree — re-apply after every `repo sync`

```
patches/0001-default-timezone-WIB.patch           bootable/recovery/data.cpp
patches/0002-platform-version-13.patch            build/make/core/version_defaults.mk
patches/0003-create-fscrypt-session-keyring.patch system/vold/KeyUtil.cpp
patches/0004-pbrp-ui-cleanup-and-repack-control.patch  gui/, bootable/recovery/twrpRepacker.cpp
patches/0005-blkroset-before-raw-write.patch      bootable/recovery/partition.cpp
```

**0005 is what makes "Automatically Reflash PBRP after flashing a ROM" work.**
Without it that feature writes ONE slot and silently fails on the other. TWRP's
`Raw_Read_Write` opens the destination successfully and then `write()` returns
**EPERM**, because `blkdev_write_iter()` refuses a block device the kernel has
marked read-only. After an A/B ROM install the OTA's TARGET slot is left in
exactly that state, so the reflash wrote `vendor_boot_a` and failed on
`vendor_boot_b` — leaving the ROM on B with the stock recovery on it. Measured
on hardware 2026-09-03:

```
1782  write vendor_boot_a -> ok
1785  Overriding slot to 'B'
1839  write vendor_boot_b -> Error writing destination fd (Operation not permitted)
```

The fix is one `ioctl(BLKROSET, 0)` before the write — exactly what this device's
own flashable zip has always done (`blockdev --setrw`, `tools/update-binary:109`),
which is why the zip works even immediately after a ROM flash and the built-in
did not.

**0003 is what makes FBE work.** Losing it silently returns you to "encrypted
with FBE" and ciphertext filenames. `installKey()` calls
`installProvisioningKey()` unconditionally *after* the modern
`FS_IOC_ADD_ENCRYPTION_KEY` ioctl has already succeeded, and that needs a session
keyring named `fscrypt`. `add_key("keyring", …)` appears nowhere in
`system/vold` or `bootable/recovery` — AOSP's vold creates it at startup, and
recovery has no vold. Creating it on miss is the whole fix.

0002 exists because `PLATFORM_VERSION` **cannot** be set from BoardConfig or the
environment: `version_defaults.mk` is included at `envsetup.mk:68` while product
config is line 312 and board config line 323, so its `ifndef` has already fired;
and soong scrubs the variable from the environment. Both were tried and both
silently produced `ro.build.version.release=12` with no build error. KeyMint binds
every key blob to the OS version and both patch levels, so getting this wrong
makes the TEE answer `KM_ERROR_KEY_REQUIRES_UPGRADE (-62)`.

---

## Installing

Prefer the **ZIP**. It swaps only the recovery fragment, on-device, against the
`vendor_boot` actually installed, and writes **both slots**:

```sh
adb sideload PitchBlack-S666LN-3.7.1_13-<date>.zip
```

The `.img` is repacked against a host-side donor and therefore pins the platform
fragment to that donor's. If you use it:

```sh
fastboot flash vendor_boot --slot=all PitchBlack-S666LN-3.7.1_13-<date>.img
```

⚠ `vendor_boot` is where recovery lives on this device (recovery-as-boot, GKI).
There is no `recovery` partition.

---

## What is in here

```
BoardConfig.mk          derived from this project's own measurements
omni_S666LN.mk          product definition
recovery/root/system/etc/recovery.fstab
                        29 entries, all 21 device paths verified to resolve on
                        the running device (8 via slotselect)
recovery/root/*.rc      init + the USB gadget work (see below)
sepolicy/               vendor + private policy
patches/                the three tree patches above
prebuilt/               Image.gz, dtb.img, dtbo.img
recovery/root/…         stock blobs — see BLOBS-boot-hal.md for why each is here
tools/                  build, package, and the installer's update-binary
```

Two fstab facts that came from checking the device rather than copying the ROM's
fstab:

* `logo` **is** slot-selected here (`logo_a`/`logo_b`). The ROM fstab lists it
  without `slotselect`, which works there but resolves to a nonexistent
  `/dev/block/by-name/logo` in recovery.
* `init_boot` and `md1img` were missing from the first draft. `md1img` is the
  **modem** image — a "full backup" that saves nvdata but not md1img restores a
  phone whose radio has no firmware.

Decryption flags derive from the ROM fstab's own userdata line
(`fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized`,
`keydirectory=/metadata/vold/metadata_encryption`), which is why
`TW_USE_FSCRYPT_POLICY := 2`, `TW_INCLUDE_FBE_METADATA_DECRYPT := true`, and why
`/metadata` must mount before `/data`.

---

## Gotchas that cost the most time

* **`class_start` does not exist in recovery's init.** A service with only
  `class main` is parsed, defined, and **never started**. Start it from an
  explicit trigger (`on post-fs`, after the persist mount).
* **`/system/etc/init/hw/init.rc` owns the USB gadget** and has triggers for
  `adb | fastboot | sideload | none` only — "mtp" appears nowhere in it. Do not
  hand-roll a competing gadget; fill in the missing case in its style. It takes
  two stages: relink `f1=ffs.mtp f2=ffs.adb` and restart adbd, then bind the UDC
  once *both* `sys.usb.ffs.ready` and `sys.usb.ffs.mtp.ready` are set. Doing both
  in one block cannot work — `start adbd` is asynchronous.
* **`stop adbd` kills the service cgroup**, including anything spawned from an
  adb shell; `setsid` does not save it. Loggers for USB tests must not live under
  adbd.
* **keystore2 dereferences `getDeviceHalManifest()` without a null check**, so a
  device VINTF manifest that is missing *or unparseable* SIGSEGVs it in a Binder
  thread. The manifest must also be meta-version **4.0** — PBRP's libvintf is
  `kMetaVersion{4,0}` and rejects a 5.0 vendor manifest wholesale, so the ROM's
  manifest can never be reused here.

---

## Provenance

Stock-derived blobs come from this device's own **revision 28** firmware dump
(`251212V1661`), never from a third-party recovery. `BLOBS-boot-hal.md` documents
each one and what proved it necessary.

Licensed under the Apache License, Version 2.0 — see `LICENSE`.
