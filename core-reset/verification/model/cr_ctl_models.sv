// ============================================================================
// Behavioral models of the new boundary logic, one-to-one with CoreReset.scala (v5):
//   cr_beat : TileLink first/last beat tracker (edge.firstlast)
//   cr_gate : TLQuiesceGate (with the isolation of the core side)
//   cr_iso  : TLResetIsolation (TL-UL edge whose manager is inside XSCore: ICache control registers)
//   cr_ctrl : CoreResetCtrl (level reset, early block of the non-coherent agents, B closed from the first cycle
//             of sDrain, exact emptiness flags)
// Synthesizable subset: used by the simulation and by the formal proof (formal/).
// Simplified TileLink encoding: see cr_env_models.sv.
// Configuration (SoCParameters): KEEP = CoreResetKeepL1 (1: L1D kept, 0: L1D swept and reset with the core);
// the simulation and the formal harness take it from the define CFG_SWEEP.
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
module cr_gate #(parameter bit BCE = 1, parameter NAME = "gate") (
  input  logic clk, rst,
  input  logic block, input logic hold_b, input logic ack_b, output logic quiet,
  input  logic isolate,                  // XSCore in reset or being released: the core side is ignored
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
    // B: closed by hold_b (KEEP, and in sDrain) or ack_b (sweep, in reset); B ready to L2 and B valid to the
    // core drop in the cycle hold_b rises (TileLink 1.8.1 4.1: an unaccepted beat may be withdrawn)
    assign ib_valid = ob_valid && !hb && !(ab || pend);
    assign ob_ready = (ab || pend) ? take_b : (ib_ready && !hb);
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
// CoreResetCtrl (v5). st (state) is an extra output for the checkers, it is not a port of the Scala module.
//   sIdle --req--> sFlush --l1_done && early_quiet--> sDrain --gates_quiet && l1_done && l1_idle--> sReset
//   sReset --cnt >= RST_CYCLES && !req--> sRelease --l1_alive && !core_in_reset--> sIdle
module cr_ctrl #(parameter bit KEEP = 1, parameter int RST_CYCLES = 100) (
  input  logic clk, rst,
  input  logic req, output logic busy, output logic in_reset, output logic hart_in_reset,
  output logic l1_flush_req, output logic l1_freeze, input logic l1_flush_done, input logic l1_idle,
  input  logic l1_alive, input logic core_in_reset,
  output logic early_block, output logic gate_block, output logic hold_probe, output logic ack_probe,
  input  logic early_quiet, input logic gates_quiet,
  output logic isolate,
  output logic core_reset, output logic [2:0] st
);
  localparam logic [2:0] S_IDLE = 3'd0, S_FLUSH = 3'd1, S_DRAIN = 3'd2, S_RESET = 3'd3, S_RELEASE = 3'd4;
  logic [2:0] state; logic [7:0] cnt; logic hir;
  // closed: sReset or sRelease, as a register raised on the same edge as core_reset (CoreResetCtrl.closed)
  logic closed;
`ifdef CTRL_MUTANT_ISO_LATE
  localparam bit ISO_LATE = 1;         // mutant: isolate rises one cycle after the core reset
`else
  localparam bit ISO_LATE = 0;
`endif
`ifdef CTRL_MUTANT_ISO_EARLY_DROP
  localparam bit ISO_EARLY_DROP = 1;   // mutant: isolate drops with the core reset request (not in sRelease)
`else
  localparam bit ISO_EARLY_DROP = 0;
`endif
  assign st = state;
  // the DCache and the frontend come from the core reset domain: done and idle looked at only while the core
  // runs, alive and the frontend reset only in sRelease (the release of the core reset is synchronous)
  wire l1_done_m = l1_flush_done && !closed;
`ifdef CTRL_MUTANT_NO_L1_IDLE
  wire l1_idle_m = 1'b1;                                         // mutant: the DCache idle flag is ignored
`else
  wire l1_idle_m = l1_idle && !closed;
`endif
`ifdef CTRL_MUTANT_NO_ALIVE
  wire core_up = !core_in_reset && state == S_RELEASE;          // mutant: the DCache is not waited for
`elsif CTRL_MUTANT_NO_FE_WAIT
  wire core_up = l1_alive && state == S_RELEASE;                // mutant: the frontend is not waited for
`else
  wire core_up = l1_alive && !core_in_reset && state == S_RELEASE;
`endif
`ifdef CTRL_MUTANT_NO_EARLY_QUIET
  wire flush_end = l1_done_m;                                    // mutant: B closes while a Get may need a Probe
`else
  wire flush_end = l1_done_m && early_quiet;
`endif
  // quiet of this cycle; the mutant uses the registered value of the previous cycle
  logic gq_q; always_ff @(posedge clk) gq_q <= gates_quiet;
`ifdef CTRL_MUTANT_STALE_QUIET
  wire gq = gq_q && state == S_DRAIN && cnt != 0;
`else
  wire gq = gates_quiet;
`endif
`ifdef CTRL_MUTANT_RESET_EARLY
  wire leave_reset = cnt >= RST_CYCLES;                          // mutant: the reset ends with the request high
`else
  wire leave_reset = cnt >= RST_CYCLES && !req;
`endif
  always_ff @(posedge clk) begin
    if (rst) begin state <= S_IDLE; cnt <= '0; core_reset <= 1'b0; hir <= 1'b0; closed <= 1'b0; end
    else case (state)
      S_IDLE:    begin cnt <= '0; if (req) state <= S_FLUSH; end
      S_FLUSH:   if (flush_end) begin state <= S_DRAIN; cnt <= '0; end
      S_DRAIN:   begin
        if (cnt != 8'hff) cnt <= cnt + 1'b1;     // cycles in sDrain (STALE_QUIET mutant only)
`ifdef CTRL_MUTANT_NO_DRAIN
        begin state <= S_RESET; cnt <= '0; core_reset <= 1'b1; hir <= 1'b1; closed <= !ISO_LATE; end      // no wait at all
`else
        if (gq && l1_done_m && l1_idle_m) begin state <= S_RESET; cnt <= '0; core_reset <= 1'b1; hir <= 1'b1; closed <= !ISO_LATE; end
`endif
      end
      S_RESET:   begin
        if (ISO_LATE) closed <= 1'b1;   // mutant: the isolation rises one cycle after the core reset
        if (cnt < RST_CYCLES) cnt <= cnt + 1'b1;
        if (leave_reset) begin state <= S_RELEASE; cnt <= '0; core_reset <= 1'b0; closed <= !ISO_EARLY_DROP; end
      end
      S_RELEASE: begin
        if (core_up) begin state <= S_IDLE; closed <= 1'b0; hir <= 1'b0; end
      end
      default:   state <= S_IDLE;
    endcase
  end
  // CoreResetCtrl assertions: no traffic across the boundary while the core is in reset; the isolation
  // covers the core reset
`ifndef NO_CTRL_ASSERT
`ifndef FORMAL
  always_ff @(posedge clk) if (!rst && state == S_RESET && !gates_quiet) $error("[%0t] CoreResetCtrl: TileLink traffic between XSCore and L2 while XSCore is in reset", $time);
  always_ff @(posedge clk) if (!rst && core_reset && !closed) $error("[%0t] CoreResetCtrl: XSCore reset without isolation", $time);
  always_ff @(posedge clk) if (!rst && closed != (state == S_RESET || state == S_RELEASE)) $error("[%0t] CoreResetCtrl: isolation out of step with the state", $time);
`endif
`endif
  assign busy = state != S_IDLE;
  assign in_reset = state == S_RESET;
  assign hart_in_reset = hir;
  assign l1_flush_req = state == S_FLUSH || state == S_DRAIN;
  assign l1_freeze = KEEP && closed;
  assign isolate = closed;
`ifdef CTRL_MUTANT_NO_EARLY_BLOCK
  assign early_block = state == S_DRAIN || closed;               // mutant: A of the non-coherent agents from sDrain (v4)
`else
  assign early_block = state != S_IDLE;
`endif
  assign gate_block = state == S_DRAIN || closed;
  // channel B: closed in sDrain from its first cycle (a function of the state register)
`ifdef CTRL_MUTANT_LATE_HOLDB
  logic drain_q; always_ff @(posedge clk) drain_q <= rst ? 1'b0 : state == S_DRAIN;
  wire drain_b = state == S_DRAIN && drain_q;                    // mutant: B closed one cycle late
`else
  wire drain_b = state == S_DRAIN;
`endif
  // while the core is in reset: held in L2 (KEEP) or answered by the gate (sweep)
`ifdef CTRL_MUTANT_NO_HOLD_IN_RELEASE
  wire probe_closed = state == S_RESET;                          // mutant: Probe released together with the core reset
`else
  wire probe_closed = closed;
`endif
`ifdef CTRL_MUTANT_NOKEEP_HOLDB
  assign hold_probe = drain_b || probe_closed;                   // mutant: no KEEP, but Probes held instead of answered
  assign ack_probe = 1'b0;
`else
  assign hold_probe = drain_b || (KEEP && probe_closed);
  assign ack_probe = !KEEP && probe_closed;
`endif
endmodule
