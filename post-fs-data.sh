#!/system/bin/sh
# Early boot (before adbd's first start on most boots). Applying here lets adbd
# come up root on its very first start -- no restart/disconnect needed.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
apply_adbroot
