#!/data/data/com.termux/files/usr/bin/python3
# Patch libsurfaceflinger.so:
#   0x5b9ba8: 9a881160 (csel x0, x11, x8, ne)  ->  aa0803e0 (mov x0, x8)
# This removes the unconditional GRALLOC_USAGE_PROTECTED (0x4000) OR in
# QtiVirtualDisplaySurfaceExtension::qtiSetOutputUsage(unsigned long).
import hashlib, shutil, sys

SRC = "/system_ext/lib64/libsurfaceflinger.so"
DST = "/data/data/com.termux/files/usr/tmp/lsf.patched.so"
OFF = 0x5b9BA8
OLD = bytes.fromhex("6011889a")
NEW = bytes.fromhex("e00308aa")
EXPECT_MD5 = "dfc8d808aa4ddcb3a127397fa8bc77e1"

data = bytearray(open(SRC, "rb").read())
md5 = hashlib.md5(data).hexdigest()
print("src size:", len(data), "md5:", md5)
if md5 != EXPECT_MD5:
    print("ABORT: unexpected source md5"); sys.exit(1)
if bytes(data[OFF:OFF + 4]) != OLD:
    print("ABORT: bytes at %#x = %s, expected %s"
          % (OFF, bytes(data[OFF:OFF + 4]).hex(), OLD.hex())); sys.exit(1)

data[OFF:OFF + 4] = NEW
open(DST, "wb").write(bytes(data))
out = open(DST, "rb").read()
print("patched bytes:", bytes(out[OFF:OFF + 4]).hex(), "(expect e00308aa)")
print("dst md5:", hashlib.md5(out).hexdigest())
if bytes(out[OFF:OFF + 4]) != NEW:
    print("ABORT: verify failed"); sys.exit(1)
print("OK")
