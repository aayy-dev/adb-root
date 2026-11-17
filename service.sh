#!/system/bin/sh
# After boot: guarantee adbd is root, and self-heal so a failure can never leave
# the system with ro.secure=0 paired with a non-root adbd.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

adbd_is_root() {
    p=$(pidof adbd); p=${p%% *}
    [ -n "$p" ] && [ "$(stat -c %u "/proc/$p" 2>/dev/null)" = "0" ]
}

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done

# If post-fs-data already brought adbd up root (ROMs that don't reset ro.secure),
# there is nothing to do -- and we skip a needless adbd bounce.
adbd_is_root && exit 0

# On ROMs like FireOS, ro.secure is reasserted to 1 during early boot (after
# post-fs-data runs), so adbd starts as shell. The reassertion stops a few
# seconds after boot_completed. Re-apply until ro.secure actually reads back 0
# (i.e. the value finally sticks), THEN restart adbd once so it re-reads the
# props as root. Restarting earlier -- while the value is still being reset --
# just yields another shell adbd, which is exactly what the naive version did.
i=0
while [ "$i" -lt 30 ]; do
    apply_adbroot
    sleep 2
    [ "$(getprop ro.secure)" = "0" ] && break
    i=$((i + 1))
done
setprop ctl.restart adbd
sleep 5

# Race fallback: if adbd lost the restart race, try once more.
if ! adbd_is_root; then
    apply_adbroot
    setprop ctl.restart adbd
    sleep 5
fi

# Self-heal: never leave ro.secure=0 paired with a non-root adbd.
if ! adbd_is_root; then
    resetprop ro.secure 1
    resetprop service.adb.root 0
    setprop ctl.restart adbd
fi
