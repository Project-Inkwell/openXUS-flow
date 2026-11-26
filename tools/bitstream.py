"""An UltraScale+ configuration image (.bit) written from its frames.

The packets are UltraScale+ configuration packets (UG570): a type-1 packet
writes a register, a type-2 the long frame data. The sequence is the one a
full, uncompressed, unencrypted image takes: the configuration registers,
the frame address 0, WCFG, every frame in one FDRI write, then the CRC
check and the start-up commands. The CRC is CRC-32C over each written word
with its register's address above it (37 bits, least significant first),
reset by RCRC.
"""
import struct
import time

FAR, FDRI, CMD, CTL0, MASK, COR0, COR1, IDCODE, CTL1, CRC, TIMER, WBSTAR, BOOTSTS = 1, 2, 4, 5, 6, 9, 14, 12, 24, 0, 17, 16, 19
RCRC, WCFG, GRESTORE, DGHIGH, START, DESYNC, SWITCH, NULL = 7, 1, 10, 3, 5, 13, 9, 0
NOOP = 0x20000000
SYNC = 0xAA995566


def write(reg, *words):
    """A type-1 write of `words` to `reg`."""
    return [0x30000000 | (reg << 13) | len(words), *words]


def crc32c(crc, reg, word):
    value = (reg << 32) | word
    for i in range(37):
        bit = (value >> i) & 1
        crc = (crc >> 1) ^ (0x82F63B78 if (crc ^ bit) & 1 else 0)
    return crc


class Packets:
    def __init__(self):
        self.words = []
        self.crc = 0

    def noop(self, count=1):
        self.words += [NOOP] * count

    def write(self, reg, *words):
        self.words += write(reg, *words)
        if reg == CRC:
            self.crc = 0
            return
        for word in words:
            self.crc = crc32c(self.crc, reg, word)
        if reg == CMD and words and words[0] == RCRC:
            self.crc = 0

    def frames(self, data):
        """Every frame in one write: a type-1 FDRI write of no words, then a
        type-2 of them all."""
        self.words += [0x30004000, 0x50000000 | len(data)]
        self.words += data
        for word in data:
            self.crc = crc32c(self.crc, FDRI, word)

    def check(self):
        self.write(CRC, self.crc)


def image(frames, idcode, part, design="top"):
    """The .bit of `frames` (a list of words, every frame in the image's
    order with its padding) for the device of `idcode`."""
    p = Packets()
    p.words.append(SYNC)
    p.noop(2)
    p.write(TIMER, 0)
    p.write(WBSTAR, 0)
    p.write(CMD, NULL)
    p.noop()
    p.write(CMD, RCRC)
    p.noop(2)
    p.write(FAR, 0)
    p.write(BOOTSTS, 0)
    p.write(COR0, 0x38003FE5)
    p.write(COR1, 0x00400000)
    p.write(IDCODE, idcode)
    p.write(CMD, SWITCH)
    p.noop()
    p.write(MASK, 0x00000001)
    p.write(CTL0, 0x00000101)
    p.write(MASK, 0)
    p.write(CTL1, 0)
    p.noop(8)
    p.write(FAR, 0)
    p.write(CMD, WCFG)
    p.noop()
    p.frames(frames)
    p.check()
    p.noop(2)
    p.write(CMD, GRESTORE)
    p.noop(2)
    p.write(CMD, DGHIGH)
    p.noop(20)
    p.write(CMD, START)
    p.noop()
    p.write(FAR, 0x07FC0000)
    p.write(MASK, 0x00000101)
    p.write(CTL0, 0x00000101)
    p.check()
    p.noop(2)
    p.write(CMD, DESYNC)
    p.noop(400)
    body = struct.pack(">%dI" % len(p.words), *p.words)
    preamble = struct.pack(">20I", *([0xFFFFFFFF] * 16 + [0x000000BB, 0x11220044, 0xFFFFFFFF, 0xFFFFFFFF]))
    return header(design, part, len(preamble) + len(body)) + preamble + body


def header(design, part, length):
    """The .bit file's header: its fields `a` (design), `b` (part), `c`
    (date), `d` (time), then `e` and the image's length."""
    def field(key, text):
        data = text.encode() + b"\0"
        return key + struct.pack(">H", len(data)) + data
    now = time.localtime()
    head = struct.pack(">H", 9) + bytes.fromhex("0ff00ff00ff00ff000") + struct.pack(">H", 1)
    head += field(b"a", "%s;UserID=0XFFFFFFFF;Version=openXUS" % design)
    head += field(b"b", part)
    head += field(b"c", time.strftime("%Y/%m/%d", now))
    head += field(b"d", time.strftime("%H:%M:%S", now))
    return head + b"e" + struct.pack(">I", length)


def read_frames(path):
    """The frames of a .bit (its one long FDRI write) and its IDCODE."""
    data = open(path, "rb").read()
    sync = data.find(struct.pack(">I", SYNC))
    words = struct.unpack(">%dI" % ((len(data) - sync) // 4), data[sync:sync + (len(data) - sync) // 4 * 4])
    idcode, i = None, 1
    while i < len(words):
        w = words[i]
        if w >> 29 == 1:
            reg, n = (w >> 13) & 0x3FFF, w & 0x7FF
            if reg == IDCODE and n:
                idcode = words[i + 1]
            i += 1 + n
        elif w >> 29 == 2:
            n = w & 0x7FFFFFF
            return list(words[i + 1:i + 1 + n]), idcode
        else:
            i += 1
    raise ValueError("%s has no frame data" % path)


def image_bits(path, frames):
    """A .bit's image as one string of bits: its frames in the order of `frames["runs"]` (a frames.json), the two
    empty frames after each row of each block type left out, each frame's
    words as they are written, packed little end first -- bit `i` the bit
    `i % 8` of byte `i / 8`."""
    words, _ = read_frames(path)
    frame_words = frames["frame_bits"] // 32
    addresses = [first + k for first, count in frames["runs"] for k in range(count)]
    out = bytearray()
    at = 0
    for k, address in enumerate(addresses):
        for word in words[at:at + frame_words]:
            out += word.to_bytes(4, "little")
        at += frame_words
        following = addresses[k + 1] if k + 1 < len(addresses) else None
        if following is None or (following >> 18) != (address >> 18):
            at += 2 * frame_words
    return bytes(out)
