"""transplant.py <tools> <database> <base.bit> <donor.bit> <out.bit> <tile type prefix>...: the base
image with the donor's bits of every tile whose type starts with a prefix."""
import sys, json
T, X = sys.argv[1], sys.argv[2]
sys.path.insert(0, T)
import bitstream, fasm2bit
base_path, donor_path, out, prefixes = sys.argv[3], sys.argv[4], sys.argv[5], tuple(sys.argv[6:])
frames = json.load(open(X + '/xcku3p-ffvb676-2-e/frames.json')); grid = json.load(open(X + '/xcku3p/tilegrid.json'))
fb = frames['frame_bits']; addrs = [f + k for f, c in frames['runs'] for k in range(c)]; place = {a: i for i, a in enumerate(addrs)}
base = bytearray(bitstream.image_bits(base_path, frames)); donor = bitstream.image_bits(donor_path, frames)
owners = {}
for t in grid.values():
    for sh in t['bits'].values():
        b0 = int(sh['baseaddr'], 16)
        for k in range(sh['frames']):
            if b0 + k in place: owners.setdefault(place[b0 + k], []).append((sh['offset_bit'], t['type']))
moved = 0
for f, shares in owners.items():
    shares.sort()
    for i, (start, kind) in enumerate(shares):
        if not kind.startswith(prefixes): continue
        end = shares[i + 1][0] if i + 1 < len(shares) else fb
        for b in range(start, end):
            bit = f * fb + b; v = donor[bit // 8] >> (bit % 8) & 1
            if (base[bit // 8] >> (bit % 8) & 1) != v: base[bit // 8] ^= 1 << (bit % 8); moved += 1
print(moved, 'bits of', prefixes, 'from', donor_path)
img = fasm2bit.Image(frames); img.bits = base; img.make_checks()
open(out, 'wb').write(bitstream.image(img.words(), 0x04A63093, 'xcku3p-ffvb676-2-e'))
