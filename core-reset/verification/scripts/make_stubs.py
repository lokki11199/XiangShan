#!/usr/bin/env python3
"""Generated part of the tile isolation test (TESTPLAN section 6): stubs of XSCore and L2Top, the wrapper of XSTile with its
monitors, and the list of RTL files of XSTile without the subtrees of XSCore and L2Top.

usage: make_stubs.py <rtl_dir> <cfg> <out_dir> [--allow <file>] [--xstile <XSTile.sv to use instead of the one in rtl_dir>]
  rtl_dir  RTL of a full XSNoCTop elaboration (split Verilog, one file per module: build/noc_<cfg>/rtl)
  cfg      full | keep (only in the names of the generated files and in the messages)
  out_dir  where the files go (tb_rtl/gen or a build directory):
     stub_XSCore_<cfg>.sv, stub_L2Top_<cfg>.sv  same module names and ports as in the RTL
     tile_iso_dut_<cfg>.sv                      module tile_iso_dut: XSTile, its inputs driven, monitors of its outputs
     tile_iso_names_<cfg>.svh                   paths of the instances (core, l2top, controller) and the options found
     tile_iso_files_<cfg>.f                     RTL files of XSTile without XSCore / L2Top (one per line)
     tile_iso_signals_<cfg>.txt                 every monitored signal and what is checked on it (for the report)

What the stubs do (TESTPLAN 6.2):
  XSCore: outside the isolation the TileLink handshake outputs are quiet (valid 0, ready 1), under it random; every other
    output (data fields, side band) is random in every cycle, except the DCache handshake and the frontend reset:
    l1_quiesce_done = l1_quiesce_req a cycle later, l1_quiesce_idle = 1 (both random while isolated), l1_quiesce_alive =
    0 in its reset then 1, resetInFrontend = its reset plus 4 cycles; in the first 1..4 cycles of its reset every output
    is random (the reset domain crossing). Extra internal signals ti_* are read by the bench.
  L2Top: outputs are constants of the bench (no Probe, hartIsInReset.toTile = 0), except reset outputs (= its reset),
    clock outputs (= its clock) and the TLB request of L2 to the core (req.valid = 1, so the mask under busy has
    something to mask: T4). Its inputs are monitored: T1 (stable while isolated), T2 (clamp values in the first cycle of
    isolate), T3 (prefetch masks while busy).
The monitors read the bench through $root.tile_iso_tb.<signal> (chk_stable, chk_first, busy_now, iso_now).

T1 exemptions: a data field qualified by a valid (`X_bits_*` by `X_valid`, `X` by `X_valid`) is not compared while the
qualifier is 0 in this or the previous cycle; clock and reset; names matching a regex of the allow file (one regex per
line, `#` comments; every entry must name the DESIGN section that allows it).
"""
import os
import re
import sys

PORT = re.compile(r"^\s*(input|output|inout)\s+(?:wire\s+|logic\s+|reg\s+)?(?:\[(\d+):(\d+)\]\s*)?(\w+)\s*,?\s*(?://.*)?$")
MODDEF = re.compile(r"^\s*module\s+(\w+)\b")
INST = re.compile(r"^\s*(\w+)\s+(?:#\(.*?\)\s*)?(\w+)\s*\(\s*(?://.*)?$")

# T2: values in the first cycle of isolate (DESIGN 6.2), regex on the port name -> expected value kind
T2_PATTERNS = [
    (r"cpu_halt", "zero"),
    (r"cpu_critical_error|cpu_crtical_error", "zero"),
    (r"(^|_)msiAck", "zero"),
    (r"l2_flush_en", "zero"),
    (r"beu_errors_\w*ecc_error_valid", "zero"),
    (r"groups_\d+_valid", "zero"),
    (r"iretire", "zero"),
    (r"itype", "zero"),
    (r"robHeadPaddr_valid", "zero"),
    (r"l2_tlb_req_req_ready", "zero"),
    (r"l2_tlb_req_resp_valid", "zero"),
    (r"resetInFrontend", "one"),
    (r"l2_pmp_resp", "ones"),
]
# T2 patterns that must find at least one signal (the others are optional in a configuration)
T2_REQUIRED = [r"cpu_halt", r"(^|_)msiAck", r"groups_\d+_valid", r"iretire", r"itype", r"robHeadPaddr_valid",
               r"l2_tlb_req_req_ready", r"l2_tlb_req_resp_valid", r"resetInFrontend", r"l2_pmp_resp"]
# A required pattern that finds no signal is an error, except for these known absences: they are reported as
# `T2 SKIP <pattern>: no such signal in this configuration (<reason>)` in the run output and in the results (not a pass)
T2_KNOWN_ABSENT = {
    r"robHeadPaddr_valid": "TopDown not built",
    r"l2_tlb_req_req_ready": "ready unused by CoupledL2, removed by firtool",
}
T3_PATTERNS = [r"(^|_)addr_valid$", r"l2_pf_master_en$"]   # not robHeadPaddr_valid


def die(msg):
    sys.stderr.write("make_stubs.py: " + msg + "\n")
    sys.exit(1)


def module_files(rtl):
    """{module name: file} of every module defined in the RTL directory (recursively)."""
    mods = {}
    for d, _, fs in os.walk(rtl):
        for f in sorted(fs):
            if not f.endswith((".sv", ".v")):
                continue
            p = os.path.join(d, f)
            with open(p, errors="replace") as fh:
                for ln in fh:
                    m = MODDEF.match(ln)
                    if m and m.group(1) not in mods:
                        mods[m.group(1)] = p
    return mods


def module_text(path, name):
    with open(path, errors="replace") as fh:
        txt = fh.read()
    m = re.search(r"^\s*module\s+" + re.escape(name) + r"\b.*?^\s*endmodule\b", txt, re.S | re.M)
    if not m:
        die("module %s not found in %s" % (name, path))
    return m.group(0)


def ports(text):
    """[(dir, width, name)] of the ANSI header of a module (firtool: one port per line, disallowPortDeclSharing)."""
    head = text[:text.index(");")] if ");" in text else text
    out = []
    for ln in head.splitlines()[1:]:
        m = PORT.match(ln)
        if m:
            w = abs(int(m.group(2)) - int(m.group(3))) + 1 if m.group(2) else 1
            out.append((m.group(1), w, m.group(4)))
    if not out:
        die("no ports parsed from the header:\n" + head[:400])
    return out


def instances(text, known):
    """[(module, instance)] of the module bodies instantiated in text (only names of known modules)."""
    res = []
    for ln in text.splitlines():
        m = INST.match(ln)
        if m and m.group(1) in known and m.group(1) not in ("module", "input", "output"):
            res.append((m.group(1), m.group(2)))
    return res


def closure(top, mods, cut):
    seen, todo, missing = [], [top], set()
    while todo:
        m = todo.pop()
        if m in seen or m in cut:
            continue
        seen.append(m)
        txt = module_text(mods[m], m)
        for sub, _ in instances(txt, mods):
            todo.append(sub)
        for ln in txt.splitlines():   # instances of modules that are not in the directory
            mm = INST.match(ln)
            if mm and mm.group(1) not in mods and mm.group(1)[0].isupper() and mm.group(1) not in seen:
                missing.add(mm.group(1))
    return seen, missing


def qualifier(name, names):
    """The valid signal that qualifies a data field, or None (DESIGN 6.2: a data field qualified by its valid needs no clamp)."""
    # the prefetch hint: pf_source is qualified by addr_valid of the same bridge
    m = re.match(r"^(.*)_pf_source$", name)
    if m and m.group(1) + "_addr_valid" in names:
        return m.group(1) + "_addr_valid"
    # trace: L2Top captures toEncoder.priv and .trap with RegEnable on groups(0).valid (L2Top.scala:286-293)
    m = re.match(r"^(.*_toEncoder)_(priv|trap_\w+)$", name)
    if m and m.group(1) + "_groups_0_valid" in names:
        return m.group(1) + "_groups_0_valid"
    m = re.match(r"^(.*)_bits(_.*)?$", name)
    if m and m.group(1) + "_valid" in names:
        return m.group(1) + "_valid"
    if not name.endswith("_valid") and name + "_valid" in names:
        return name + "_valid"
    return None


def load_allow(path):
    pats = []
    if path and os.path.exists(path):
        for ln in open(path):
            ln = ln.split("#", 1)[0].strip()
            if ln:
                pats.append(re.compile(ln))
    return pats


def vec(w):
    return "" if w == 1 else "[%d:0] " % (w - 1)


def monitor_block(sigs, names, allow, where, prefix, cfg):
    names = {n for _, n in sigs}   # a qualifier is used only if it is monitored here too (its _q register exists)
    """SystemVerilog of the T1 / T2 / T3 monitors on a list of (width, name) signals visible in the module.
    Returns (code, report lines, matched T2 patterns)."""
    code, rep, hit = [], [], set()
    code.append("  // ---- monitors (generated): T1 stable while isolated, T2 clamp values, T3 prefetch masks while busy")
    code.append("  wire ti_chk_stable = $root.tile_iso_tb.chk_stable, ti_chk_first = $root.tile_iso_tb.chk_first;")
    code.append("  wire ti_busy = $root.tile_iso_tb.busy_now;")
    code.append("  int n_t1 = 0, n_t2 = 0, n_t3 = 0, n_t3_checked = 0;")
    code.append("  wire ti_ack = $root.tile_iso_tb.ack_now, ti_ack_q = $root.tile_iso_tb.ack_q;")
    fin = []   # final summary: every signal with a T1 violation and its number of cycles
    for w, n in sigs:
        q = qualifier(n, names)
        allowed = any(p.search(n) for p in allow)
        # B ready of the L1D gate to L2: 0 or takeB, registers of the gate (DESIGN 3, 6.1). FULL only, and only in the
        # cycles where the controller's ackProbe is (or was) high; in KEEP and outside ackProbe a change is an error
        b_ready_ack = where == "L2Top" and cfg == "full" and re.search(r"_b_ready$", n) is not None
        t2 = [(p, k) for p, k in T2_PATTERNS if re.search(p, n)]
        t3 = any(re.search(p, n) for p in T3_PATTERNS)
        code.append("  logic %s%s_q_%s;" % (vec(w), prefix, n))
        body = ["    %s_q_%s <= %s;" % (prefix, n, n)]
        what = []
        if allowed:
            what.append("T1 allowed")
        else:
            cond = "ti_chk_stable && %s !== %s_q_%s" % (n, prefix, n)
            if b_ready_ack:
                cond += " && !(ti_ack || ti_ack_q)"
                what.append("T1 except while ackProbe (FULL, gate takeB)")
            if q:
                cond += " && (%s || %s_q_%s)" % (q, prefix, q)   # compared only while its valid is (was) high
                what.append("T1 when %s" % q)
            else:
                what.append("T1")
            code.append("  int c1_%s_%s = 0;" % (prefix, n))
            body.append('    if (%s) begin n_t1++; c1_%s_%s++; if (n_t1 <= 20) $display("[%%0t] ERROR T1: %s %s changed while isolated (%%h -> %%h)", $time, %s_q_%s, %s); end'
                        % (cond, prefix, n, where, n, prefix, n, n))
            fin.append('    if (c1_%s_%s != 0) $display("T1 summary: %s %s changed in %%0d cycles while isolated", c1_%s_%s);'
                       % (prefix, n, where, n, prefix, n))
        for p, k in t2:
            hit.add(p)
            exp = {"zero": "'0", "one": "1'b1", "ones": "'1"}[k]
            body.append('    if (ti_chk_first && %s !== %s) begin n_t2++; $display("[%%0t] ERROR T2: %s %s = %%h in the first cycle of isolate, expected %s", $time, %s); end'
                        % (n, exp, where, n, k, n))
            what.append("T2 %s" % k)
        if t3:
            body.append("    if (ti_busy) n_t3_checked++;")
            body.append('    if (ti_busy && %s !== \'0) begin n_t3++; if (n_t3 <= 20) $display("[%%0t] ERROR T3: %s %s = %%h while busy", $time, %s); end'
                        % (n, where, n, n))
            what.append("T3 0 while busy")
        code.append("  always @(posedge clock) begin")
        code.extend(body)
        code.append("  end")
        rep.append("%-8s %-70s %s" % (where, n, ", ".join(what)))
    code.append("  final begin")
    code.extend(fin)
    code.append("  end")
    return code, rep, hit


def main():
    a = sys.argv[1:]
    allow_path, xstile_override = None, None
    if "--allow" in a:
        i = a.index("--allow"); allow_path = a[i + 1]; del a[i:i + 2]
    if "--xstile" in a:
        i = a.index("--xstile"); xstile_override = a[i + 1]; del a[i:i + 2]
    if len(a) != 3:
        die(__doc__)
    rtl, cfg, out = a
    os.makedirs(out, exist_ok=True)
    allow = load_allow(allow_path)
    mods = module_files(rtl)
    for m in ("XSTile", "XSCore", "L2Top"):
        if m not in mods:
            die("module %s not found under %s (names differ in this RTL? TESTPLAN 6.2)" % (m, rtl))
    tile_path = xstile_override or mods["XSTile"]
    tile_txt = module_text(tile_path, "XSTile")
    insts = instances(tile_txt, mods)
    core_i = [i for m, i in insts if m == "XSCore"]
    l2_i = [i for m, i in insts if m == "L2Top"]
    ctl = [(m, i) for m, i in insts if m.startswith("CoreResetCtrl")]
    gates = [i for m, i in insts if re.match(r"TLQuiesceGate(_\d+)?$", m)]
    isos = [i for m, i in insts if re.match(r"TLResetIsolation(_\d+)?$", m)]
    if len(core_i) != 1 or len(l2_i) != 1 or len(ctl) != 1:
        die("XSTile: instances XSCore %s, L2Top %s, CoreResetCtrl %s (one of each expected)" % (core_i, l2_i, ctl))
    ctl_ports = [n for _, _, n in ports(module_text(mods[ctl[0][0]], ctl[0][0]))]
    for p in ("io_isolate", "io_busy", "io_inReset"):
        if p not in ctl_ports:
            die("%s has no port %s" % (ctl[0][0], p))

    # ---------------- XSCore stub
    cports = ports(module_text(mods["XSCore"], "XSCore"))
    cnames = {n for _, _, n in cports}
    outs = [(w, n) for d, w, n in cports if d == "output"]
    total = sum(w for w, _ in outs) or 1
    nw = (total + 31) // 32
    keep_reset = next((n for d, _, n in cports if d == "input" and re.search(r"keep_reset", n)), None)
    tlb_valid_in = next((n for d, _, n in cports if d == "input" and re.search(r"l2_tlb_req_req_valid$", n)), None)
    q_req = next((n for d, _, n in cports if d == "input" and re.search(r"l1_quiesce_req$", n)), None)
    if not q_req:
        die("XSCore has no l1_quiesce_req input: not a configuration with EnableCoreReset")
    if "clock" not in cnames or "reset" not in cnames:
        die("XSCore: clock / reset ports not found")
    s = ["// generated by scripts/make_stubs.py from %s (%s): stub of XSCore for the tile isolation test" % (rtl, cfg),
         "module XSCore("]
    s.append(",\n".join("  %-6s %s%s" % (d, vec(w), n) for d, w, n in cports))
    s.append(");")
    s.append("  wire iso = $root.tile_iso_tb.iso_now;")
    s.append("  logic [%d:0][31:0] rw;" % (nw - 1))
    s.append("  always @(posedge clock) for (int i = 0; i < %d; i++) rw[i] <= $urandom;" % nw)
    s.append("  wire [%d:0] rv = rw;" % (nw * 32 - 1))
    s.append("  // the first 1..4 cycles of its reset: every output random (reset domain crossing)")
    s.append("  logic rst_q = 1'b0; logic [2:0] garb_n = 3'd0;")
    s.append("  always @(posedge clock) begin rst_q <= reset; if (reset && !rst_q) garb_n <= 3'($urandom_range(1, 4)); else if (garb_n != 0) garb_n <= garb_n - 3'd1; end")
    s.append("  wire garb = reset && (!rst_q || garb_n != 0);")
    s.append("  logic done_r, alive_r; logic [2:0] fe_cnt;")
    s.append("  always @(posedge clock or posedge reset)")
    s.append("    if (reset) begin done_r <= 1'b0; alive_r <= 1'b0; fe_cnt <= 3'd4; end")
    s.append("    else begin done_r <= %s; alive_r <= 1'b1; if (fe_cnt != 0) fe_cnt <= fe_cnt - 3'd1; end" % q_req)
    s.append("  wire ti_alive = alive_r, ti_fe = reset || fe_cnt != 0, ti_reset = reset;")
    s.append("  wire ti_keep_reset = %s;" % (keep_reset if keep_reset else "1'b0"))
    s.append("  wire ti_tlb_req_valid = %s;" % (tlb_valid_in if tlb_valid_in else "1'b0"))
    off, pf, pfm = 0, [], []   # the prefetch hints (addr_valid: random always, not a TileLink handshake) and l2_pf_master_en
    for w, n in outs:
        r = "rv[%d +: %d]" % (off, w)
        off += w
        if re.search(r"l1_quiesce_done$", n):
            e = "garb || iso ? %s : done_r" % r
        elif re.search(r"l1_quiesce_idle$", n):
            e = "garb || iso ? %s : 1'b1" % r
        elif re.search(r"l1_quiesce_alive$", n):
            e = "garb ? %s : alive_r" % r
        elif re.search(r"resetInFrontend$", n):
            e = "garb ? %s : ti_fe" % r
        elif n.startswith("auto_") and n.endswith("_valid") and "_bits_" not in n and not re.search(T3_PATTERNS[0], n):
            e = "garb || iso ? %s : 1'b0" % r
        elif n.startswith("auto_") and n.endswith("_ready") and "_bits_" not in n:
            e = "garb || iso ? %s : 1'b1" % r
        else:
            e = r
        if re.search(T3_PATTERNS[0], n):
            pf.append(n)
        if re.search(T3_PATTERNS[1], n):
            pfm.append(n)
        s.append("  assign %s = %s;" % (n, e))
    s.append("  wire ti_pf_out = %s;" % (" || ".join("(|%s)" % n for n in pf) if pf else "1'b0"))
    s.append("  wire ti_pf_master = %s;" % (" || ".join("(|%s)" % n for n in pfm) if pfm else "1'b0"))
    s.append("endmodule")
    open(os.path.join(out, "stub_XSCore_%s.sv" % cfg), "w").write("\n".join(s) + "\n")

    # ---------------- L2Top stub
    lports = ports(module_text(mods["L2Top"], "L2Top"))
    lnames = {n for _, _, n in lports}
    if "clock" not in lnames or "reset" not in lnames:
        die("L2Top: clock / reset ports not found")
    s = ["// generated by scripts/make_stubs.py from %s (%s): stub of L2Top for the tile isolation test" % (rtl, cfg),
         "module L2Top("]
    s.append(",\n".join("  %-6s %s%s" % (d, vec(w), n) for d, w, n in lports))
    s.append(");")
    for d, w, n in lports:
        if d != "output":
            continue
        if re.search(r"reset", n, re.I):
            e = "{%d{reset}}" % w if w > 1 else "reset"
        elif re.search(r"clock", n, re.I):
            e = "clock"
        elif re.search(r"l2_tlb_req_req_valid$", n):
            e = "1'b1"
        else:
            e = "'0"
        s.append("  assign %s = %s;" % (n, e))
    mon_in = [(w, n) for d, w, n in lports if d == "input" and n not in ("clock", "reset")]
    code, rep_l2, hit_l2 = monitor_block(mon_in, lnames, allow, "L2Top", "l2", cfg)
    s.extend(code)
    s.append("endmodule")
    open(os.path.join(out, "stub_L2Top_%s.sv" % cfg), "w").write("\n".join(s) + "\n")

    # ---------------- XSTile wrapper with its inputs driven and its outputs monitored
    tports = ports(tile_txt)
    tnames = {n for _, _, n in tports}
    def find(rx, d):
        r = [n for dd, _, n in tports if dd == d and re.search(rx, n)]
        if len(r) != 1:
            die("XSTile: %d %s ports match %s (one expected): %s" % (len(r), d, rx, r))
        return r[0]
    req_dbg, req_hart, req_cl = find(r"debug_reset$", "input"), find(r"hart_reset$", "input"), find(r"core_reset_req$", "input")
    o_busy, o_inr, o_hir = find(r"core_reset_busy$", "output"), find(r"core_in_reset$", "output"), find(r"hartIsInReset$", "output")
    s = ["// generated by scripts/make_stubs.py from %s (%s): XSTile with its inputs driven by the bench" % (rtl, cfg),
         "module tile_iso_dut(input clock, input reset, input req_debug, input req_hart, input req_cluster,",
         "                    output ti_core_reset_busy, output ti_core_in_reset, output ti_hart_in_reset);"]
    conns = []
    for d, w, n in tports:
        if n == "clock":
            conns.append(".clock(clock)")
        elif n == "reset":
            conns.append(".reset(reset)")
        elif n == req_dbg:
            conns.append(".%s(req_debug)" % n)
        elif n == req_hart:
            conns.append(".%s(req_hart)" % n)
        elif n == req_cl:
            conns.append(".%s(req_cluster)" % n)
        elif d == "input":
            # constants: active-low resets and enables (`_n`) are 1, everything else 0
            conns.append(".%s(%s)" % (n, "'1" if re.search(r"_n$", n) else "'0"))
        else:
            s.append("  wire %s%s;" % (vec(w), n))
            conns.append(".%s(%s)" % (n, n))
    s.append("  XSTile u_tile (\n    " + ",\n    ".join(conns) + ");")
    s.append("  assign ti_core_reset_busy = %s; assign ti_core_in_reset = %s; assign ti_hart_in_reset = %s;" % (o_busy, o_inr, o_hir))
    mon_out = [(w, n) for d, w, n in tports if d == "output"]
    code, rep_t, hit_t = monitor_block(mon_out, tnames, allow, "XSTile", "xt", cfg)
    s.extend(code)
    s.append("endmodule")
    open(os.path.join(out, "tile_iso_dut_%s.sv" % cfg), "w").write("\n".join(s) + "\n")

    # ---------------- names, files, report
    hit = hit_l2 | hit_t
    absent = [p for p in T2_REQUIRED if p not in hit]
    missing_t2 = [p for p in absent if p not in T2_KNOWN_ABSENT]
    skip_t2 = ["%s: no such signal in this configuration (%s)" % (p, T2_KNOWN_ABSENT[p]) for p in absent if p in T2_KNOWN_ABSENT]
    with open(os.path.join(out, "tile_iso_names_%s.svh" % cfg), "w") as f:
        f.write("// generated by scripts/make_stubs.py (%s)\n" % cfg)
        f.write("`define TI_CORE tile_iso_tb.dut.u_tile.%s\n" % core_i[0])
        f.write("`define TI_L2 tile_iso_tb.dut.u_tile.%s\n" % l2_i[0])
        f.write("`define TI_CTRL tile_iso_tb.dut.u_tile.%s\n" % ctl[0][1])
        f.write("`define TI_CFG \"%s\"\n" % cfg)
        f.write("`define TI_N_GATES %d\n`define TI_N_ISO %d\n" % (len(gates), len(isos)))
        if keep_reset:
            f.write("`define TI_HAS_KEEP_RESET\n")
        if "io_ackProbe" in ctl_ports:   # KEEP: ackProbe is constant 0 and firtool removes the port
            f.write("`define TI_HAS_ACK_PROBE\n")
        if not tlb_valid_in:
            f.write("`define TI_NO_TLB_REQ\n")
        f.write("`define TI_T2_MISSING \"%s\"\n" % " ".join(missing_t2))
        f.write("`define TI_T2_SKIP \"%s\"\n" % "; ".join(skip_t2))
    files, missing = closure("XSTile", mods, {"XSCore", "L2Top"})
    if missing:
        die("modules instantiated under XSTile but not defined in %s: %s" % (rtl, sorted(missing)))
    with open(os.path.join(out, "tile_iso_files_%s.f" % cfg), "w") as f:
        for m in files:
            f.write((xstile_override if (m == "XSTile" and xstile_override) else mods[m]) + "\n")
    with open(os.path.join(out, "tile_iso_signals_%s.txt" % cfg), "w") as f:
        f.write("# %s: XSTile gates %d, isolations %d, core %s, l2top %s, controller %s %s, keep_reset %s\n"
                % (cfg, len(gates), len(isos), core_i[0], l2_i[0], ctl[0][0], ctl[0][1], keep_reset))
        f.write("# T2 patterns without a signal: %s\n" % (missing_t2 or "none"))
        f.write("# T2 SKIP: %s\n" % ("; ".join(skip_t2) or "none"))
        f.write("\n".join(rep_l2 + rep_t) + "\n")
    print("make_stubs %s: %d modules in the closure of XSTile, XSCore %d ports (%d outputs), L2Top %d ports, XSTile %d ports; "
          "gates %d, isolations %d, keep_reset %s, T2 patterns without a signal: %s"
          % (cfg, len(files), len(cports), len(outs), len(lports), len(tports), len(gates), len(isos),
             keep_reset or "-", missing_t2 or "none") + ("; T2 SKIP: " + "; ".join(skip_t2) if skip_t2 else ""))


if __name__ == "__main__":
    main()
