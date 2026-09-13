#!/usr/bin/env python3
"""Read the logic of Sim2600's TIA netlist around a wire.

Copyright 2026 Leonardo Roman da Rosa
SPDX-License-Identifier: CERN-OHL-S-2.0

The netlist names only the pads, the register write strobes and a handful of
buses; every other wire is N<index>. It is still perfectly readable, because
the TIA is built from very few kinds of structure:

- a wire with a pull-up and transistors to ground is a NOR of their gates
  (two transistors in series make an AND term, printed a*b);
- a wire with no pull-up that is reached through a transistor is a dynamic
  storage node, loaded from the far side while that transistor's gate -- a
  clock -- is high;
- two NORs feeding each other are a latch.

Subcommands:

    python sim/netlist.py node  RESP0_metal       what a wire drives and is driven by
    python sim/netlist.py tree  N2203 --depth 4   the logic behind a wire
    python sim/netlist.py loads N1703             every storage node a clock loads
    python sim/netlist.py waves --probe p.npy --trace sim/traces/audio.trace \\
                                --line 60 N1703 N2591
                                                  where in a scanline wires change

`waves` reads a recording made with probe_die.py. All of them need
--sim2600 (default ./Sim2600) to find chips/net_TIA.pkl.
"""

import argparse
import collections
import os
import pickle
import re
import sys


class Netlist(object):
    def __init__(self, sim2600):
        path = os.path.join(sim2600, "chips", "net_TIA.pkl")
        with open(path, "rb") as f:
            d = pickle.load(f, encoding="latin1")
        self.names = d["WIRE_NAMES"]
        self.pulled = d["WIRE_PULLED"]
        no = d["NO_WIRE"]
        self.s1, self.s2, self.g = d["FET_SIDE1_WIRE_INDS"], d["FET_SIDE2_WIRE_INDS"], d["FET_GATE_INDS"]
        self.gates_of = collections.defaultdict(list)
        self.chan_of = collections.defaultdict(list)
        for t in range(d["NUM_FETS"]):
            if self.s1[t] == no:
                continue
            self.gates_of[self.g[t]].append(t)
            self.chan_of[self.s1[t]].append(t)
            self.chan_of[self.s2[t]].append(t)
        self.index = {n: i for i, n in enumerate(self.names) if n}
        self.vss, self.vcc = self.index["VSS"], self.index["VCC"]

    def wire(self, name):
        if name in self.index:
            return self.index[name]
        if re.fullmatch(r"N?\d+", name):
            return int(name.lstrip("N"))
        sys.exit("no wire called %s" % name)

    def nm(self, w):
        return self.names[w] or "N%d" % w

    def other(self, t, w):
        return self.s2[t] if self.s1[t] == w else self.s1[t]

    def is_internal(self, w):
        return re.fullmatch(r"N\d+", self.names[w] or "") is not None

    def nor_terms(self, w):
        terms = []
        for t in self.chan_of[w]:
            o = self.other(t, w)
            if o == self.vss:
                terms.append([self.g[t]])
            elif o != self.vcc and self.pulled[o] == 0:
                for t2 in self.chan_of[o]:
                    if t2 != t and self.other(t2, o) == self.vss:
                        terms.append([self.g[t], self.g[t2]])
        return terms


def cmd_node(net, args):
    w = net.wire(args.wire)
    print("%s  pulled=%d  gates %d transistors, channel of %d"
          % (net.nm(w), net.pulled[w], len(net.gates_of[w]), len(net.chan_of[w])))
    print("  gates:   " + ", ".join("t%d[%s-%s]" % (t, net.nm(net.s1[t]), net.nm(net.s2[t]))
                                    for t in net.gates_of[w]))
    print("  channel: " + ", ".join("t%d(gate %s)->%s" % (t, net.nm(net.g[t]), net.nm(net.other(t, w)))
                                    for t in net.chan_of[w]))


def cmd_tree(net, args):
    seen = set()

    def walk(w, depth, indent):
        pad = "  " * indent
        again = "   (above)" if w in seen else ""
        if net.pulled[w] == 0 and net.is_internal(w):
            loads = [(net.g[t], net.other(t, w)) for t in net.chan_of[w]
                     if net.other(t, w) not in (net.vss, net.vcc)]
            print(pad + "%s = STORE(%s)%s" % (net.nm(w), ", ".join(
                "%s<-%s" % (net.nm(c), net.nm(s)) for c, s in loads), again))
            nexts = [s for _, s in loads]
        else:
            terms = net.nor_terms(w)
            print(pad + "%s = NOR(%s)%s" % (net.nm(w), ", ".join(
                "*".join(net.nm(x) for x in term) for term in terms), again))
            nexts = [x for term in terms for x in term]
        if w in seen or depth == 0:
            return
        seen.add(w)
        for x in nexts:
            if net.is_internal(x):
                walk(x, depth - 1, indent + 1)

    walk(net.wire(args.wire), args.depth, 0)


def cmd_loads(net, args):
    ck = net.wire(args.wire)
    print("%s loads:" % net.nm(ck))
    for t in net.gates_of[ck]:
        a, b = net.s1[t], net.s2[t]
        if {a, b} & {net.vss, net.vcc}:
            continue
        store, src = (a, b) if net.pulled[a] == 0 else (b, a)
        print("  %-6s <- %-6s" % (net.nm(store), net.nm(src)))


def cmd_waves(net, args):
    import numpy as np
    bits = np.load(args.probe, mmap_mode="r")
    rows = [l.split() for l in open(args.trace) if not l.startswith("#")]
    starts = [i for i in range(1, len(rows)) if rows[i][13] == "1" and rows[i - 1][13] == "0"]
    a, b = starts[args.line], starts[args.line + 1]
    print("scanline %d: records %d..%d" % (args.line, a, b))
    for name in args.wires:
        w = net.wire(name)
        v = [(int(bits[k, w >> 3]) >> (7 - (w & 7))) & 1 for k in range(a, b + 1)]
        changes = ["%d%s" % (k, "+" if v[k] else "-") for k in range(1, len(v)) if v[k] != v[k - 1]]
        print("  %-8s starts %d, changes at %s" % (net.nm(w), v[0], " ".join(changes) or "-"))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim2600", default="Sim2600")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("node"); p.add_argument("wire")
    p = sub.add_parser("tree"); p.add_argument("wire"); p.add_argument("--depth", type=int, default=3)
    p = sub.add_parser("loads"); p.add_argument("wire")
    p = sub.add_parser("waves"); p.add_argument("wires", nargs="+")
    p.add_argument("--probe", required=True); p.add_argument("--trace", required=True)
    p.add_argument("--line", type=int, required=True)
    args = ap.parse_args()

    net = Netlist(args.sim2600)
    {"node": cmd_node, "tree": cmd_tree, "loads": cmd_loads, "waves": cmd_waves}[args.cmd](net, args)


if __name__ == "__main__":
    main()
