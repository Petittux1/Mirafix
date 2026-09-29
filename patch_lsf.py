#!/usr/bin/env python3
# Patch libsurfaceflinger.so:
#   0x5b9ba8: 9a881160 (csel x0, x11, x8, ne)  ->  aa0803e0 (mov x0, 8)
# This removes the unconditional GRALLOC_USAGE_PROTECTED (0x4000) OR in
# QtiVirtualDisplaySurfaceExtension::qtiSetOutputUsage(unsigned long).
#
# Usage:  python3 patch_lsf.py [SRC] [DST]
#   SRC defaults to the on-device stock library
#   DST defaults to ./lsf.patched.so
import hashlib
import sys

OFF = 0x5B9BA8
OLD = bytes.fromhex("6011889a")
NEW = bytes.fromhex("e00308aa")
EXPECT_MD5 = "dfc8d808aa4ddcb3a127397fa8bc77e1"  # stock libsurfaceflinger.so

SRC = sys.argv[1] if len(sys.argv) > 1 else "/system_ext/lib64/libsurfaceflinger.so"
DST = sys.argv[2] if len(sys.argv) > 2 else "lsf.patched.so"

data = bytearray(open(SRC, "rb").read())
md5 = hashlib.md5(data).hexdigest()
print("src size:", len(data), "md5:", md5)
if md5 != EXPECT_MD5:
    print("ABORT: unexpected source md5")
    sys.exit(1)
if bytes(data[OFF:OFF + 4]) != OLD:
    print("ABORT: bytes at %#x = %s, expected %s"
          % (OFF, bytes(data[OFF:OFF + 4]).hex(), OLD.hex()))
    sys.exit(1)

data[OFF:OFF + 4] = NEW
with open(DST, "wb") as fh:
    fh.write(bytes(data))
with open(DST, "rb") as fh:
    out = fh.read()

print("patched bytes:", bytes(out[OFF:OFF + 4]).hex(), "(expect e00308aa)")
print("dst md5:", hashlib.md5(out).hexdigest())
if bytes(out[OFF:OFF + 4]) != NEW:
    print("ABORT: verify failed")
    sys.exit(1)
print("OK")
