# Changelog

## v1.0
- Initial release.
- Stock `adbd` runs as root (uid 0, `u:r:su:s0`) so both `adb shell` and
  `adb shell <cmd>` are root. No KernelSU, no custom kernel, `ro.debuggable`
  left untouched.
- Mechanism: `magiskpolicy --live` rule allowing adbd's `adbd->su`
  dyntransition + `ro.secure=0` / `service.adb.root=1`.
- Live on/off toggle via the Magisk Action button (`action.sh`); enabled by
  default at every boot.
- Self-heal in `service.sh` reverts to a plain shell adbd if adbd fails to
  come up, so adb access is never lost.
