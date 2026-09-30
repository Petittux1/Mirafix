#!/system/bin/sh
# -----------------------------------------------------------------
# Mirafix — 解决投屏  v1.3   install gate  (customize.sh)
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
# MF_TGT / MF_NO_PERMS / MF_FORCE_TD are test hooks used by the offline unit
# tests; they are never set by the Magisk / KernelSU installer.
# MF_FORCE_TD skips the byte-window tiers so tier D can be exercised.
TGT=${MF_TGT:-/system_ext/lib64/libsurfaceflinger.so}
PAY="$MODPATH/system_ext/lib64/libsurfaceflinger.so"
INFO="$MODPATH/build.info"
KNOWN=6003624                                             # 0x5b9ba8 fast path
WIN=0b0172b25f01096a6011889ac0035fd6                      # orr|tst|csel|ret 16B
CSRET=6011889ac0035fd6                                    # csel|ret           8B
ANCHOR=6011889a                                           # csel               4B
PATCHED=e00308aa
# 4 bytes to write / 4 bytes to put back when proving the diff.
# Tiers A-C always patch the well known csel; tier D (foreign builds)
# overwrites both from the site it found.
PATCH_HEX=$PATCHED
ORIG_HEX=$ANCHOR

rm -f "$MODPATH/unsupported" 2>/dev/null

# ---- 2b. small helpers --------------------------------------------
# hex string (as od prints it, byte order preserved) -> u32 value
hex2u32() { # $1 = 8 hex chars
	echo $((0x${1:6:2}${1:4:2}${1:2:2}${1:0:2}))
}
# u32 value -> 8 hex chars in od byte order
u32hex() { # $1 = decimal u32
	printf '%08x' "$1" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/'
}
# u32 value -> 4 raw bytes
u32bytes() { # $1 = decimal u32
	printf "\\$(printf '%03o' $(( $1        & 255 )))\\$(printf '%03o' $(( ($1 >> 8)  & 255 )))\\$(printf '%03o' $(( ($1 >> 16) & 255 )))\\$(printf '%03o' $(( ($1 >> 24) & 255 )))"
}
# hex string in od byte order -> the raw bytes it describes
hexbytes() { # $1 = hex string (even length)
	_hb=$1
	_fmt=
	while [ -n "$_hb" ]; do
		_fmt="$_fmt\\$(printf '%03o' $((0x${_hb:0:2})))"
		_hb=${_hb:2}
	done
	[ -n "$_fmt" ] && printf "$_fmt"
	return 0
}

# ---- 2d. byte scanner --------------------------------------------
# `grep -b` (report byte offsets) does NOT exist in BusyBox grep, and every
# root solution runs installer scripts under `busybox ash` with
# ASH_STANDALONE=1, where every command resolves to a BusyBox applet no
# matter what PATH says. The old `grep -bo` pipeline therefore died with
# "grep: invalid option -- b", produced nothing, and every install that had
# to scan came out as "signature not found" - on a device it should have
# patched. Scan in awk instead: BusyBox ships awk, and awk has the byte
# offsets built in.
#
#   hexscan sig <file>   literal instruction windows  -> "<hex offset>:<hex>"
#   hexscan orr <file>   candidate `orr ?,?,#0x4000`   -> same, reported at b0
#
# The offset indexes the od hex stream (divide by 2 for a file offset) -
# byte for byte the contract `grep -b` used to give us, so callers are
# unchanged. Both the program and the fallback must stay free of regex
# intervals: BusyBox awk has no {n,m} and BusyBox grep has no -b.
HS_AWK='
	BEGIN { K = 64; tail = ""; sp = 0; tlen = 0 }
	{
		line = $1
		for (i = 2; i <= NF; i++) line = line $i
		if (line == "") next
		buf = tail line
		tlen = length(tail)
		if (mode == "sig") {
			if (WIN != "")    sigscan(WIN)
			if (CSRET != "")  sigscan(CSRET)
			if (ANCHOR != "") sigscan(ANCHOR)
		} else {
			orrscan("72b2")
			orrscan("1232")
		}
		sp += length(line)
		L = length(buf)
		if (L > K) { tail = substr(buf, L - K + 1) } else { tail = buf }
	}
	# A match is reported the moment its LAST byte lands in a line, so each
	# one is seen exactly once and a line boundary can never split it: only
	# starts at s0 or later can still be incomplete before this line.
	function sigscan(pat,   pl, s0, region, base, e, p) {
		pl = length(pat)
		s0 = tlen - pl + 2
		if (s0 < 1) s0 = 1
		region = substr(buf, s0)
		base = s0
		while ((e = index(region, pat)) > 0) {
			p = base + e - 1
			printf "%d:%s\n", int(sp - tlen + p - 1), pat
			region = substr(region, e + 1)
			base = base + e
		}
	}
	# The word is b0 b1 b2 b3 in memory; b2b3 is the fixed immediate and b1
	# holds the only nibble the 0xFFFFFC00 mask leaves free - 00 / 01 / 02 /
	# 03. tier_d re-reads the word and checks the mask properly; this is the
	# cheap pre-filter, and it must stay a superset of it.
	function orrscan(pat,   s0, region, base, e, p, g, b1) {
		s0 = tlen - 2
		if (s0 < 1) s0 = 1
		region = substr(buf, s0)
		base = s0
		while ((e = index(region, pat)) > 0) {
			p = base + e - 1
			g = p - 4
			if (g >= 1) {
				b1 = substr(buf, g + 2, 2)
				if (b1 == "00" || b1 == "01" || b1 == "02" || b1 == "03")
					printf "%d:%s%s%s\n", int(sp - tlen + g - 1), substr(buf, g, 2), b1, pat
			}
			region = substr(region, e + 1)
			base = base + e
		}
	}
'
hexscan() { # $1 = sig|orr  $2 = file
	_hs_mode=$1
	_hs_f=$2
	# MF_NO_AWK is a test hook (never set by an installer) that exercises
	# the fallback; without awk at all the same path keeps us safe.
	if [ -z "${MF_NO_AWK:-}" ] && awk 'BEGIN { exit 0 }' </dev/null >/dev/null 2>&1; then
		$NSPRE od -An -v -tx1 "$_hs_f" 2>/dev/null | awk \
			-v mode="$_hs_mode" -v WIN="$WIN" -v CSRET="$CSRET" \
			-v ANCHOR="$ANCHOR" "$HS_AWK"
	elif [ "$_hs_mode" = sig ]; then
		$NSPRE od -An -v -tx1 "$_hs_f" 2>/dev/null | tr -d ' \n' | \
			grep -bo -E "$WIN|$CSRET|$ANCHOR"
	else
		$NSPRE od -An -v -tx1 "$_hs_f" 2>/dev/null | tr -d ' \n' | \
			grep -bo -E '[0-9a-f]{2}0[0-3]72b2|[0-9a-f]{2}0[0-3]1232'
	fi
}

ui_print "  Mirafix — 解决投屏 v1.3"
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

# ---- 2c. tier D: register agnostic locator ----------------------
# Tiers A-C look for one exact byte window. A different compiler release
# allocates different registers and all three miss (this is what happened
# on HyperOS 3 / Android 16, where the build aborted safely instead of
# bootlooping). Tier D keys on the shape of the code instead:
#
#     orr  Ra, Rb, #0x4000     ; Ra = usage | GRALLOC_USAGE_PROTECTED
#     ...                      ; at most 7 instructions later
#     csel Rd, Ra, Rb, cond     ; pick between protected and clean usage
#
# `#0x4000` is GRALLOC_USAGE_PROTECTED, a fixed HAL constant, so the ORR
# encodes identically in every build - and tiers A-C only ever rewrite the
# csel, so this anchor survives even a previously patched file.
# Requiring the csel's two sources to be exactly {Ra,Rb} is the tight part:
# our library holds two `orr ?,?,#0x4000` but only one of them feeds a csel.
# Exactly one (orr,csel) pair must exist anywhere, otherwise we abort.
# The patch itself is derived from what we found: keep the clean source Rb.
TD_ORR_N=0 TD_PAIR_N=0 TD_ORR_AT=
TD_OFF=0 TD_ORIG=0 TD_PATCH=0

tier_d() { # $1 = pristine stock library ; 0 = exactly one pair found
	_td_st=$1
	_td_hex=$(hexscan orr "$_td_st") || _td_hex=
	[ -n "$_td_hex" ] || return 1
	_td_prev=
	while IFS= read -r _td_ln; do
		[ -z "$_td_ln" ] && continue
		_td_h=${_td_ln%%:*}
		case $_td_h in
			''|*[!0-9]*) _td_h=${_td_ln%:*}; _td_h=${_td_h##*:} ;;
		esac
		_td_o=$((_td_h / 2))
		[ $((_td_o % 4)) -eq 0 ] || continue
		[ "$_td_o" = "$_td_prev" ] && continue
		# regex is only a pre-filter: confirm the exact logical-immediate encoding
		_td_w=$(hex2u32 "$($NSPRE dd if="$_td_st" bs=1 skip=$_td_o count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')")
		if [ $((_td_w & 0xFFFFFC00)) -eq $((0xB2720000)) ]; then
			_td_sf=64
		elif [ $((_td_w & 0xFFFFFC00)) -eq $((0x32120000)) ]; then
			_td_sf=32
		else
			continue
		fi
		_td_prev=$_td_o
		_td_ra=$((_td_w & 31))
		_td_rb=$((_td_w >> 5 & 31))
		TD_ORR_N=$((TD_ORR_N + 1))
		TD_ORR_AT="$TD_ORR_AT $_td_o"
		[ "$_td_ra" -eq "$_td_rb" ] && continue     # orr x8,x8,#.. is a dead shape
		_td_ctx=$($NSPRE dd if="$_td_st" bs=1 skip=$((_td_o + 4)) count=32 2>/dev/null | od -An -tx1 | tr -d ' \n')
		_td_i=0
		while [ $_td_i -lt 64 ]; do
			_td_s=${_td_ctx:$_td_i:8}
			[ ${#_td_s} -eq 8 ] || break
			_td_cw=$(hex2u32 "$_td_s")
			_td_ok=0
			if [ "$_td_sf" -eq 64 ] && [ $((_td_cw & 0xFFE00C00)) -eq $((0x9A800000)) ]; then
				_td_ok=1
			elif [ "$_td_sf" -eq 32 ] && [ $((_td_cw & 0xFFE00C00)) -eq $((0x1A800000)) ]; then
				_td_ok=1
			fi
			if [ "$_td_ok" -eq 1 ]; then
				_td_rd=$((_td_cw & 31))
				_td_rn=$((_td_cw >> 5 & 31))
				_td_rm=$((_td_cw >> 16 & 31))
				if { [ "$_td_rn" -eq "$_td_ra" ] && [ "$_td_rm" -eq "$_td_rb" ]; } ||
				   { [ "$_td_rn" -eq "$_td_rb" ] && [ "$_td_rm" -eq "$_td_ra" ]; }; then
					TD_PAIR_N=$((TD_PAIR_N + 1))
					TD_OFF=$((_td_o + 4 + _td_i / 2))
					TD_ORIG=$_td_cw
					if [ "$_td_sf" -eq 64 ]; then
						TD_PATCH=$((0xAA0003E0 | (_td_rb << 16) | _td_rd))
					else
						TD_PATCH=$((0x2A0003E0 | (_td_rb << 16) | _td_rd))
					fi
				fi
			fi
			_td_i=$((_td_i + 8))
		done
	done <<EOF
$_td_hex
EOF
	[ "$TD_PAIR_N" -eq 1 ]
}

# ---- 4. locate the target instruction ---------------------------
ui_print "  [2/5] locate target instruction"
OFF=
TIER=
GOT=
W=$($NSPRE dd if="$TGT" bs=1 skip=6003616 count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')
SIGLEN=
AC_N=0
AC_BEST=0
if [ "$W" = "$WIN" ] && [ -z "$MF_FORCE_TD" ]; then
	OFF=$KNOWN
	SIGLEN=32
	TIER=a
	GOT=1
	ui_print "       fast path hit at offset $OFF (0x5b9ba8)"
fi

if [ -z "$GOT" ]; then
	HITS=$(hexscan sig "$TGT")

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

	AC_N=$N
	AC_BEST=$BEST
	if [ "$N" -eq 1 ]; then
		SIGLEN=$BEST
		case $BEST in
			32) TIER=a ;;
			16) TIER=b ;;
			*)  TIER=c ;;
		esac
		# A 16-byte window or csel|ret is hard evidence. A bare 4-byte
		# anchor is not: there are hundreds of `csel x0,?` in a real
		# library, so a lone one may well be an accident - it only wins
		# if tier D turns up nothing better.
		if [ "$BEST" -ge 16 ] && [ -z "$MF_FORCE_TD" ]; then
			GOT=1
			ui_print "       scanned: best match ${BEST} hex chars, unique -> offset $OFF"
		fi
	else
		OFF=
	fi
fi

# Tiers A-C need the exact bytes; a different compiler release allocates
# different registers and all three miss (this is what HyperOS 3 / Android 16
# does, where v1.1 aborted safely instead of bootlooping). Tier D keys on the
# shape of the code instead and runs whenever the byte evidence is weak.
if [ -z "$GOT" ]; then
	ui_print "       exact byte match weak or absent, trying semantic locator (tier D)"
	if tier_d "$TGT"; then
		OFF=$TD_OFF
		ORIG_HEX=$(u32hex "$TD_ORIG")
		PATCH_HEX=$(u32hex "$TD_PATCH")
		SIGLEN=8
		TIER=d
		GOT=1
		ui_print "       tier D: 'orr ?,?,#0x4000' -> csel pair unique, offset $OFF"
		ui_print "               orig=$ORIG_HEX patch=$PATCH_HEX"
	elif [ "$AC_N" -eq 1 ] && [ -z "$MF_FORCE_TD" ]; then
		GOT=1
		ui_print "       tier D inconclusive, using the unique csel anchor at offset $OFF"
	else
		fail "signature not found in this build (md5=$STOCK_MD5, exact csel anchors=$AC_N len=$AC_BEST; tier D 'orr #0x4000' sites=$TD_ORR_N at:$TD_ORR_AT, csel pairs=$TD_PAIR_N) - unsupported"
	fi
fi

[ -n "$OFF" ] || fail "failed to compute patch offset"
ui_print "       patch offset = $OFF (0x$(printf '%x' "$OFF"))"

# ---- 5. build the payload from our OWN library ------------------
ui_print "  [3/5] build payload"
mkdir -p "${PAY%/*}" 2>/dev/null
rm -f "$PAY" 2>/dev/null
cp "$TGT" "$PAY" 2>/dev/null || fail "cannot copy the stock library"

hexbytes "$PATCH_HEX" | dd of="$PAY" bs=1 seek="$OFF" conv=notrunc 2>/dev/null
B=$(dd if="$PAY" bs=1 skip="$OFF" count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$B" = "$PATCH_HEX" ] || fail "patch write verify failed (got $B, want $PATCH_HEX)"

# ---- 6. prove that ONLY those 4 bytes changed -------------------
ui_print "  [4/5] prove change is exactly 4 bytes"
V="$MODPATH/.mf_verify"
rm -f "$V" 2>/dev/null
cp "$PAY" "$V" 2>/dev/null || fail "verify copy failed"
hexbytes "$ORIG_HEX" | dd of="$V" bs=1 seek="$OFF" conv=notrunc 2>/dev/null
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
	echo "version=1.3"
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
	echo "tier=${TIER:-a}"
	echo "patch_hex=$PATCH_HEX"
	echo "orig_hex=$ORIG_HEX"
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
