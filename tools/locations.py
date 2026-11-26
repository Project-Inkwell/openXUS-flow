"""A logic location file (Vivado's `.ll`) for a design nextpnr placed: each
register's place in a readback of the image, from the device
database. A register's state reads back at the cell its initial value is
written to: the cell its element's `FFINIT.INIT0` (or `INIT1`) sets, a
frame `<row>` of its tile's share and a bit `<bit>` from the share's
first. The state reads back as the cell holds it -- for an UltraScale+
slice, the complement of the register's value. Each line's first number is
the bit's place in a readback of the whole image, as Vivado's are: its
frame's place in address order, two empty frames after each row of each
block type, times the frame's bits, plus the bit.

    locations.py <database> <fabric> routed.json [<part>] > design.ll
"""
import glob
import json
import os
import sys


def init_cells(database):
    """By `<TILE TYPE>.<SITE TYPE>_X<site>.<BEL>`: the cell its initial value is at."""
    cells = {}
    for path in glob.glob(os.path.join(database, "segbits_*.db")):
        for line in open(path):
            words = line.split()
            if len(words) == 2 and (words[0].endswith(".FFINIT.INIT0") or words[0].endswith(".FFINIT.INIT1")):
                cells[words[0].rsplit(".FFINIT.", 1)[0]] = words[1].lstrip("!")
    return cells


def frame_places(database, part):
    """By frame address: the frame's place in a readback of the image."""
    frames = json.load(open(os.path.join(database, part, "frames.json")))
    addresses = [first + k for first, count in frames["runs"] for k in range(count)]
    places, at = {}, 0
    for i, address in enumerate(addresses):
        places[address] = at
        at += 1
        if i + 1 == len(addresses) or (addresses[i + 1] >> 18) != (address >> 18):
            at += 2
    return places, frames["frame_bits"]


def main(database, fabric, routed, part="xcku3p-ffvb676-2-e"):
    grid = json.load(open(os.path.join(database, fabric, "tilegrid.json")))
    places, frame_bits = frame_places(database, part)
    tile_of_site = {site: (name, kind) for name, tile in grid.items() for site, kind in tile["sites"].items()}
    cells = init_cells(database)
    design = json.load(open(routed))["modules"]["top"]
    names = {}
    for name, net in design["netnames"].items():
        for bit in net["bits"]:
            names.setdefault(bit, name if len(net["bits"]) == 1 else "%s[%d]" % (name, net["bits"].index(bit)))
    print("Revision 4")
    print("; written by locations.py from nextpnr's placement and the device database")
    for name, cell in sorted(design["cells"].items()):
        if cell["type"] != "SLICE_FFX":
            continue
        site, bel = cell["attributes"]["NEXTPNR_BEL"].split("/")
        tile_name, site_type = tile_of_site[site]
        tile = grid[tile_name]
        sites = [s for s in tile["sites"]]
        # The site's place among its tile's sites, as the database names it.
        key = "%s.%s_X%d.%s" % (tile["type"], site_type, sites.index(site), bel)
        if key not in cells:
            print("; %s: no initial-value cell for %s" % (name, key))
            continue
        row, bit = (int(n) for n in cells[key].split("_"))
        share = tile["bits"]["0"]
        frame = int(share["baseaddr"], 16) + row
        offset = share["offset_bit"] + bit
        net = names.get(cell["connections"]["Q"][0], "?")
        print("Bit %d 0x%08x %d SLR0 0 Block=%s Latch=%s Net=%s" % (places[frame] * frame_bits + offset, frame, offset, site, bel, net))


if __name__ == "__main__":
    main(*sys.argv[1:5])
