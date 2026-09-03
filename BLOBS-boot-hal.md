android.hardware.boot@1.0-impl-1.2-mtkimpl.so  (+ ../libmtk_bsg.so)

WHY THESE TWO FILES ARE HERE
PBRP ships /system/bin/android.hardware.boot@1.2-service and its rc, complete
with `interface android.hardware.boot@1.0::IBootControl default` lines -- but
NOT the passthrough implementation the service dlopens. So the service starts,
fails instantly, and init reports:

    LegacySupport: Could not get passthrough implementation for
      android.hardware.boot@1.0::IBootControl/default
    init: Service 'boot-hal-1-2' (pid ...) exited with status 1

Meanwhile TWRP calls IBootControl::getService(), which is the BLOCKING variant,
so it retries forever:

    HidlServiceManagement: Waited one second for
      android.hardware.boot@1.0::IBootControl/default
    hwservicemanager: ...not registered, trying to start it as a lazy HAL

That is a hang on the splash screen with no error shown, and it looks exactly
like the decryption failures it has nothing to do with. Recovery sat at 2
threads in futex_wait; every crypto service (keystore2, keymint, mcDriverDaemon)
was IDLE in binder_wait_for_work, which is what proved the block was elsewhere.

Proven on the device: pushing these two files to a RUNNING, hung recovery was
enough -- hwservicemanager retries once a second, so the HAL came up on its own,
recovery went 2 -> 4 threads, reached the main menu, and /data decrypted and
mounted (dm-12, 228G) with no further intervention.

WHY ONLY TWO FILES
Everything else the impl needs is already in the ramdisk. Checked on the device:
libbase, liblog, libhidlbase, libhardware, libutils, libc++ and all three
android.hardware.boot@1.x.so interface libraries were already present; only
libmtk_bsg.so (the impl's MTK dependency) and the impl itself were missing.

They live under /system/lib64 because the recovery linker's default namespace
searches ONLY /system/${LIB} (/system/etc/ld.config.txt), and passthrough
implementations are looked up in <path>/hw/.

Source: the stock vendor dump (.build/work/vendor), never a third-party recovery.


================================================================================

android.hardware.gatekeeper@1.0-impl.so  +  gatekeeper.trustonic.so
  (both -> system/lib64/hw/;  the second IS libMcGatekeeper.so, copied not
   symlinked;  added 2026-09-03)

WHY THESE TWO FILES ARE HERE
Without them /data cannot be decrypted by anyone who has a screen lock, and the
recovery does not say so -- it HANGS, on "Attempting to decrypt FBE for user
0...", with no error and no timeout. That shipped publicly on 03/09/2026 and a
user reported it the same day.

This is the SAME FAILURE as the IBootControl entry above, one HAL along, and it
is worth stating as a rule: a HAL that is DECLARED in
vendor/etc/vintf/manifest.xml but registered by no running service is strictly
worse than one that is absent, because the declaration is what makes an
unbounded wait legitimate. TWRP calls the blocking getService():

    IGatekeeper::getService()            system/vold/Decrypt.cpp:753
      reached from Decrypt_User -> Decrypt_User_Synth_Pass -> secdis branch
      (secdis, not weaver: this device writes <handle>.secdis, no .weaver file)

and hwservicemanager then tries to lazy-start it once a second, forever:

    init: Control message: Could not find
      'android.hardware.gatekeeper@1.0::IGatekeeper/default' for
      ctl.interface_start from pid: 305 (/system/bin/hwservicemanager)

The default-password path (Decrypt_Device("!")) never touches gatekeeper, which
is why every measurement ever taken on the developer's phone -- which has no
credential -- passed. Decrypt.cpp:896-907 is explicit: Default_Password goes
straight to Decrypt_CE_storage and returns.

WHY ONLY TWO FILES, AND WHY THE OLD ESTIMATE WAS WRONG
The note this replaces in init.recovery.mt6789.rc said shipping gatekeeper
"means importing a chain of system libs", naming libgatekeeper.so and
libhardware.so as "NOT in the stock vendor blob set". Measured in the SHIPPED
3.7.1_13 ramdisk, all of these were already present, built by PBRP:

    system/lib64/libgatekeeper.so                    19744
    system/lib64/libhardware.so                      10752
    system/lib64/android.hardware.gatekeeper@1.0.so 106032
    system/lib64/libhidlbase.so  libutils.so  libc++.so
    system/lib64/libMcClient.so   (already carried for keymint)

So the full closure of impl.so (-> gatekeeper@1.0, libhardware, libhidlbase,
libutils, libc++, libc/m/dl) and of libMcGatekeeper.so (-> libMcClient,
libgatekeeper, liblog, libc++, libc/m/dl) is satisfied by two files, 35,760
bytes. The overstated cost is what justified deferring the work for two weeks;
nobody re-checked it against the artifact.

TWO THINGS BEYOND THE FILES, both proven necessary by isolation
  1. ro.hardware.gatekeeper=trustonic must be SET IN RECOVERY. It lives in
     /vendor/build.prop and /vendor is deliberately never mounted here, so
     libhardware's hw_get_module("gatekeeper") walks its whole fallback chain
     (ro.hardware.gatekeeper -> ro.hardware=mt6789 -> ro.product.board ->
     ro.board.platform -> ro.arch -> "default") and finds nothing, because
     neither gatekeeper.mt6789.so nor gatekeeper.default.so is in this ramdisk.
     With both blobs staged and the property absent, measured on the device:
         Unable to open GateKeeper HAL
         libc: Fatal signal 6 (SIGABRT) in tid 419
  2. /mnt/vendor/persist must be mounted rw. The TA writes its throttling record
     to /mnt/vendor/persist/mcRegistry/failure_records.dat (a literal string in
     libMcGatekeeper.so). Read-only, verify() fails for EVERY password and TWRP
     reports only "Begin Operation failed" -- an error from the keystore call
     AFTER the failed verify, so the message names the wrong layer entirely.

     The tell was that right and wrong PINs failed IDENTICALLY. A correct
     credential and an incorrect one producing the same output is never a
     password problem.

The trustlet itself needed nothing: all 28 of stock's mcRegistry files are
already in this ramdisk, so tlTeeGatekeeper (TA version 100.258) loads as-is.

PROVEN ON HARDWARE 2026-09-03, on the shipped image, from a fresh boot, with a
control, driven over adb with `twrp decrypt <pin>`:
    9999  wrong  -> "Failed to decrypt user 0"                     rejected
    1234  right  -> "User 0 Decrypted Successfully"
                    /data/media/0 lists Alarms Android Audiobooks DCIM
                    in PLAINTEXT; /data/data lists real package names
                    failure_records.dat mtime advances

Source: this device's own revision 28 vendor dump (.build/work/vendor/lib64/hw),
never a third-party recovery.
