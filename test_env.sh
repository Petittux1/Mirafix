#!/usr/bin/env bash
# Install-gate tests run inside a REPRODUCTION of the real installer shell.
#
# Magisk (and KernelSU) run module scripts as `busybox ash` with
# ASH_STANDALONE=1, which resolves EVERY command to a BusyBox applet before
# it even looks at PATH. That is why `customize.sh` line 14 (putting
# /system/bin first) does not help: `grep` is still BusyBox grep, and
# BusyBox grep has no `-b`, so the old `grep -bo` scanner printed
# "grep: invalid option -- b", produced no output, and every install that
# needed a scan died with "signature not found" on a device it should have
# patched. The other test suites run under bash with GNU tools, so they
# could not see this - this one does.
# Not shipped in the module zip.
set -u

STG=$(cd "$(dirname "$0")" && pwd)
GATE="$STG/customize.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
OUT=
report() { # $1=name $2=ok/FAIL $3=detail
	if [ "$2" = ok ]; then
		pass=$((pass + 1)); printf '  ok   %-30s %s\n' "$1" "$3"
	else
		fail=$((fail + 1)); printf '  FAIL %-30s %s\n' "$1" "$3"
		printf '%s\n' "${OUT:-}" | sed 's/^/         /'
	fi
}

# ---------- find a BusyBox the Termux user can execute -------------
# The file MUST be named `busybox`: BusyBox dispatches on argv[0], so a copy
# called anything else tries to run an applet by that name and dies with
# "<name>: applet not found".
BB=
for c in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
	"/data/data/com.termux/files/usr/bin/busybox"; do
	if [ -x "$c" ] && [ -r "$c" ]; then BB=$c; break; fi
done
if [ -z "$BB" ] || [ ! -x "$BB" ] || [ ! -r "$BB" ]; then
	su -c "cp /data/adb/ksu/bin/busybox '$WORK/busybox' 2>/dev/null; chmod 755 '$WORK/busybox'" 2>/dev/null
	[ -x "$WORK/busybox" ] && BB=$WORK/busybox
fi
[ -n "$BB" ] && [ -r "$BB" ] && [ -x "$BB" ] || {
	echo "SKIP: no usable busybox readable as $(id -un)"; exit 0; }
echo "== installer shell reproduction =="
echo "  busybox: $BB ($("$BB" 2>&1 | head -n 1))"

# ---------- does this shell reproduce the bug? --------------------
PROBE=$(ASH_STANDALONE=1 "$BB" ash -c '
	echo "grep -b probe:"
	echo hello123 | grep -bo 123 2>&1 | head -n 1
	echo "awk probe:"
	awk "BEGIN { print \"awk-ok\" }" 2>&1 | head -n 1
')
printf '%s\n' "$PROBE" | sed 's/^/  /'
case $PROBE in
*"invalid option"*) report "grep -b unsupported (the bug)" ok "reproduced" ;;
*) report "grep -b unsupported (the bug)" FAIL "this busybox grep DOES have -b, test is vacuous" ;;
esac
case $PROBE in
*awk-ok*) report "awk available" ok "busybox awk works" ;;
*) report "awk available" FAIL "no awk: hexscan has no scanner" ;;
esac

# ---------- helpers (mirrors test_gate.sh) ------------------------
hex2bin() { local h="$1" i out=""; for ((i = 0; i < ${#h}; i += 2)); do out="$out\\x${h:i:2}"; done; printf "$out"; }
poke()     { hex2bin "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null; }
read4()    { dd if="$1" bs=1 skip="$2" count=4 2>/dev/null | od -An -tx1 | tr -d ' \n'; }
mk_ascii() { yes "Mirafix installer env test line" | head -c "$2" > "$1"; }
u32hex()   { printf '%08x' "$1" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/'; }
orr64()    { u32hex $((0xB2720000 | ($2 << 5) | $1)); }
csel64()   { u32hex $((0x9A800000 | ($3 << 16) | ($4 << 12) | ($2 << 5) | $1)); }
put_pair() { poke "$1" "$2" "$3"; poke "$1" $(($2 + 4)) "1f2003d5"; poke "$1" $(($2 + 8)) "$4"; }

WIN_HEX="0b0172b25f01096a6011889ac0035fd6"
CSRET_HEX="6011889ac0035fd6"
ANCHOR_HEX="6011889a"

# ---------- run the gate exactly the way Magisk does --------------
# ASH_STANDALONE=1 + busybox ash: grep/awk/od/dd/sed/stat/md5sum are all
# applets. MF_TGT/MF_NO_PERMS/MF_FORCE_TD are the offline test hooks.
run_gate() { # $1=stock file, $2...=extra env assignments
	local stock="$1"; shift
	local dir="$WORK/mod.$RANDOM$RANDOM"
	mkdir -p "$dir"
	printf 'id=mirafix\nname=test\n' > "$dir/module.prop"
	# `env` rather than a `VAR=x "$@" cmd` prefix: the shell decides which
	# words are assignments at parse time, so a quoted "$@" would become the
	# command word and each test hook would be run as a command.
	OUT=$(env ASH_STANDALONE=1 ${1+"$@"} "$BB" ash -c '
		ui_print() { printf "  | %s\n" "$1"; }
		abort()    { printf "  ABORT: %s\n" "$1"; }
		MODPATH=$1; GATE=$2; MF_TGT=$3; MF_NO_PERMS=1
		. "$GATE"
	' _ "$dir" "$GATE" "$stock" 2>&1)
	RC=$?
	MODDIR_T="$dir"
	PAY="$dir/system_ext/lib64/libsurfaceflinger.so"
	INFO="$dir/build.info"
	MARK="$dir/unsupported"
}

expect_ok() { # $1=name $2=offset [$3=4-byte hex]
	local name="$1" want="$2" hx="${3:-}" got
	[ "$RC" = 0 ] || { report "$name" FAIL "gate aborted (rc=$RC)"; return; }
	[ -f "$PAY" ] || { report "$name" FAIL "no payload"; return; }
	got=$(sed -n 's/^offset=//p' "$INFO")
	[ "$got" = "$want" ] || { report "$name" FAIL "offset=$got want=$want"; return; }
	local b; b=$(read4 "$PAY" "$want")
	[ "$b" = "${hx:-e00308aa}" ] || { report "$name" FAIL "payload@$want=$b want ${hx:-e00308aa}"; return; }
	report "$name" ok "offset=$want payload=$b tier=$(sed -n 's/^tier=//p' "$INFO")"
}

expect_fail() { # $1=name $2=message-substring
	local name="$1" why="$2"
	[ "$RC" != 0 ] || { report "$name" FAIL "expected abort, but succeeded"; return; }
	[ -f "$MARK" ] || { report "$name" FAIL "no unsupported marker"; return; }
	case $OUT in
	*"$why"*) report "$name" ok "aborted safely: $why" ;;
	*) report "$name" FAIL "wanted '$why', got: $(printf '%s\n' "$OUT" | tail -n 3 | head -n 1)" ;;
	esac
}

echo
echo "== gate under ASH_STANDALONE busybox ash =="

# --- 1. fast path (no scan needed) --------------------------------
F=$WORK/fast; mk_ascii "$F" 7000000; poke "$F" 6003616 "$WIN_HEX"
run_gate "$F"
expect_ok "fast path" 6003624

# --- 2. shifted window: FORCES a full scan ------------------------
F=$WORK/scan; mk_ascii "$F" 2500000; poke "$F" 1000008 "$WIN_HEX"
run_gate "$F"
expect_ok "full scan (hexscan sig)" 1000016

# --- 3. unaligned window: byte offsets must survive ---------------
F=$WORK/odd; mk_ascii "$F" 2500000; poke "$F" 1234567 "$WIN_HEX"
run_gate "$F"
expect_ok "unaligned window" 1234575

# --- 4. csel|ret tier ---------------------------------------------
F=$WORK/csret; mk_ascii "$F" 2500000; poke "$F" 777776 "$CSRET_HEX"
run_gate "$F"
expect_ok "csel+ret tier" 777776

# --- 5. bare csel anchor ------------------------------------------
F=$WORK/anchor; mk_ascii "$F" 2500000; poke "$F" 333332 "$ANCHOR_HEX"
run_gate "$F"
expect_ok "bare csel anchor" 333332

# --- 6. no signature: must refuse, never half-install -------------
F=$WORK/none; mk_ascii "$F" 2500000
run_gate "$F"
expect_fail "no signature aborts" "not found in this build"

# --- 7. two windows: ambiguous, must refuse -----------------------
F=$WORK/two; mk_ascii "$F" 2500000
poke "$F" 500000 "$WIN_HEX"; poke "$F" 1900000 "$WIN_HEX"
run_gate "$F"
expect_fail "ambiguous aborts" "exact csel anchors=2"

# --- 8. tier D: the semantic locator runs on the busybox scanner --
F=$WORK/td; mk_ascii "$F" 2500000
put_pair "$F" 400000 "$(orr64 9 7)" "$(csel64 0 9 7 1)"   # orr x9,x7,#0x4000 ; csel x0,x9,x7,ne
run_gate "$F"
expect_ok "tier D foreign regs" 400008 "e00307aa"
[ "$(sed -n 's/^tier=//p' "$INFO" 2>/dev/null)" = d ] &&
	report "tier D recorded" ok "tier=d" || report "tier D recorded" FAIL "tier=$(sed -n 's/^tier=//p' "$INFO")"

# --- 9. tier D ambiguous -> refuse --------------------------------
F=$WORK/td2; mk_ascii "$F" 2500000
put_pair "$F" 400000 "$(orr64 9 7)" "$(csel64 0 9 7 1)"
put_pair "$F" 900000 "$(orr64 12 6)" "$(csel64 0 12 6 1)"
run_gate "$F"
expect_fail "tier D ambiguous aborts" "csel pairs=2"

# --- 10. NEGATIVE CONTROL: the old scanner must fail here ---------
# If this ever starts passing, either ASH_STANDALONE is not in effect or
# BusyBox grew `grep -b` - in both cases the test above proves nothing.
F=$WORK/oldscan; mk_ascii "$F" 2500000; poke "$F" 1000008 "$WIN_HEX"
run_gate "$F" MF_NO_AWK=1
if [ "$RC" != 0 ] && [ -f "$MARK" ]; then
	report "control: grep -b scanner fails" ok "aborted, as v1.2 did"
else
	report "control: grep -b scanner fails" FAIL "it succeeded - this suite is not reproducing the bug"
fi

# --- 11. the real stock library, fast path ------------------------
REAL="${MF_REAL_LIB:-}"
if [ -n "$REAL" ] && [ -f "$REAL" ]; then
	run_gate "$REAL"
	expect_ok "real stock library" 6003624
	# and the same library with the fast path disabled -> full scan + tier D
	run_gate "$REAL" MF_FORCE_TD=1
	expect_ok "real stock, forced scan/tier D" 6003624
	[ "$(sed -n 's/^tier=//p' "$INFO" 2>/dev/null)" = d ] &&
		report "forced tier D on real lib" ok "tier=d" ||
		report "forced tier D on real lib" FAIL "tier=$(sed -n 's/^tier=//p' "$INFO")"
else
	report "real stock library" ok "MF_REAL_LIB unset, skipped"
fi

echo
echo "== installer-environment tests: pass=$pass fail=$fail =="
[ "$fail" = 0 ]
