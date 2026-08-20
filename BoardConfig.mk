#
# Copyright (C) 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# PitchBlack Recovery board config for the itel RS4 (S666LN, MT6789).
#
# Every value here is derived from THIS project's own measurements of the
# device -- device_itel_S666LN/BoardConfig.mk, the stock vendor_boot, and
# on-device readings -- not copied from another RS4 tree. That matters: the
# whole reason this recovery exists is that full backup was the last remaining
# dependency on a banned source, so a port that imports that source's config
# would defeat its own purpose.

DEVICE_PATH := device/itel/S666LN

# --- architecture. Mirrors device_itel_S666LN/BoardConfig.mk exactly; the
# recovery runs on the same silicon as the ROM.
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a-dotprod
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := cortex-a76
TARGET_CPU_VARIANT_RUNTIME := cortex-a76
TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-2a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := cortex-a55
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a55
TARGET_USES_64_BIT_BINDER := true

TARGET_BOARD_PLATFORM := mt6789
TARGET_NO_BOOTLOADER := true
TARGET_OTA_ASSERT_DEVICE := S666LN

# --- kernel. The ROM ships a vanilla 5.10.260 built from itel-rs4-kernel and
# imported as a prebuilt; recovery uses the SAME Image.gz. Do not substitute the
# ksunext kernel here -- root belongs to a hand-patched boot.img flashed on top,
# never to a shipped artifact.
BOARD_KERNEL_IMAGE_NAME := Image.gz
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/Image.gz
TARGET_PREBUILT_DTB := $(DEVICE_PATH)/prebuilt/dtb.img
BOARD_PREBUILT_DTBOIMAGE := $(DEVICE_PATH)/prebuilt/dtbo.img
BOARD_INCLUDE_DTB_IN_BOOTIMG :=

BOARD_BOOT_HEADER_VERSION := 4
BOARD_KERNEL_PAGESIZE := 4096
BOARD_KERNEL_BASE := 0x3fff8000
BOARD_KERNEL_OFFSET := 0x00008000
BOARD_RAMDISK_OFFSET := 0x26f08000
BOARD_KERNEL_TAGS_OFFSET := 0x07c88000
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2
BOARD_RAMDISK_USE_LZ4 := true

BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)
BOARD_MKBOOTIMG_ARGS += --base $(BOARD_KERNEL_BASE)
BOARD_MKBOOTIMG_ARGS += --kernel_offset $(BOARD_KERNEL_OFFSET)
BOARD_MKBOOTIMG_ARGS += --ramdisk_offset $(BOARD_RAMDISK_OFFSET)
BOARD_MKBOOTIMG_ARGS += --tags_offset $(BOARD_KERNEL_TAGS_OFFSET)
BOARD_MKBOOTIMG_ARGS += --pagesize $(BOARD_KERNEL_PAGESIZE)
BOARD_MKBOOTIMG_ARGS += --dtb $(TARGET_PREBUILT_DTB)

# --- 🔴 RECOVERY LIVES IN vendor_boot. There is no recovery partition on this
# device, and recovery shares the boot kernel.
#
# ⚠ The recovery fragment supplies the vendor ramdisk at NORMAL boot as well
# (measured 2026-08-06), so a botched fragment breaks normal-boot module loading
# and not merely recovery. Test as a separate fastboot image before shipping.
#
# ⚠ BOTH vendor_ramdisk fragments must survive. Measured on build 70's
# vendor_boot.img:
#     fragment 0 (platform, type 0x1)   8,321,463 B
#     fragment 1 (recovery, type 0x2)  14,965,666 B
#     dtb + header                        202,496 B
#     ------------------------------------------------
#     used 23,489,625 of 67,108,864  ->  ~43.6 MB headroom
# The PLATFORM fragment carries all four touch firmware blobs and the patched
# adaptive-ts.ko. Drop it and you get a touch UI with no touch input.
BOARD_USES_RECOVERY_AS_BOOT :=
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true
BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE := true

BOARD_FLASH_BLOCK_SIZE := 262144
BOARD_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_DTBOIMG_PARTITION_SIZE := 8388608
BOARD_SUPER_PARTITION_SIZE := 9847996416
BOARD_USES_METADATA_PARTITION := true

TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_COPY_OUT_VENDOR := vendor

# --- A/B. Virtual A/B, one physical copy plus COW snapshots.
# A/B. AB_OTA_UPDATER without AB_OTA_PARTITIONS is a hard error
# (build/make/core/Makefile:4795). The list is the partitions that actually
# carry _a/_b suffixes on this unit, read off /dev/block/by-name rather than
# assumed -- logical ones first, then the slotted images.
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS := \
    system \
    system_ext \
    product \
    vendor \
    vendor_dlkm \
    odm_dlkm \
    boot \
    init_boot \
    vendor_boot \
    dtbo \
    vbmeta \
    vbmeta_system \
    vbmeta_vendor
BOARD_USES_AB_IMAGE := true
# ⚠ PRODUCT_USE_DYNAMIC_PARTITIONS is NOT a BOARD_ variable and is readonly by
# the time BoardConfig.mk is read -- assigning it here is a hard error. It
# lives in omni_S666LN.mk instead. device_itel_S666LN/BoardConfig.mk:451
# records the same split for the ROM tree; this repeated it.

# --- recovery fstab. The SAME fstab first-stage init and /vendor use, exactly
# as the ROM tree does -- one file, so recovery and normal boot cannot disagree
# about a mount point. Its sdcard and usb-otg entries (11240000.mmc*,
# 11230000.msdc*, mt_usb*) were verified present on 2026-08-18; the older
# "recovery has no sdcard entry" note is stale.
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery/root/system/etc/recovery.fstab

# --- display. 720x1612 panel (measured from a screencap on build 69).
TARGET_SCREEN_WIDTH := 720
TARGET_SCREEN_HEIGHT := 1612
TARGET_RECOVERY_PIXEL_FORMAT := "RGBX_8888"
TW_THEME := portrait_hdpi
TW_EXTRA_LANGUAGES := true

# Backlight. Measured on the running device: max_brightness reads 4095, and the
# node is the leds class one. ⚠ That node is a SECONDARY interface -- the panel
# is actually driven through the display driver's lcm_setbacklight_cmdq -- but
# it is the one recovery can write, and writing it does light the panel
# (verified 2026-08-19 when the screen came back from a zero backlight).
TW_BRIGHTNESS_PATH := "/sys/class/leds/lcd-backlight/brightness"
TW_MAX_BRIGHTNESS := 4095
TW_DEFAULT_BRIGHTNESS := 1200

# --- temperature readout.
# TWRP defaults to /sys/class/thermal/thermal_zone0/temp (data.cpp:710). On this
# device zone0 is `soc_max`, and EVERY cpu_*/gpu_*/soc_* zone returns EINVAL:
#     cat /sys/class/thermal/thermal_zone0/temp
#     cat: ... Invalid argument
# The MTK LVTS sensors need a thermal HAL that recovery does not run, so there
# is no CPU temperature to be had here. That empty read is why the gauge showed
# 0 degrees.
#
# Measured on the device: of 29 zones, exactly one reports a usable value:
#     thermal_zone28  battery  37000
# so the gauge shows BATTERY temperature. That is not the CPU, and it is
# labelled as CPU in the UI; it is the only real sensor available in recovery.
#
# [!] Unquoted on purpose. twcommon.h:38 is EXPAND(x) -> STRINGIFY(x) -> #x, so
# a quoted value would stringify to a path with embedded quotes.
# [!] Zone numbering comes from driver probe order. If a kernel change reorders
# them this silently reads the wrong sensor; check `cat .../thermal_zone28/type`
# still says `battery`.
TW_CUSTOM_CPU_TEMP_PATH := /sys/class/thermal/thermal_zone28/temp

# --- battery readout.
# Read the battery from sysfs instead of the health HAL.
#
# twrp.cpp:456 picks between two paths: with TW_USE_LEGACY_BATTERY_SERVICES it
# fopen()s /sys/class/power_supply/battery/{capacity,status}; without it, it
# calls GetBatteryInfo(), which goes through libhealthhalutils to
# IHealth::getService().
#
# That HAL route is fragile here. PBRP ships android.hardware.health@2.0-service
# and @2.1-service, but BOTH are `disabled` in their rc files with no `interface`
# lines, so nothing can start them and nothing lazy-starts them either. It only
# ever worked by accident: with NO parseable device VINTF manifest, libhidl logs
# "Potential race detected. The VINTF manifest is not being enforced" and falls
# back to a PASSTHROUGH lookup, which finds
# /system/lib64/hw/android.hardware.health@2.0-impl-2.1.so.
#
# Adding our own manifest (needed for keymint) made the manifest authoritative,
# health is not declared in it, and the passthrough fallback stopped. The gauge
# vanished -- reported the first time a build ever reached the main menu WITH
# that manifest present. sysfs has no such dependency.
TW_USE_LEGACY_BATTERY_SERVICES := true

# --- decryption. THE REASON THIS PORT EXISTS.
# fscrypt v2 policy: Android 11+ and this device is FBE, not FDE. The
# vold.decrypt=trigger_restart_framework path is FDE-only and does not apply.
TW_INCLUDE_CRYPTO := true
TW_INCLUDE_CRYPTO_FBE := true
TW_INCLUDE_FBE_METADATA_DECRYPT := true
TW_USE_FSCRYPT_POLICY := 2
# ⚠ THESE THREE MUST MATCH THE ROM EXACTLY. They are not cosmetic.
#
# KeyMint binds every key blob to the OS version and the two patch levels, and
# `strings` on the stock keymint binary shows these are the ONLY three
# properties it reads:
#     ro.build.version.release  ro.build.version.security_patch
#     ro.vendor.build.security_patch
#
# The TWRP recipe value here was 2127-12-31 / 16.1.0 -- a deliberate far-future
# date. On this device that is fatal: the TEE saw the real metadata key as stale
# and answered KM_ERROR_KEY_REQUIRES_UPGRADE (-62), then failed the upgrade with
# KM_ERROR_INVALID_ARGUMENT (-38), so /data never decrypted and TWRP hung
# forever in waitForService() before even drawing its UI.
#
# Measured on the running ROM (build 71), which is what created the key:
#     /system/build.prop  ro.build.version.release=13
#                         ro.build.version.security_patch=2024-09-05
#     /vendor/build.prop  ro.vendor.build.security_patch=2025-04-05
#
# Proven on the device: with resetprop setting exactly these three values,
# /data decrypted and mounted (dm-12, 228G). With 2127-12-31 it does not.
#
# If the ROM's security patch level ever changes, change it here too.
# [!] PLATFORM_VERSION is NOT set here. version_defaults.mk:130 guards it with
# `ifndef` and runs BEFORE this file, so an assignment here is silently dead --
# the built image came out with ro.build.version.release=12. It is exported by
# tools/build-pbrp.sh instead. The other two below DO work from here.
PLATFORM_SECURITY_PATCH := 2024-09-05
VENDOR_SECURITY_PATCH := 2025-04-05
TW_DEFAULT_LANGUAGE := en

# --- storage / misc
RECOVERY_SDCARD_ON_DATA := true
TW_INCLUDE_NTFS_3G := true

# Mount exFAT with the KERNEL driver, not FUSE.
#
# TWRP prefers exfat-fuse purely because the binary exists: partition.cpp:1597
#   if (Current_File_System == "exfat" && Path_Exists("/system/bin/exfat-fuse"))
# and the kernel path at :1690 is guarded by `if (!exfat_mounted ...)`, so it is
# never reached. Measured on the device 2026-08-20, mounting an OTG stick:
#   I:cmd: /system/bin/exfat-fuse -o big_writes,max_read=131072,... /dev/block/sdd1 /usb_otg
#
# This kernel has exfat natively -- CONFIG_EXFAT_FS=y, and `exfat` is listed in
# /proc/filesystems on the running recovery -- so the FUSE round-trip buys
# nothing and costs throughput on every read and write. Installing a 1.6 GB ROM
# zip from OTG goes through it.
#
# The flag removes the binary (Android.mk:606 drops it from TWRP_REQUIRED_MODULES,
# :789 stops building it) and defines -DTW_NO_EXFAT_FUSE. With the binary gone the
# Path_Exists test fails, the probe block is skipped, and mount() runs with fstype
# "exfat". If that fails, :1692 falls back to vfat, so the safety net survives.
#
# ⚠ It does NOT remove exFAT support: mkexfatfs and fsck.exfat are gated by
# TW_NO_EXFAT, which stays unset, so Format and Repair still work.
#
# 🔑 What is given up: upstream uses a successful FUSE mount as a PROBE, then
# unmounts and lets the kernel mount it -- because "some kernels let us mount
# vfat as exfat which doesn't work out too well" (partition.cpp:1608). Without
# the binary there is no probe, and detection rests on Check_FS_Type()/blkid.
# That is the correct trade here: blkid reads the exFAT superblock directly, and
# this is one known kernel rather than the arbitrary set upstream supports.
TW_NO_EXFAT_FUSE := true
TW_INCLUDE_REPACKTOOLS := true
TW_INCLUDE_RESETPROP := true
TW_HAS_MTP := true
# [!] TW_MTP_DEVICE deliberately NOT set. It would define USB_MTP_DEVICE, the
# fallback path in mtp_MtpServer.cpp, and /dev/mtp_usb is the KERNEL f_mtp
# gadget which this kernel does not have (creating functions/mtp.gs0 fails with
# ENOENT on the device). TWRP prefers FFS when /dev/usb-ffs/mtp/ep0 is writable,
# which init.recovery.usb.rc now provides.
TW_EXCLUDE_APEX := true
TW_NO_SCREEN_BLANK := true
TW_SCREEN_BLANK_ON_BOOT := true
TW_USE_TOOLBOX := true

# --- SELinux. Recovery reuses the ROM tree's policy so the TEE stack keeps the
# labels it was granted; without them keymint cannot open its own trustlets.
BOARD_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy

# --- 🔴 EXPORT THE TW_*/PB_* VARIABLES INTO SOONG. MUST BE LAST.
#
# bootable/recovery does NOT read TW_THEME from make. It reads it from a soong
# VendorConfig namespace:
#   bootable/recovery/soong/makevars.go:8
#     makeVars := ctx.Config().VendorConfig("pbVarsPlugin")
# and vendor/pb/config/BoardConfigSoong.mk is what populates that namespace from
# the TW_* variables set above.
#
# Without this include every TW_* assignment in this file is invisible to the
# recovery build, and it dies in soong bootstrap with
#   (theme selection failed; exiting)
# listing the valid themes -- which reads as "TW_THEME is unset" even though it
# is set right here. Include it AFTER the assignments, or it exports nothing.
include vendor/pb/config/BoardConfigSoong.mk
