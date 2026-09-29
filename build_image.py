"""Build nova_fat.img = boot sector + Nova Core + version block + startup sound + FAT32 data partition.
   python build_image.py [version] [sound.u8 rate]      e.g.  python build_image.py 1.3 startup.u8 16000"""
import sys, struct
ver = (sys.argv[1] if len(sys.argv) > 1 else "1.3").encode()
BUILD = b"2026-09-29"
boot = open("boot_vesa.bin", "rb").read(); k = open("kernel_vesa.bin", "rb").read(); fat = open("fat32.img", "rb").read()
assert len(boot) == 512 and len(k) <= 199*512, len(k)
img = bytearray(2048*512)
img[0:512] = boot
img[512:512+len(k)] = k
blk = bytearray(512); blk[0:8] = b"NOVAUSB "; blk[8:8+len(ver)] = ver; blk[24:24+len(BUILD)] = BUILD
img[202*512:203*512] = blk                                   # lets an installed NovaOS spot this USB as an update
if len(sys.argv) > 3:
    pcm = open(sys.argv[2], "rb").read(); rate = int(sys.argv[3])
    n = (len(pcm) + 511) // 512; assert 257 + n <= 2047, "sound too long"
    img[256*512:256*512+16] = b"NOVASND " + struct.pack("<II", rate, len(pcm))
    img[257*512:257*512+len(pcm)] = pcm
    print(f"sound: {len(pcm)} samples @ {rate} Hz = {len(pcm)/rate:.1f} s, {n} sectors")
try:
    sfx = open("sfx.u8", "rb").read()                            # Music Maker's SFX bank -- fixed LBA, no header needed
    ns = (len(sfx) + 511) // 512; assert 600 + ns <= 2047, "sfx too long"
    img[600*512:600*512+len(sfx)] = sfx
    print(f"sfx: {len(sfx)} bytes, {ns} sectors")
except FileNotFoundError:
    pass
img += fat
open("nova_fat.img", "wb").write(img)
print(f"nova_fat.img: core {len(k)} B ({-(-len(k)//512)} sectors), version {ver.decode()}")
