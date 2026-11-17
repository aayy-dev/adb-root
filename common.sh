#!/system/bin/sh
# Shared logic: apply the SELinux rules that let a root adbd survive, and set
# the props that make adbd keep root. Sourced by post-fs-data.sh and service.sh.
#
# WHY: on a user build, adbd is launched with `--root_seclabel=u:r:<T>:s0`. When
# adbd decides to stay root it must dyntransition adbd -> <T>, which base policy
# denies -> adbd LOG(FATAL)s and init respawns it as shell. Allowing that
# dyntransition (and relaxing <T>) is the actual fix -- not the properties.
# Verified on an AVD: adbd then runs as root in u:r:<T>:s0 and every adb shell
# is root. Magisk does NOT reliably auto-apply module sepolicy.rule, so we apply
# live with magiskpolicy.

apply_adbroot() {
    MAGISKPOLICY=/data/adb/magisk/magiskpolicy
    [ -x "$MAGISKPOLICY" ] || MAGISKPOLICY=$(command -v magiskpolicy 2>/dev/null)
    [ -x "$MAGISKPOLICY" ] || MAGISKPOLICY=$(command -v magiskpolicy)

    # Robust defaults: su and adbd types always exist on a Magisk device.
    # - adbd -> su dyntransition + permissive su covers ROMs whose adbd uses
    #   root_seclabel=u:r:su:s0 (the common case).
    # - permissive adbd covers ROMs that pass no root_seclabel (adbd stays in
    #   its own domain when root). Harmless where it doesn't apply.
    "$MAGISKPOLICY" --live \
        "allow adbd su process dyntransition" \
        "permissive su" \
        "permissive adbd" \
        "allow magisk ctl_adbd_prop property_service set" 2>/dev/null

    # Portability: if this ROM uses some OTHER root_seclabel type, allow that too.
    RL=$(grep -rhoE -- '--root_seclabel=u:r:[a-zA-Z0-9_]+:s0' \
            /apex/com.android.adbd/etc/*.rc /system/etc/init/*.rc \
            /system_ext/etc/init/*.rc /vendor/etc/init/*.rc 2>/dev/null | head -n1)
    T=$(echo "$RL" | sed -E 's/.*u:r:([a-zA-Z0-9_]+):s0/\1/')
    if [ -n "$T" ] && [ "$T" != "su" ] && [ "$T" != "adbd" ]; then
        "$MAGISKPOLICY" --live \
            "allow adbd $T process dyntransition" "permissive $T" 2>/dev/null
    fi

    # Keep adbd root. ro.secure=0 alone suffices; service.adb.root=1 also covers
    # the (debuggable && adb.root) branch. ro.debuggable is deliberately NOT set.
    resetprop -n ro.secure 0
    resetprop service.adb.root 1
}
