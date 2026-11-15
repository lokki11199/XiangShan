// ============================================================================
// Behavioral models of the environment for the XSCore-only reset (L2 keeps running), v5.
//   (cr_beat, cr_gate, cr_iso, cr_ctrl: cr_ctl_models.sv; cr_dcache, cr_buf1: cr_dcache.sv)
//   cr_ulclient  : uncached client (ICache/PTW/Uncache stand-in): Get / 2-beat PutFull
//   cr_ulmgr     : uncached manager inside the core (ICache control registers), random outputs in reset
//   cr_ulbuf     : one-entry A and D buffers of the tile (TLBuffer in the MMIO crossbar of L2Top)
//   cr_l2        : inclusive L2 with directory, HN snoops, UL responder; AcquirePerm grants no data
//                  and leaves L2 without a valid copy (poison, TileLink 1.9.3 section 9.3.2). A Get of the UL
//                  port to a line L1D holds in T waits for a Probe toB of L1D (as CoupledL2 does).
// Simplified TileLink: line address 4 bits, data 32 bits, data messages are 2 beats.
//   A opcodes: 0 PutFull(2 beats) 4 Get 6 AcquireBlock 7 AcquirePerm   param(grow): 0 NtoB 1 NtoT 2 BtoT
//   B opcode : Probe                                      param(cap) : 0 toT 1 toB 2 toN
//   C opcodes: 4 ProbeAck 5 ProbeAckData(2) 6 Release 7 ReleaseData(2)
//              param(report/shrink): 0 TtoB 1 TtoN 2 BtoN 3 TtoT 4 BtoB 5 NtoN
//   D opcodes: 0 AccessAck 1 AccessAckData(2) 4 Grant 5 GrantData(2) 6 ReleaseAck
// ============================================================================

// ---------------------------------------------------------------------------
module cr_ulclient (
  input  logic clk, rst, input logic traffic_en,   // AccessAck(Data) checked: source, data, no stale response
  output logic        a_valid, input  logic a_ready, output logic [2:0] a_op, output logic [1:0] a_param,
  output logic [3:0]  a_src, output logic [3:0] a_addr, output logic [31:0] a_data,
  input  logic        d_valid, output logic d_ready, input logic [2:0] d_op, input logic [3:0] d_src, input logic [31:0] d_data,
  output int          n_ops
);
  logic busy [2]; logic sending; logic beat; logic [2:0] op; logic [3:0] src, addr; logic [31:0] data;
  logic dbeat; logic [2:0] rq_op [2]; logic [3:0] rq_addr [2]; logic [31:0] d0;
  assign a_valid = sending; assign a_op = op; assign a_param = '0; assign a_src = src; assign a_addr = addr;
  assign a_data = beat ? ~data : data;
  assign d_ready = 1'b1;
  logic [31:0] rnd; always_ff @(posedge clk) rnd <= $urandom;
  always_ff @(posedge clk) begin
    if (rst) begin busy[0] <= 1'b0; busy[1] <= 1'b0; sending <= 1'b0; beat <= 1'b0; dbeat <= 1'b0; n_ops <= 0; end
    else begin
      if (a_valid && a_ready) begin
        if (op == 3'd0 && !beat) beat <= 1'b1;
        else begin beat <= 1'b0; sending <= 1'b0; end
      end
      if (d_valid && d_ready) begin
        // core-side checks: the response belongs to a request of this client (not to one from before the reset)
        if (!busy[d_src[0]] || sending && src == d_src) $error("[%0t] UL client: response for source %0d that has no request in flight (stale response?)", $time, d_src);
        else if ((rq_op[d_src[0]] == 3'd4) != (d_op == 3'd1)) $error("[%0t] UL client: wrong response opcode %0d", $time, d_op);
        if (d_op == 3'd1 && !dbeat) begin
          dbeat <= 1'b1; d0 <= d_data;
          if (d_data != (32'hABCD0000 | rq_addr[d_src[0]])) $error("[%0t] UL client: Get data %h for address %0d", $time, d_data, rq_addr[d_src[0]]);
        end else begin
          if (dbeat && d_data != ~d0) $error("[%0t] UL client: AccessAckData beats mismatch", $time);
          dbeat <= 1'b0; busy[d_src[0]] <= 1'b0; n_ops <= n_ops + 1;
        end
      end
      if (traffic_en && !sending && rnd[2:0] == 3'b000) begin
        automatic int f = !busy[0] ? 0 : (!busy[1] ? 1 : -1);
        if (f >= 0) begin
          busy[f] <= 1'b1; sending <= 1'b1; beat <= 1'b0; src <= 4'(f); addr <= rnd[7:4];
          op <= rnd[8] ? 3'd4 : 3'd0; data <= $urandom; rq_op[f] <= rnd[8] ? 3'd4 : 3'd0; rq_addr[f] <= rnd[7:4];
        end
      end
    end
  end
endmodule

// ---------------------------------------------------------------------------
// Uncached manager inside the core (ICache control registers of XSCore): reset with the core, random outputs
// right after its reset is asserted. Get -> AccessAckData (2 beats: ABCD0000|addr, then its inverse),
// PutFull (2 beats) -> AccessAck, after 1..12 cycles; two sources.
module cr_ulmgr #(parameter bit GARBAGE = 1) (
  input  logic clk, rst, input logic tile_rst,
  input  logic        a_valid, output logic a_ready, input logic [2:0] a_op, input logic [3:0] a_src,
  input  logic [3:0]  a_addr, input logic [31:0] a_data,
  output logic        d_valid, input  logic d_ready, output logic [2:0] d_op, output logic [3:0] d_src,
  output logic [31:0] d_data,
  output int          n_ops
);
  logic v [2]; logic [2:0] op [2]; int dly [2]; logic [31:0] dat [2]; logic abeat, dbeat; int cur, didx;
  logic a_ready_i, d_valid_i; logic [2:0] d_op_i; logic [3:0] d_src_i; logic [31:0] d_data_i;
  always_comb begin
    d_valid_i = 1'b0; d_op_i = '0; d_src_i = '0; d_data_i = '0; cur = -1;
    for (int i = 1; i >= 0; i--) if (v[i] && dly[i] == 0) cur = i;
    if (dbeat) cur = didx;
    if (cur >= 0) begin
      d_valid_i = 1'b1; d_op_i = (op[cur] == 3'd4) ? 3'd1 : 3'd0; d_src_i = 4'(cur);
      d_data_i = dbeat ? ~dat[cur] : dat[cur];
    end
  end
  assign a_ready_i = !(v[0] && v[1]) || abeat;
  always_ff @(posedge clk) begin
    if (rst) begin v[0] <= 1'b0; v[1] <= 1'b0; abeat <= 1'b0; dbeat <= 1'b0; n_ops <= 0; end
    else begin
      for (int i = 0; i < 2; i++) if (v[i] && dly[i] > 0) dly[i] <= dly[i] - 1;
      if (a_valid && a_ready_i) begin
        if (a_op == 3'd0 && !abeat) abeat <= 1'b1;
        else begin
          abeat <= 1'b0;
          if (v[a_src[0]]) $error("[%0t] ICache ctrl: request for source %0d that is busy", $time, a_src);
          v[a_src[0]] <= 1'b1; op[a_src[0]] <= a_op; dly[a_src[0]] <= $urandom_range(1, 12); dat[a_src[0]] <= 32'hABCD0000 | a_addr;
        end
      end
      if (d_valid_i && d_ready) begin
        if (d_op_i == 3'd1 && !dbeat) begin dbeat <= 1'b1; didx <= cur; end
        else begin dbeat <= 1'b0; v[cur] <= 1'b0; n_ops <= n_ops + 1; end
      end
    end
  end
  // reset domain crossing, as in cr_dcache
  logic rst_q; logic [1:0] garb_n; logic [31:0] gr;
  always_ff @(posedge clk) begin
    rst_q <= rst; gr <= $urandom;
    if (rst && !rst_q) garb_n <= 2'($urandom_range(0, 3)); else if (garb_n != 0) garb_n <= garb_n - 1'b1;
  end
  wire garb = GARBAGE && rst && !tile_rst && (!rst_q || garb_n != 0);
  assign a_ready = garb ? gr[0] : a_ready_i;
  assign d_valid = garb ? gr[1] : d_valid_i; assign d_op = garb ? gr[4:2] : d_op_i;
  assign d_src = garb ? gr[8:5] : d_src_i;   assign d_data = garb ? {gr[31:9], gr[8:0]} : d_data_i;
endmodule

// ---------------------------------------------------------------------------
// One-entry buffers on A and D of a TL-UL edge, tile domain (TLBuffer in the MMIO crossbar of L2Top)
module cr_ulbuf (
  input  logic clk, rst,
  input  logic        ia_valid, output logic ia_ready, input logic [2:0] ia_op, input logic [3:0] ia_src,
  input  logic [3:0]  ia_addr, input logic [31:0] ia_data,
  output logic        id_valid, input  logic id_ready, output logic [2:0] id_op, output logic [3:0] id_src,
  output logic [31:0] id_data,
  output logic        oa_valid, input  logic oa_ready, output logic [2:0] oa_op, output logic [3:0] oa_src,
  output logic [3:0]  oa_addr, output logic [31:0] oa_data,
  input  logic        od_valid, output logic od_ready, input logic [2:0] od_op, input logic [3:0] od_src,
  input  logic [31:0] od_data,
  output logic        empty
);
  logic av, dv;
  assign ia_ready = !av || oa_ready; assign oa_valid = av;
  assign od_ready = !dv || id_ready; assign id_valid = dv;
  always_ff @(posedge clk)
    if (rst) begin av <= 1'b0; dv <= 1'b0; end
    else begin
      if (ia_valid && ia_ready) begin av <= 1'b1; {oa_op, oa_src, oa_addr, oa_data} <= {ia_op, ia_src, ia_addr, ia_data}; end
      else if (oa_ready) av <= 1'b0;
      if (od_valid && od_ready) begin dv <= 1'b1; {id_op, id_src, id_data} <= {od_op, od_src, od_data}; end
      else if (id_ready) dv <= 1'b0;
    end
  assign empty = !av && !dv;
endmodule


// ---------------------------------------------------------------------------
module cr_l2 (
  input  logic clk, rst,
  input  logic snoop_en,               // HN snoops to the tile
  input  logic slow,                   // long and random latencies, ready stalls, gaps between beats
  // forced snoop (directed tests): a Probe of this line as soon as possible
  input  logic fsnp_v, input logic [3:0] fsnp_addr, input logic [1:0] fsnp_param,
  input  logic fsnp_force,             // probe even if the directory lists no copy (the client answers NtoN)
  output logic fsnp_ack, output logic fsnp_l2only,
  input  logic spur_en,                // now and then a Probe of a line the directory lists as N (legal TileLink)
  input  logic core_in_reset,          // for checks only
  input  logic b_to_gate,              // a Probe accepted now is taken by the gate (answered NtoN), not by the core
  // port 0: DCache (TL-C)
  input  logic        a_valid, output logic a_ready, input logic [2:0] a_op, input logic [1:0] a_param,
  input  logic [3:0]  a_src, input logic [3:0] a_addr, input logic [31:0] a_data,
  output logic        b_valid, input  logic b_ready, output logic [1:0] b_param, output logic [3:0] b_addr,
  input  logic        c_valid, output logic c_ready, input logic [2:0] c_op, input logic [2:0] c_param,
  input  logic [3:0]  c_src, input logic [3:0] c_addr, input logic [31:0] c_data,
  output logic        d_valid, input  logic d_ready, output logic [2:0] d_op, output logic [1:0] d_param,
  output logic [3:0]  d_src, output logic [3:0] d_sink, output logic [31:0] d_data,
  input  logic        e_valid, output logic e_ready, input logic [3:0] e_sink,
  // port 1: uncached (UL)
  input  logic        ua_valid, output logic ua_ready, input logic [2:0] ua_op, input logic [3:0] ua_src,
  input  logic [3:0]  ua_addr, input logic [31:0] ua_data,
  output logic        ud_valid, input  logic ud_ready, output logic [2:0] ud_op, output logic [3:0] ud_src,
  output logic [31:0] ud_data,
  // state for checks
  output logic [1:0]  dir [16], output logic [31:0] mem [16],
  output logic        busy_core, output int n_snoop_l2only, output int n_probe, output int n_perm, output int n_spur,
  output int          n_get_probe        // Gets of the UL port that waited for a Probe toB of L1D
);
  localparam logic [1:0] N = 2'd0, B = 2'd1, T = 2'd2;
  // acquire handling (one at a time)
  logic acq_v, acq_perm; logic [3:0] acq_addr; logic [1:0] acq_grow; logic [3:0] acq_src;
  logic gnt_send, gnt_beat, gnt_wait_e; logic [1:0] gnt_cap; int gnt_delay, gnt_gap;
  // probe
  logic prb_v, prb_sent; logic [3:0] prb_addr; logic [1:0] prb_param;
  // release acks
  logic ra_v [4]; logic [3:0] ra_src [4]; int ra_dly [4];
  logic c_beat; logic [31:0] c_d0;
  // UL responder
  logic ul_v [2]; logic [2:0] ul_op [2]; int ul_dly [2]; logic [31:0] ul_dat [2]; logic ula_beat; logic uld_beat; int ul_cur;
  int uld_idx, uld_gap;
  // CoupledL2: a Get of a non-coherent agent to a line that L1D holds in T (TRUNK / TIP) waits for a Probe toB
  // of L1D before L2 answers it (ul_np: the Get of this source needs that Probe)
  logic ul_np [2]; logic [3:0] ul_npa [2];
  logic [31:0] rnd; always_ff @(posedge clk) rnd <= $urandom;
  logic [31:0] stl; always_ff @(posedge clk) stl <= $urandom;   // ready stalls (slow)

  assign a_ready = !acq_v && (!slow || stl[1:0] != 2'b00);
  // slow: random stalls, and now and then a long one (20..60 cycles), as when the L2 C-channel buffers fill
  int c_burst;
  always_ff @(posedge clk)
    if (rst) c_burst <= 0;
    else if (c_burst > 0) c_burst <= c_burst - 1;
    else if (slow && stl[13:8] == 6'd0) c_burst <= $urandom_range(20, 60);
  assign c_ready = !slow || (stl[3:2] != 2'b00 && c_burst == 0);
  assign e_ready = !slow || stl[5:4] != 2'b00;
  assign b_valid = prb_v && !prb_sent; assign b_param = prb_param; assign b_addr = prb_addr;

  // D arbitration: an ongoing GrantData continues (nothing else in between its beats, maybe a gap);
  // else ReleaseAck; else Grant
  int ra_sel;
  always_comb begin
    ra_sel = -1;
    for (int i = 3; i >= 0; i--) if (ra_v[i] && ra_dly[i] == 0) ra_sel = i;
  end
  logic d_isgnt;
  always_comb begin
    d_valid = 1'b0; d_op = '0; d_param = '0; d_src = '0; d_sink = 4'd3; d_data = '0; d_isgnt = 1'b0;
    if (gnt_send && acq_perm) begin
      // AcquirePerm: Grant without data (1 beat)
      if (ra_sel < 0 && gnt_delay == 0) begin d_valid = 1'b1; d_op = 3'd4; d_param = 2'd0; d_src = acq_src; d_isgnt = 1'b1; end
      else if (ra_sel >= 0) begin d_valid = 1'b1; d_op = 3'd6; d_src = ra_src[ra_sel]; end
    end else if (gnt_send && gnt_beat) begin
      if (gnt_gap == 0) begin
        d_valid = 1'b1; d_op = 3'd5; d_param = gnt_cap; d_src = acq_src; d_data = ~mem[acq_addr]; d_isgnt = 1'b1;
      end
    end else if (gnt_send && ra_sel < 0 && gnt_delay == 0) begin
      d_valid = 1'b1; d_op = 3'd5; d_param = gnt_cap; d_src = acq_src; d_data = mem[acq_addr];
      d_isgnt = 1'b1;
    end else if (ra_sel >= 0) begin
      d_valid = 1'b1; d_op = 3'd6; d_src = ra_src[ra_sel];
    end
  end
  // UL D
  always_comb begin
    ud_valid = 1'b0; ud_op = '0; ud_src = '0; ud_data = '0; ul_cur = -1;
    for (int i = 1; i >= 0; i--) if (ul_v[i] && ul_dly[i] == 0 && !ul_np[i]) ul_cur = i;
    if (uld_beat) ul_cur = uld_idx;     // second beat of an AccessAckData
    if (ul_cur >= 0 && !(uld_beat && uld_gap != 0)) begin
      ud_valid = 1'b1; ud_op = (ul_op[ul_cur] == 3'd4) ? 3'd1 : 3'd0; ud_src = 4'(ul_cur);
      ud_data = uld_beat ? ~ul_dat[ul_cur] : ul_dat[ul_cur];
    end
  end
  assign ua_ready = (!(ul_v[0] && ul_v[1]) || ula_beat) && (!slow || stl[7:6] != 2'b00);

  // a Probe that is not sent yet is not a transaction with the core (it may wait while the core is in reset)
  // lines whose L2 copy is not valid after an AcquirePerm (until the client writes them back with data); a
  // separate flag, not a data pattern: random store data may look like any pattern
  logic [15:0] poison;
  assign busy_core = acq_v || (prb_v && prb_sent) || ra_v[0] || ra_v[1] || ra_v[2] || ra_v[3] || ul_v[0] || ul_v[1] || c_beat || ula_beat;

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 16; i++) begin dir[i] <= N; mem[i] <= 32'h1000 + i; end
      poison <= '0;
      acq_v <= 1'b0; acq_perm <= 1'b0; gnt_send <= 1'b0; gnt_beat <= 1'b0; gnt_wait_e <= 1'b0; gnt_delay <= 0; n_perm <= 0;
      prb_v <= 1'b0; prb_sent <= 1'b0;
      for (int i = 0; i < 4; i++) ra_v[i] <= 1'b0;
      c_beat <= 1'b0; ul_v[0] <= 1'b0; ul_v[1] <= 1'b0; ula_beat <= 1'b0; uld_beat <= 1'b0;
      n_snoop_l2only <= 0; n_probe <= 0; n_spur <= 0; fsnp_ack <= 1'b0; fsnp_l2only <= 1'b0; gnt_gap <= 0; uld_gap <= 0;
      ul_np[0] <= 1'b0; ul_np[1] <= 1'b0; n_get_probe <= 0;
    end else begin
      fsnp_ack <= 1'b0; fsnp_l2only <= 1'b0;
      if (gnt_gap > 0) gnt_gap <= gnt_gap - 1;
      if (uld_gap > 0) uld_gap <= uld_gap - 1;
      for (int i = 0; i < 4; i++) if (ra_v[i] && ra_dly[i] > 0) ra_dly[i] <= ra_dly[i] - 1;
      for (int i = 0; i < 2; i++) if (ul_v[i] && ul_dly[i] > 0 && !ul_np[i]) ul_dly[i] <= ul_dly[i] - 1;
      if (gnt_delay > 0) gnt_delay <= gnt_delay - 1;
      // ---- A: acquire
      if (a_valid && a_ready) begin
        if (a_op != 3'd6 && a_op != 3'd7) $error("[%0t] L2: unexpected A opcode %0d on the TL-C port", $time, a_op);
        if (a_op == 3'd7 && a_param != 2'd1) $error("[%0t] L2: AcquirePerm without NtoT", $time);
        // (an Acquire may overtake the ProbeAck of the same line, which is still in the L1D buffer of channel C:
        // CoupledL2 accepts that; the directory is updated by the ProbeAck)
        if (dir[a_addr] != N && !(a_op == 3'd6 && a_param == 2'd2 && dir[a_addr] == B) &&
            !(prb_v && prb_sent && prb_addr == a_addr))
          $error("[%0t] L2: Acquire (op %0d grow %0d) of line %0d that the client already holds (%0d): it lost the line?", $time, a_op, a_param, a_addr, dir[a_addr]);
        acq_v <= 1'b1; acq_perm <= a_op == 3'd7; acq_addr <= a_addr; acq_grow <= a_param; acq_src <= a_src; gnt_send <= 1'b0; gnt_wait_e <= 1'b0;
      end
      // start the grant once no probe is outstanding on that line
      if (acq_v && !gnt_send && !gnt_wait_e && !(prb_v && prb_addr == acq_addr)) begin
        gnt_send <= 1'b1; gnt_beat <= 1'b0; gnt_delay <= slow ? $urandom_range(0, 40) : $urandom_range(0, 6);
        // a read may get T (L2 grants T when no other client holds the line): clean T lines in L1D
        gnt_cap <= (acq_grow == 2'd0) ? ($urandom_range(0, 1) ? 2'd1 : 2'd0) : 2'd0;
      end
      if (d_valid && d_ready) begin
        if (d_isgnt && acq_perm) begin
          // the client gets T without data and overwrites the whole line: L2's copy is no longer valid
          // ("data not valid", TileLink 1.9.3 9.3.2); poison it, the next valid data comes from the client
          gnt_send <= 1'b0; gnt_wait_e <= 1'b1; dir[acq_addr] <= T; mem[acq_addr] <= 32'hDEAD0000 | acq_addr; n_perm <= n_perm + 1;
          poison[acq_addr] <= 1'b1;
        end else if (d_isgnt) begin
          if (!gnt_beat) begin
            gnt_beat <= 1'b1; gnt_gap <= slow ? $urandom_range(0, 8) : 0;
            if (poison[acq_addr]) $error("[%0t] L2: GrantData of line %0d with data L2 does not hold (AcquirePerm, the client lost its dirty copy)", $time, acq_addr);
          end
          else begin gnt_beat <= 1'b0; gnt_send <= 1'b0; gnt_wait_e <= 1'b1; dir[acq_addr] <= (gnt_cap == 2'd0) ? T : B; end
        end else ra_v[ra_sel] <= 1'b0;
      end
      if (e_valid && e_ready) begin
        if (!gnt_wait_e) $error("[%0t] L2: GrantAck without Grant", $time);
        gnt_wait_e <= 1'b0; acq_v <= 1'b0;
      end
      // ---- C: release / probe ack
      if (c_valid && c_ready) begin
        automatic logic data = c_op == 3'd5 || c_op == 3'd7;
        if (!c_beat && (c_op == 3'd6 || c_op == 3'd7) && c_param == 3'd5)
          $error("[%0t] L2: Release with NtoN (illegal, TileLink 1.9.3 9.3.10)", $time);
        if (!c_beat && c_op == 3'd5 && c_param == 3'd5)
          $error("[%0t] L2: ProbeAckData with NtoN (illegal, TileLink 1.9.3 9.3.6)", $time);
        if (data && !c_beat) begin c_beat <= 1'b1; c_d0 <= c_data; end
        else begin
          c_beat <= 1'b0;
          if (data) begin
            mem[c_addr] <= c_d0; poison[c_addr] <= 1'b0;
            if (c_data != ~c_d0) $error("[%0t] L2: C data beats mismatch", $time);
          end
          if (c_op == 3'd6 || c_op == 3'd7) begin
            automatic int f = -1;
            for (int i = 3; i >= 0; i--) if (!ra_v[i]) f = i;
            if (f < 0) $error("[%0t] L2: ReleaseAck queue overflow", $time);
            else begin ra_v[f] <= 1'b1; ra_src[f] <= c_src; ra_dly[f] <= slow ? $urandom_range(0, 40) : $urandom_range(0, 5); end
            dir[c_addr] <= (c_param == 3'd0) ? B : N;
            if (dir[c_addr] == N) $error("[%0t] L2: Release of a line the client does not hold (addr %0d)", $time, c_addr);
          end else begin
            if (!(prb_v && prb_sent && prb_addr == c_addr)) $error("[%0t] L2: unexpected ProbeAck", $time);
            prb_v <= 1'b0; prb_sent <= 1'b0;
            for (int i = 0; i < 2; i++) if (ul_np[i] && ul_npa[i] == c_addr) ul_np[i] <= 1'b0;
            if (c_param == 3'd1 || c_param == 3'd2 || c_param == 3'd5) dir[c_addr] <= N;
            else if (c_param == 3'd0 || c_param == 3'd4) dir[c_addr] <= (dir[c_addr] == N) ? N : B;
          end
        end
      end
      if (b_valid && b_ready) begin
        prb_sent <= 1'b1; n_probe <= n_probe + 1;
        if (core_in_reset && !b_to_gate) $error("[%0t] L2: Probe sent to the core while it is in reset", $time);
      end
      // ---- forced snoop (directed tests): has priority over the random snoops
      if (fsnp_v && !fsnp_ack && !prb_v && !(acq_v && acq_addr == fsnp_addr)) begin
        fsnp_ack <= 1'b1;
        if (dir[fsnp_addr] != N || fsnp_force) begin
          prb_v <= 1'b1; prb_sent <= 1'b0; prb_addr <= fsnp_addr; prb_param <= (dir[fsnp_addr] == N) ? 2'd2 : fsnp_param;
          if (dir[fsnp_addr] == N) n_spur <= n_spur + 1;
        end else begin fsnp_l2only <= 1'b1; n_snoop_l2only <= n_snoop_l2only + 1; end
      end else
      // ---- the Probe toB a Get of the UL port needs (line held in T by L1D)
      if ((ul_np[0] || ul_np[1]) && !prb_v) begin
        automatic int k = ul_np[0] ? 0 : 1;
        if (dir[ul_npa[k]] != T) ul_np[k] <= 1'b0;   // released meanwhile: L2 holds the data, answer at once
        else if (!(acq_v && acq_addr == ul_npa[k])) begin
          prb_v <= 1'b1; prb_sent <= 1'b0; prb_addr <= ul_npa[k]; prb_param <= 2'd1;
        end
      end else
      // ---- HN snoop generator
      if (snoop_en && !prb_v && rnd[3:0] == 4'd0) begin
        automatic logic [3:0] sa = rnd[11:8];
        if (dir[sa] != N && !(acq_v && acq_addr == sa)) begin
          prb_v <= 1'b1; prb_sent <= 1'b0; prb_addr <= sa; prb_param <= (rnd[12] && dir[sa] == T) ? 2'd1 : 2'd2;
        end else if (dir[sa] == N && spur_en && rnd[14:13] == 2'd0 && !(acq_v && acq_addr == sa)) begin
          prb_v <= 1'b1; prb_sent <= 1'b0; prb_addr <= sa; prb_param <= 2'd2; n_spur <= n_spur + 1;
        end else if (dir[sa] == N) n_snoop_l2only <= n_snoop_l2only + 1;
      end
      // ---- UL port
      if (ua_valid && ua_ready) begin
        if (ua_op == 3'd0 && !ula_beat) ula_beat <= 1'b1;
        else begin
          ula_beat <= 1'b0;
          ul_v[ua_src[0]] <= 1'b1; ul_op[ua_src[0]] <= ua_op;
          if (ua_op == 3'd4 && dir[ua_addr] == T) begin
            ul_np[ua_src[0]] <= 1'b1; ul_npa[ua_src[0]] <= ua_addr; n_get_probe <= n_get_probe + 1;
          end ul_dly[ua_src[0]] <= ($urandom_range(0, 3) == 0) ? $urandom_range(20, 80) : $urandom_range(1, 12);   // slow devices sometimes
          ul_dat[ua_src[0]] <= 32'hABCD0000 | ua_addr;
        end
      end
      if (ud_valid && ud_ready) begin
        if (ud_op == 3'd1 && !uld_beat) begin uld_beat <= 1'b1; uld_idx <= ul_cur; uld_gap <= slow ? $urandom_range(0, 8) : 0; end
        else begin uld_beat <= 1'b0; ul_v[ul_cur] <= 1'b0; end
      end
      if (core_in_reset && (d_valid || ud_valid)) $error("[%0t] L2: D response to the core while it is in reset", $time);
    end
  end
endmodule
