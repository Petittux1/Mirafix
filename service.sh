#!/system/bin/sh
# CastFix late_start stage.
# SurfaceFlinger may have started before the magic mount landed; verify it is
# actually running the patched library and bounce it once if not.
# Hard safety rails: never bounce SF unless the payload is 0644, and roll back
# immediately if SF fails to come back up.
#
# NOTE: after a lazy unmount the kernel may render the mapped path as "/" in
# /proc/<pid>/maps, so we match by INODE, never by path.
MODDIR="${0%/*}"
SRC="$MODDIR/system_ext/lib64/libsurfaceflinger.so"
TGT="/system_ext/lib64/libsurfaceflinger.so"
PATCHED="e00308aa"
OFF=6003624

say() { (log -t CastFix "$1") 2>/dev/null || echo "CastFix: $1"; }

read4() {
	nsenter -t 1 -m -- dd if="$1" bs=1 skip="$OFF" count=4 2>/dev/null |
		od -An -tx1 2>/dev/null | tr -d ' \n'
}

sf_has_inode() {
	# $1 = pid, $2 = inode number
	grep -q " $2 " "/proc/$1/maps" 2>/dev/null
}

rollback() {
	say "$1 - ROLLING BACK to stock"
	nsenter -t 1 -m -- umount -l "$TGT" 2>/dev/null
	setprop ctl.restart surfaceflinger
	sleep 5
	exit 1
}

sf=$(pidof surfaceflinger)
cur4=$(read4 "$TGT")

if [ -z "$sf" ]; then
	say "service: surfaceflinger not running, nothing to do"
	exit 0
fi

if [ "$cur4" != "$PATCHED" ]; then
	say "service: target still $cur4, rebinding payload"
	nsenter -t 1 -m -- mount --bind "$SRC" "$TGT" 2>/dev/null
fi

tgt_ino=$(nsenter -t 1 -m -- stat -c %i "$TGT" 2>/dev/null)
if [ -n "$tgt_ino" ] && sf_has_inode "$sf" "$tgt_ino"; then
	say "service: SF pid=$sf already runs the patched lib (inode $tgt_ino)"
	exit 0
fi

# Only ever restart surfaceflinger if the payload is readable by uid 1000.
mode=$(stat -c %a "$SRC" 2>/dev/null)
if [ "$mode" != "644" ]; then
	chmod 0644 "$SRC" 2>/dev/null
	mode=$(stat -c %a "$SRC" 2>/dev/null)
fi
if [ "$mode" != "644" ]; then
	say "service: payload mode=$mode, refusing to restart SF"
	exit 1
fi

say "service: bouncing surfaceflinger (sf=$sf tgt_ino=$tgt_ino)"
setprop ctl.restart surfaceflinger

i=0; empty=0; restarts=0; cur=$sf
while [ "$i" -lt 45 ]; do
	sleep 1
	i=$((i + 1))
	cur=$(pidof surfaceflinger)
	if [ -z "$cur" ]; then
		empty=$((empty + 1))
		[ "$empty" -ge 6 ] && rollback "service: SF gone"
		continue
	fi
	empty=0
	[ "$cur" = "$sf" ] && continue

	# new pid: require it to stay up 5 seconds
	stable=1; j=0
	while [ "$j" -lt 5 ]; do
		sleep 1
		j=$((j + 1))
		[ "$(pidof surfaceflinger)" = "$cur" ] || { stable=0; break; }
	done
	if [ "$stable" = "1" ]; then
		if [ -n "$tgt_ino" ] && sf_has_inode "$cur" "$tgt_ino"; then
			say "service: SF up pid=$cur running patched lib (inode $tgt_ino)"
		else
			say "service: SF up pid=$cur but patched lib not mapped yet"
		fi
		exit 0
	fi
	restarts=$((restarts + 1))
	[ "$restarts" -ge 2 ] && rollback "service: SF keeps restarting"
	sf=$cur
done
say "service: timeout waiting for SF restart"
exit 0
