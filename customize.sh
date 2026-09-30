#!/system/bin/sh
# -----------------------------------------------------------------
# Mirafix — 解决投屏  v1.1   install gate  (customize.sh)
# Sourced by the Magisk / KernelSU installer.
#
# The payload is ALWAYS generated from THIS device's own
# libsurfaceflinger.so. If the target instruction cannot be located,
# the pristine file cannot be read, or any verification fails,
# installation ABORTS and the phone is left untouched.
# -----------------------------------------------------------------

# The installer may put a BusyBox applet dir first in PATH; BusyBox
# stat has no %C and other applets differ, so prefer the system ones.
export PATH=/system/bin:/system/xbin:/system/sbin:/sbin:/vendor/bin:$PATH

# ---- 0. locate the module directory -----------------------------
if [ -z "$MODPATH" ] || [ ! -d "$MODPATH" ]; then
	for _d in /data/adb/modules_update/mirafix /data/adb/modules/mirafix; do
		[ -f "$_d/module.prop" ] && MODPATH=$_d && break
	done
fi

# ---- 1. installer helpers ---------------------------------------
if ! command -v ui_print >/dev/null 2>&1; then
	ui_print() { echo "$1"; }
fi
if ! command -v abort >/dev/null 2>&1; then
	abort() { echo "!! $1"; exit 1; }
fi

# abort but never leave a bootable-looking module behind
fail() {
	[ -n "$MODPATH" ] && [ -d "$MODPATH" ] && echo "$1" > "$MODPATH/unsupported" 2>/dev/null
	abort "! $1"
	exit 1
}

# SELinux context of $1. BusyBox `stat` has no %C (it just prints the
# letter C), so prefer `ls -Z`, which both BusyBox and toybox print as
# "<context> <path>".
getctx() {
	_c=$(ls -Z "$1" 2>/dev/null | head -n 1); _c=${_c%% *}
	case $_c in *:*) printf '%s\n' "$_c"; return 0 ;; esac
	_c=$(stat -c %C "$1" 2>/dev/null)
	case $_c in *:*) printf '%s\n' "$_c"; return 0 ;; esac
	return 1
}

[ -n "$MODPATH" ] && [ -d "$MODPATH" ] || fail "cannot locate the module directory"

# Namespace prefix: unmount and read MUST happen in the same mount
# namespace, otherwise we could read a masked file and mistake it for
# the pristine stock library.
NSPRE=
if command -v nsenter >/dev/null 2>&1 && nsenter -t 1 -m -- true 2>/dev/null; then
	NSPRE="nsenter -t 1 -m --"
fi
MI=/proc/self/mountinfo
[ -n "$NSPRE" ] && MI=/proc/1/mountinfo

# ---- 2. constants ------------------------------------------------
# MF_TGT / MF_NO_PERMS are test hooks used by the offline unit tests;
# they are never set by the Magisk / KernelSU installer.
TGT=${MF_TGT:-/system_ext/lib64/libsurfaceflinger.so}
PAY="$MODPATH/system_ext/lib64/libsurfaceflinger.so"
INFO="$MODPATH/build.info"
KNOWN=6003624                                             # 0x5b9ba8 fast path
WIN=0b0172b25f01096a6011889ac0035fd6                      # orr|tst|csel|ret 16B
CSRET=6011889ac0035fd6                                    # csel|ret           8B
ANCHOR=6011889a                                           # csel               4B
PATCHED=e00308aa

rm -f "$MODPATH/unsupported" 2>/dev/null

ui_print "  Mirafix — 解决投屏 v1.1"
ui_print "  ------------------------------------------------------------"
ui_print "  Device identity / 设备身份"
for _p in ro.product.model ro.product.device ro.build.version.release \
	ro.build.version.sdk ro.build.version.incremental \
	ro.mi.os.version.name ro.mi.os.version.code; do
	ui_print "    $_p = $(getprop $_p 2>/dev/null)"
done
ui_print "    ro.build.fingerprint = $(getprop ro.build.fingerprint 2>/dev/null)"
ui_print "  ------------------------------------------------------------"

# ---- 3. read the PRISTINE stock library -------------------------
ui_print "  [1/5] read pristine $TGT"

# drop any mount sitting on the target so we see the real file
_n=0
while [ "$_n" -lt 6 ]; do
	grep -q " $TGT " "$MI" 2>/dev/null || break
	_n=$((_n + 1))
	ui_print "       masked by a mount, unmounting (try $_n)"
	$NSPRE umount -l "$TGT" 2>/dev/null
done
grep -q " $TGT " "$MI" 2>/dev/null && \
	fail "cannot read the pristine library (a mount is still in the way)"

STOCK_MD5=$($NSPRE md5sum "$TGT" 2>/dev/null); STOCK_MD5=${STOCK_MD5%% *}
STOCK_SIZE=$($NSPRE stat -c %s "$TGT" 2>/dev/null)
[ -n "$STOCK_MD5" ] && [ -n "$STOCK_SIZE" ] || \
	fail "$TGT cannot be read on this device"
[ "$STOCK_SIZE" -gt 1000000 ] 2>/dev/null || fail "stock library looks truncated ($STOCK_SIZE bytes)"
ui_print "       stock md5  = $STOCK_MD5"
ui_print "       stock size = $STOCK_SIZE"

# ---- 4. locate the target instruction ---------------------------
ui_print "  [2/5] locate target instruction"
OFF=
W=$($NSPRE dd if="$TGT" bs=1 skip=6003616 count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')
SIGLEN=
if [ "$W" = "$WIN" ]; then
	OFF=$KNOWN
	SIGLEN=32
	ui_print "       fast path hit at offset $OFF (0x5b9ba8)"
else
	HITS=$($NSPRE od -An -v -tx1 "$TGT" 2>/dev/null | tr -d ' \n' | \
		grep -bo -E "$WIN|$CSRET|$ANCHOR")
	[ -n "$HITS" ] || fail "signature not found in this build (md5=$STOCK_MD5) - unsupported"

	# highest confidence = longest match
	BEST=0
	while IFS= read -r _ln; do
		[ -z "$_ln" ] && continue
		_h=${_ln%%:*}
		_m=${_ln#*:}
		case $_h in
			''|*[!0-9]*) _m=${_ln##*:}; _h=${_ln%:*}; _h=${_h##*:} ;;
		esac
		[ ${#_m} -gt "$BEST" ] && BEST=${#_m}
	done <<EOF
$HITS
EOF

	N=0
	while IFS= read -r _ln; do
		[ -z "$_ln" ] && continue
		_h=${_ln%%:*}
		_m=${_ln#*:}
		case $_h in
			''|*[!0-9]*) _m=${_ln##*:}; _h=${_ln%:*}; _h=${_h##*:} ;;
		esac
		[ ${#_m} -eq "$BEST" ] || continue
		N=$((N + 1))
		case $BEST in
			32) OFF=$((_h / 2 + 8)) ;;
			*)  OFF=$((_h / 2)) ;;
		esac
	done <<EOF
$HITS
EOF

	[ "$N" -eq 1 ] || fail "signature matched $N places (len=$BEST) - too ambiguous, aborted"
	SIGLEN=$BEST
	ui_print "       scanned: best match ${BEST} hex chars, unique -> offset $OFF"
fi

[ -n "$OFF" ] || fail "failed to compute patch offset"
ui_print "       patch offset = $OFF (0x$(printf '%x' "$OFF"))"

# ---- 5. build the payload from our OWN library ------------------
ui_print "  [3/5] build payload"
mkdir -p "${PAY%/*}" 2>/dev/null
rm -f "$PAY" 2>/dev/null
cp "$TGT" "$PAY" 2>/dev/null || fail "cannot copy the stock library"

printf '\340\003\010\252' | dd of="$PAY" bs=1 seek="$OFF" conv=notrunc 2>/dev/null
B=$(dd if="$PAY" bs=1 skip="$OFF" count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$B" = "$PATCHED" ] || fail "patch write verify failed (got $B)"

# ---- 6. prove that ONLY those 4 bytes changed -------------------
ui_print "  [4/5] prove change is exactly 4 bytes"
V="$MODPATH/.mf_verify"
rm -f "$V" 2>/dev/null
cp "$PAY" "$V" 2>/dev/null || fail "verify copy failed"
printf '\140\021\210\232' | dd of="$V" bs=1 seek="$OFF" conv=notrunc 2>/dev/null
VM=$(md5sum "$V" 2>/dev/null); VM=${VM%% *}
rm -f "$V" 2>/dev/null
[ "$VM" = "$STOCK_MD5" ] || fail "payload differs from stock outside the 4 patched bytes"
ui_print "       restoring the original 4 bytes reproduces stock md5  OK"

# ---- 7. permissions + SELinux context ---------------------------
ui_print "  [5/5] permissions and SELinux context"
if [ -z "$MF_NO_PERMS" ]; then
	chown 0:0 "$PAY" 2>/dev/null
	chmod 0644 "$PAY" 2>/dev/null
	chcon u:object_r:system_lib_file:s0 "$PAY" 2>/dev/null

	M=$(stat -c %a "$PAY" 2>/dev/null)
	[ "$M" = "644" ] || fail "cannot set mode 0644 (got '$M') - surfaceflinger could not load it"

	CTX=$(getctx "$PAY")
	case $CTX in
		*system_lib_file*) : ;;
		*system_file*)
			ui_print "       context = system_file (boot script will retry system_lib_file)"
			;;
		*)
			chcon u:object_r:system_file:s0 "$PAY" 2>/dev/null
			CTX=$(getctx "$PAY")
			case $CTX in
				*system_lib_file*|*system_file*)
					ui_print "       context = $CTX"
					;;
				*) fail "unsafe SELinux context '$CTX' - surfaceflinger could not load it" ;;
			esac
			;;
	esac
	ui_print "       mode = 0644, context = $CTX"
else
	CTX="(test: skipped)"
fi

PAY_MD5=$(md5sum "$PAY" 2>/dev/null); PAY_MD5=${PAY_MD5%% *}
[ -n "$PAY_MD5" ] || fail "cannot checksum the generated payload"

# ---- 8. record the device identity for boot-time checks ---------
{
	echo "version=1.1"
	echo "installed=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
	echo "model=$(getprop ro.product.model 2>/dev/null)"
	echo "device=$(getprop ro.product.device 2>/dev/null)"
	echo "release=$(getprop ro.build.version.release 2>/dev/null)"
	echo "sdk=$(getprop ro.build.version.sdk 2>/dev/null)"
	echo "incremental=$(getprop ro.build.version.incremental 2>/dev/null)"
	echo "mi_os_name=$(getprop ro.mi.os.version.name 2>/dev/null)"
	echo "mi_os_code=$(getprop ro.mi.os.version.code 2>/dev/null)"
	echo "fingerprint=$(getprop ro.build.fingerprint 2>/dev/null)"
	echo "stock_md5=$STOCK_MD5"
	echo "stock_size=$STOCK_SIZE"
	echo "payload_md5=$PAY_MD5"
	echo "offset=$OFF"
	echo "signature_len=$SIGLEN"
} > "$INFO" 2>/dev/null
[ -f "$INFO" ] || fail "cannot write build.info"

# ---- 9. tidy up + report -----------------------------------------
chmod 0755 "$MODPATH/post-fs-data.sh" "$MODPATH/service.sh" "$MODPATH/action.sh" 2>/dev/null
chmod 0644 "$MODPATH/module.prop" "$MODPATH/skip_mount" 2>/dev/null
chown 0:0 "$MODPATH"/* 2>/dev/null

ui_print "  ------------------------------------------------------------"
ui_print "  payload md5 = $PAY_MD5"
ui_print "  offset      = $OFF"
ui_print "  ✓ 本机库现场生成并校验通过 / generated from THIS device OK"
ui_print "  ✓ 重启后生效 / takes effect after reboot"
ui_print "  ------------------------------------------------------------"
# NOTE: no `exit` here — customize.sh is SOURCED by the installer and
# the installer still has to run its own post-install steps.
