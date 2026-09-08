#!/bin/bash
#
# pbrp-lp-accept.sh — prove the liblp partition tools on a device running PBRP.
#
# WHY THIS EXISTS
# ===============
# "The binary is in the ramdisk" is not the test. A port-ROM installer needs
# lptools to WRITE the super metadata from recovery and have the change stick,
# and every one of the failure modes below is invisible to `ls`:
#   - the binary is there but its libs are not, so it dies in the linker
#   - it runs but cannot find the super device, so every subcommand no-ops
#   - it edits the metadata in RAM and the write back to the metadata slot fails
#   - it works on the active slot only
# So this runs a real create -> map -> write -> read-back -> unmap -> remove
# round trip on a SCRATCH partition and checks the metadata after each step.
#
# 🔴 It writes to the super METADATA. It never touches an existing partition:
#    the scratch name is unique, the size is small, and the run ends by
#    removing it and asserting the partition table is back to what it was.
#
# Run it with the phone in PBRP and adb up:
#     bash tools/pbrp-lp-accept.sh
set -o pipefail
SCRATCH=rs4lpaccept
SIZE=8388608          # 8 MiB
fail=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
sh_() { adb shell "$@" 2>&1; }

echo "== 0. it is PBRP, not the ROM"
state=$(adb get-state 2>&1)
mode=$(sh_ 'getprop ro.twrp.boot; getprop ro.bootmode' | tr -d '\r' | tr '\n' ' ')
echo "   adb state: ${state}   ro.twrp.boot/ro.bootmode: ${mode}"
case "$(sh_ 'ls /sbin/recovery /system/bin/recovery 2>/dev/null' | tr -d '\r')" in
  *recovery*) pass "a recovery binary is present" ;;
  *) bad "no recovery binary — is the phone actually in PBRP?" ;;
esac

echo
echo "== 1. the tools are in the ramdisk AND they run"
for t in lptools lpdump lpmake lpadd lpflash lpunpack bootctl; do
    if sh_ "ls /system/bin/$t" | grep -q "$t"; then
        # every one of these prints usage on a bare invocation; a linker
        # failure prints "CANNOT LINK EXECUTABLE" instead, which is the
        # failure this check exists for.
        out=$(sh_ "$t" | head -3)
        if echo "$out" | grep -qi 'CANNOT LINK\|not found\|No such file'; then
            bad "$t present but does not run: $(echo "$out" | head -1)"
        else
            pass "$t runs: $(echo "$out" | head -1 | cut -c1-70)"
        fi
    else
        bad "$t MISSING from /system/bin"
    fi
done

echo
echo "== 2. lpdump reads this device's metadata from recovery"
groups=$(sh_ 'lpdump' | sed -n '/Group table:/,$p')
echo "$groups" | sed 's/^/   /' | head -20
if echo "$groups" | grep -q 'mtk_dynamic_partitions'; then
    pass "group table readable in recovery"
else
    bad "lpdump could not read the group table"
fi

echo
echo "== 3. lptools sees the super and reports free space"
free=$(sh_ 'lptools free')
echo "$free" | sed 's/^/   /'
echo "$free" | grep -q 'Free space:' && pass "lptools free answered" || bad "lptools free did not answer"

echo
echo "== 4. round trip: create -> map -> write -> read back -> unmap -> remove"
before=$(sh_ 'lpdump' | grep -c '^  Name:')
echo "   partitions before: ${before}"
sh_ "lptools create ${SCRATCH} ${SIZE}" | sed 's/^/   /'
if sh_ 'lpdump' | grep -q "Name: ${SCRATCH}"; then
    pass "create — the partition is in the METADATA, not just in RAM"
else
    bad "create did not reach the metadata"
fi
sh_ "lptools map ${SCRATCH}" | sed 's/^/   /'
if sh_ "ls -l /dev/block/mapper/${SCRATCH}" | grep -q "${SCRATCH}"; then
    pass "map — /dev/block/mapper/${SCRATCH} exists"
    sh_ "dd if=/dev/urandom of=/tmp/lpaccept.bin bs=4096 count=64 2>/dev/null; \
         dd if=/tmp/lpaccept.bin of=/dev/block/mapper/${SCRATCH} bs=4096 count=64 conv=fsync 2>&1 | tail -1" | sed 's/^/   /'
    a=$(sh_ "md5sum /tmp/lpaccept.bin" | awk '{print $1}')
    b=$(sh_ "dd if=/dev/block/mapper/${SCRATCH} bs=4096 count=64 2>/dev/null | md5sum" | awk '{print $1}')
    echo "   wrote ${a}  read ${b}"
    [ -n "$a" ] && [ "$a" = "$b" ] && pass "256 KiB written and read back identical" \
                                   || bad "read-back differs — a raw write to a mapped logical partition does not stick"
else
    bad "map produced no device node"
fi
sh_ "lptools unmap ${SCRATCH}" | sed 's/^/   /'
sh_ "lptools remove ${SCRATCH}" | sed 's/^/   /'
after=$(sh_ 'lpdump' | grep -c '^  Name:')
if sh_ 'lpdump' | grep -q "Name: ${SCRATCH}"; then
    bad "🔴 SCRATCH PARTITION ${SCRATCH} IS STILL IN THE METADATA — remove it by hand"
elif [ "$before" = "$after" ]; then
    pass "remove — partition table back to ${after} entries, exactly as before"
else
    bad "partition count changed ${before} -> ${after} after a full round trip"
fi
sh_ 'rm -f /tmp/lpaccept.bin' >/dev/null

echo
echo "== 5. the partition list the GUI will show"
# Every partition TWRP creates logs "Processing '<mount point>'" from
# Process_Fstab_Line, so a mount point that appears twice IS a duplicate entry.
log=$(sh_ 'cat /tmp/recovery.log 2>/dev/null || cat /cache/recovery/log 2>/dev/null')
seen=$(echo "$log" | grep -cE "Processing '/")
echo "   ${seen} 'Processing' lines in the recovery log"
if [ "${seen:-0}" -lt 10 ]; then
    bad "the recovery log has almost no Processing lines — this check could not run"
else
    # /data and /metadata legitimately appear twice: Process_Fstab runs a
    # SECOND pass over the vendor fstab for exactly those two, and that pass
    # ERASES the entry the first pass made before adding its own
    # (partitionmanager.cpp, the `parse_userdata` block). Verified in the final
    # partition dump -- one Data, one Metadata. Everything else appearing
    # twice is a real duplicate entry in the menus.
    dupes=$(echo "$log" | grep -oE "Processing '[^']+'" \
            | grep -vE "'(/data|/metadata)'" \
            | sort | uniq -c | awk '$1>1{print $3}')
    if [ -z "$dupes" ]; then
        pass "no mount point is processed twice (the five /mnt/vendor/* duplicates are gone)"
    else
        bad "still processed twice: $(echo $dupes)"
    fi
fi
# and the names the two menus actually render
echo "   display names now on the fstab-derived entries:"
echo "$log" | grep -E "Display_Name: |Backup_Display_Name: " | head -8 | sed 's/^/     /'

echo
if [ "$fail" -eq 0 ]; then
    echo "== ALL CHECKS PASSED"
else
    echo "== ${fail} CHECK(S) FAILED"
fi
exit "$fail"
