// Driver of the RTL test: the core as the DCache sees it (store, atomics, CBO, load, WFI), the triggers that raise
// the reset request on an event, the timing of the Probes of L2, the cases D1..D13 and R, the checks after a
// sequence (K8). Included into dcache_tb.sv (module scope), so tasks and variables are shared.
// All signals are driven non-blocking at an edge and sampled at the next one (the values before the edge).

  // ------------------------------------------------------------------ constants and state
  localparam int CMD_SWAP = 4, CMD_LR = 6, CMD_SC = 7, CMD_ADD = 8, CMD_OR = 10, CMD_CASD = 27;
  localparam int TK_NOW = 0, TK_ACQ = 1, TK_ACQ_B = 2, TK_ACQ_P = 3, TK_CBO = 4, TK_REL = 5, TK_REL1 = 6, TK_ST_REPLAY = 7;
  localparam int PG_OFF = 0, PG_NOW = 1, PG_LASTQ = 2, PG_DRAIN1 = 3, PG_DECIDE = 4, PG_ISO1 = 5, PG_ISO2 = 6,
                 PG_RESET1 = 7, PG_RELEASE1 = 8, PG_COREUP = 9;

  logic [31:0] rs;
  function automatic int rnd(input int n);
    rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5;
    return int'(rs % 32'(n));
  endfunction
  function automatic int L(input int s, input int t);
    return s * NTAGS + t;
  endfunction
  // a line nobody used before: spread over the sets so that no set holds more than NWAYS of them (no evictions)
  int fresh_n = 0;
  function automatic int fresh();
    int n;
    n = fresh_n; fresh_n++;
    return L(n % NSETU, (n / NSETU) % NWAYS);
  endfunction

  int pm_mode = PG_NOW;                    // when a queued Probe of the stand may be offered
  always_comb begin
    case (pm_mode)
      PG_NOW:      pr_go = 1'b1;
      PG_LASTQ:    pr_go = (ph == 3'd1) && quiesce_done;                       // the last cycle of sQuiesce
      PG_DRAIN1:   pr_go = (ph == 3'd2) && (ph_q != 3'd2);                     // the first cycle of sDrain
      PG_DECIDE:   pr_go = (ph == 3'd2) && quiesce_done && gate_quiet && quiesce_idle;   // the decision cycle
      PG_ISO1:     pr_go = (ph == 3'd3) && (ph_q != 3'd3);
      PG_ISO2:     pr_go = (ph == 3'd3) && (ph_q == 3'd3);
      PG_RESET1:   pr_go = (ph == 3'd4) && (ph_q != 3'd4);
      PG_RELEASE1: pr_go = (ph == 3'd5) && (ph_q != 3'd5);
      PG_COREUP:   pr_go = (ph == 3'd5) && quiesce_alive && !core_in_reset;    // the last cycle of sRelease
      default:     pr_go = 1'b0;
    endcase
  end

  // ------------------------------------------------------------------ trigger: raises the request on an event
  int trig_kind = TK_NOW, trig_delay = 0, trig_hold = 3, trig_dly = 0, req_trig_cnt = 0;
  bit trig_armed = 1'b0, trig_pending = 1'b0;
  always @(posedge clk) begin
    bit ev;
    ev = 1'b0;
    if (req_trig_cnt > 0) begin
      req_trig_cnt <= req_trig_cnt - 1;
      if (req_trig_cnt == 1) req_trig <= 1'b0;
    end
    if (trig_armed) begin
      case (trig_kind)
        TK_NOW:   ev = 1'b1;
        TK_ACQ:   ev = ev_acq;
        TK_ACQ_B: ev = ev_acq && !ev_acq_perm;
        TK_ACQ_P: ev = ev_acq_perm;
        TK_CBO:   ev = ev_cbo;
        TK_REL:   ev = ev_rel_first;
        TK_REL1:  ev = (ph == 3'd5) && (ph_q != 3'd5);
        TK_ST_REPLAY: ev = st_replay_valid;                    // a store missed: its miss entry exists
        default:  ev = 1'b0;
      endcase
      if (ev) begin trig_armed <= 1'b0; trig_pending <= 1'b1; trig_dly <= trig_delay; end
    end
    if (trig_pending) begin
      if (trig_dly == 0) begin req_trig <= 1'b1; req_trig_cnt <= trig_hold; trig_pending <= 1'b0; acq_at_req <= l2_n_acq; end
      else trig_dly <= trig_dly - 1;
    end
  end

  int acq_at_req = 0;                      // Acquires seen by L2 up to the cycle the trigger raised the request
  task automatic arm(input int kind, input int dly, input int hold);
    trig_kind = kind; trig_delay = dly; trig_hold = hold; trig_armed = 1'b1;
  endtask
  task automatic setup(input int gd, input int rd, input int cd);
    k_grant_delay = gd; k_rel_delay = rd; k_cbo_delay = cd;
  endtask
  task automatic tick(input int n);
    repeat (n) @(posedge clk);
  endtask
  task automatic req_pulse(input int n);
    @(posedge clk); req_man <= 1'b1; repeat (n) @(posedge clk); req_man <= 1'b0;
  endtask

  // the sequence: wait for busy to rise and to fall
  task automatic wait_seq(input int tmo);
    int t;
    t = 0;
    while (!ctl_busy) begin
      @(posedge clk); t++;
      if (t > tmo) begin fail("K2", "the sequence did not start (the trigger never fired?)"); return; end
    end
    t = 0;
    while (ctl_busy) begin
      @(posedge clk); t++;
      if (t > tmo) begin fail("K2", $sformatf("the sequence did not end within %0d cycles", tmo)); return; end
    end
    tick(4);
  endtask

  // ------------------------------------------------------------------ stand initialisation
  task automatic init_stand();
    st_req_valid = 0; st_req_addr = 0; st_req_data = 0; st_req_mask = 0; st_req_id = 0;
    amo_req_valid = 0; amo_cmd = 0; amo_addr = 0; amo_data = 0; amo_mask = 0; amo_cmp = 0;
    cmo_req_valid = 0; cmo_opcode = 0; cmo_address = 0; cmo_resp_ready = 1;
    wfi_req = 0; ld_req_valid = 0; ld_req_addr = 0;
    for (int l = 0; l < NL; l++) begin
      gold[l] = init_line(l); gold_ok[l] = 1'b1; l1dirty[l] = 1'b0; touched[l] = 1'b0;
      snap_dir[l] = 2'd0; snap_poison[l] = 1'b0;
    end
  endtask

  // ------------------------------------------------------------------ operations of the core (abort when the core is reset)
  function automatic logic [BW/8-1:0] rnd_mask();
    logic [BW/8-1:0] m; int cnt, lo;
    cnt = 1 + rnd(BLOCK_BYTES - 1); lo = rnd(BLOCK_BYTES - cnt + 1);
    m = ((BW/8)'(1) << cnt) - (BW/8)'(1);
    return m << lo;
  endfunction

  task automatic do_store(input int li, input bit full, output bit ok);
    logic [BW-1:0] d; logic [BW/8-1:0] m; int id, t; bit done, replay, taken;
    d = '0; for (int b = 0; b < BW / 32; b++) d[b*32 +: 32] = 32'(rnd(32'h7fffffff)) ^ 32'(b * 977);
    m = full ? '1 : rnd_mask();
    id = li % (1 << REQ_ID_BITS);
    touched[li] = 1'b1;
    if (full) gold_ok[li] = 1'b0;           // the line is overwritten: unknown until the store has an answer
    ok = 1'b0; done = 1'b0;
    while (!done) begin
      st_req_valid <= 1'b1; st_req_addr <= line_base(li); st_req_data <= d; st_req_mask <= m; st_req_id <= id[REQ_ID_BITS-1:0];
      taken = 1'b0;
      while (!taken) begin
        @(posedge clk);
        if (!core_alive) begin st_req_valid <= 1'b0; return; end
        taken = st_req_ready;
      end
      st_req_valid <= 1'b0; inflight_st++;
      replay = 1'b0;
      for (t = 0; t < 400 && !done && !replay; t++) begin
        @(posedge clk);
        if (!core_alive) begin inflight_st = 0; return; end
        if (st_hit_valid && st_hit_id == id[REQ_ID_BITS-1:0]) done = 1'b1;
        else if (st_replay_valid && st_replay_id == id[REQ_ID_BITS-1:0]) replay = 1'b1;
      end
      inflight_st--;
      if (!done && !replay) begin fail("K2", "store: no answer within 400 cycles"); return; end
      if (replay) tick(1 + rnd(4));
    end
    for (int b = 0; b < BLOCK_BYTES; b++) if (m[b]) gold[li][b*8 +: 8] = d[b*8 +: 8];
    if (full) gold_ok[li] = 1'b1;
    l1dirty[li] = 1'b1;
    ok = 1'b1;
  endtask

  // atomic on the doubleword at byte offset off (a multiple of 16: the even word of the quad word)
  task automatic do_amo(input int li, input int off, input int cmd, input logic [63:0] dat, input logic [63:0] cmp,
                        output logic [63:0] res, output bit ok);
    logic [63:0] old; int w, t; bit done, resend, taken;
    w = off / 8; touched[li] = 1'b1; ok = 1'b0; done = 1'b0; res = '0;
    old = gold[li][w*64 +: 64];
    while (!done) begin
      amo_cmd <= cmd[4:0]; amo_addr <= line_base(li) + addr_t'(off); amo_data <= {dat, dat}; amo_mask <= 16'h00ff;
      amo_cmp <= {cmp, cmp}; amo_req_valid <= 1'b1;
      taken = 1'b0;
      while (!taken) begin
        @(posedge clk);
        if (!core_alive) begin amo_req_valid <= 1'b0; return; end
        taken = amo_req_ready;
      end
      amo_req_valid <= 1'b0; inflight_amo++;
      resend = 1'b0;
      for (t = 0; t < 3000 && !done && !resend; t++) begin
        @(posedge clk);
        if (!core_alive) begin inflight_amo = 0; return; end
        if (amo_resp_valid) begin
          if (amo_resp_miss && amo_resp_replay) resend = 1'b1;
          else if (!amo_resp_miss) done = 1'b1;
        end
      end
      inflight_amo--;
      if (!done && !resend) begin fail("K2", "atomic: no answer within 3000 cycles"); return; end
      if (resend) tick(1 + rnd(4));
    end
    res = amo_resp_data[63:0];
    if (cmd == CMD_SC) begin
      if (res[0] == 1'b0) begin gold[li][w*64 +: 64] = dat; l1dirty[li] = 1'b1; end
    end else begin
      if (gold_ok[li] && res != old) fail("K10", $sformatf("atomic cmd %0d line %0d: old value %h, the core wrote %h", cmd, li, res, old));
      case (cmd)
        CMD_ADD:  begin gold[li][w*64 +: 64] = old + dat; l1dirty[li] = 1'b1; end
        CMD_SWAP: begin gold[li][w*64 +: 64] = dat; l1dirty[li] = 1'b1; end
        CMD_OR:   begin gold[li][w*64 +: 64] = old | dat; l1dirty[li] = 1'b1; end
        CMD_CASD: begin if (old == cmp) gold[li][w*64 +: 64] = dat; l1dirty[li] = 1'b1; end
        default:  ;
      endcase
    end
    ok = 1'b1;
  endtask

  task automatic do_cmo(input int li, input int op, output bit ok);
    int t; bit taken;
    touched[li] = 1'b1; ok = 1'b0;
    cmo_opcode <= op[2:0]; cmo_address <= 64'(line_base(li)); cmo_req_valid <= 1'b1;
    taken = 1'b0;
    while (!taken) begin
      @(posedge clk);
      if (!core_alive) begin cmo_req_valid <= 1'b0; return; end
      taken = cmo_req_ready;
    end
    cmo_req_valid <= 1'b0; inflight_cmo++;
    for (t = 0; t < 4000 && !ok; t++) begin
      @(posedge clk);
      if (!core_alive) begin inflight_cmo = 0; return; end
      if (cmo_resp_valid) ok = 1'b1;
    end
    inflight_cmo--;
    if (!ok) fail("K2", "CBO: no answer within 4000 cycles");
  endtask

  // one load; hit = the answer of the cache was a hit
  task automatic do_ld(input int li, input int off, output bit hit, output bit ok);
    int c0, t; bit taken;
    touched[li] = 1'b1; ok = 1'b0; hit = 1'b0; c0 = ld_resp_cnt;
    ld_req_addr <= line_base(li) + addr_t'(off); ld_req_valid <= 1'b1;
    taken = 1'b0;
    while (!taken) begin
      @(posedge clk);
      if (!core_alive) begin ld_req_valid <= 1'b0; return; end
      taken = ld_req_ready;
    end
    ld_req_valid <= 1'b0;
    for (t = 0; t < 12 && ld_resp_cnt == c0; t++) @(posedge clk);
    if (ld_resp_cnt != c0) begin ok = 1'b1; hit = ld_last_hit; end
  endtask

  task automatic load_until_hit(input int li, input int off, output bit ok);
    bit hit;
    ok = 1'b0;
    for (int i = 0; i < 60 && !ok; i++) begin
      do_ld(li, off, hit, ok);
      if (!core_alive) return;
      if (ok && hit) return;
      ok = 1'b0; tick(3 + rnd(5));
    end
    if (core_alive) fail("K2", $sformatf("load of line %0d did not hit after 60 tries", li));
  endtask

  // a stream of loads (D13): every cycle, to the lines of the list, until it is switched off
  bit ld_stream_en = 1'b0, ld_stream_was = 1'b0; int ld_stream_lines [3]; int ld_stream_k = 0, ld_iso_fires = 0;
  always @(posedge clk) begin
    if (ld_stream_en && ph == 3'd4) ld_stream_en = 1'b0;    // the core is reset: its load stream ends there
    ld_stream_was <= ld_stream_en;
    if (ld_stream_en) begin
      if (core_alive) begin
        ld_req_valid <= 1'b1;
        ld_req_addr <= line_base(ld_stream_lines[ld_stream_k % 3]) + addr_t'(8 * (ld_stream_k % 8));
        if (ld_req_valid && ld_req_ready) ld_stream_k <= ld_stream_k + 1;
      end else ld_req_valid <= 1'b0;
    end else if (ld_stream_was) ld_req_valid <= 1'b0;
    if (ph == 3'd3 && ld_req_valid && ld_req_ready) ld_iso_fires <= ld_iso_fires + 1;
  end

  // a Probe of the stand (cap: 1 toB, 2 toN); it is offered when pm_mode allows
  int pd_cnt = 0;
  always @(posedge clk) if (ev_probe_done) pd_cnt++;
  task automatic inject_probe(input int li, input int cap);
    touched[li] = 1'b1;
    @(posedge clk);
    pr_addr <= line_base(li); pr_cap <= cap[1:0]; pr_req <= 1'b1;
    @(posedge clk);
    pr_req <= 1'b0;
  endtask
  task automatic wait_probe(input int n0, input int tmo);
    int t;
    for (t = 0; t < tmo && pd_cnt <= n0; t++) @(posedge clk);
    if (pd_cnt <= n0) fail("K7", $sformatf("the Probe was not answered within %0d cycles", tmo));
  endtask
  // a Probe in the quiet state (after a sequence): the line is not in flight
  task automatic probe_now(input int li, input int cap);
    int n0, t;
    pm_mode = PG_NOW;
    for (t = 0; t < 400 && !(l2_quiet && l2_n_open_probe == 0); t++) @(posedge clk);
    n0 = pd_cnt;
    inject_probe(li, cap);
    wait_probe(n0, 800);
  endtask

  // ------------------------------------------------------------------ K8: the state after a sequence
  task automatic verify_after();
    bit hit, ok; int nacq0;
    tick(8);
    pm_mode = PG_NOW;
    if (!snap_valid) begin fail("K8", "no reset point was seen in the sequence"); return; end
    for (int l = 0; l < NL; l++) begin
      if (touched[l] && snap_dir[l] != 2'd0) begin
        if (IS_KEEP) begin
          do_ld(l, 0, hit, ok);
          if (ok && !hit) fail("K8", $sformatf("KEEP: line %0d (directory %0d) is not in L1D after the reset", l, snap_dir[l]));
          if (snap_dir[l] == 2'd2 && l % 2 == 0) begin
            nacq0 = l2_n_acq;
            do_store(l, 0, ok);
            if (ok && l2_n_acq != nacq0) fail("K8", $sformatf("KEEP: a store to the T line %0d needed an Acquire", l));
          end
          if (l % 3 == 0) probe_now(l, 2);     // the report is checked against the directory, the data against gold
        end else begin
          if (l % 2 == 0) probe_now(l, 2);     // stale line: NtoN (checked in L2)
          else begin
            do_ld(l, 0, hit, ok);
            if (ok && hit) fail("K8", $sformatf("FULL: line %0d is in L1D after the reset (load hit)", l));
          end
        end
      end
    end
    tick(20);
  endtask

  // ------------------------------------------------------------------ cases
  task automatic scn_d1();
    int ks [3];
    bit ok;
    ks[0] = 0; ks[1] = 5; ks[2] = 40;
    for (int i = 0; i < 3; i++) begin
      setup(ks[i], 4, 4);
      arm(TK_ACQ_B, 0, 3);
      do_store(fresh(), 1'b0, ok);
      wait_seq(8000);
      verify_after();
    end
  endtask

  task automatic scn_d2();
    bit ok;
    int p0;
    p0 = cnt_acq_perm;
    for (int i = 0; i < 3; i++) begin
      setup(3 * i, 4, 4);
      arm(TK_ACQ_P, 0, 3);
      do_store(fresh(), 1'b1, ok);
      wait_seq(8000);
      verify_after();
    end
    if (cnt_acq_perm == p0) fail("K8", "D2: a store of a whole line did not produce an AcquirePerm");
  endtask

  task automatic scn_d3();
    bit ok; logic [63:0] r;
    for (int i = 0; i < 3; i++) begin
      setup(3 * i, 4, 4);
      arm(TK_ACQ, 0, 3);
      do_amo(fresh(), 0, CMD_ADD, 64'h1111_0000_0000_0001 * (i + 1), 64'd0, r, ok);
      wait_seq(8000);
      verify_after();
    end
  endtask

  task automatic scn_d4();
    bit ok, hit; logic [63:0] r; int n0, li;
    for (int i = 0; i < 2; i++) begin
      li = fresh(); setup(3, 4, 4);
      do_amo(li, 0, CMD_LR, 64'd0, 64'd0, r, ok);              // the reservation is set (the line is T)
      n0 = pd_cnt; pm_mode = PG_NOW;
      inject_probe(li, 2);                                     // a Probe in the LR/SC window
      arm(TK_NOW, 4, 3);
      do_amo(li, 0, CMD_SC, 64'hABCD_0000_0000_0000, 64'd0, r, ok);
      wait_seq(8000);
      if (pd_cnt > n0 && l2_last_probe_lat > LRSC_CYCLES + 120)
        fail("K10", $sformatf("a Probe in the LR/SC window waited %0d cycles (window %0d)", l2_last_probe_lat, LRSC_CYCLES));
      verify_after();
      do_amo(li, 0, CMD_SC, 64'h5555_0000_0000_0000, 64'd0, r, ok);   // no reservation after the reset
      if (ok && r[0] == 1'b0) fail("K8", "an SC after the reset succeeded: the reservation survived");
      tick(20);
    end
  endtask

  task automatic scn_d5();
    bit ok; logic [63:0] r; int li;
    for (int i = 0; i < 2; i++) begin
      setup(3 * i + 2, 4, 4);
      li = fresh();
      arm(TK_ACQ, 0, 3);
      do_amo(li, 16, CMD_CASD, 64'hCAFE_0000_0000_0000 + i, gold[li][128 +: 64], r, ok);   // the doubleword at byte 16 is compared with itself
      wait_seq(8000);
      verify_after();
    end
  endtask

  task automatic scn_d6();
    bit ok;
    for (int op = 0; op < 3; op++) begin
      int li;
      li = fresh();
      setup(3, 4, 6);
      do_store(li, 1'b0, ok);                  // a dirty line in L1D
      arm(TK_CBO, 0, 3);
      do_cmo(li, op, ok);
      wait_seq(8000);
      verify_after();
    end
  endtask

  // WFI holds the Acquire of a store miss in the MissQueue; the request comes while it is held. The drain must
  // release it (quiesceBlock clears wfiReq), or the sequence could never finish. The request is raised 10 cycles
  // after the replay answer of the store: the miss entry exists by then. (A fixed delay after the start is not
  // enough: after a reset the tag array is being initialised for NSETS cycles and refuses stores.)
  task automatic scn_d7();
    bit ok; int n0;
    for (int i = 0; i < 2; i++) begin
      setup(3, 4, 4);
      n0 = l2_n_acq;
      wfi_req <= 1'b1; tick(3);
      arm(TK_ST_REPLAY, 10, 3);
      do_store(fresh(), 1'b0, ok);             // the Acquire is held by WFI
      wait_seq(2000);
      wfi_req <= 1'b0;
      if (acq_at_req != n0) fail("TB", "D7: an Acquire left before the request although WFI was requested (the case did not set up)");
      if (l2_n_acq == n0) fail("K2", "D7: the Acquire held by WFI never left (the drain did not release it)");
      verify_after();
    end
  endtask

  // a Probe at a chosen point of the sequence: dirty line (store) and clean line (load)
  task automatic scn_probe_at(input int mode, input int nphase);
    bit ok, okl; int li;
    for (int v = 0; v < 2; v++) begin
      li = fresh();
      setup(3, 4, 4);
      if (v == 0) do_store(li, 1'b0, ok); else load_until_hit(li, 0, okl);
      pm_mode = mode;
      inject_probe(li, 2);
      arm(TK_NOW, 0, 3);
      wait_seq(8000);
      pm_mode = PG_NOW;
      verify_after();
    end
  endtask
  task automatic scn_d8();  scn_probe_at(PG_LASTQ, 0); endtask
  task automatic scn_d9();  scn_probe_at(PG_DRAIN1, 1); scn_probe_at(PG_DECIDE, 2); endtask
  task automatic scn_d10();
    scn_probe_at(PG_ISO1, 3);
    if (ISO_CYC > 1) scn_probe_at(PG_ISO2, 4);
    scn_probe_at(PG_RESET1, 5);
    scn_probe_at(PG_RELEASE1, 6);
    scn_probe_at(PG_COREUP, 7);
  endtask

  task automatic scn_d11();
    bit ok;
    for (int rep = 0; rep < 2; rep++) begin
      setup(3, 40 + 30 * rep, 4);
      for (int t = 0; t <= NWAYS; t++) begin
        if (t == NWAYS) arm(TK_REL, 0, 3);
        do_store(L(rep, t), 1'b0, ok);   // the last store evicts a dirty line: a Release in flight
      end
      wait_seq(8000);
      verify_after();
    end
  endtask

  task automatic scn_d12();
    bit ok; int d0;
    setup(3, 4, 4);
    do_store(L(0, 0), 1'b0, ok);
    req_pulse(1);                              // a one-cycle impulse in sIdle: a whole sequence
    wait_seq(8000);
    verify_after();
    do_store(L(0, 1), 1'b0, ok);
    d0 = b2b_direct;
    arm(TK_REL1, 0, 130);                      // raised again in the first cycle of sRelease and held: a second sequence follows
    @(posedge clk); req_man <= 1'b1; tick(140); req_man <= 1'b0;
    wait_seq(12000);
    if (b2b_direct == d0) fail("K6", "D12: no direct sRelease -> sQuiesce transition after a request raised in sRelease");
    verify_after();
  endtask

  task automatic scn_d13();
    bit ok; logic [63:0] r;
    setup(3, 4, 4);
    for (int t = 0; t < 3; t++) do_store(L(0, t), 1'b0, ok);   // dirty lines in the arrays
    ld_stream_lines[0] = L(0, 0); ld_stream_lines[1] = L(0, 1); ld_stream_lines[2] = L(0, 2);
    ld_stream_en = 1'b1;
    tick(60);
    arm(TK_NOW, 0, 3);
    wait_seq(8000);
    ld_stream_en = 1'b0; tick(4);
    verify_after();
    $display("D13: loads accepted in sIso=%0d, array accesses while isolated: boundary=%0d memory=%0d", ld_iso_fires, sram_bnd_iso, sram_mem_iso);
    if (ld_iso_fires == 0) fail("K5", "D13: no load reached the DCache in sIso, the freeze check was not exercised");
    if (!IS_KEEP && sram_bnd_iso == 0 && sram_mem_iso == 0)
      fail("K5", "D13: FULL: no array access seen while isolated, the probes see nothing (an empty check)");
  endtask

  // random mixture: stores, atomics, loads, CBO, Probes, requests
  task automatic scn_rand();
    bit ok, hit; logic [63:0] r; int li, k;
    for (int sq = 0; sq < 3; sq++) begin
      setup(rnd(30), rnd(30), rnd(20));
      pm_mode = (rnd(3) == 0) ? (PG_LASTQ + rnd(8)) : PG_NOW;
      arm(TK_NOW, 20 + rnd(300), (rnd(4) == 0) ? 120 + rnd(100) : 1 + rnd(6));
      for (k = 0; k < 40; k++) begin
        li = L(rnd(NSETU), rnd(NTAGS));
        case (rnd(8))
          0, 1: do_store(li, rnd(4) == 0, ok);
          2:    do_amo(li, 16 * rnd(4), CMD_ADD, 64'(rnd(1000000)), 64'd0, r, ok);
          3:    do_ld(li, 8 * rnd(8), hit, ok);
          4:    do_cmo(li, rnd(3), ok);
          5:    begin if (pm_mode == PG_NOW && l2_n_open_req == 0 && l2_n_open_grant == 0 && l2_n_open_rel == 0 && !ctl_busy)
                        inject_probe(li, 1 + rnd(2)); end
          6:    begin wfi_req <= rnd(2); end
          default: tick(1 + rnd(10));
        endcase
        tick(rnd(6));
      end
      wfi_req <= 1'b0;
      if (!ctl_busy && !trig_pending && !trig_armed && req_trig_cnt == 0) arm(TK_NOW, 0, 3);
      wait_seq(30000);
      pm_mode = PG_NOW;
      verify_after();
    end
  endtask

  task automatic run_case(input string c);
    if      (c == "D1")  scn_d1();
    else if (c == "D2")  scn_d2();
    else if (c == "D3")  scn_d3();
    else if (c == "D4")  scn_d4();
    else if (c == "D5")  scn_d5();
    else if (c == "D6")  scn_d6();
    else if (c == "D7")  scn_d7();
    else if (c == "D8")  scn_d8();
    else if (c == "D9")  scn_d9();
    else if (c == "D10") scn_d10();
    else if (c == "D11") scn_d11();
    else if (c == "D12") scn_d12();
    else if (c == "D13") scn_d13();
    else if (c == "R")   scn_rand();
    else fail("TB", {"unknown case ", c});
  endtask

  // ------------------------------------------------------------------ trace for debugging (+DBG): one line per event
  bit dbg = 1'b0;
  initial dbg = $test$plusargs("DBG");
  always @(posedge clk) if (dbg && !rst) begin
    if (ph != ph_q) $display("DBG %0d phase %0d -> %0d", cycle, ph_q, ph);
    if (st_req_valid && st_req_ready) $display("DBG %0d store taken addr=%h id=%0d", cycle, st_req_addr, st_req_id);
    if (st_hit_valid) $display("DBG %0d store hit id=%0d", cycle, st_hit_id);
    if (st_replay_valid) $display("DBG %0d store replay id=%0d", cycle, st_replay_id);
    if (amo_req_valid && amo_req_ready) $display("DBG %0d amo taken cmd=%0d addr=%h", cycle, amo_cmd, amo_addr);
    if (amo_resp_valid) $display("DBG %0d amo resp miss=%0b replay=%0b", cycle, amo_resp_miss, amo_resp_replay);
    if (cmo_req_valid && cmo_req_ready) $display("DBG %0d cmo taken op=%0d", cycle, cmo_opcode);
    if (cmo_resp_valid) $display("DBG %0d cmo resp", cycle);
    if (ld_resp_valid) $display("DBG %0d load resp miss=%0b replay=%0b", cycle, ld_resp_miss, ld_resp_replay);
    if (l2io_0_a_valid && l2io_0_a_ready) $display("DBG %0d L2 A op=%0d param=%0d addr=%h src=%0d", cycle,
      l2io_0_a_bits_opcode, l2io_0_a_bits_param, l2io_0_a_bits_address, l2io_0_a_bits_source);
    if (l2io_0_b_valid && l2io_0_b_ready) $display("DBG %0d L2 B probe param=%0d addr=%h", cycle, l2io_0_b_bits_param, l2io_0_b_bits_address);
    if (l2io_0_c_valid && l2io_0_c_ready) $display("DBG %0d L2 C op=%0d param=%0d addr=%h src=%0d", cycle,
      l2io_0_c_bits_opcode, l2io_0_c_bits_param, l2io_0_c_bits_address, l2io_0_c_bits_source);
    if (l2io_0_d_valid && l2io_0_d_ready) $display("DBG %0d L2 D op=%0d src=%0d", cycle, l2io_0_d_bits_opcode, l2io_0_d_bits_source);
    if (l2io_0_e_valid && l2io_0_e_ready) $display("DBG %0d L2 E", cycle);
    if (quiesce_done && !done_q) $display("DBG %0d quiesce done", cycle);
    if (wfi_req && !wfi_q) $display("DBG %0d wfi_req up", cycle);
  end
  bit wfi_q = 1'b0;
  always @(posedge clk) wfi_q <= wfi_req;

  // ------------------------------------------------------------------ end of the case
  task automatic finish_case();
    int t;
    if (finished) return;
    finished = 1'b1;
    ld_stream_en = 1'b0;
    for (t = 0; t < 3000 && !(l2_quiet && !ctl_busy); t++) @(posedge clk);
    if (!l2_quiet) fail("K1", $sformatf("end of the case: L2 has open transactions (req=%0d grant=%0d rel=%0d probe=%0d)",
                                       l2_n_open_req, l2_n_open_grant, l2_n_open_rel, l2_n_open_probe));
    if (ctl_busy) fail("K2", "end of the case: the sequence is still running");
    if (l2_err != 0) err_cnt += l2_err;
    if (err_cnt == 0)
      $display("RESULT: PASS  probes=%0d gate-acks=%0d lost-dirty=%0d foreign=%0d sram-in-iso=%0d cycles=%0d seqs=%0d b2b=%0d loads=%0d/%0d",
               l2_n_probe, l2_n_gate_ack, full_lost, full_foreign, sram_bnd_iso + sram_mem_iso, cycle, seqs, b2b_direct,
               ld_hits, ld_misses);
    else
      $display("RESULT: FAIL ERROR %0d error(s), see the first ERROR line above (probes=%0d gate-acks=%0d cycles=%0d)",
               err_cnt, l2_n_probe, l2_n_gate_ack, cycle);
    $finish;
  endtask
