#
# Copyright (C) 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# PitchBlack Recovery product for the itel RS4 (S666LN).
#
# `omni_` is PBRP/TWRP's product prefix, inherited from OmniROM -- it is not a
# hint that any Omni source is used here.

# ⚠ NOT embedded.mk -- it does not exist in a 12.1 tree and kati reports its
# absence against base_vendor.mk, which is misleading (that file is merely where
# processing stopped). NOT vendor/omni either: this source ships PitchBlack's own
# config at vendor/pb/config/common.mk, which sets TW_THEME and the PB_* flags.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/base.mk)
$(call inherit-product, vendor/pb/config/common.mk)

# vendor/pb/config/common.mk:25 runs
#   pb_devices.py verify $(TARGET_VENDOR) $(PB_CODE) true
# against PitchBlack's OFFICIAL device registry. This device is not in it, and
# that is fine -- tested directly: the script exits 0 and prints nothing, so
# MAINTAINER is simply empty. It is not a gate on unofficial builds.
PB_CODE := S666LN

# Belongs here, not in BoardConfig.mk (readonly there).
PRODUCT_USE_DYNAMIC_PARTITIONS := true

PRODUCT_DEVICE := S666LN
PRODUCT_NAME := omni_S666LN
PRODUCT_BRAND := Itel
PRODUCT_MODEL := itel RS4
PRODUCT_MANUFACTURER := Itel
PRODUCT_RELEASE_NAME := S666LN

PRODUCT_TARGET_VNDK_VERSION := 33

# Identity is the device's real one. The ROM presents an honest itel
# fingerprint rather than a spoof, and recovery has no reason to differ.
PRODUCT_BUILD_PROP_OVERRIDES += \
    TARGET_DEVICE=S666LN \
    PRODUCT_NAME=S666LN

# --- the FBE decryption stack ------------------------------------------------
#
# 🔴 THIS IS WHY THE PORT EXISTS. Our recovery has zero libkeymaster*, so it
# cannot decrypt /data, so it cannot back it up -- which is the one job still
# being done by a banned-source recovery.
#
# ⚠ Every file below comes from STOCK (.build/work/vendor), never from another
# recovery's ramdisk. Importing them from the artifact this replaces would
# smuggle back in the exact dependency the project exists to remove.
#
# The KERNEL half already works: mcDrvModule.ko and isee.ko are in the
# 199-entry recovery module load list, and the 28 mcRegistry trustlets are
# already in proprietary-files.txt. What is missing is userspace.
# ⏸ STAGED FOR STEP 2. These modules do not exist yet -- the blobs are
# extracted by the ROM tree and need .recovery module definitions before
# they can be requested. Building the tree WITHOUT them first proves the
# board config, fstab and prebuilts are right, so that when FBE fails it
# fails for a reason about FBE.
# PRODUCT_PACKAGES += \
#     mcDriverDaemon.recovery \
#     android.hardware.security.keymint-service.trustonic.recovery \
#     android.hardware.gatekeeper@1.0-service.recovery \
#     tee.recovery \
#     kmsetkey_ca.trustonic.recovery \
#     libMcClient.recovery \
#     libcppbor_external.recovery \
#     android.hardware.gatekeeper@1.0.recovery

# No PRODUCT_COPY_FILES for the ramdisk: build/make/core/Makefile:2077 copies
# $(TARGET_DEVICE_DIR)/recovery/root wholesale into the recovery ramdisk, so
# everything under recovery/root/ (fstab, the TEE binaries, init.recovery.mt6789.rc)
# is installed automatically. A PRODUCT_COPY_FILES for the same path would be a
# second rule for one target.
