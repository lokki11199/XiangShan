/***************************************************************************************
* Copyright (c) 2020-2021 Institute of Computing Technology, Chinese Academy of Sciences
* Copyright (c) 2020-2021 Peng Cheng Laboratory
*
* XiangShan is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

/***************************************************************************************
* Reset of XSCore (core + L1) alone, while L2 and the CHI port of the tile keep running.
* Intended for the Debug Module resets (ndmreset, hartreset) and for a reset controller of the cluster.
*
* The problem is the same as for a reset of the whole tile, one level up: the core and L2 talk
* TileLink, and a reset in the middle of a transaction breaks L2 (an MSHR waits forever for a
* GrantAck / ProbeAck, a half-sent ReleaseData blocks its SinkC, a snoop from the HN is never answered).
* So the boundary is drained first, nothing crosses it while the core is in reset, and every signal that
* leaves the core reset domain is isolated on the tile side before the reset is asserted and until it is
* released. No line of L1D is walked or written back: the DCache is only emptied of transactions.
*
* One option (SoCParameters.CoreResetKeepL1, with EnableCoreReset) chooses what the reset does to L1D:
*   false (FULL, default): L1D is reset with the core and is empty afterwards. Dirty lines are lost and L2's
*          directory is stale (a line L2 lists for L1D is not there). A Probe offered while the core is in
*          reset is answered by the gate in front of L1D with ProbeAck NtoN, which is what the reset L1D would
*          answer. The protocol cost of this is described in core-reset/DESIGN.md section 7.2.
*   true  (KEEP): L1D keeps its lines. Coherence meta, error flags and the tag array (its initialisation counter
*          would clear the tags on a core reset) are on the tile reset, the data SRAMs have no reset. None of
*          these arrays is written or read by the core while it is isolated (freeze). L2's directory stays
*          valid. A Probe offered while the core is in reset waits in L2 (channel B held in the gate) until the
*          DCache is out of reset.
*   Either way only the control logic of the DCache matters at the reset point: it must be idle.
*
* The reset is a level: XSCore stays in reset as long as the request is high, and at least rstCycles
* (CoreResetCtrl, 100 by default: TileLink section 3.2.2 asks for at least 100 cycles of reset with the
* valid signals low on every link that is reset, the links inside XSCore).
*
* Sequence (CoreResetCtrl), started by a request (level, never cancelled):
*   1. sQuiesce: channel A of the non-coherent agents of the core (ICache, PTW, instruction and data MMIO:
*                TL-UL, "early" gates) is closed at once: their requests are of no use after the reset. The
*                DCache blocks stores, atomics, CMOs and new misses and waits until its misses and releases
*                are done (DCacheQuiesceUnit). L2 can still probe the DCache. The state is left when the DCache
*                is done and every early gate is quiet: a Get of a non-coherent agent may need a Probe of L1D
*                in CoupledL2 (a line L1D holds in TRUNK / TIP), so channel B must stay open until no such
*                Get is outstanding.
*   2. sDrain  : channel A of L1D is closed, and channel B is closed in the first cycle: Probes are held in L2.
*                The state is left as soon as every gate is quiet, the DCache is done and idle (exact emptiness
*                flags, no waiting time), all in the same cycle.
*   3. sIso    : isolation (and freeze with KEEP) is on, the reset is not yet: the core is alive but cannot be
*                seen from outside. Lasts isoCycles >= 1 cycles, so every clamp is in place a full cycle before
*                the outputs of the core can change asynchronously.
*   4. sReset  : XSCore is reset for at least rstCycles and until the request drops. Probes are held (KEEP) or
*                answered NtoN by the gate (FULL).
*   5. sRelease: XSCore leaves reset through its ResetGen chain; the isolation stays until the DCache and the
*                frontend (the last of the chain) are out of reset. Then sIdle, or sQuiesce at once if the
*                request is high again (busy does not drop in between).
* hartInReset (for the Debug Module) is busy: high from the first cycle of the sequence.
*
* Reset domain crossing (RDC): the assertion of the core reset is asynchronous (ResetGen synchronises only its
* release). Rules, with isolate / releasing registers of the tile reset domain as the only qualifiers (a decode
* of the multi-bit state may glitch):
*   R1 every path from the core reset domain into the tile reset domain (or into logic without reset) goes
*      through a clamp qualified by isolate: the gates and TLResetIsolation (TileLink), XSTile (all other
*      signals), freeze at the arrays of L1D that survive the reset (KEEP);
*   R3 isolate is high at least isoCycles full cycles before coreReset rises (asserted below);
*   R4 isolate falls no earlier than a full cycle after the DCache and the frontend left reset.
***************************************************************************************/

package xiangshan

import org.chipsalliance.cde.config.Parameters
import chisel3._
import chisel3.util._
import freechips.rocketchip.diplomacy.{LazyModule, LazyModuleImp}
import freechips.rocketchip.tilelink._
import freechips.rocketchip.tilelink.TLMessages._

class QuiesceGateIO extends Bundle {
  val block   = Input(Bool())   // stop new requests on channel A (only between messages)
  val holdB   = Input(Bool())   // hold Probes in L2: B is neither accepted from L2 nor offered to the core
  val ackB    = Input(Bool())   // answer Probes here with ProbeAck NtoN: what the L1D reset with the core would answer
  // XSCore isolated (a register of CoreResetCtrl, high from sIso to the end of sRelease): every signal that
  // comes from the core reset domain (A, C, E valid, B and D ready) is ignored, nothing is offered to the
  // core. The outputs of the core change asynchronously when its reset is asserted; this keeps them away from
  // L2 and from the counters below.
  val isolate = Input(Bool())
  // nothing outstanding across the boundary, no message in transfer (a Probe offered by L2 but not taken
  // does not count: it is held or answered by the gate)
  val quiet   = Output(Bool())
}

/** TileLink adapter on one client edge (core side -> L2Top side). Pass-through, except that
  * channel A can be blocked, Probes on channel B can be held or answered by the gate itself, every
  * transaction crossing it is tracked, and the core side is isolated while XSCore is isolated.
  * Together with CoreResetCtrl and the DCache drain this is the TileLink-to-TileLink adapter of TileLink
  * section 3.2.3 that lets one side of the link be reset separately: the L2 side never sees the reset.
  * early: the gate of a non-coherent agent (TL-UL edge), its channel A is closed from the start of the
  *        sequence (CoreResetCtrl.earlyBlock); otherwise from sDrain (CoreResetCtrl.gateBlock). */
class TLQuiesceGate(val gateName: String, val early: Boolean)(implicit p: Parameters) extends LazyModule {
  val node = TLAdapterNode()
  lazy val module = new TLQuiesceGateImp(this)
}

class TLQuiesceGateImp(outer: TLQuiesceGate) extends LazyModuleImp(outer) {
  val io = IO(new QuiesceGateIO)
  private val gname = outer.gateName

  val quiets = (outer.node.in zip outer.node.out).map { case ((in, edgeIn), (out, edgeOut)) =>
    val hasBCE = edgeOut.manager.anySupportAcquireB && edgeOut.client.anySupportProbe
    // a request of a coherent agent cannot simply be stopped at the start of the sequence: the DCache still
    // answers Probes then
    require(!(outer.early && hasBCE), s"TLQuiesceGate($gname): an early gate must be on a TL-UL edge")

    out.a <> in.a
    in.d <> out.d
    if (hasBCE) {
      in.b <> out.b
      out.c <> in.c
      out.e <> in.e
      // isolation of B, C and E, from a register (a qualifier of the reset domain crossing): the core's C and E
      // valid and B ready are not looked at, no Probe is offered to the core. A ProbeAck of the gate itself is
      // still sent, below. out.b.ready is then 0 or takeB, never a function of the core.
      when (io.isolate) {
        in.c.ready := false.B
        out.c.valid := false.B
        in.e.ready := false.B
        out.e.valid := false.B
        in.b.valid := false.B
        out.b.ready := false.B
      }
      // holdB: a Probe waits in L2 (Probe is a single-beat message). B ready to L2 and B valid to the core
      // drop in the cycle holdB rises: a Probe offered but not taken may be withdrawn from the core
      // (TileLink section 4.1: valid may fall while the beat has not been accepted), L2 keeps offering it
      when (io.holdB) {
        in.b.valid := false.B
        out.b.ready := false.B
      }
      // ackB: the gate takes the Probe and answers it on behalf of the core: ProbeAck NtoN. L1D is reset with
      // the core and returns no line, NtoN is what the reset L1D would answer; L2's directory is stale until
      // this answer. One Probe at a time; C from the core stays closed meanwhile (it is isolated while the
      // core is in reset, and has nothing to send on C then).
      val ackPending = RegInit(false.B)
      val ackProbe   = Reg(new TLBundleB(edgeOut.bundle))
      val takeB      = io.ackB && !io.holdB && !ackPending
      when (io.ackB || ackPending) {
        in.b.valid := false.B
        out.b.ready := takeB
      }
      when (out.b.fire && takeB) {
        ackPending := true.B
        ackProbe := out.b.bits
      }
      when (ackPending) {
        out.c.valid := true.B
        out.c.bits := edgeOut.ProbeAck(ackProbe, TLPermissions.NtoN)
        in.c.ready := false.B
        when (out.c.ready) { ackPending := false.B }
      }
      assert(!(io.ackB && io.holdB), s"TLQuiesceGate($gname): Probes both held and answered")
      assert(!io.isolate || io.holdB || io.ackB, s"TLQuiesceGate($gname): channel B open while XSCore is isolated")
    } else {
      in.b.valid := false.B
      in.c.ready := true.B
      in.e.ready := true.B
      out.b.ready := true.B
      out.c.valid := false.B
      out.e.valid := false.B
    }

    // message boundaries (each firstlast call instantiates one beat counter per channel)
    val (aFirst, _, _)     = edgeIn.firstlast(in.a)
    val (dFirst, dLast, _) = edgeIn.firstlast(in.d)

    // block A only at a message boundary, so a multi-beat Put is never cut
    when (io.block && aFirst) {
      out.a.valid := false.B
      in.a.ready := false.B
    }
    // isolation of A and D (the drain left nothing in flight: no A message is cut, no D is pending)
    when (io.isolate) {
      out.a.valid := false.B
      in.a.ready := false.B
      in.d.valid := false.B
      out.d.ready := false.B
    }

    def counter(inc: Bool, dec: Bool, what: String): UInt = {
      val c = RegInit(0.U(8.W))
      c := c + inc.asUInt - dec.asUInt
      assert(!(dec && !inc && c === 0.U), s"TLQuiesceGate($gname): $what underflow")
      assert(!(inc && !dec && c.andR), s"TLQuiesceGate($gname): $what overflow")
      c
    }

    val dIsReleaseAck = in.d.bits.opcode === ReleaseAck
    val dIsGrant      = in.d.bits.opcode === Grant || in.d.bits.opcode === GrantData

    // every request on A gets exactly one response message on D
    val reqs = counter(in.a.fire && aFirst, in.d.fire && dLast && !dIsReleaseAck, "A->D")

    val quietBCE = if (hasBCE) {
      val (cFirst, cLast, _) = edgeIn.firstlast(in.c)
      val cIsProbeAck = in.c.bits.opcode === ProbeAck || in.c.bits.opcode === ProbeAckData
      val cIsRelease  = in.c.bits.opcode === Release || in.c.bits.opcode === ReleaseData
      // Grant -> GrantAck, Probe -> ProbeAck, Release -> ReleaseAck. The counters see the messages where they
      // cross the gate, so a message still in the L1D buffer (l1d_to_l2_buffer, between the DCache and the
      // gate) is covered too: a ProbeAck on its way keeps probes above 0, a GrantAck keeps grants above 0.
      val grants   = counter(in.d.fire && dFirst && dIsGrant, in.e.fire, "Grant->GrantAck")
      val probes   = counter(in.b.fire && in.b.bits.opcode === Probe, in.c.fire && cLast && cIsProbeAck, "Probe->ProbeAck")
      val releases = counter(in.c.fire && cLast && cIsRelease, in.d.fire && dIsReleaseAck, "Release->ReleaseAck")
      grants === 0.U && probes === 0.U && releases === 0.U && cFirst
    } else {
      true.B
    }

    reqs === 0.U && aFirst && dFirst && quietBCE
  }
  io.quiet := quiets.reduce(_ && _)
}

/** TileLink adapter on an edge whose manager is inside XSCore (the ICache control registers, reached through
  * the MMIO crossbar of L2Top). While XSCore is isolated no request is offered to it and none of its signals
  * (A ready, D valid) reaches the tile side. Only the core's own MMIO reaches these registers (the i_mmio /
  * d_mmio gates drain it), so nothing is in flight across this edge at the reset point; quiet tells so to
  * CoreResetCtrl like a gate does. TL-UL edges only. */
class TLResetIsolation(implicit p: Parameters) extends LazyModule {
  val node = TLAdapterNode()
  lazy val module = new TLResetIsolationImp(this)
}

class TLResetIsolationImp(outer: TLResetIsolation) extends LazyModuleImp(outer) {
  val io = IO(new Bundle {
    val isolate = Input(Bool())
    val quiet   = Output(Bool())   // no request to the core is waiting for its response
  })
  val quiets = (outer.node.in zip outer.node.out).map { case ((in, edgeIn), (out, edgeOut)) =>
    require(!(edgeOut.manager.anySupportAcquireB && edgeOut.client.anySupportProbe),
      "TLResetIsolation: TL-UL edges only")
    out.a <> in.a
    in.d <> out.d
    in.b.valid := false.B
    in.c.ready := true.B
    in.e.ready := true.B
    out.b.ready := true.B
    out.c.valid := false.B
    out.e.valid := false.B
    when (io.isolate) {
      out.a.valid := false.B   // no request into the core while it is isolated (it would be lost)
      in.a.ready := false.B    // the ready of the core is not looked at
      in.d.valid := false.B    // nor its responses
      out.d.ready := false.B
    }
    // requests on A (first beat) and their responses on D (last beat), seen on the tile side
    val (aFirst, _, _) = edgeIn.firstlast(in.a)
    val (_, dLast, _)  = edgeIn.firstlast(in.d)
    val reqs = RegInit(0.U(8.W))
    reqs := reqs + (in.a.fire && aFirst).asUInt - (in.d.fire && dLast).asUInt
    assert(!(in.d.fire && dLast && !(in.a.fire && aFirst) && reqs === 0.U), "TLResetIsolation: A->D underflow")
    assert(!(io.isolate && reqs =/= 0.U), "TLResetIsolation: request in flight while XSCore is isolated")
    reqs === 0.U && aFirst
  }
  io.quiet := quiets.foldLeft(true.B)(_ && _)
}

class CoreResetCtrlIO extends Bundle {
  val req         = Input(Bool())   // level, tile clock: reset XSCore; it is held in reset while high
  val busy        = Output(Bool())  // a core reset sequence is in progress (from its first cycle to its last)
  val inReset     = Output(Bool())  // the reset of XSCore is asserted (sReset only; the core leaves reset later)
  val hartInReset = Output(Bool())  // = busy (Debug Module)
  val l1          = new xiangshan.cache.L1QuiesceIO
  // reset of the frontend, the last of the reset chain of XSCore (core reset domain; looked at in sRelease only)
  val coreInReset = Input(Bool())
  val earlyBlock  = Output(Bool())  // channel A of the non-coherent agents closed (from sQuiesce)
  val gateBlock   = Output(Bool())  // channel A of L1D closed (from sDrain)
  val holdProbe   = Output(Bool())  // channel B held in L2 (sDrain, sIso; with KEEP also sReset, sRelease)
  val ackProbe    = Output(Bool())  // Probes answered NtoN by the gate (FULL: sReset, sRelease)
  // XSCore isolated (sIso, sReset, sRelease): every signal that leaves the core reset domain must be clamped on
  // the tile side (gates, XSTile). A register, glitch-free; it rises at least isoCycles full cycles before
  // the core reset is asserted and falls a full cycle after the core is out of reset.
  val isolate     = Output(Bool())
  val earlyQuiet  = Input(Bool())   // every gate of a non-coherent agent is quiet
  val gatesQuiet  = Input(Bool())   // every gate and every TLResetIsolation is quiet
  val coreReset   = Output(Bool())  // to XSCore reset (synchronised by the tile)
}

/** Sequencer of the core-only reset (tile clock, tile reset).
  * keepL1 = CoreResetKeepL1: L1D keeps its lines (Probes are held while the core is in reset, freeze at the
  *          arrays), or it is reset with the core (Probes are answered NtoN by the gate meanwhile).
  * rstCycles: minimum length of the core reset. TileLink section 3.2.2 asks for at least 100 cycles of
  *          reset with the valid signals low, for every link of the reset part (the links inside XSCore).
  *          The core stays in reset as long as the request is high, but never shorter than that.
  * isoCycles: how many cycles isolation leads the core reset (one is enough for every clamp to be in place;
  *          with KEEP at most two, see DCacheImp: the load pipes run on while the array reads are frozen). */
class CoreResetCtrl(keepL1: Boolean, rstCycles: Int = 100, isoCycles: Int = 1) extends Module {
  val io = IO(new CoreResetCtrlIO)

  require(rstCycles >= 100 && rstCycles < 255, "TileLink 3.2.2: at least 100 cycles of reset")
  require(isoCycles >= 1 && isoCycles <= 16, "isolation must lead the core reset by at least one cycle")
  require(!keepL1 || isoCycles <= 2, "KEEP: load pipes run on with the array reads frozen, at most two cycles")

  val sIdle :: sQuiesce :: sDrain :: sIso :: sReset :: sRelease :: Nil = Enum(6)
  val state = RegInit(sIdle)
  val cnt = RegInit(0.U(8.W))

  // registers of the tile reset domain: the qualifiers of every signal that comes from the core reset domain
  val busy      = RegInit(false.B)   // the whole sequence, including the cycles between two sequences in a row
  val isolate   = RegInit(false.B)   // sIso, sReset, sRelease
  val coreReset = RegInit(false.B)   // sReset
  val releasing = RegInit(false.B)   // sRelease

  // the inputs from the DCache and the frontend come from the core reset domain: done and idle are used only
  // while the core runs (sQuiesce, sDrain), alive and the frontend reset only when the core leaves reset
  // (sRelease, the release is synchronous); while the core reset is asserted none of them reaches the state
  // machine
  val l1Done = io.l1.done && !isolate
  val l1Idle = io.l1.idle && !isolate
  val coreUp = releasing && io.l1.alive && !io.coreInReset

  switch (state) {
    is (sIdle) {
      when (io.req) { state := sQuiesce; busy := true.B }
    }
    is (sQuiesce) {
      // channel A of the non-coherent agents is closed (earlyBlock); DCache drain; L2 may still probe the
      // DCache. A Get of a non-coherent agent may wait in L2 for a Probe of L1D, so B stays open until every
      // early gate is quiet.
      when (l1Done && io.earlyQuiet) { state := sDrain }
    }
    is (sDrain) {
      // channel A of L1D closed, B closed from the first cycle (holdProbe). The decision looks at quiet of this
      // cycle (the counters already include a Probe taken in the last cycle of sQuiesce), so nothing that
      // crossed a gate before can be lost.
      // The emptiness flags do not cover the one registered write stage of the L1D data and meta arrays
      // (BankedDataArray, AsynchronousMetaArray): a write of an s3 fire in the previous cycle is committed into
      // the array at the edge that ends this cycle, and freeze (KEEP) rises at that edge, not before. The
      // core reset is at least isoCycles cycles later, so that write lands before it.
      when (io.gatesQuiet && l1Done && l1Idle) { state := sIso; isolate := true.B; cnt := 0.U }
    }
    is (sIso) {
      // isolation and freeze are on, the core reset is not. l1.req stays high: otherwise the DCache would
      // unblock and a store of the sbuffer could enter MainPipe a cycle before the reset.
      cnt := cnt + 1.U
      when (cnt === (isoCycles - 1).U) { state := sReset; coreReset := true.B; cnt := 0.U }
    }
    is (sReset) {
      // at least rstCycles, and until the request drops (Probes held or answered by the gate meanwhile)
      when (cnt < rstCycles.U) { cnt := cnt + 1.U }
      when (cnt >= rstCycles.U && !io.req) { state := sRelease; coreReset := false.B; releasing := true.B }
    }
    is (sRelease) {
      // the core leaves reset through its reset synchronisers; the isolation stays until the DCache (with
      // KEEP it takes the held Probes then) and the frontend are out of reset. A request that came meanwhile
      // starts the next sequence at once, busy does not drop.
      when (coreUp) {
        isolate := false.B
        releasing := false.B
        when (io.req) { state := sQuiesce } .otherwise { state := sIdle; busy := false.B }
      }
    }
  }

  // the registers follow the state
  assert(busy === (state =/= sIdle), "CoreResetCtrl: busy out of step with the state")
  assert(isolate === (state === sIso || state === sReset || state === sRelease), "CoreResetCtrl: isolate out of step with the state")
  assert(coreReset === (state === sReset), "CoreResetCtrl: coreReset out of step with the state")
  assert(releasing === (state === sRelease), "CoreResetCtrl: releasing out of step with the state")
  // the isolation leads the core reset
  assert(!coreReset || RegNext(isolate, false.B), "CoreResetCtrl: XSCore reset without an isolation lead")
  // nothing may cross the core/L2 boundary while XSCore is isolated (a message would be lost and L2 would
  // wait for its answer forever); a Probe may be offered, it is held or answered by the gate
  assert(!isolate || io.gatesQuiet, "CoreResetCtrl: TileLink traffic between XSCore and L2 while XSCore is isolated")
  // the isolation falls only at the end of sRelease
  assert(!(RegNext(isolate, false.B) && !isolate) || RegNext(releasing && !coreReset, false.B),
    "CoreResetCtrl: isolation dropped outside sRelease")

  io.busy := busy
  io.inReset := coreReset
  io.hartInReset := busy
  // keep the DCache drained and blocked until the core is reset (sIso included, see there)
  io.l1.req := state === sQuiesce || state === sDrain || state === sIso
  io.l1.freeze := (if (keepL1) isolate else false.B)
  // channel A: the non-coherent agents from the start, L1D from sDrain
  io.earlyBlock := busy
  io.gateBlock := state === sDrain || isolate
  // channel B, a function of the state register: closed in the first cycle of sDrain. In sDrain and sIso the
  // DCache is still there and holds its lines, so the Probe waits in L2 in both modes. While the core is in
  // reset: with KEEP L1D holds its lines (maybe dirty), the Probe waits until the DCache is out of reset;
  // FULL: L1D is reset with the core and returns nothing, the gate answers NtoN.
  io.holdProbe := (if (keepL1) state === sDrain || isolate else state === sDrain || state === sIso)
  io.ackProbe := (if (keepL1) false.B else state === sReset || state === sRelease)
  io.isolate := isolate
  io.coreReset := coreReset
}
