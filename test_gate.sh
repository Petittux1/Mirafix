#!/usr/bin/env bash
# Offline unit tests for the Mirafix install gate (customize.sh).
# Not shipped in the module zip.
set -u

STG=$(cd "$(dirname "$0")" && pwd)
GATE="$STG/customize.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# ---------- synthetic stock libraries -----------------------------
WIN_HEX="0b0172b25f01096a6011889ac0035fd6"
CSRET_HEX="6011889ac0035fd6"
ANCHOR_HEX="6011889a"

# AArch64 words as od prints them (byte order preserved)
u32hex() { printf '%08x' "$1" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/'; }
orr64() { u32hex $((0xB2720000 | ($2 << 5) | $1)); }            # orr x$1, x$2, #0x4000
orr32() { u32hex $((0x32120000 | ($2 << 5) | $1)); }            # orr w$1, w$2, #0x4000
csel64() { u32hex $((0x9A800000 | ($3 << 16) | ($4 << 12) | ($2 << 5) | $1)); }
csel32() { u32hex $((0x1A800000 | ($3 << 16) | ($4 << 12) | ($2 << 5) | $1)); }
NOP_HEX="1f2003d5"

# place a foreign-looking orr/nop/csel triple
#   put_pair <file> <offset> <orr-hex> <csel-hex>
put_pair() {
	poke "$1" "$2" "$3"
	poke "$1" $(($2 + 4)) "$NOP_HEX"
	poke "$1" $(($2 + 8)) "$4"
}

hex2bin() { # hex string -> stdout as raw bytes
	local h="$1" i out=""
	for ((i = 0; i < ${#h}; i += 2)); do out="${out}\\x${h:i:2}"; done
	printf "$out"
}

# pure ASCII so the binary signature can never appear by chance
mk_ascii() { # $1=path $2=size
	yes "Mirafix gate unit test payload line" | head -c "$2" > "$1"
}

poke() { # $1=file $2=offset $3=hexbytes
	hex2bin "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

read4() { # $1=file $2=offset
	dd if="$1" bs=1 skip="$2" count=4 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

# ---------- harness ------------------------------------------------
# run_gate <stock file> -> prints gate output, sets RC
run_gate() {
	local stock="$1"
	local dir="$WORK/mod_$$.$RANDOM"
	mkdir -p "$dir"
	printf 'id=mirafix\nname=test\n' > "$dir/module.prop"
	OUT=$(GATE="$GATE" MODDIR_T="$dir" MF_TGT="$stock" MF_NO_PERMS=1 bash -c '
		ui_print() { printf "  | %s\n" "$1"; }
		abort()    { printf "  ABORT: %s\n" "$1"; }
		MODPATH="$MODDIR_T"
		. "$GATE"
	' 2>&1)
	RC=$?
	MODDIR_T="$dir"
	PAY="$dir/system_ext/lib64/libsurfaceflinger.so"
	INFO="$dir/build.info"
	MARK="$dir/unsupported"
}

report() { # $1=name $2=ok/FAIL $3=detail
	if [ "$2" = ok ]; then
		pass=$((pass + 1))
		printf '  \342\234\223 %-26s %s\n' "$1" "$3"
	else
		fail=$((fail + 1))
		printf '  \342\234\227 %-26s %s\n' "$1" "$3"
		printf '%s\n' "$OUT" | sed 's/^/        /'
	fi
}

expect_ok() { # $1=name $2=expected offset
	local name="$1" want="$2" got
	if [ "$RC" != 0 ]; then
		report "$name" FAIL "expected success, rc=$RC"
		return
	fi
	[ -f "$PAY" ] || { report "$name" FAIL "payload not generated"; return; }
	[ -f "$INFO" ] || { report "$name" FAIL "build.info not written"; return; }
	got=$(sed -n 's/^offset=//p' "$INFO")
	[ "$got" = "$want" ] || { report "$name" FAIL "offset=$got want=$want"; return; }
	local b
	b=$(read4 "$PAY" "$want")
	[ "$b" = "e00308aa" ] || { report "$name" FAIL "payload@$want = $b"; return; }
	report "$name" ok "offset=$want payload bytes ok"
}

expect_fail() { # $1=name $2=reason-substring
	local name="$1" why="$2"
	if [ "$RC" = 0 ]; then
		report "$name" FAIL "expected abort, but succeeded"
		return
	fi
	[ -f "$MARK" ] || { report "$name" FAIL "no 'unsupported' marker written"; return; }
	case $OUT in
		*"$why"*) report "$name" ok "aborted: $why" ;;
		*) report "$name" FAIL "wrong message, wanted '$why'; got: $(echo "$OUT" | tail -2 | head -1)" ;;
	esac
}

# like expect_ok but for a patch whose bytes are not the classic window
expect_ok_b() { # $1=name $2=offset $3=hexbytes
	local name="$1" want="$2" hx="$3" got
	if [ "$RC" != 0 ]; then
		report "$name" FAIL "expected success, rc=$RC"
		return
	fi
	got=$(sed -n 's/^offset=//p' "$INFO")
	[ "$got" = "$want" ] || { report "$name" FAIL "offset=$got want=$want"; return; }
	local b
	b=$(read4 "$PAY" "$want")
	[ "$b" = "$hx" ] || { report "$name" FAIL "payload@$want = $b want $hx"; return; }
	report "$name" ok "offset=$want payload=$hx"
}

expect_tier() { # $1=name $2=tier
	local name="$1" want="$2" got
	got=$(sed -n 's/^tier=//p' "$INFO")
	[ "$got" = "$want" ] && report "$name" ok "tier=$want" ||
		report "$name" FAIL "tier=${got:-<none>} want $want"
}

echo "== Mirafix install-gate unit tests =="

# --- case 1: fast path (window exactly at 0x5b9ba0) ---------------
F=$WORK/stock_fast
mk_ascii "$F" 7000000
poke "$F" 6003616 "$WIN_HEX"
run_gate "$F"
expect_ok "fast-path@0x5b9ba0" 6003624
[ "$(sed -n 's/^signature_len=//p' "$INFO")" = "32" ] &&
	report "fast-path siglen" ok "32" || report "fast-path siglen" FAIL "$(sed -n 's/^signature_len=//p' "$INFO")"

# --- case 2: shifted window, forces a full scan -------------------
F=$WORK/stock_scan
mk_ascii "$F" 2500000
poke "$F" 1000008 "$WIN_HEX"
run_gate "$F"
expect_ok "scan shifted window" 1000016
[ "$(sed -n 's/^signature_len=//p' "$INFO")" = "32" ] &&
	report "scan siglen" ok "32" || report "scan siglen" FAIL

# --- case 3: window at an UNaligned offset ------------------------
F=$WORK/stock_odd
mk_ascii "$F" 2500000
poke "$F" 1234567 "$WIN_HEX"
run_gate "$F"
expect_ok "scan unaligned offset" 1234575

# --- case 4: csel|ret only (no orr/tst before it) -----------------
F=$WORK/stock_csret
mk_ascii "$F" 2500000
poke "$F" 777776 "$CSRET_HEX"
run_gate "$F"
expect_ok "csel+ret tier" 777776
[ "$(sed -n 's/^signature_len=//p' "$INFO")" = "16" ] &&
	report "csel+ret siglen" ok "16" || report "csel+ret siglen" FAIL

# --- case 5: bare anchor only -------------------------------------
F=$WORK/stock_anchor
mk_ascii "$F" 2500000
poke "$F" 333332 "$ANCHOR_HEX"
run_gate "$F"
expect_ok "bare anchor tier" 333332
[ "$(sed -n 's/^signature_len=//p' "$INFO")" = "8" ] &&
	report "anchor siglen" ok "8" || report "anchor siglen" FAIL

# --- case 6: no signature at all -> must refuse -------------------
F=$WORK/stock_none
mk_ascii "$F" 2500000
run_gate "$F"
expect_fail "no signature" "not found in this build"

# --- case 7: two identical windows -> ambiguous, must refuse ------
F=$WORK/stock_two
mk_ascii "$F" 2500000
poke "$F" 500000 "$WIN_HEX"
poke "$F" 1900000 "$WIN_HEX"
run_gate "$F"
expect_fail "ambiguous (2 hits)" "exact csel anchors=2"

# --- case 8: window + decoy anchor -> highest tier wins -----------
F=$WORK/stock_decoy
mk_ascii "$F" 2500000
poke "$F" 900000 "$WIN_HEX"
poke "$F" 1800000 "$ANCHOR_HEX"
run_gate "$F"
expect_ok "decoy anchor ignored" 900008

# --- case 9: payload really differs from stock by 4 bytes only ----
F=$WORK/stock_delta
mk_ascii "$F" 2500000
poke "$F" 400000 "$WIN_HEX"
run_gate "$F"
if [ "$RC" = 0 ]; then
	s1=$(md5sum "$F" | cut -d' ' -f1)
	s2=$(md5sum "$PAY" | cut -d' ' -f1)
	[ "$s1" != "$s2" ] && report "payload != stock" ok "md5 differ" ||
		report "payload != stock" FAIL "identical md5"
	# restore the 4 original bytes -> must reproduce stock md5 exactly
	printf '\x60\x11\x88\x9a' | dd of="$PAY" bs=1 seek=400008 conv=notrunc 2>/dev/null
	s3=$(md5sum "$PAY" | cut -d' ' -f1)
	[ "$s1" = "$s3" ] && report "restore == stock md5" ok "$s1" ||
		report "restore == stock md5" FAIL "$s3 != $s1"
else
	report "payload != stock" FAIL "gate failed"
fi

echo
# ==================== tier D: foreign builds =======================
# The classic window is absent (a different compiler release allocated
# different registers). The installer must fall back to the
# orr #0x4000 -> csel semantic locator instead of refusing outright.

# --- case 10: different registers, same shape ----------------------
F=$WORK/stock_foreign
mk_ascii "$F" 2500000
put_pair "$F" 400000 "$(orr64 9 7)" "$(csel64 0 9 7 1)"   # orr x9,x7,#0x4000 ; csel x0,x9,x7,ne
run_gate "$F"
expect_ok_b "tier D foreign regs" 400008 "e00307aa"
expect_tier "tier D recorded" d

# --- case 11: swapped operands / inverted condition ---------------
F=$WORK/stock_inv
mk_ascii "$F" 2500000
put_pair "$F" 400000 "$(orr64 9 7)" "$(csel64 0 7 9 0)"   # csel x0,x7,x9,eq
run_gate "$F"
expect_ok_b "tier D inverted csel" 400008 "e00307aa"
expect_tier "tier D inverted tier" d

# --- case 12: dead-shape orr x8,x8,#0x4000 distractor ignored -----
F=$WORK/stock_dead
mk_ascii "$F" 2500000
put_pair "$F" 400000 "$(orr64 9 7)" "$(csel64 0 9 7 1)"
put_pair "$F" 900000 "$(orr64 8 8)" "$(csel64 0 8 8 1)"
run_gate "$F"
expect_ok_b "tier D dead shape ignored" 400008 "e00307aa"
expect_tier "tier D dead shape tier" d

# --- case 13: two genuine pairs -> ambiguous, must refuse ---------
F=$WORK/stock_2pair
mk_ascii "$F" 2500000
put_pair "$F" 400000 "$(orr64 9 7)" "$(csel64 0 9 7 1)"
put_pair "$F" 900000 "$(orr64 12 6)" "$(csel64 0 12 6 1)"
run_gate "$F"
expect_fail "tier D ambiguous" "csel pairs=2"

# --- case 14: orr present but never selected on -> refuse ---------
F=$WORK/stock_nocsel
mk_ascii "$F" 2500000
poke "$F" 400000 "$(orr64 9 7)"
run_gate "$F"
expect_fail "tier D orr w/o csel" "csel pairs=0"

# --- case 15: 32-bit variant (orr w / csel w) ---------------------
F=$WORK/stock_w
mk_ascii "$F" 2500000
put_pair "$F" 400000 "$(orr32 9 7)" "$(csel32 0 9 7 1)"
run_gate "$F"
expect_ok_b "tier D 32-bit variant" 400008 "e003072a"
expect_tier "tier D 32-bit tier" d

# --- case 16: a full window still outranks tier D -----------------
F=$WORK/stock_both
mk_ascii "$F" 7000000
poke "$F" 6003616 "$WIN_HEX"
put_pair "$F" 400000 "$(orr64 9 7)" "$(csel64 0 9 7 1)"
run_gate "$F"
expect_ok "window beats tier D" 6003624
expect_tier "window beats tier D tier" a

# --- case 17: tier D outranks a bare csel anchor ------------------
F=$WORK/stock_beat
mk_ascii "$F" 2500000
poke "$F" 900000 "$ANCHOR_HEX"
put_pair "$F" 400000 "$(orr64 9 7)" "$(csel64 0 9 7 1)"
run_gate "$F"
expect_ok_b "tier D beats bare anchor" 400008 "e00307aa"
expect_tier "tier D over anchor tier" d

# --- case 18: restoring the original bytes reproduces stock md5 ---
F=$WORK/stock_td_delta
mk_ascii "$F" 2500000
put_pair "$F" 400000 "$(orr64 9 7)" "$(csel64 0 9 7 1)"
run_gate "$F"
if [ "$RC" = 0 ]; then
	s1=$(md5sum "$F" | cut -d' ' -f1)
	s2=$(md5sum "$PAY" | cut -d' ' -f1)
	[ "$s1" != "$s2" ] && report "tier D payload != stock" ok "md5 differ" ||
		report "tier D payload != stock" FAIL "identical md5"
	printf '\x20\x11\x87\x9a' | dd of="$PAY" bs=1 seek=400008 conv=notrunc 2>/dev/null
	s3=$(md5sum "$PAY" | cut -d' ' -f1)
	[ "$s1" = "$s3" ] && report "tier D restore == stock" ok "ok" ||
		report "tier D restore == stock" FAIL "$s3 != $s1"
else
	report "tier D payload != stock" FAIL "gate failed"
fi

echo
echo "== result: pass=$pass fail=$fail =="
[ "$fail" = 0 ]
