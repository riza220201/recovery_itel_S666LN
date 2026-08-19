#!/bin/bash
#
# package-pbrp.sh <recovery-fragment.cpio> <out.zip>
#
# Wrap the PBRP recovery ramdisk fragment in a flashable zip.
#
# THE ZIP SHIPS THE FRAGMENT, NOT A WHOLE IMAGE.
# vendor_boot holds two ramdisk fragments and only the recovery one is ours.
# The PLATFORM fragment carries the kernel modules, the four touch firmware
# blobs and the patched adaptive-ts.ko, and both are loaded in recovery -- a
# PBRP-built vendor_boot flashed whole gives a touch UI with no touch input,
# because PBRP's own platform fragment is four bytes.
#
# An earlier version of this script shipped a 64 MiB image that had been
# repacked on the BUILD HOST against a donor. That works, but pins the platform
# fragment to whatever the donor held on the day it was built -- and the donor
# in use was three ROM builds out of date. The installer now does the swap on
# the device, against the vendor_boot that is actually installed, so it stays
# correct across ROM updates. It also makes the zip ~28 MB smaller.
#
# magiskboot is NOT shipped: PBRP already builds it to /system/bin/magiskboot,
# verified present both in the built ramdisk and on the running device.
#
# Round-trip proven on this device before adopting: `magiskboot repack` of an
# UNMODIFIED vendor_boot reproduced the input byte for byte (sha256 identical,
# AVB footer included), and both fragments re-unpacked unchanged.
set -euo pipefail

FRAG="${1:?usage: package-pbrp.sh <recovery-fragment.cpio> <out.zip>}"
OUT="${2:?usage: package-pbrp.sh <recovery-fragment.cpio> <out.zip>}"
[ -f "${FRAG}" ] || { echo "!! no fragment at ${FRAG}" >&2; exit 2; }

SZ=$(stat -c%s "${FRAG}")
# a recovery fragment for this device is tens of MB; anything tiny is the
# four-byte-platform-fragment mistake in another costume.
[ "${SZ}" -gt 1000000 ] || { echo "!! ${FRAG} is only ${SZ} B -- that is not a recovery ramdisk" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/META-INF/com/google/android"
cp "${FRAG}" "${TMP}/vendor_ramdisk_recovery.cpio"
echo "# dummy; update-binary is a shell script" > "${TMP}/META-INF/com/google/android/updater-script"
cp "${HERE}/update-binary" "${TMP}/META-INF/com/google/android/update-binary"
chmod 755 "${TMP}/META-INF/com/google/android/update-binary"

rm -f "${OUT}"
( cd "${TMP}" && zip -q -r -X "${OUT}" META-INF vendor_ramdisk_recovery.cpio )
echo "== $(stat -c%s "${OUT}") bytes  ${OUT}"

unzip -l "${OUT}" | grep -q "vendor_ramdisk_recovery.cpio" \
  || { echo "!! the zip does not carry vendor_ramdisk_recovery.cpio" >&2; exit 3; }
sh -n "${HERE}/update-binary" || { echo "!! update-binary has a syntax error" >&2; exit 3; }
echo "== control OK: fragment present, installer parses"
