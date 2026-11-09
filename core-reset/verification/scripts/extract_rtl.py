#!/usr/bin/env python3
"""Cut the firtool-generated RTL into one file per module for the formal equivalence check.

usage: extract_rtl.py <elab_outdir> [rtl_dir]      (rtl_dir default: ../rtl relative to this script)

Writes into rtl_dir:
  CoreResetCtrl_keep.sv   CoreResetCtrl (keepL1 = true),   module renamed CoreResetCtrl_keep
  CoreResetCtrl_sweep.sv  CoreResetCtrl (keepL1 = false),  module renamed CoreResetCtrl_sweep
  TLQuiesceGate.sv, TLQuiesceGate_1.sv, TLResetIsolation.sv  (cut out of gates/CoreResetGatesHarness.sv)
  TLMonitor_stubs.sv      port-only stubs, only if the cut modules instantiate a TLMonitor*
Every file starts with the firtool macro preamble (everything before the first `module`).
"""
import os
import re
import sys

MOD_RE = re.compile(r'^module\s+(\w+)\s*[(#]', re.M)


def read(path):
    with open(path) as f:
        return f.read()


def split_modules(text):
    """Return (preamble, {name: module_text}); a module runs from `module` to the next `endmodule`."""
    starts = list(MOD_RE.finditer(text))
    if not starts:
        raise SystemExit("no module found")
    preamble = text[:starts[0].start()]
    mods = {}
    for m in starts:
        end = text.index("endmodule", m.start()) + len("endmodule")
        mods[m.group(1)] = text[m.start():end] + "\n"
    return preamble, mods


def write(path, text):
    with open(path, "w") as f:
        f.write(text)
    print("wrote", path)


def find_def(name, search_dirs, own_mods):
    """Header (up to the closing `);`) of module `name`, from the cut harness or any .sv below the elab dir."""
    if name in own_mods:
        return own_mods[name]
    for d in search_dirs:
        for root, _, files in os.walk(d):
            for fn in files:
                if fn.endswith((".sv", ".v")):
                    t = read(os.path.join(root, fn))
                    m = re.search(r'^module\s+%s\s*\(' % re.escape(name), t, re.M)
                    if m:
                        return t[m.start():t.index("endmodule", m.start())]
    return None


def make_stub(name, body):
    """Port-only stub: header copied, no body, outputs tied to zero."""
    hdr = body[:body.index(");") + 2]
    outs = re.findall(r'^\s*output\s+(?:\[[^\]]*\]\s*)?(\w+)', hdr, re.M)
    assigns = "".join("  assign %s = '0;\n" % o for o in outs)
    return hdr + "\n" + assigns + "endmodule\n"


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    elab = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    rtl = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "..", "rtl")
    os.makedirs(rtl, exist_ok=True)

    for cfg, sub in (("keep", "ctrl_keep"), ("sweep", "ctrl_sweep")):
        pre, mods = split_modules(read(os.path.join(elab, sub, "CoreResetCtrl.sv")))
        body = re.sub(r'^module\s+CoreResetCtrl\b', "module CoreResetCtrl_" + cfg, mods["CoreResetCtrl"], count=1, flags=re.M)
        write(os.path.join(rtl, "CoreResetCtrl_%s.sv" % cfg), pre + body)

    pre, mods = split_modules(read(os.path.join(elab, "gates", "CoreResetGatesHarness.sv")))
    stubs = {}
    for name in ("TLQuiesceGate", "TLQuiesceGate_1", "TLResetIsolation"):
        if name not in mods:
            raise SystemExit("module %s not found in the harness file" % name)
        write(os.path.join(rtl, name + ".sv"), pre + mods[name])
        for inst in set(re.findall(r'^\s*(TLMonitor\w*)\s+', mods[name], re.M)):
            stubs[inst] = None
    if stubs:
        out = pre
        for inst in sorted(stubs):
            d = find_def(inst, [elab], mods)
            if d is None:
                print("warning: definition of %s not found, stub has no ports" % inst, file=sys.stderr)
                out += "module %s();\nendmodule\n" % inst
            else:
                out += make_stub(inst, d)
        write(os.path.join(rtl, "TLMonitor_stubs.sv"), out)
    else:
        stale = os.path.join(rtl, "TLMonitor_stubs.sv")
        if os.path.exists(stale):
            os.remove(stale)
        print("no TLMonitor instances in the cut modules: no stubs")


if __name__ == "__main__":
    main()
