// ============================================================================
// Formal harness (v6) of the TileLink adapters alone: TLQuiesceGate (TL-C, DCache), TLQuiesceGate (TL-UL) and
// TLResetIsolation, models of ../model/cr_ctl_models.sv (one-to-one with CoreReset.scala); no controller.
// Spec: core-reset/verification/TESTPLAN.md section 2.3, core-reset/DESIGN.md section 3.
//
// Purpose: show that the isolation is LOCAL, held by the register `isolate` alone (rule R2), without any
// assumption about the decodes holdB / ackB / block: every control input (block, hold_b, ack_b, isolate) of
// every adapter is FREE, in every cycle, with NO assumption "isolate -> hold_b || ack_b" and NO assumption
// "!(hold_b && ack_b)". In fv_boundary the controller guarantees both, and there GATE_MUTANT_NO_ISO_A and
// _NO_ISO_B are equivalent mutants (A is also closed by block, B by hold_b / ack_b); here they are killed.
// Run with -DFORMAL.
//
// Environment: TileLink only, on both sides of every adapter (A1..A4 of TESTPLAN 2.2): legal opcodes, the beats
// of one message keep the opcode, a response only to an open request, at most 5 open transactions of each kind;
// no valid-stability assumption (a sender may retract an unaccepted beat). Opcodes of the model: A 5 = CBO,
// D 2 = CBOAck (see fv_boundary.sv).
//
// Properties (assert):
//   L1  TL-C gate, isolate: to L2 a.valid = e.valid = 0, d.ready = 0, c.valid only for the gate's own ProbeAck
//       (pending), b.ready == the gate takes a Probe (ack_b && !hold_b && !pending); to the core b.valid =
//       d.valid = 0, a, c, e ready = 0
//   L2  TL-UL gate, isolate: a.valid = 0, d.ready = 0, to the core d.valid = 0, a.ready = 0
//   L3  TLResetIsolation, isolate: to the core a.valid = 0, d.ready = 0; to the tile a.ready = 0, d.valid = 0
//   L4  quiet of EVERY adapter: nothing outstanding on its edge and no half message
//   L5  channel A is cut only at a message boundary (block free; a cut by isolate is excluded: the drain leaves
//       nothing half sent when isolate rises, which is P4 / P5 of fv_boundary)
//   L6  the gate's own answer: one at a time, ProbeAck NtoN, the address of the Probe it took.
//       NOT checked here: "not inside a C message of the core": it needs ack_b to rise only with the core C
//       channel closed (isolate), a controller guarantee (P12_not_inside_c_msg of fv_boundary).
// ============================================================================
module fv_adapters (
  input logic clk,
  // free control inputs of the three adapters
  input logic blk0, hold0, ack0, iso0,        // TL-C gate
  input logic blk1, hold1, ack1, iso1,        // TL-UL gate
  input logic iso2,                           // TLResetIsolation
  // TL-C gate: core side
  input logic c_a_v, input logic [2:0] c_a_op, input logic c_b_r,
  input logic c_c_v, input logic [2:0] c_c_op, input logic c_d_r, input logic c_e_v,
  // TL-C gate: L2 side
  input logic l_a_r, input logic l_b_v, input logic [3:0] l_b_addr, input logic l_c_r,
  input logic l_d_v, input logic [2:0] l_d_op, input logic l_e_r,
  // TL-UL gate
  input logic u_a_v, input logic [2:0] u_a_op, input logic u_d_r,
  input logic m_a_r, input logic m_d_v, input logic [2:0] m_d_op,
  // TLResetIsolation: tile side (v) and core side (k)
  input logic v_a_v, input logic [2:0] v_a_op, input logic v_d_r,
  input logic k_a_r, input logic k_d_v, input logic [2:0] k_d_op
);
  logic rst = 1'b1;
  always_ff @(posedge clk) rst <= 1'b0;

  // ---------------- DUTs ----------------
  logic quiet0, quiet1, iso_quiet, ack_pend0;
  logic c_a_r, c_b_v, c_c_r, c_d_v, c_e_r; logic [2:0] c_d_op;
  logic l_a_v, l_b_r, l_c_v, l_d_r, l_e_v; logic [2:0] l_a_op, l_c_op;
  logic [1:0] c_b_par, c_d_par; logic [3:0] c_b_addr, c_d_src, c_d_sink; logic [31:0] c_d_dat;
  logic [1:0] l_a_par; logic [3:0] l_a_src, l_a_addr, l_c_src, l_c_addr, l_e_sink; logic [2:0] l_c_par;
  logic [31:0] l_a_dat, l_c_dat;
  cr_gate #(1, "l1d") g0 (.clk, .rst, .block(blk0), .hold_b(hold0), .ack_b(ack0), .quiet(quiet0),
    .ack_pend(ack_pend0), .isolate(iso0),
    .ia_valid(c_a_v), .ia_ready(c_a_r), .ia_op(c_a_op), .ia_param(2'd0), .ia_src(4'd1), .ia_addr(4'd0), .ia_data(32'd0),
    .ib_valid(c_b_v), .ib_ready(c_b_r), .ib_param(c_b_par), .ib_addr(c_b_addr),
    .ic_valid(c_c_v), .ic_ready(c_c_r), .ic_op(c_c_op), .ic_param(3'd0), .ic_src(4'd0), .ic_addr(4'd0), .ic_data(32'd0),
    .id_valid(c_d_v), .id_ready(c_d_r), .id_op(c_d_op), .id_param(c_d_par), .id_src(c_d_src), .id_sink(c_d_sink), .id_data(c_d_dat),
    .ie_valid(c_e_v), .ie_ready(c_e_r), .ie_sink(4'd0),
    .oa_valid(l_a_v), .oa_ready(l_a_r), .oa_op(l_a_op), .oa_param(l_a_par), .oa_src(l_a_src), .oa_addr(l_a_addr), .oa_data(l_a_dat),
    .ob_valid(l_b_v), .ob_ready(l_b_r), .ob_param(2'd2), .ob_addr(l_b_addr),
    .oc_valid(l_c_v), .oc_ready(l_c_r), .oc_op(l_c_op), .oc_param(l_c_par), .oc_src(l_c_src), .oc_addr(l_c_addr), .oc_data(l_c_dat),
    .od_valid(l_d_v), .od_ready(l_d_r), .od_op(l_d_op), .od_param(2'd0), .od_src(4'd1), .od_sink(4'd0), .od_data(32'd0),
    .oe_valid(l_e_v), .oe_ready(l_e_r), .oe_sink(l_e_sink));

  logic u_a_r, u_d_v, m_a_v, m_d_r; logic [2:0] u_d_op, m_a_op;
  logic [1:0] m_a_par, u_d_par; logic [3:0] m_a_src, m_a_addr, u_d_src, u_d_sink; logic [31:0] m_a_dat, u_d_dat;
  logic g1_ibv, g1_icr, g1_ier, g1_obr, g1_ocv, g1_oev; logic [1:0] g1_ibp; logic [3:0] g1_iba, g1_ocs, g1_oca, g1_oes;
  logic [2:0] g1_oco, g1_ocp; logic [31:0] g1_ocd;
  cr_gate #(0, "ul") g1 (.clk, .rst, .block(blk1), .hold_b(hold1), .ack_b(ack1), .quiet(quiet1),
    .ack_pend(), .isolate(iso1),
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

  logic v_a_r, v_d_v, k_a_v, k_d_r; logic [2:0] v_d_op, k_a_op; logic [3:0] k_a_src, k_a_addr, v_d_src; logic [31:0] k_a_dat, v_d_dat;
  cr_iso #("icachectrl") iso (.clk, .rst, .isolate(iso2), .quiet(iso_quiet),
    .ia_valid(v_a_v), .ia_ready(v_a_r), .ia_op(v_a_op), .ia_src(4'd0), .ia_addr(4'd0), .ia_data(32'd0),
    .id_valid(v_d_v), .id_ready(v_d_r), .id_op(v_d_op), .id_src(v_d_src), .id_data(v_d_dat),
    .oa_valid(k_a_v), .oa_ready(k_a_r), .oa_op(k_a_op), .oa_src(k_a_src), .oa_addr(k_a_addr), .oa_data(k_a_dat),
    .od_valid(k_d_v), .od_ready(k_d_r), .od_op(k_d_op), .od_src(4'd0), .od_data(32'd0));

  // ---------------- reference trackers (independent of the gates' counters) ----------------
  wire fa0 = l_a_v && l_a_r, fb0 = l_b_v && l_b_r, fc0 = l_c_v && l_c_r, fd0 = l_d_v && l_d_r, fe0 = l_e_v && l_e_r;
  wire fa1 = m_a_v && m_a_r, fd1 = m_d_v && m_d_r;
  wire fbc = c_b_v && c_b_r, fcc = c_c_v && c_c_r;
  wire fbg = fb0 && !fbc, fcg = fc0 && !fcc;     // Probe taken by the gate / C beat from the gate
  logic c_mid, d0_mid, a1_mid, d1_mid; logic [2:0] c_mop, d0_mop, a1_mop, d1_mop;
  logic [2:0] r_acq, r_cbo, r_gack, r_prb, r_rel, r_get, r_put, r_gprb; logic [3:0] gp_addr;
  // TLResetIsolation: tile side (w) and core side (k)
  wire fa2 = v_a_v && v_a_r, fd2 = v_d_v && v_d_r, fka = k_a_v && k_a_r, fkd = k_d_v && k_d_r;
  logic a2_mid, d2_mid, ka_mid, kd_mid; logic [2:0] a2_mop, kd_mop, r_u2, r_k;
  wire a2_last = a2_mid || v_a_op != 3'd0, d2_last = d2_mid || v_d_op != 3'd1;
  wire ka_last = ka_mid || k_a_op != 3'd0, kd_last = kd_mid || k_d_op != 3'd1;
  wire c_last = c_mid || !(c_c_op == 3'd5 || c_c_op == 3'd7);
  wire d0_first = !d0_mid, d0_last = d0_mid || l_d_op != 3'd5;
  wire a1_last = a1_mid || m_a_op != 3'd0, d1_last = d1_mid || m_d_op != 3'd1;
  always_ff @(posedge clk) begin
    if (rst) begin
      a2_mid <= 0; d2_mid <= 0; ka_mid <= 0; kd_mid <= 0; r_u2 <= 0; r_k <= 0;
      c_mid <= 0; d0_mid <= 0; a1_mid <= 0; d1_mid <= 0;
      r_acq <= 0; r_cbo <= 0; r_gack <= 0; r_prb <= 0; r_rel <= 0; r_get <= 0; r_put <= 0; r_gprb <= 0;
    end else begin
      if (fa2) begin a2_mid <= !a2_last; a2_mop <= v_a_op; end
      if (fd2) d2_mid <= !d2_last;
      if (fka) ka_mid <= !ka_last;
      if (fkd) begin kd_mid <= !kd_last; kd_mop <= k_d_op; end
      r_u2 <= r_u2 + 3'(fa2 && a2_last) - 3'(fd2 && d2_last);
      r_k  <= r_k  + 3'(fka && ka_last) - 3'(fkd && kd_last);
      if (fcc) begin c_mid <= !c_last; c_mop <= c_c_op; end
      if (fd0) begin d0_mid <= !d0_last; d0_mop <= l_d_op; end
      if (fa1) begin a1_mid <= !a1_last; a1_mop <= m_a_op; end
      if (fd1) begin d1_mid <= !d1_last; d1_mop <= m_d_op; end
      r_acq  <= r_acq  + 3'(fa0) - 3'(fd0 && d0_last && l_d_op != 3'd6);
      r_cbo  <= r_cbo  + 3'(fa0 && c_a_op == 3'd5) - 3'(fd0 && l_d_op == 3'd2);
      r_gack <= r_gack + 3'(fd0 && d0_first && (l_d_op == 3'd4 || l_d_op == 3'd5)) - 3'(fe0);
      r_prb  <= r_prb  + 3'(fbc) - 3'(fcc && c_last && (c_c_op == 3'd4 || c_c_op == 3'd5));
      r_rel  <= r_rel  + 3'(fcc && c_last && (c_c_op == 3'd6 || c_c_op == 3'd7)) - 3'(fd0 && l_d_op == 3'd6);
      r_gprb <= r_gprb + 3'(fbg) - 3'(fcg);
      if (fbg) gp_addr <= l_b_addr;
      r_get  <= r_get  + 3'(fa1 && m_a_op == 3'd4) - 3'(fd1 && d1_last && m_d_op == 3'd1);
      r_put  <= r_put  + 3'(fa1 && a1_last && m_a_op == 3'd0) - 3'(fd1 && m_d_op == 3'd0);
    end
  end

  // ---------------- environment: TileLink on both sides of every adapter ----------------
  always_comb begin
    // A1 legal opcodes
    assume(l_d_op == 3'd4 || l_d_op == 3'd5 || l_d_op == 3'd6 || l_d_op == 3'd2);
    assume(m_d_op == 3'd0 || m_d_op == 3'd1);
    assume(c_a_op == 3'd6 || c_a_op == 3'd7 || c_a_op == 3'd5);
    assume(c_c_op[2]);
    assume(u_a_op == 3'd0 || u_a_op == 3'd4);
    assume(v_a_op == 3'd0 || v_a_op == 3'd4);
    assume(k_d_op == 3'd0 || k_d_op == 3'd1);
    // A2 the beats of one message keep the opcode
    if (c_mid && c_c_v) assume(c_c_op == c_mop);
    if (d0_mid && l_d_v) assume(l_d_op == d0_mop);
    if (a1_mid && u_a_v) assume(u_a_op == a1_mop);
    if (d1_mid && m_d_v) assume(m_d_op == d1_mop);
    if (a2_mid && v_a_v) assume(v_a_op == a2_mop);
    if (kd_mid && k_d_v) assume(k_d_op == kd_mop);
    // A3 responses only to open requests (a message already half transferred may finish)
    if (l_d_v && !d0_mid && (l_d_op == 3'd4 || l_d_op == 3'd5)) assume(r_acq != r_cbo);
    if (l_d_v && l_d_op == 3'd2) assume(r_cbo != 0);
    if (l_d_v && l_d_op == 3'd6) assume(r_rel != 0);
    if (m_d_v && !d1_mid && m_d_op == 3'd1) assume(r_get != 0);
    if (m_d_v && m_d_op == 3'd0) assume(r_put != 0);
    if (c_e_v) assume(r_gack != 0);
    if (c_c_v && !c_mid && (c_c_op == 3'd4 || c_c_op == 3'd5)) assume(r_prb != 0);
    if (k_d_v && !kd_mid) assume(r_k != 0);
    // A4 finite number of open transactions
    if (c_a_v) assume(r_acq < 3'd6);
    if (l_b_v) assume(r_prb < 3'd6);
    if (c_c_v && !c_mid && (c_c_op == 3'd6 || c_c_op == 3'd7)) assume(r_rel < 3'd6);
    if (u_a_v && !a1_mid) assume(r_get + r_put < 3'd6);
    if (v_a_v && !a2_mid) assume(r_u2 < 3'd6);
  end

  // ---------------- properties ----------------
  // the gate takes the Probe itself: what b.ready to L2 is while the core side is isolated
  wire take0 = ack0 && !hold0 && !ack_pend0;
  wire c_edge_idle = r_acq == 0 && r_gack == 0 && r_prb == 0 && r_rel == 0 && !c_mid && !d0_mid;
  wire u_edge_idle = r_get == 0 && r_put == 0 && !a1_mid && !d1_mid;
  wire i_edge_idle = r_u2 == 0 && r_k == 0 && !a2_mid && !d2_mid && !ka_mid && !kd_mid;
  always_comb if (!rst) begin
    L1_tlc_isolation: assert(!iso0 || (!l_a_v && !l_e_v && !l_d_r && (!l_c_v || ack_pend0) && l_b_r == take0 &&
                                       !c_b_v && !c_d_v && !c_a_r && !c_c_r && !c_e_r));
    L2_ul_isolation:  assert(!iso1 || (!m_a_v && !m_d_r && !u_d_v && !u_a_r));
    L3_iso_isolation: assert(!iso2 || (!k_a_v && !k_d_r && !v_a_r && !v_d_v));
    L4_gate_c_quiet_is_sound:  assert(!quiet0 || c_edge_idle);
    L4_gate_ul_quiet_is_sound: assert(!quiet1 || u_edge_idle);
    L4_iso_quiet_is_sound:     assert(!iso_quiet || i_edge_idle);
    L5_a_cut_only_at_boundary: assert(!(a1_mid && u_a_v && !iso1) || m_a_v);
    L6_ack_one_at_a_time:      assert(r_gprb <= 3'd1);
    L6_ack_is_NtoN:            assert(!fcg || (l_c_op == 3'd4 && l_c_par == 3'd5));
    L6_ack_address:            assert(!fcg || l_c_addr == gp_addr);
    L6_ack_follows_probe:      assert(!fcg || r_gprb == 3'd1 || fbg);
  end
endmodule
