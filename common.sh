#!/system/bin/sh
# Shared logic: apply the SELinux rules that let a root adbd survive, and set
# the props that make adbd keep root. Sourced by post-fs-data.sh and service.sh.
#
# WHY (three independent blockers, all verified on-device):
#  1. adbd is launched with `--root_seclabel=u:r:<T>:s0` (usually su). To stay
#     root it must dyntransition adbd -> <T>, which base policy denies, so adbd
#     LOG(FATAL)s and init respawns it as shell. We allow that dyntransition.
#  2. On a real device adbd's sockets are routed through netd/fwmarkd. Once adbd
#     runs as <T>, its fds/sockets are labelled <T>, and netd (which stays
#     enforcing -- `permissive su` does NOT affect it) is denied `use` on them,
#     so the adb transport never completes its handshake and the device shows
#     `offline`. We must allow netd to operate on <T>-labelled fds/sockets.
#  3. cmd/pm/settings/am/appops/dumpsys etc. use the binder SHELL_COMMAND
#     transaction, which passes the shell's stdio fds to system_server. With the
#     shell in <T>, those fds are labelled <T>; system_server stays enforcing and
#     is denied `use` on them, so the transaction aborts with
#     `Failed transaction (2147483646)`. Same shape as #2, different peer. We must
#     allow system_server to operate on <T>-labelled fds/sockets/pipes/ptys.
# Magisk does not reliably auto-apply a module sepolicy.rule, so we apply live.

apply_adbroot() {
    MP=/data/adb/magisk/magiskpolicy
    [ -x "$MP" ] || MP=$(command -v magiskpolicy) || MP=magiskpolicy

    # su/adbd types always exist on a Magisk device.
    #  - adbd->su dyntransition + permissive su: the common root_seclabel=su case.
    #    permissive su is REQUIRED -- an enforcing su domain leaves adbd root but
    #    the adb transport offline.
    #  - permissive adbd: ROMs that pass no root_seclabel.
    #  - netd<->su fd/socket rules: let the fwmark/netd path service adbd's
    #    now-su-labelled transport socket (without these the device goes offline).
    #  - system_server<->su fd/socket/pipe/pty rules: let the binder SHELL_COMMAND
    #    path work, so cmd/pm/settings/am/appops/dumpsys do not fail with
    #    `Failed transaction (2147483646)`.
    #  - system_server->su binder {call transfer}: `adb install` streams via the
    #    `abb` helper (in the su context) and registers a result callback;
    #    system_server calls BACK into su to deliver the result. Base policy denies
    #    (and dontaudits) that, so abb hangs forever waiting. cmd/pm don't use a
    #    cross-process callback, which is why only install hangs.
    "$MP" --live \
        "allow adbd su process dyntransition" \
        "permissive su" \
        "permissive adbd" \
        "allow magisk ctl_adbd_prop property_service set" \
        "allow netd su fd use" \
        "allow netd su unix_stream_socket { read write getattr getopt setopt }" \
        "allow netd su tcp_socket { read write getattr getopt setopt }" \
        "allow netd su udp_socket { read write getattr getopt setopt }" \
        "allow system_server su fd use" \
        "allow system_server su unix_stream_socket { read write getattr getopt setopt }" \
        "allow system_server su fifo_file { read write getattr ioctl }" \
        "allow system_server su chr_file { read write getattr ioctl }" \
        "allow system_server su binder { call transfer }" 2>/dev/null

    # Portability: if this ROM uses some OTHER root_seclabel type, relax it too.
    RL=$(grep -rhoE -- '--root_seclabel=u:r:[a-zA-Z0-9_]+:s0' \
            /apex/com.android.adbd/etc/*.rc \
            /system/etc/init/*.rc /system/etc/init/hw/*.rc \
            /system_ext/etc/init/*.rc \
            /vendor/etc/init/*.rc /vendor/etc/init/hw/*.rc 2>/dev/null | head -n1)
    T=$(echo "$RL" | sed -E 's/.*u:r:([a-zA-Z0-9_]+):s0/\1/')
    if [ -n "$T" ] && [ "$T" != "su" ] && [ "$T" != "adbd" ]; then
        "$MP" --live \
            "allow adbd $T process dyntransition" "permissive $T" \
            "allow netd $T fd use" \
            "allow netd $T unix_stream_socket { read write getattr getopt setopt }" \
            "allow netd $T tcp_socket { read write getattr getopt setopt }" \
            "allow netd $T udp_socket { read write getattr getopt setopt }" \
            "allow system_server $T fd use" \
            "allow system_server $T unix_stream_socket { read write getattr getopt setopt }" \
            "allow system_server $T fifo_file { read write getattr ioctl }" \
            "allow system_server $T chr_file { read write getattr ioctl }" \
            "allow system_server $T binder { call transfer }" 2>/dev/null
    fi

    # Keep adbd root. ro.secure=0 alone suffices; service.adb.root=1 also covers
    # the (ro.debuggable && adb.root) branch. ro.debuggable is deliberately NOT
    # touched.
    #
    # IMPORTANT: do NOT pass `resetprop -n` for ro.secure. With -n the value does
    # not persist on some ROMs (e.g. FireOS): it reverts to 1 before adbd's first
    # start, so adbd comes up shell even though we "set" it. Without -n it sticks.
    resetprop ro.secure 0
    resetprop service.adb.root 1
}
