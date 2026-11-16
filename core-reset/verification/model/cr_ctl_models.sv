// ============================================================================
// Behavioral models of the new boundary logic, one-to-one with CoreReset.scala (v6):
//   cr_beat : TileLink first/last beat tracker (edge.firstlast)
//   cr_gate : TLQuiesceGate (with the isolation of the core side)
//   cr_iso  : TLResetIsolation (TL-UL edge whose manager is inside XSCore: ICache control registers)
//   cr_ctrl : CoreResetCtrl (six states with sIso, level reset, early block of the non-coherent agents, B closed
//             from the first cycle of sDrain, exact emptiness flags, isolation leading the core reset)
//   cr_quiesce : DCacheQuiesceUnit (drain of the DCache, three states)
// Synthesizable subset: used by the simulation and by the formal proof (formal/).
// Simplified TileLink encoding: see cr_env_models.sv.
// Configuration (SoCParameters): KEEP = CoreResetKeepL1 (1: L1D kept, 0 = FULL: L1D reset with the core, the gate
// answers Probes); the simulation and the formal harness take it from the define CFG_KEEP. ISO_CYCLES = isoCycles
// (define ISO2 selects 2).
// Mutants: `define NAME selects a wrong variant of one detail; every one must be caught (see scripts/, formal/).
// ============================================================================

module cr_beat (
  input  logic clk, rst,
  input  logic fire, input logic has_data,
  output logic first, output logic last
);
  logic cnt;
  assign first = !cnt;
  assign last  = !has_data || cnt;
  always_ff @(posedge clk) if (rst) cnt <= 1'b0; else if (fire) cnt <= last ? 1'b0 : 1'b1;
endmodule

// ---------------------------------------------------------------------------
// TLQuiesceGate. Isolation clamp on B (v6): ib_valid and the ready of the core side are 0 while isolate is high,
// whatever hold_b / ack_b say; ob_ready is then 0 or take_b (the gate's own answer), never a function of the core.
module cr_gate #(parameter bit BCE = 1, parameter NAME = "gate") (
  input  logic clk, rst,
  input  logic block, input logic hold_b, input logic ack_b, output logic quiet,
  input  logic isolate,                  // XSCore isolated (sIso, sReset, sRelease): the core side is ignored
  output logic ack_pend,                 // the gate is answering a Probe itself (ProbeAck NtoN pending)
  // core side (in)
  input  logic        ia_valid, output logic ia_ready, input logic [2:0] ia_op, input logic [1:0] ia_param,
  input  logic [3:0]  ia_src, input logic [3:0] ia_addr, input logic [31:0] ia_data,
  output logic        ib_valid, input  logic ib_ready, output logic [1:0] ib_param, output logic [3:0] ib_addr,
  input  logic        ic_valid, output logic ic_ready, input logic [2:0] ic_op, input logic [2:0] ic_param,
  input  logic [3:0]  ic_src, input logic [3:0] ic_addr, input logic [31:0] ic_data,
  output logic        id_valid, input  logic id_ready, output logic [2:0] id_op, output logic [1:0] id_param,
  output logic [3:0]  id_src, output logic [3:0] id_sink, output logic [31:0] id_data,
  input  logic        ie_valid, output logic ie_ready, input logic [3:0] ie_sink,
  // L2 side (out)
  output logic        oa_valid, input  logic oa_ready, output logic [2:0] oa_op, output logic [1:0] oa_param,
  output logic [3:0]  oa_src, output logic [3:0] oa_addr, output logic [31:0] oa_data,
  input  logic        ob_valid, output logic ob_ready, input logic [1:0] ob_param, input logic [3:0] ob_addr,
  output logic        oc_valid, input  logic oc_ready, output logic [2:0] oc_op, output logic [2:0] oc_param,
  output logic [3:0]  oc_src, output logic [3:0] oc_addr, output logic [31:0] oc_data,
  input  logic        od_valid, output logic od_ready, input logic [2:0] od_op, input logic [1:0] od_param,
  input  logic [3:0]  od_src, input logic [3:0] od_sink, input logic [31:0] od_data,
  output logic        oe_valid, input  logic oe_ready, output logic [3:0] oe_sink
);
  logic a_first, a_last, d_first, d_last, c_first, c_last;
  logic a_fire, b_fire, c_fire, d_fire, e_fire;
  cr_beat u_ab (.clk, .rst, .fire(a_fire), .has_data(ia_op == 3'd0), .first(a_first), .last(a_last));
  cr_beat u_db (.clk, .rst, .fire(d_fire), .has_data(od_op == 3'd1 || od_op == 3'd5), .first(d_first), .last(d_last));
  cr_beat u_cb (.clk, .rst, .fire(c_fire), .has_data(ic_op == 3'd5 || ic_op == 3'd7), .first(c_first), .last(c_last));

`ifdef GATE_MUTANT_CUT_A
  wire blk = block;              // mutant: blocks A in the middle of a multi-beat Put
`else
  wire blk = block && a_first;   // block A only at a message boundary
`endif
  // isolation (CoreReset.scala: when (io.isolate) ...), per channel so that each can be removed by a mutant
`ifdef GATE_MUTANT_NO_ISO_A
  wire iso_a = 1'b0;
`else
  wire iso_a = isolate;
`endif
`ifdef GATE_MUTANT_NO_ISO_B
  wire iso_b = 1'b0;             // mutant: B is clamped only by hold_b / ack_b, not by isolate
`else
  wire iso_b = isolate;
`endif
`ifdef GATE_MUTANT_NO_ISO_C
  wire iso_c = 1'b0;
`else
  wire iso_c = isolate;
`endif
`ifdef GATE_MUTANT_NO_ISO_D
  wire iso_d = 1'b0;
`else
  wire iso_d = isolate;
`endif
`ifdef GATE_MUTANT_NO_ISO_E
  wire iso_e = 1'b0;
`else
  wire iso_e = isolate;
`endif
  assign oa_valid = ia_valid && !blk && !iso_a;
  assign ia_ready = oa_ready && !blk && !iso_a;
  assign {oa_op, oa_param, oa_src, oa_addr, oa_data} = {ia_op, ia_param, ia_src, ia_addr, ia_data};
  assign id_valid = od_valid && !iso_d; assign od_ready = id_ready && !iso_d;
  assign {id_op, id_param, id_src, id_sink, id_data} = {od_op, od_param, od_src, od_sink, od_data};
  if (BCE) begin : g_bce
`ifdef GATE_MUTANT_NO_HOLDB
    wire hb = 1'b0;
`else
    wire hb = hold_b;
`endif
`ifdef GATE_MUTANT_NO_ACKB
    wire ab = 1'b0;                // mutant: Probes neither held nor answered (they reach the core)
`else
    wire ab = ack_b;
`endif
    // ack_b: the gate takes the Probe and answers ProbeAck NtoN itself, one at a time
    logic pend; logic [3:0] pend_addr;
    wire take_b = ab && !hb && !pend;
    assign ack_pend = pend;
    // B: clamped by isolate (a register), closed by hold_b (KEEP, and sDrain / sIso) or answered by the gate with
    // ack_b (FULL, in reset); B ready to L2 and B valid to the core drop in the cycle hold_b rises (TileLink 1.9.3
    // 4.1: an unaccepted beat may be withdrawn). Order as in CoreReset.scala: isolate, holdB, ackB / pending.
    assign ib_valid = ob_valid && !iso_b && !hb && !(ab || pend);
    assign ob_ready = (ab || pend) ? take_b : (ib_ready && !hb && !iso_b);
    assign {ib_param, ib_addr} = {ob_param, ob_addr};
`ifdef GATE_MUTANT_ACK_PARAM
    localparam logic [2:0] ACK_PARAM = 3'd1;   // mutant: reports TtoN (it had a copy)
`else
    localparam logic [2:0] ACK_PARAM = 3'd5;   // NtoN
`endif
    assign oc_valid = pend || (ic_valid && !iso_c); assign ic_ready = oc_ready && !pend && !iso_c;
    assign {oc_op, oc_param, oc_src, oc_addr, oc_data} = pend ? {3'd4, ACK_PARAM, 4'd0, pend_addr, 32'd0} :
                                                                {ic_op, ic_param, ic_src, ic_addr, ic_data};
    always_ff @(posedge clk)
      if (rst) pend <= 1'b0;
      else begin
        if (ob_valid && ob_ready && take_b) begin pend <= 1'b1; pend_addr <= ob_addr; end
        else if (pend && oc_ready) pend <= 1'b0;
`ifndef FORMAL
        if (isolate && !hold_b && !ack_b) $error("[%0t] %s: channel B open while XSCore is isolated", $time, NAME);
`endif
      end
    assign oe_valid = ie_valid && !iso_e; assign ie_ready = oe_ready && !iso_e; assign oe_sink = ie_sink;
  end else begin : g_ul
    assign ack_pend = 1'b0;
    assign ib_valid = 1'b0; assign ob_ready = 1'b1; assign {ib_param, ib_addr} = '0;
    assign oc_valid = 1'b0; assign ic_ready = 1'b1; assign {oc_op, oc_param, oc_src, oc_addr, oc_data} = '0;
    assign oe_valid = 1'b0; assign ie_ready = 1'b1; assign oe_sink = '0;
  end
  assign a_fire = ia_valid && ia_ready;
  assign b_fire = ib_valid && ib_ready;
  assign c_fire = ic_valid && ic_ready && BCE;
  assign d_fire = id_valid && id_ready;
  assign e_fire = ie_valid && ie_ready && BCE;

  wire d_rack  = od_op == 3'd6;
  wire d_grant = od_op == 3'd4 || od_op == 3'd5;
  wire c_pack  = ic_op == 3'd4 || ic_op == 3'd5;
  wire c_rel   = ic_op == 3'd6 || ic_op == 3'd7;
  logic [7:0] reqs, grants, probes, rels;
  always_ff @(posedge clk) begin
    if (rst) begin reqs <= '0; grants <= '0; probes <= '0; rels <= '0; end
    else begin
      reqs   <= reqs   + 8'(a_fire && a_first) - 8'(d_fire && d_last && !d_rack);
      grants <= grants + 8'(d_fire && d_first && d_grant) - 8'(e_fire);
      probes <= probes + 8'(b_fire) - 8'(c_fire && c_last && c_pack);
      rels   <= rels   + 8'(c_fire && c_last && c_rel) - 8'(d_fire && d_rack);
`ifndef FORMAL
      if (d_fire && d_last && !d_rack && reqs == 0 && !(a_fire && a_first)) $error("[%0t] %s: A->D underflow", $time, NAME);
      if (e_fire && grants == 0) $error("[%0t] %s: GrantAck underflow", $time, NAME);
`endif
    end
  end
`ifdef GATE_MUTANT_ALWAYS_QUIET
  assign quiet = 1'b1;           // mutant: reports quiet with transactions outstanding
`else
  assign quiet = reqs == 0 && a_first && d_first && (!BCE || (grants == 0 && probes == 0 && rels == 0 && c_first));
`endif
endmodule

// ---------------------------------------------------------------------------
// TLResetIsolation: TL-UL edge from the tile (in: the MMIO crossbar of L2Top) to a manager inside XSCore
// (out: the ICache control registers). While isolate is high nothing is offered to the core and none of its
// signals reaches the tile; quiet = no request waits for its response (counted on the tile side).
module cr_iso #(parameter NAME = "iso") (
  input  logic clk, rst,
  input  logic isolate, output logic quiet,
  // tile side (in)
  input  logic        ia_valid, output logic ia_ready, input logic [2:0] ia_op, input logic [3:0] ia_src,
  input  logic [3:0]  ia_addr, input logic [31:0] ia_data,
  output logic        id_valid, input  logic id_ready, output logic [2:0] id_op, output logic [3:0] id_src,
  output logic [31:0] id_data,
  // core side (out)
  output logic        oa_valid, input  logic oa_ready, output logic [2:0] oa_op, output logic [3:0] oa_src,
  output logic [3:0]  oa_addr, output logic [31:0] oa_data,
  input  logic        od_valid, output logic od_ready, input logic [2:0] od_op, input logic [3:0] od_src,
  input  logic [31:0] od_data
);
`ifdef ISO_MUTANT_NO_ISO
  wire iso = 1'b0;               // mutant: the edge is not isolated
`else
  wire iso = isolate;
`endif
  assign oa_valid = ia_valid && !iso; assign ia_ready = oa_ready && !iso;
  assign {oa_op, oa_src, oa_addr, oa_data} = {ia_op, ia_src, ia_addr, ia_data};
  assign id_valid = od_valid && !iso; assign od_ready = id_ready && !iso;
  assign {id_op, id_src, id_data} = {od_op, od_src, od_data};
  logic a_first, a_last, d_first, d_last;
  wire a_fire = ia_valid && ia_ready, d_fire = id_valid && id_ready;
  cr_beat u_ab (.clk, .rst, .fire(a_fire), .has_data(ia_op == 3'd0), .first(a_first), .last(a_last));
  cr_beat u_db (.clk, .rst, .fire(d_fire), .has_data(id_op == 3'd1), .first(d_first), .last(d_last));
  logic [7:0] reqs;
  always_ff @(posedge clk)
    if (rst) reqs <= '0;
    else begin
      reqs <= reqs + 8'(a_fire && a_first) - 8'(d_fire && d_last);
`ifndef FORMAL
      if (d_fire && d_last && reqs == 0 && !(a_fire && a_first)) $error("[%0t] %s: A->D underflow", $time, NAME);
      if (isolate && reqs != 0) $error("[%0t] %s: request in flight while XSCore is in reset", $time, NAME);
`endif
    end
`ifdef ISO_MUTANT_ALWAYS_QUIET
  assign quiet = 1'b1;
`else
  assign quiet = reqs == 0 && a_first;
`endif
endmodule

// ---------------------------------------------------------------------------
// CoreResetCtrl (v6), one-to-one with CoreReset.scala. st (state) is an extra output for the checkers (codes:
// 0 sIdle, 1 sQuiesce, 2 sDrain, 3 sIso, 4 sReset, 5 sRelease), not a port of the Scala module.
//   sIdle --req--> sQuiesce --l1_done && early_quiet--> sDrain --gates_quiet && l1_done && l1_idle--> sIso
//   sIso --ISO_CYCLES--> sReset --cnt >= RST_CYCLES && !req--> sRelease --l1_alive && !core_in_reset--> sIdle
//   (sRelease --> sQuiesce at once when req is high again, busy stays 1)
// Registers: state, cnt, busy_r, iso_r (isolate), crst_r (coreReset), rel_r (releasing).
module cr_ctrl #(parameter bit KEEP = 0, parameter int RST_CYCLES = 100, parameter int ISO_CYCLES = 1) (
  input  logic clk, rst,
  input  logic req, output logic busy, output logic in_reset, output logic hart_in_reset,
  output logic l1_req, output logic l1_freeze, input logic l1_done, input logic l1_idle,
  input  logic l1_alive, input logic core_in_reset,
  output logic early_block, output logic gate_block, output logic hold_probe, output logic ack_probe,
  input  logic early_quiet, input logic gates_quiet,
  output logic isolate,
  output logic core_reset, output logic [2:0] st
);
  localparam logic [2:0] S_IDLE = 3'd0, S_QUIESCE = 3'd1, S_DRAIN = 3'd2, S_ISO = 3'd3, S_RESET = 3'd4, S_RELEASE = 3'd5;
`ifdef CTRL_MUTANT_ISO_SHORT
  localparam int ISO_EFF = 1;          // mutant: sIso lasts one cycle whatever ISO_CYCLES says
`else
  localparam int ISO_EFF = ISO_CYCLES;
`endif
  logic [2:0] state; logic [7:0] cnt;
  logic busy_r, iso_r, crst_r, rel_r;
  assign st = state;
`ifdef CTRL_MUTANT_ISO_LATE
  localparam bit ISO_LATE = 1;         // mutant: isolate rises one cycle after the core reset
`else
  localparam bit ISO_LATE = 0;
`endif
`ifdef CTRL_MUTANT_ISO_EARLY_DROP
  localparam bit ISO_EARLY_DROP = 1;   // mutant: isolate drops with the core reset (not at the end of sRelease)
`else
  localparam bit ISO_EARLY_DROP = 0;
`endif
`ifdef CTRL_MUTANT_NO_ISO_LEAD
  localparam bit NO_ISO_LEAD = 1;      // mutant: sDrain -> sReset, isolate and core reset on the same edge
`else
  localparam bit NO_ISO_LEAD = 0;
`endif
`ifdef CTRL_MUTANT_BUSY_GAP
  localparam bit BUSY_GAP = 1;         // mutant: sRelease always goes to sIdle (busy drops for a cycle)
`else
  localparam bit BUSY_GAP = 0;
`endif
  // the DCache and the frontend come from the core reset domain: done and idle looked at only while the core
  // runs, alive and the frontend reset only in sRelease (the release of the core reset is synchronous)
  wire l1_done_m = l1_done && !iso_r;
`ifdef CTRL_MUTANT_NO_L1_IDLE
  wire l1_idle_m = 1'b1;                                         // mutant: the DCache idle flag is ignored
`else
  wire l1_idle_m = l1_idle && !iso_r;
`endif
`ifdef CTRL_MUTANT_NO_ALIVE
  wire core_up = rel_r && !core_in_reset;                        // mutant: the DCache is not waited for
`elsif CTRL_MUTANT_NO_FE_WAIT
  wire core_up = rel_r && l1_alive;                              // mutant: the frontend is not waited for
`else
  wire core_up = rel_r && l1_alive && !core_in_reset;
`endif
`ifdef CTRL_MUTANT_NO_EARLY_QUIET
  wire quiesce_end = l1_done_m;                                  // mutant: B closes while a Get may need a Probe
`else
  wire quiesce_end = l1_done_m && early_quiet;
`endif
  // quiet of this cycle; the mutant decides on the quiet of the PREVIOUS cycle, also in the first cycle of sDrain
  // (a Probe taken by the gate in the last cycle of sQuiesce then slips through)
  logic gq_q; always_ff @(posedge clk) gq_q <= gates_quiet;
`ifdef CTRL_MUTANT_STALE_QUIET
  wire gq = gq_q;
`else
  wire gq = gates_quiet;
`endif
`ifdef CTRL_MUTANT_NO_DRAIN
  wire drain_end = 1'b1;                                         // mutant: no wait at all
`else
  wire drain_end = gq && l1_done_m && l1_idle_m;
`endif
`ifdef CTRL_MUTANT_RESET_EARLY
  wire leave_reset = cnt >= RST_CYCLES;                          // mutant: the reset ends with the request high
`else
  wire leave_reset = cnt >= RST_CYCLES && !req;
`endif
  always_ff @(posedge clk) begin
    if (rst) begin state <= S_IDLE; cnt <= '0; busy_r <= 1'b0; iso_r <= 1'b0; crst_r <= 1'b0; rel_r <= 1'b0; end
    else case (state)
      S_IDLE:    if (req) begin state <= S_QUIESCE; busy_r <= 1'b1; end
      S_QUIESCE: if (quiesce_end) state <= S_DRAIN;
      S_DRAIN:   if (drain_end) begin
        if (NO_ISO_LEAD) begin state <= S_RESET; iso_r <= 1'b1; crst_r <= 1'b1; cnt <= '0; end
        else begin state <= S_ISO; iso_r <= !ISO_LATE; cnt <= '0; end
      end
      S_ISO: begin
        cnt <= cnt + 1'b1;
        if (cnt == 8'(ISO_EFF - 1)) begin state <= S_RESET; crst_r <= 1'b1; cnt <= '0; end
      end
      S_RESET: begin
        if (ISO_LATE) iso_r <= 1'b1;    // mutant ISO_LATE: the isolation rises one cycle after the core reset
        if (cnt < RST_CYCLES) cnt <= cnt + 1'b1;
        if (leave_reset) begin state <= S_RELEASE; crst_r <= 1'b0; rel_r <= 1'b1; if (ISO_EARLY_DROP) iso_r <= 1'b0; end
      end
      S_RELEASE: if (core_up) begin
        iso_r <= 1'b0; rel_r <= 1'b0;
        if (req && !BUSY_GAP) state <= S_QUIESCE; else begin state <= S_IDLE; busy_r <= 1'b0; end
      end
      default:   state <= S_IDLE;
    endcase
  end
  // CoreResetCtrl assertions (the assert statements of CoreReset.scala; not in the formal model, where the same
  // facts are the properties P1, P16, P21, P22): the registers follow the state, the isolation leads the core
  // reset, no TileLink traffic while isolated, the isolation drops only at the end of sRelease
`ifndef NO_CTRL_ASSERT
`ifndef FORMAL
  logic iso_q, rel_nr_q;
  always_ff @(posedge clk) begin iso_q <= rst ? 1'b0 : iso_r; rel_nr_q <= rst ? 1'b0 : (rel_r && !crst_r); end
  always_ff @(posedge clk) if (!rst) begin
    if (busy_r !== (state != S_IDLE)) $error("[%0t] CoreResetCtrl: busy out of step with the state", $time);
    if (iso_r !== (state == S_ISO || state == S_RESET || state == S_RELEASE)) $error("[%0t] CoreResetCtrl: isolate out of step with the state", $time);
    if (crst_r !== (state == S_RESET)) $error("[%0t] CoreResetCtrl: coreReset out of step with the state", $time);
    if (rel_r !== (state == S_RELEASE)) $error("[%0t] CoreResetCtrl: releasing out of step with the state", $time);
    if (crst_r && !iso_q) $error("[%0t] CoreResetCtrl: XSCore reset without an isolation lead", $time);
    if (iso_r && !gates_quiet) $error("[%0t] CoreResetCtrl: TileLink traffic between XSCore and L2 while XSCore is isolated", $time);
    if (iso_q && !iso_r && !rel_nr_q) $error("[%0t] CoreResetCtrl: isolation dropped outside sRelease", $time);
  end
`endif
`endif
  // outputs (CoreResetCtrl, section 2.2 of DESIGN.md)
  assign busy = busy_r;
`ifdef CTRL_MUTANT_LATE_HART_IN_RESET
  assign hart_in_reset = state == S_RESET || state == S_RELEASE; // mutant: hartInReset from sReset (as in v5)
`else
  assign hart_in_reset = busy_r;
`endif
  assign core_reset = crst_r;
`ifdef CTRL_MUTANT_IN_RESET_WIDE
  assign in_reset = state == S_RESET || state == S_RELEASE;      // mutant: inReset also in sRelease
`else
  assign in_reset = crst_r;
`endif
`ifdef CTRL_MUTANT_NO_REQ_IN_ISO
  assign l1_req = state == S_QUIESCE || state == S_DRAIN;        // mutant: the DCache unblocks in sIso
`else
  assign l1_req = state == S_QUIESCE || state == S_DRAIN || state == S_ISO;
`endif
`ifdef CTRL_MUTANT_LATE_FREEZE
  assign l1_freeze = KEEP && (crst_r || rel_r);                  // mutant: freeze with the core reset, not with isolate
`else
  assign l1_freeze = KEEP && iso_r;
`endif
  assign isolate = iso_r;
`ifdef CTRL_MUTANT_NO_EARLY_BLOCK
  assign early_block = state == S_DRAIN || iso_r;                // mutant: A of the non-coherent agents from sDrain (v4)
`else
  assign early_block = busy_r;
`endif
  assign gate_block = state == S_DRAIN || iso_r;
  // channel B, a function of the state register: closed in sDrain from its first cycle
`ifdef CTRL_MUTANT_LATE_HOLDB
  logic drain_q; always_ff @(posedge clk) drain_q <= rst ? 1'b0 : state == S_DRAIN;
  wire drain_b = state == S_DRAIN && drain_q;                    // mutant: B closed one cycle late
`else
  wire drain_b = state == S_DRAIN;
`endif
  if (KEEP) begin : g_keep
    // KEEP: held from sDrain to the end of sRelease (isolate), never answered
`ifdef CTRL_MUTANT_NO_HOLD_IN_RELEASE
    assign hold_probe = drain_b || state == S_ISO || state == S_RESET;   // mutant: released together with the reset
`else
    assign hold_probe = drain_b || iso_r;
`endif
    assign ack_probe = 1'b0;
  end else begin : g_full
    // FULL: held in sDrain and sIso (L1D alive, holds its lines), answered by the gate in sReset and sRelease
`ifdef CTRL_MUTANT_ACK_IN_ISO
    assign hold_probe = drain_b;
    assign ack_probe = iso_r;
`elsif CTRL_MUTANT_NOKEEP_HOLDB
    assign hold_probe = drain_b || state == S_ISO || state == S_RESET || state == S_RELEASE;   // mutant: held, not answered
    assign ack_probe = 1'b0;
`elsif CTRL_MUTANT_NO_HOLD_IN_RELEASE
    assign hold_probe = drain_b || state == S_ISO;
    assign ack_probe = state == S_RESET;                          // mutant: Probe goes to the core in sRelease
`else
    assign hold_probe = drain_b || state == S_ISO;
    assign ack_probe = crst_r || rel_r;
`endif
  end
endmodule

// ---------------------------------------------------------------------------
// DCacheQuiesceUnit (QuiesceUnit.scala): drain of the DCache. 0 sIdle, 1 sDrain, 2 sDone.
//   block = not sIdle, done = sDone, idle = the four emptiness flags of this cycle, alive = 0 in reset, 1 after.
// Mutants remove one flag from idle (both the output and the transition to sDone, as the flag is one signal).
module cr_quiesce (
  input  logic clk, rst,
  input  logic req, input logic mq_empty, wbq_empty, mp_empty, pq_empty,
  output logic block, output logic done, output logic idle, output logic alive
);
`ifdef QUIESCE_MUTANT_NO_MQ_WAIT
  wire mq_e = 1'b1;
`else
  wire mq_e = mq_empty;
`endif
`ifdef QUIESCE_MUTANT_NO_WBQ_WAIT
  wire wbq_e = 1'b1;
`else
  wire wbq_e = wbq_empty;
`endif
`ifdef QUIESCE_MUTANT_NO_MP_WAIT
  wire mp_e = 1'b1;
`else
  wire mp_e = mp_empty;
`endif
  logic [1:0] state;
  wire idle_w = mq_e && wbq_e && mp_e && pq_empty;
  always_ff @(posedge clk)
    if (rst) state <= 2'd0;
    else case (state)
      2'd0: if (req) state <= 2'd1;
      2'd1: if (!req) state <= 2'd0; else if (idle_w) state <= 2'd2;
      2'd2: if (!req) state <= 2'd0;
      default: state <= 2'd0;
    endcase
  assign block = state != 2'd0;
  assign done = state == 2'd2;
  assign idle = idle_w;
  logic alive_r; always_ff @(posedge clk) alive_r <= rst ? 1'b0 : 1'b1;
  assign alive = alive_r;
endmodule
