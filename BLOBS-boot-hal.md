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
