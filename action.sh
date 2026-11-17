#!/system/bin/sh
# Magisk "Action" button (v26+). Toggles adb root ON/OFF live, no reboot.
#
# State is derived from reality (adbd's current uid), not a stored flag, so it
# always reflects what adb actually is right now. The module still enables adb
# root at every boot by default (post-fs-data.sh); turning it OFF here lasts only
# until you toggle it back on or until the next reboot. Toggling back ON in the
# same boot works because the SELinux rules applied at boot stay in place -- we
# only flip the props and bounce adbd.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

adbd_uid() {
    p=$(pidof adbd 2>/dev/null)
    [ -n "$p" ] && stat -c %u "/proc/$p" 2>/dev/null
}

cur=$(adbd_uid)

if [ "$cur" = "0" ]; then
    echo "ADB root is ON  ->  turning OFF (until re-toggled or next boot)"
    resetprop -n ro.secure 1
    resetprop service.adb.root 0
    setprop ctl.restart adbd
else
    echo "ADB root is OFF ->  turning ON"
    apply_adbroot            # re-assert SELinux rules + props (idempotent)
    setprop ctl.restart adbd
fi

# adbd is restarting; give it a moment, then report the result.
sleep 3
new=$(adbd_uid)
if [ "$new" = "0" ]; then
    echo "Result: adb root is now ON  (adb shell = root)."
else
    echo "Result: adb root is now OFF (adb shell = shell)."
fi
