// ============================================================================
// Independent checkers on the L2 side of the gates (they do not look at the gate counters). v5.
//
//   cr_txmon    : every TileLink transaction between XSCore and L2, from its first beat to its
//                 last response: Acquire -> Grant(Data) -> GrantAck, Release(Data) -> ReleaseAck,
//                 Probe -> ProbeAck(Data), Get / PutFull -> AccessAck(Data).
//                 - the transactions open when the procedure starts are marked "pre";
//                 - at the reset point no transaction may be open (the pre ones must be complete);
//                 - nothing crosses the boundary in sReset / sRelease, no Probe crosses in sDrain;
//                 - no new request of a non-coherent agent after the start of the sequence (early block), and
//                   none of them is open when sDrain starts;
//                 - no Release starts after the DCache has reported its drain (l1.done);
//                 - every response matches an open request (no stale or duplicated response);
//                 - no transaction stays open longer than HANG cycles;
//                 - with the sweep the gate answers Probes while the core is in reset: such a Probe and its
//                   ProbeAck (NtoN, from the gate) are tracked apart, they are not a transaction with the core.
//   cr_probe_sb : every Probe and its ProbeAck: ProbeAckData carries the current (golden) data,
//                 a ProbeAck without data from a T copy means L2's data is current, the report
//                 matches L2's directory, the DCache state afterwards matches the cap; the Probes
//                 are classified by the phase in which L2 offered them and by whether the line was
//                 kept in L1D across a core reset (served from the hot L1D). No Probe waits more than
//                 MAX_WAIT cycles (a debugger may hold the reset request for any time); with KEEP the cycles
//                 while the core is in reset do not count (the Probe waits there by design).
//                 The report must match L2's directory exactly, in both configurations (NtoN only for a line
//                 the directory lists as N: the sweep left nothing behind).
// ============================================================================

// transaction classes (open states) used for triggers and coverage
//   0 ACQ_WAIT  Acquire accepted, no Grant beat yet          (C1)
//   1 GNT_MID   GrantData: first beat delivered, second not  (C2)
//   2 GACK      Grant delivered, GrantAck not yet            (C3)
//   3 REL_WAIT  Release(Data) complete, ReleaseAck not yet   (C4)
//   4 REL_MID   ReleaseData: first beat only                 (C5)
//   5 PRB_WAIT  Probe delivered, ProbeAck not yet            (C6)
//   6 PACK_MID  ProbeAckData: first beat only                (C7)
//   7 UL_WAIT   Get / PutFull complete, AccessAck not yet    (C8)
//   8 PUT_MID   PutFull: first beat only                     (C9)
//   9 UACK_MID  AccessAckData: first beat only               (C10)
module cr_txmon #(parameter int HANG = 8000) (
  input  logic clk, rst,
  input  logic start,                    // the controller leaves sIdle at this edge
  input  logic in_flush, in_drain, in_reset, in_release,
  input  logic l1_done,
  input  logic b_gate, c_gate,           // this B beat is taken by the gate / this C beat comes from the gate
  // L2 side of the DCache gate (TL-C)
  input  logic a_v, a_r, input logic [2:0] a_op, input logic [3:0] a_src,
  input  logic b_v, b_r, input logic [3:0] b_addr,
  input  logic c_v, c_r, input logic [2:0] c_op, input logic [2:0] c_param, input logic [3:0] c_src, input logic [3:0] c_addr,
  input  logic d_v, d_r, input logic [2:0] d_op, input logic [3:0] d_src,
  input  logic e_v, e_r,
  // L2 side of the uncached gate (TL-UL)
  input  logic ua_v, ua_r, input logic [2:0] ua_op, input logic [3:0] ua_src,
  input  logic ud_v, ud_r, input logic [2:0] ud_op, input logic [3:0] ud_src,
  output logic [9:0] open_cls,           // which classes are open now (for the directed triggers)
  output logic [9:0] start_cls,          // which classes were open when the last procedure started
  output int start_nopen,
  output int errors
);
  localparam int NC = 10;
  typedef enum int {NONE = -1, ACQ_WAIT = 0, GNT_MID = 1, GACK = 2, REL_WAIT = 3, REL_MID = 4,
                    PRB_WAIT = 5, PACK_MID = 6, UL_WAIT = 7, PUT_MID = 8, UACK_MID = 9} cls_t;
  localparam string CNAME [NC] = '{"Acquire waiting for Grant", "GrantData between beats", "Grant waiting for GrantAck",
    "Release waiting for ReleaseAck", "ReleaseData between beats", "Probe waiting for ProbeAck",
    "ProbeAckData between beats", "Get/Put waiting for AccessAck", "PutFull between beats", "AccessAckData between beats"};
  // one table per kind, indexed by source (A/C requests) or by address (Probes)
  cls_t acq [16], rel [16], prb [16], ul [16];
  logic acq_pre [16], rel_pre [16], prb_pre [16], ul_pre [16];
  longint acq_t [16], rel_t [16], prb_t [16], ul_t [16];
  longint cyc;
  // coverage
  int n_open_at_start [NC];    // open transactions at the start of a procedure, by class
  int n_pre_done [4];          // pre transactions completed before the reset point: acq, rel, prb, ul
  int n_started_flush [4], n_started_drain [4];
  int n_procedures, n_reset_points;
  int max_pre_latency;         // longest time from the procedure start to the completion of a pre transaction
  int gate_open, n_gate_probes; // Probes answered by the gate (sweep)
  longint t_start;

  always_comb begin
    open_cls = '0;
    for (int i = 0; i < 16; i++) begin
      if (acq[i] != NONE) open_cls[acq[i]] = 1'b1;
      if (rel[i] != NONE) open_cls[rel[i]] = 1'b1;
      if (prb[i] != NONE) open_cls[prb[i]] = 1'b1;
      if (ul[i]  != NONE) open_cls[ul[i]]  = 1'b1;
    end
  end

  wire fa = a_v && a_r, fd = d_v && d_r, fe = e_v && e_r;
  wire fb = b_v && b_r && !b_gate, fc = c_v && c_r && !c_gate;   // beats that cross to / from the core
  wire fbg = b_v && b_r && b_gate, fcg = c_v && c_r && c_gate;   // Probe taken / answered by the gate
  wire fua = ua_v && ua_r, fud = ud_v && ud_r;
  logic in_reset_q, in_drain_q;
  wire in_proc = in_flush || in_drain || in_reset || in_release;

  task automatic err(input string m);
    errors++; $display("[%0t] ERROR txmon: %s", $time, m);
  endtask
  // a transaction is complete: count it if it was open when the procedure started
  task automatic done(input int kind, input logic pre);
    if (pre) begin
      n_pre_done[kind]++;
      if (int'(cyc - t_start) > max_pre_latency) max_pre_latency = int'(cyc - t_start);
    end
  endtask
  task automatic started(input int kind);
    if (in_flush) n_started_flush[kind]++;
    if (in_drain) n_started_drain[kind]++;
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 16; i++) begin acq[i] = NONE; rel[i] = NONE; prb[i] = NONE; ul[i] = NONE; end
      cyc = 0; errors = 0; in_reset_q <= 1'b0; in_drain_q <= 1'b0; gate_open = 0;
    end else begin
      cyc++;
      in_reset_q <= in_reset; in_drain_q <= in_drain;
      // ---- procedure start: snapshot of what is in flight
      if (start) begin
        n_procedures++; t_start = cyc; start_cls <= open_cls; start_nopen <= n_open();
        for (int i = 0; i < 16; i++) begin
          acq_pre[i] = acq[i] != NONE; rel_pre[i] = rel[i] != NONE; prb_pre[i] = prb[i] != NONE; ul_pre[i] = ul[i] != NONE;
          if (acq[i] != NONE) n_open_at_start[acq[i]]++;
          if (rel[i] != NONE) n_open_at_start[rel[i]]++;
          if (prb[i] != NONE) n_open_at_start[prb[i]]++;
          if (ul[i]  != NONE) n_open_at_start[ul[i]]++;
        end
      end
      // ---- nothing crosses in sReset / sRelease
      if ((in_reset || in_release) && (fa || fb || fc || fd || fe || fua || fud))
        err($sformatf("TileLink beat between XSCore and L2 in %s (a%0d b%0d c%0d d%0d e%0d ua%0d ud%0d)",
            in_reset ? "sReset" : "sRelease", fa, fb, fc, fd, fe, fua, fud));
      // ---- sDrain: channel B is closed from its first cycle, no Probe crosses the gate
      if (in_drain && (fb || fbg)) err("a Probe crosses the gate in sDrain");
      // ---- the non-coherent agents: no new request once the sequence has started (channel A closed from
      // the first cycle of sFlush), none open when sDrain starts (a Get may wait for a Probe of L1D)
      if (in_proc && fua && ul[ua_src] == NONE) err($sformatf("new request of a non-coherent agent (source %0d) after the start of the sequence", ua_src));
      if (in_drain && !in_drain_q)
        for (int i = 0; i < 16; i++)
          if (ul[i] != NONE) err($sformatf("non-coherent request (source %0d, %s) still open when sDrain starts", i, CNAME[ul[i]]));
      // ---- reset point: no transaction open
      if (in_reset && !in_reset_q) begin
        n_reset_points++;
        for (int i = 0; i < 16; i++) begin
          if (acq[i] != NONE) err($sformatf("at the reset point: %s (source %0d, %0s, open since cycle %0d)", CNAME[acq[i]], i, acq_pre[i] ? "started before the procedure" : "started during the procedure", acq_t[i]));
          if (rel[i] != NONE) err($sformatf("at the reset point: %s (source %0d, %0s)", CNAME[rel[i]], i, rel_pre[i] ? "started before the procedure" : "started during the procedure"));
          if (prb[i] != NONE) err($sformatf("at the reset point: %s (address %0d, %0s)", CNAME[prb[i]], i, prb_pre[i] ? "started before the procedure" : "started during the procedure"));
          if (ul[i]  != NONE) err($sformatf("at the reset point: %s (source %0d, %0s)", CNAME[ul[i]], i, ul_pre[i] ? "started before the procedure" : "started during the procedure"));
        end
      end
      // ---- channel A (TL-C port): AcquireBlock / AcquirePerm
      if (fa) begin
        if (acq[a_src] != NONE) err($sformatf("Acquire with source %0d already in flight", a_src));
        acq[a_src] = ACQ_WAIT; acq_pre[a_src] = 1'b0; acq_t[a_src] = cyc; started(0);
      end
      // ---- the gate answers a Probe itself (sweep): one at a time, ProbeAck NtoN, nothing reaches the core
      if (fbg) begin
        n_gate_probes++; gate_open++;
        if (gate_open > 1) err("the gate took a second Probe before answering the first");
      end
      if (fcg) begin
        if (gate_open == 0) err("ProbeAck from the gate without a Probe");
        else gate_open--;
        if (c_op != 3'd4 || c_param != 3'd5) err($sformatf("the gate answers with opcode %0d param %0d (ProbeAck NtoN expected)", c_op, c_param));
      end
      // ---- channel B: Probe
      if (fb) begin
        if (prb[b_addr] != NONE) err($sformatf("second Probe of address %0d before its ProbeAck", b_addr));
        prb[b_addr] = PRB_WAIT; prb_pre[b_addr] = 1'b0; prb_t[b_addr] = cyc; started(2);
      end
      // ---- channel C: Release(Data) / ProbeAck(Data)
      if (fc) begin
        case (c_op)
          3'd6, 3'd7: begin
            if (rel[c_src] == NONE) begin
              if (l1_done || in_drain || in_reset || in_release) err("a Release starts after the DCache reported its drain (l1.done)");
              rel_pre[c_src] = 1'b0; rel_t[c_src] = cyc; started(1);
              rel[c_src] = (c_op == 3'd7) ? REL_MID : REL_WAIT;
            end else if (rel[c_src] == REL_MID && c_op == 3'd7) rel[c_src] = REL_WAIT;
            else err($sformatf("Release with source %0d while one is in flight", c_src));
          end
          3'd4, 3'd5: begin
            if (prb[c_addr] == PRB_WAIT) begin
              if (c_op == 3'd5) prb[c_addr] = PACK_MID;
              else begin done(2, prb_pre[c_addr]); prb[c_addr] = NONE; end
            end else if (prb[c_addr] == PACK_MID && c_op == 3'd5) begin done(2, prb_pre[c_addr]); prb[c_addr] = NONE; end
            else err($sformatf("ProbeAck of address %0d without a Probe", c_addr));
          end
          default: err($sformatf("illegal C opcode %0d", c_op));
        endcase
      end
      // ---- channel D (TL-C port): Grant(Data) / ReleaseAck
      if (fd) begin
        case (d_op)
          3'd4, 3'd5: begin
            if (acq[d_src] == ACQ_WAIT) acq[d_src] = (d_op == 3'd5) ? GNT_MID : GACK;
            else if (acq[d_src] == GNT_MID && d_op == 3'd5) acq[d_src] = GACK;
            else err($sformatf("Grant for source %0d without an Acquire (stale response)", d_src));
          end
          3'd6: begin
            if (rel[d_src] == REL_WAIT) begin done(1, rel_pre[d_src]); rel[d_src] = NONE; end
            else err($sformatf("ReleaseAck for source %0d without a Release (stale response)", d_src));
          end
          default: err($sformatf("illegal D opcode %0d", d_op));
        endcase
      end
      // ---- channel E: GrantAck (one Grant at a time per client in this model: match any)
      if (fe) begin
        automatic int k = -1;
        for (int i = 0; i < 16; i++) if (acq[i] == GACK) k = i;
        if (k < 0) err("GrantAck without a Grant");
        else begin done(0, acq_pre[k]); acq[k] = NONE; end
      end
      // ---- uncached port
      if (fua) begin
        if (ul[ua_src] == NONE) begin
          ul_pre[ua_src] = 1'b0; ul_t[ua_src] = cyc; started(3);
          ul[ua_src] = (ua_op == 3'd0) ? PUT_MID : UL_WAIT;
        end else if (ul[ua_src] == PUT_MID && ua_op == 3'd0) ul[ua_src] = UL_WAIT;
        else err($sformatf("uncached request with source %0d while one is in flight", ua_src));
      end
      if (fud) begin
        if (ul[ud_src] == UL_WAIT) begin
          if (ud_op == 3'd1) ul[ud_src] = UACK_MID;
          else begin done(3, ul_pre[ud_src]); ul[ud_src] = NONE; end
        end else if (ul[ud_src] == UACK_MID && ud_op == 3'd1) begin done(3, ul_pre[ud_src]); ul[ud_src] = NONE; end
        else err($sformatf("AccessAck for source %0d without a request (stale response)", ud_src));
      end
      // ---- hang
      for (int i = 0; i < 16; i++) begin
        if (acq[i] != NONE && cyc - acq_t[i] == HANG) err($sformatf("%s (source %0d) hangs", CNAME[acq[i]], i));
        if (rel[i] != NONE && cyc - rel_t[i] == HANG) err($sformatf("%s (source %0d) hangs", CNAME[rel[i]], i));
        if (prb[i] != NONE && cyc - prb_t[i] == HANG) err($sformatf("%s (address %0d) hangs", CNAME[prb[i]], i));
        if (ul[i]  != NONE && cyc - ul_t[i]  == HANG) err($sformatf("%s (source %0d) hangs", CNAME[ul[i]], i));
      end
    end
  end

  function automatic int n_open();
    int n = 0;
    for (int i = 0; i < 16; i++) n += int'(acq[i] != NONE) + int'(rel[i] != NONE) + int'(prb[i] != NONE) + int'(ul[i] != NONE);
    return n;
  endfunction
  task automatic report();
    $display("txmon: procedures=%0d reset-points=%0d open-at-end=%0d errors=%0d max-pre-latency=%0d probes-answered-by-gate=%0d",
             n_procedures, n_reset_points, n_open() + gate_open, errors, max_pre_latency, n_gate_probes);
    $write("txmon-open-at-start:");
    for (int k = 0; k < NC; k++) $write(" C%0d=%0d", k + 1, n_open_at_start[k]);
    $display("");
    $display("txmon-pre-completed: acquire=%0d release=%0d probe=%0d uncached=%0d",
             n_pre_done[0], n_pre_done[1], n_pre_done[2], n_pre_done[3]);
    $display("txmon-started-in-sFlush: acquire=%0d release=%0d probe=%0d uncached=%0d; in-sDrain: acquire=%0d release=%0d probe=%0d uncached=%0d",
             n_started_flush[0], n_started_flush[1], n_started_flush[2], n_started_flush[3],
             n_started_drain[0], n_started_drain[1], n_started_drain[2], n_started_drain[3]);
  endtask
endmodule

// ---------------------------------------------------------------------------
module cr_probe_sb #(parameter int MAX_WAIT = 200, parameter bit WAIT_IN_RESET = 0) (
  input  logic clk, rst,
  input  logic in_flush, in_drain, in_reset, in_release, busy,
  input  logic rp, input logic rp_keep,            // reset point, and whether L1D is kept at it
  // L2 side of the DCache gate
  input  logic b_v, b_r, input logic [1:0] b_param, input logic [3:0] b_addr,
  input  logic c_v, c_r, input logic [2:0] c_op, input logic [2:0] c_param, input logic [3:0] c_addr, input logic [31:0] c_data,
  input  logic a_fire, input logic [3:0] a_addr,
  // core side
  input  logic cb_v, input logic cb_r, input logic core_rst, input logic dc_alive,
  // state
  input  logic [1:0] dir [16], input logic [31:0] mem [16], input logic [31:0] golden [16],
  input  logic [1:0] l1 [16],                      // DCache state of every line: 0 N 1 B 2 T 3 dirty
  input  logic c_gate,                             // this C beat is the gate's ProbeAck
  // last ProbeAck (for the directed tests)
  output logic ack_v, output logic [3:0] ack_addr, output logic ack_data, output logic [31:0] ack_val,
  output logic [2:0] ack_param, output int errors
);
  // phase in which L2 first offered the Probe: 0 idle, 1 sFlush, 2 sDrain, 3 sReset, 4 sRelease
  int offer_ph; longint offer_t, cyc; logic b_v_q; int waited;
  int n_nton, n_gate_ack, n_wait_out_max;
  int pr_ph [16]; longint pr_t [16]; logic [1:0] pr_cap [16];
  logic [1:0] kept [16];           // state the line had in L1D at the last keep reset point (0: not kept)
  logic chk_v; logic [3:0] chk_addr; logic [1:0] chk_cap; logic chk_data; logic [31:0] chk_val;
  int n_by_phase [5], n_held_max; logic wait_err;
  int n_hot [4];                   // ProbeAck from a line kept across the reset: [1] B, [2] clean T, [3] dirty
  int n_hot_toB, n_dirty_data, n_clean_ack_t, n_core_offer_bad;
  logic mid_q;                     // between the two beats of a ProbeAckData

  task automatic err(input string m);
    errors++; $display("[%0t] ERROR probe-sb: %s", $time, m);
  endtask
  function automatic int phase();
    return in_reset ? 3 : in_release ? 4 : in_drain ? 2 : in_flush ? 1 : 0;
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      errors = 0; cyc = 0; b_v_q <= 1'b0; chk_v <= 1'b0; ack_v <= 1'b0;
      for (int i = 0; i < 16; i++) kept[i] = 2'd0;
    end else begin
      cyc++;
      b_v_q <= b_v && !b_r;
      ack_v <= 1'b0;
      // a Probe that L2 starts offering
      if (b_v && !b_v_q) begin offer_ph = phase(); offer_t = cyc; wait_err = 1'b0; waited = 0; end
      // a Probe must never wait long: L2 (and the HN behind it) would be stuck that long. With KEEP it waits
      // while the core is in reset (the request may be held for any time), by design.
      if (b_v && !b_r && !(WAIT_IN_RESET && (in_reset || in_release))) waited++;
      if (b_v && !b_r && !wait_err && waited >= MAX_WAIT) begin
        wait_err = 1'b1; err($sformatf("Probe of line %0d offered in phase %0d waits %0d cycles", b_addr, offer_ph, MAX_WAIT));
      end
      if (b_v && b_r) begin
        pr_ph[b_addr] = offer_ph; pr_t[b_addr] = cyc - offer_t; pr_cap[b_addr] = b_param;
        n_by_phase[offer_ph]++;
        if (int'(cyc - offer_t) > n_held_max) n_held_max = int'(cyc - offer_t);
        if (waited > n_wait_out_max) n_wait_out_max = waited;
      end
      // core side: never offered while the DCache is in reset or not alive
      if (cb_v && (core_rst || !dc_alive)) begin
        n_core_offer_bad++; err("Probe offered to the DCache while it is in reset / not alive");
      end
      // reset point: remember which lines L1D keeps
      if (rp) for (int i = 0; i < 16; i++) kept[i] = rp_keep ? l1[i] : 2'd0;
      // a line that L1D acquires again is no longer the kept copy
      if (a_fire) kept[a_addr] = 2'd0;
      // ---- after the ProbeAck: DCache state follows the cap, L2 has the data
      if (chk_v && !mid_q) begin
        chk_v <= 1'b0;
        if (chk_cap == 2'd2 && l1[chk_addr] != 2'd0) err($sformatf("line %0d still valid in L1D after a Probe toN", chk_addr));
        if (chk_cap == 2'd1 && l1[chk_addr] > 2'd1) err($sformatf("line %0d still T in L1D after a Probe toB", chk_addr));
        if (mem[chk_addr] != golden[chk_addr]) err($sformatf("after the ProbeAck L2 holds %h for line %0d, current value %h", mem[chk_addr], chk_addr, golden[chk_addr]));
        ack_v <= 1'b1; ack_addr <= chk_addr; ack_data <= chk_data; ack_val <= chk_val;
      end
      // ---- ProbeAck(Data): first beat carries the report and the data
      if (c_v && c_r && (c_op == 3'd4 || c_op == 3'd5) && !(c_op == 3'd5 && mid_q)) begin
        automatic logic [1:0] d = dir[c_addr];
        automatic logic ok_rep;
        // report vs L2 directory: T -> TtoN/TtoB/TtoT, B -> BtoN/BtoB, N -> NtoN
        case (d)
          2'd2:    ok_rep = c_param == 3'd1 || c_param == 3'd0 || c_param == 3'd3;
          2'd1:    ok_rep = c_param == 3'd2 || c_param == 3'd4;
          default: ok_rep = c_param == 3'd5;
        endcase
        if (ok_rep && c_param == 3'd5) n_nton++;
        if (c_gate) n_gate_ack++;
        if (!ok_rep) err($sformatf("ProbeAck of line %0d reports %0s, but L2's directory says %0s (L1D lost the line?)",
                                   c_addr, c_param == 3'd5 ? "NtoN" : $sformatf("param %0d", c_param), d == 2 ? "T" : d == 1 ? "B" : "N"));
        if (c_op == 3'd5) begin
          n_dirty_data++;
          if (c_data != golden[c_addr]) err($sformatf("ProbeAckData of line %0d carries %h, current value %h", c_addr, c_data, golden[c_addr]));
        end else if (d == 2'd2) begin
          n_clean_ack_t++;
          if (mem[c_addr] != golden[c_addr]) err($sformatf("clean ProbeAck from T of line %0d, but L2 holds %h, current value %h (dirty data lost)", c_addr, mem[c_addr], golden[c_addr]));
        end
        if (kept[c_addr] != 2'd0) begin
          n_hot[c_op == 3'd5 ? 3 : kept[c_addr]]++;
          if (pr_cap[c_addr] == 2'd1) n_hot_toB++;
          kept[c_addr] = 2'd0;
        end
        chk_v <= 1'b1; chk_addr <= c_addr; chk_cap <= pr_cap[c_addr]; chk_data <= c_op == 3'd5; chk_val <= c_data;
        ack_param <= c_param;
      end
      if (c_v && c_r && (c_op == 3'd6 || c_op == 3'd7)) kept[c_addr] = 2'd0;
    end
  end
  // ProbeAckData beat tracking (the first beat is the one checked)
  always_ff @(posedge clk)
    if (rst) mid_q <= 1'b0;
    else if (c_v && c_r && c_op == 3'd5) mid_q <= !mid_q;
    else if (c_v && c_r) mid_q <= 1'b0;

  task automatic report();
    $display("probe-sb: probes offered in idle=%0d sFlush=%0d sDrain(held)=%0d sReset(held)=%0d sRelease(held)=%0d longest-wait=%0d errors=%0d",
             n_by_phase[0], n_by_phase[1], n_by_phase[2], n_by_phase[3], n_by_phase[4], n_held_max, errors);
    $display("probe-sb: ProbeAckData=%0d clean-ProbeAck-from-T=%0d; from lines kept across a reset (hot L1D): dirty=%0d clean-T=%0d B=%0d (toB %0d)",
             n_dirty_data, n_clean_ack_t, n_hot[3], n_hot[2], n_hot[1], n_hot_toB);
    $display("probe-sb: NtoN-for-lines-not-held=%0d answered-by-the-gate=%0d longest-wait-outside-reset=%0d", n_nton, n_gate_ack, n_wait_out_max);
  endtask
endmodule
