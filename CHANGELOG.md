# Changelog

## v1.0
- Stock `adbd` runs as root (uid 0, `u:r:su:s0`) so both `adb shell` and
  `adb shell <cmd>` are root. No KernelSU, no custom kernel, `ro.debuggable`
  left untouched.
- Mechanism: `magiskpolicy --live` rules + `ro.secure=0` / `service.adb.root=1`.
  Three blockers cleared (all verified on-device):
  - `adbd->su` dyntransition denial (adbd would SIGABRT and respawn as shell);
  - on real devices, `netd` (enforcing) denied `use` on a root adbd's
    `su`-labelled sockets, leaving the transport `offline` — fixed with
    `allow netd su fd use` + netd<->su socket perms;
  - on FireOS, `ro.secure` is reasserted to 1 during early boot, so `service.sh`
    now retries until `ro.secure` reads back 0, then restarts adbd once
    (`resetprop` used without `-n`, which does not persist there).
- Installer sets `.sh` scripts to 0755.
- Live on/off toggle via the Magisk Action button (`action.sh`); enabled by
  default at every boot.
- Self-heal in `service.sh` reverts to a plain shell adbd if adbd fails to
  come up, so adb access is never lost.
- Verified root-at-boot on FireOS 11 (Fire TV 4K Max) and Android 16 (OnePlus).
