#!/usr/bin/env python3
"""Structural checks of a full XSNoCTop elaboration (TESTPLAN 6.4, E1..E3).

usage: elab_struct.py <rtl_dir> <off|full|keep>
  E1 (full, keep): the top has the ports debug_reset, core_reset_req, core_reset_busy, core_in_reset; XSTile instantiates
     CoreResetCtrl, TLResetIsolation and 5 TLQuiesceGate; a DCacheQuiesceUnit module exists
  E2 keep: metaArray, errorArray and tagArray of the DCache get its keepReset as reset, bankedDataArray does not;
     full: no keepReset anywhere
  E3 (off, EnableCoreReset = false): no occurrence of CoreReset|Quiesce|keepReset|core_reset_req|core_in_reset at all
Prints `structural <cfg>: OK` or `structural <cfg>: <violations>`; exit code 0 / 1.
"""
import os
import re
import sys

MODDEF = re.compile(r"^\s*module\s+(\w+)\b", re.M)


def sources(rtl):
    out = {}
    for d, _, fs in os.walk(rtl):
        for f in sorted(fs):
            if f.endswith((".sv", ".v")):
                p = os.path.join(d, f)
                out[p] = open(p, errors="replace").read()
    return out


def modules(src):
    mods = {}
    for txt in src.values():
        for m in re.finditer(r"^\s*module\s+(\w+)\b(.*?)^\s*endmodule\b", txt, re.S | re.M):
            mods.setdefault(m.group(1), m.group(0))
    return mods


def inst_reset(body, inst_rx):
    """{instance: expression of its .reset} for instances whose name matches inst_rx."""
    res = {}
    for m in re.finditer(r"^\s*\w+\s+(" + inst_rx + r")\s*\((.*?)\);", body, re.S | re.M):
        r = re.search(r"\.reset\s*\(([^()]*)\)", m.group(2))
        res[m.group(1)] = r.group(1).strip() if r else None
    return res


def main():
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    rtl, cfg = sys.argv[1:]
    src = sources(rtl)
    if not src:
        print("structural %s: no RTL in %s" % (cfg, rtl)); sys.exit(1)
    bad = []
    alltxt = "\n".join(src.values())
    if cfg == "off":
        hits = sorted({m.group(0) for m in re.finditer(r"CoreReset|Quiesce|keepReset|core_reset_req|core_in_reset", alltxt)})
        if hits:
            files = sorted(os.path.relpath(p, rtl) for p, t in src.items()
                           if re.search(r"CoreReset|Quiesce|keepReset|core_reset_req|core_in_reset", t))
            bad.append("E3: %s in %s" % (", ".join(hits), ", ".join(files[:10])))
    else:
        mods = modules(src)
        top = mods.get("XSTop") or mods.get("XSNoCTop")
        if top is None:
            bad.append("E1: no top module XSTop / XSNoCTop")
        else:
            head = top[:top.find(");")]
            for p in ("debug_reset", "core_reset_req", "core_reset_busy", "core_in_reset"):
                if not re.search(r"\b\w*%s\b" % p, head):
                    bad.append("E1: top lacks a port *%s" % p)
        t = mods.get("XSTile")
        if t is None:
            bad.append("E1: no module XSTile")
        else:
            n = lambda rx: len(re.findall(r"^\s*" + rx + r"\s+\w+\s*\(", t, re.M))
            if n(r"CoreResetCtrl\w*") != 1:
                bad.append("E1: XSTile has %d CoreResetCtrl instances" % n(r"CoreResetCtrl\w*"))
            if n(r"TLResetIsolation\w*") < 1:
                bad.append("E1: XSTile has no TLResetIsolation")
            if n(r"TLQuiesceGate(_\d+)?") != 5:
                bad.append("E1: XSTile has %d TLQuiesceGate instances, expected 5" % n(r"TLQuiesceGate(_\d+)?"))
        if not any(re.match(r"DCacheQuiesceUnit\w*$", m) for m in mods):
            bad.append("E1: no DCacheQuiesceUnit module")
        # E2: the module that holds the arrays of the DCache (it instantiates DCacheQuiesceUnit)
        dc = [b for name, b in mods.items() if re.search(r"^\s*DCacheQuiesceUnit\w*\s+\w+\s*\(", b, re.M)]
        if len(dc) != 1:
            bad.append("E2: %d modules instantiate DCacheQuiesceUnit (1 expected)" % len(dc))
        else:
            r = inst_reset(dc[0], r"metaArray\w*|errorArray\w*|tagArray\w*|bankedDataArray\w*")
            for a in ("metaArray", "errorArray", "tagArray", "bankedDataArray"):
                ins = [k for k in r if k.startswith(a)]
                if not ins:
                    bad.append("E2: no instance %s in the DCache" % a); continue
                for k in ins:
                    keep_r = r[k] is not None and "keepReset" in r[k]
                    want = cfg == "keep" and a != "bankedDataArray"
                    if keep_r != want:
                        bad.append("E2: %s.reset = %s (%s expected)" % (k, r[k], "keepReset" if want else "the DCache reset"))
            if cfg == "full" and "keepReset" in alltxt:
                bad.append("E2: keepReset present in FULL")
    print("structural %s: %s" % (cfg, "OK" if not bad else "; ".join(bad)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
