// ============================================================================
// Formal harness (v6): TLQuiesceGate (TL-C edge of the DCache and two early TL-UL edges) + TLResetIsolation
// (the ICache control registers: core MMIO -> gate -> TLResetIsolation -> manager in the core) + CoreResetCtrl
// (six states: sIdle, sQuiesce, sDrain, sIso, sReset, sRelease; level reset), with an unconstrained environment
// that only obeys TileLink and the DCache drain rule. Models: ../model/cr_ctl_models.sv, one-to-one with
// CoreReset.scala; spec: core-reset/verification/TESTPLAN.md section 2.2, core-reset/DESIGN.md section 2.
// Configurations (defines): FULL by default (KEEP = 0: L1D reset with the core, Probes answered by the gate while
// the core is in reset); CFG_KEEP (KEEP = 1: L1D kept, Probes held in L2); RST16 (rstCycles = 16 instead of 100,
// for the bounded runs); ISO2 (isoCycles = 2). Run with -DFORMAL (drops the models' $error).
//
// Gates: g0 (TL-C, DCache) is blocked by gate_block (from sDrain); g1 (UL client) and g2 (core MMIO to the ICache
// control registers) are "early": blocked by early_block (from sQuiesce). early_quiet = quiet1 && quiet2;
// gates_quiet = quiet0 && quiet1 && quiet2 && iso_quiet.
//
// Environment (assumptions A1..A14 of TESTPLAN 2.2; each is no stronger than a guarantee of the design):
//   A1  opcodes: L2 on D: Grant, GrantData, ReleaseAck, CBOAck (code 2); UL D: AccessAck(Data); core (outside the
//       freedom window): A AcquireBlock / AcquirePerm / CBO (code 5), C ProbeAck(Data) / Release(Data), UL A PutFull / Get
//   A2  the beats of one message keep the opcode (TileLink 4.1)
//   A3  a response only to an open request (Grant <-> Acquire, CBOAck <-> CBO, ReleaseAck <-> Release,
//       AccessAck <-> Get / Put, GrantAck <-> Grant, ProbeAck <-> Probe)
//   A4  at most 5 open transactions of each kind (finite source IDs)
//   A5  freedom window core_free = !rst && (sIso || sReset): EVERY output of the core is unconstrained in every
//       cycle (TL, l1_done, l1_idle, alive, fe_any). sReset: the asynchronous assertion of the core reset (RDC);
//       sIso: the core is alive but isolated, allowing everything is weaker than reality, so the proof is stronger
//   A6  in the core reset outside the window (tile reset, sRelease while the synchroniser holds): valid 0,
//       alive 0, done 0; idle stays free
//   A7  the frontend leaves reset 2 cycles after the rest of the core; the controller's core_in_reset is fe_any
//       in the window, else fe_rst
//   A8  the DCache starts no Release outside sIdle / sQuiesce (DCacheImp assert "Release started after the drain
//       reported done", checked by the RTL test K3 and by S19)
//   A10 l1_done -> (l1_req || l1_req_q) (DCacheQuiesceUnit: sDone needs req in the previous cycle; FakeDCache:
//       done := req in the same cycle)
//   A11 alive = 0 in reset, rises not later than 6 cycles after the synchroniser releases, then stays
//   A12 before the first sequence the core runs (alive = 1)
//   A13 req, the Probe offered by L2, every ready: free; NO stability assumption on valid (TileLink 4.1 lets a
//       sender retract an unaccepted beat)
//   A14 l1_idle is free in every cycle (a flag of the current cycle, promises nothing)
// Reference trackers below count transactions independently of the gate's own counters: A, D, E on the
// L2 side; Probes and C messages on the core side (a Probe that the gate answers itself never reaches the
// core: it is tracked apart, from the L2 side).
//
// Properties (assert), numbers of v5 kept where the meaning is the same:
//   P1  in sIso and sReset nothing is outstanding across the boundary and no message is half transferred
//   P2  in sIso, sReset and sRelease nothing crosses the boundary on any channel
//   P3  a Probe is never offered to the core while it is in reset, isolated, or before the gates open
//   P4  a multi-beat message on A is never cut by the gate
//   P5  the gates report quiet only when nothing is outstanding
//   P6  the core reset is asserted only in sReset, inReset = coreReset
//   P7  a Probe reaches the DCache only after it reports alive (its ProbeQueue is out of reset)
//   P8  channel B is closed (held or answered) only in the procedure (sDrain .. sRelease); P8B after the
//       request dropped it is closed for a bounded time outside sDrain
//   P8N FULL: Probes are held exactly in sDrain and sIso; while the gate answers, a Probe offered is taken at
//       once unless the previous ProbeAck is still pending, and a pending ProbeAck is always offered to L2
//   P9  once the sequence started, no new request of an early gate (non-coherent agents) crosses on A
//   P10 in sDrain the non-coherent agents are quiet
//   P11 hartIsInReset == busy == !sIdle
//   P12 the gate's own answers: one Probe at a time, exactly one ProbeAck NtoN, never in the middle of a C
//       message of the core, only without KEEP, only in sReset / sRelease
//   P13 the core leaves reset only after the request dropped
//   P14 every core reset lasts at least rstCycles (TileLink 1.9.3 3.2.2: 100 cycles with valid low)
//   P15 isolation: while isolate is high no signal on the tile side of a gate or of TLResetIsolation depends
//       on the core, and nothing is offered to the core
//   P16 the isolation covers the core reset (asserted and in its synchroniser); isolate == sIso | sReset | sRelease
//   P17 channel B is held or answered whenever the core is isolated
//   P18 channel B is held from the first cycle of sDrain
//   P19 the isolation starts (decision of sDrain) only after l1.done, l1.idle and all quiet in the decision cycle
//   P20 the core runs again (sIdle after sRelease) only when the frontend is out of reset
//   P21 the core reset rises only after isolate stood for isoCycles cycles (R3)
//   P22 isolate falls only after sRelease with alive and the frontend out of reset a cycle earlier (R4)
//   P23 l1.req == sQuiesce | sDrain | sIso
//   P24 l1.freeze == (KEEP && isolate)
//   P25 busy does not drop between two sequences; it falls only from sRelease with the request low
// Covers C1..C14 (non-vacuity), see the end of the file.
// ============================================================================
module fv_boundary #(
`ifdef CFG_KEEP
  parameter bit KEEP = 1,
`else
  parameter bit KEEP = 0,
`endif
`ifdef RST16
  parameter int RST = 16,
`else
  parameter int RST = 100,
`endif
`ifdef ISO2
  parameter int ISO = 2
`else
  parameter int ISO = 1
`endif
) (
  input logic clk,
  input logic req, l1_done, l1_idle, alive, fe_any,
  // gate 0 (DCache, TL-C) core side
  input logic c_a_v, input logic [2:0] c_a_op,
  input logic c_b_r,
  input logic c_c_v, input logic [2:0] c_c_op,
  input logic c_d_r,
  input logic c_e_v,
  // gate 0 L2 side
  input logic l_a_r,
  input logic l_b_v,
  input logic l_c_r,
  input logic l_d_v, input logic [2:0] l_d_op,
  input logic l_e_r,
  // gate 1 (uncached, TL-UL)
  input logic u_a_v, input logic [2:0] u_a_op, input logic u_d_r,
  input logic m_a_r, input logic m_d_v, input logic [2:0] m_d_op,
  // gate 2 + TLResetIsolation: core MMIO client (v) -> ICache control registers in the core (k)
  input logic v_a_v, input logic [2:0] v_a_op, input logic v_d_r,
  input logic k_a_r, input logic k_d_v, input logic [2:0] k_d_op
);
  // ---------------- reset of the harness: first cycle only ----------------
  logic rst = 1'b1;
  always_ff @(posedge clk) rst <= 1'b0;

  // ---------------- DUT ----------------
  logic busy, in_reset, hart_in_reset, l1_req, l1_freeze, early_block, gate_block, hold_probe, ack_probe, core_reset; logic [2:0] st;
  logic core_in_reset;
  logic ack_pend0;
  logic quiet0, quiet1;
  // gate 0 wires
  logic c_a_r, c_b_v, c_c_r, c_d_v, c_e_r; logic [2:0] c_d_op;
  logic l_a_v, l_b_r, l_c_v, l_d_r, l_e_v; logic [2:0] l_a_op, l_c_op;
  logic [1:0] c_b_par, c_d_par; logic [3:0] c_b_addr, c_d_src, c_d_sink; logic [31:0] c_d_dat;
  logic [1:0] l_a_par; logic [3:0] l_a_src, l_a_addr, l_c_src, l_c_addr, l_e_sink; logic [2:0] l_c_par;
  logic [31:0] l_a_dat, l_c_dat;
  // gate 1 wires
  logic u_a_r, u_d_v, m_a_v, m_d_r; logic [2:0] u_d_op, m_a_op;
  logic [1:0] m_a_par, u_d_par; logic [3:0] m_a_src, m_a_addr, u_d_src, u_d_sink; logic [31:0] m_a_dat, u_d_dat;
  logic g1_ibv, g1_icr, g1_ier, g1_obr, g1_ocv, g1_oev; logic [1:0] g1_ibp; logic [3:0] g1_iba, g1_ocs, g1_oca, g1_oes;
  logic [2:0] g1_oco, g1_ocp; logic [31:0] g1_ocd;

  logic isolate;
  cr_gate #(1, "l1d") g0 (.clk, .rst, .block(gate_block), .hold_b(hold_probe), .ack_b(ack_probe), .quiet(quiet0),
    .ack_pend(ack_pend0), .isolate,
    .ia_valid(c_a_v), .ia_ready(c_a_r), .ia_op(c_a_op), .ia_param(2'd0), .ia_src(4'd1), .ia_addr(4'd0), .ia_data(32'd0),
    .ib_valid(c_b_v), .ib_ready(c_b_r), .ib_param(c_b_par), .ib_addr(c_b_addr),
    .ic_valid(c_c_v), .ic_ready(c_c_r), .ic_op(c_c_op), .ic_param(3'd0), .ic_src(4'd0), .ic_addr(4'd0), .ic_data(32'd0),
    .id_valid(c_d_v), .id_ready(c_d_r), .id_op(c_d_op), .id_param(c_d_par), .id_src(c_d_src), .id_sink(c_d_sink), .id_data(c_d_dat),
    .ie_valid(c_e_v), .ie_ready(c_e_r), .ie_sink(4'd0),
    .oa_valid(l_a_v), .oa_ready(l_a_r), .oa_op(l_a_op), .oa_param(l_a_par), .oa_src(l_a_src), .oa_addr(l_a_addr), .oa_data(l_a_dat),
    .ob_valid(l_b_v), .ob_ready(l_b_r), .ob_param(2'd2), .ob_addr(4'd0),
    .oc_valid(l_c_v), .oc_ready(l_c_r), .oc_op(l_c_op), .oc_param(l_c_par), .oc_src(l_c_src), .oc_addr(l_c_addr), .oc_data(l_c_dat),
    .od_valid(l_d_v), .od_ready(l_d_r), .od_op(l_d_op), .od_param(2'd0), .od_src(4'd1), .od_sink(4'd0), .od_data(32'd0),
    .oe_valid(l_e_v), .oe_ready(l_e_r), .oe_sink(l_e_sink));

  cr_gate #(0, "ul") g1 (.clk, .rst, .block(early_block), .hold_b(hold_probe), .ack_b(ack_probe), .quiet(quiet1),
    .ack_pend(), .isolate,
    .ia_valid(u_a_v), .ia_ready(u_a_r), .ia_op(u_a_op), .ia_param(2'd0), .ia_src(4'd0), .ia_addr(4'd0), .ia_data(32'd0),
    .ib_valid(g1_ibv), .ib_ready(1'b1), .ib_param(g1_ibp), .ib_addr(g1_iba),
    .ic_valid(1'b0), .ic_ready(g1_icr), .ic_op(3'd0), .ic_param(3'd0), .ic_src(4'd0), .ic_addr(4'd0), .ic_data(32'd0),
    .id_valid(u_d_v), .id_ready(u_d_r), .id_op(u_d_op), .id_param(u_d_par), .id_src(u_d_src), .id_sink(u_d_sink), .id_data(u_d_dat),
    .ie_valid(1'b0), .ie_ready(g1_ier), .ie_sink(4'd0),
    .oa_valid(m_a_v), .oa_ready(m_a_r), .oa_op(m_a_op), .oa_param(m_a_par), .oa_src(m_a_src), .oa_addr(m_a_addr), .oa_data(m_a_dat),
    .ob_valid(1'b0), .ob_ready(g1_obr), .ob_param(2'd0), .ob_addr(4'd0),
    .oc_valid(g1_ocv), .oc_ready(1'b1), .oc_op(g1_oco), .oc_param(g1_ocp), .oc_src(g1_ocs), .oc_addr(g1_oca), .oc_data(g1_ocd),
    .od_valid(m_d_v), .od_ready(m_d_r), .od_op(m_d_op), .od_param(2'd0), .od_src(4'd0), .od_sink(4'd0), .od_data(32'd0),
    .oe_valid(g1_oev), .oe_ready(1'b1), .oe_sink(g1_oes));

  // gate 2 (core MMIO to its ICache control registers) -> TLResetIsolation -> manager in the core
  logic quiet2, iso_quiet;
  logic v_a_r, v_d_v, w_a_v, w_a_r, w_d_v, w_d_r, k_a_v, k_d_r; logic [2:0] v_d_op, w_a_op, w_d_op, k_a_op;
  logic [1:0] w_a_par, v_d_par; logic [3:0] w_a_src, w_a_addr, w_d_src, k_a_src, k_a_addr, v_d_src, v_d_sink;
  logic [31:0] w_a_dat, w_d_dat, k_a_dat, v_d_dat;
  logic g2_ibv, g2_icr, g2_ier, g2_obr, g2_ocv, g2_oev; logic [1:0] g2_ibp; logic [3:0] g2_iba, g2_ocs, g2_oca, g2_oes;
  logic [2:0] g2_oco, g2_ocp; logic [31:0] g2_ocd;
  cr_gate #(0, "icachectrl_client") g2 (.clk, .rst, .block(early_block), .hold_b(hold_probe), .ack_b(ack_probe),
    .quiet(quiet2), .ack_pend(), .isolate,
    .ia_valid(v_a_v), .ia_ready(v_a_r), .ia_op(v_a_op), .ia_param(2'd0), .ia_src(4'd0), .ia_addr(4'd0), .ia_data(32'd0),
    .ib_valid(g2_ibv), .ib_ready(1'b1), .ib_param(g2_ibp), .ib_addr(g2_iba),
    .ic_valid(1'b0), .ic_ready(g2_icr), .ic_op(3'd0), .ic_param(3'd0), .ic_src(4'd0), .ic_addr(4'd0), .ic_data(32'd0),
    .id_valid(v_d_v), .id_ready(v_d_r), .id_op(v_d_op), .id_param(v_d_par), .id_src(v_d_src), .id_sink(v_d_sink), .id_data(v_d_dat),
    .ie_valid(1'b0), .ie_ready(g2_ier), .ie_sink(4'd0),
    .oa_valid(w_a_v), .oa_ready(w_a_r), .oa_op(w_a_op), .oa_param(w_a_par), .oa_src(w_a_src), .oa_addr(w_a_addr), .oa_data(w_a_dat),
    .ob_valid(1'b0), .ob_ready(g2_obr), .ob_param(2'd0), .ob_addr(4'd0),
    .oc_valid(g2_ocv), .oc_ready(1'b1), .oc_op(g2_oco), .oc_param(g2_ocp), .oc_src(g2_ocs), .oc_addr(g2_oca), .oc_data(g2_ocd),
    .od_valid(w_d_v), .od_ready(w_d_r), .od_op(w_d_op), .od_param(2'd0), .od_src(4'd0), .od_sink(4'd0), .od_data(w_d_dat),
    .oe_valid(g2_oev), .oe_ready(1'b1), .oe_sink(g2_oes));
  cr_iso #("icachectrl") iso (.clk, .rst, .isolate, .quiet(iso_quiet),
    .ia_valid(w_a_v), .ia_ready(w_a_r), .ia_op(w_a_op), .ia_src(w_a_src), .ia_addr(w_a_addr), .ia_data(w_a_dat),
    .id_valid(w_d_v), .id_ready(w_d_r), .id_op(w_d_op), .id_src(w_d_src), .id_data(w_d_dat),
    .oa_valid(k_a_v), .oa_ready(k_a_r), .oa_op(k_a_op), .oa_src(k_a_src), .oa_addr(k_a_addr), .oa_data(k_a_dat),
    .od_valid(k_d_v), .od_ready(k_d_r), .od_op(k_d_op), .od_src(4'd0), .od_data(32'd0));

  cr_ctrl #(.KEEP(KEEP), .RST_CYCLES(RST), .ISO_CYCLES(ISO)) u_ctl (.clk, .rst, .req, .busy, .in_reset, .hart_in_reset,
    .l1_req, .l1_freeze, .l1_done, .l1_idle, .l1_alive(alive), .core_in_reset,
    .early_block, .gate_block, .hold_probe, .ack_probe, .early_quiet(quiet1 && quiet2),
    .gates_quiet(quiet0 && quiet1 && quiet2 && iso_quiet), .isolate, .core_reset, .st);

  // controller state (st is an extra output of the model for the checkers); codes of TESTPLAN section 0
  wire s_idle = st == 3'd0, s_quiesce = st == 3'd1, s_drain = st == 3'd2, s_iso = st == 3'd3, s_reset = st == 3'd4, s_release = st == 3'd5;

  // core reset as in XSTile: asserted with coreReset, released through a 2-flop synchroniser
  logic cr_q1 = 1'b0, cr_q2 = 1'b0;
  always_ff @(posedge clk) begin
    if (rst) begin cr_q1 <= 1'b0; cr_q2 <= 1'b0; end
    else if (core_reset) begin cr_q1 <= 1'b1; cr_q2 <= 1'b1; end
    else begin cr_q1 <= 1'b0; cr_q2 <= cr_q1; end
  end
  wire core_rst = rst || core_reset || cr_q2;
  // frontend: leaves reset 2 cycles after the rest of the core
  logic fe_q1 = 1'b0, fe_q2 = 1'b0;
  always_ff @(posedge clk) begin
    if (core_rst) begin fe_q1 <= 1'b1; fe_q2 <= 1'b1; end
    else begin fe_q1 <= 1'b0; fe_q2 <= fe_q1; end
  end
  wire fe_rst = core_rst || fe_q2;
  // A5: the freedom window of the core: sIso (alive but isolated) and sReset (asynchronous assertion of the reset)
  wire core_free = !rst && (s_iso || s_reset);
  // the core obeys TileLink: running, outside the window and outside its reset
  wire core_run = !core_free && !core_rst;

  // ---------------- reference trackers (L2 side) ----------------
  wire fa0 = l_a_v && l_a_r, fb0 = l_b_v && l_b_r, fc0 = l_c_v && l_c_r, fd0 = l_d_v && l_d_r, fe0 = l_e_v && l_e_r;
  wire fa1 = m_a_v && m_a_r, fd1 = m_d_v && m_d_r;
  // core side of channels B and C (a Probe answered by the gate is seen only on the L2 side)
  wire fbc = c_b_v && c_b_r, fcc = c_c_v && c_c_r;
  wire fbg = fb0 && !fbc, fcg = fc0 && !fcc;     // Probe taken by the gate / C beat from the gate
  // data messages: Put (A 0), ProbeAckData (C 5), ReleaseData (C 7), AccessAckData (D 1), GrantData (D 5)
  // opcodes of the model: A 5 = CBO (RTL 12..14), D 2 = CBOAck (RTL 8)
  logic c_mid, d0_mid, a1_mid, d1_mid; logic [2:0] c_mop, d0_mop, a1_mop, d1_mop;
  logic [2:0] r_acq, r_cbo, r_gack, r_prb, r_rel, r_get, r_put, r_gprb;
  // path 2, counted on the core-manager side of TLResetIsolation: requests and responses of the manager
  wire fa2 = w_a_v && w_a_r, fd2 = w_d_v && w_d_r;               // tile side of TLResetIsolation
  wire fka = k_a_v && k_a_r, fkd = k_d_v && k_d_r;               // core side of TLResetIsolation
  logic a2_mid, d2_mid, ka_mid, kd_mid; logic [2:0] a2_mop, d2_mop, kd_mop; logic [2:0] r_u2, r_k;
  wire a2_last = a2_mid || w_a_op != 3'd0;
  wire d2_last = d2_mid || w_d_op != 3'd1;
  wire ka_last = ka_mid || k_a_op != 3'd0;
  wire kd_last = kd_mid || k_d_op != 3'd1;
  always_ff @(posedge clk)
    if (rst) begin a2_mid <= 0; d2_mid <= 0; ka_mid <= 0; kd_mid <= 0; r_u2 <= 0; r_k <= 0; end
    else begin
      if (fa2) begin a2_mid <= !a2_last; a2_mop <= w_a_op; end
      if (fd2) begin d2_mid <= !d2_last; d2_mop <= w_d_op; end
      if (fka) ka_mid <= !ka_last;
      if (fkd) begin kd_mid <= !kd_last; kd_mop <= k_d_op; end
      r_u2 <= r_u2 + 3'(fa2 && a2_last) - 3'(fd2 && d2_last);
      r_k  <= r_k  + 3'(fka && ka_last) - 3'(fkd && kd_last);
    end
  wire c_last  = c_mid  || !(c_c_op == 3'd5 || c_c_op == 3'd7);
  wire d0_first = !d0_mid;
  wire d0_last = d0_mid || l_d_op != 3'd5;
  wire a1_first = !a1_mid;
  wire a1_last = a1_mid || m_a_op != 3'd0;
  wire d1_last = d1_mid || m_d_op != 3'd1;
  always_ff @(posedge clk) begin
    if (rst) begin
      c_mid <= 0; d0_mid <= 0; a1_mid <= 0; d1_mid <= 0;
      r_acq <= 0; r_cbo <= 0; r_gack <= 0; r_prb <= 0; r_rel <= 0; r_get <= 0; r_put <= 0; r_gprb <= 0;
    end else begin
      if (fcc) begin c_mid <= !c_last; c_mop <= c_c_op; end
      if (fd0) begin d0_mid <= !d0_last; d0_mop <= l_d_op; end
      if (fa1) begin a1_mid <= !a1_last; a1_mop <= m_a_op; end
      if (fd1) begin d1_mid <= !d1_last; d1_mop <= m_d_op; end
      // r_acq: every request on A (Acquire and CBO) until its response on D; r_cbo: the CBOs among them
      r_acq  <= r_acq  + 3'(fa0) - 3'(fd0 && d0_last && l_d_op != 3'd6);
      r_cbo  <= r_cbo  + 3'(fa0 && c_a_op == 3'd5) - 3'(fd0 && l_d_op == 3'd2);
      r_gack <= r_gack + 3'(fd0 && d0_first && (l_d_op == 3'd4 || l_d_op == 3'd5)) - 3'(fe0);
      r_prb  <= r_prb  + 3'(fbc) - 3'(fcc && c_last && (c_c_op == 3'd4 || c_c_op == 3'd5));
      r_rel  <= r_rel  + 3'(fcc && c_last && (c_c_op == 3'd6 || c_c_op == 3'd7)) - 3'(fd0 && l_d_op == 3'd6);
      r_gprb <= r_gprb + 3'(fbg) - 3'(fcg);
      r_get  <= r_get  + 3'(fa1 && m_a_op == 3'd4) - 3'(fd1 && d1_last && m_d_op == 3'd1);
      r_put  <= r_put  + 3'(fa1 && a1_last && m_a_op == 3'd0) - 3'(fd1 && m_d_op == 3'd0);
    end
  end

  // ---------------- history registers ----------------
  logic ran = 1'b0;                    // the core has been reset at least once
  always_ff @(posedge clk) if (!rst && in_reset) ran <= 1'b1;
  logic pv = 1'b0;   // past valid
  logic p_alive, p_core_rst;
  always_ff @(posedge clk) begin pv <= !rst; p_alive <= alive; p_core_rst <= core_rst; end
  logic [7:0] rcnt;   // cycles in sReset
  always_ff @(posedge clk) rcnt <= (rst || !s_reset) ? 8'd0 : ((rcnt == 8'hff) ? rcnt : rcnt + 8'd1);
  logic st_reset_q; always_ff @(posedge clk) st_reset_q <= rst ? 1'b0 : s_reset;
  logic [7:0] rcnt_q; always_ff @(posedge clk) rcnt_q <= rcnt;
  logic [2:0] st_q; logic isolate_q, alive_q, core_in_reset_q, busy_q, l1_req_q, core_reset_q, req_q, l1_done_q, l1_idle_q, fe_rst_q, gq_q;
  logic [7:0] iso_run;                 // consecutive cycles with isolate high before this cycle
  wire all_quiet = quiet0 && quiet1 && quiet2 && iso_quiet;
  always_ff @(posedge clk) begin
    if (rst) begin
      st_q <= 3'd0; isolate_q <= 1'b0; alive_q <= 1'b0; core_in_reset_q <= 1'b0; busy_q <= 1'b0; l1_req_q <= 1'b0;
      core_reset_q <= 1'b0; req_q <= 1'b0; l1_done_q <= 1'b0; l1_idle_q <= 1'b0; fe_rst_q <= 1'b0; gq_q <= 1'b0; iso_run <= 8'd0;
    end else begin
      st_q <= st; isolate_q <= isolate; alive_q <= alive; core_in_reset_q <= core_in_reset; busy_q <= busy; l1_req_q <= l1_req;
      core_reset_q <= core_reset; req_q <= req; l1_done_q <= l1_done; l1_idle_q <= l1_idle; fe_rst_q <= fe_rst; gq_q <= all_quiet;
      iso_run <= isolate ? ((iso_run == 8'hff) ? iso_run : iso_run + 8'd1) : 8'd0;
    end
  end

  // ---------------- environment assumptions ----------------
  // the core: running (obeys TileLink), free (window A5: arbitrary), or in reset otherwise (tile reset, release
  // through the synchroniser: reset values)
  assign core_in_reset = core_free ? fe_any : fe_rst;
  always_comb begin
    // legal opcodes (A1; L2 side always; core side while it runs)
    assume(l_d_op == 3'd4 || l_d_op == 3'd5 || l_d_op == 3'd6 || l_d_op == 3'd2);
    assume(m_d_op == 3'd0 || m_d_op == 3'd1);
    if (core_run) begin
      assume(c_a_op == 3'd6 || c_a_op == 3'd7 || c_a_op == 3'd5);   // DCache: AcquireBlock / AcquirePerm / CBO
      assume(c_c_op[2]);
      assume(u_a_op == 3'd0 || u_a_op == 3'd4);                      // PutFull / Get
      assume(v_a_op == 3'd0 || v_a_op == 3'd4);
      assume(k_d_op == 3'd0 || k_d_op == 3'd1);
    end
    // A6: the core in reset, but not in the window: reset values (l1_idle stays free)
    if (core_rst && !core_free) assume(!c_a_v && !c_c_v && !c_e_v && !u_a_v && !v_a_v && !k_d_v && !alive && !l1_done);
    // A2: the beats of one message keep the opcode
    if (core_run && c_mid && c_c_v) assume(c_c_op == c_mop);
    if (d0_mid && l_d_v) assume(l_d_op == d0_mop);
    if (core_run && a1_mid && u_a_v) assume(u_a_op == a1_mop);
    if (d1_mid && m_d_v) assume(m_d_op == d1_mop);
    if (core_run && a2_mid && v_a_v) assume(v_a_op == a2_mop);
    if (core_run && kd_mid && k_d_v) assume(k_d_op == kd_mop);
    // A3: responses only to outstanding requests (a message that is already half transferred may finish)
    if (l_d_v && !d0_mid && (l_d_op == 3'd4 || l_d_op == 3'd5)) assume(r_acq != r_cbo);   // an Acquire is open
    if (l_d_v && l_d_op == 3'd2) assume(r_cbo != 0);                                       // a CBO is open
    if (l_d_v && l_d_op == 3'd6) assume(r_rel != 0);
    if (m_d_v && !d1_mid && m_d_op == 3'd1) assume(r_get != 0);
    if (m_d_v && m_d_op == 3'd0) assume(r_put != 0);
    if (core_run && c_e_v) assume(r_gack != 0);
    if (core_run && c_c_v && !c_mid && (c_c_op == 3'd4 || c_c_op == 3'd5)) assume(r_prb != 0);
    if (core_run && k_d_v && !kd_mid) assume(r_k != 0);
    // A8: DCache drain: no new Release once the controller has left sIdle / sQuiesce
    if (core_run && c_c_v && !c_mid && (c_c_op == 3'd6 || c_c_op == 3'd7)) assume(s_idle || s_quiesce);
    // A4: finite number of outstanding transactions (source IDs)
    if (core_run && c_a_v) assume(r_acq < 3'd6);
    if (l_b_v) assume(r_prb < 3'd6);
    if (core_run && c_c_v && !c_mid && (c_c_op == 3'd6 || c_c_op == 3'd7)) assume(r_rel < 3'd6);
    if (core_run && u_a_v && !a1_mid) assume(r_get + r_put < 3'd6);
    if (core_run && v_a_v && !a2_mid) assume(r_u2 < 3'd6);
    // A10: DCache handshakes
    if (core_run && l1_done) assume(l1_req || l1_req_q);
    // A12: normal operation before the first sequence: the DCache is up
    if (!ran && !core_free && !rst) assume(alive);
  end
  // TileLink 4.1 lets a sender retract a beat that was not accepted, so there is NO stability assumption on any
  // channel (A13): the proof holds for senders that retract (the gate itself retracts an unaccepted A when it
  // closes). Only the beats of a burst belong to one message (assumed above).
  // A11: cycles since the core left reset while alive is still low
  logic [2:0] alive_wait;
  always_ff @(posedge clk) alive_wait <= (rst || core_rst || core_free || alive) ? 3'd0 : alive_wait + 3'd1;
  always_comb if (pv && !core_free) begin
    // alive stays high once the DCache is out of reset, and rises within 6 cycles after it
    if (p_alive && !core_rst && !p_core_rst) assume(alive);
    if (alive_wait >= 3'd6) assume(alive);
  end

  // ---------------- properties ----------------
  // beats that cross to / from the core (a Probe answered by the gate does not)
  wire any_fire = fa0 || fbc || fcc || fd0 || fe0 || fa1 || fd1 || fa2 || fd2 || fka || fkd ||
                  (v_a_v && v_a_r) || (v_d_v && v_d_r) || (u_a_v && u_a_r) || (u_d_v && u_d_r) || (c_a_v && c_a_r) ||
                  (c_d_v && c_d_r) || (c_e_v && c_e_r);
  wire nothing_outstanding = r_acq == 0 && r_gack == 0 && r_prb == 0 && r_rel == 0 && r_get == 0 && r_put == 0 &&
                             !c_mid && !d0_mid && !a1_mid && !d1_mid && r_u2 == 0 && r_k == 0 && !a2_mid && !d2_mid &&
                             !ka_mid && !kd_mid;
  // isolation: tile side of every gate and of TLResetIsolation, and what is offered to the core
  wire tile_side_quiet = !l_a_v && (!l_c_v || ack_pend0) && !l_e_v && !l_d_r && (!l_b_r || (ack_probe && !ack_pend0)) &&
                         !m_a_v && !m_d_r && !w_a_v && !w_d_r && !w_a_r && !w_d_v;
  wire core_side_quiet = !c_b_v && !c_d_v && !u_d_v && !v_d_v && !k_a_v && !k_d_r;
  logic [7:0] hold_noreq; logic st_was_reset, st_was_release, st_drain_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      hold_noreq <= '0; st_was_reset <= 1'b0; st_was_release <= 1'b0; st_drain_q <= 1'b0;
    end else begin
      st_was_reset <= s_reset; st_was_release <= s_release; st_drain_q <= s_drain;
      // consecutive cycles with B closed (held or answered), the request low, outside sDrain
      hold_noreq <= (req || s_drain || !(hold_probe || ack_probe)) ? 8'd0 :
                    ((hold_noreq == 8'hff) ? hold_noreq : hold_noreq + 8'd1);
    end
  end
`ifndef COVER_AS_ASSERT
  always_comb if (!rst) begin
    P1_reset_point_clean:   assert(!(s_iso || s_reset) || nothing_outstanding);
    P2_nothing_crosses:     assert(!(s_iso || s_reset || s_release) || !any_fire);
    P3_no_probe_to_reset:   assert(!(core_rst || s_iso || s_reset || s_release) || !c_b_v);
    P4_a_message_not_cut:   assert(!(a1_mid && u_a_v) || m_a_v);
    P5_quiet_is_sound:      assert(!all_quiet || nothing_outstanding);
    P6_reset_only_in_reset: assert(core_reset == s_reset && in_reset == core_reset);
    P7_no_probe_before_alive: assert(!c_b_v || alive);
    P8_b_closed_only_in_procedure: assert(!(hold_probe || ack_probe) || s_drain || s_iso || s_reset || s_release);
    P8B_closed_bounded_after_req:  assert(hold_noreq <= 8'(RST + ISO + 16));
    P8N_held_only_in_drain_iso: assert(KEEP || hold_probe == (s_drain || s_iso));
    P8N_taken_at_once:        assert(!(ack_probe && !ack_pend0 && l_b_v) || l_b_r);
    P8N_ack_offered:          assert(!ack_pend0 || (l_c_v && l_c_op == 3'd4));
    P9_no_new_noncoherent:    assert(s_idle || !((fa1 && !a1_mid) || (fa2 && !a2_mid)));
    P10_noncoherent_quiet_in_drain: assert(!s_drain || (r_get == 0 && r_put == 0 && !a1_mid && !d1_mid && r_u2 == 0 &&
                                      r_k == 0 && !a2_mid && !d2_mid && !ka_mid && !kd_mid));
    P11_hart_in_reset_is_busy: assert(hart_in_reset == busy && busy == !s_idle);
    P12_one_at_a_time:        assert(r_gprb <= 3'd1);
    P12_ack_is_NtoN:          assert(!fcg || (l_c_op == 3'd4 && l_c_par == 3'd5));
    P12_ack_follows_probe:    assert(!fcg || r_gprb == 3'd1 || fbg);
    P12_not_inside_c_msg:     assert(!(fcg && c_mid));
    P12_only_without_keep:    assert(!KEEP || (!fbg && !fcg && !ack_pend0));
    P12_take_only_in_reset:   assert(!fbg || s_reset || s_release);
    P13_reset_until_req_drops: assert(!(s_release && st_was_reset && req_q));
    P14_reset_at_least_rst:   assert(!(st_reset_q && !s_reset) || rcnt_q >= 8'(RST));
    P15_isolation_tile_side:  assert(!isolate || tile_side_quiet);
    P15_isolation_core_side:  assert(!isolate || core_side_quiet);
    P16_isolation_covers_reset: assert(!(core_reset || cr_q2) || isolate);
    P16_isolation_only_in_procedure: assert(isolate == (s_iso || s_reset || s_release));
    P17_b_closed_when_isolated: assert(!isolate || hold_probe || ack_probe);
    P18_b_held_from_first_drain_cycle: assert(!s_drain || (hold_probe && !c_b_v && !fb0));
    P19_decision_after_done_idle: assert(!(isolate && !isolate_q) || (l1_done_q && l1_idle_q && gq_q));
    P20_run_only_after_frontend: assert(!(s_idle && st_was_release) || !fe_rst_q);
    P21_iso_lead:             assert(!(core_reset && !core_reset_q) || iso_run >= 8'(ISO));
    P22_iso_drop_after_core_up: assert(!(isolate_q && !isolate) || (st_q == 3'd5 && alive_q && !core_in_reset_q));
    P23_l1_req_through_iso:   assert(l1_req == (s_quiesce || s_drain || s_iso));
    P24_freeze_from_iso:      assert(l1_freeze == (KEEP && isolate));
    P25_no_busy_gap:          assert(!(st_q == 3'd5 && s_idle && req_q));
    P25_busy_falls_only_from_release: assert(!(busy_q && !busy) || (st_q == 3'd5 && !req_q));
  end
`endif

  // ---------------- covers (non-vacuity) ----------------
  // transactions in flight when the procedure starts, then a full sequence back to sIdle
  logic st_prb, st_rel, st_acq, st_gack, st_cmid, st_get, st_amid, seen_reset, bheld, held_then_delivered;
  logic long_reset, long_reset_done, gate_answered, gate_answered_done;
  logic st_k, garbage_seen, garbage_done, c5_offered, c5_reset, c5_done;
  logic c10_seen1, c10_gapfree, c10_done, c11_off, c11_reset, c11_done, c12_a, c12_b, c13_a, c13_b, c14_a;
  wire core_rise = core_reset && !core_reset_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      {st_prb, st_rel, st_acq, st_gack, st_cmid, st_get, st_amid, seen_reset, bheld, held_then_delivered} <= '0;
      {long_reset, long_reset_done, gate_answered, gate_answered_done} <= '0;
      {st_k, garbage_seen, garbage_done, c5_offered, c5_reset, c5_done} <= '0;
      {c10_seen1, c10_done, c11_off, c11_reset, c11_done, c12_a, c12_b, c13_a, c13_b, c14_a} <= '0;
      c10_gapfree <= 1'b1;
    end else begin
      if (s_idle && req) begin
        st_prb <= r_prb != 0; st_rel <= r_rel != 0; st_acq <= r_acq != 0; st_gack <= r_gack != 0;
        st_cmid <= c_mid; st_get <= r_get != 0; st_amid <= a1_mid; st_k <= r_k != 0;
      end
      if (s_reset && core_free && (c_c_v || c_e_v || k_d_v || c_a_v)) garbage_seen <= 1'b1;
      if (garbage_seen && s_idle) garbage_done <= 1'b1;
      if (s_reset) seen_reset <= 1'b1;
      if (s_reset && l_b_v) bheld <= 1'b1;
      if (bheld && s_idle && fb0) held_then_delivered <= 1'b1;
      // C5: Probe offered by L2 in the first cycle of sDrain; KEEP: held through the reset, delivered after the
      // sequence; FULL: held, answered by the gate in sReset / sRelease
      if (s_drain && !st_drain_q && l_b_v && !fb0) c5_offered <= 1'b1;
      if (c5_offered && s_reset) c5_reset <= 1'b1;
      if (c5_reset && ((KEEP && s_idle && fbc) || (!KEEP && fcg))) c5_done <= 1'b1;
      if (s_reset && rcnt >= 8'(RST + 24)) long_reset <= 1'b1;
      if (long_reset && s_idle) long_reset_done <= 1'b1;
      if (fcg && (s_reset || s_release)) gate_answered <= 1'b1;
      if (gate_answered && s_idle) gate_answered_done <= 1'b1;
      // C10: two core resets in a row, busy high all the time between them
      if (core_rise) begin
        if (c10_seen1 && c10_gapfree) c10_done <= 1'b1;
        c10_seen1 <= 1'b1;
      end
      if (c10_seen1 && !busy) c10_gapfree <= 1'b0;
      // C11: Probe offered in sIso (held), then FULL: answered by the gate; KEEP: delivered after the sequence
      if (s_iso && l_b_v && !fb0) c11_off <= 1'b1;
      if (c11_off && s_reset) c11_reset <= 1'b1;
      if (c11_reset && ((KEEP && fbc) || (!KEEP && fcg))) c11_done <= 1'b1;
      // C12: request dropped in sQuiesce, the sequence still reaches sReset and sIdle
      if (s_quiesce && !req) c12_a <= 1'b1;
      if (c12_a && s_reset) c12_b <= 1'b1;
      // C13: the gate's own ProbeAck still pending in sIdle, then channel B open again (Probe to the core)
      if (ack_pend0 && s_idle) c13_a <= 1'b1;
      if (c13_a && fbc) c13_b <= 1'b1;
      // C14: sIso lasts two cycles, then sReset
      if (s_iso && st_q == 3'd3) c14_a <= 1'b1;
    end
  end
  wire cv1  = seen_reset && st_prb && st_rel && st_acq && st_cmid;
  wire cv2  = seen_reset && st_gack && st_get && st_amid;
  wire cv4  = seen_reset && s_idle && !req;
  wire cv8  = seen_reset && st_k && s_idle;
  wire cv10 = c10_done && s_idle;
  wire cv11 = c11_done && s_idle;
  wire cv12 = c12_b && s_idle && !req;
  wire cv13 = c13_b;
  wire cv14 = c14_a && s_reset;
`ifndef COVER_AS_ASSERT
  always_comb if (!rst) begin
    C1_inflight_at_start_then_reset: cover(cv1);
    C2_more_inflight_at_start:       cover(cv2);
    if (KEEP)  C3_probe_held_then_delivered: cover(held_then_delivered);
    C4_back_to_idle:                 cover(cv4);
    C5_probe_in_first_drain_cycle_held_then_delivered: cover(c5_done && s_idle);
    C6_reset_held_long_then_run:     cover(long_reset_done);
    if (!KEEP) C7_probe_answered_by_gate_in_reset_then_run: cover(gate_answered_done);
    C8_icachectrl_inflight_at_start_then_reset: cover(cv8);
    C9_core_garbage_in_reset_then_run: cover(garbage_done);
    C10_two_sequences_in_a_row:      cover(cv10);
    C11_probe_offered_in_iso:        cover(cv11 && s_idle);
    C12_request_dropped_in_quiesce:  cover(cv12);
    if (!KEEP) C13_ack_pending_survives_idle: cover(cv13);
    if (ISO == 2) C14_iso_two_cycles: cover(cv14);
  end
`else
  // COVER_AS_ASSERT (for engines without cover, e.g. abc bmc3): -DCOVER_ONLY=n turns cover Cn into
  // assert(!(cond)); the cover is reached at the step where this assertion fails. All P* assertions are
  // left out of such a run.
`ifdef COVER_ONLY
  localparam int CSEL = `COVER_ONLY;
`else
  localparam int CSEL = 0;
`endif
  always_comb if (!rst) begin
    if (CSEL == 1) C1_inflight_at_start_then_reset: assert(!cv1);
    if (CSEL == 2) C2_more_inflight_at_start:       assert(!cv2);
    if (CSEL == 3 && KEEP) C3_probe_held_then_delivered: assert(!held_then_delivered);
    if (CSEL == 4) C4_back_to_idle:                 assert(!cv4);
    if (CSEL == 5) C5_probe_in_first_drain_cycle_held_then_delivered: assert(!(c5_done && s_idle));
    if (CSEL == 6) C6_reset_held_long_then_run:     assert(!long_reset_done);
    if (CSEL == 7 && !KEEP) C7_probe_answered_by_gate_in_reset_then_run: assert(!gate_answered_done);
    if (CSEL == 8) C8_icachectrl_inflight_at_start_then_reset: assert(!cv8);
    if (CSEL == 9) C9_core_garbage_in_reset_then_run: assert(!garbage_done);
    if (CSEL == 10) C10_two_sequences_in_a_row:     assert(!cv10);
    if (CSEL == 11) C11_probe_offered_in_iso:       assert(!(cv11 && s_idle));
    if (CSEL == 12) C12_request_dropped_in_quiesce: assert(!cv12);
    if (CSEL == 13 && !KEEP) C13_ack_pending_survives_idle: assert(!cv13);
    if (CSEL == 14 && ISO == 2) C14_iso_two_cycles: assert(!cv14);
  end
`endif
endmodule
