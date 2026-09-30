#!/system/bin/sh
# -----------------------------------------------------------------
# Mirafix — 解决投屏  v1.1   post-fs-data
#
# Fail-safe contract: EVERY error path ends with "exit 0" and never
# blocks or delays boot. If anything looks wrong the module simply
# does not mount anything, and the phone boots with the stock library.
# -----------------------------------------------------------------
export PATH=/system/bin:/system/xbin:/system/sbin:/sbin:/vendor/bin

MODDIR="${0%/*}"
# MF_TGT is an offline unit-test hook; never set by Magisk / KernelSU.
TGT=${MF_TGT:-/system_ext/lib64/libsurfaceflinger.so}
SRC="$MODDIR/system_ext/lib64/libsurfaceflinger.so"
INFO="$MODDIR/build.info"
STATE="$MODDIR/.boot_state"
RETRY="$MODDIR/.retry_count"
# MF_LOG is an offline unit-test hook too (keeps test output out of the
# real log that users share when reporting a problem).
LOG=${MF_LOG:-/data/adb/mirafix.log}
PATCHED=e00308aa

say() {
	_s="$1"
	_t=$(date '+%m-%d %H:%M:%S' 2>/dev/null)
	_z=$(stat -c %s "$LOG" 2>/dev/null); [ -z "$_z" ] && _z=0
	[ "$_z" -gt 200000 ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
	echo "$_t [post-fs-data] $_s" >> "$LOG" 2>/dev/null
	log -t Mirafix "$_s" 2>/dev/null
	return 0
}

read4() { # $1 = file, $2 = byte offset (current namespace)
	dd if="$1" bs=1 skip="$2" count=4 2>/dev/null |
		od -An -tx1 2>/dev/null | tr -d ' \n'
}

read4_init() { # $1 = byte offset, as seen by init
	if command -v nsenter >/dev/null 2>&1; then
		nsenter -t 1 -m -- dd if="$TGT" bs=1 skip="$1" count=4 2>/dev/null
	else
		dd if="$TGT" bs=1 skip="$1" count=4 2>/dev/null
	fi | od -An -tx1 2>/dev/null | tr -d ' \n'
}

bind_payload() { # $1 = offset
	if command -v nsenter >/dev/null 2>&1; then
		nsenter -t 1 -m -- mount --bind "$SRC" "$TGT" 2>/dev/null &&
			[ "$(read4_init "$1")" = "$PATCHED" ] && return 0
	fi
	mount --bind "$SRC" "$TGT" 2>/dev/null
	[ "$(read4_init "$1")" = "$PATCHED" ]
}

set_state() { echo "$1" > "$STATE" 2>/dev/null; }

# BusyBox `stat` has no %C (it prints the letter C), so prefer ls -Z.
getctx() {
	_c=$(ls -Z "$1" 2>/dev/null | head -n 1); _c=${_c%% *}
	case $_c in *:*) printf '%s\n' "$_c"; return 0 ;; esac
	_c=$(stat -c %C "$1" 2>/dev/null)
	case $_c in *:*) printf '%s\n' "$_c"; return 0 ;; esac
	return 1
}

# ---- 0. previous boot never finished -> protect, do NOT mount ----
if [ -f "$STATE" ] && [ "$(cat "$STATE" 2>/dev/null)" = "pending" ]; then
	_n=$(cat "$RETRY" 2>/dev/null)
	case $_n in ''|*[!0-9]*) _n=0 ;; esac
	_n=$((_n + 1))
	echo "$_n" > "$RETRY" 2>/dev/null
	say "上次启动未走完(pending)，第 $_n 次保护性跳过，本次使用原版库"
	if [ "$_n" -ge 2 ]; then
		touch "$MODDIR/disable" 2>/dev/null
		say "连续 $_n 次启动异常，已自动禁用模块；日志见 $LOG"
	fi
	set_state skipped
	exit 0
fi

# ---- 1. install-time refusal -------------------------------------
if [ -f "$MODDIR/unsupported" ]; then
	say "安装时标记为不适用：$(cat "$MODDIR/unsupported" 2>/dev/null)"
	set_state skipped
	exit 0
fi

# ---- 2. recorded identity ----------------------------------------
if [ ! -f "$INFO" ]; then
	say "缺少 build.info（模块未正确安装），跳过"
	set_state skipped
	exit 0
fi

k() { sed -n "s/^$1=//p" "$INFO" 2>/dev/null | head -n 1; }

WANT_FP=$(k fingerprint)
WANT_MODEL=$(k model)
WANT_OFF=$(k offset)
WANT_MD5=$(k payload_md5)
# tier D installs write different bytes than the classic window; they tell
# us what to expect so the runtime check stays exact.
_kp=$(k patch_hex)
[ -n "$_kp" ] && PATCHED=$_kp

[ -n "$WANT_OFF" ] || { say "build.info 缺少 offset，跳过"; set_state skipped; exit 0; }

CUR_FP=$(getprop ro.build.fingerprint 2>/dev/null)
CUR_MODEL=$(getprop ro.product.model 2>/dev/null)

if [ -n "$WANT_FP" ] && [ -n "$CUR_FP" ] && [ "$CUR_FP" != "$WANT_FP" ]; then
	say "系统指纹已变化（OTA？）：$CUR_FP，停用模块，需重新安装 Mirafix"
	touch "$MODDIR/disable" 2>/dev/null
	set_state skipped
	exit 0
fi
if [ -n "$WANT_MODEL" ] && [ -n "$CUR_MODEL" ] && [ "$CUR_MODEL" != "$WANT_MODEL" ]; then
	say "机型已变化：$CUR_MODEL（记录为 $WANT_MODEL），停用模块"
	touch "$MODDIR/disable" 2>/dev/null
	set_state skipped
	exit 0
fi

# ---- 3. payload sanity -------------------------------------------
if [ ! -f "$SRC" ]; then
	say "载荷不存在，跳过"
	set_state skipped
	exit 0
fi

_md=$(md5sum "$SRC" 2>/dev/null); _md=${_md%% *}
if [ -n "$WANT_MD5" ] && [ "$_md" != "$WANT_MD5" ]; then
	say "载荷 md5 与安装记录不符，跳过"
	set_state skipped
	exit 0
fi

_m=$(stat -c %a "$SRC" 2>/dev/null)
if [ "$_m" != "644" ]; then
	chmod 0644 "$SRC" 2>/dev/null
	_m=$(stat -c %a "$SRC" 2>/dev/null)
fi
if [ "$_m" != "644" ]; then
	say "载荷权限 $_m 不是 0644，跳过（surfaceflinger 会拒绝加载）"
	set_state skipped
	exit 0
fi

_ctx=$(getctx "$SRC")
case $_ctx in
	*system_lib_file*|*system_file*) : ;;
	*)
		chcon u:object_r:system_lib_file:s0 "$SRC" 2>/dev/null
		_ctx=$(getctx "$SRC")
		case $_ctx in
			*system_lib_file*|*system_file*) : ;;
			*)
				say "载荷 SELinux 上下文不安全 ($_ctx)，跳过"
				set_state skipped
				exit 0
				;;
		esac
		;;
esac

_v=$(read4 "$SRC" "$WANT_OFF")
if [ "$_v" != "$PATCHED" ]; then
	say "载荷补丁字节异常 ($_v != $PATCHED)，跳过"
	set_state skipped
	exit 0
fi

# ---- 4. bind ------------------------------------------------------
# mark as pending BEFORE mounting: if this boot dies, next boot skips
set_state pending

if bind_payload "$WANT_OFF"; then
	_now=$(read4_init "$WANT_OFF")
	say "已绑定载荷 offset=$WANT_OFF，init 视角=$_now，model=$CUR_MODEL"
else
	say "绑定失败，本次使用原版库"
	set_state skipped
fi
exit 0
