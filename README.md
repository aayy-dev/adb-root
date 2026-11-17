# ADB Root (Magisk module)

Makes stock `adbd` run as **root** so **both** `adb shell` (interactive) and
`adb shell <cmd>` (non-interactive) are root — on a Magisk-only device, **no
KernelSU and no custom kernel**, and **without flipping `ro.debuggable`**.

This is the clean, KernelSU-style outcome: adbd *itself* is genuinely root, so
every shell it spawns is transparently root. No `su` routing, no `LD_PRELOAD`
shim, nothing injected into adbd.

## Proven working

Verified end-to-end on a Magisk 30.6 arm64 **user**-build AVD, from a clean
reboot:

```
adb shell id       -> uid=0(root) ... context=u:r:su:s0   (non-interactive)
adb shell id (cmd) -> uid=0  ctx=u:r:su:s0                 (adb shell <cmd>)
adb shell          -> uid=0(root) ... context=u:r:su:s0   (interactive)
adbd process       -> root  u:r:su:s0
props              -> ro.secure=0  ro.debuggable=0  service.adb.root=1
```

Disabling the module reverts cleanly to stock `shell` adbd on next boot;
re-enabling restores root. Confirmed reversible.

## How it works — the real blocker was SELinux, not properties

On a user build, adbd is launched (see `/apex/com.android.adbd/etc/init.rc`)
with `--root_seclabel=u:r:su:s0`. When adbd decides to stay root it must
**dyntransition `adbd` -> `su`**, which base policy **denies**, so adbd
`LOG(FATAL)`s and init respawns it as `shell`:

```
avc: denied { dyntransition } for comm="adbd" scontext=u:r:adbd:s0 \
     tcontext=u:r:su:s0 tclass=process permissive=0
init: Service 'adbd' (pid ...) received SIGABRT
```

That crash/respawn is what makes it *look* like `service.adb.root` "reverts to
0." The fix is an **SELinux rule**, combined with the properties adbd reads
(AOSP `packages/modules/adb/daemon/main.cpp::should_drop_privileges`):

```
drop = ro.secure;
if (ro.debuggable && service.adb.root==1) drop = false;
if (service.adb.root==0)                  drop = true;
```

So root is kept by `ro.secure=0` (we use this; `ro.debuggable` stays 0). Magisk
does **not** reliably auto-apply a module `sepolicy.rule`, so the module applies
the rule live with `magiskpolicy --live` at boot.

### What the module does (`common.sh`)

1. `magiskpolicy --live`:
   - `allow adbd su process dyntransition` + `permissive su` (the common case),
   - `permissive adbd` (ROMs that pass no `root_seclabel`),
   - `allow magisk ctl_adbd_prop property_service set`,
   - and, if this ROM's `--root_seclabel` is some other type, a matching
     `allow adbd <T> process dyntransition` + `permissive <T>`.
2. `resetprop -n ro.secure 0` and `resetprop service.adb.root 1`.

`post-fs-data.sh` runs this early so adbd comes up root on its **first** start
(no restart needed). `service.sh` re-asserts after boot and **self-heals**: if
adbd ever fails to come up, it reverts the props and restarts so you are never
locked out of adb.

## Live toggle (Magisk "Action" button) — `action.sh`

Magisk v26+ shows an **Action** button for modules shipping `action.sh`. Tapping
it toggles adb root **on/off live, no reboot**:

- Default is **ON at every boot** (via `post-fs-data.sh`).
- Tap once -> **OFF** until you toggle it back or reboot (reverts adbd to shell).
- Tap again (same boot) -> **ON** again — works because the SELinux rules
  applied at boot stay in place; the toggle only flips the props and bounces
  adbd.

State is read from adbd's actual uid, so the button always reflects reality.
Both transitions verified live on the AVD within one boot.

## Files

| File | Role |
|------|------|
| `common.sh` | Shared `apply_adbroot()` — SELinux rules + props. |
| `post-fs-data.sh` | Enable at boot (adbd starts root). |
| `service.sh` | Re-assert after boot + self-heal fallback. |
| `action.sh` | Magisk Action-button live on/off toggle. |
| `module.prop`, `customize.sh`, `META-INF/` | Module metadata / installer. |

## Install

- **From a release (recommended):** download `adb-root-<version>.zip` from the
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
  matches, so attaching a debugger (Android Studio / `adb jdwp`) to an app
  fails. Toggle adb root **OFF** (Magisk Action button) when you need to debug
  apps, then back ON.
- **`permissive su` is required, not optional.** An enforcing `su` domain leaves
  adbd running as root but the adb transport never completes its handshake (adb
  shows the device `offline`). A minimal explicit allow-set is impractical — the
  permissions an interactive root shell needs are open-ended — so `permissive
  su` is the pragmatic choice. KernelSU likewise runs adbd in a dedicated
  permissive-style domain, so this is comparable, not worse.
- **`ro.secure=0`** is set system-wide (consumed mainly by adbd; some
  security/CTS checks read it). `ro.debuggable` is left at 0, so the most
  Play-Integrity-visible flag is untouched.
- **ROM-specific seclabel:** the rule is keyed to adbd's `--root_seclabel`.
  `common.sh` handles the common `su` case and auto-detects other types; a ROM
  with an unusual policy could need tuning — check `dmesg | grep avc`.
- **Tested on a Magisk 30.6 arm64 user-build AVD**, including an adversarial
  review with on-device validation. The mechanism is grounded in AOSP +
  on-device evidence, but confirm on your target device.

## History

Earlier drafts tried a props-only path and an `LD_PRELOAD`/`execle->su` shim;
both were incomplete (the props path hit the SELinux dyntransition crash; the
shim needs an injection Magisk can't cleanly do on a user build). Those are
superseded by the sepolicy approach here.
