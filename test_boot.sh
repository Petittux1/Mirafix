#!/usr/bin/env bash
# Offline tests for the Mirafix post-fs-data.sh / service.sh decision
# branches. Must run as root (needs mount / chcon / nsenter).
# Not shipped in the module zip.
set -u

if [ "$(id -u)" != 0 ]; then
	echo "run me as root:  su -c bash $0"
	exit 1
fi

STG=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
pass=0
fail=0
OUT=""

# fake mount target; the patched bytes live at byte offset 100
OFF=100
PATCHED_HEX="e00308aa"

cleanup() {
	nsenter -t 1 -m -- umount -l "$WORK/tgt" 2>/dev/null
	umount -l "$WORK/tgt" 2>/dev/null
	rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

mk_target() { yes "Mirafix boot test TARGET placeholder" | head -c 1000 > "$WORK/tgt"; }

mk_payload() { # $1 = moddir
	mkdir -p "$1/system_ext/lib64"
	yes "Mirafix boot test PAYLOAD placeholder" | head -c 1000 > "$1/system_ext/lib64/libsurfaceflinger.so"
	printf '\xe0\x03\x08\xaa' | dd of="$1/system_ext/lib64/libsurfaceflinger.so" \
		bs=1 seek=$OFF conv=notrunc 2>/dev/null
	chmod 644 "$1/system_ext/lib64/libsurfaceflinger.so"
}

mk_info() { # $1 = moddir [$2 = fingerprint] [$3 = model]
	local fp="${2:-$(getprop ro.build.fingerprint)}"
	local md="${3:-$(getprop ro.product.model)}"
	local sum
	sum=$(md5sum "$1/system_ext/lib64/libsurfaceflinger.so" 2>/dev/null | cut -d' ' -f1)
	{
		echo "version=1.1"
		echo "model=$md"
		echo "fingerprint=$fp"
		echo "payload_md5=$sum"
		echo "offset=$OFF"
	} > "$1/build.info"
}

fresh_mod() { # $1 = name
	local d="$WORK/$1"
	rm -rf "$d"
	mkdir -p "$d"
	cp "$STG/post-fs-data.sh" "$STG/service.sh" "$d/"
	chmod 755 "$d/post-fs-data.sh" "$d/service.sh"
	mk_payload "$d"
	mk_info "$d"
	echo "$d"
}

# truncate the log for every run so assertions cannot match stale lines
run_pfs() { # $1 = moddir
	: > "$WORK/log"
	MF_TGT="$WORK/tgt" MF_LOG="$WORK/log" /system/bin/sh "$1/post-fs-data.sh"
}

run_svc() { # $1 = moddir
	: > "$WORK/log"
	MF_TGT="$WORK/tgt" MF_LOG="$WORK/log" /system/bin/sh "$1/service.sh"
}

state() { cat "$1/.boot_state" 2>/dev/null; }

report() { # $1=name $2=ok|FAIL $3=detail
	if [ "$2" = ok ]; then
		pass=$((pass + 1))
		printf '  \342\234\223 %-34s %s\n' "$1" "$3"
	else
		fail=$((fail + 1))
		printf '  \342\234\227 %-34s %s\n' "$1" "$3"
		printf '%s\n' "$OUT" | tail -5 | sed 's/^/        /'
	fi
}

target4() {
	nsenter -t 1 -m -- dd if="$WORK/tgt" bs=1 skip=$OFF count=4 2>/dev/null |
		od -An -tx1 | tr -d ' \n'
}

unbind() {
	nsenter -t 1 -m -- umount -l "$WORK/tgt" 2>/dev/null
	umount -l "$WORK/tgt" 2>/dev/null
}

echo "== Mirafix boot-script branch tests (root) =="
mk_target

# --- 1. happy path: everything valid -> bind + pending ------------
M=$(fresh_mod happy)
OUT=$(run_pfs "$M"); RC=$?
if [ "$RC" = 0 ] && [ "$(state "$M")" = pending ]; then
	B=$(target4)
	if [ "$B" = "$PATCHED_HEX" ]; then
		report "happy path binds payload" ok "init view@$OFF = $B"
	else
		report "happy path binds payload" FAIL "init view@$OFF = '$B'"
	fi
else
	report "happy path binds payload" FAIL "rc=$RC state=$(state "$M")"
fi
grep -q "已绑定载荷" "$WORK/log" && report "happy path logs bind" ok "已绑定载荷" ||
	report "happy path logs bind" FAIL "log line missing"
unbind

# --- 2. service.sh, state != pending -> early exit ----------------
M=$(fresh_mod sv_skip)
echo skipped > "$M/.boot_state"
OUT=$(run_svc "$M"); RC=$?
[ "$RC" = 0 ] && [ "$(state "$M")" = ok ] &&
	report "svc: non-pending early exit" ok "state -> ok" ||
	report "svc: non-pending early exit" FAIL "rc=$RC state=$(state "$M")"
grep -q "本次未启用补丁" "$WORK/log" && report "svc: logs skip" ok "" ||
	report "svc: logs skip" FAIL "missing line"

# --- 3. service.sh, pending but payload missing -> no SF restart ---
# `say()` writes to the LOG, not stdout, so assert on the log file.
M=$(fresh_mod sv_nopayload)
echo pending > "$M/.boot_state"
rm -f "$M/system_ext/lib64/libsurfaceflinger.so"
OUT=$(run_svc "$M"); RC=$?
L=$(cat "$WORK/log" 2>/dev/null)
case $L in
	*载荷权限*)
		case $L in
			*"未加载补丁库"*) report "svc: refuses to bounce" FAIL "reached bounce path" ;;
			*) report "svc: refuses to bounce" ok "mode guard held, no setprop" ;;
		esac ;;
	*) report "svc: refuses to bounce" FAIL "rc=$RC log=$L" ;;
esac

# --- 4. stale pending #1 -> protective skip, retry=1 --------------
M=$(fresh_mod stale)
echo pending > "$M/.boot_state"
OUT=$(run_pfs "$M"); RC=$?
[ "$RC" = 0 ] && [ "$(state "$M")" = skipped ] && [ "$(cat "$M/.retry_count")" = 1 ] &&
	[ ! -f "$M/disable" ] &&
	report "stale pending #1" ok "skip, retry=1, no disable" ||
	report "stale pending #1" FAIL "rc=$RC state=$(state "$M") retry=$(cat "$M/.retry_count" 2>/dev/null)"

# --- 5. observed pending again -> auto disable --------------------
echo pending > "$M/.boot_state"
OUT=$(run_pfs "$M"); RC=$?
[ "$RC" = 0 ] && [ "$(cat "$M/.retry_count")" = 2 ] && [ -f "$M/disable" ] &&
	report "2nd pending disables module" ok "retry=2 + disable" ||
	report "2nd pending disables module" FAIL "retry=$(cat "$M/.retry_count" 2>/dev/null) disable=$([ -f "$M/disable" ] && echo yes || echo no)"

# --- 6. missing build.info -> skip --------------------------------
M=$(fresh_mod noinfo)
rm -f "$M/build.info"
OUT=$(run_pfs "$M"); RC=$?
[ "$RC" = 0 ] && [ "$(state "$M")" = skipped ] && grep -q "缺少 build.info" "$WORK/log" &&
	report "missing build.info" ok "skip" || report "missing build.info" FAIL "rc=$RC state=$(state "$M")"

# --- 7. install-time unsupported marker -> skip -------------------
M=$(fresh_mod unsupported)
echo "signature not found in this build" > "$M/unsupported"
OUT=$(run_pfs "$M"); RC=$?
[ "$RC" = 0 ] && [ "$(state "$M")" = skipped ] &&
	report "unsupported marker" ok "skip" || report "unsupported marker" FAIL "rc=$RC state=$(state "$M")"

# --- 8. fingerprint changed (OTA) -> disable ----------------------
M=$(fresh_mod ota)
mk_info "$M" "Xiaomi/otherdevice/other:16/fakebuild/OS1.0:user/release-keys"
OUT=$(run_pfs "$M"); RC=$?
[ "$RC" = 0 ] && [ "$(state "$M")" = skipped ] && [ -f "$M/disable" ] &&
	report "fingerprint mismatch (OTA)" ok "skip + disable" ||
	report "fingerprint mismatch (OTA)" FAIL "rc=$RC state=$(state "$M") disable=$([ -f "$M/disable" ] && echo yes || echo no)"

# --- 9. model changed -> disable ----------------------------------
M=$(fresh_mod model)
mk_info "$M" "$(getprop ro.build.fingerprint)" "OTHERPHONE"
OUT=$(run_pfs "$M"); RC=$?
[ "$RC" = 0 ] && [ "$(state "$M")" = skipped ] && [ -f "$M/disable" ] &&
	report "model mismatch" ok "skip + disable" ||
	report "model mismatch" FAIL "rc=$RC state=$(state "$M")"

# --- 10. payload md5 mismatch -> skip -----------------------------
M=$(fresh_mod badmd5)
sed -i 's/^payload_md5=.*/payload_md5=deadbeefdeadbeefdeadbeefdeadbeef/' "$M/build.info"
OUT=$(run_pfs "$M"); RC=$?
[ "$RC" = 0 ] && [ "$(state "$M")" = skipped ] && grep -q "md5 与安装记录不符" "$WORK/log" &&
	report "payload md5 mismatch" ok "skip" || report "payload md5 mismatch" FAIL "rc=$RC state=$(state "$M")"

# --- 11. payload bytes wrong (md5 updated!) -> skip ---------------
M=$(fresh_mod badbytes)
printf '\x11\x22\x33\x44' | dd of="$M/system_ext/lib64/libsurfaceflinger.so" \
	bs=1 seek=$OFF conv=notrunc 2>/dev/null
mk_info "$M"        # refresh md5 so the byte check is the one that fires
OUT=$(run_pfs "$M"); RC=$?
[ "$RC" = 0 ] && [ "$(state "$M")" = skipped ] && grep -q "补丁字节异常" "$WORK/log" &&
	report "payload bytes wrong" ok "skip" || report "payload bytes wrong" FAIL "rc=$RC state=$(state "$M")"

# --- 12. payload missing -> skip ----------------------------------
M=$(fresh_mod nopayload)
rm -f "$M/system_ext/lib64/libsurfaceflinger.so"
OUT=$(run_pfs "$M"); RC=$?
[ "$RC" = 0 ] && [ "$(state "$M")" = skipped ] && grep -q "载荷不存在" "$WORK/log" &&
	report "payload missing" ok "skip" || report "payload missing" FAIL "rc=$RC state=$(state "$M")"

# --- 13. payload mode 0600 -> self-heal then bind -----------------
M=$(fresh_mod badmode)
chmod 600 "$M/system_ext/lib64/libsurfaceflinger.so"
OUT=$(run_pfs "$M"); RC=$?
if [ "$RC" = 0 ] && [ "$(state "$M")" = pending ] && [ "$(target4)" = "$PATCHED_HEX" ]; then
	report "mode 0600 self-heals to 644" ok "chmod + bind"
else
	report "mode 0600 self-heals to 644" FAIL "rc=$RC state=$(state "$M") t4=$(target4)"
fi
unbind

echo
echo "== result: pass=$pass fail=$fail =="
[ "$fail" = 0 ]
