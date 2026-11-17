// TileLink-C responder for the RTL test of the DCache (TESTPLAN section 5.3): one client, one L2 slice, no CHI.
// Directory per line (N / B / T), data per line (512 bit), delays of Grant / ReleaseAck / CBOAck, a queue of Probes
// (directed by the stand and made by CBO), and the protocol checks of K11 and the L2-side checks of K7 / K8.
// Counters of the L2 side (open requests, grants, releases, probes) are independent of the counters of the gate:
// K1 / K2 compare them. FULL: after the reset point every line the directory holds for the client is `stale`
// (DESIGN 7.2): ProbeAck NtoN and a repeated Acquire of such a line are legal and counted, not errors.
// All state changes are non-blocking: the stand and the DUT sample the outputs of the same edge.

package dp;
`include "params.svh"
  localparam int DW     = BEAT_BYTES * 8;
  localparam int BW     = BLOCK_BYTES * 8;
  localparam int NBEAT  = BLOCK_BYTES / BEAT_BYTES;
  localparam int OFFB   = $clog2(BLOCK_BYTES);
  localparam int SETB   = $clog2(NSETS);
  localparam int NTAGS  = NWAYS + 2;       // tags per set: more than the ways, so lines are evicted
  localparam int NSETU  = 3;               // sets in use
  localparam int NL     = NSETU * NTAGS;   // lines in the test
  localparam int TAG0   = 16;
  // the DCache asserts that every Acquire address lies in PmemRanges (DCacheWrapper.scala:1802): bit 31 set, below 2^43
  localparam logic [63:0] ABASE = 64'h8000_0000;
  typedef logic [ADDR_BITS-1:0] addr_t;

  function automatic addr_t line_base(int li);
    int seti, tagi;
    seti = li / NTAGS; tagi = li % NTAGS;
    return addr_t'(ABASE | (64'(TAG0 + tagi) << (OFFB + SETB)) | (64'(seti) << OFFB));
  endfunction

  // index of the line of an address, -1 outside the test space
  function automatic int line_of(addr_t a);
    int seti, tagi;
    if ((64'(a) & ABASE) == 64'd0) return -1;
    seti = int'((64'(a) >> OFFB) & 64'(NSETS - 1));
    tagi = int'((64'(a) & (ABASE - 64'd1)) >> (OFFB + SETB)) - TAG0;
    if (seti >= NSETU || tagi < 0 || tagi >= NTAGS) return -1;
    return seti * NTAGS + tagi;
  endfunction

  function automatic logic [BW-1:0] init_line(int li);
    logic [BW-1:0] r;
    for (int b = 0; b < BLOCK_BYTES; b++) r[b*8 +: 8] = 8'(li * 37 + b * 5 + 1);
    return r;
  endfunction

  // what L2 holds after MakeUnique of a line it did not have: the data of some other (evicted) line
  function automatic logic [BW-1:0] foreign_line(int li);
    return ~init_line(li) ^ BW'(32'hF0F0A5A5);
  endfunction

  // TileLink encodings
  localparam logic [3:0] A_ACQBLOCK = 4'd6, A_ACQPERM = 4'd7, A_CBOCLEAN = 4'd12, A_CBOFLUSH = 4'd13, A_CBOINVAL = 4'd14;
  localparam logic [3:0] D_GRANT = 4'd4, D_GRANTDATA = 4'd5, D_RELACK = 4'd6, D_CBOACK = 4'd8;
  localparam logic [2:0] C_PROBEACK = 3'd4, C_PROBEACKDATA = 3'd5, C_RELEASE = 3'd6, C_RELEASEDATA = 3'd7;
  // ProbeAck / Release params (TileLink 1.9.3 tables 35, 36)
  localparam logic [2:0] P_TtoB = 3'd0, P_TtoN = 3'd1, P_BtoN = 3'd2, P_TtoT = 3'd3, P_BtoB = 3'd4, P_NtoN = 3'd5;
endpackage

module rtl_l2 import dp::*; (
  input  logic clk, rst,
  // channel A (from the DUT)
  input  logic a_valid, output logic a_ready,
  input  logic [3:0] a_opcode, input logic [2:0] a_param, input logic [SIZE_BITS-1:0] a_size,
  input  logic [SRC_BITS-1:0] a_source, input logic [ADDR_BITS-1:0] a_address,
  // channel B (to the DUT)
  output logic b_valid, input logic b_ready,
  output logic [2:0] b_opcode, output logic [1:0] b_param, output logic [SIZE_BITS-1:0] b_size,
  output logic [SRC_BITS-1:0] b_source, output logic [ADDR_BITS-1:0] b_address,
  output logic [BEAT_BYTES-1:0] b_mask, output logic [DW-1:0] b_data, output logic b_corrupt,
  // channel C (from the DUT)
  input  logic c_valid, output logic c_ready,
  input  logic [2:0] c_opcode, input logic [2:0] c_param, input logic [SIZE_BITS-1:0] c_size,
  input  logic [SRC_BITS-1:0] c_source, input logic [ADDR_BITS-1:0] c_address, input logic [DW-1:0] c_data,
  input  logic c_corrupt,
  // channel D (to the DUT)
  output logic d_valid, input logic d_ready,
  output logic [3:0] d_opcode, output logic [1:0] d_param, output logic [SIZE_BITS-1:0] d_size,
  output logic [SRC_BITS-1:0] d_source, output logic [SNK_BITS-1:0] d_sink, output logic d_denied,
  output logic [DW-1:0] d_data, output logic d_corrupt,
  // channel E (from the DUT)
  input  logic e_valid, output logic e_ready, input logic [SNK_BITS-1:0] e_sink,
  // knobs of the stand
  input  int grant_delay, rel_delay, cbo_delay,
  input  logic c_stall,                // C ready = 0
  input  logic full_mode,              // FULL: directory goes stale at the reset point
  input  logic reset_point,            // pulse: XSCore reset is established
  input  logic pr_req, input addr_t pr_addr, input logic [1:0] pr_cap,   // queue a Probe (cap 1 toB, 2 toN)
  input  logic pr_go,                  // the head Probe of the stand may be offered (once offered it stays)
  // status
  output logic quiet,                  // nothing open, no message in transfer (a Probe not yet taken does not count)
  output logic quiet_noprobe,          // the same, a Probe in progress is not looked at
  output int n_open_req, n_open_grant, n_open_rel, n_open_probe,
  output logic ev_acq, ev_acq_perm, ev_cbo, ev_rel_first, ev_b_fire, ev_probe_done, ev_wb, ev_wb_data_valid,
  output int ev_wb_line, output logic [BW-1:0] ev_wb_data,
  output int n_acq, n_rel, n_probe, n_gate_ack, n_nton_stale, n_reacq_stale, n_foreign_grant,
  output int last_ack_param, last_probe_lat, last_probe_line,
  output logic [NL*2-1:0] dir_o, output logic [NL-1:0] poison_o, output logic [NL-1:0] stale_o,
  output logic [NL*BW-1:0] mem_o,
  output int err_cnt
);
  localparam int QD = 8;
  localparam logic [SRC_BITS-1:0] PROBE_SRC = '0;

  logic [BW-1:0] mem [NL];
  logic [1:0]    dir [NL];
  logic          poison [NL], stale [NL];
  int            now;
  logic          d_hold_q;

  // A queue
  logic [3:0] aq_op [QD]; logic [2:0] aq_param [QD]; logic [SRC_BITS-1:0] aq_src [QD]; addr_t aq_addr [QD];
  int aq_rdy [QD]; int aq_head, aq_tail, aq_cnt;
  // D queue
  logic [3:0] dq_op [QD]; logic [1:0] dq_param [QD]; logic [SRC_BITS-1:0] dq_src [QD];
  logic [SNK_BITS-1:0] dq_sink [QD]; logic [BW-1:0] dq_data [QD]; int dq_nb [QD]; int dq_rdy [QD];
  logic dq_isgrant [QD], dq_isrel [QD], dq_isreq [QD];
  int dq_head, dq_tail, dq_cnt, d_beat;
  // Probe queue
  addr_t pq_addr [QD]; logic [1:0] pq_cap [QD]; logic pq_cbo [QD];
  int pq_head, pq_tail, pq_cnt;
  logic b_pend, probe_open; addr_t probe_addr; logic [1:0] probe_cap; logic probe_cbo; int probe_t0;
  // engine (CBO waits for its Probe)
  logic eng_wait; int eng_line; logic [SRC_BITS-1:0] eng_src; int eng_rdy;
  // C message in progress
  int c_beat; logic [2:0] c_op_q, c_param_q; logic [SRC_BITS-1:0] c_src_q; addr_t c_addr_q; logic [BW-1:0] c_acc;
  // sinks
  logic [(1<<SNK_BITS)-1:0] sink_open; logic [SNK_BITS-1:0] sink_next;

  // scratch of the clock block (blocking, re-initialised each cycle)
  int n_dq_cnt, n_dq_tail, n_pq_cnt, n_pq_tail, n_aq_cnt, n_aq_tail;
  int d_open_req, d_open_grant, d_open_rel, d_open_probe;   // deltas of this cycle

  wire addr_t    b_head_addr = pq_addr[pq_head];
  wire dq_ok = dq_cnt != 0 && now >= dq_rdy[dq_head];
  assign a_ready = aq_cnt < QD - 1;
  assign c_ready = !c_stall;
  assign e_ready = 1'b1;
  wire pr_go_eff = pq_cbo[pq_head] ? 1'b1 : pr_go;
  assign b_valid   = b_pend || (!probe_open && pq_cnt != 0 && pr_go_eff);
  assign b_opcode  = 3'd6;
  assign b_param   = pq_cap[pq_head];
  assign b_size    = SIZE_BITS'(OFFB);
  assign b_source  = PROBE_SRC;
  assign b_address = b_head_addr;
  assign b_mask    = '1;
  assign b_data    = '0;
  assign b_corrupt = 1'b0;
  assign d_valid   = dq_ok;
  assign d_opcode  = dq_op[dq_head];
  assign d_param   = dq_param[dq_head];
  assign d_size    = SIZE_BITS'(OFFB);
  assign d_source  = dq_src[dq_head];
  assign d_sink    = dq_sink[dq_head];
  assign d_denied  = 1'b0;
  assign d_data    = dq_data[dq_head][d_beat * DW +: DW];
  assign d_corrupt = 1'b0;
  assign quiet_noprobe = n_open_req == 0 && n_open_grant == 0 && n_open_rel == 0 && c_beat == 0 && d_beat == 0;
  assign quiet = quiet_noprobe && n_open_probe == 0;

  for (genvar l = 0; l < NL; l++) begin : g_flat
    assign dir_o[l*2 +: 2] = dir[l];
    assign poison_o[l] = poison[l];
    assign stale_o[l] = stale[l];
    assign mem_o[l*BW +: BW] = mem[l];
  end

  initial begin
    now = 0; err_cnt = 0; d_hold_q = 1'b0;
    for (int l = 0; l < NL; l++) begin mem[l] = init_line(l); dir[l] = 2'd0; poison[l] = 1'b0; stale[l] = 1'b0; end
    aq_head = 0; aq_tail = 0; aq_cnt = 0; dq_head = 0; dq_tail = 0; dq_cnt = 0; d_beat = 0;
    pq_head = 0; pq_tail = 0; pq_cnt = 0; b_pend = 0; probe_open = 0; probe_addr = '0; probe_cap = '0; probe_cbo = 0;
    probe_t0 = 0; eng_wait = 0; eng_line = 0; eng_src = '0; eng_rdy = 0;
    c_beat = 0; c_op_q = '0; c_param_q = '0; c_src_q = '0; c_addr_q = '0; c_acc = '0;
    sink_open = '0; sink_next = '0;
    n_open_req = 0; n_open_grant = 0; n_open_rel = 0; n_open_probe = 0;
    n_acq = 0; n_rel = 0; n_probe = 0; n_gate_ack = 0; n_nton_stale = 0; n_reacq_stale = 0; n_foreign_grant = 0;
    last_ack_param = -1; last_probe_lat = 0; last_probe_line = -1;
  end

  task automatic perr(input string kid, input string msg);
    err_cnt++;
    $display("ERROR %s l2: %s [t=%0t]", kid, msg, $time);
  endtask

  // push a response into the D queue (called from the clock block; uses the scratch tail / count)
  task automatic push_d(input logic [3:0] op, input logic [1:0] prm, input logic [SRC_BITS-1:0] src,
                        input logic [SNK_BITS-1:0] snk, input logic [BW-1:0] data, input int nb, input int rdy,
                        input logic isgrant, input logic isrel, input logic isreq);
    if (n_dq_cnt >= QD) perr("K11", "D queue overflow");
    else begin
      dq_op[n_dq_tail] <= op; dq_param[n_dq_tail] <= prm; dq_src[n_dq_tail] <= src; dq_sink[n_dq_tail] <= snk;
      dq_data[n_dq_tail] <= data; dq_nb[n_dq_tail] <= nb; dq_rdy[n_dq_tail] <= rdy;
      dq_isgrant[n_dq_tail] <= isgrant; dq_isrel[n_dq_tail] <= isrel; dq_isreq[n_dq_tail] <= isreq;
      n_dq_tail = (n_dq_tail + 1) % QD; n_dq_cnt++;
    end
  endtask

  task automatic push_pq(input addr_t addr, input logic [1:0] cap, input logic cbo);
    if (n_pq_cnt >= QD) perr("K11", "Probe queue overflow");
    else begin
      pq_addr[n_pq_tail] <= addr; pq_cap[n_pq_tail] <= cap; pq_cbo[n_pq_tail] <= cbo;
      n_pq_tail = (n_pq_tail + 1) % QD; n_pq_cnt++;
    end
  endtask

  // expected ProbeAck param for the directory state and the cap of the Probe (1 toB, 2 toN)
  function automatic logic [2:0] expect_param(logic [1:0] d, logic [1:0] cap);
    if (d == 2'd0) return P_NtoN;
    if (cap == 2'd2) return d == 2'd1 ? P_BtoN : P_TtoN;
    return d == 2'd1 ? P_BtoB : P_TtoB;
  endfunction

  always @(posedge clk) begin
    int l;
    logic [BW-1:0] dsel;
    logic pd, a_fire, c_fire, d_fire, b_fire, e_fire, c_last, c_first, hasdata;
    logic [2:0] par;
    now <= now + 1;
    n_dq_cnt = dq_cnt; n_dq_tail = dq_tail; n_pq_cnt = pq_cnt; n_pq_tail = pq_tail;
    d_open_req = 0; d_open_grant = 0; d_open_rel = 0; d_open_probe = 0;
    pd = 0; n_aq_cnt = aq_cnt;
    ev_acq <= 0; ev_acq_perm <= 0; ev_cbo <= 0; ev_rel_first <= 0; ev_b_fire <= 0; ev_probe_done <= 0;
    ev_wb <= 0; ev_wb_data_valid <= 0;
    a_fire = a_valid && a_ready; c_fire = c_valid && c_ready; d_fire = d_valid && d_ready;
    b_fire = b_valid && b_ready; e_fire = e_valid && e_ready;

    if (rst) begin
      aq_head <= 0; aq_tail <= 0; aq_cnt <= 0; dq_head <= 0; dq_tail <= 0; dq_cnt <= 0; d_beat <= 0;
      pq_head <= 0; pq_tail <= 0; pq_cnt <= 0; b_pend <= 0; probe_open <= 0; eng_wait <= 0; c_beat <= 0;
      n_open_req <= 0; n_open_grant <= 0; n_open_rel <= 0; n_open_probe <= 0;
    end else begin
      // ---------------------------------------------------------------- FULL: the directory goes stale
      if (reset_point && full_mode)
        for (int k = 0; k < NL; k++) if (dir[k] != 2'd0) stale[k] <= 1'b1;

      // ---------------------------------------------------------------- directed Probe
      if (pr_req) begin
        push_pq(pr_addr, pr_cap, 1'b0);
        if (line_of(pr_addr) < 0) perr("K11", "directed Probe outside the test space");
      end

      // ---------------------------------------------------------------- B: a Probe was offered
      if (b_valid && !b_ready) b_pend <= 1'b1;
      if (b_fire) begin
        b_pend <= 1'b0; probe_open <= 1'b1; probe_addr <= b_head_addr; probe_cap <= pq_cap[pq_head];
        probe_cbo <= pq_cbo[pq_head]; probe_t0 <= now; ev_b_fire <= 1'b1; d_open_probe++; n_probe <= n_probe + 1;
        pq_head <= (pq_head + 1) % QD; n_pq_cnt--;
      end

      // ---------------------------------------------------------------- A
      if (a_fire) begin
        l = line_of(a_address);
        if (a_size != SIZE_BITS'(OFFB)) perr("K11", $sformatf("A size %0d, block expected", a_size));
        if (l < 0) perr("K11", $sformatf("A address %h outside the test space", a_address));
        else if (a_opcode == A_ACQBLOCK || a_opcode == A_ACQPERM || a_opcode == A_CBOCLEAN ||
                 a_opcode == A_CBOFLUSH || a_opcode == A_CBOINVAL) begin
          aq_op[aq_tail] <= a_opcode; aq_param[aq_tail] <= a_param; aq_src[aq_tail] <= a_source;
          aq_addr[aq_tail] <= a_address;
          aq_rdy[aq_tail] <= now + ((a_opcode >= A_CBOCLEAN) ? cbo_delay : grant_delay);
          aq_tail <= (aq_tail + 1) % QD; n_aq_cnt++;
          d_open_req++;
          if (a_opcode >= A_CBOCLEAN) ev_cbo <= 1'b1;
          else begin ev_acq <= 1'b1; n_acq <= n_acq + 1; if (a_opcode == A_ACQPERM) ev_acq_perm <= 1'b1; end
        end else perr("K11", $sformatf("unexpected A opcode %0d", a_opcode));
      end

      // ---------------------------------------------------------------- C
      if (c_fire) begin
        c_first = c_beat == 0;
        hasdata = c_opcode == C_PROBEACKDATA || c_opcode == C_RELEASEDATA;
        if (c_first) begin
          c_op_q <= c_opcode; c_param_q <= c_param; c_src_q <= c_source; c_addr_q <= c_address;
          if (c_size != SIZE_BITS'(OFFB)) perr("K11", $sformatf("C size %0d, block expected", c_size));
          if (c_opcode == C_RELEASE || c_opcode == C_RELEASEDATA) ev_rel_first <= 1'b1;
          if (!(c_opcode inside {C_PROBEACK, C_PROBEACKDATA, C_RELEASE, C_RELEASEDATA}))
            perr("K11", $sformatf("unexpected C opcode %0d", c_opcode));
        end else begin
          if (c_opcode != c_op_q || c_param != c_param_q || c_source != c_src_q || c_address != c_addr_q)
            perr("K11", "C beats of one message differ");
        end
        if (hasdata) c_acc[c_beat * DW +: DW] <= c_data;
        c_last = !hasdata || c_beat == NBEAT - 1;
        c_beat <= c_last ? 0 : c_beat + 1;
        if (c_corrupt) perr("K11", "C corrupt");
        if (c_last) begin
          l = line_of(c_address);
          dsel = hasdata ? ((NBEAT == 1) ? BW'(c_data) :
                  ((c_acc & ((BW'(1) << ((NBEAT - 1) * DW)) - BW'(1))) | (BW'(c_data) << ((NBEAT - 1) * DW)))) :
                 mem[(l < 0) ? 0 : l];
          if (l < 0) perr("K11", $sformatf("C address %h outside the test space", c_address));
          else if (c_opcode == C_PROBEACK || c_opcode == C_PROBEACKDATA) begin
            // ---------------------------------------------------------- ProbeAck
            par = c_param;
            if (!probe_open) perr("K11", "ProbeAck without an open Probe");
            else begin
              if (c_address != probe_addr) perr("K11", "ProbeAck address differs from the Probe");
              // the DCache answers with the id of its writeback entry, the gate echoes the source of the Probe
              if (c_source != PROBE_SRC && !(c_source >= REL_ID_BASE && c_source < REL_ID_BASE + NREL))
                perr("K11", $sformatf("ProbeAck source %0d is neither the source of the Probe nor a writeback id", c_source));
              if (par > 3'd5) perr("K11", "ProbeAck param out of range");
              if (c_opcode == C_PROBEACKDATA && par > 3'd2) perr("K11", "ProbeAckData with a Report param (NtoN, TtoT, BtoB)");
              if (stale[l]) begin
                // FULL: the L1D was reset, it is empty; the answer is NtoN whatever the directory says
                if (par != P_NtoN) perr("K8", $sformatf("FULL: line %0d stale in the directory, L1D answers param %0d, not NtoN", l, par));
                else if (dir[l] != 2'd0) n_nton_stale <= n_nton_stale + 1;
              end else if (par != expect_param(dir[l], probe_cap)) begin
                // a clean T line may be reported with TtoB / TtoN without data; a dirty one with data: same params
                perr("K8", $sformatf("line %0d: dir=%0d cap=%0d, ProbeAck param %0d, expected %0d", l, dir[l], probe_cap, par,
                                     expect_param(dir[l], probe_cap)));
              end
              if (c_opcode == C_PROBEACKDATA && dir[l] != 2'd2 && !stale[l]) perr("K11", "ProbeAckData for a line the client does not hold in T");
              if (par == P_NtoN) n_gate_ack <= n_gate_ack + 1;
              last_ack_param <= par; last_probe_line <= l; last_probe_lat <= now - probe_t0;
              if (hasdata) begin mem[l] <= dsel; poison[l] <= 1'b0; end
              dir[l] <= (par == P_NtoN || par == P_BtoN || par == P_TtoN) ? 2'd0 :
                        (par == P_BtoB || par == P_TtoB) ? 2'd1 : dir[l];
              stale[l] <= 1'b0;
              ev_wb <= 1'b1; ev_wb_line <= l; ev_wb_data <= dsel; ev_wb_data_valid <= hasdata;
              probe_open <= 1'b0; d_open_probe--; ev_probe_done <= 1'b1;
              if (eng_wait && eng_line == l && probe_cbo) pd = 1;
            end
          end else begin
            // ---------------------------------------------------------- Release
            par = c_param;
            if (par > P_BtoN) perr("K11", $sformatf("Release with param %0d (NtoN or a Report): not a Shrink", par));
            if (c_opcode == C_RELEASEDATA && par > P_TtoN) perr("K11", "ReleaseData with a param that is not TtoB / TtoN");
            if (stale[l] || dir[l] == 2'd0) perr("K8", $sformatf("Release of line %0d, which the directory does not list for the client", l));
            else if ((par == P_TtoB || par == P_TtoN) && dir[l] != 2'd2) perr("K8", $sformatf("Release param %0d, dir=%0d", par, dir[l]));
            else if (par == P_BtoN && dir[l] != 2'd1) perr("K8", $sformatf("Release BtoN, dir=%0d", dir[l]));
            if (hasdata) begin mem[l] <= dsel; poison[l] <= 1'b0; end
            dir[l] <= (par == P_TtoB) ? 2'd1 : 2'd0;
            ev_wb <= 1'b1; ev_wb_line <= l; ev_wb_data <= dsel; ev_wb_data_valid <= hasdata;
            n_rel <= n_rel + 1; d_open_rel++;
            push_d(D_RELACK, 2'd0, c_source, '0, '0, 1, now + rel_delay, 1'b0, 1'b1, 1'b0);
          end
        end
      end

      // ---------------------------------------------------------------- E
      if (e_fire) begin
        if (!sink_open[e_sink]) perr("K11", $sformatf("GrantAck for sink %0d, which is not open", e_sink));
        else begin sink_open[e_sink] <= 1'b0; d_open_grant--; end
      end

      // ---------------------------------------------------------------- engine: one A request at a time
      if (eng_wait) begin
        if (pd) begin
          push_d(D_CBOACK, 2'd0, eng_src, '0, '0, 1, now, 1'b0, 1'b0, 1'b1);
          eng_wait <= 1'b0;
        end
      end else if (aq_cnt != 0 && now >= aq_rdy[aq_head]) begin
        l = line_of(aq_addr[aq_head]);
        aq_head <= (aq_head + 1) % QD; n_aq_cnt--;
        if (aq_op[aq_head] == A_ACQBLOCK || aq_op[aq_head] == A_ACQPERM) begin
          // ---------------------------------------------------------- Acquire
          if (!stale[l] && dir[l] != 2'd0 && !(dir[l] == 2'd1 && aq_param[aq_head] == 3'd2))
            perr("K8", $sformatf("Acquire param %0d of line %0d, which the client holds (dir=%0d)", aq_param[aq_head], l, dir[l]));
          if (stale[l]) begin n_reacq_stale <= n_reacq_stale + 1; stale[l] <= 1'b0; end
          if (aq_op[aq_head] == A_ACQBLOCK) begin
            if (poison[l]) begin
              n_foreign_grant <= n_foreign_grant + 1;
              if (!full_mode) perr("K10", $sformatf("KEEP: GrantData of line %0d, whose data L2 does not hold (poisoned by AcquirePerm)", l));
            end
            push_d(D_GRANTDATA, (aq_param[aq_head] == 3'd0) ? 2'd1 : 2'd0, aq_src[aq_head], sink_next, mem[l], NBEAT, now,
                   1'b1, 1'b0, 1'b1);
            dir[l] <= (aq_param[aq_head] == 3'd0) ? 2'd1 : 2'd2;
          end else begin
            // MakeUnique: ownership without data. NtoT: L2's data array holds some other line afterwards
            push_d(D_GRANT, 2'd0, aq_src[aq_head], sink_next, '0, 1, now, 1'b1, 1'b0, 1'b1);
            dir[l] <= 2'd2;
            if (aq_param[aq_head] == 3'd1) begin poison[l] <= 1'b1; mem[l] <= foreign_line(l); end
          end
          sink_open[sink_next] <= 1'b1; sink_next <= sink_next + 1'b1;
        end else begin
          // ---------------------------------------------------------- CBO
          if (!stale[l] && dir[l] != 2'd0) begin
            push_pq(aq_addr[aq_head], (aq_op[aq_head] == A_CBOCLEAN) ? 2'd1 : 2'd2, 1'b1);
            eng_wait <= 1'b1; eng_line <= l; eng_src <= aq_src[aq_head];
          end else begin
            stale[l] <= 1'b0; dir[l] <= 2'd0;
            push_d(D_CBOACK, 2'd0, aq_src[aq_head], '0, '0, 1, now, 1'b0, 1'b0, 1'b1);
          end
        end
      end

      // ---------------------------------------------------------------- D
      if (d_fire) begin
        if (d_beat == dq_nb[dq_head] - 1) begin
          d_beat <= 0; dq_head <= (dq_head + 1) % QD; n_dq_cnt--;
          if (dq_isreq[dq_head]) d_open_req--;
          if (dq_isgrant[dq_head]) d_open_grant++;
          if (dq_isrel[dq_head]) d_open_rel--;
        end else d_beat <= d_beat + 1;
      end

      // ---------------------------------------------------------------- counters
      n_open_req <= n_open_req + d_open_req;
      n_open_grant <= n_open_grant + d_open_grant;
      n_open_rel <= n_open_rel + d_open_rel;
      n_open_probe <= n_open_probe + d_open_probe;
      aq_cnt <= n_aq_cnt; dq_cnt <= n_dq_cnt; dq_tail <= n_dq_tail; pq_cnt <= n_pq_cnt; pq_tail <= n_pq_tail;
    end
  end

  // checks that are independent of the traffic
  always @(posedge clk) if (!rst) begin
    if (n_open_probe < 0 || n_open_probe > 1) perr("K11", "more than one Probe open");
    if (n_open_req < 0 || n_open_grant < 0 || n_open_rel < 0) perr("K11", "negative open count");
    if (d_hold_q && !d_valid) perr("K11", "D valid dropped before the beat was taken");
    d_hold_q <= d_valid && !d_ready;
  end
endmodule
