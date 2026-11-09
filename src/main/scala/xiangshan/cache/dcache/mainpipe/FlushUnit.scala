/***************************************************************************************
* DCacheFlushUnit: L1 DCache drain (and sweep) before a reset of XSCore (core + L1) alone, while L2 keeps
* running (SoCParameters.EnableCoreReset, see xiangshan/CoreReset.scala).
*
* The core reset resets the control logic of the DCache (MainPipe, MissQueue, WritebackQueue, ProbeQueue),
* so it must be idle at the reset point: no miss, no Release waiting for its ReleaseAck or half sent, no
* store or atomic in MainPipe. The flush unit makes it so and keeps it so until the core is reset.
* Two implementations (SoCParameters.CoreResetKeepL1, the Scala parameter sweep = !CoreResetKeepL1):
*   keep  (sweep = false): L1D keeps its lines across the core reset: their coherence state (metaArray)
*                          and error flags (errorArray) are flops on the tile reset (DCacheWrapper), tags and
*                          data are SRAMs that are never reset.
*   sweep (sweep = true) : every valid line is released to L2 first: a voluntary Release (clean line) or
*                          ReleaseData (dirty line; a line obtained by AcquirePerm is always dirty), the
*                          eviction path of MainPipe. L1D is empty afterwards, no data is lost, and L2's
*                          directory records no L1D copy; then L1D is reset together with the core.
*
* Sequence (state machine below):
*   sIdle  -- quiesce.req --> sDrain : block stores, atomics, CMOs and new misses (loads still read hits)
*   sDrain -- MissQueue and WritebackQueue empty for 16 cycles (and in the cycle of the transition)
*             --> sSweep (sweep) or sDone (keep)
*   sSweep : one MainPipe flush request per (set, way), way-major so consecutive requests hit different
*            sets and are not stalled by the MainPipe set-conflict check; an invalid way ends in s3 at once
*   sWait  -- no flush request in MainPipe, WritebackQueue empty (every Release got its ReleaseAck, every
*             ProbeAck sent), MissQueue empty, for 16 cycles (and in the cycle of the transition) --> sDone
*   sDone  : quiesce.done = 1, blocking is kept while quiesce.req is high
* L2 probes keep being served throughout (ProbeQueue -> MainPipe -> WritebackQueue); MainPipe gives them a
* higher priority than the sweep, and a Probe that meets a Release of the same line waits for its
* ReleaseAck exactly as with an ordinary eviction.
***************************************************************************************/

package xiangshan.cache

import org.chipsalliance.cde.config.Parameters
import chisel3._
import chisel3.util._
import utility._

class L1QuiesceIO extends Bundle {
  // level: drain L1D (and sweep it, sweep implementation) and keep it blocked (no store, atomic, CMO, miss)
  val req    = Output(Bool())
  // the core reset is asserted or being released: no write into the arrays that survive it
  // (CoreResetKeepL1 only, 0 otherwise)
  val freeze = Output(Bool())
  // L1D has no miss, no release and no store in flight (and is empty with the sweep); high while req is high
  val done   = Input(Bool())
  // the DCache control logic is out of reset (0 while it is held in reset)
  val alive  = Input(Bool())
}

class DCacheFlushUnit(sweep: Boolean)(implicit p: Parameters) extends DCacheModule {
  val io = IO(new Bundle {
    val flush     = Flipped(new L1QuiesceIO)
    // block stores, atomics, CMOs and allocation of new misses (loads still read hits)
    val block     = Output(Bool())
    val mq_empty  = Input(Bool())
    val wbq_empty = Input(Bool())
    // to MainPipe (sweep): flush requests, and a pulse when one leaves s3
    val pipe_req  = DecoupledIO(new MainPipeReq)
    val pipe_resp = Input(Bool())
  })

  val sIdle :: sDrain :: sSweep :: sWait :: sDone :: Nil = Enum(5)
  val state = RegInit(sIdle)

  val set = RegInit(0.U(idxBits.W))
  val way = RegInit(0.U(log2Up(nWays).W))
  // flush requests between MainPipe s0 fire and s3 fire (pipeline depth is 3)
  val inflight = RegInit(0.U(3.W))
  // consecutive cycles of the wait condition, saturating
  val quiet = RegInit(0.U(4.W))

  inflight := inflight + io.pipe_req.fire.asUInt - io.pipe_resp.asUInt

  def countQuiet(cond: Bool): Unit = {
    quiet := Mux(cond, Mux(quiet.andR, quiet, quiet + 1.U), 0.U)
  }

  val idle = io.mq_empty && io.wbq_empty

  switch (state) {
    is (sIdle) {
      quiet := 0.U
      when (io.flush.req) { state := sDrain }
    }
    is (sDrain) {
      // a store or atomic accepted just before the block is at most 3 cycles in MainPipe;
      // a miss or a Release keeps its queue busy until its Grant / ReleaseAck
      countQuiet(idle)
      when (!io.flush.req) {
        state := sIdle
      }.elsewhen (quiet.andR && idle) {
        state := (if (sweep) sSweep else sDone)
        quiet := 0.U
        set := 0.U
        way := 0.U
      }
    }
    is (sSweep) {
      // CoreResetCtrl keeps quiesce.req high until l1.done, so the sweep always runs to its end
      quiet := 0.U
      when (io.pipe_req.fire) {
        set := set + 1.U
        when (set === (nSets - 1).U) {
          set := 0.U
          way := way + 1.U
          when (way === (nWays - 1).U) { state := sWait }
        }
      }
    }
    is (sWait) {
      // the last flush requests leave MainPipe, the last Releases of the sweep get their ReleaseAck
      val swept = inflight === 0.U && idle
      countQuiet(swept)
      when (quiet.andR && swept) { state := sDone }
    }
    is (sDone) {
      when (!io.flush.req) { state := sIdle }
    }
  }
  if (!sweep) {
    assert(state =/= sSweep && state =/= sWait, "DCacheFlushUnit: sweep state in the keep implementation")
  }

  io.block := state =/= sIdle
  io.flush.done := state === sDone

  // 0 while the DCache is held in reset, 1 from the first cycle after it
  val alive = RegInit(false.B)
  alive := true.B
  io.flush.alive := alive

  // flush request: MainPipe reads tag and coherence state of (set, way) and, if the line is valid,
  // releases it (Release / ReleaseData with TtoN or BtoN) and invalidates it in the same s3 cycle
  val r = io.pipe_req.bits
  r := DontCare
  r.miss := false.B
  r.miss_id := 0.U
  r.miss_param := 0.U
  r.miss_dirty := false.B
  r.occupy_way := 0.U
  r.miss_fail_cause_evict_btot := false.B
  r.probe := false.B
  r.probe_param := 0.U
  r.probe_need_data := false.B
  r.source := LOAD_SOURCE.U          // neither a store nor an AMO
  r.cmd := M_XRD
  r.vaddr := Cat(set, 0.U(blockOffBits.W))   // set index (with the alias bits of the VIPT cache), offset 0
  r.addr := 0.U                      // not used: MainPipe builds the line address from the tag it reads in s1
  r.store_data := 0.U
  r.store_mask := 0.U
  r.word_idx := 0.U
  r.amo_data := 0.U
  r.amo_mask := 0.U
  r.amo_cmp := 0.U
  r.error := false.B
  r.replace := false.B
  r.replace_way_en := UIntToOH(way, nWays)
  r.flush := true.B
  r.pf_source := L1_HW_PREFETCH_NULL
  r.access := false.B
  r.id := 0.U
  io.pipe_req.valid := (if (sweep) state === sSweep else false.B)
  // a flush request leaves s3 only after it entered s0
  assert(!(io.pipe_resp && inflight === 0.U), "DCacheFlushUnit: flush response without a flush request in MainPipe")

  XSPerfAccumulate("l1_quiesce", state === sIdle && io.flush.req)
  XSPerfAccumulate("l1_quiesce_cycles", state === sDrain)
  XSPerfAccumulate("l1_sweep_cycles", state === sSweep || state === sWait)
}
