#!/usr/bin/env python3
"""Probes of the DCache arrays and of the gate for the RTL test (TESTPLAN section 5.5, K5, K6), built from the RTL.

usage: mem_probes.py <rtl_dir> <cfg> <out.svh>       cfg: full | keep (only in the header of the file)

Names of the instances in the RTL come from the elaboration (firtool), so the paths are found by walking the
instance tree from CoreResetDCacheHarness, not typed by hand. Written into <out.svh> (included into the stand):
  probe_bnd   [N_BND-1:0]      access enables on the boundaries of the modules metaArray, errorArray, tagArray,
                               bankedDataArray: every io_{read,readline,write,write_dup}*_valid input
                               (what the freeze clamps, DESIGN 4.3)
  probe_mem_tag_init           per tag memory enable: its TagSRAMBank is running its own initialisation (rst_cnt)
  probe_mem_tag, probe_mem_data   the enables of the memory instances (*_ext: R<n>_en, W<n>_en, RW<n>_en) below
                               tagArray, resp. bankedDataArray: what the SRAMs really see (CE, and the exception
                               R6 (a) of the design: wen_reg)
  probe_core_side              outputs of the gate towards the core (A, C, E ready, B and D valid), 0 while isolated
Exit code 2 when no probe of the memory of tags or of data is found (an empty check is a failed check).
"""
import os
import re
import sys

TOP = "CoreResetDCacheHarness"
MOD_HDR = re.compile(r"^module\s+(\w+)\s*(?:#\(.*?\)\s*)?\((.*?)\);", re.S | re.M)
PORT = re.compile(r"(input|output|inout)\s+(?:\[[^\]]*\]\s*)?(\w+)")
BND_RE = re.compile(r"^io_(read|readline|write|write_dup)(_\d+)*_valid$")
MEM_EN_RE = re.compile(r"^(R|W|RW)\d+_en$")
GATE_CORE_RE = re.compile(r"^auto_.*in_(a_ready|c_ready|e_ready|b_valid|d_valid)$")


def load(rtl_dir):
    """{module: (ports {name: dir}, body text)} of every module in the .sv / .v files below rtl_dir."""
    mods = {}
    for root, _, files in os.walk(rtl_dir):
        for fn in sorted(files):
            if not fn.endswith((".sv", ".v")):
                continue
            t = open(os.path.join(root, fn), errors="replace").read()
            t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
            t = re.sub(r"//[^\n]*", "", t)
            heads = list(MOD_HDR.finditer(t))
            for k, m in enumerate(heads):
                end = t.find("endmodule", m.end())
                body = t[m.end():end if end >= 0 else len(t)]
                ports = {pm.group(2): pm.group(1) for pm in PORT.finditer(m.group(2))}
                mods[m.group(1)] = (ports, body)
    return mods


def instances(mods, mod):
    """[(module, instance name)] instantiated in `mod`."""
    res = []
    for m in re.finditer(r"^\s*(\w+)\s+(?:#\(.*?\)\s*)?(\w+)\s*\(", mods[mod][1], re.M):
        if m.group(1) in mods and m.group(1) != mod:
            res.append((m.group(1), m.group(2)))
    return res


def find(mods, name_re):
    """[(path, module)] of every instance whose name matches name_re, walking down from TOP."""
    found = []

    def walk(mod, path, depth):
        if depth > 12:
            return
        for cm, inst in instances(mods, mod):
            p = path + [inst]
            if re.fullmatch(name_re, inst):
                found.append((p, cm))
            else:
                walk(cm, p, depth + 1)

    walk(TOP, [], 0)
    return found


def mem_enables(mods, mod, path, bank=None):
    """[('dut.a.b.arr_ext.R0_en', bank)] of every memory-like instance at or below (path, mod). bank is the path of
    the enclosing TagSRAMBank whose reset counter (rst_cnt) can drive the memory by itself, or None."""
    res = []
    for cm, inst in instances(mods, mod):
        p = path + [inst]
        b = bank
        if cm.startswith("TagSRAMBank") and re.search(r"\breg\s+(\[[^\]]*\]\s*)?rst_cnt\b", mods[cm][1]):
            b = ".".join(["dut"] + p)
        en = [n for n, d in mods[cm][0].items() if d == "input" and MEM_EN_RE.match(n)]
        if en:
            res += [(".".join(["dut"] + p + [n]), b) for n in sorted(en)]
        else:
            res += mem_enables(mods, cm, p, b)
    return res


def vec(name, items):
    if not items:
        return "localparam int N_%s = 0;\nwire probe_%s = 1'b0;\n" % (name.upper(), name)
    s = "localparam int N_%s = %d;\nwire [N_%s-1:0] probe_%s = {\n" % (name.upper(), len(items), name.upper(), name)
    s += ",\n".join("  " + i for i in items) + "\n};\n"
    return s


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    rtl, cfg, out = sys.argv[1:]
    mods = load(rtl)
    if TOP not in mods:
        raise SystemExit("module %s not found under %s" % (TOP, rtl))
    bnd, memtag, memdata, core_side = [], [], [], []
    notes = []
    for arr in ("metaArray", "errorArray", "tagArray", "bankedDataArray"):
        hits = find(mods, arr)
        if not hits:
            notes.append("no instance %s" % arr)
        for path, mod in hits:
            ins = sorted(n for n, d in mods[mod][0].items() if d == "input" and BND_RE.match(n))
            bnd += [".".join(["dut"] + path + [n]) for n in ins]
            notes.append("%s: %s, %d boundary enables" % (".".join(path), mod, len(ins)))
            if arr == "tagArray":
                memtag += mem_enables(mods, mod, path)
            if arr == "bankedDataArray":
                memdata += [e for e, _ in mem_enables(mods, mod, path)]
    for path, mod in find(mods, r"l1dGate"):
        outs = sorted(n for n, d in mods[mod][0].items() if d == "output" and GATE_CORE_RE.match(n))
        core_side += [".".join(["dut"] + path + [n]) for n in outs]
        notes.append("%s: %s, %d outputs to the core" % (".".join(path), mod, len(outs)))
    text = "// generated by scripts/mem_probes.py (cfg %s) from %s\n" % (cfg, rtl)
    text += "".join("// %s\n" % n for n in notes)
    # the tag memory enables, and for each the "its TagSRAMBank is initialising" condition (rst_cnt < NSETS: the bank
    # writes zeros to every set by itself after its reset, TagArray.scala:66-75), a tile reset domain activity
    tag_init = ["(%s.rst_cnt < NSETS)" % b if b else "1'b0" for _, b in memtag]
    notes.append("tag memory enables with an initialisation counter: %d of %d" % (sum(1 for _, b in memtag if b), len(memtag)))
    memtag_en = [e for e, _ in memtag]
    text += vec("bnd", bnd) + vec("mem_tag", memtag_en) + vec("mem_tag_init", tag_init) + vec("mem_data", memdata)
    text += vec("core_side", core_side)
    with open(out, "w") as f:
        f.write(text)
    print("mem_probes %s: boundary=%d mem-tag=%d mem-data=%d core-side=%d" %
          (cfg, len(bnd), len(memtag), len(memdata), len(core_side)))
    for n in notes:
        print("  " + n)
    if not memtag or not memdata or not bnd:
        print("FAIL: no probes of the %s: an empty check is a failed check" %
              ", ".join(k for k, v in (("tag memory", memtag), ("data memory", memdata), ("module boundaries", bnd)) if not v))
        sys.exit(2)


if __name__ == "__main__":
    main()
