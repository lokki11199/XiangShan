// ============================================================================
// cr_tb (v5): XSCore-only reset. DCache + uncached clients (core domain, reset by the core reset)
//   <-> TLQuiesceGates <-> L2 (never reset); CoreResetCtrl sequences flush/drain/reset/release.
//   Between the DCache and its gate: one-entry buffers on B and C in the core reset domain (l1d_to_l2_buffer of
//   MemBlock). A second uncached client of the core reaches a manager inside the core (ICache control
//   registers) through its gate, a tile buffer (MMIO crossbar of L2Top) and TLResetIsolation. The two uncached
//   gates are "early": channel A closed from the first cycle of sFlush.
//   The frontend leaves reset 4 cycles after the rest of the core (fe_rst, ResetGen chain); the controller
//   waits for it in sRelease.
//   Every core-side model drives random outputs (and random array writes) for 1..4 cycles right after the
//   core reset is asserted: the isolation of the tile side must keep that away from L2 and from the arrays
//   that survive the reset (reset domain crossing).
//   Configuration: CFG_SWEEP (CoreResetKeepL1 = false: L1D releases every line before the reset and is reset
//   with the core; Probes answered NtoN by the gate during the reset). The reset is a level: the core stays in
//   reset while the request is high (at least rstCycles).
//   L2 sends now and then a Probe of a line its directory lists as N (+NOSPUR: never); store misses that
//   overwrite a whole line use AcquirePerm (L2 has no valid copy afterwards: poison); a Get of the UL port to a
//   line L1D holds in T waits for a Probe toB of L1D (CoupledL2).
//   +SCEN=1  three core resets (short request) during traffic and HN snoops
//   +SCEN=2  12 back-to-back core resets with random gaps
//   +SCEN=3  request of random length (2..2000 cycles: the core is held in reset), x4
//   +SCEN=4  naive core reset without the sequence (reproduces the problem; errors expected)
//   +SCEN=5  directed: the procedure starts exactly while a transaction of class C1..C12 is in flight
//            (cr_txmon classes C1..C10, C11 MSHR with an unsent Acquire, C12 Probe offered, not accepted)
//   +SCEN=6  directed Probes of L1D lines (dirty / clean T / B, toN / toB), six cases: 0 offered in sReset,
//            1 in sRelease, 2 right after the sequence, 3 at the start of sFlush, 4 in the first cycle of sDrain,
//            5 in the last cycle of sFlush (taken by the gate, sDrain waits for its ProbeAck)
//   +SCEN=7  debug reset held for a long time (2000..20000 cycles, like ndmreset / hartreset held by a
//            debugger) with HN snoops and directed snoops during the hold (KEEP: one Probe of a hot line waits in
//            L2 until the request drops; sweep: snoops of swept lines answered NtoN by the gate at once)
//   +SLOW    long random latencies in L2, ready stalls, gaps between beats (default in SCEN 5, 6, 7)
// Checks at every reset point and when the core leaves reset: no transaction outstanding in L2 for the core;
// the DCache control logic is empty (busy_true) and so are the B / C buffers; L2's directory matches the DCache
// meta line by line, exactly (sweep: L1D is empty and L2 lists nothing at the reset point); the current data of
// every line (DCache if dirty, else L2) == golden memory. No new non-coherent request after the start of the
// sequence, nothing non-coherent open in sDrain, no Probe crosses the gate in sDrain; the core leaves reset only
// after the request dropped and the sequence ends only with the frontend out of reset; one core reset per
// request. During the reset nothing crosses to or from the core on any channel, with KEEP the DCache meta must
// not change; a Probe never waits more than 200 cycles (KEEP: outside the reset). Every load hit is checked
// against the golden memory, every uncached response by its client. At the end: global consistency, no hang.
// ============================================================================
`timescale 1ns/1ps
module cr_tb;
`ifdef CFG_SWEEP
  localparam bit KEEP = 0;
`else
  localparam bit KEEP = 1;
`endif
`ifdef RST16
  localparam int RST_CYCLES = 16;
`else
  localparam int RST_CYCLES = 100;    // CoreResetCtrl rstCycles (TileLink 1.8.1 section 3.2.2)
`endif
`ifdef NO_GARBAGE
  localparam bit GARBAGE = 0;
`else
  localparam bit GARBAGE = 1;         // random core outputs right after the core reset is asserted
`endif
  logic clk = 0; always #5 clk = ~clk;
  logic sys_rst, traffic_en, snoop_en, req_task, force_core_rst, slow_en;
  logic trig_arm; int trig_sel; logic trig_cond;
  wire  req = req_task || (trig_arm && trig_cond);   // request: from the scenario or from a directed trigger
  logic fsnp_req, fsnp_ack, fsnp_l2only; logic [3:0] fsnp_addr; logic [1:0] fsnp_param;
  int   fsnp_arm;                                    // SCEN 6: snoop started by a trigger (cases 3, 4, 5)
  logic fsnp_trig, fsnp_hold; wire fsnp_v = fsnp_req || fsnp_trig || fsnp_hold;   // a triggered snoop stays requested until L2 starts it
  logic spur_en; wire fsnp_force = !KEEP;   // sweep: L2 lists nothing after the sweep, the directed Probes are sent anyway

  // core reset: tile reset OR sequencer reset OR forced (naive), released 2 cycles later (synchroniser)
  logic ctl_core_reset; logic crst_q1 = 1'b1, crst_q2 = 1'b1;
  // tile reset of the arrays that survive a core reset (same synchroniser, without the sequencer)
  logic mrst_q1 = 1'b1, mrst_q2 = 1'b1;
  always_ff @(posedge clk or posedge sys_rst)
    if (sys_rst) {mrst_q1, mrst_q2} <= 2'b11; else {mrst_q1, mrst_q2} <= {1'b0, mrst_q1};
  wire meta_rst = mrst_q2;
  wire  crst_async = sys_rst || ctl_core_reset || force_core_rst;
  always_ff @(posedge clk or posedge crst_async)
    if (crst_async) {crst_q1, crst_q2} <= 2'b11; else {crst_q1, crst_q2} <= {1'b0, crst_q1};
  wire core_rst = crst_q2;
  // the frontend is the last of the ResetGen chain: it leaves reset 4 cycles after the rest of the core
  logic [3:0] fe_q = 4'hf;
  always_ff @(posedge clk or posedge core_rst)
    if (core_rst) fe_q <= 4'hf; else fe_q <= {fe_q[2:0], 1'b0};
  wire fe_rst = fe_q[3];

  // ---------------- wires ----------------
  // DCache <-> buffers (core reset domain): db_* B into the DCache, dc_* C from the DCache
  logic db_v, db_r, dc_v, dc_r; logic [1:0] db_par; logic [3:0] db_addr;
  logic [2:0] dc_op, dc_par; logic [3:0] dc_src, dc_addr; logic [31:0] dc_dat;
  // DCache / buffers <-> gate0 (core side): ca A, gb B (from the gate), cc C (into the gate), cd D, ce E
  logic ca_v, ca_r, gb_v, gb_r, cc_v, cc_r, cd_v, cd_r, ce_v, ce_r;
  logic [2:0] ca_op, cc_op, cd_op; logic [1:0] ca_par, gb_par, cd_par; logic [2:0] cc_par;
  logic [3:0] ca_src, ca_addr, gb_addr, cc_src, cc_addr, cd_src, cd_sink, ce_sink; logic [31:0] ca_dat, cc_dat, cd_dat;
  // gate0 <-> L2
  logic la_v, la_r, lb_v, lb_r, lc_v, lc_r, ld_v, ld_r, le_v, le_r;
  logic [2:0] la_op, lc_op, ld_op; logic [1:0] la_par, lb_par, ld_par; logic [2:0] lc_par;
  logic [3:0] la_src, la_addr, lb_addr, lc_src, lc_addr, ld_src, ld_sink, le_sink; logic [31:0] la_dat, lc_dat, ld_dat;
  // UL client <-> gate1 <-> L2
  logic ua_v, ua_r, ud_v, ud_r, ma_v, ma_r, md_v, md_r;
  logic [2:0] ua_op, ud_op, ma_op, md_op; logic [1:0] ua_par, ma_par; logic [3:0] ua_src, ua_addr, ud_src, ma_src, ma_addr, md_src;
  logic [31:0] ua_dat, ud_dat, ma_dat, md_dat;
  logic gold_we, gold_we2; logic [3:0] gold_addr, gold_addr2; logic [31:0] gold_data, gold_data2;
  logic flush_req, flush_done, flush_idle, dc_busy_true, gate_block, early_block, busy, in_reset;
  logic hart_in_reset, l1_freeze, dc_alive, hold_probe, ack_probe, quiet0, quiet1, isolate; logic [2:0] ctl_st;
  logic g0_ack_pend, b_gate, c_gate, probe_closed;
  logic lh_v; logic [3:0] lh_addr; logic [31:0] lh_data;   // load hits
  int n_dc, n_ul, n_ul2, n_mgr;
  logic [1:0] dir [16]; logic [31:0] mem [16]; logic l2_busy; int n_l2only, n_probe, n_perm, n_spur, n_get_probe;
  logic [31:0] golden [16];

  // the core runs no instruction from its reset until the sequence ends (the instruction fetch needs channel A
  // of the ICache, closed until then): no load or store reaches the DCache
  cr_dcache #(.KEEP(KEEP), .GARBAGE(GARBAGE)) u_dc (.clk, .rst(core_rst), .meta_rst, .traffic_en(traffic_en && !core_rst && !hart_in_reset), .slow(slow_en),
    .flush_req, .freeze(l1_freeze), .flush_done, .flush_idle, .alive(dc_alive), .busy_true(dc_busy_true),
    .ld_v(lh_v), .ld_addr(lh_addr), .ld_data(lh_data),
    .a_valid(ca_v), .a_ready(ca_r), .a_op(ca_op), .a_param(ca_par), .a_src(ca_src), .a_addr(ca_addr), .a_data(ca_dat),
    .b_valid(db_v), .b_ready(db_r), .b_param(db_par), .b_addr(db_addr),
    .c_valid(dc_v), .c_ready(dc_r), .c_op(dc_op), .c_param(dc_par), .c_src(dc_src), .c_addr(dc_addr), .c_data(dc_dat),
    .d_valid(cd_v), .d_ready(cd_r), .d_op(cd_op), .d_param(cd_par), .d_src(cd_src), .d_sink(cd_sink), .d_data(cd_dat),
    .e_valid(ce_v), .e_ready(ce_r), .e_sink(ce_sink), .gold_we, .gold_addr, .gold_data,
    .gold_we2, .gold_addr2, .gold_data2, .n_ops(n_dc));

  // l1d_to_l2_buffer: B (gate -> DCache) and C (DCache -> gate), in the core reset domain
  logic bufb_empty, bufc_empty;
  cr_buf1 #(.W(6), .GARBAGE(GARBAGE)) u_bufb (.clk, .rst(core_rst), .tile_rst(meta_rst),
    .in_valid(gb_v), .in_ready(gb_r), .in_bits({gb_par, gb_addr}),
    .out_valid(db_v), .out_ready(db_r), .out_bits({db_par, db_addr}), .empty(bufb_empty));
  cr_buf1 #(.W(46), .GARBAGE(GARBAGE)) u_bufc (.clk, .rst(core_rst), .tile_rst(meta_rst),
    .in_valid(dc_v), .in_ready(dc_r), .in_bits({dc_op, dc_par, dc_src, dc_addr, dc_dat}),
    .out_valid(cc_v), .out_ready(cc_r), .out_bits({cc_op, cc_par, cc_src, cc_addr, cc_dat}), .empty(bufc_empty));

  cr_gate #(1, "l1d") u_g0 (.clk, .rst(sys_rst), .block(gate_block), .hold_b(hold_probe), .ack_b(ack_probe),
    .quiet(quiet0), .ack_pend(g0_ack_pend), .isolate,
    .ia_valid(ca_v), .ia_ready(ca_r), .ia_op(ca_op), .ia_param(ca_par), .ia_src(ca_src), .ia_addr(ca_addr), .ia_data(ca_dat),
    .ib_valid(gb_v), .ib_ready(gb_r), .ib_param(gb_par), .ib_addr(gb_addr),
    .ic_valid(cc_v), .ic_ready(cc_r), .ic_op(cc_op), .ic_param(cc_par), .ic_src(cc_src), .ic_addr(cc_addr), .ic_data(cc_dat),
    .id_valid(cd_v), .id_ready(cd_r), .id_op(cd_op), .id_param(cd_par), .id_src(cd_src), .id_sink(cd_sink), .id_data(cd_dat),
    .ie_valid(ce_v), .ie_ready(ce_r), .ie_sink(ce_sink),
    .oa_valid(la_v), .oa_ready(la_r), .oa_op(la_op), .oa_param(la_par), .oa_src(la_src), .oa_addr(la_addr), .oa_data(la_dat),
    .ob_valid(lb_v), .ob_ready(lb_r), .ob_param(lb_par), .ob_addr(lb_addr),
    .oc_valid(lc_v), .oc_ready(lc_r), .oc_op(lc_op), .oc_param(lc_par), .oc_src(lc_src), .oc_addr(lc_addr), .oc_data(lc_dat),
    .od_valid(ld_v), .od_ready(ld_r), .od_op(ld_op), .od_param(ld_par), .od_src(ld_src), .od_sink(ld_sink), .od_data(ld_dat),
    .oe_valid(le_v), .oe_ready(le_r), .oe_sink(le_sink));

  // uncached clients of the core: outputs random right after the core reset is asserted, as in cr_dcache
  logic garb_ul; logic [31:0] gul;
  logic core_rst_g; logic [1:0] garb_n;
  always_ff @(posedge clk) begin
    core_rst_g <= core_rst; gul <= $urandom;
    if (core_rst && !core_rst_g) garb_n <= 2'($urandom_range(0, 3)); else if (garb_n != 0) garb_n <= garb_n - 1'b1;
  end
  assign garb_ul = GARBAGE && core_rst && !meta_rst && (!core_rst_g || garb_n != 0);
  logic ua_v_i, ud_r_i; logic [2:0] ua_op_i; logic [3:0] ua_src_i, ua_addr_i; logic [31:0] ua_dat_i;
  cr_ulclient u_ul (.clk, .rst(core_rst), .traffic_en(traffic_en && !core_rst),
    .a_valid(ua_v_i), .a_ready(ua_r), .a_op(ua_op_i), .a_param(ua_par), .a_src(ua_src_i), .a_addr(ua_addr_i), .a_data(ua_dat_i),
    .d_valid(ud_v), .d_ready(ud_r_i), .d_op(ud_op), .d_src(ud_src), .d_data(ud_dat), .n_ops(n_ul));
  assign ua_v = garb_ul ? gul[0] : ua_v_i;   assign ua_op = garb_ul ? gul[3:1] : ua_op_i;
  assign ua_src = garb_ul ? gul[7:4] : ua_src_i; assign ua_addr = garb_ul ? gul[11:8] : ua_addr_i;
  assign ua_dat = garb_ul ? ~gul : ua_dat_i; assign ud_r = garb_ul ? gul[12] : ud_r_i;

  // ---- core MMIO to its own ICache control registers: client (core) -> gate -> tile buffer (MMIO crossbar)
  //      -> TLResetIsolation -> manager (core)
  logic va_v, va_r, vd_v, vd_r, va_v_i, vd_r_i; logic [2:0] va_op, va_op_i, vd_op; logic [1:0] va_par;
  logic [3:0] va_src, va_src_i, va_addr, va_addr_i, vd_src; logic [31:0] va_dat, va_dat_i, vd_dat;
  cr_ulclient u_ul2 (.clk, .rst(core_rst), .traffic_en(traffic_en && !core_rst),
    .a_valid(va_v_i), .a_ready(va_r), .a_op(va_op_i), .a_param(va_par), .a_src(va_src_i), .a_addr(va_addr_i), .a_data(va_dat_i),
    .d_valid(vd_v), .d_ready(vd_r_i), .d_op(vd_op), .d_src(vd_src), .d_data(vd_dat), .n_ops(n_ul2));
  assign va_v = garb_ul ? gul[13] : va_v_i;  assign va_op = garb_ul ? gul[16:14] : va_op_i;
  assign va_src = garb_ul ? gul[20:17] : va_src_i; assign va_addr = garb_ul ? gul[24:21] : va_addr_i;
  assign va_dat = garb_ul ? gul : va_dat_i;  assign vd_r = garb_ul ? gul[25] : vd_r_i;
  logic quiet2, iso_quiet, xb_empty;
  logic wa_v, wa_r, wd_v, wd_r; logic [2:0] wa_op, wd_op; logic [1:0] wa_par; logic [3:0] wa_src, wa_addr, wd_src; logic [31:0] wa_dat, wd_dat;
  logic g2_ibv, g2_ocv, g2_oev; logic [1:0] g2_ibp, g2_idp; logic [3:0] g2_iba, g2_ocs, g2_oca, g2_oes, g2_ids;
  logic [2:0] g2_oco, g2_ocp; logic [31:0] g2_ocd; logic g2_icr, g2_ier, g2_obr;
  cr_gate #(0, "icachectrl_client") u_g2 (.clk, .rst(sys_rst), .block(early_block), .hold_b(hold_probe), .ack_b(ack_probe),
    .quiet(quiet2), .ack_pend(), .isolate,
    .ia_valid(va_v), .ia_ready(va_r), .ia_op(va_op), .ia_param(va_par), .ia_src(va_src), .ia_addr(va_addr), .ia_data(va_dat),
    .ib_valid(g2_ibv), .ib_ready(1'b1), .ib_param(g2_ibp), .ib_addr(g2_iba),
    .ic_valid(1'b0), .ic_ready(g2_icr), .ic_op(3'd0), .ic_param(3'd0), .ic_src(4'd0), .ic_addr(4'd0), .ic_data(32'd0),
    .id_valid(vd_v), .id_ready(vd_r), .id_op(vd_op), .id_param(g2_idp), .id_src(vd_src), .id_sink(g2_ids), .id_data(vd_dat),
    .ie_valid(1'b0), .ie_ready(g2_ier), .ie_sink(4'd0),
    .oa_valid(wa_v), .oa_ready(wa_r), .oa_op(wa_op), .oa_param(wa_par), .oa_src(wa_src), .oa_addr(wa_addr), .oa_data(wa_dat),
    .ob_valid(1'b0), .ob_ready(g2_obr), .ob_param(2'd0), .ob_addr(4'd0),
    .oc_valid(g2_ocv), .oc_ready(1'b1), .oc_op(g2_oco), .oc_param(g2_ocp), .oc_src(g2_ocs), .oc_addr(g2_oca), .oc_data(g2_ocd),
    .od_valid(wd_v), .od_ready(wd_r), .od_op(wd_op), .od_param(2'd0), .od_src(wd_src), .od_sink(4'd0), .od_data(wd_dat),
    .oe_valid(g2_oev), .oe_ready(1'b1), .oe_sink(g2_oes));
  logic xa_v, xa_r, xd_v, xd_r; logic [2:0] xa_op, xd_op; logic [3:0] xa_src, xa_addr, xd_src; logic [31:0] xa_dat, xd_dat;
  cr_ulbuf u_xb (.clk, .rst(sys_rst),
    .ia_valid(wa_v), .ia_ready(wa_r), .ia_op(wa_op), .ia_src(wa_src), .ia_addr(wa_addr), .ia_data(wa_dat),
    .id_valid(wd_v), .id_ready(wd_r), .id_op(wd_op), .id_src(wd_src), .id_data(wd_dat),
    .oa_valid(xa_v), .oa_ready(xa_r), .oa_op(xa_op), .oa_src(xa_src), .oa_addr(xa_addr), .oa_data(xa_dat),
    .od_valid(xd_v), .od_ready(xd_r), .od_op(xd_op), .od_src(xd_src), .od_data(xd_dat), .empty(xb_empty));
  logic ka_v, ka_r, kd_v, kd_r; logic [2:0] ka_op, kd_op; logic [3:0] ka_src, ka_addr, kd_src; logic [31:0] ka_dat, kd_dat;
  cr_iso #("icachectrl") u_iso (.clk, .rst(sys_rst), .isolate, .quiet(iso_quiet),
    .ia_valid(xa_v), .ia_ready(xa_r), .ia_op(xa_op), .ia_src(xa_src), .ia_addr(xa_addr), .ia_data(xa_dat),
    .id_valid(xd_v), .id_ready(xd_r), .id_op(xd_op), .id_src(xd_src), .id_data(xd_dat),
    .oa_valid(ka_v), .oa_ready(ka_r), .oa_op(ka_op), .oa_src(ka_src), .oa_addr(ka_addr), .oa_data(ka_dat),
    .od_valid(kd_v), .od_ready(kd_r), .od_op(kd_op), .od_src(kd_src), .od_data(kd_dat));
  cr_ulmgr #(.GARBAGE(GARBAGE)) u_mgr (.clk, .rst(core_rst), .tile_rst(meta_rst),
    .a_valid(ka_v), .a_ready(ka_r), .a_op(ka_op), .a_src(ka_src), .a_addr(ka_addr), .a_data(ka_dat),
    .d_valid(kd_v), .d_ready(kd_r), .d_op(kd_op), .d_src(kd_src), .d_data(kd_dat), .n_ops(n_mgr));

  logic g1_ibv, g1_ocv, g1_oev; logic [1:0] g1_ibp; logic [3:0] g1_iba, g1_ocs, g1_oca, g1_oes; logic [2:0] g1_oco, g1_ocp;
  logic [31:0] g1_ocd; logic g1_icr, g1_ier, g1_obr; logic [1:0] g1_idp; logic [3:0] g1_ids;
  cr_gate #(0, "ul") u_g1 (.clk, .rst(sys_rst), .block(early_block), .hold_b(hold_probe), .ack_b(ack_probe),
    .quiet(quiet1), .ack_pend(), .isolate,
    .ia_valid(ua_v), .ia_ready(ua_r), .ia_op(ua_op), .ia_param(ua_par), .ia_src(ua_src), .ia_addr(ua_addr), .ia_data(ua_dat),
    .ib_valid(g1_ibv), .ib_ready(1'b1), .ib_param(g1_ibp), .ib_addr(g1_iba),
    .ic_valid(1'b0), .ic_ready(g1_icr), .ic_op(3'd0), .ic_param(3'd0), .ic_src(4'd0), .ic_addr(4'd0), .ic_data(32'd0),
    .id_valid(ud_v), .id_ready(ud_r), .id_op(ud_op), .id_param(g1_idp), .id_src(ud_src), .id_sink(g1_ids), .id_data(ud_dat),
    .ie_valid(1'b0), .ie_ready(g1_ier), .ie_sink(4'd0),
    .oa_valid(ma_v), .oa_ready(ma_r), .oa_op(ma_op), .oa_param(ma_par), .oa_src(ma_src), .oa_addr(ma_addr), .oa_data(ma_dat),
    .ob_valid(1'b0), .ob_ready(g1_obr), .ob_param(2'd0), .ob_addr(4'd0),
    .oc_valid(g1_ocv), .oc_ready(1'b1), .oc_op(g1_oco), .oc_param(g1_ocp), .oc_src(g1_ocs), .oc_addr(g1_oca), .oc_data(g1_ocd),
    .od_valid(md_v), .od_ready(md_r), .od_op(md_op), .od_param(2'd0), .od_src(md_src), .od_sink(4'd0), .od_data(md_dat),
    .oe_valid(g1_oev), .oe_ready(1'b1), .oe_sink(g1_oes));

  cr_l2 u_l2 (.clk, .rst(sys_rst), .snoop_en, .slow(slow_en), .fsnp_v, .fsnp_addr, .fsnp_param, .fsnp_force, .fsnp_ack,
    .fsnp_l2only, .spur_en,
    .core_in_reset(core_rst && !sys_rst), .b_to_gate(b_gate),
    .a_valid(la_v), .a_ready(la_r), .a_op(la_op), .a_param(la_par), .a_src(la_src), .a_addr(la_addr), .a_data(la_dat),
    .b_valid(lb_v), .b_ready(lb_r), .b_param(lb_par), .b_addr(lb_addr),
    .c_valid(lc_v), .c_ready(lc_r), .c_op(lc_op), .c_param(lc_par), .c_src(lc_src), .c_addr(lc_addr), .c_data(lc_dat),
    .d_valid(ld_v), .d_ready(ld_r), .d_op(ld_op), .d_param(ld_par), .d_src(ld_src), .d_sink(ld_sink), .d_data(ld_dat),
    .e_valid(le_v), .e_ready(le_r), .e_sink(le_sink),
    .ua_valid(ma_v), .ua_ready(ma_r), .ua_op(ma_op), .ua_src(ma_src), .ua_addr(ma_addr), .ua_data(ma_dat),
    .ud_valid(md_v), .ud_ready(md_r), .ud_op(md_op), .ud_src(md_src), .ud_data(md_dat),
    .dir, .mem, .busy_core(l2_busy), .n_snoop_l2only(n_l2only), .n_probe, .n_perm, .n_spur, .n_get_probe);

  cr_ctrl #(.KEEP(KEEP), .RST_CYCLES(RST_CYCLES)) u_ctl (.clk, .rst(sys_rst), .req, .busy, .in_reset, .hart_in_reset,
    .l1_flush_req(flush_req), .l1_freeze, .l1_flush_done(flush_done), .l1_idle(flush_idle), .l1_alive(dc_alive),
    .core_in_reset(fe_rst), .early_block, .gate_block, .hold_probe, .ack_probe,
    .early_quiet(quiet1 && quiet2), .gates_quiet(quiet0 && quiet1 && quiet2 && iso_quiet), .isolate,
    .core_reset(ctl_core_reset), .st(ctl_st));
  // a B beat accepted from L2 is taken by the gate (sweep, core in reset); a C beat to L2 comes from the gate
  assign b_gate = u_g0.g_bce.take_b;
  assign c_gate = g0_ack_pend;
  assign probe_closed = hold_probe || ack_probe;
  localparam logic [2:0] S_IDLE = 3'd0, S_FLUSH = 3'd1, S_DRAIN = 3'd2, S_RESET = 3'd3, S_RELEASE = 3'd4;

  // ---------------- independent monitors (L2 side) ----------------
  wire s_flush = ctl_st == S_FLUSH, s_drain = ctl_st == S_DRAIN, s_release = ctl_st == S_RELEASE;
  logic in_reset_q; always_ff @(posedge clk) in_reset_q <= in_reset;
  wire rp_pulse = in_reset && !in_reset_q;
  logic [9:0] mon_open; int e_mon, e_sb;
  cr_txmon u_mon (.clk, .rst(sys_rst), .start(!busy && req), .in_flush(s_flush), .in_drain(s_drain), .in_reset,
    .in_release(s_release), .l1_done(flush_done && !core_rst), .b_gate, .c_gate,
    .a_v(la_v), .a_r(la_r), .a_op(la_op), .a_src(la_src), .b_v(lb_v), .b_r(lb_r), .b_addr(lb_addr),
    .c_v(lc_v), .c_r(lc_r), .c_op(lc_op), .c_param(lc_par), .c_src(lc_src), .c_addr(lc_addr),
    .d_v(ld_v), .d_r(ld_r), .d_op(ld_op), .d_src(ld_src), .e_v(le_v), .e_r(le_r),
    .ua_v(ma_v), .ua_r(ma_r), .ua_op(ma_op), .ua_src(ma_src), .ud_v(md_v), .ud_r(md_r), .ud_op(md_op), .ud_src(md_src),
    .open_cls(mon_open), .start_cls(), .start_nopen(), .errors(e_mon));
  // DCache state of every line, current golden value (including a store applied in this cycle)
  logic [1:0] l1st [16]; logic [31:0] golden_now [16];
  always_comb for (int i = 0; i < 16; i++) begin
    l1st[i] = 2'd0;
    for (int w = 0; w < 2; w++) if (u_dc.st[i[1:0]][w] != 2'd0 && u_dc.tg[i[1:0]][w] == i[3:2]) l1st[i] = u_dc.st[i[1:0]][w];
    golden_now[i] = golden[i];
    if (gold_we2 && !core_rst && gold_addr2 == i) golden_now[i] = gold_data2;
    if (gold_we && !core_rst && gold_addr == i) golden_now[i] = gold_data;
  end
  logic sb_ack_v, sb_ack_data; logic [3:0] sb_ack_addr; logic [31:0] sb_ack_val; logic [2:0] sb_ack_param;
  cr_probe_sb #(.WAIT_IN_RESET(KEEP)) u_sb (.clk, .rst(sys_rst), .in_flush(s_flush), .in_drain(s_drain),
    .in_reset, .in_release(s_release), .busy, .rp(rp_pulse), .rp_keep(KEEP), .c_gate,
    .b_v(lb_v), .b_r(lb_r), .b_param(lb_par), .b_addr(lb_addr),
    .c_v(lc_v), .c_r(lc_r), .c_op(lc_op), .c_param(lc_par), .c_addr(lc_addr), .c_data(lc_dat),
    .a_fire(la_v && la_r), .a_addr(la_addr), .cb_v(gb_v), .cb_r(gb_r), .core_rst, .dc_alive,
    .dir, .mem, .golden(golden_now), .l1(l1st),
    .ack_v(sb_ack_v), .ack_addr(sb_ack_addr), .ack_data(sb_ack_data), .ack_val(sb_ack_val), .ack_param(sb_ack_param), .errors(e_sb));
  // directed triggers (SCEN=5)
  always_comb begin
    trig_cond = 1'b0;
    if (trig_sel >= 1 && trig_sel <= 10) trig_cond = mon_open[trig_sel - 1];
    else if (trig_sel == 11) trig_cond = u_dc.mq_v && !u_dc.mq_sent;   // MSHR allocated, Acquire not sent yet
    else if (trig_sel == 12) trig_cond = lb_v && !lb_r;                // L2 offers a Probe, not accepted yet
  end
  // directed snoops started by a trigger (SCEN=6): 3 the request is raised now (the Probe is offered in the first
  // cycle of sFlush), 4 the controller leaves sFlush now (offered in the first cycle of sDrain), 5 the DCache is
  // finishing its drain (KEEP) / sweep (the Probe may be taken in the last cycle of sFlush)
  always_comb begin
    fsnp_trig = 1'b0;
    case (fsnp_arm)
      3: fsnp_trig = !busy && req;
      4: fsnp_trig = s_flush && u_ctl.flush_end;
      // the flush unit leaves its last waiting state now (KEEP: sDrain of the flush unit, sweep: sWait): the
      // snoop is started now, the Probe is offered in the cycle the controller sees done
      5: fsnp_trig = s_flush && (KEEP ? u_dc.fst == 3'd1 : u_dc.fst == 3'd3 && u_dc.inflight == 0) && u_dc.idle;
      default: fsnp_trig = 1'b0;
    endcase
  end

  always_ff @(posedge clk)
    if (sys_rst || fsnp_ack) fsnp_hold <= 1'b0; else if (fsnp_trig) fsnp_hold <= 1'b1;

  // operation counters of the core-side models restart at every core reset: accumulate them
  int n_dc_acc = 0, n_ul_acc = 0, n_dc_q = 0, n_ul_q = 0, n_ul2_acc = 0, n_ul2_q = 0;
  always_ff @(posedge clk) begin
    n_dc_q <= n_dc; n_ul_q <= n_ul; n_ul2_q <= n_ul2;
    if (n_dc < n_dc_q) n_dc_acc <= n_dc_acc + n_dc_q;
    if (n_ul < n_ul_q) n_ul_acc <= n_ul_acc + n_ul_q;
    if (n_ul2 < n_ul2_q) n_ul2_acc <= n_ul2_acc + n_ul2_q;
  end

  // ---------------- golden memory ----------------
  logic core_rst_q;
  wire rp_now = !sys_rst && core_rst && !core_rst_q && ctl_core_reset;
  // every store is kept, in both configurations (sweep: L2 has the data of every line before the reset)
  always_ff @(posedge clk) begin
    if (sys_rst) for (int i = 0; i < 16; i++) golden[i] <= 32'h1000 + i;
    else begin
      if (gold_we2 && !core_rst) golden[gold_addr2] <= gold_data2;
      if (gold_we && !core_rst) golden[gold_addr] <= gold_data;   // a later store hit wins
    end
  end

  // ---------------- checks ----------------
  int e_tb = 0, n_resets = 0, n_rp = 0, n_swept = 0, n_swept_dirty = 0;
  always_ff @(posedge clk)
    if (!sys_rst && lc_v && lc_r && u_g0.c_first && (lc_op == 3'd6 || lc_op == 3'd7) && u_dc.block) begin
      n_swept <= n_swept + 1; if (lc_op == 3'd7) n_swept_dirty <= n_swept_dirty + 1;
    end
  // L2 directory vs DCache meta, and the current data of every line vs the golden memory
  task automatic check_lines(input string where);
    for (int i = 0; i < 16; i++) begin
      automatic logic [1:0] s = 2'd0; automatic logic [31:0] d = '0;
      for (int w = 0; w < 2; w++)
        if (u_dc.st[i[1:0]][w] != 2'd0 && u_dc.tg[i[1:0]][w] == i[3:2]) begin s = u_dc.st[i[1:0]][w]; d = u_dc.dat[i[1:0]][w]; end
      // dir: 0 N, 1 B, 2 T   dcache: 0 N, 1 B, 2 T, 3 Dirty: exact in both configurations
      if (!((dir[i] == 2'd0 && s == 2'd0) || (dir[i] == 2'd1 && s == 2'd1) || (dir[i] == 2'd2 && s >= 2'd2))) begin
        e_tb++; $display("[%0t] ERROR (%s): line %0d: L2 directory %0d, DCache meta %0d", $time, where, i, dir[i], s);
      end
      if (s == 2'd3) begin
        if (d != golden[i]) begin e_tb++; $display("[%0t] ERROR (%s): line %0d lost data: DCache %h, golden %h", $time, where, i, d, golden[i]); end
      end else begin
        if (mem[i] != golden[i]) begin e_tb++; $display("[%0t] ERROR (%s): line %0d lost data: L2 %h, golden %h", $time, where, i, mem[i], golden[i]); end
        if (s != 2'd0 && d != mem[i]) begin e_tb++; $display("[%0t] ERROR (%s): line %0d clean copy %h != L2 %h", $time, where, i, d, mem[i]); end
      end
    end
  endtask
  int n_warm = 0, n_held = 0, n_gate_ack = 0;
  // sDrain statistics: number of sDrain phases, the longest one, Probes held in sDrain
  int n_drain = 0, max_drain = 0, cur_drain = 0, n_held_drain = 0;
  logic held_q, req_q, fe_rst_q; logic [2:0] st_q; int rst_len_any = 0;
  always_ff @(posedge clk) if (!sys_rst && lc_v && lc_r && c_gate) n_gate_ack <= n_gate_ack + 1;
  always_ff @(posedge clk) begin
    held_q <= hold_probe && lb_v;
    if (!sys_rst && hold_probe && lb_v && !held_q) begin
      n_held <= n_held + 1;                                       // a Probe from L2 waits in the gate
      if (s_drain) n_held_drain <= n_held_drain + 1;
    end
    if (!sys_rst && s_drain) begin
      cur_drain = (st_q == S_DRAIN) ? cur_drain + 1 : 1;
      if (cur_drain > max_drain) max_drain <= cur_drain;
      if (st_q != S_DRAIN) n_drain <= n_drain + 1;
    end
    // the Debug Module sees the hart in reset from the core reset until the core runs again
    if (!sys_rst && (ctl_st == S_RESET || ctl_st == S_RELEASE) && !hart_in_reset) begin
      e_tb++; $display("[%0t] ERROR: hartIsInReset low in state %0d", $time, ctl_st);
    end
    // nothing reaches or leaves the core on any channel while it is in reset or being released
    if (!sys_rst && (ctl_st == S_RESET || ctl_st == S_RELEASE) &&
        (ca_v && ca_r || gb_v && gb_r || cc_v && cc_r || cd_v && cd_r || ce_v && ce_r || ua_v && ua_r || ud_v && ud_r ||
         va_v && va_r || vd_v && vd_r || ka_v && ka_r || kd_v && kd_r)) begin
      e_tb++; $display("[%0t] ERROR: a TileLink beat on the core side of the gates / isolation in state %0d", $time, ctl_st);
    end
    // the tile side of every gate and of the isolation sees nothing from the core then (the gate's own
    // ProbeAck excepted)
    if (!sys_rst && (ctl_st == S_RESET || ctl_st == S_RELEASE) &&
        (la_v || lc_v && !g0_ack_pend || le_v || ma_v || wa_v || xd_v || ld_v && ld_r || md_v && md_r || wd_v && wd_r || xa_v && xa_r)) begin
      e_tb++; $display("[%0t] ERROR: a signal from the core reset domain reaches the tile in state %0d", $time, ctl_st);
    end
    // no new request of a non-coherent agent once the sequence has started (early block)
    if (!sys_rst && ctl_st != S_IDLE && (ma_v && ma_r && u_g1.a_first || wa_v && wa_r && u_g2.a_first)) begin
      e_tb++; $display("[%0t] ERROR: a new request of a non-coherent agent crosses its gate in state %0d", $time, ctl_st);
    end
    // nothing non-coherent is open when sDrain starts (a Get may need a Probe of L1D: B closes in sDrain)
    if (!sys_rst && s_drain && st_q == S_FLUSH &&
        (!xb_empty || u_mgr.v[0] || u_mgr.v[1] || u_mgr.abeat || u_mgr.dbeat || u_l2.ul_v[0] || u_l2.ul_v[1] || u_l2.ula_beat)) begin
      e_tb++; $display("[%0t] ERROR: a non-coherent request is still open when sDrain starts", $time);
    end
    // no Probe crosses the gate in sDrain (channel B closed from its first cycle)
    if (!sys_rst && s_drain && lb_v && lb_r) begin
      e_tb++; $display("[%0t] ERROR: a Probe crosses the L1D gate in sDrain", $time);
    end
    // every core reset lasts at least rstCycles (TileLink 1.8.1 3.2.2: valid low for 100 cycles in reset)
    if (!sys_rst && st_q == S_RESET && ctl_st != S_RESET && rst_len_any < RST_CYCLES) begin
      e_tb++; $display("[%0t] ERROR: core reset shorter than %0d cycles (%0d)", $time, RST_CYCLES, rst_len_any);
    end
    rst_len_any <= (ctl_st == S_RESET) ? rst_len_any + 1 : 0;
    // the core leaves reset only after the request dropped
    if (!sys_rst && st_q == S_RESET && ctl_st == S_RELEASE && req_q) begin
      e_tb++; $display("[%0t] ERROR: the core leaves reset while the request is high", $time);
    end
    // the sequence ends (the core runs) only with the frontend out of reset
    if (!sys_rst && st_q == S_RELEASE && ctl_st == S_IDLE && fe_rst_q) begin
      e_tb++; $display("[%0t] ERROR: the sequence ends while the frontend is still in reset", $time);
    end
    // isolation: high whenever the core reset is asserted by the sequencer (also in its synchroniser), and
    // only in sReset / sRelease
    if (!sys_rst && !meta_rst && core_rst && !force_core_rst && !isolate) begin
      e_tb++; $display("[%0t] ERROR: XSCore in reset without isolation (state %0d)", $time, ctl_st);
    end
    if (!sys_rst && isolate && !(ctl_st == S_RESET || ctl_st == S_RELEASE)) begin
      e_tb++; $display("[%0t] ERROR: isolation in state %0d", $time, ctl_st);
    end
    // sweep: while the gate answers Probes (isolation) a Probe offered is taken at once, unless the previous
    // ProbeAck of the gate is still waiting for channel C
    if (!sys_rst && !KEEP && isolate && lb_v && !lb_r && !g0_ack_pend) begin
      e_tb++; $display("[%0t] ERROR: sweep: a Probe offered while the core is in reset is not taken by the gate", $time);
    end
    st_q <= ctl_st; req_q <= req; fe_rst_q <= fe_rst;
    if (!sys_rst && ctl_st == S_IDLE && hart_in_reset) begin e_tb++; $display("[%0t] ERROR: hartIsInReset high in sIdle", $time); end
  end
  always_ff @(posedge clk) begin
    core_rst_q <= core_rst;
    if (!sys_rst && ctl_core_reset && !core_rst_q && core_rst) n_resets <= n_resets + 1;
    // reset point: first cycle of a sequencer reset
    if (rp_now) begin
      n_rp <= n_rp + 1;
      if (l2_busy) begin e_tb++; $display("[%0t] ERROR: L2 has a core transaction outstanding at the reset point", $time); end
      if (!xb_empty || !iso_quiet || u_mgr.v[0] || u_mgr.v[1] || u_mgr.abeat || u_mgr.dbeat) begin
        e_tb++; $display("[%0t] ERROR: ICache control request outstanding at the reset point", $time);
      end
      // sweep: L1D is empty at the reset point (every line released)
      if (!KEEP) begin
        automatic int nv = 0;
        for (int a = 0; a < 4; a++) for (int b = 0; b < 2; b++) if (u_dc.st[a][b] != 2'd0) nv++;
        if (nv != 0) begin e_tb++; $display("[%0t] ERROR: sweep: %0d lines still valid in L1D at the reset point", $time, nv); end
      end
      // the DCache control logic (reset now) must be empty: the real state, not its flags; and the L1D buffers
      if (dc_busy_true) begin e_tb++; $display("[%0t] ERROR: DCache control logic busy at the reset point", $time); end
      if (!bufb_empty || !bufc_empty) begin e_tb++; $display("[%0t] ERROR: a message in the L1D buffer (B %0d, C %0d) at the reset point", $time, !bufb_empty, !bufc_empty); end
      check_lines("reset point");
    end
    // the core leaves reset: KEEP: L1D still holds its lines and still matches L2; sweep: L1D is empty
    if (!sys_rst && !core_rst && core_rst_q && !meta_rst) begin
      automatic int nv = 0;
      for (int a = 0; a < 4; a++) for (int b = 0; b < 2; b++) if (u_dc.st[a][b] != 2'd0) nv++;
      n_warm <= n_warm + nv;
      if (!KEEP && nv != 0) begin e_tb++; $display("[%0t] ERROR: %0d lines still valid in L1D after the core reset (sweep)", $time, nv); end
      check_lines("after reset");
    end
    // every load hit returns the current value of the line
    if (!sys_rst && !core_rst && lh_v && lh_data != golden[lh_addr]) begin
      e_tb++; $display("[%0t] ERROR: load of line %0d returned %h, golden %h", $time, lh_addr, lh_data, golden[lh_addr]);
    end
  end

  int trace_addr = -1;
  initial if (!$value$plusargs("TRACE=%d", trace_addr)) trace_addr = -1;
  always_ff @(posedge clk) if (trace_addr >= 0 && !sys_rst) begin
    if (gold_we && gold_addr == trace_addr) $display("[%0t] T store %h (core_rst=%0d)", $time, gold_data, core_rst);
    if (gold_we2 && gold_addr2 == trace_addr) $display("[%0t] T store@refill %h", $time, gold_data2);
    if (lc_v && lc_r && lc_addr == trace_addr) $display("[%0t] T C op%0d param%0d data %h", $time, lc_op, lc_par, lc_dat);
    if (lb_v && lb_r && lb_addr == trace_addr) $display("[%0t] T Probe param%0d", $time, lb_par);
    if (la_v && la_r && la_addr == trace_addr) $display("[%0t] T Acquire grow%0d", $time, la_par);
    if (ld_v && ld_r && u_l2.d_isgnt && u_l2.acq_addr == trace_addr) $display("[%0t] T GrantData cap%0d data %h", $time, ld_par, ld_dat);
    if (core_rst && !core_rst_q) $display("[%0t] T core reset (ctl=%0d)", $time, ctl_core_reset);
  end

  // waveform: +VCD (needs a --trace build: TRACE_BUILD=1 scripts/run.sh ...), optionally only the cycles
  // +VCD_FROM=.. +VCD_TO=.. into +VCD_FILE=..
  longint cyc_tb = 0; always_ff @(posedge clk) cyc_tb <= cyc_tb + 1;
  int vcd_from, vcd_to; string vcd_file;
  initial if ($test$plusargs("VCD")) begin
    if (!$value$plusargs("VCD_FROM=%d", vcd_from)) vcd_from = 0;
    if (!$value$plusargs("VCD_TO=%d", vcd_to)) vcd_to = 2000000000;
    if (!$value$plusargs("VCD_FILE=%s", vcd_file)) vcd_file = "build/wave.vcd";
    $dumpfile(vcd_file); $dumpvars(0, cr_tb);
    if (vcd_from > 0) $dumpoff;
  end
  always @(posedge clk) if ($test$plusargs("VCD")) begin
    if (vcd_from > 0 && cyc_tb == longint'(vcd_from)) $dumpon;
    if (cyc_tb == longint'(vcd_to)) begin $dumpoff; $finish; end
  end
  // for the waveforms: open transactions (txmon), state of the line of a directed Probe, line counts
  int mon_nopen; always_comb mon_nopen = u_mon.n_open();
  int tgt_addr = 0; logic [1:0] tgt_l1, tgt_dir; logic tgt_l2_current;
  logic [3:0] n_l1_lines, n_dir_lines;   // valid lines in L1D, lines L2's directory lists for L1D
  always_comb begin
    n_l1_lines = 0; n_dir_lines = 0;
    for (int a = 0; a < 4; a++) for (int b = 0; b < 2; b++) if (u_dc.st[a][b] != 2'd0) n_l1_lines++;
    for (int i = 0; i < 16; i++) if (dir[i] != 2'd0) n_dir_lines++;
  end
  always_comb begin tgt_l1 = l1st[tgt_addr]; tgt_dir = dir[tgt_addr]; tgt_l2_current = mem[tgt_addr] == golden_now[tgt_addr]; end

  task automatic cycles(input int n); repeat (n) @(posedge clk); endtask
  task automatic wait_for(input string what, input int maxc, ref logic sig, input logic val);
    int i = 0;
    while (sig !== val) begin @(posedge clk); i++; if (i > maxc) begin $display("[%0t] TIMEOUT waiting for %s", $time, what); $finish; end end
  endtask

  // one request: exactly one core reset
  task automatic check_resets(input int n0);
    if (n_resets - n0 != 1) begin
      e_tb++; $display("[%0t] ERROR: %0d core resets for one request", $time, n_resets - n0);
    end
  endtask
  task automatic core_reset(input int hold);
    int n0 = n_resets;
    req_task = 1;
    fork
      begin cycles(hold); req_task = 0; end
      begin wait_for("core reset", 20000, in_reset, 1'b1); end
    join
    wait_for("sequence end", 30000, busy, 1'b0);
    check_resets(n0);
  endtask

  // ---------------- SCEN=5: start the procedure while a transaction of class c is in flight ----------------
  int n_trig_hit [13], n_trig_miss [13];
  task automatic core_reset_on(input int c);
    int n0 = n_resets; int i = 0;
    trig_sel = c; trig_arm = 1;
    while (busy !== 1'b1 && i < 30000) begin @(posedge clk); i++; end
    trig_arm = 0;
    if (busy !== 1'b1) begin n_trig_miss[c]++; core_reset(1); return; end
    n_trig_hit[c]++;
    $display("#PROC %0d C%0d start-cycle=%0d open-at-start=%b n=%0d", n_resets, c, cyc_tb, u_mon.start_cls, u_mon.start_nopen);
    wait_for("core reset", 20000, in_reset, 1'b1);
    wait_for("sequence end", 20000, busy, 1'b0);
    check_resets(n0);
  endtask

  // ---------------- SCEN=6: directed Probes of L1D lines ----------------
  //   when: 0 offered while the core is in reset, 1 in sRelease, 2 right after the sequence, 3 at the start of
  //         sFlush, 4 in the first cycle of sDrain, 5 in the last cycle of sFlush
  //   kind: 3 dirty, 2 clean T, 1 B
  localparam int NWHEN = 6;
  localparam string WNAME [NWHEN] = '{"offered in sReset", "offered in sRelease", "right after the sequence",
                                      "start of sFlush", "first cycle of sDrain", "last cycle of sFlush"};
  int n_dir [NWHEN][4][3];      // [when][kind][cap] completed and checked
  int n_dir_skip, n_dir_stale_l2;
  int n_d3_flush, n_d3_later, n_d4_drain, n_d4_later, n_d5_last, n_d5_later;
  task automatic quiet_env();
    int i = 0;
    traffic_en = 0; snoop_en = 0;
    // the DCache (with MainPipe: a store may still wait in s3) and its buffers must be empty too, else the
    // reference value of a line is taken while a store to it is still on its way
    while ((l2_busy || u_l2.prb_v || dc_busy_true || db_v || cc_v) && i < 20000) begin @(posedge clk); i++; end
    cycles(20);
  endtask
  function automatic int pick_line(input logic [1:0] want);
    int off = $urandom_range(0, 15);
    for (int k = 0; k < 16; k++) if (l1st[(k + off) % 16] == want) return (k + off) % 16;
    return -1;
  endfunction
  // ProbeAck of every line, latched (a held Probe may be answered before the scenario starts waiting)
  int n_ack [16]; logic ack_data [16]; logic [31:0] ack_val [16]; logic [2:0] ack_par [16]; longint ack_t [16];
  always_ff @(posedge clk) if (sb_ack_v) begin
    n_ack[sb_ack_addr] <= n_ack[sb_ack_addr] + 1; ack_data[sb_ack_addr] <= sb_ack_data; ack_val[sb_ack_addr] <= sb_ack_val;
    ack_par[sb_ack_addr] <= sb_ack_param; ack_t[sb_ack_addr] <= cyc_tb;
  end
  // the gate took a Probe in the last cycle of sFlush (case 5)
  longint take_flush_t = -10; logic last_flush_take;
  always_ff @(posedge clk) begin
    if (!sys_rst && lb_v && lb_r && s_flush) take_flush_t <= cyc_tb;
    if (!sys_rst && s_drain && st_q == S_FLUSH) last_flush_take <= take_flush_t == cyc_tb - 1;
  end
  // forced snoop: wait until L2 has started it; snp_l2only = L2 served it alone (its directory lists no copy)
  logic snp_l2only; longint snp_start_t;
  task automatic issue_snoop(input int addr, input logic [1:0] cap, input int maxc = 20000);
    int i = 0;
    fsnp_addr = 4'(addr); fsnp_param = cap; fsnp_req = 1; snp_start_t = -1;
    while (fsnp_ack !== 1'b1 && i < maxc) begin @(posedge clk); i++; end
    snp_l2only = fsnp_l2only; snp_start_t = cyc_tb;
    fsnp_req = 0;
    if (i >= maxc) begin e_tb++; $display("[%0t] TIMEOUT: L2 could not start a snoop of line %0d (previous Probe not answered)", $time, addr); finish(0); end
  endtask
  // snoop started by the trigger fsnp_arm (cases 3, 4, 5)
  task automatic arm_snoop(input int addr, input logic [1:0] cap, input int arm);
    fsnp_addr = 4'(addr); fsnp_param = cap; fsnp_arm = arm; snp_start_t = -1;
  endtask
  task automatic wait_armed_snoop();
    int i = 0;
    while (fsnp_ack !== 1'b1 && i < 20000) begin @(posedge clk); i++; end
    snp_l2only = fsnp_l2only; snp_start_t = cyc_tb;
    fsnp_arm = 0;
  endtask
  int n_dir_swept, n_dir_swept_data;
  task automatic directed_probe(input int when_, input int kind, input logic [1:0] cap);
    int addr = -1, i = 0, a0, n0 = n_resets; logic [31:0] expv, expv_l2; logic [1:0] st0; logic l2_stale; longint t_drop = 0;
    for (int tries = 0; tries < 12 && addr < 0; tries++) begin
      traffic_en = 1; snoop_en = 1; cycles($urandom_range(800, 2000));
      quiet_env();
      addr = pick_line(2'(kind));
    end
    if (addr < 0) begin n_dir_skip++; return; end
    expv = golden[addr]; expv_l2 = mem[addr]; st0 = l1st[addr]; l2_stale = mem[addr] != expv; tgt_addr = addr; a0 = n_ack[addr];
    $display("#DIR %0d when=%0d kind=%0d cap=%0d line=%0d start-cycle=%0d", n_resets, when_, kind, cap, addr, cyc_tb);
    if (kind == 3 && l2_stale) n_dir_stale_l2++;
    case (when_)
      0: begin   // the core is held in reset while the Probe arrives
        req_task = 1;
        wait_for("core reset", 20000, in_reset, 1'b1);
        cycles($urandom_range(1, 10));
        fork issue_snoop(addr, cap); join_none
        cycles($urandom_range(20, 300));
        req_task = 0; t_drop = cyc_tb;
      end
      1: begin   // the core has left reset, the gates are not open yet
        req_task = 1; wait_for("core reset", 20000, in_reset, 1'b1); req_task = 0;
        while (!(probe_closed && !in_reset)) @(posedge clk);
        issue_snoop(addr, cap);
      end
      2: begin   // right after the sequence
        req_task = 1; wait_for("core reset", 20000, in_reset, 1'b1); req_task = 0;
        wait_for("sequence end", 20000, busy, 1'b0);
        // KEEP: the line is still in L1D with its state and data (hot); sweep: L1D is empty
        if (l1st[addr] != (KEEP ? st0 : 2'd0)) begin e_tb++; $display("[%0t] ERROR: line %0d state %0d before the reset, %0d after", $time, addr, st0, l1st[addr]); end
        issue_snoop(addr, cap);
      end
      3, 4, 5: begin   // started by a trigger at the start of sFlush / at the end of sFlush
        arm_snoop(addr, cap, when_);
        cycles(1);
        req_task = 1;
        wait_armed_snoop();
        cycles(2); req_task = 0;
      end
    endcase
    // the ProbeAck of this line
    i = 0;
    while (n_ack[addr] == a0 && i < 20000) begin @(posedge clk); i++; end
    if (i >= 20000) begin e_tb++; $display("[%0t] ERROR: no ProbeAck for the directed Probe of line %0d (%s)", $time, addr, WNAME[when_]); end
    else begin
      automatic int ph = u_sb.pr_ph[addr];
      // answered by L1D: KEEP always (before the reset or by the hot L1D after it); sweep only in sFlush,
      // before the sweep reached the line. Otherwise (sweep) the line was released before: ProbeAck NtoN, by the
      // gate while the core is in reset, by the empty DCache afterwards.
      if (KEEP) begin
        if (kind == 3 && !(ack_data[addr] && ack_val[addr] == expv)) begin
          e_tb++; $display("[%0t] ERROR: dirty line %0d (%s): ProbeAck%s %h, expected ProbeAckData %h", $time, addr, WNAME[when_], ack_data[addr] ? "Data" : "", ack_val[addr], expv);
        end
        if (kind != 3 && ack_data[addr]) begin e_tb++; $display("[%0t] ERROR: clean line %0d answered with data", $time, addr); end
        if (cap == 2'd1 && l1st[addr] != 2'd1) begin e_tb++; $display("[%0t] ERROR: line %0d not B in L1D after toB (state %0d)", $time, addr, l1st[addr]); end
      end else begin
        if (ph != 1 && (ack_data[addr] || ack_par[addr] != 3'd5)) begin
          e_tb++; $display("[%0t] ERROR: swept line %0d (%s, phase %0d): ProbeAck%s param %0d, expected ProbeAck NtoN", $time, addr, WNAME[when_], ph, ack_data[addr] ? "Data" : "", ack_par[addr]);
        end
        if (ack_data[addr] && ack_val[addr] != expv) begin
          e_tb++; $display("[%0t] ERROR: line %0d in sFlush: ProbeAckData %h, expected %h", $time, addr, ack_val[addr], expv);
        end
        n_dir_swept++; if (expv != expv_l2) n_dir_swept_data++;
      end
      if (mem[addr] != expv) begin e_tb++; $display("[%0t] ERROR: L2 holds %h for line %0d after the Probe, expected %h", $time, mem[addr], addr, expv); end
      if (cap == 2'd2 && l1st[addr] != 2'd0) begin e_tb++; $display("[%0t] ERROR: line %0d still in L1D after toN", $time, addr); end
      // KEEP: a Probe offered in sReset waits until the request dropped and the core is out of reset
      if (KEEP && when_ == 0 && ack_t[addr] <= t_drop) begin
        e_tb++; $display("[%0t] ERROR: line %0d answered at cycle %0d, the request dropped at %0d", $time, addr, ack_t[addr], t_drop);
      end
      // the Probe really was offered in the intended phase (0 idle 1 sFlush 2 sDrain 3 sReset 4 sRelease);
      // the cases started by a trigger are counted (hit / later), the phase is checked above
      if ((when_ == 0 && ph != 3) || (when_ == 1 && ph != 4) || (when_ == 2 && ph != 0)) begin
        e_tb++; $display("[%0t] ERROR: directed Probe of line %0d offered in phase %0d, intended: %s", $time, addr, ph, WNAME[when_]);
      end
      if (when_ == 3) begin if (ph == 1) n_d3_flush++; else n_d3_later++; end
      if (when_ == 4) begin if (ph == 2) n_d4_drain++; else n_d4_later++; end
      if (when_ == 5) begin if (ph == 1 && last_flush_take) n_d5_last++; else n_d5_later++; end
      n_dir[when_][kind][cap == 2'd1 ? 1 : 2]++;
    end
    while (req_task) @(posedge clk);
    wait_for("sequence end", 20000, busy, 1'b0);
    check_resets(n0);
    // loads of the remaining lines are checked against the golden memory (no snoops)
    traffic_en = 1; cycles($urandom_range(200, 600));
  endtask
  // ---------------- SCEN=7: a debug reset held for a long time ----------------
  // ndmreset / hartreset held by a debugger: random HN snoops go on, and the scenario snoops lines as a
  // system bus access of the debugger would.
  //   KEEP  : the core is in reset: one snoop of a kept line, its Probe waits in L2 until the request drops,
  //           then L1D answers with its data
  //   sweep : lines that L1D released (L2 lists none of them): the Probe, sent anyway, is answered NtoN at once
  //           by the gate, L2 holds the data
  int n_dbg, n_dbg_snoops, n_dbg_dirty, max_dbg_ack, n_dbg_l2only, n_dbg_waited, max_dbg_wait, n_dbg_hot, n_dbg_race;
  logic held_at_rp [16];   // L1D held the line at the last reset point (sweep: it was released before)
  logic swept_line [16];   // the line was released during the current quiesce
  always_ff @(posedge clk) if (rp_now) for (int i = 0; i < 16; i++) held_at_rp[i] <= swept_line[i];
  always_ff @(posedge clk)
    for (int i = 0; i < 16; i++)
      if (sys_rst || (ctl_st == S_IDLE && !req)) swept_line[i] <= 1'b0;
      else if (lc_v && lc_r && u_g0.c_first && (lc_op == 3'd6 || lc_op == 3'd7) && lc_addr == 4'(i)) swept_line[i] <= 1'b1;
  function automatic int pick_swept();
    int off = $urandom_range(0, 15);
    for (int k = 0; k < 16; k++) if (held_at_rp[(k + off) % 16]) return (k + off) % 16;
    return -1;
  endfunction
  task automatic debug_hold(input int len);
    int n0 = n_resets; longint t_end, t_drop; int i;
    int p_addr = -1, p_a0 = 0; logic [31:0] p_exp; logic p_dirty;
    traffic_en = 1; snoop_en = 1; cycles($urandom_range(500, 1500));
    req_task = 1;
    wait_for("core reset", 20000, in_reset, 1'b1);
    t_end = cyc_tb + len;
    while (cyc_tb < t_end) begin
      automatic int addr = -1;
      if (KEEP) begin
        addr = pick_line(2'd3);
        if (addr < 0) addr = pick_line(2'd2);
        if (addr < 0) addr = pick_line(2'd1);
      end else begin
        addr = pick_swept();
        if (addr < 0) addr = $urandom_range(0, 15);
      end
      if (addr >= 0) begin
        automatic logic [31:0] expv = golden[addr];
        automatic logic dirty = l1st[addr] == 2'd3;
        automatic logic [1:0] cap = (l1st[addr] >= 2'd2 && $urandom_range(0, 1)) ? 2'd1 : 2'd2;
        automatic longint t0;
        automatic int a0 = n_ack[addr];
        if (KEEP) begin
          // one Probe per hold: it waits in L2 for the whole reset (the HN snoop behind it too)
          if (p_addr < 0) begin
            p_addr = addr; p_a0 = a0; p_exp = expv; p_dirty = dirty;
            fork issue_snoop(addr, cap, len + 40000); join_none
            n_dbg_snoops++; if (dirty) n_dbg_dirty++;
          end
        end else begin
          issue_snoop(addr, cap);
          if (snp_l2only) n_dbg_l2only++;
          else begin
            t0 = cyc_tb; i = 0;
            while (n_ack[addr] == a0 && i < 20000) begin @(posedge clk); i++; end
            if (int'(cyc_tb - t0) > max_dbg_ack) max_dbg_ack = int'(cyc_tb - t0);
            if (i >= 20000) begin e_tb++; $display("[%0t] ERROR: snoop of line %0d during the debug hold not answered", $time, addr); end
            else if (ack_data[addr] || ack_par[addr] != 3'd5 || mem[addr] != expv) begin
              e_tb++; $display("[%0t] ERROR: snoop of swept line %0d during the hold: ProbeAck%s param %0d, L2 %h, expected NtoN and %h", $time, addr, ack_data[addr] ? "Data" : "", ack_par[addr], mem[addr], expv);
            end
            n_dbg_snoops++; if (dirty) n_dbg_dirty++;
          end
        end
      end
      cycles($urandom_range(30, 600));
    end
    if (ctl_st != S_RESET) begin e_tb++; $display("[%0t] ERROR: debug hold: controller left sReset while the request is high", $time); end
    if (KEEP && p_addr >= 0 && n_ack[p_addr] != p_a0) begin
      e_tb++; $display("[%0t] ERROR: line %0d answered while the core is held in reset", $time, p_addr);
    end
    req_task = 0; t_drop = cyc_tb;
    if (KEEP && p_addr >= 0) begin
      // the snoop starts in L2 during the reset, unless a random HN snoop held there was first: then it
      // starts after the release and the core may have changed the line meanwhile (only L2's data is checked)
      i = 0;
      while ((snp_start_t < 0 || !snp_l2only && n_ack[p_addr] == p_a0) && i < 20000) begin @(posedge clk); i++; end
      if (i >= 20000) begin e_tb++; $display("[%0t] ERROR: the Probe of line %0d held during the reset is never answered", $time, p_addr); end
      else if (snp_start_t <= t_drop) begin
        // the held Probe reaches L1D when the gates open, together with the first requests of the core: an
        // eviction of the line may be queued just before it, then the data goes to L2 by ReleaseData and the
        // Probe gets NtoN. Either way L2 must hold the current value afterwards.
        cycles(4);
        if (ack_data[p_addr] && ack_val[p_addr] != golden[p_addr] && ack_val[p_addr] != p_exp) begin
          e_tb++; $display("[%0t] ERROR: line %0d after the reset: ProbeAckData %h, expected %h", $time, p_addr, ack_val[p_addr], p_exp);
        end
        if (l1st[p_addr] != 2'd3 && mem[p_addr] != golden[p_addr]) begin
          e_tb++; $display("[%0t] ERROR: line %0d after the reset: L2 %h, current value %h", $time, p_addr, mem[p_addr], golden[p_addr]);
        end
        if (p_dirty && ack_data[p_addr] && ack_val[p_addr] == p_exp) n_dbg_hot++; else n_dbg_race++;
        n_dbg_waited++; if (int'(cyc_tb - t_drop) > max_dbg_wait) max_dbg_wait = int'(cyc_tb - t_drop);
      end else begin
        cycles(4);
        if (mem[p_addr] != golden[p_addr] && l1st[p_addr] != 2'd3) begin
          e_tb++; $display("[%0t] ERROR: line %0d after a late snoop: L2 %h, current value %h", $time, p_addr, mem[p_addr], golden[p_addr]);
        end
      end
    end
    wait_for("sequence end", 20000, busy, 1'b0);
    check_resets(n0);
    n_dbg++;
  endtask

  task automatic finish(input bit expect_errors);
    traffic_en = 0; snoop_en = 0;
    cycles(2000);
    // global consistency: a line dirty in the DCache holds the golden value, otherwise L2 does
    for (int i = 0; i < 16; i++) begin
      automatic logic in_dc = 1'b0;
      for (int w = 0; w < 2; w++)
        if (u_dc.st[i[1:0]][w] == 2'd3 && u_dc.tg[i[1:0]][w] == i[3:2]) begin
          in_dc = 1'b1;
          if (u_dc.dat[i[1:0]][w] != golden[i]) begin e_tb++; $display("ERROR: DCache line %0d %h != golden %h", i, u_dc.dat[i[1:0]][w], golden[i]); end
        end
      if (!in_dc && mem[i] != golden[i]) begin e_tb++; $display("ERROR: final L2 line %0d %h != golden %h", i, mem[i], golden[i]); end
    end
    if (l2_busy) begin e_tb++; $display("ERROR: L2 still has core transactions outstanding at the end (hung)"); end
    if (u_ul.busy[0] || u_ul.busy[1] || u_ul2.busy[0] || u_ul2.busy[1] || !xb_empty || !iso_quiet) begin
      e_tb++; $display("ERROR: an uncached request is still waiting for its response at the end (hung)");
    end
    if (u_mon.n_open() != 0) begin e_tb++; $display("ERROR: txmon: %0d transactions still open at the end", u_mon.n_open()); end
    u_mon.report(); u_sb.report();
    $display("drain: sDrain-phases=%0d longest-sDrain=%0d probes-held-in-sDrain=%0d get-probes=%0d", n_drain, max_drain, n_held_drain, n_get_probe);
    if (scen == 5) begin
      $write("triggers hit:"); for (int c = 1; c <= 12; c++) $write(" C%0d=%0d", c, n_trig_hit[c]); $display("");
      $write("triggers missed:"); for (int c = 1; c <= 12; c++) $write(" C%0d=%0d", c, n_trig_miss[c]); $display("");
    end
    if (scen == 7)
      $display("debug-hold: holds=%0d snoops-during-hold=%0d (dirty %0d) longest-snoop-to-ProbeAck=%0d served-by-L2-alone=%0d waited-for-the-release=%0d longest-after-release=%0d data-from-hot-L1D=%0d crossed-an-eviction=%0d",
               n_dbg, n_dbg_snoops, n_dbg_dirty, max_dbg_ack, n_dbg_l2only, n_dbg_waited, max_dbg_wait, n_dbg_hot, n_dbg_race);
    if (scen == 6) begin
      for (int w = 0; w < NWHEN; w++)
        $display("directed %-26s dirty toN=%0d toB=%0d | clean-T toN=%0d toB=%0d | B toN=%0d", WNAME[w],
                 n_dir[w][3][2], n_dir[w][3][1], n_dir[w][2][2], n_dir[w][2][1], n_dir[w][1][2]);
      $display("directed: start-of-sFlush offered-in-sFlush=%0d later=%0d", n_d3_flush, n_d3_later);
      $display("directed: first-cycle-of-sDrain offered-in-sDrain=%0d transition-later=%0d", n_d4_drain, n_d4_later);
      $display("directed: last-cycle-of-sFlush offered-in-sFlush=%0d later=%0d", n_d5_last, n_d5_later);
      $display("directed: dirty lines whose L2 copy was stale before the Probe=%0d, skipped=%0d, swept-lines-probed=%0d (of them dirty before the sweep %0d)",
               n_dir_stale_l2, n_dir_skip, n_dir_swept, n_dir_swept_data);
    end
    e_tb += e_mon + e_sb;
    $display("config: KEEP=%0d SWEEP=%0d RST_CYCLES=%0d", KEEP, !KEEP, RST_CYCLES);
    $display("final: resets=%0d reset-points=%0d dcache-ops=%0d ul-ops=%0d icachectrl-ops=%0d probes=%0d spurious-probes=%0d snoops-served-by-L2-alone=%0d acquire-perm=%0d releases-during-quiesce=%0d (with data %0d) lines-kept=%0d probes-held=%0d probes-answered-by-gate=%0d errors=%0d",
             n_resets, n_rp, n_dc_acc + n_dc, n_ul_acc + n_ul, n_ul2_acc + n_ul2, n_probe, n_spur, n_l2only, n_perm,
             n_swept, n_swept_dirty, n_warm, n_held, n_gate_ack, e_tb);
    if (!expect_errors) begin
      if (e_tb == 0 && n_dc_acc + n_dc > 200 && n_ul_acc + n_ul > 20 && n_ul2_acc + n_ul2 > 20 && (KEEP ? n_warm > 0 : n_swept > 0))
        $display("RESULT: PASS"); else $display("RESULT: FAIL");
    end else begin
      if (e_tb != 0) $display("RESULT: PASS (problem reproduced, as expected)"); else $display("RESULT: FAIL (no error observed)");
    end
    $finish;
  endtask

  int scen, seed;
  initial begin
    if (!$value$plusargs("SCEN=%d", scen)) scen = 1;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    void'($urandom(seed));
    slow_en = $test$plusargs("SLOW") || scen >= 5;
    $display("=== core-only reset v5: scenario %0d, seed %0d, slow %0d, KEEP %0d (sweep %0d), rstCycles %0d ===", scen, seed, slow_en, KEEP, !KEEP, RST_CYCLES);
    sys_rst = 1; traffic_en = 0; snoop_en = 0; req_task = 0; force_core_rst = 0; spur_en = !$test$plusargs("NOSPUR");
    trig_arm = 0; trig_sel = 0; fsnp_req = 0; fsnp_arm = 0; fsnp_addr = 0; fsnp_param = 0;
    cycles(5); sys_rst = 0; cycles(5);
    traffic_en = 1; snoop_en = 1;
    cycles(3000);
    case (scen)
      1: begin for (int k = 0; k < 3; k++) begin core_reset(1); cycles(3000); end finish(0); end
      2: begin for (int k = 0; k < 12; k++) begin core_reset(1); cycles($urandom_range(0, 400)); end cycles(2000); finish(0); end
      3: begin for (int k = 0; k < 4; k++) begin core_reset($urandom_range(2, 2000)); cycles(2000); end finish(0); end
      5: begin
        for (int r = 0; r < 3; r++) for (int c = 1; c <= 12; c++) begin core_reset_on(c); cycles($urandom_range(50, 600)); end
        finish(0);
      end
      6: begin
        for (int r = 0; r < 2; r++)
          for (int w = 0; w < NWHEN; w++)
            for (int k = 1; k <= 3; k++)
              for (int c = 1; c <= 2; c++)
                if (!(k == 1 && c == 1)) directed_probe(w, k, 2'(c));   // toB is not sent to a B copy
        finish(0);
      end
      7: begin
        for (int k = 0; k < 4; k++) begin debug_hold($urandom_range(2000, 20000)); cycles($urandom_range(100, 2000)); end
        finish(0);
      end
      4: begin
        for (int k = 0; k < 3; k++) begin
          force_core_rst = 1; cycles(20); force_core_rst = 0; cycles(2000);
        end
        finish(1);
      end
      default: begin $display("unknown scenario"); $finish; end
    endcase
  end
endmodule
