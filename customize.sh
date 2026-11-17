#!/system/bin/sh
# Nothing to stage -- the module is pure scripts + policy. Just report.
ui_print "- ADB Root (sepolicy + props)"
ui_print "- Makes stock adbd run as root; reboot to apply."
ui_print "- ro.debuggable is left untouched."

# All .sh must be executable. Magisk sources post-fs-data.sh/service.sh via `sh`
# so 0644 would still boot, but action.sh and manual runs need the exec bit, and
# 0755 is the correct, least-surprising mode for module scripts.
set_perm_recursive "$MODPATH" 0 0 0755 0755
