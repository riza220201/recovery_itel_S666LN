#!/system/bin/sh
#
# sync-rom-spl.sh — make the recovery adopt the INSTALLED ROM's KeyMint identity.
#
# WHY THIS EXISTS
#   KeyMint binds every key blob to the OS version and the two patch levels, and
#   `strings` on this device's Trustonic keymint shows it reads exactly three
#   properties and no others:
#       ro.build.version.release
#       ro.build.version.security_patch
#       ro.vendor.build.security_patch
#   A recovery whose values do not match the ROM that CREATED the metadata key is
#   refused by rollback protection, and /data never decrypts.
#
#   Baking those values in at build time pins the recovery to one ROM. It broke
#   exactly that way on 2026-08-24: Tier B moved the ROM from 2024-09-05 to
#   2026-02-01, this recovery still said 2024-09-05, and PBRP could no longer
#   open /data (no userdata entry in /dev/block/mapper, "Unable to decrypt
#   metadata encryption", 0 MB internal storage). Android survived the jump
#   because vold upgrades the key blob; a recovery BEHIND the key has no
#   downgrade path and never can.
#
#   So: read the values off the ROM that is actually installed, on the active
#   slot, and adopt them before keymint starts.
#
# 🔴 MOUNTPOINTS ARE DELIBERATELY NOT /system AND /vendor.
#   In recovery those paths are the RAMDISK's, and /system/bin is where sh,
#   resetprop and the whole TEE stack live. Mounting the real system partition
#   over /system would shadow the running environment mid-script.
#
# 🔴 FAILURE MUST BE SILENT AND HARMLESS.
#   Every step is guarded and the script always exits 0. If the ROM cannot be
#   read — freshly wiped device, no ROM installed, unexpected layout — the
#   compiled-in BoardConfig values stay in place. A recovery that cannot decrypt
#   is an inconvenience; a recovery that does not boot is unrecoverable.

LOG=/tmp/sync-rom-spl.log
M=/tmp/.romspl
exec 2>>"$LOG"
echo "=== sync-rom-spl $(date 2>/dev/null) ===" >>"$LOG"

SLOT=$(getprop ro.boot.slot_suffix)
echo "slot='$SLOT'" >>"$LOG"

mkdir -p "$M/system" "$M/vendor" 2>/dev/null

# mount <label> <mountpoint>  — try erofs then ext4; never fatal
try_mount() {
    _dev="/dev/block/mapper/$1$SLOT"
    [ -e "$_dev" ] || _dev="/dev/block/mapper/$1"
    [ -e "$_dev" ] || { echo "  no device for $1"; return 1; }
    for fs in erofs ext4; do
        if mount -t "$fs" -o ro "$_dev" "$2" 2>/dev/null; then
            echo "  mounted $_dev ($fs) at $2"; return 0
        fi
    done
    echo "  FAILED to mount $_dev"; return 1
}

# read a property out of a build.prop, tolerating both system-as-root layouts
prop_from() {   # prop_from <dir> <key>
    for p in "$1/build.prop" "$1/system/build.prop" "$1/etc/build.prop"; do
        [ -f "$p" ] || continue
        v=$(grep -m1 "^$2=" "$p" 2>/dev/null | cut -d= -f2-)
        [ -n "$v" ] && { echo "$v"; return 0; }
    done
    return 1
}

# adopt <key> <value> — only if we actually read something
adopt() {
    [ -n "$2" ] || { echo "  $1: nothing read, keeping '$(getprop "$1")'" >>"$LOG"; return; }
    old=$(getprop "$1")
    [ "$old" = "$2" ] && { echo "  $1: already '$2'" >>"$LOG"; return; }
    if /system/bin/resetprop "$1" "$2" 2>/dev/null; then
        echo "  $1: '$old' -> '$2'" >>"$LOG"
    else
        echo "  $1: resetprop FAILED, keeping '$old'" >>"$LOG"
    fi
}

try_mount system "$M/system" >>"$LOG" 2>&1
try_mount vendor "$M/vendor" >>"$LOG" 2>&1

REL=$(prop_from "$M/system" ro.build.version.release)
SPL=$(prop_from "$M/system" ro.build.version.security_patch)
VSPL=$(prop_from "$M/vendor" ro.vendor.build.security_patch)
echo "read: release='$REL' spl='$SPL' vendor_spl='$VSPL'" >>"$LOG"

adopt ro.build.version.release          "$REL"
adopt ro.build.version.security_patch   "$SPL"
adopt ro.vendor.build.security_patch    "$VSPL"

umount "$M/system" 2>/dev/null
umount "$M/vendor" 2>/dev/null

# a marker so a human (or a check) can tell this ran at all, and with what
setprop ro.rs4.spl_sync "${SPL:-none}"
echo "done. release=$(getprop ro.build.version.release) spl=$(getprop ro.build.version.security_patch) vspl=$(getprop ro.vendor.build.security_patch)" >>"$LOG"
exit 0
