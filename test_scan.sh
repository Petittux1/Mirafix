#!/usr/bin/env bash
# Unit tests for the hexscan byte scanner (customize.sh).
#
# Background: `grep -b` (byte offsets) does not exist in BusyBox grep, so the
# old `grep -bo` pipeline produced nothing inside an installer and every scan
# looked like "signature not found". hexscan() scans in awk instead.
#
# awk reports every pattern occurrence independently, whereas grep -E works
# leftmost-longest and non-overlapping, so a shorter signature nested inside a
# longer one (csel inside csel|ret inside the 16-byte window) is swallowed by
# grep but not by awk. That difference is harmless and strictly safer, and
# these tests pin down the invariants that make it harmless:
#   * awk's output is a superset of grep's
#   * BEST (longest match) and N (how many of them) are identical - those are
#     the only two numbers the install gate actually reads
#   * every planted signature is reported at the right offset, even when it
#     straddles an od line boundary
# Not shipped in the module zip.
set -u

STG=$(cd "$(dirname "$0")" && pwd)
GATE="$STG/customize.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()    { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

# ---------- load the scanner out of customize.sh ------------------
eval "$(awk '
	/^HS_AWK=/ { on = 1 }
	on {
		print
		if (hex && $0 == "}") exit
		if ($0 ~ /^hexscan\(\) \{/) hex = 1
	}
' "$GATE")" || { echo "cannot extract hexscan() from customize.sh"; exit 1; }
command -v hexscan >/dev/null 2>&1 || { echo "hexscan() not defined after eval"; exit 1; }

WIN=0b0172b25f01096a6011889ac0035fd6
CSRET=6011889ac0035fd6
ANCHOR=6011889a
NSPRE=
# hexscan() tests this for the grep fallback; keep it declared so `set -u`
# in this harness does not fire, and never let it leak between calls.
MF_NO_AWK=

hex2bin() { local h="$1" i out=""; for ((i = 0; i < ${#h}; i += 2)); do out="$out\\x${h:i:2}"; done; printf "$out"; }
poke()     { hex2bin "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null; }

# the two numbers the install gate reads out of a sig scan
gate_stats() { # stdin: hexscan sig lines  ->  "BEST N"
	awk '{ n = length(substr($0, index($0, ":") + 1)); if (n > best) { best = n; cnt = 1 }
	      else if (n == best) cnt++ }
	     END { printf "%d %d", best + 0, cnt + 0 }'
}

echo "== 1. awk is a superset of the old grep -b pipeline =="
LIB="$WORK/lib.so"
# ASCII filler with no digits at all: a signature can only appear where we
# put it, and an od line boundary is 16 bytes
yes "Mirafix hexscan parity filler line.............." | head -c 300000 > "$LIB"

# WIN, csel|ret and csel plantings, several of them straddling a boundary
poke "$LIB" 3      "$WIN"      # 3..18   straddles boundary 16
poke "$LIB" 25     "$CSRET"    # 25..32  straddles boundary 32
poke "$LIB" 111    "$CSRET"    # 111..118 straddles boundary 112
poke "$LIB" 1000   "$ANCHOR"   # 1000..1003 in line
poke "$LIB" 1007   "$ANCHOR"   # 1007..1010 straddles boundary 1008
poke "$LIB" 4096   "$WIN"      # 4096..4111 line aligned
poke "$LIB" 65537  "$WIN"      # 65537..65552 straddles boundary 65552
poke "$LIB" 100003 "$WIN"      # 100003..100018 straddles boundary 100016

for MODE in sig orr; do
	AWK_OUT=$(hexscan "$MODE" "$LIB")
	GRP_OUT=$(MF_NO_AWK=1 hexscan "$MODE" "$LIB")
	MF_NO_AWK=
	MISSING=$(printf '%s\n' "$GRP_OUT" | grep -vxF -f <(printf '%s\n' "$AWK_OUT") | grep -c . || true)
	check "$MODE: every grep -b line is also reported by awk" 0 "$MISSING"
	[ "$MISSING" -ne 0 ] && printf '%s\n' "$GRP_OUT" | grep -vxF -f <(printf '%s\n' "$AWK_OUT") | sed 's/^/       missing /'
done

echo "== 2. BEST and N (the gate's only inputs) are identical =="
STAT_AWK=$(hexscan sig "$LIB" | gate_stats)
STAT_GRP=$(MF_NO_AWK=1 hexscan sig "$LIB" | gate_stats)
MF_NO_AWK=
check "gate reads BEST N the same from either scanner" "$STAT_GRP" "$STAT_AWK"
echo "    awk: BEST,N=$STAT_AWK   grep: BEST,N=$STAT_GRP"
[ "$STAT_AWK" = "32 4" ] && ok "four unique 16-byte windows found" || bad "expected BEST=32 N=4, got $STAT_AWK"

echo "== 3. every planted signature is reported at its own offset =="
FOUND=$(hexscan sig "$LIB" | cut -d: -f1 | sort -n -u | tr '\n' ' ')
# WIN@3,4096,65537,100003  -> those offsets, plus csel|ret & csel at +8 inside
# each window, plus the standalone CSRET/ANCHOR plantings
EXP="6 22 50 222 2000 2014 8192 8208 131074 131090 200006 200022"
check "hex offsets = 2 x byte offset, none lost at a line boundary" "$EXP" "$(echo $FOUND)"

echo "== 4. orr prefilter: only b1 in 00..03 is reported =="
ORRLIB="$WORK/orr.so"
yes "Mirafix orr prefilter filler line..............." | head -c 200000 > "$ORRLIB"
poke "$ORRLIB" 16  "0b0172b2"   # b1=01 -> report @32
poke "$ORRLIB" 64  "0f0772b2"   # b1=07 -> must be dropped
poke "$ORRLIB" 128 "03021232"   # 32-bit orr, b1=02 -> report @256
poke "$ORRLIB" 140 "000072b2"   # b1=00 -> report @280
ORR_OUT=$(hexscan orr "$ORRLIB" | sort -n)
printf '%s\n' "$ORR_OUT" | sed 's/^/    /'
check "orr candidates at hex 32 / 256 / 280" "32 256 280" \
	"$(printf '%s\n' "$ORR_OUT" | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//')"

echo "== 5. the prefilter is a superset of tier_d's mask check =="
# Rebuild each candidate word the way the CPU sees it: od order is
# b0 b1 b2 b3, the word is b3 b2 b1 b0.
word_at() { od -An -v -tx1 "$1" | tr -d ' \n' | awk \
	'{ print substr($0,7,2) substr($0,5,2) substr($0,3,2) substr($0,1,2) }'; }
BADCNT=0
for B1 in 00 01 02 03; do
	T="$WORK/m_$B1.so"
	yes "Mirafix mask superset filler line..............." | head -c 64 > "$T"
	poke "$T" 0 "00${B1}72b2"
	W=$(word_at "$T")
	[ $((0x$W & 0xFFFFFC00)) -eq $((0xB2720000)) ] || { BADCNT=$((BADCNT + 1)); echo "      b1=$B1 word 0x$W rejected"; }
done
check "b1=00..03 all satisfy the 0xFFFFFC00 mask" 0 "$BADCNT"

T="$WORK/m_07.so"
yes "Mirafix mask superset filler line..............." | head -c 64 > "$T"
poke "$T" 0 "000772b2"
W=$(word_at "$T")
[ $((0x$W & 0xFFFFFC00)) -ne $((0xB2720000)) ] &&
	ok "b1=07 is correctly dropped by the mask" || bad "b1=07 should be dropped, word 0x$W"

echo "== 6. awk implementations agree on the real library =="
REAL="${MF_REAL_LIB:-}"
if [ -n "$REAL" ] && [ -f "$REAL" ]; then
	SIG_REF=$(hexscan sig "$REAL" | sort)
	ORR_REF=$(hexscan orr "$REAL" | sort)
	echo "    sig lines: $(printf '%s\n' "$SIG_REF" | grep -c .)   orr candidates: $(printf '%s\n' "$ORR_REF" | grep -c .)"
	printf '%s\n' "$SIG_REF" | sed 's/^/      sig /'
	printf '%s\n' "$ORR_REF" | sed 's/^/      orr /'
	for AWKCMD in "/system/bin/awk"; do
		[ -x "$AWKCMD" ] || { ok "$AWKCMD absent, skipped"; continue; }
		S=$(od -An -v -tx1 "$REAL" | "$AWKCMD" -v mode=sig -v WIN="$WIN" -v CSRET="$CSRET" \
			-v ANCHOR="$ANCHOR" "$HS_AWK" | sort)
		O=$(od -An -v -tx1 "$REAL" | "$AWKCMD" -v mode=orr "$HS_AWK" | sort)
		check "$AWKCMD sig == default awk" "$SIG_REF" "$S"
		check "$AWKCMD orr == default awk" "$ORR_REF" "$O"
	done
	GS=$(hexscan sig "$REAL" | gate_stats)
	GO=$(MF_NO_AWK=1 hexscan sig "$REAL" | gate_stats)
	MF_NO_AWK=
	check "real lib: BEST/N identical across scanners" "$GO" "$GS"
	echo "    gate reads BEST,N = $GS"
else
	ok "no MF_REAL_LIB, real-library checks skipped"
fi

echo "== 7. performance =="
if [ -n "$REAL" ] && [ -f "$REAL" ]; then
	T0=$(date +%s); hexscan sig "$REAL" >/dev/null; T1=$(date +%s)
	hexscan orr "$REAL" >/dev/null; T2=$(date +%s)
	echo "    sig $((T1 - T0))s, orr $((T2 - T1))s on $(stat -c %s "$REAL") bytes"
	[ $((T1 - T0)) -le 20 ] && ok "sig scan <= 20s" || bad "sig scan too slow: $((T1 - T0))s"
	[ $((T2 - T1)) -le 20 ] && ok "orr scan <= 20s" || bad "orr scan too slow: $((T2 - T1))s"
else
	ok "no MF_REAL_LIB, perf skipped"
fi

echo
echo "hexscan tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
