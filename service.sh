#!/system/bin/sh
# Belt-and-suspenders: re-assert after boot (covers late property resets), then
# self-heal so a failure can never leave you unable to adb in.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done
sleep 2

apply_adbroot
setprop ctl.restart adbd
sleep 4

# If adbd failed to come back (e.g. a seclabel we couldn't satisfy), revert the
# props and restart so adb still works as a normal shell.
if ! pidof adbd >/dev/null 2>&1; then
    resetprop -n ro.secure 1
    resetprop service.adb.root 0
    setprop ctl.restart adbd
fi
