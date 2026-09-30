#!/system/bin/sh
# -----------------------------------------------------------------
# Mirafix — 解决投屏  v1.1   action button (diagnostics)
# Read-only. Run from the Magisk / KernelSU manager "Action" button
# and share the output when reporting a problem.
# -----------------------------------------------------------------
export PATH=/system/bin:/system/xbin:/system/sbin:/sbin:/vendor/bin

MODDIR="${0%/*}"
TGT=/system_ext/lib64/libsurfaceflinger.so
SRC="$MODDIR/system_ext/lib64/libsurfaceflinger.so"
INFO="$MODDIR/build.info"
LOG=/data/adb/mirafix.log

hr() { echo "------------------------------------------------------------"; }

echo "Mirafix diagnostic / 诊断信息"
hr
echo "[device / 设备]"
for p in ro.product.model ro.product.device ro.build.version.release \
	ro.build.version.sdk ro.build.version.incremental \
	ro.mi.os.version.name ro.mi.os.version.code; do
	echo "  $p = $(getprop $p 2>/dev/null)"
done
echo "  ro.build.fingerprint = $(getprop ro.build.fingerprint 2>/dev/null)"
hr

echo "[root / 获取 root]"
if [ -d /data/adb/modules ]; then
	echo "  /data/adb/modules OK"
fi
for f in /data/adb/magisk /data/adb/ksu /data/adb/ap; do
	[ -d "$f" ] && echo "  found: $f"
done
[ -f /data/adb/magisk.db ] && echo "  magisk.db present (Magisk)"
hr

echo "[module / 模块]"
echo "  dir = $MODDIR"
for f in skip_mount disable unsupported; do
	[ -e "$MODDIR/$f" ] && echo "  flag present: $f"
done
echo "  state  = $(cat "$MODDIR/.boot_state" 2>/dev/null)"
echo "  retry  = $(cat "$MODDIR/.retry_count" 2>/dev/null)"
if [ -f "$INFO" ]; then
	echo "  build.info:"
	sed 's/^/    /' "$INFO"
else
	echo "  build.info MISSING (module not installed correctly)"
fi
hr

echo "[payload / 载荷]"
if [ -f "$SRC" ]; then
	_x=$(md5sum "$SRC" 2>/dev/null)
	echo "  path    = $SRC"
	echo "  md5     = ${_x%% *}"
	echo "  mode    = $(stat -c %a "$SRC" 2>/dev/null)"
	# BusyBox stat has no %C, prefer ls -Z
	_ctx=$(ls -Z "$SRC" 2>/dev/null | head -n 1); _ctx=${_ctx%% *}
	case $_ctx in *:*) : ;; *) _ctx=$(stat -c %C "$SRC" 2>/dev/null) ;; esac
	echo "  context = $_ctx"
	echo "  size    = $(stat -c %s "$SRC" 2>/dev/null)"
else
	echo "  MISSING (nothing will be mounted)"
fi
hr

echo "[target / 目标库]"
OFF=$(sed -n 's/^offset=//p' "$INFO" 2>/dev/null)
echo "  expected offset = ${OFF:-?}"
if command -v nsenter >/dev/null 2>&1; then
	B=$(nsenter -t 1 -m -- dd if="$TGT" bs=1 skip="${OFF:-0}" count=4 2>/dev/null |
		od -An -tx1 | tr -d ' \n')
else
	B=$(dd if="$TGT" bs=1 skip="${OFF:-0}" count=4 2>/dev/null |
		od -An -tx1 | tr -d ' \n')
fi
PH=$(sed -n 's/^patch_hex=//p' "$INFO" 2>/dev/null | head -n 1)
[ -n "$PH" ] || PH=e00308aa
echo "  bytes@$OFF = ${B:-unreadable}   (patched = $PH)"
[ -n "$B" ] && [ "$B" = "$PH" ] && echo "  ✓ bytes match what the installer wrote" ||
	echo "  ! bytes do NOT match what the installer wrote"
echo "  stock md5 = $(sed -n 's/^stock_md5=//p' "$INFO" 2>/dev/null)"
grep " $TGT " /proc/1/mountinfo 2>/dev/null | sed 's/^/  mountinfo: /' || \
	echo "  mountinfo: (no mount on the target file)"
hr

echo "[surfaceflinger]"
sf=$(pidof surfaceflinger)
echo "  pid = ${sf:-not running}"
if [ -n "$sf" ] && [ -f "$SRC" ]; then
	ino=$(nsenter -t 1 -m -- stat -c %i "$TGT" 2>/dev/null)
	ino=${ino:-$(stat -c %i "$TGT" 2>/dev/null)}
	echo "  target inode = $ino"
	if grep -q " $ino " "/proc/$sf/maps" 2>/dev/null; then
		echo "  SF is running the patched library  ✓"
	else
		echo "  SF is NOT running our library (stock or another module)"
	fi
fi
echo "  enforce = $(cat /sys/fs/selinux/enforce 2>/dev/null)"
hr

echo "[known trigger / 已知触发源]"
_found=0
for d in /data/misc/lspd /data/adb/lspd /data/adb/modules/lsposed \
	/data/adb/modules/zygisk_lsposed /data/user/0/com.tsng.hyperceiler \
	/data/user/0/com.gman.mod; do
	if [ -e "$d" ]; then
		echo "  found: $d"
		_found=1
	fi
done
[ "$_found" = "0" ] && echo "  no LSPosed / HyperCeiler / DisableFlagSecure marker found"
echo "  note: 本 bug 常见于 HyperCeiler「允许在任何应用截屏」或 disable flag secure 类设置"
hr

echo "[log tail / 日志末尾]"
if [ -f "$LOG" ]; then
	tail -n 25 "$LOG" 2>/dev/null
else
	echo "  (no log yet)"
fi
hr
echo "诊断结束 / end of report"
exit 0
