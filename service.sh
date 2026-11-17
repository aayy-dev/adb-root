#!/system/bin/sh
# After boot: re-assert only if needed, and self-heal so a failure can never
# leave the system with ro.secure=0 paired with a non-root adbd.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

adbd_is_root() {
    p=$(pidof adbd); p=${p%% *}
    [ -n "$p" ] && [ "$(stat -c %u "/proc/$p" 2>/dev/null)" = "0" ]
}

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done

# Normal path: post-fs-data already brought adbd up root -> nothing to do, and
# we avoid a needless adbd bounce (which would drop any early adb session).
adbd_is_root && exit 0

# adbd isn't root (e.g. /apex wasn't mounted yet at post-fs-data on an exotic
# ROM): apply now (/apex is guaranteed mounted post-boot) and restart.
apply_adbroot
setprop ctl.restart adbd
sleep 4

# Still not root? AOSP has already respawned adbd as a usable shell; revert the
# props so adb still works as a normal shell and we don't leave ro.secure=0 set.
if ! adbd_is_root; then
    resetprop -n ro.secure 1
    resetprop service.adb.root 0
    setprop ctl.restart adbd
fi
