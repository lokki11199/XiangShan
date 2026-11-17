#!/usr/bin/env python3
"""Mutants of the tile isolation test (TESTPLAN 6.3): text patches of the generated XSTile.sv.

usage: tile_mutants.py <MUTANT> <XSTile.sv> <out.sv>
  TM1 PF_MASK_LATE          the prefetch hint to L2 is not masked while busy: `~busy` removed from addr_valid (T3)
  TM2 NO_SIDEBAND_ISO       cpu_halt of the core reaches L2Top while isolated: the isolate term removed (T1 / T2)
  TM3 KEEP_RESET_WITH_CORE  KEEP: l1_keep_reset of the core gets the reset of the core (T6)
Best effort: a patch must apply exactly once. Otherwise the script prints `SKIPPED (<reason>)` and exits 3; the run
script reports it as a hole (the patch has to be adapted to the RTL, the check is not changed for the patch).
Exit 0 and `PATCHED <what>` when the mutant was written.
"""
import re
import sys


def skipped(why):
    print("SKIPPED (%s)" % why)
    sys.exit(3)


def module_span(txt):
    m = re.search(r"^\s*module\s+XSTile\b.*?^\s*endmodule\b", txt, re.S | re.M)
    if not m:
        skipped("no module XSTile in the file")
    return m.start(), m.end()


# a negated register output of the controller, as firtool names it: ~_coreResetCtrl_io_busy (or ~coreResetCtrl_io_busy)
def neg(port):
    return r"~\s*_?\w*[Cc]oreResetCtrl\w*_io_%s\b" % port


def tm1(body):
    # the line that drives the addr_valid of the prefetch bridge and contains ~busy
    lines = body.split("\n")
    hits = [i for i, ln in enumerate(lines) if "addr_valid" in ln and re.search(neg("busy"), ln)]
    if len(hits) != 1:
        skipped("TM1: %d lines with addr_valid and ~busy (exactly 1 needed)" % len(hits))
    i = hits[0]
    lines[i] = re.sub(neg("busy"), "1'h1", lines[i])
    return "\n".join(lines), "addr_valid without ~busy: " + lines[i].strip()


def tm2(body):
    lines = body.split("\n")
    hits = [i for i, ln in enumerate(lines) if "cpu_halt" in ln and re.search(neg("isolate"), ln)]
    if len(hits) != 1:
        skipped("TM2: %d lines with cpu_halt and ~isolate (exactly 1 needed)" % len(hits))
    i = hits[0]
    new = re.sub(neg("isolate") + r"\s*&\s*", "", lines[i])
    new = re.sub(r"\s*&\s*" + neg("isolate"), "", new)
    if new == lines[i] or re.search(neg("isolate"), new):
        skipped("TM2: the isolate term of cpu_halt is not a plain AND: " + lines[i].strip())
    lines[i] = new
    return "\n".join(lines), "cpu_halt without isolate: " + new.strip()


def tm3(body):
    m = re.search(r"^\s*XSCore\s+\w+\s*\((.*?)\);", body, re.S | re.M)
    if not m:
        skipped("TM3: no XSCore instance in XSTile")
    inst = m.group(1)
    rk = re.findall(r"\.io_l1_keep_reset\s*\(([^()]*)\)", inst)
    rc = re.findall(r"\.reset\s*\(([^()]*)\)", inst)
    if len(rk) != 1 or len(rc) != 1:
        skipped("TM3: XSCore instance has %d io_l1_keep_reset and %d reset connections (1 and 1 needed)" % (len(rk), len(rc)))
    if rk[0].strip() == rc[0].strip():
        skipped("TM3: l1_keep_reset already connected to the core reset")
    new_inst = re.sub(r"(\.io_l1_keep_reset\s*\()[^()]*(\))", lambda x: x.group(1) + rc[0].strip() + x.group(2), inst)
    return body[:m.start(1)] + new_inst + body[m.end(1):], "l1_keep_reset <- " + rc[0].strip()


def main():
    if len(sys.argv) != 4:
        print(__doc__); sys.exit(2)
    mut, src, dst = sys.argv[1:]
    txt = open(src).read()
    a, b = module_span(txt)
    f = {"TM1": tm1, "TM2": tm2, "TM3": tm3}.get(mut)
    if f is None:
        print("unknown mutant " + mut); sys.exit(2)
    body, what = f(txt[a:b])
    open(dst, "w").write(txt[:a] + body + txt[b:])
    print("PATCHED " + what)


if __name__ == "__main__":
    main()
