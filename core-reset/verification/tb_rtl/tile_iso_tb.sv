// ============================================================================
// tile_iso_tb: isolation of the side band of XSCore in the RTL of XSTile (TESTPLAN section 6), on the RTL of a full
// XSNoCTop elaboration with stubs in place of XSCore and L2Top (scripts/make_stubs.py, scripts/run_tile_iso.sh).
// The XSCore stub drives garbage on every output while it is isolated (and side band garbage always); the bench requires
// that nothing of it reaches L2Top or the outputs of XSTile:
//   T1 from the second cycle of isolate to its end every input of L2Top and every output of XSTile is stable (data
//      fields qualified by a low valid excepted, allow list tb_rtl/tile_iso_allow.txt)       (monitors in the stubs)
//   T2 clamp values in the first cycle of isolate (DESIGN 6.2)                                (monitors in the stubs)
//   T3 while busy: the prefetch hints to L2 (addr_valid) and l2_pf_master_en are 0           (monitors in the stubs)
//   T4 while busy: the TLB request of L2 to the core (l2_tlb_req.req.valid) is 0
//   T5 the reset of the core rises only after a cycle of isolate; isolate falls only after a cycle with the DCache
//      alive and the frontend out of reset; core_in_reset only while the core reset is asserted; core_reset_busy
//      and hartIsInReset = busy
//   T6 KEEP: l1_keep_reset of the core is high in the tile reset and never during a sequence; FULL: no such port
//   T7 each request input alone starts a sequence after its synchroniser (3 flip-flops); all three at once: one
// Names: tile_iso_names.svh (generated, copied from tile_iso_names_<cfg>.svh by the run script).
// One line at the end: RESULT: PASS | RESULT: FAIL <list>.
// ============================================================================
`timescale 1ns/1ps
`include "tile_iso_names.svh"
module tile_iso_tb;
  logic clock = 1'b0; always #5 clock = ~clock;
  logic reset = 1'b1, req_debug = 1'b0, req_hart = 1'b0, req_cluster = 1'b0;
  wire ti_core_reset_busy, ti_core_in_reset, ti_hart_in_reset;
  tile_iso_dut dut (.clock, .reset, .req_debug, .req_hart, .req_cluster, .ti_core_reset_busy, .ti_core_in_reset,
                    .ti_hart_in_reset);

  // ---- state of the controller (read through the hierarchy) and the windows of the monitors
  wire busy_now = `TI_CTRL.io_busy;
  wire iso_now = `TI_CTRL.io_isolate;
`ifdef TI_HAS_ACK_PROBE
  wire ack_now = `TI_CTRL.io_ackProbe;           // the gate answers Probes (FULL, sReset / sRelease): its B ready is takeB
`else
  wire ack_now = 1'b0;                           // KEEP: the controller has no ackProbe (constant 0, removed by firtool)
`endif
  logic ack_q = 1'b0; always @(posedge clock) ack_q <= ack_now;
  logic iso_q = 1'b0, tile_up = 1'b0; int up_cnt = 0;
  always @(posedge clock) begin
    iso_q <= iso_now;
    up_cnt <= reset ? 0 : (up_cnt < 1000 ? up_cnt + 1 : up_cnt);
    tile_up <= !reset && up_cnt >= 20;
  end
  wire chk_stable = tile_up && iso_now && iso_q;   // T1: from the second cycle of isolate
  wire chk_first = tile_up && iso_now && !iso_q;   // T2: the first cycle of isolate

  // ---- checks T4..T6
  int e_t4 = 0, e_t5 = 0, e_t6 = 0, e_t7 = 0;
  int n_iso_cycles = 0, n_iso_first = 0, n_seq = 0, n_core_resets = 0, n_t3_pf = 0, n_t3_master = 0, n_t4_seen = 0, n_keep_seen = 0;
  logic core_rst_q = 1'b0, alive_q = 1'b0, fe_q = 1'b0, busy_q = 1'b0;
  task automatic err(input string t, input string m, inout int n);
    n++; if (n <= 20) $display("[%0t] ERROR %s: %s", $time, t, m);
  endtask
  always @(posedge clock) begin
    core_rst_q <= `TI_CORE.ti_reset; alive_q <= `TI_CORE.ti_alive; fe_q <= `TI_CORE.ti_fe; busy_q <= busy_now;
    if (iso_now) n_iso_cycles++;
    if (chk_first) n_iso_first++;
    if (tile_up && busy_now && !busy_q) n_seq++;
    if (tile_up && busy_now && `TI_CORE.ti_pf_out) n_t3_pf++;
    if (tile_up && busy_now && `TI_CORE.ti_pf_master) n_t3_master++;
    // T4
`ifndef TI_NO_TLB_REQ
    if (tile_up && busy_now && `TI_CORE.ti_tlb_req_valid) err("T4", "l2_tlb_req.req.valid reaches the core while busy", e_t4);
    if (tile_up && !busy_now && `TI_CORE.ti_tlb_req_valid) n_t4_seen++;
`endif
    // T5
    if (tile_up && `TI_CORE.ti_reset && !core_rst_q) begin
      n_core_resets++;
      if (!iso_q) err("T5", "the reset of XSCore rises without a cycle of isolate before it", e_t5);
    end
    if (tile_up && iso_q && !iso_now && !(alive_q && !fe_q))
      err("T5", $sformatf("isolate falls after a cycle with alive %0d, resetInFrontend %0d", alive_q, fe_q), e_t5);
    if (tile_up && ti_core_in_reset && !(`TI_CORE.ti_reset && iso_now))
      err("T5", "core_in_reset high while the core is not in reset or not isolated", e_t5);
    if (tile_up && ti_core_reset_busy !== busy_now) err("T5", "core_reset_busy != busy", e_t5);
    if (tile_up && ti_hart_in_reset !== busy_now) err("T5", "hartIsInReset != busy", e_t5);
    // T6
`ifdef TI_HAS_KEEP_RESET
    if (reset && `TI_CORE.ti_keep_reset) n_keep_seen++;
    if (tile_up && busy_now && `TI_CORE.ti_keep_reset) err("T6", "l1_keep_reset of the core is high during the sequence", e_t6);
`endif
  end

  task automatic cycles(input int n); repeat (n) @(posedge clock); endtask
  task automatic wait_busy(input logic v, input int maxc, output int waited);
    waited = 0;
    while (busy_now !== v && waited < maxc) begin @(posedge clock); waited++; end
    if (busy_now !== v) begin e_t7++; $display("[%0t] ERROR T7: busy did not become %0d within %0d cycles", $time, v, maxc); end
  endtask
  // one request input (0 debug_reset, 1 hart_reset, 2 core_reset_req, 3 all three), held for hold cycles after busy
  task automatic one_request(input int src, input int hold);
    int n0 = n_seq, w;
    if (src == 0 || src == 3) req_debug = 1'b1;
    if (src == 1 || src == 3) req_hart = 1'b1;
    if (src == 2 || src == 3) req_cluster = 1'b1;
    wait_busy(1'b1, 50, w);
    // T7: the synchroniser (3 flip-flops) and the step of the controller
    if (w < 3 || w > 5) begin e_t7++; $display("[%0t] ERROR T7: request %0d seen as busy after %0d cycles (3..5 expected)", $time, src, w); end
    else $display("T7 request %0d: busy after %0d cycles", src, w);
    cycles(hold);
    req_debug = 1'b0; req_hart = 1'b0; req_cluster = 1'b0;
    wait_busy(1'b0, 5000, w);
    if (n_seq - n0 != 1) begin e_t7++; $display("[%0t] ERROR T7: %0d sequences for request %0d, expected 1", $time, n_seq - n0, src); end
    cycles(30);
  endtask

  int seed;
  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("=== tile isolation test, configuration %s, seed %0d (gates %0d, TLResetIsolation %0d) ===", `TI_CFG, seed, `TI_N_GATES, `TI_N_ISO);
    reset = 1'b1; cycles(30); reset = 1'b0; cycles(60);
    for (int src = 0; src < 4; src++) one_request(src, 150);
    for (int k = 0; k < 6; k++) one_request(k % 3, $urandom_range(110, 600));
    finish();
  end

  task automatic finish();
    int t1, t2, t3, t3c; string bad;
    cycles(20);
    t1 = `TI_L2.n_t1 + dut.n_t1; t2 = `TI_L2.n_t2 + dut.n_t2; t3 = `TI_L2.n_t3 + dut.n_t3; t3c = `TI_L2.n_t3_checked + dut.n_t3_checked;
    $display("tile-iso: sequences=%0d core-resets=%0d isolate-cycles=%0d first-cycles=%0d t3-samples=%0d t3-pf-from-core=%0d t3-pf-master-from-core=%0d t4-unmasked-seen=%0d keep-reset-in-tile-reset=%0d",
             n_seq, n_core_resets, n_iso_cycles, n_iso_first, t3c, n_t3_pf, n_t3_master, n_t4_seen, n_keep_seen);
    $display("tile-iso errors: T1=%0d T2=%0d T3=%0d T4=%0d T5=%0d T6=%0d T7=%0d", t1, t2, t3, e_t4, e_t5, e_t6, e_t7);
    bad = "";
    if (t1) bad = {bad, " T1"};
    if (t2 || `TI_T2_MISSING != "") bad = {bad, " T2"};
    if (`TI_T2_MISSING != "") $display("ERROR T2: patterns without a signal (names differ in this RTL): %s", `TI_T2_MISSING);
    if (`TI_T2_SKIP != "") $display("T2 SKIP %s", `TI_T2_SKIP);
    if (t3 || t3c == 0 || n_t3_pf == 0 || n_t3_master == 0) bad = {bad, " T3"};
    if (e_t4) bad = {bad, " T4"};
`ifndef TI_NO_TLB_REQ
    if (n_t4_seen == 0) bad = {bad, " T4(empty)"};
`endif
    if (e_t5 || n_core_resets != n_seq) bad = {bad, " T5"};
`ifdef TI_HAS_KEEP_RESET
    if (e_t6 || n_keep_seen == 0) bad = {bad, " T6"};
    if (`TI_CFG == "full") bad = {bad, " T6(l1_keep_reset port in FULL)"};
`else
    if (`TI_CFG == "keep") begin bad = {bad, " T6(no l1_keep_reset port in KEEP)"}; end
`endif
    if (e_t7 || n_seq != 10) bad = {bad, " T7"};
    if (n_iso_first == 0) bad = {bad, " (no isolate)"};
    if (bad == "") $display("RESULT: PASS"); else $display("RESULT: FAIL%s", bad);
    $finish;
  endtask
endmodule
