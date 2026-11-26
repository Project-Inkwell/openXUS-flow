"""The FASM of a Vivado build, from what it recorded of its design
(`routes.txt`, `sites.txt`: the starter flow's and the cells harness's
`write_routes` and `write_sites`), in the names the database's segbits use: each
pip a net takes `<TILE>.<to>.<from>`; each configuration attribute of each
element of each used site `<TILE>.<SITE TYPE>_X<place>.<BEL>.<ATTRIBUTE>.<VALUE>`
(a space in a value `_`); each site pip `<...>.<BEL>.<PIN>`; each LUT's
contents `<...>.<BEL>.EQN[63:0]` from its equation. With the database's
fabric, each pip into a node a net takes, in a tile the net does not drive
it from, `<TILE>.<to>.<from>.TRISTATED` (what drives it left undriving,
where the database codes that).

    vivado2fasm.py <routes.txt> <sites.txt> [<database> <fabric>] > design.fasm
"""
import glob
import json
import os
import sys

from equation import truth_table


def pips(routes):
    # A pip both ways (`A<<->>B`) is listed with its nodes in the pip's own
    # order, not the net's: the way the net took it is from the node another
    # of the net's pips drives -- the uphill one -- to the other.
    nets = []
    for line in open(routes):
        fields = line.rstrip("\n").split("\t")
        if fields[0] == "net":
            nets.append([])
        elif fields[0] == "pip" and nets:
            nets[-1].append(fields)
    for net in nets:
        driven = {fields[4] for fields in net if "<<->>" not in fields[1]}
        for fields in net:
            tile, name = fields[1].split("/", 1)
            _, arc = name.split(".", 1)
            if "<<->>" in arc:
                a, b = arc.split("<<->>")
                node_a, node_b = fields[3], fields[4]
                # From b where b's node is the one driven, else from a.
                yield (tile, a, b) if node_b in driven and node_a not in driven else (tile, b, a)
            else:
                a, b = arc.replace("->>", "->").split("->")
                yield tile, b, a


def undriven(routes, database, fabric):
    """Each pip into a wire of a node a net takes, in a tile the net does
    not drive that wire in, whose driver the database can leave undriving."""
    grid = json.load(open(os.path.join(database, fabric, "tilegrid.json")))
    tristated = set()
    for path in glob.glob(os.path.join(database, "segbits_*.db")):
        for line in open(path):
            words = line.split()
            if words and words[0].endswith(".TRISTATED"):
                tristated.add(words[0])
    into = {}
    for name in {key.split(".", 1)[0] for key in tristated}:
        for key in tristated:
            if key.startswith(name + "."):
                _, to, frm, _ = key.split(".")
                into.setdefault((name, to), []).append(frm)
    driven = set()
    for tile, to, _ in pips(routes):
        driven.add((tile, to))
    for line in open(routes):
        fields = line.rstrip("\n").split("\t")
        if fields[0] != "node" or len(fields) < 4:
            continue
        for wire in fields[3].split(","):
            tile, name = wire.split("/", 1)
            if (tile, name) in driven or tile not in grid:
                continue
            kind = grid[tile]["type"]
            for frm in into.get((kind, name), []):
                yield tile, name, frm


def sites(path):
    site = None
    for line in open(path):
        fields = line.rstrip("\n").split("\t")
        if fields[0] == "site":
            site = "%s.%s_X%s" % (fields[3], fields[2], fields[4]) if len(fields) >= 5 else None
        elif site and fields[0] == "config":
            bel, attribute, value = fields[1], fields[2], fields[3]
            if attribute == "EQN":
                table = truth_table(value, 5 if bel.endswith("5LUT") else 6)
                bits = "".join("1" if v else "0" for v in reversed(table))
                yield "%s.%s.EQN[%d:0] = %d'b%s" % (site, bel, len(table) - 1, len(table), bits)
            else:
                yield "%s.%s.%s.%s" % (site, bel, attribute, value.replace(" ", "_"))
        elif site and fields[0] == "pip":
            bel, pin = fields[1].split(":", 1)
            yield "%s.%s.%s" % (site, bel, pin)


if __name__ == "__main__":
    for tile, to, frm in pips(sys.argv[1]):
        print("%s.%s.%s" % (tile, to, frm))
    for feature in sites(sys.argv[2]):
        print(feature)
    if len(sys.argv) > 4:
        for tile, to, frm in undriven(sys.argv[1], sys.argv[3], sys.argv[4]):
            print("%s.%s.%s.TRISTATED" % (tile, to, frm))
