/***************************************************************************************
* Reset of XSCore (core + L1) alone, while L2 and the CHI port of the tile keep running.
* Intended for the Debug Module resets (ndmreset, hartreset) and for a reset controller of the cluster.
*
* The problem is the same as for a reset of the whole tile, one level up: the core and L2 talk
* TileLink, and a reset in the middle of a transaction breaks L2 (an MSHR waits forever for a
* GrantAck / ProbeAck, a half-sent ReleaseData blocks its SinkC, a snoop from the HN is never answered).
* So the boundary is drained first, nothing crosses it while the core is in reset, and every signal that
* leaves the core reset domain is isolated on the tile side while the reset is asserted or released.
*
* One option (SoCParameters.CoreResetKeepL1, with EnableCoreReset) chooses what happens to the lines of L1D:
*   true : L1D keeps its lines across the core reset: their coherence state and error flags are on the
*          tile reset (DCacheWrapper), as is the tag array (its initialisation counter would clear the tags
*          on a core reset); the data SRAMs have no reset at all. Writes into tags and data are masked during
*          the reset (freeze).
*          L2's directory stays valid and L2 takes dirty data from the "hot" L1D with an ordinary Probe. A
*          Probe offered while the core is in reset waits in L2 (channel B held in the gate) until the DCache
*          is out of reset.
*   false: before the reset L1D releases every valid line to L2 (DCache sweep: Release / ReleaseData, the
*          eviction path), so no data is lost and L2's directory records no L1D copy; then L1D is reset
*          together with the core (meta and error flags on the core reset, as without EnableCoreReset). A Probe
*          offered while the core is in reset is answered by the gate with ProbeAck NtoN, the true report of
*          the empty L1D (CoupledL2 does not even send one: its directory lists no L1D copy).
*   Either way only the control logic of the DCache matters at the reset point: it must be idle.
*
* The reset is a level: XSCore stays in reset as long as the request is high, and at least rstCycles
* (CoreResetCtrl, 100 by default: TileLink 1.8.1 section 3.2.2 asks for at least 100 cycles of reset with the
* valid signals low on every link that is reset, the links inside XSCore).
*
* Sequence (CoreResetCtrl), started by a request (level):
*   1. sFlush  : channel A of the non-coherent agents of the core (ICache, PTW, instruction and data MMIO:
*                TL-UL, "early" gates) is closed at once: their requests are of no use after the reset. The
*                DCache blocks stores, atomics, CMOs and new misses and waits until its misses and releases
*                are done (DCacheFlushUnit); without CoreResetKeepL1 it then releases every line. L2 can still
*                probe the DCache. The state is left when the DCache is done and every early gate is quiet:
*                a Get of a non-coherent agent may need a Probe of L1D in CoupledL2 (a line L1D holds in
*                TRUNK / TIP), so channel B must stay open until no such Get is outstanding.
*   2. sDrain  : channel A of L1D is closed, and channel B is closed in the first cycle: Probes are held in L2
*                (the gate drops B ready, and B valid towards the core). The state is left as soon as every
*                gate is quiet, the DCache is done and idle (exact emptiness flags, no waiting time), all in
*                the same cycle; usually that is the first cycle (only a Probe taken in the last cycle of
*                sFlush can still be open: its ProbeAck is on its way through the L1D buffer).
*   3. sReset  : XSCore is reset for at least rstCycles and until the request drops. isolate = 1. Probes are
*                held (keep) or answered NtoN (sweep) in the gate; with keep the L1D arrays that survive the
*                reset are not written.
*   4. sRelease: XSCore leaves reset; channels A and B stay closed (and the core isolated) until the DCache
*                and the frontend are out of reset (the last of the reset chain of the core). Then sIdle: the
*                core runs. A request raised again meanwhile starts a new sequence from sIdle.
* hartInReset (for the Debug Module) is high from the core reset until the core runs again.
*
* Reset domain crossing: the assertion of the core reset is asynchronous (ResetGen synchronises only its
* release), so the outputs of the core change at no particular clock edge. Every signal from the core reset
* domain to the tile reset domain is therefore isolated by isolate (CoreResetCtrl register, sReset and
* sRelease): valid signals are masked, levels are held, in the gates (TileLink), in TLResetIsolation (the
* ICache control registers, where the core is the manager), in XSTile (everything else) and, with
* CoreResetKeepL1, by freeze at the arrays of L1D that survive the reset.
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
  val ackB    = Input(Bool())   // answer Probes here with ProbeAck NtoN, the core sees none (it holds no line)
  // XSCore reset asserted or being released (a register of CoreResetCtrl): every signal that comes from the
  // core reset domain (A, C, E valid, D ready; B ready through holdB / ackB, which are high then) is ignored,
  // nothing is offered to the core. The outputs of the core change asynchronously when its reset is asserted;
  // this keeps them away from L2 and from the counters below (reset domain crossing isolation).
  val isolate = Input(Bool())
  // nothing outstanding across the boundary, no message in transfer (a Probe offered by L2 but not taken
  // does not count: it is held or answered by the gate)
  val quiet   = Output(Bool())
}

/** TileLink adapter on one client edge (core side -> L2Top side). Pass-through, except that
  * channel A can be blocked, Probes on channel B can be held or answered by the gate itself, every
  * transaction crossing it is tracked, and the core side is isolated while XSCore is in reset.
  * Together with CoreResetCtrl and the DCache drain this is the TileLink-to-TileLink adapter of TileLink
  * 1.8.1 section 3.2.3 that lets one side of the link be reset separately: the L2 side never sees the reset.
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
    // releases lines and answers Probes then
    require(!(outer.early && hasBCE), s"TLQuiesceGate($gname): an early gate must be on a TL-UL edge")

    out.a <> in.a
    in.d <> out.d
    if (hasBCE) {
      in.b <> out.b
      out.c <> in.c
      out.e <> in.e
      // isolation of C and E: C and E valid of the core are not looked at (a ProbeAck of the gate itself is
      // still sent, below). B needs nothing more: whenever isolate is high, holdB (keep) or ackB (sweep) is high
      // too and closes B (no Probe to the core, its B ready is not looked at; asserted below).
      when (io.isolate) {
        in.c.ready := false.B
        out.c.valid := false.B
        in.e.ready := false.B
        out.e.valid := false.B
      }
      // holdB: a Probe waits in L2 (Probe is a single-beat message). B ready to L2 and B valid to the core
      // drop in the cycle holdB rises: a Probe offered but not taken may be withdrawn from the core
      // (TileLink 1.8.1 section 4.1: valid may fall while the beat has not been accepted), L2 keeps offering it
      when (io.holdB) {
        in.b.valid := false.B
        out.b.ready := false.B
      }
      // ackB: the gate takes the Probe and answers it on behalf of the core: ProbeAck NtoN, the report of a
      // client that holds no copy (CoreResetKeepL1 = false: L1D released every line before the reset and is
      // reset with the core). One Probe at a time; C from the core stays closed meanwhile (it is isolated
      // while the core is in reset, and the core has nothing to send on C then).
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
  * the MMIO crossbar of L2Top). While XSCore is in reset or being released (isolate) no request is offered to
  * it and none of its signals (A ready, D valid) reaches the tile side. Only the core's own MMIO reaches
  * these registers (the i_mmio / d_mmio gates drain it), so nothing is in flight across this edge at the
  * reset point; quiet tells so to CoreResetCtrl like a gate does. TL-UL edges only. */
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
      out.a.valid := false.B   // no request into the core while it is in reset (it would be lost)
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
    assert(!(io.isolate && reqs =/= 0.U), "TLResetIsolation: request in flight while XSCore is in reset")
    reqs === 0.U && aFirst
  }
  io.quiet := quiets.foldLeft(true.B)(_ && _)
}

class CoreResetCtrlIO extends Bundle {
  val req         = Input(Bool())   // level, tile clock: reset XSCore; it is held in reset while high
  val busy        = Output(Bool())  // a core reset sequence is in progress
  val inReset     = Output(Bool())  // XSCore reset is asserted
  val hartInReset = Output(Bool())  // from the core reset until the core runs again (Debug Module)
  val l1          = new xiangshan.cache.L1QuiesceIO
  // reset of the frontend, the last of the reset chain of XSCore (core reset domain; looked at in sRelease)
  val coreInReset = Input(Bool())
  val earlyBlock  = Output(Bool())  // channel A of the non-coherent agents closed (from sFlush)
  val gateBlock   = Output(Bool())  // channel A of L1D closed (from sDrain)
  val holdProbe   = Output(Bool())  // channel B held in L2 (sDrain; and in sReset, sRelease with CoreResetKeepL1)
  val ackProbe    = Output(Bool())  // Probes answered NtoN by the gate (CoreResetKeepL1 = false: L1D swept)
  // XSCore reset asserted or being released (sReset, sRelease): every signal that leaves the core reset
  // domain must be isolated on the tile side (gates, XSTile). A register, glitch-free; it rises on the same
  // clock edge as coreReset, so the first edge that could sample an output of the core changed by the
  // (asynchronous) reset assertion already sees the isolation.
  val isolate     = Output(Bool())
  val earlyQuiet  = Input(Bool())   // every gate of a non-coherent agent is quiet
  val gatesQuiet  = Input(Bool())   // every gate and every TLResetIsolation is quiet
  val coreReset   = Output(Bool())  // to XSCore reset (synchronised by the tile)
}

/** Sequencer of the core-only reset (tile clock, tile reset).
  * keepL1 = CoreResetKeepL1: L1D keeps its lines (Probes are held while the core is in reset), or it releases
  *          every line first (DCache sweep in sFlush) and is reset with the core (Probes are answered NtoN by
  *          the gate meanwhile: L1D holds nothing, L2's directory records nothing for it).
  * rstCycles: minimum length of the core reset. TileLink 1.8.1 section 3.2.2 asks for at least 100 cycles of
  *          reset with the valid signals low, for every link of the reset part (the links inside XSCore).
  *          The core stays in reset as long as the request is high, but never shorter than that. */
class CoreResetCtrl(keepL1: Boolean, rstCycles: Int = 100) extends Module {
  val io = IO(new CoreResetCtrlIO)

  val sIdle :: sFlush :: sDrain :: sReset :: sRelease :: Nil = Enum(5)
  val state = RegInit(sIdle)
  val cnt = RegInit(0.U(8.W))
  require(rstCycles >= 100 && rstCycles < 255, "TileLink 1.8.1, 3.2.2: at least 100 cycles of reset")

  val coreReset = RegInit(false.B)
  val hartInReset = RegInit(false.B)
  // sReset or sRelease, as a register (see CoreResetCtrlIO.isolate)
  val closed = RegInit(false.B)

  // the inputs from the DCache and the frontend come from the core reset domain: done and idle are used only
  // while the core runs (sFlush, sDrain), alive and the frontend reset only when the core leaves reset
  // (sRelease, the release is synchronous); in sReset, when the core reset is asserted asynchronously, none
  // of them reaches the state machine
  val l1Done = io.l1.done && !closed
  val l1Idle = io.l1.idle && !closed
  val coreUp = io.l1.alive && !io.coreInReset && state === sRelease

  switch (state) {
    is (sIdle) {
      cnt := 0.U
      when (io.req) { state := sFlush }
    }
    is (sFlush) {
      // channel A of the non-coherent agents is closed (earlyBlock); DCache drain (and sweep, without keepL1);
      // L2 may still probe the DCache. A Get of a non-coherent agent may wait in L2 for a Probe of L1D, so B
      // stays open until every early gate is quiet.
      when (l1Done && io.earlyQuiet) { state := sDrain }
    }
    is (sDrain) {
      // channel A of L1D closed, B closed from the first cycle (holdProbe). The decision looks at quiet of this
      // cycle (the counters already include a Probe taken in the last cycle of sFlush), so nothing that
      // crossed a gate before can be lost.
      // The emptiness flags do not cover the one registered write stage of the L1D data and meta arrays
      // (BankedDataArray, AsynchronousMetaArray): a write of an s3 fire in the previous cycle is committed
      // into the array at the edge that ends this cycle, the same edge at which coreReset rises, so it lands
      // before the asynchronous reset assertion. No delay may be added between this decision and coreReset.
      when (io.gatesQuiet && l1Done && l1Idle) {
        state := sReset; cnt := 0.U; coreReset := true.B; hartInReset := true.B; closed := true.B
      }
    }
    is (sReset) {
      // at least rstCycles, and until the request drops (Probes held or answered by the gate meanwhile)
      when (cnt < rstCycles.U) { cnt := cnt + 1.U }
      when (cnt >= rstCycles.U && !io.req) { state := sRelease; coreReset := false.B }
    }
    is (sRelease) {
      // the core leaves reset through its reset synchronisers; channels A and B stay closed (and the core
      // isolated) until the DCache (with keepL1 it takes the held Probes) and the frontend are out of reset
      when (coreUp) {
        state := sIdle; closed := false.B; hartInReset := false.B
      }
    }
  }

  // nothing may cross the core/L2 boundary while XSCore is in reset (a message would be lost and
  // L2 would wait for its answer forever); a Probe may be offered, it is held or answered by the gate
  assert(!(state === sReset && !io.gatesQuiet),
    "CoreResetCtrl: TileLink traffic between XSCore and L2 while XSCore is in reset")
  // the isolation covers the whole time the core reset is asserted
  assert(closed === (state === sReset || state === sRelease), "CoreResetCtrl: isolation out of step with the state")
  assert(!coreReset || closed, "CoreResetCtrl: XSCore reset without isolation")

  io.busy := state =/= sIdle
  io.inReset := state === sReset
  io.hartInReset := hartInReset
  // keep the DCache drained and blocked until the core is reset
  io.l1.req := state === sFlush || state === sDrain
  io.l1.freeze := (if (keepL1) closed else false.B)
  // channel A: the non-coherent agents from the start, L1D from sDrain (it releases lines in sFlush)
  io.earlyBlock := state =/= sIdle
  io.gateBlock := state === sDrain || closed
  // channel B, a function of the state register: closed in the first cycle of sDrain. With keepL1 the Probe
  // waits in L2 until the DCache is out of reset (L1D holds the line, maybe dirty); without it the gate answers
  // NtoN while the core is in reset (L1D released everything before), and holds it in sDrain (the DCache is
  // still there, but no new Probe may reach it any more)
  io.holdProbe := (if (keepL1) state === sDrain || closed else state === sDrain)
  io.ackProbe := (if (keepL1) false.B else closed)
  io.isolate := closed
  io.coreReset := coreReset
}
