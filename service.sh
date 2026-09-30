#!/system/bin/sh
# -----------------------------------------------------------------
# Mirafix — 解决投屏  v1.1   late_start service
#
# Only ever acts when post-fs-data actually decided to mount the
# payload (state == pending). Verifies by INODE (after a lazy
# unmount the kernel renders the mapped path as "/"), never by path.
# Refuses to bounce surfaceflinger unless the payload is 0644 and has
# a safe SELinux context, and rolls back immediately if SF cannot
# come back up.
# -----------------------------------------------------------------
export PATH=/system/bin:/system/xbin:/system/sbin:/sbin:/vendor/bin

MODDIR="${0%/*}"
# MF_TGT / MF_LOG are offline unit-test hooks; never set by Magisk / KernelSU.
TGT=${MF_TGT:-/system_ext/lib64/libsurfaceflinger.so}
SRC="$MODDIR/system_ext/lib64/libsurfaceflinger.so"
INFO="$MODDIR/build.info"
STATE="$MODDIR/.boot_state"
RETRY="$MODDIR/.retry_count"
LOG=${MF_LOG:-/data/adb/mirafix.log}
PATCHED=e00308aa

say() {
	_s="$1"
	_t=$(date '+%m-%d %H:%M:%S' 2>/dev/null)
	_z=$(stat -c %s "$LOG" 2>/dev/null); [ -z "$_z" ] && _z=0
	[ "$_z" -gt 200000 ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
	echo "$_t [service] $_s" >> "$LOG" 2>/dev/null
	log -t Mirafix "$_s" 2>/dev/null
	return 0
}

read4() { # $1 = file, $2 = offset (current namespace)
	dd if="$1" bs=1 skip="$2" count=4 2>/dev/null |
		od -An -tx1 2>/dev/null | tr -d ' \n'
}

read4_init() {
	if command -v nsenter >/dev/null 2>&1; then
		nsenter -t 1 -m -- dd if="$TGT" bs=1 skip="$1" count=4 2>/dev/null
	else
		dd if="$TGT" bs=1 skip="$1" count=4 2>/dev/null
	fi | od -An -tx1 2>/dev/null | tr -d ' \n'
}

bind_payload() {
	if command -v nsenter >/dev/null 2>&1; then
		nsenter -t 1 -m -- mount --bind "$SRC" "$TGT" 2>/dev/null &&
			[ "$(read4_init "$1")" = "$PATCHED" ] && return 0
	fi
	mount --bind "$SRC" "$TGT" 2>/dev/null
	[ "$(read4_init "$1")" = "$PATCHED" ]
}

set_state() { echo "$1" > "$STATE" 2>/dev/null; }
k() { sed -n "s/^$1=//p" "$INFO" 2>/dev/null | head -n 1; }

# BusyBox `stat` has no %C (it prints the letter C), so prefer ls -Z.
getctx() {
	_c=$(ls -Z "$1" 2>/dev/null | head -n 1); _c=${_c%% *}
	case $_c in *:*) printf '%s\n' "$_c"; return 0 ;; esac
	_c=$(stat -c %C "$1" 2>/dev/null)
	case $_c in *:*) printf '%s\n' "$_c"; return 0 ;; esac
	return 1
}

sf_maps() { # $1 = pid, $2 = inode
	grep -q " $2 " "/proc/$1/maps" 2>/dev/null
}

rollback() {
	say "$1 — 立即回滚到原版库"
	nsenter -t 1 -m -- umount -l "$TGT" 2>/dev/null
	umount -l "$TGT" 2>/dev/null
	setprop ctl.restart surfaceflinger 2>/dev/null
	sleep 5
	set_state pending
	exit 1
}

# ---- nothing was mounted this boot -> stay out of the way --------
CUR_STATE=$(cat "$STATE" 2>/dev/null)
if [ "$CUR_STATE" != "pending" ]; then
	say "本次未启用补丁 (state=${CUR_STATE:-none})，保持原版运行"
	set_state ok
	exit 0
fi

WANT_OFF=$(k offset)
[ -n "$WANT_OFF" ] || { say "build.info 缺少 offset，保持 pending"; exit 1; }
# tier D installs tell us which bytes they wrote; keep the check exact.
_kp=$(k patch_hex)
[ -n "$_kp" ] && PATCHED=$_kp

# ---- give surfaceflinger a moment to come up ---------------------
sf=$(pidof surfaceflinger)
_w=0
while [ -z "$sf" ] && [ "$_w" -lt 15 ]; do
	sleep 1
	_w=$((_w + 1))
	sf=$(pidof surfaceflinger)
done
if [ -z "$sf" ]; then
	say "surfaceflinger 未运行，保持 pending（下次启动将保护性跳过）"
	exit 1
fi

# ---- payload must be loadable before we ever touch SF ------------
_m=$(stat -c %a "$SRC" 2>/dev/null)
if [ "$_m" != "644" ]; then
	chmod 0644 "$SRC" 2>/dev/null
	_m=$(stat -c %a "$SRC" 2>/dev/null)
fi
[ "$_m" = "644" ] || { say "载荷权限 $_m，拒绝重启 surfaceflinger"; exit 1; }

_ctx=$(getctx "$SRC")
case $_ctx in
	*system_lib_file*|*system_file*) : ;;
	*)
		chcon u:object_r:system_lib_file:s0 "$SRC" 2>/dev/null
		_ctx=$(getctx "$SRC")
		;;
esac
case $_ctx in
	*system_lib_file*|*system_file*) : ;;
	*) rollback "载荷 SELinux 上下文不安全 ($_ctx)" ;;
esac

# ---- is the target really our payload? ---------------------------
if [ "$(read4_init "$WANT_OFF")" != "$PATCHED" ]; then
	say "目标不是补丁库，重新绑定"
	bind_payload "$WANT_OFF" || { say "重新绑定失败，保持 pending"; exit 1; }
fi

tgt_ino=$(nsenter -t 1 -m -- stat -c %i "$TGT" 2>/dev/null)
[ -n "$tgt_ino" ] || tgt_ino=$(stat -c %i "$TGT" 2>/dev/null)
if [ -z "$tgt_ino" ]; then
	say "无法读取目标 inode，保持 pending"
	exit 1
fi

if sf_maps "$sf" "$tgt_ino"; then
	say "SF pid=$sf 已加载补丁库 (inode $tgt_ino)"
	echo 0 > "$RETRY" 2>/dev/null
	set_state ok
	exit 0
fi

# ---- bounce surfaceflinger exactly once --------------------------
say "SF pid=$sf 未加载补丁库 (inode $tgt_ino)，重启 surfaceflinger"
setprop ctl.restart surfaceflinger 2>/dev/null

i=0
empty=0
restarts=0
old=$sf
while [ "$i" -lt 45 ]; do
	sleep 1
	i=$((i + 1))
	cur=$(pidof surfaceflinger)
	if [ -z "$cur" ]; then
		empty=$((empty + 1))
		[ "$empty" -ge 6 ] && rollback "surfaceflinger 消失"
		continue
	fi
	empty=0
	[ "$cur" = "$old" ] && continue

	# new pid: require it to stay up 5 seconds
	stable=1
	j=0
	while [ "$j" -lt 5 ]; do
		sleep 1
		j=$((j + 1))
		[ "$(pidof surfaceflinger)" = "$cur" ] || { stable=0; break; }
	done
	if [ "$stable" = "1" ]; then
		if sf_maps "$cur" "$tgt_ino"; then
			say "SF 新进程 pid=$cur 已加载补丁库 (inode $tgt_ino)"
			echo 0 > "$RETRY" 2>/dev/null
			set_state ok
		else
			say "SF 新进程 pid=$cur 仍未加载补丁库，回滚"
			rollback "重启后仍未加载补丁库"
		fi
		exit 0
	fi
	restarts=$((restarts + 1))
	[ "$restarts" -ge 2 ] && rollback "surfaceflinger 反复崩溃"
	old=$cur
done
say "等待 surfaceflinger 重启超时，保持 pending"
exit 1
