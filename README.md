# ADB Root (Magisk module)

Makes stock `adbd` run as **root** so **both** `adb shell` (interactive) and
`adb shell <cmd>` (non-interactive) are root — on a Magisk-only device, **no
KernelSU and no custom kernel**, and **without flipping `ro.debuggable`**.

This is the clean, KernelSU-style outcome: adbd *itself* is genuinely root, so
every shell it spawns is transparently root. No `su` routing, no `LD_PRELOAD`
shim, nothing injected into adbd.

## Proven working

Verified end-to-end from a clean reboot on:

- **Fire TV Stick 4K Max (`karat` / AFTKRT), FireOS 11 (Android 11), user build,
  SELinux enforcing, Magisk 30.7** — the hard case; see the FireOS notes below.
- **onn 4K Pro (Google TV, `jarvis`), user build, SELinux enforcing, Magisk
  30.7** — root at boot plus `cmd`/`pm`/`settings`/`adb install` all working.
- A OnePlus 10T (`GN2200`), Android 16, Magisk 30.7.
- A Magisk 30.6 arm64 **user**-build AVD.

```
adb shell id       -> uid=0(root) ... context=u:r:su:s0   (non-interactive)
adb shell id (cmd) -> uid=0  ctx=u:r:su:s0                 (adb shell <cmd>)
adb shell          -> uid=0(root) ... context=u:r:su:s0   (interactive)
adbd process       -> root  u:r:su:s0
props              -> ro.secure=0  ro.debuggable=0  service.adb.root=1
```

Disabling the module reverts cleanly to stock `shell` adbd on next boot;
re-enabling restores root. Confirmed reversible, and the module **self-heals**
(reverts the props if adbd ever fails to come up root) so you cannot be locked
out of adb.

## How it works

adbd is launched (see `/apex/com.android.adbd/etc/init.rc`) with
`--root_seclabel=u:r:su:s0`, and decides whether to keep root in AOSP's
`packages/modules/adb/daemon/main.cpp::should_drop_privileges`:

```
drop = ro.secure;
if (ro.debuggable && service.adb.root==1) drop = false;
if (service.adb.root==0)                  drop = true;
```

So `ro.secure=0` keeps root (we use this; `ro.debuggable` stays 0). But on a real
device two SELinux/boot blockers have to be cleared as well — both were found and
fixed with on-device evidence:

### Blocker 1 — SELinux dyntransition (all devices)

To stay root, adbd must **dyntransition `adbd` -> `su`**, which base policy
**denies**, so adbd `LOG(FATAL)`s and init respawns it as `shell`:

```
avc: denied { dyntransition } scontext=u:r:adbd:s0 tcontext=u:r:su:s0 \
     tclass=process permissive=0
```

Fix: `allow adbd su process dyntransition` + `permissive su`.

### Blocker 2 — netd can't service a root adbd's sockets (real devices)

On a real device adbd's transport sockets are routed through **netd/fwmarkd**.
Once adbd runs as `su:s0`, its fds/sockets are labelled `su:s0`, and **netd
stays enforcing** (`permissive su` does *not* affect netd), so netd is denied
`use` on them — the adb handshake never completes and the device shows
**`offline`** even though adbd is root:

```
avc: denied { use } scontext=u:r:netd:s0 tcontext=u:r:su:s0 tclass=fd permissive=0
```

Fix: allow **netd** to operate on `su`-labelled fds/sockets
(`allow netd su fd use` + the netd↔su socket perms). The AVD never hit this
because the emulator doesn't fwmark adbd's sockets the same way.

### Blocker 3 — system_server can't service shell-command fds (real devices)

`cmd`, `pm`, `settings`, `am`, `appops`, `dumpsys` and friends don't do the work
in your shell — they hand it to a framework service over the binder
**SHELL_COMMAND** transaction, passing your shell's stdin/stdout/stderr fds along
so the service can read args and write output. With the shell in `su:s0` those
fds are labelled `su:s0`, and **system_server stays enforcing**, so it's denied
`use` on them and the whole transaction aborts:

```
$ adb shell cmd package list packages
cmd: Failure calling service package: Failed transaction (2147483646)

avc: denied { use } comm="cmd" scontext=u:r:system_server:s0 \
     tcontext=u:r:su:s0 tclass=fd permissive=0
```

(`adb install` hits the same wall — it streams the APK over that stdin fd.) Same
shape as Blocker 2, different enforcing peer. Fix: allow **system_server** to
operate on `su`-labelled fds, sockets, pipes and ptys (`allow system_server su fd
use` + the socket/fifo/chr_file perms). Note `service list` still worked without
this — it only talks to servicemanager and passes no fds, which is why the
breakage looks selective.

### Blocker 4 — `ro.secure` is reasserted during early boot (FireOS)

On FireOS, `ro.secure` is set back to `1` *during* boot, **after**
`post-fs-data` runs — so adbd starts (as shell) before our value takes hold. The
reassertion stops a few seconds after `sys.boot_completed`. Measured on-device:

```
post-fs-data (~up5): ro.secure=0
boot_completed (up27): ro.secure=1   <- reverted
set 0 at up33: sticks, and stays 0 forever after
```

Fix: `service.sh` re-applies after boot and **retries until `ro.secure` actually
reads back `0`** (a couple of seconds), *then* restarts adbd once so it re-reads
the props as root. Restarting adbd earlier, while the value is still being reset,
just yields another shell adbd. Importantly `resetprop` is used **without `-n`**
for `ro.secure` (with `-n` the value does not persist on FireOS).

Magisk does not reliably auto-apply a module `sepolicy.rule`, so all the SELinux
rules are applied live with `magiskpolicy --live`.

### What the module does

- `common.sh` (`apply_adbroot`): applies the SELinux rules (dyntransition +
  `permissive su`/`permissive adbd` + the netd↔su and system_server↔su
  fd/socket rules; auto-detects and relaxes a non-`su` `root_seclabel`), then
  sets `ro.secure=0` and `service.adb.root=1`.
- `post-fs-data.sh`: runs `apply_adbroot` early so adbd can come up root on its
  first start on ROMs that don't reset `ro.secure` (no restart needed there).
- `service.sh`: after boot, if adbd isn't already root, re-applies until
  `ro.secure` sticks, restarts adbd once, and **self-heals** (reverts the props)
  if it still can't make adbd root.

## Live toggle (Magisk "Action" button) — `action.sh`

Magisk v26+ shows an **Action** button for modules shipping `action.sh`. Tapping
it toggles adb root **on/off live, no reboot**:

- Default is **ON at every boot**.
- Tap once -> **OFF** until you toggle it back or reboot (reverts adbd to shell).
- Tap again (same boot) -> **ON** again — the SELinux rules applied at boot stay
  in place; the toggle only flips the props and bounces adbd.

State is read from adbd's actual uid, so the button always reflects reality.

## Files

| File | Role |
|------|------|
| `common.sh` | Shared `apply_adbroot()` — SELinux rules + props. |
| `post-fs-data.sh` | Enable early at boot. |
| `service.sh` | Re-assert after boot (retry until it sticks) + self-heal. |
| `action.sh` | Magisk Action-button live on/off toggle. |
| `module.prop`, `customize.sh`, `META-INF/` | Module metadata / installer. |

## Install

- **From a release:** download `adb-root-<version>.zip` from the
  [Releases](../../releases) page and flash it in the Magisk app, then reboot.
- **From source:** zip the repo root (the folder containing `module.prop`) and
  flash that, or push the files into `/data/adb/modules/adbroot/` as root and
  reboot.

Remove: delete `/data/adb/modules/adbroot` (or tap-disable in Magisk) + reboot.

Releases are built and published automatically by GitHub Actions
(`.github/workflows/release.yml`) whenever `version` in `module.prop` changes.

## Caveats / trade-offs

- **App JDWP debugging breaks while adb root is ON.** Because adbd runs in
  `u:r:su:s0`, the platform's JDWP `connectto u:r:adbd:s0` rule no longer
  matches, so attaching a debugger to an app fails. Toggle adb root **OFF**
  (Action button) to debug apps, then back ON.
- **`permissive su` is required, not optional.** An enforcing `su` domain leaves
  adbd root but the transport offline. A minimal explicit allow-set is
  impractical — an interactive root shell's needs are open-ended.
- **`ro.secure=0`** is set system-wide (consumed mainly by adbd; some
  security/CTS checks read it). `ro.debuggable` is left at 0, so the most
  Play-Integrity-visible flag is untouched.
- **ROM-specific seclabel / policy:** the rules are keyed to adbd's
  `--root_seclabel`. `common.sh` handles the common `su` case and auto-detects
  other types; an unusual policy could need tuning — check `dmesg | grep avc`.
- Tested on the two builds listed above; confirm on your target device. If it
  doesn't work, the avc denials (`dmesg | grep -i avc`) plus adbd's context and
  the `ro.secure`/`service.adb.root` props are what to collect.

## History

Earlier drafts tried a props-only path and an `LD_PRELOAD`/`execle->su` shim;
both were incomplete (the props path hit the SELinux dyntransition crash; the
shim needs an injection Magisk can't cleanly do on a user build). Those are
superseded by the sepolicy approach here.
