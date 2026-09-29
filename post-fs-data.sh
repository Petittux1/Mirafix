#!/system/bin/sh
# CastFix post-fs-data stage.
# Guarantee the patched libsurfaceflinger.so is what init/SurfaceFlinger sees.
MODDIR="${0%/*}"
SRC="$MODDIR/system_ext/lib64/libsurfaceflinger.so"
TGT="/system_ext/lib64/libsurfaceflinger.so"
PATCHED="e00308aa"
OFF=6003624

say() { (log -t CastFix "$1") 2>/dev/null || echo "CastFix: $1"; }

# payload must be world readable with a system lib SELinux type,
# otherwise surfaceflinger (uid 1000) cannot dlopen it and the device reboots.
chmod 0644 "$SRC" 2>/dev/null
chcon u:object_r:system_lib_file:s0 "$SRC" 2>/dev/null

# read 4 bytes at $2 from $1 as seen from init's mount namespace
read4() {
	nsenter -t 1 -m -- dd if="$1" bs=1 skip="$2" count=4 2>/dev/null |
		od -An -tx1 2>/dev/null | tr -d ' \n'
}

bind_payload() {
	nsenter -t 1 -m -- mount --bind "$SRC" "$TGT" 2>/dev/null ||
		mount --bind "$SRC" "$TGT" 2>/dev/null
}

b=$(read4 "$TGT" "$OFF")
if [ "$b" != "$PATCHED" ]; then
	say "init view is $b, binding payload"
	bind_payload
	b=$(read4 "$TGT" "$OFF")
fi

if [ "$b" = "$PATCHED" ]; then
	say "patched libsurfaceflinger visible to init"
else
	say "FAILED to apply patch, init view=$b"
fi
exit 0
