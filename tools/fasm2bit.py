"""An UltraScale+ configuration image (.bit) from a FASM file and the device
database (openXUS-db, laid out as X-Ray's).

The image starts as an unused device's: each tile's cells that hold 1
where nothing of it is used (`defaults_<type>.db`) and the bits no tile
holds that hold 1 (`<part>/frames.json` `ones`). Each feature then sets
its bits (`segbits_<type>.db`): a bit `<row>_<bit>` to 1, `!<row>_<bit>`
to 0, a row counted across the tile's shares in address order, a bit from
the share's first (`tilegrid.json` `bits`). A vector feature
(`EQN[63:0] = 64'b...`) sets each entry's cell to the entry, or its
complement where its line says `!`. A tile type whose bits are functions
of its sites' settings (`functions_<type>.json`) has
each such bit set last from the settings its tile's features name
(`<site type>_X<n>.<element>.<attribute>.<value>`, a vector's bits by
number), per what occupies the tile. Last each frame's check
(`frames.json` `check`) is made: its bits the exclusive or of the columns
of the frame's bits that hold 1. Bit b of word w of a frame is bit
32 w + b of it, b from the word's least significant. The frames go in
address order, two empty frames after each row of each block type, as the
device reads them.

    fasm2bit.py <database> <fabric> <part> <idcode> design.fasm design.bit
"""
import glob
import json
import os
import re
import sys

from bitstream import image

FRAME_WORDS = 93


def load(database, fabric, part):
    grid = json.load(open(os.path.join(database, fabric, "tilegrid.json")))
    frames = json.load(open(os.path.join(database, part, "frames.json")))
    segbits = {}
    for path in glob.glob(os.path.join(database, "segbits_*.db")):
        for line in open(path):
            words = line.split()
            if words:
                segbits[words[0]] = [(w.startswith("!"), w.lstrip("!")) for w in words[1:]]
    defaults = {}
    for path in glob.glob(os.path.join(database, "defaults_*.db")):
        name = os.path.basename(path)[len("defaults_"):-len(".db")]
        defaults[name] = [line.strip() for line in open(path) if line.strip()]
    functions = {}
    for path in glob.glob(os.path.join(database, "functions_*.json")):
        read = json.load(open(path))
        functions[read["tile_type"]] = read["functions"]
    return grid, frames, segbits, defaults, functions


def evaluate(function, settings):
    """A rule #38 function's bit for a tile's settings; None where it met
    no such combination."""
    if "constant" in function:
        return function["constant"] == 1
    if "table" in function:
        key = [settings.get(name) for name in function["table"]]
        for values, bit in function["entries"]:
            if values == key:
                return bit == 1
        return None
    selected = settings.get(function["case"])
    for value, inner in function["cases"]:
        if value == selected:
            return evaluate(inner, settings)
    return None


class Image:
    def __init__(self, frames):
        self.frame_bits = frames["frame_bits"]
        self.addresses = [first + k for first, count in frames["runs"] for k in range(count)]
        self.index = {address: at for at, address in enumerate(self.addresses)}
        self.bits = bytearray(len(self.addresses) * self.frame_bits // 8)
        for bit in frames["ones"]:
            self.set(bit, True)
        check = frames.get("check") or {"bits": [], "columns": []}
        self.check_bits = check["bits"]
        self.columns = dict(check["columns"])

    def set(self, bit, value):
        if value:
            self.bits[bit // 8] |= 1 << (bit % 8)
        else:
            self.bits[bit // 8] &= ~(1 << (bit % 8)) & 0xFF

    def place(self, tile, cell):
        """A tile's cell `<row>_<bit>`: its bit of the image."""
        row, bit = (int(n) for n in cell.split("_"))
        for share in sorted(tile["bits"].values(), key=lambda share: int(share["baseaddr"], 16)):
            if row < share["frames"]:
                frame = self.index[int(share["baseaddr"], 16) + row]
                return frame * self.frame_bits + share["offset_bit"] + bit
            row -= share["frames"]
        raise KeyError("%s has no row %s" % (tile["type"], cell))

    def make_checks(self):
        """Each frame's check, from the bits it holds."""
        if not self.check_bits:
            return
        frame_bytes = self.frame_bits // 8
        for at in range(len(self.addresses)):
            frame = int.from_bytes(self.bits[at * frame_bytes:(at + 1) * frame_bytes], "little")
            for bit in self.check_bits:
                frame &= ~(1 << bit)
            value = 0
            while frame:
                low = frame & -frame
                value ^= self.columns.get(low.bit_length() - 1, 0)
                frame ^= low
            for k, bit in enumerate(self.check_bits):
                self.set(at * self.frame_bits + bit, value >> k & 1)

    def words(self):
        """The frames' words, two empty frames after each row of each block
        type (the address's bits 18 up)."""
        out = []
        frame_bytes = self.frame_bits // 8
        for at, address in enumerate(self.addresses):
            frame = self.bits[at * frame_bytes:(at + 1) * frame_bytes]
            out += [int.from_bytes(frame[w * 4:(w + 1) * 4], "little") for w in range(FRAME_WORDS)]
            following = self.addresses[at + 1] if at + 1 < len(self.addresses) else None
            if following is None or (following >> 18) != (address >> 18):
                out += [0] * (2 * FRAME_WORDS)
        return out


def assemble(database, fabric, part, fasm):
    grid, frames, segbits, defaults, functions = load(database, fabric, part)
    img = Image(frames)
    # A tile whose type has functions: its sites' settings, named as rule #38
    # names them (`<slot>/<element>/<attribute>`), and the sites by slot.
    stated = {}
    site_name = re.compile(r"^(\w+)_X(\d+)\.([^.]+)\.([^.\[]+)(?:\.(.+))?$")
    for tile in grid.values():
        if tile["bits"]:
            for cell in defaults.get(tile["type"].lower(), []):
                img.set(img.place(tile, cell), True)
    unknown = []
    vector = re.compile(r"^(\S+)\[(\d+):(\d+)\]\s*=\s*(\d+)'b([01]+)$")
    for line in open(fasm):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        match = vector.match(line)
        name = match.group(1) if match else line.split()[0]
        tile_name, rest = name.split(".", 1)
        tile = grid[tile_name]
        kind = tile["type"]
        settled = site_name.match(rest if not match else rest + ".v") if kind in functions else None
        if settled:
            site, slot, element, attribute = settled.group(1), int(settled.group(2)), settled.group(3), settled.group(4)
            into = stated.setdefault(tile_name, ({}, {}))
            into[1][slot] = site
            if match:
                high, low, bits = int(match.group(2)), int(match.group(3)), match.group(5)
                if high == low == 0:
                    into[0]["%d/%s/%s" % (slot, element, attribute)] = "1'b" + bits
                if high - low + 1 <= 64:
                    for k in range(low, high + 1):
                        into[0]["%d/%s/%s[%d]" % (slot, element, attribute, k)] = bits[len(bits) - 1 - (k - low)]
            elif settled.group(5) is not None:
                into[0]["%d/%s/%s" % (slot, element, attribute)] = settled.group(5)
        if match:
            high, low, bits = int(match.group(2)), int(match.group(3)), match.group(5)
            for k in range(low, high + 1):
                value = bits[len(bits) - 1 - (k - low)] == "1"
                key = "%s.%s[%d]" % (kind, rest, k)
                if key not in segbits:
                    if not settled:
                        unknown.append(key)
                    continue
                for complement, cell in segbits[key]:
                    img.set(img.place(tile, cell), value != complement)
            continue
        key = "%s.%s" % (kind, rest)
        if key not in segbits:
            if not settled:
                unknown.append(key)
            continue
        for clear, cell in segbits[key]:
            img.set(img.place(tile, cell), not clear)
    # Each function's bit, last: what segbits' codes per value cannot state.
    for tile_name, (settings, units) in stated.items():
        tile = grid[tile_name]
        occupied = "+".join("%d:%s" % (slot, units[slot]) for slot in sorted(units))
        for function in functions[tile["type"]]:
            occupancies = dict((occupancy, f) for occupancy, f in function["occupancies"])
            first = function["occupancies"][0][0] if function["occupancies"] else ""
            if first.startswith("@"):
                slot = int(first[1:].split(":", 1)[0])
                key = "@%d:%s" % (slot, units.get(slot, ""))
            else:
                key = occupied
            inner = occupancies.get(key)
            if inner is None:
                unknown.append("%s: no function for %s" % (tile["type"], key))
                continue
            bit = evaluate(inner, settings)
            if bit is None:
                unknown.append("%s: a combination of settings never met (%d_%d)" % (tile["type"], function["row"], function["bit"]))
                continue
            img.set(img.place(tile, "%d_%d" % (function["row"], function["bit"])), bit)
    img.make_checks()
    return img, unknown


if __name__ == "__main__":
    database, fabric, part, idcode, fasm, out = sys.argv[1:7]
    img, unknown = assemble(database, fabric, part, fasm)
    open(out, "wb").write(image(img.words(), int(idcode, 0), part))
    kinds = {}
    for key in unknown:
        kinds[key] = kinds.get(key, 0) + 1
    print("%d features not in the database (%d distinct)" % (len(unknown), len(kinds)), file=sys.stderr)
    for key in sorted(kinds)[:60]:
        print("  %s x%d" % (key, kinds[key]), file=sys.stderr)
