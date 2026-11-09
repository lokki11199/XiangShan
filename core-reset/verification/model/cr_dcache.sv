// ============================================================================
// cr_dcache: behavioral model of the L1 DCache for the XSCore-only reset (v5): TL-C client with
//   MissQueue (1 entry), WritebackQueue (2 Release entries + the ProbeAck slot pa), ProbeQueue (entry pq_v and
//   the register in front of MainPipe pq_sel), MainPipe with three stages s1..s3 and DCacheFlushUnit
//   (FlushUnit.scala). Random loads/stores, golden memory updated where a store is applied (MainPipe s3, or the
//   refill of a store miss).
//   MainPipe: probes (K_PROBE), stores (K_STORE) and flush requests of the sweep (K_FLUSH, lowest priority).
//     A request enters s1 only if no request of the same set is in s1..s3 (set-conflict check), moves one stage
//     per cycle and is applied in s3, after a data-write delay dw of 0..2 cycles (0..6 with slow). In s3:
//       K_PROBE : report and data of the line, new coherence state; ProbeAck into the slot pa (needs it free)
//       K_STORE : hit T/D -> write; hit B -> BtoT upgrade through the MissQueue; miss -> AcquireBlock /
//                 AcquirePerm (full-line store) with a victim, if the MissQueue and the victim allow; else replay
//       K_FLUSH : (sweep) a valid line -> Release / ReleaseData into a free WritebackQueue entry, line invalid.
//                 It does not wait for the ProbeQueue (a Probe in the ProbeQueue waits for the set of this
//                 flush to leave MainPipe: waiting the other way round would deadlock).
//   Exact emptiness flags, the same four as DCacheFlushUnit in the RTL:
//     mq_empty  MissQueue empty            wb_empty WritebackQueue (Releases, ProbeAck slot, beat in transfer)
//     mp_empty  nothing in s1..s3          pq_empty no Probe in the ProbeQueue or in front of MainPipe
//   flush unit: F_IDLE -req-> F_DRAIN -idle-> F_SWEEP (sweep) / F_DONE (keep); F_SWEEP: one flush request per
//     (set, way), way-major; F_WAIT -no flush request in MainPipe and idle-> F_DONE.
//   KEEP = 1 (CoreResetKeepL1): the coherence meta (st) is on the tile reset (meta_rst), tags/data are never
//   reset (SRAMs, writes masked by freeze): L1D keeps its lines. KEEP = 0 (sweep): meta on the core reset.
//   Reset domain crossing: right after the core reset is asserted (1..4 cycles) every output of the DCache and
//   every write enable of its arrays is random (GARBAGE); the isolation on the tile side must keep it from L2.
// Simplified TileLink: see cr_env_models.sv.
// Mutants: FLUSH_MUTANT_NO_BLOCK, FLUSH_MUTANT_NO_WBQ_WAIT, FLUSH_MUTANT_NO_MP_WAIT, FLUSH_MUTANT_NO_SWEEP,
//   FLUSH_MUTANT_SWEEP_NO_WAIT, FLUSH_MUTANT_SWEEP_NO_DATA, FLUSH_MUTANT_SWEEP_ONE_WAY, META_MUTANT_CORE_RESET,
//   NOKEEP_MUTANT_META_KEPT, FREEZE_MUTANT_NO_SRAM_MASK.
// ============================================================================
module cr_dcache #(parameter int NS = 4, parameter int NW = 2, parameter bit KEEP = 1, parameter bit GARBAGE = 1) (
  input  logic clk, rst,                 // rst = core reset
  input  logic meta_rst,                 // tile reset: coherence meta array (L1CohMetaArray)
  input  logic traffic_en,               // core is executing (random loads/stores)
  input  logic slow,                     // the ProbeQueue is sometimes not ready, long data-write delays
  input  logic flush_req, input logic freeze, output logic flush_done, output logic flush_idle,
  output logic alive,                    // control logic out of reset
  output logic busy_true,                // the real state: some part of the control logic is not empty (tb only)
  output logic ld_v, output logic [3:0] ld_addr, output logic [31:0] ld_data,   // load hit (checked by the tb)
  output logic        a_valid, input  logic a_ready, output logic [2:0] a_op, output logic [1:0] a_param,
  output logic [3:0]  a_src, output logic [3:0] a_addr, output logic [31:0] a_data,
  input  logic        b_valid, output logic b_ready, input logic [1:0] b_param, input logic [3:0] b_addr,
  output logic        c_valid, input  logic c_ready, output logic [2:0] c_op, output logic [2:0] c_param,
  output logic [3:0]  c_src, output logic [3:0] c_addr, output logic [31:0] c_data,
  input  logic        d_valid, output logic d_ready, input logic [2:0] d_op, input logic [1:0] d_param,
  input  logic [3:0]  d_src, input logic [3:0] d_sink, input logic [31:0] d_data,
  output logic        e_valid, input  logic e_ready, output logic [3:0] e_sink,
  // golden memory update (store applied in the DCache)
  output logic        gold_we, output logic [3:0] gold_addr, output logic [31:0] gold_data,     // store in s3
  output logic        gold_we2, output logic [3:0] gold_addr2, output logic [31:0] gold_data2,  // store at refill
  output int          n_ops
);
  localparam logic [1:0] N = 2'd0, B = 2'd1, T = 2'd2, D = 2'd3;
  localparam bit SWEEP = !KEEP;
  localparam int WB = $clog2(NW), SB = $clog2(NS);
  localparam logic [1:0] K_PROBE = 2'd0, K_STORE = 2'd1, K_FLUSH = 2'd2;
  localparam logic [2:0] F_IDLE = 3'd0, F_DRAIN = 3'd1, F_SWEEP = 3'd2, F_WAIT = 3'd3, F_DONE = 3'd4;
  // sweep mutants
`ifdef FLUSH_MUTANT_NO_SWEEP
  localparam bit NO_SWEEP = 1;        // the drain only: L1D is reset with its lines (the removed full reset)
`else
  localparam bit NO_SWEEP = 0;
`endif
`ifdef FLUSH_MUTANT_SWEEP_NO_WAIT
  localparam bit SWEEP_NO_WAIT = 1;   // done right after the last flush request, Releases still queued
`else
  localparam bit SWEEP_NO_WAIT = 0;
`endif
`ifdef FLUSH_MUTANT_SWEEP_NO_DATA
  localparam bit SWEEP_NO_DATA = 1;   // a dirty line is released without its data
`else
  localparam bit SWEEP_NO_DATA = 0;
`endif
`ifdef FLUSH_MUTANT_SWEEP_ONE_WAY
  localparam bit SWEEP_ONE_WAY = 1;   // the sweep stops after way 0
`else
  localparam bit SWEEP_ONE_WAY = 0;
`endif

  // outputs as computed by the (running) DCache; the ports carry them, or garbage right after the reset
  logic a_valid_i, b_ready_i, c_valid_i, d_ready_i, e_valid_i, flush_done_i, flush_idle_i, alive_i;
  logic [2:0] a_op_i, c_op_i, c_param_i; logic [1:0] a_param_i; logic [3:0] a_src_i, a_addr_i, c_src_i, c_addr_i, e_sink_i;
  logic [31:0] a_data_i, c_data_i;
  logic [1:0]  st  [NS][NW];
  logic [1:0]  tg  [NS][NW];
  logic [31:0] dat [NS][NW];

  // miss queue (1 entry); mq_perm: AcquirePerm (full-line store miss)
  logic mq_v, mq_sent, mq_gotd, mq_store, mq_perm; logic [3:0] mq_addr; logic [31:0] mq_val; logic [WB-1:0] mq_way;
  logic [1:0] mq_grow; logic [3:0] mq_sink; logic mq_dbeat; logic [31:0] mq_d0;
  // writeback queue (2 Release entries)
  logic       wb_v [2]; logic wb_sent [2]; logic [3:0] wb_addr [2]; logic wb_hasd [2]; logic [31:0] wb_data [2]; logic [2:0] wb_param [2];
  // ProbeAck slot (the ProbeAck of the probe that left s3)
  logic pa_v; logic [2:0] pa_op, pa_param; logic [3:0] pa_addr; logic [31:0] pa_data;
  // probe queue: entry, and the register in front of MainPipe (selected)
  logic pq_v, pq_sel; logic [3:0] pq_addr; logic [1:0] pq_param;
  // MainPipe stages 1..3
  logic mv [4]; logic [1:0] mk [4]; logic [3:0] ma [4]; logic [31:0] mval [4]; logic [1:0] mcap [4]; logic [WB-1:0] mw [4];
  logic mperm [4];
  int dw;                                   // data-write delay of the request in s3
  // flush unit
  logic [2:0] fst; logic [SB-1:0] fset; logic [WB-1:0] fway; logic [2:0] inflight;
  wire block = fst != F_IDLE;
  assign flush_done_i = fst == F_DONE;
  // C channel: second beat of a data message
  logic c_busy, c_isprobe; int c_wbi;
  logic [2:0] cl_param; logic [3:0] cl_addr, cl_src; logic [31:0] cl_data;

  function automatic int find_way(input logic [3:0] addr);
    for (int w = 0; w < NW; w++) if (st[addr[1:0]][w] != N && tg[addr[1:0]][w] == addr[3:2]) return w;
    return -1;
  endfunction
  // a Release or ProbeAck of the line is still in the WritebackQueue (the next Acquire / Probe of the line waits)
  function automatic logic wb_conflict(input logic [3:0] addr);
    for (int i = 0; i < 2; i++) if (wb_v[i] && wb_addr[i] == addr) return 1'b1;
    if (pa_v && pa_addr == addr) return 1'b1;
    if (c_busy && c_isprobe && cl_addr == addr) return 1'b1;
    return 1'b0;
  endfunction
  function automatic int wb_free();
    for (int i = 0; i < 2; i++) if (!wb_v[i]) return i;
    return -1;
  endfunction
  // a MainPipe stage other than skip holds a request of this set
  function automatic logic mp_set_busy(input logic [SB-1:0] set, input int skip);
    for (int i = 1; i <= 3; i++) if (i != skip && mv[i] && ma[i][SB-1:0] == set) return 1'b1;
    return 1'b0;
  endfunction
  // a MainPipe stage other than skip works on this line (or on its set, for a flush request)
  function automatic logic mp_line_busy(input logic [3:0] addr, input int skip);
    for (int i = 1; i <= 3; i++)
      if (i != skip && mv[i] && (mk[i] == K_FLUSH ? ma[i][SB-1:0] == addr[SB-1:0] : ma[i] == addr)) return 1'b1;
    return 1'b0;
  endfunction
  // way for a new line: an invalid way, else the victim vw_rnd if it can be evicted now (free WritebackQueue
  // entry, no Release / ProbeAck of the victim queued, the victim not in MainPipe or in the ProbeQueue)
  function automatic logic can_alloc(input logic [3:0] addr, input int vw_rnd, input int skip, output int vw);
    vw = -1;
    for (int k = 0; k < NW; k++) if (vw < 0 && st[addr[1:0]][k] == N) vw = k;
    if (vw >= 0) return 1'b1;
    begin
      automatic logic [3:0] va = {tg[addr[1:0]][vw_rnd], addr[1:0]};
      if (wb_free() >= 0 && !wb_conflict(va) && !mp_line_busy(va, skip) && !(pq_v && pq_addr == va)) begin
        vw = vw_rnd; return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // ---------------- emptiness flags (DCacheFlushUnit) ----------------
  wire mq_empty = !mq_v;
  wire wb_empty = !wb_v[0] && !wb_v[1] && !pa_v && !c_busy;
  wire mp_empty = !mv[1] && !mv[2] && !mv[3];
  wire pq_empty = !pq_v && !pq_sel;
`ifdef FLUSH_MUTANT_NO_WBQ_WAIT
  wire idle = mq_empty && mp_empty && pq_empty;              // mutant: Releases / ProbeAcks not waited for
`elsif FLUSH_MUTANT_NO_MP_WAIT
  wire idle = mq_empty && wb_empty && pq_empty;              // mutant: MainPipe not waited for
`else
  wire idle = mq_empty && wb_empty && mp_empty && pq_empty;
`endif
  assign flush_idle_i = idle;
  assign busy_true = !(mq_empty && wb_empty && mp_empty && pq_empty);

  // ---------------- C channel: second beat, then the ProbeAck slot, then Releases ----------------
  int wb_sel;
  always_comb begin
    wb_sel = -1;
    for (int i = 1; i >= 0; i--) if (wb_v[i] && !wb_sent[i]) wb_sel = i;
  end
  always_comb begin
    c_valid_i = 1'b0; c_op_i = '0; c_param_i = '0; c_src_i = '0; c_addr_i = '0; c_data_i = '0;
    if (c_busy) begin
      c_valid_i = 1'b1; c_op_i = c_isprobe ? 3'd5 : 3'd7; c_param_i = cl_param; c_addr_i = cl_addr; c_src_i = cl_src;
      c_data_i = ~cl_data;
    end else if (pa_v) begin
      c_valid_i = 1'b1; c_op_i = pa_op; c_param_i = pa_param; c_addr_i = pa_addr; c_data_i = pa_data;
    end else if (wb_sel >= 0) begin
      c_valid_i = 1'b1; c_op_i = wb_hasd[wb_sel] ? 3'd7 : 3'd6; c_param_i = wb_param[wb_sel]; c_addr_i = wb_addr[wb_sel];
      c_data_i = wb_data[wb_sel]; c_src_i = 4'(8 + wb_sel);
    end
  end
  // ProbeQueue ready; with slow it is sometimes busy, so L2 offers a Probe that is not accepted at once
  logic [31:0] stl; always_ff @(posedge clk) stl <= $urandom;
  assign b_ready_i = !pq_v && (!slow || stl[1:0] != 2'b00);

  // ---------------- A, D, E ----------------
  assign a_valid_i = mq_v && !mq_sent;
  assign a_op_i = mq_perm ? 3'd7 : 3'd6; assign a_param_i = mq_grow; assign a_src_i = 4'd1; assign a_addr_i = mq_addr;
  assign a_data_i = '0;
  assign d_ready_i = 1'b1;
  assign e_valid_i = mq_v && mq_gotd; assign e_sink_i = mq_sink;

  // ---------------- reset domain crossing: the first 1..4 cycles of a core reset ----------------
  logic rst_q; logic [1:0] garb_n; logic [31:0] gr, gr2;
  always_ff @(posedge clk) begin
    rst_q <= rst; gr <= $urandom; gr2 <= $urandom;
    if (rst && !rst_q) garb_n <= 2'($urandom_range(0, 3)); else if (garb_n != 0) garb_n <= garb_n - 1'b1;
  end
  wire garb = GARBAGE && rst && !meta_rst && (!rst_q || garb_n != 0);
  assign a_valid = garb ? gr[0] : a_valid_i;   assign a_op = garb ? gr[3:1] : a_op_i;
  assign a_param = garb ? gr[5:4] : a_param_i; assign a_src = garb ? gr[9:6] : a_src_i;
  assign a_addr = garb ? gr[13:10] : a_addr_i; assign a_data = garb ? gr2 : a_data_i;
  assign b_ready = garb ? gr[14] : b_ready_i;
  assign c_valid = garb ? gr[15] : c_valid_i;  assign c_op = garb ? gr[18:16] : c_op_i;
  assign c_param = garb ? gr[21:19] : c_param_i; assign c_src = garb ? gr[25:22] : c_src_i;
  assign c_addr = garb ? gr[29:26] : c_addr_i; assign c_data = garb ? ~gr2 : c_data_i;
  assign d_ready = garb ? gr[30] : d_ready_i;
  assign e_valid = garb ? gr[31] : e_valid_i;  assign e_sink = garb ? gr2[3:0] : e_sink_i;
  assign flush_done = garb ? gr2[4] : flush_done_i;
  assign flush_idle = garb ? gr2[6] : flush_idle_i;
  assign alive = garb ? gr2[5] : alive_i;

  logic [31:0] rnd; always_ff @(posedge clk) rnd <= $urandom;

  // ---------------- MainPipe s3: can the request be applied in this cycle ----------------
  wire s3_line_valid = mv[3] && mk[3] == K_FLUSH && st[ma[3][SB-1:0]][mw[3]] != N;
  logic s3_go;
  always_comb begin
    s3_go = 1'b0;
    if (mv[3] && dw == 0)
      case (mk[3])
        K_PROBE: s3_go = !pa_v;
        K_STORE: s3_go = 1'b1;                                   // applied, or replayed (not modelled further)
        default: s3_go = !s3_line_valid || (wb_free() >= 0 &&
                         !wb_conflict({tg[ma[3][SB-1:0]][mw[3]], ma[3][SB-1:0]}));
      endcase
  end
  wire s3_free = !mv[3] || s3_go;
  wire s2_move = mv[2] && s3_free;
  wire s1_move = mv[1] && (!mv[2] || s2_move);
  wire s1_free = !mv[1] || s1_move;
  // s0 arbitration: Probe > store > flush; the set must not be in MainPipe
  wire pq_go = pq_sel && s1_free && !mp_set_busy(pq_addr[SB-1:0], 0) && !wb_conflict(pq_addr);
`ifdef FLUSH_MUTANT_NO_BLOCK
  wire st_try = traffic_en && rnd[1:0] == 2'b00 && rnd[8] && (!block || rnd[10]);   // stores keep coming in the flush
`else
  wire st_try = traffic_en && !block && rnd[1:0] == 2'b00 && rnd[8];
`endif
  wire [3:0] st_addr = rnd[7:4];
  wire st_go = st_try && !pq_go && s1_free && !mp_set_busy(st_addr[SB-1:0], 0);
  wire fl_go = fst == F_SWEEP && !NO_SWEEP && !pq_go && !st_go && s1_free && !mp_set_busy(fset, 0);

  always_ff @(posedge clk) begin
    gold_we <= 1'b0; gold_we2 <= 1'b0; ld_v <= 1'b0;
    if (rst) begin
`ifdef META_MUTANT_CORE_RESET
      for (int s = 0; s < NS; s++) for (int w = 0; w < NW; w++) st[s][w] <= N;     // KEEP mutant: meta on the core reset
`elsif NOKEEP_MUTANT_META_KEPT
      if (meta_rst) for (int s = 0; s < NS; s++) for (int w = 0; w < NW; w++) st[s][w] <= N;  // no-KEEP mutant: meta survives
`else
      // KEEP: meta on the tile reset; sweep: meta on the core reset (L1D starts empty)
      if (meta_rst || !KEEP) for (int s = 0; s < NS; s++) for (int w = 0; w < NW; w++) st[s][w] <= N;
`endif
      // the write enables of the arrays come from the control logic, random while the reset ripples; with
      // KEEP the arrays survive the reset and freeze masks the writes (DCacheWrapper)
`ifdef FREEZE_MUTANT_NO_SRAM_MASK
      if (garb && gr2[8]) begin                            // mutant: tag / data SRAM writes not masked
        tg[gr2[10:9] % NS][gr2[11] % NW] <= gr2[13:12]; dat[gr2[10:9] % NS][gr2[11] % NW] <= gr;
      end
`else
      if (garb && gr2[8] && !freeze) begin
        tg[gr2[10:9] % NS][gr2[11] % NW] <= gr2[13:12]; dat[gr2[10:9] % NS][gr2[11] % NW] <= gr;
      end
`endif
      if (garb && gr2[14] && !freeze && KEEP) st[gr2[16:15] % NS][gr2[17] % NW] <= gr2[19:18];
      mq_v <= 1'b0; mq_sent <= 1'b0; mq_gotd <= 1'b0; mq_dbeat <= 1'b0; mq_perm <= 1'b0;
      for (int i = 0; i < 2; i++) begin wb_v[i] <= 1'b0; wb_sent[i] <= 1'b0; end
      pa_v <= 1'b0; pq_v <= 1'b0; pq_sel <= 1'b0; c_busy <= 1'b0;
      for (int i = 1; i <= 3; i++) mv[i] <= 1'b0;
      dw <= 0; fst <= F_IDLE; fset <= '0; fway <= '0; inflight <= '0; n_ops <= 0;
    end else begin
      // ---- B: accept a Probe into the ProbeQueue; one cycle later it is selected for MainPipe
      if (b_valid && b_ready_i) begin pq_v <= 1'b1; pq_sel <= 1'b0; pq_addr <= b_addr; pq_param <= b_param; end
      else if (pq_v && !pq_sel) pq_sel <= 1'b1;
      // ---- C: send
      if (c_valid_i && c_ready) begin
        if (c_busy) begin
          c_busy <= 1'b0;
          if (!c_isprobe) wb_sent[c_wbi] <= 1'b1;
        end else if (pa_v) begin
          pa_v <= 1'b0;
          if (pa_op == 3'd5) begin c_busy <= 1'b1; c_isprobe <= 1'b1; cl_param <= pa_param; cl_addr <= pa_addr; cl_src <= '0; cl_data <= pa_data; end
        end else if (wb_sel >= 0) begin
          if (wb_hasd[wb_sel]) begin
            c_busy <= 1'b1; c_isprobe <= 1'b0; c_wbi <= wb_sel;
            cl_param <= wb_param[wb_sel]; cl_addr <= wb_addr[wb_sel]; cl_src <= 4'(8 + wb_sel); cl_data <= wb_data[wb_sel];
          end else wb_sent[wb_sel] <= 1'b1;
        end
      end
      // ---- D: ReleaseAck / Grant / GrantData
      if (d_valid && d_ready_i) begin
        if (d_op == 3'd6) begin
          automatic logic hit = 1'b0;
          for (int i = 0; i < 2; i++) if (wb_v[i] && wb_sent[i] && 4'(8 + i) == d_src) begin wb_v[i] <= 1'b0; wb_sent[i] <= 1'b0; hit = 1'b1; end
          // core-side check: a response that belongs to a transaction from before the core reset
          if (!hit) $error("[%0t] DCache: ReleaseAck src %0d for a Release it did not send (stale response?)", $time, d_src);
        end else if (d_op == 3'd4) begin
          // Grant (AcquirePerm): no data, the line is written whole by the store
          if (!(mq_v && mq_sent && !mq_gotd && mq_perm)) $error("[%0t] DCache: Grant for an AcquirePerm it did not send (stale response?)", $time);
          mq_gotd <= 1'b1; mq_sink <= d_sink;
          tg[mq_addr[1:0]][mq_way] <= mq_addr[3:2];
          st[mq_addr[1:0]][mq_way] <= D; dat[mq_addr[1:0]][mq_way] <= mq_val;
          gold_we2 <= 1'b1; gold_addr2 <= mq_addr; gold_data2 <= mq_val;
          if (d_param != 2'd0) $error("[%0t] DCache: Grant for AcquirePerm without permission toT", $time);
        end else if (d_op == 3'd5) begin
          if (!(mq_v && mq_sent && !mq_gotd && !mq_perm)) $error("[%0t] DCache: GrantData for an Acquire it did not send (stale response?)", $time);
          if (!mq_dbeat) begin mq_dbeat <= 1'b1; mq_d0 <= d_data; end
          else begin
            mq_dbeat <= 1'b0; mq_gotd <= 1'b1; mq_sink <= d_sink;
            tg[mq_addr[1:0]][mq_way] <= mq_addr[3:2];
            if (mq_store && d_param == 2'd0) begin
              st[mq_addr[1:0]][mq_way] <= D; dat[mq_addr[1:0]][mq_way] <= mq_val;
              gold_we2 <= 1'b1; gold_addr2 <= mq_addr; gold_data2 <= mq_val;
            end else begin
              st[mq_addr[1:0]][mq_way] <= (d_param == 2'd0) ? T : B;
              dat[mq_addr[1:0]][mq_way] <= mq_d0;
            end
            if (d_data != ~mq_d0) $error("[%0t] DCache: GrantData beats mismatch", $time);
          end
        end else $error("[%0t] DCache: unexpected D opcode %0d", $time, d_op);
      end
      if (a_valid_i && a_ready) mq_sent <= 1'b1;
      if (e_valid_i && e_ready) begin mq_v <= 1'b0; mq_gotd <= 1'b0; mq_perm <= 1'b0; n_ops <= n_ops + 1; end

      // ---- MainPipe s3
      if (mv[3] && dw > 0) dw <= dw - 1;
      if (s3_go) begin
        automatic logic [3:0] a3 = ma[3];
        case (mk[3])
          K_PROBE: begin
            automatic int w = find_way(a3);
            automatic logic [2:0] op = 3'd4, par = 3'd5; automatic logic [31:0] pd = '0;
            if (w >= 0) begin
              automatic logic [1:0] s = st[a3[1:0]][w];
              if (mcap[3] == 2'd2) par = (s == B) ? 3'd2 : 3'd1;   // toN: BtoN / TtoN
              else                 par = (s == B) ? 3'd4 : 3'd0;   // toB: BtoB / TtoB
              if (s == D) begin op = 3'd5; pd = dat[a3[1:0]][w]; end
              if (mcap[3] == 2'd2) st[a3[1:0]][w] <= N;
              else if (s != B) st[a3[1:0]][w] <= B;
            end
            pa_v <= 1'b1; pa_op <= op; pa_param <= par; pa_addr <= a3; pa_data <= pd;
          end
          K_STORE: begin
            automatic int w = find_way(a3);
            if (w >= 0 && (st[a3[1:0]][w] == T || st[a3[1:0]][w] == D)) begin
              st[a3[1:0]][w] <= D; dat[a3[1:0]][w] <= mval[3];
              gold_we <= 1'b1; gold_addr <= a3; gold_data <= mval[3]; n_ops <= n_ops + 1;
            end else if (w >= 0) begin
              // BtoT upgrade: the B copy stays valid until the refill (a Probe meanwhile is answered BtoN)
              if (!mq_v && !wb_conflict(a3)) begin
                mq_v <= 1'b1; mq_sent <= 1'b0; mq_addr <= a3; mq_store <= 1'b1; mq_val <= mval[3]; mq_way <= WB'(w);
                mq_grow <= 2'd2; mq_perm <= 1'b0;
              end
            end else if (!mq_v && !block && !wb_conflict(a3)) begin
              automatic int vw;
              if (can_alloc(a3, int'(rnd[12 +: WB]), 3, vw)) begin
                if (st[a3[1:0]][vw] != N) begin
                  automatic int f = wb_free();
                  wb_v[f] <= 1'b1; wb_sent[f] <= 1'b0; wb_addr[f] <= {tg[a3[1:0]][vw], a3[1:0]};
                  wb_hasd[f] <= st[a3[1:0]][vw] == D; wb_data[f] <= dat[a3[1:0]][vw];
                  wb_param[f] <= (st[a3[1:0]][vw] == B) ? 3'd2 : 3'd1;
                  st[a3[1:0]][vw] <= N;
                end
                mq_v <= 1'b1; mq_sent <= 1'b0; mq_addr <= a3; mq_store <= 1'b1; mq_val <= mval[3]; mq_way <= WB'(vw);
                mq_grow <= 2'd1;
                mq_perm <= mperm[3];   // a store that overwrites the whole line: AcquirePerm (no data from L2)
              end
            end
          end
          default: begin   // K_FLUSH
            automatic logic [SB-1:0] s = a3[SB-1:0];
            automatic logic [1:0] cs = st[s][mw[3]];
            if (cs != N) begin
              automatic int f = wb_free();
              wb_v[f] <= 1'b1; wb_sent[f] <= 1'b0; wb_addr[f] <= {tg[s][mw[3]], 2'(s)};
              wb_hasd[f] <= (cs == D) && !SWEEP_NO_DATA;
              wb_data[f] <= dat[s][mw[3]]; wb_param[f] <= (cs == B) ? 3'd2 : 3'd1;    // BtoN / TtoN
              st[s][mw[3]] <= N;
            end
          end
        endcase
      end
      // ---- MainPipe stage moves and s0
      if (s2_move) begin
        mv[3] <= 1'b1; mk[3] <= mk[2]; ma[3] <= ma[2]; mval[3] <= mval[2]; mcap[3] <= mcap[2]; mw[3] <= mw[2]; mperm[3] <= mperm[2];
        dw <= slow ? $urandom_range(0, 6) : $urandom_range(0, 2);
      end else if (s3_go) mv[3] <= 1'b0;
      if (s1_move) begin
        mv[2] <= 1'b1; mk[2] <= mk[1]; ma[2] <= ma[1]; mval[2] <= mval[1]; mcap[2] <= mcap[1]; mw[2] <= mw[1]; mperm[2] <= mperm[1];
      end else if (s2_move) mv[2] <= 1'b0;
      if (pq_go) begin
        mv[1] <= 1'b1; mk[1] <= K_PROBE; ma[1] <= pq_addr; mcap[1] <= pq_param;
        pq_v <= 1'b0; pq_sel <= 1'b0;
        if (b_valid && b_ready_i) $error("[%0t] DCache model: Probe accepted while the ProbeQueue entry is in use", $time);
      end else if (st_go) begin
        mv[1] <= 1'b1; mk[1] <= K_STORE; ma[1] <= st_addr; mval[1] <= $urandom; mperm[1] <= rnd[9];
      end else if (fl_go) begin
        mv[1] <= 1'b1; mk[1] <= K_FLUSH; ma[1] <= {2'b00, 2'(fset)}; mw[1] <= fway;
      end else if (s1_move) mv[1] <= 1'b0;
      inflight <= inflight + 3'(fl_go) - 3'(s3_go && mk[3] == K_FLUSH);

      // ---- core loads (hits read the arrays directly; misses go to the MissQueue). A line whose set is in
      // MainPipe is not read (its store / probe is applied in s3)
      if (traffic_en && rnd[1:0] == 2'b00 && !rnd[8]) begin
        automatic logic [3:0] addr = rnd[7:4];
        automatic int w = find_way(addr);
        if (w >= 0 && !mp_set_busy(addr[1:0], 0) && !(pq_v && pq_addr == addr)) begin
          n_ops <= n_ops + 1; ld_v <= 1'b1; ld_addr <= addr; ld_data <= dat[addr[1:0]][w];
        end else if (w < 0 && !block && !mq_v && !wb_conflict(addr) && !(pq_v && pq_addr == addr) &&
                   !mp_set_busy(addr[1:0], 0) && !(s3_go && mk[3] == K_STORE)) begin
          automatic int vw;
          if (can_alloc(addr, int'(rnd[12 +: WB]), 0, vw)) begin
            if (st[addr[1:0]][vw] != N) begin
              automatic int f = wb_free();
              wb_v[f] <= 1'b1; wb_sent[f] <= 1'b0; wb_addr[f] <= {tg[addr[1:0]][vw], addr[1:0]};
              wb_hasd[f] <= st[addr[1:0]][vw] == D; wb_data[f] <= dat[addr[1:0]][vw];
              wb_param[f] <= (st[addr[1:0]][vw] == B) ? 3'd2 : 3'd1;
              st[addr[1:0]][vw] <= N;
            end
            mq_v <= 1'b1; mq_sent <= 1'b0; mq_addr <= addr; mq_store <= 1'b0; mq_val <= '0; mq_way <= WB'(vw);
            mq_grow <= 2'd0; mq_perm <= 1'b0;
          end
        end
      end

      // ---- flush unit (DCacheFlushUnit)
      case (fst)
        F_IDLE:  if (flush_req) fst <= F_DRAIN;
        F_DRAIN: begin
          if (!flush_req) fst <= F_IDLE;
          else if (idle) begin fst <= (SWEEP && !NO_SWEEP) ? F_SWEEP : F_DONE; fset <= '0; fway <= '0; end
        end
        F_SWEEP: begin
          // CoreResetCtrl keeps flush_req high until done: the sweep always runs to its end
          if (fl_go) begin
            if (fset == SB'(NS - 1)) begin
              fset <= '0; fway <= fway + 1'b1;
              if (fway == WB'(NW - 1) || SWEEP_ONE_WAY) fst <= SWEEP_NO_WAIT ? F_DONE : F_WAIT;
            end else fset <= fset + 1'b1;
          end
        end
        F_WAIT:  if (inflight == 0 && idle) fst <= F_DONE;   // the last flush requests and ReleaseAcks
        F_DONE:  if (!flush_req) fst <= F_IDLE;
        default: fst <= F_IDLE;
      endcase
    end
  end

  // DCacheFlushUnit.alive: 0 while the control logic is in reset, 1 from the first cycle after it
  logic alive_q; always_ff @(posedge clk) alive_q <= !rst;
  assign alive_i = alive_q && !rst;
  // the arrays that survive the core reset must not change while frozen (reset asserted / released)
  logic [1:0] st_q [NS][NW]; logic frz_q;
  always_ff @(posedge clk) begin
    frz_q <= freeze && !meta_rst;
    for (int a = 0; a < NS; a++) for (int b = 0; b < NW; b++) st_q[a][b] <= st[a][b];
`ifndef NO_FREEZE_CHECK
    if (KEEP && frz_q && freeze && !meta_rst)
      for (int a = 0; a < NS; a++) for (int b = 0; b < NW; b++)
        if (st[a][b] != st_q[a][b]) $error("[%0t] DCache: coherence meta of set %0d way %0d changed while frozen", $time, a, b);
`endif
  end
endmodule

// ---------------------------------------------------------------------------
// One-entry buffer in the core reset domain (l1d_to_l2_buffer of MemBlock, one channel): reset with the core,
// random outputs for 1..4 cycles right after the core reset is asserted (as cr_dcache).
module cr_buf1 #(parameter int W = 8, parameter bit GARBAGE = 1) (
  input  logic clk, rst, tile_rst,
  input  logic in_valid, output logic in_ready, input logic [W-1:0] in_bits,
  output logic out_valid, input logic out_ready, output logic [W-1:0] out_bits,
  output logic empty
);
  logic v; logic [W-1:0] b;
  always_ff @(posedge clk)
    if (rst) v <= 1'b0;
    else if (in_valid && in_ready) begin v <= 1'b1; b <= in_bits; end
    else if (out_ready) v <= 1'b0;
  logic rst_q; logic [1:0] garb_n; logic [63:0] gr;
  always_ff @(posedge clk) begin
    rst_q <= rst; gr <= {$urandom, $urandom};
    if (rst && !rst_q) garb_n <= 2'($urandom_range(0, 3)); else if (garb_n != 0) garb_n <= garb_n - 1'b1;
  end
  wire garb = GARBAGE && rst && !tile_rst && (!rst_q || garb_n != 0);
  assign in_ready  = garb ? gr[0] : (!v || out_ready);
  assign out_valid = garb ? gr[1] : v;
  assign out_bits  = garb ? W'(gr[63:2]) : b;
  assign empty = !v;
endmodule
