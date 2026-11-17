#!/system/bin/sh
# Nothing to stage -- the module is pure scripts + policy. Just report.
ui_print "- ADB Root (sepolicy + props)"
ui_print "- Makes stock adbd run as root; reboot to apply."
ui_print "- ro.debuggable is left untouched."
set_perm_recursive "$MODPATH" 0 0 0755 0644
