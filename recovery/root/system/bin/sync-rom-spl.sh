#!/system/bin/sh
#
# sync-rom-spl.sh [early|late] — make the recovery adopt the INSTALLED ROM's
#                                KeyMint identity.
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
# 🔴 WHY THERE ARE TWO MODES, AND WHY ONE PASS CANNOT WORK
#   Measured on hardware 2026-09-04, on the first boot where this script ever
#   ran at all:
#       t=2.390  this script runs from `on post-fs`
#       t=2.645  mcDriverDaemon · t=2.647 keymint · t=2.649 gatekeeper
#       t=2.78   /system/bin/recovery maps and mounts the logical partitions
#   The ROM lives on LOGICAL partitions, and nothing maps them until TWRP does
#   — 390 ms AFTER this script and AFTER keymint. So at post-fs there is simply
#   nothing to read:
#       no device for system / no device for vendor
#
#   And it cannot be fixed by moving the exec later. `exec` blocks init's
#   command queue (init.cpp:1002 gates on is_exec_service_running before EACH
#   command), and the process that creates those nodes is started BY INIT AFTER
#   the exec. A script that waited for them would deadlock the boot.
#
#   So the read and the use are split across two runs:
#       late   after TWRP has mapped the partitions: mount, read the truth,
#              adopt it, and CACHE it on the persist partition.
#       early  at post-fs, before keymint: adopt from that cache. persist is a
#              PHYSICAL partition and is already mounted rw two lines above the
#              exec, so it is readable at a point the ROM is not.
#   Steady state is therefore correct at post-fs. The one boot that is not is
#   the first one after the ROM's SPL moves, and `late` repairs that in-place by
#   restarting keymint — see rs4.spl_changed below.
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
#
# MARKERS, all readable in one getprop sweep:
#   ro.rs4.spl_sync    what `early` adopted, or `none` if the cache was unusable
#   ro.rs4.spl_late    what `late`  read,    or `none` if the ROM was unreadable
#   rs4.spl_changed    1 only if `late` actually moved a value; the rc restarts
#                      keymint on this, so a normal boot triggers no restart

MODE="${1:-late}"
LOG=/tmp/sync-rom-spl.log
M=/tmp/.romspl
CACHE=/mnt/vendor/persist/rs4-spl.conf
CHANGED=0

exec 2>>"$LOG"
echo "=== sync-rom-spl [$MODE] $(date 2>/dev/null) ===" >>"$LOG"

# ---- validation. The cache lives on a partition only root can write, but these
# values are fed straight to resetprop, so a corrupt or truncated file must not
# be able to set an arbitrary property. Cheap, and it also catches a half-written
# cache from a power cut mid-write.
valid_release() { case "$1" in ""|*[!0-9.]*) return 1;; *) return 0;; esac; }
valid_date() {
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0;;
        *) return 1;;
    esac
}

# adopt <key> <value> — only if we actually read something
adopt() {
    [ -n "$2" ] || { echo "  $1: nothing read, keeping '$(getprop "$1")'" >>"$LOG"; return; }
    old=$(getprop "$1")
    [ "$old" = "$2" ] && { echo "  $1: already '$2'" >>"$LOG"; return; }
    if /system/bin/resetprop "$1" "$2" 2>/dev/null; then
        echo "  $1: '$old' -> '$2'" >>"$LOG"
        CHANGED=1
    else
        echo "  $1: resetprop FAILED, keeping '$old'" >>"$LOG"
    fi
}

# =====================================================================  EARLY
if [ "$MODE" = "early" ]; then
    REL=""; SPL=""; VSPL=""
    if [ -f "$CACHE" ]; then
        # read it without sourcing it: a cache file is data, not code.
        REL=$(grep -m1 '^release='     "$CACHE" 2>/dev/null | cut -d= -f2-)
        SPL=$(grep -m1 '^spl='         "$CACHE" 2>/dev/null | cut -d= -f2-)
        VSPL=$(grep -m1 '^vendor_spl=' "$CACHE" 2>/dev/null | cut -d= -f2-)
        echo "cache: release='$REL' spl='$SPL' vendor_spl='$VSPL'" >>"$LOG"
        valid_release "$REL" || { echo "  ! release rejected"  >>"$LOG"; REL=""; }
        valid_date    "$SPL" || { echo "  ! spl rejected"      >>"$LOG"; SPL=""; }
        valid_date   "$VSPL" || { echo "  ! vendor_spl rejected" >>"$LOG"; VSPL=""; }
    else
        echo "cache: $CACHE absent (first boot, or persist not mounted)" >>"$LOG"
    fi

    adopt ro.build.version.release          "$REL"
    adopt ro.build.version.security_patch   "$SPL"
    adopt ro.vendor.build.security_patch    "$VSPL"

    setprop ro.rs4.spl_sync "${SPL:-none}"
    echo "done[early]. release=$(getprop ro.build.version.release) spl=$(getprop ro.build.version.security_patch) vspl=$(getprop ro.vendor.build.security_patch)" >>"$LOG"
    exit 0
fi

# ======================================================================  LATE
SLOT=$(getprop ro.boot.slot_suffix)
echo "slot='$SLOT'" >>"$LOG"

# The trigger (twrp.super.symlinks_created) fires on the FIRST symlink TWRP
# creates, not the last, so the nodes we want may be a few ms behind it. Bounded
# wait -- this runs as a plain `start`ed service, NOT an exec, so waiting here
# delays nothing but ourselves.
i=0
while [ $i -lt 100 ]; do
    [ -e "/dev/block/mapper/system$SLOT" ] && [ -e "/dev/block/mapper/vendor$SLOT" ] && break
    i=$((i+1))
    sleep 0.1
done
echo "waited ${i}00 ms for the mapper nodes" >>"$LOG"

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

try_mount system "$M/system" >>"$LOG" 2>&1
try_mount vendor "$M/vendor" >>"$LOG" 2>&1

REL=$(prop_from "$M/system" ro.build.version.release)
SPL=$(prop_from "$M/system" ro.build.version.security_patch)
VSPL=$(prop_from "$M/vendor" ro.vendor.build.security_patch)
echo "read: release='$REL' spl='$SPL' vendor_spl='$VSPL'" >>"$LOG"

valid_release "$REL" || { echo "  ! release rejected"    >>"$LOG"; REL=""; }
valid_date    "$SPL" || { echo "  ! spl rejected"        >>"$LOG"; SPL=""; }
valid_date   "$VSPL" || { echo "  ! vendor_spl rejected" >>"$LOG"; VSPL=""; }

adopt ro.build.version.release          "$REL"
adopt ro.build.version.security_patch   "$SPL"
adopt ro.vendor.build.security_patch    "$VSPL"

umount "$M/system" 2>/dev/null
umount "$M/vendor" 2>/dev/null

# ---- refresh the cache `early` will use on the NEXT boot.
# Written whole then renamed, so a power cut cannot leave a half-file that the
# validators would have to catch. Only written when all three were read.
#
# [!] THE FILE COMES OUT u:object_r:unlabeled:s0 AND THAT IS EXPECTED HERE, not
# an oversight. The recovery's sepolicy does not define persist_data_file at
# all -- the kernel says so on every boot:
#     SELinux: Context u:object_r:persist_data_file:s0 is not valid (left unmapped)
# so EVERYTHING on this mount is unmapped in recovery, lost+found included, and
# a chcon to that type would fail because the type does not exist here. This is
# the same footing as the Trustonic gatekeeper TA's own
# failure_records.dat, which is written on this mount every decrypt and was
# proven working on 2026-09-03. Measured, not assumed: `early` read this file
# back under u:r:recovery:s0 on hardware.
if [ -n "$REL" ] && [ -n "$SPL" ] && [ -n "$VSPL" ]; then
    if [ -d /mnt/vendor/persist ]; then
        if { echo "release=$REL"; echo "spl=$SPL"; echo "vendor_spl=$VSPL"; } > "$CACHE.tmp" 2>/dev/null \
           && mv -f "$CACHE.tmp" "$CACHE" 2>/dev/null; then
            echo "  cache written: $CACHE" >>"$LOG"
        else
            echo "  ! cache write FAILED (persist ro?)" >>"$LOG"
            rm -f "$CACHE.tmp" 2>/dev/null
        fi
    else
        echo "  ! /mnt/vendor/persist not mounted, no cache" >>"$LOG"
    fi
else
    echo "  cache NOT written: incomplete read, keeping the previous one" >>"$LOG"
fi

setprop ro.rs4.spl_late "${SPL:-none}"

# ---- and only now, if something actually moved, ask the rc to restart keymint.
# keymint reads these three properties ONCE at its own startup, so a value that
# changed after it started is not in effect until it does. A normal boot changes
# nothing and therefore restarts nothing -- which matters, because a restart
# lands in the middle of TWRP's own startup.
if [ "$CHANGED" = "1" ]; then
    echo "  values MOVED -> requesting keymint restart" >>"$LOG"
    setprop rs4.spl_changed 1
else
    echo "  nothing moved, no restart" >>"$LOG"
fi

echo "done[late]. release=$(getprop ro.build.version.release) spl=$(getprop ro.build.version.security_patch) vspl=$(getprop ro.vendor.build.security_patch)" >>"$LOG"
exit 0
