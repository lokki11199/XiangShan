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

package xiangshan

import org.chipsalliance.cde.config.{Config, Parameters}
import chisel3._
import chisel3.util.{RegEnable, Valid, ValidIO, log2Up}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.interrupts._
import freechips.rocketchip.tile.{BusErrorUnit, BusErrorUnitParams, BusErrors}
import freechips.rocketchip.tilelink._
import freechips.rocketchip.amba.axi4._
import freechips.rocketchip.util.AsyncResetSynchronizerShiftReg
import system.HasSoCParameter
import top.{ArgParser, BusPerfMonitor, Generator}
import utility._
import utility.sram.SramBroadcastBundle
import coupledL2.{EnableCHI, L2ParamKey, PrefetchRecv}
import coupledL2.tl2chi.{PortIO, LCrdyIn}
import xiangshan.backend.fu.PMPRespBundle
import xiangshan.backend.trace.TraceCoreInterface

class XSTile()(implicit p: Parameters) extends LazyModule
  with HasXSParameter
  with HasSoCParameter
{
  override def shouldBeInlined: Boolean = false
  val core = LazyModule(new XSCore())
  val l2top = LazyModule(new L2Top())

  val enableL2 = coreParams.L2CacheParamsOpt.isDefined
  val txSourceReady = p(L2ParamKey).txSourceReady
// =========== Public Ports ============
  val memBlock = core.memBlock.inner
  // L1 prefetch requests to L3. With EnableCoreReset the bridge is cut in two (a sink and a source), so that
  // XSTileImp can isolate it from the core reset domain
  val l3_pf_iso = if (EnableCoreReset) memBlock.l3_pf_sender_opt.map { src =>
    val l3_pf_from_core = BundleBridgeSink(Some(() => new huancun.PrefetchRecv))
    val l3_pf_to_l3 = BundleBridgeSource(() => new huancun.PrefetchRecv)
    l3_pf_from_core := src
    (l3_pf_from_core, l3_pf_to_l3)
  } else None
  val core_l3_pf_port = if (EnableCoreReset) l3_pf_iso.map(_._2) else memBlock.l3_pf_sender_opt
  val memory_port = if (enableCHI && enableL2) None else Some(l2top.inner.memory_port.get)
  val tl_uncache = l2top.inner.mmio_port
  val sep_tl_opt = l2top.inner.sep_tl_port_opt
  val beu_int_source = l2top.inner.beu.intNode
  val core_reset_sink = BundleBridgeSink(Some(() => Reset()))
  val clint_int_node = l2top.inner.clint_int_node
  val plic_int_node = l2top.inner.plic_int_node
  val debug_int_node = l2top.inner.debug_int_node
  val nmi_int_node = l2top.inner.nmi_int_node
  memBlock.clint_int_sink := IntBuffer() := clint_int_node
  memBlock.plic_int_sink :*= IntBuffer() :*= plic_int_node
  memBlock.debug_int_sink := IntBuffer() := debug_int_node
  memBlock.nmi_int_sink   := IntBuffer() := nmi_int_node
  memBlock.beu_local_int_sink := l2top.inner.beu_local_int_source_buffer

  // =========== Core-only reset (EnableCoreReset) ============
  // One TLQuiesceGate on every TileLink edge from XSCore to L2Top: it can stop channel A, hold channel B
  // (Probes) or answer them itself (NtoN), isolates the core side while XSCore is isolated, and tells when
  // no transaction is outstanding across the core/L2 boundary (see CoreReset.scala). Both helpers are
  // called only with EnableCoreReset, otherwise the edges are connected as upstream.
  // early: a non-coherent agent (TL-UL), its channel A is closed from the start of the sequence (sQuiesce);
  // the coherent L1D keeps A open until sDrain (it answers Probes in sQuiesce)
  val coreGates = scala.collection.mutable.ListBuffer[TLQuiesceGate]()
  private def coreGate(name: String, early: Boolean) = {
    val g = LazyModule(new TLQuiesceGate(name, early))
    coreGates += g
    g.node
  }
  // One TLResetIsolation on every TileLink edge from L2Top to a manager inside XSCore (ICache control).
  val coreIsolations = scala.collection.mutable.ListBuffer[TLResetIsolation]()
  private def coreIsolation() = {
    val i = LazyModule(new TLResetIsolation)
    coreIsolations += i
    i.node
  }

  // =========== Components' Connection ============
  // L1 to l1_xbar
  coreParams.dcacheParametersOpt.map { _ =>
    if (EnableCoreReset) {
      l2top.inner.misc_l2_pmu := l2top.inner.l1d_logger := coreGate("l1d", early = false) := memBlock.dcache_port :=
        memBlock.l1d_to_l2_buffer.node := memBlock.dcache.clientNode
    } else {
      l2top.inner.misc_l2_pmu := l2top.inner.l1d_logger := memBlock.dcache_port :=
        memBlock.l1d_to_l2_buffer.node := memBlock.dcache.clientNode
    }
  }

  if (EnableCoreReset) {
    l2top.inner.misc_l2_pmu := l2top.inner.l1i_logger := coreGate("l1i", early = true) := memBlock.frontendBridge.icache_node
  } else {
    l2top.inner.misc_l2_pmu := l2top.inner.l1i_logger := memBlock.frontendBridge.icache_node
  }
  if (!coreParams.softPTW) {
    if (EnableCoreReset) {
      l2top.inner.misc_l2_pmu := l2top.inner.ptw_logger := l2top.inner.ptw_to_l2_buffer.node :=
        coreGate("ptw", early = true) := memBlock.ptw_to_l2_buffer.node
    } else {
      l2top.inner.misc_l2_pmu := l2top.inner.ptw_logger := l2top.inner.ptw_to_l2_buffer.node := memBlock.ptw_to_l2_buffer.node
    }
  }

  // L2 Prefetch. With EnableCoreReset the bridge is cut in two (a sink and a source), so that XSTileImp can
  // isolate it from the core reset domain
  val l2_pf_iso = l2top.inner.l2cache match {
    case Some(l2) =>
      l2.pf_recv_node.flatMap { recv =>
        println("Connecting L1 prefetcher to L2!")
        if (EnableCoreReset) {
          val l2_pf_from_core = BundleBridgeSink(Some(() => new PrefetchRecv))
          val l2_pf_to_l2 = BundleBridgeSource(() => new PrefetchRecv)
          l2_pf_from_core := memBlock.l2_pf_sender_opt.get
          recv := l2_pf_to_l2
          Some((l2_pf_from_core, l2_pf_to_l2))
        } else {
          recv := memBlock.l2_pf_sender_opt.get
          None
        }
      }
    case None => None
  }

  val core_l3_tpmeta_source_port = l2top.inner.l2cache match {
    case Some(l2) => l2.tpmeta_source_node
    case None => None
  }
  val core_l3_tpmeta_sink_port = l2top.inner.l2cache match {
    case Some(l2) => l2.tpmeta_sink_node
    case None => None
  }

  // mmio
  if (EnableCoreReset) {
    l2top.inner.i_mmio_port := l2top.inner.i_mmio_buffer.node := coreGate("i_mmio", early = true) :=
      memBlock.frontendBridge.instr_uncache_node
  } else {
    l2top.inner.i_mmio_port := l2top.inner.i_mmio_buffer.node := memBlock.frontendBridge.instr_uncache_node
  }
  if (soc.EnableICacheCtrl) {
    if (EnableCoreReset) {
      // only the core itself reaches its ICache control registers (through its own MMIO path), so this edge
      // is drained together with the i_mmio / d_mmio gates; the core is the manager here
      memBlock.frontendBridge.icachectrl_node := coreIsolation() := l2top.inner.icachectrl_port_opt.get
    } else {
      memBlock.frontendBridge.icachectrl_node := l2top.inner.icachectrl_port_opt.get
    }
  }
  if (EnableCoreReset) {
    l2top.inner.d_mmio_port := coreGate("d_mmio", early = true) := memBlock.uncache_port
  } else {
    l2top.inner.d_mmio_port := memBlock.uncache_port
  }

  // =========== IO Connection ============
  class XSTileImp(wrapper: LazyModule) extends LazyModuleImp(wrapper) {
    val io = IO(new Bundle {
      val hartId = Input(UInt(hartIdLen.W))
      val msiInfo = Input(ValidIO(UInt(soc.IMSICParams.MSI_INFO_WIDTH.W)))
      val msiAck = Output(Bool())
      val teemsiInfo = Option.when(soc.IMSICParams.HasTEEIMSIC)(Input(ValidIO(UInt(soc.IMSICParams.MSI_INFO_WIDTH.W))))
      val teemsiAck = Option.when(soc.IMSICParams.HasTEEIMSIC)(Output(Bool()))
      val reset_vector = Input(UInt(PAddrBits.W))
      val reset_mtvec  = Option.when(enableResetMtvec)(Input(UInt(PAddrBits.W)))
      val cpu_halt = Output(Bool())
      val cpu_crtical_error = Output(Bool())
      val hartIsInReset = Output(Bool())
      val traceCoreInterface = new TraceCoreInterface
      val debugTopDown = new Bundle {
        val robHeadPaddr = Valid(UInt(PAddrBits.W))
        val l3MissMatch = Input(Bool())
      }
      val l3Miss = Input(Bool())
      val chi = if (enableCHI) Some(new PortIO) else None
      val nodeID = if (enableCHI) Some(Input(UInt(NodeIDWidth.W))) else None
      val clintTime = Input(ValidIO(UInt(64.W)))
      val dft = Option.when(hasDFT)(Input(new SramBroadcastBundle))
      val dft_reset = Option.when(hasMbist)(Input(new DFTResetSignals()))
      val l2_flush_en = Option.when(EnablePowerDown) (Output(Bool()))
      val l2_flush_done = Option.when(EnablePowerDown) (Output(Bool()))
      // reset of XSCore alone, L2 and CHI keep running (EnableCoreReset, CoreResetKeepL1; see CoreReset.scala).
      // The three requests are levels, asynchronous (each has its own synchroniser here, driven by a flip-flop
      // output, no glitches) and start the same sequence; the core is held in reset while a request is high
      // (at least 100 cycles) and starts when it drops. A request is never cancelled.
      //   debug_reset     - ndmreset of the Debug Module
      //   hart_reset      - hartreset of this hart
      //   core_reset_req  - reset controller of the cluster
      //   core_reset_busy - tile clock domain: the sequence is running, from its first cycle to its last
      //   core_in_reset   - tile clock domain: the reset of XSCore is asserted (it falls when the reset is
      //                     released, the core leaves reset about 20 cycles later: only busy = 0 says it runs)
      val debug_reset = Option.when(EnableCoreReset) (Input(Bool()))
      val hart_reset = Option.when(EnableCoreReset) (Input(Bool()))
      val core_reset_req = Option.when(EnableCoreReset) (Input(Bool()))
      val core_reset_busy = Option.when(EnableCoreReset) (Output(Bool()))
      val core_in_reset = Option.when(EnableCoreReset) (Output(Bool()))
      val lcrdy = Option.when(txSourceReady) (new LCrdyIn)
    })

    dontTouch(io.hartId)
    dontTouch(io.msiInfo)
    io.teemsiInfo.foreach(dontTouch(_))
    if (!io.chi.isEmpty) { dontTouch(io.chi.get) }

    val core_soft_rst = core_reset_sink.in.head._1 // unused

    l2top.module.io.hartId.fromTile := io.hartId
    core.module.io.hartId := l2top.module.io.hartId.toCore
    core.module.io.reset_vector := l2top.module.io.reset_vector.toCore
    core.module.io.reset_mtvec.foreach(_ := l2top.module.io.reset_mtvec.get.toCore)
    core.module.io.msiInfo := l2top.module.io.msiInfo.toCore
    l2top.module.io.msiInfo.fromTile := io.msiInfo
    core.module.io.teemsiInfo zip l2top.module.io.teemsiInfo foreach { case (core_teemsiInfo, l2top_teemsiInfo) =>
      core_teemsiInfo := l2top_teemsiInfo.toCore
    }
    l2top.module.io.teemsiInfo zip io.teemsiInfo foreach { case (l2top_teemsiInfo, io_teemsiInfo) =>
      l2top_teemsiInfo.fromTile := io_teemsiInfo
    }
    core.module.io.clintTime := l2top.module.io.clintTime.toCore
    l2top.module.io.clintTime.fromTile := io.clintTime
    l2top.module.io.reset_vector.fromTile := io.reset_vector
    l2top.module.io.reset_mtvec.foreach(x => x.fromTile := io.reset_mtvec.get)
    l2top.module.io.cpu_halt.fromCore := core.module.io.cpu_halt
    io.cpu_halt := l2top.module.io.cpu_halt.toTile
    l2top.module.io.cpu_critical_error.fromCore := core.module.io.cpu_critical_error
    io.cpu_crtical_error := l2top.module.io.cpu_critical_error.toTile
    l2top.module.io.msiAck.fromCore := core.module.io.msiAck
    io.msiAck := l2top.module.io.msiAck.toTile
    l2top.module.io.teemsiAck zip core.module.io.teemsiAck foreach { case (l2top_teemsiAck, core_teemsiAck) =>
      l2top_teemsiAck.fromCore := core_teemsiAck
    }
    io.teemsiAck zip l2top.module.io.teemsiAck foreach { case (io_teemsiAck, l2top_teemsiAck) =>
      io_teemsiAck := l2top_teemsiAck.toTile
    }

    l2top.module.io.hartIsInReset.resetInFrontend := core.module.io.resetInFrontend
    io.hartIsInReset := l2top.module.io.hartIsInReset.toTile
    l2top.module.io.traceCoreInterface.fromCore <> core.module.io.traceCoreInterface
    io.traceCoreInterface <> l2top.module.io.traceCoreInterface.toTile

    l2top.module.io.beu_errors.icache <> core.module.io.beu_errors.icache
    l2top.module.io.beu_errors.dcache <> core.module.io.beu_errors.dcache
    l2top.module.io.beu_errors.uncache <> core.module.io.beu_errors.uncache

    l2top.module.io.l2_flush_en.foreach { _ := core.module.io.l2_flush_en }
    io.l2_flush_en.foreach { _ := core.module.io.l2_flush_en }
    core.module.io.l2_flush_done := l2top.module.io.l2_flush_done.getOrElse(false.B)
    io.l2_flush_done.foreach { _ := l2top.module.io.l2_flush_done.getOrElse(false.B) }
    io.lcrdy.foreach { in => l2top.module.io.lcrdy.foreach( out => out := in ) }

    l2top.module.io.dft.zip(io.dft).foreach({ case (a, b) => a := b })
    l2top.module.io.dft_reset.zip(io.dft_reset).foreach({ case (a, b) => a := b })
    core.module.io.dft.zip(io.dft).foreach({ case (a, b) => a := b })
    core.module.io.dft_reset.zip(io.dft_reset).foreach({ case (a, b) => a := b })

    if (enableL2) {
      // TODO: add ECC interface of L2
      l2top.module.io.pfCtrlFromCore := core.module.io.l2PfCtrl

      l2top.module.io.beu_errors.l2 <> 0.U.asTypeOf(l2top.module.io.beu_errors.l2)
      core.module.io.l2_hint.bits.sourceId := l2top.module.io.l2_hint.bits.sourceId
      core.module.io.l2_hint.bits.isKeyword := l2top.module.io.l2_hint.bits.isKeyword
      core.module.io.l2_hint.valid := l2top.module.io.l2_hint.valid

      core.module.io.l2PfqBusy := false.B
      core.module.io.debugTopDown.l2MissMatch := l2top.module.io.debugTopDown.l2MissMatch
      l2top.module.io.debugTopDown.robHeadPaddr := core.module.io.debugTopDown.robHeadPaddr
      l2top.module.io.debugTopDown.robTrueCommit := core.module.io.debugTopDown.robTrueCommit
      l2top.module.io.l2_pmp_resp := core.module.io.l2_pmp_resp
      core.module.io.l2_tlb_req <> l2top.module.io.l2_tlb_req
      core.module.io.topDownInfo.l2Miss := l2top.module.io.l2Miss

      core.module.io.perfEvents <> l2top.module.io.perfEvents
    } else {

      l2top.module.io.beu_errors.l2 <> 0.U.asTypeOf(l2top.module.io.beu_errors.l2)
      core.module.io.l2_hint.bits.sourceId := l2top.module.io.l2_hint.bits.sourceId
      core.module.io.l2_hint.bits.isKeyword := l2top.module.io.l2_hint.bits.isKeyword
      core.module.io.l2_hint.valid := l2top.module.io.l2_hint.valid

      core.module.io.l2PfqBusy := false.B
      core.module.io.debugTopDown.l2MissMatch := false.B
      core.module.io.topDownInfo.l2Miss := false.B

      core.module.io.l2_tlb_req.req.valid := false.B
      core.module.io.l2_tlb_req.req.bits := DontCare
      core.module.io.l2_tlb_req.req_kill := DontCare
      core.module.io.l2_tlb_req.resp.ready := true.B

      core.module.io.perfEvents <> DontCare
    }

    io.debugTopDown.robHeadPaddr := core.module.io.debugTopDown.robHeadPaddr
    core.module.io.debugTopDown.l3MissMatch := io.debugTopDown.l3MissMatch
    l2top.module.io.l3Miss.fromTile := io.l3Miss
    core.module.io.topDownInfo.l3Miss := l2top.module.io.l3Miss.toCore

    io.chi.foreach(_ <> l2top.module.io.chi.get)
    l2top.module.io.nodeID.foreach(_ := io.nodeID.get)

    // =========== Core-only reset (EnableCoreReset) ============
    // The sequencer, the isolation of every output of XSCore and the reset of XSCore. All of it is under
    // Option / foreach: without EnableCoreReset nothing of this exists and the connections above are upstream's.
    val coreResetCtrl = Option.when(EnableCoreReset)(Module(new CoreResetCtrl(CoreResetKeepL1)))
    coreResetCtrl.foreach { ctl =>
      // every asynchronous source has its own synchroniser (3 flip-flops, cleared by the tile reset); they are
      // combined after it
      val reqs = Seq(io.debug_reset.get, io.hart_reset.get, io.core_reset_req.get)
        .map(AsyncResetSynchronizerShiftReg(_, 3, 0))
      ctl.io.req := reqs.reduce(_ || _)
      io.core_reset_busy.get := ctl.io.busy
      io.core_in_reset.get := ctl.io.inReset
      core.module.io.l1_quiesce.get <> ctl.io.l1
      coreGates.foreach { g =>
        // channel A: non-coherent agents from sQuiesce, L1D from sDrain
        g.module.io.block := (if (g.early) ctl.io.earlyBlock else ctl.io.gateBlock)
        g.module.io.holdB := ctl.io.holdProbe
        g.module.io.ackB := ctl.io.ackProbe
        g.module.io.isolate := ctl.io.isolate
      }
      coreIsolations.foreach(_.module.io.isolate := ctl.io.isolate)
      ctl.io.earlyQuiet := coreGates.filter(_.early).map(_.module.io.quiet).foldLeft(true.B)(_ && _)
      ctl.io.gatesQuiet := (coreGates.map(_.module.io.quiet) ++ coreIsolations.map(_.module.io.quiet))
        .foldLeft(true.B)(_ && _)
      // the frontend is the last part of XSCore to leave reset (ResetGen chain memBlock -> backend ->
      // frontend); CoreResetCtrl looks at it in sRelease only
      ctl.io.coreInReset := core.module.io.resetInFrontend

      // ---- isolation of the outputs of XSCore ----
      // The core reset is asserted asynchronously (ResetGen synchronises only its release), so the outputs of
      // XSCore change at no particular clock edge then (reset domain crossing). isolate (a register of
      // CoreResetCtrl, high from sIso, at least one full cycle before the core reset, until a cycle after the
      // core is out of reset) replaces each control output on the tile side by a value that does not depend
      // on the core:
      //   isoReset(x, r): r, the value x takes in reset (valid signals 0, levels of a handshake, status levels);
      //   isoHold(x)    : the value x had before (configuration levels with no handshake).
      // A data field qualified by an isolated valid needs nothing (it is not looked at without its valid).
      // TileLink is isolated in the gates and in TLResetIsolation, the DCache handshake (l1_quiesce.done, alive)
      // in CoreResetCtrl, the L1D arrays that survive the reset by l1_quiesce.freeze; the inputs of XSCore need
      // nothing. The overrides below follow the upstream connections above (the last connection wins).
      val iso = ctl.io.isolate
      def isoReset[T <: Data](x: T, r: T): T = Mux(iso, r, x)
      def isoHold[T <: Data](x: T): T = Mux(iso, RegEnable(x, !iso), x)

      // L1 prefetch requests to L2 and L3: masked from the first cycle of the sequence (not only from isolate),
      // so that no prefetch of the core is on its way to L2 when a held Probe has to wait there (see DESIGN 8.2)
      l2_pf_iso.foreach { case (fromCore, toL2) =>
        toL2.out.head._1 := fromCore.in.head._1
        toL2.out.head._1.addr_valid := isoReset(fromCore.in.head._1.addr_valid, false.B) && !ctl.io.busy
        toL2.out.head._1.l2_pf_en := isoHold(fromCore.in.head._1.l2_pf_en)
      }
      l3_pf_iso.foreach { case (fromCore, toL3) =>
        toL3.out.head._1 := fromCore.in.head._1
        toL3.out.head._1.addr_valid := isoReset(fromCore.in.head._1.addr_valid, false.B) && !ctl.io.busy
        toL3.out.head._1.l2_pf_en := isoHold(fromCore.in.head._1.l2_pf_en)
      }

      // status levels, 0 in reset
      l2top.module.io.cpu_halt.fromCore := isoReset(core.module.io.cpu_halt, false.B)
      l2top.module.io.cpu_critical_error.fromCore := isoReset(core.module.io.cpu_critical_error, false.B)
      // MSI handshake with the IMSIC bus bridge (four-phase, levels): ack is 0 in reset. Not a hold: a held 1
      // would hide the 0 of the core's reset and the bridge would wait for it forever
      l2top.module.io.msiAck.fromCore := isoReset(core.module.io.msiAck, false.B)
      l2top.module.io.teemsiAck zip core.module.io.teemsiAck foreach { case (l2top_teemsiAck, core_teemsiAck) =>
        l2top_teemsiAck.fromCore := isoReset(core_teemsiAck, false.B)
      }

      // the reset of the frontend itself, 1 in reset (asserted asynchronously)
      l2top.module.io.hartIsInReset.resetInFrontend := isoReset(core.module.io.resetInFrontend, true.B)
      // for the Debug Module: the hart is "in reset" from the first cycle of the sequence until the core runs
      io.hartIsInReset := l2top.module.io.hartIsInReset.toTile || ctl.io.hartInReset

      // trace: the groups are valid-qualified (L2Top registers priv, trap, iaddr, ilastsize with the valid of a
      // group, but iretire and itype without it), mstatus is a plain level
      val traceFromCore = core.module.io.traceCoreInterface.toEncoder
      val traceToL2Top = l2top.module.io.traceCoreInterface.fromCore.toEncoder
      traceToL2Top.groups.zip(traceFromCore.groups).foreach { case (t, c) =>
        t.valid := isoReset(c.valid, false.B)
        t.bits.iretire := isoReset(c.bits.iretire, 0.U.asTypeOf(c.bits.iretire))
        t.bits.itype := isoReset(c.bits.itype, 0.U.asTypeOf(c.bits.itype))
      }
      traceToL2Top.mstatus := isoHold(traceFromCore.mstatus)

      // ECC errors to the bus error unit: valid-qualified
      Seq(
        (l2top.module.io.beu_errors.icache, core.module.io.beu_errors.icache),
        (l2top.module.io.beu_errors.dcache, core.module.io.beu_errors.dcache),
        (l2top.module.io.beu_errors.uncache, core.module.io.beu_errors.uncache)
      ).foreach { case (t, c) => t.ecc_error.valid := isoReset(c.ecc_error.valid, false.B) }

      // L2 flush request (power down), a CSR level, 0 in reset
      val l2FlushEn = isoReset(core.module.io.l2_flush_en, false.B)
      l2top.module.io.l2_flush_en.foreach { _ := l2FlushEn }
      io.l2_flush_en.foreach { _ := l2FlushEn }

      if (enableL2) {
        // L2 prefetcher configuration (CSR levels): held while the core is isolated, and the L2 prefetchers
        // are off for the whole sequence (a prefetch MSHR may pick a line of L1D as its victim and Probe it)
        l2top.module.io.pfCtrlFromCore := isoHold(core.module.io.l2PfCtrl)
        when (ctl.io.busy) { l2top.module.io.pfCtrlFromCore.l2_pf_master_en := false.B }

        l2top.module.io.debugTopDown.robHeadPaddr.valid := isoReset(core.module.io.debugTopDown.robHeadPaddr.valid, false.B)
        l2top.module.io.debugTopDown.robTrueCommit := isoHold(core.module.io.debugTopDown.robTrueCommit)
        // CoupledL2 looks at pmp_resp a cycle after resp.valid: while isolated it answers "denied", so a
        // response that was in flight is dropped as an exception and not taken with an all-zero PMP answer
        val pmpDeny = Wire(new PMPRespBundle)
        pmpDeny.ld := true.B
        pmpDeny.st := true.B
        pmpDeny.instr := true.B
        pmpDeny.mmio := true.B
        pmpDeny.atomic := true.B
        l2top.module.io.l2_pmp_resp := isoReset(core.module.io.l2_pmp_resp, pmpDeny)
        // the L2 prefetcher translates through the core's TLB: no request during the sequence (the TLB answers
        // every request within a few cycles, so none is pending at the reset point)
        when (ctl.io.busy) { core.module.io.l2_tlb_req.req.valid := false.B }
        // isolation of the TLB port (the core is the responder): req.ready and resp.valid; ready is masked under busy like valid,
        // otherwise L2 would see a request fire that the core never took
        l2top.module.io.l2_tlb_req.req.ready := isoReset(core.module.io.l2_tlb_req.req.ready, false.B) && !ctl.io.busy
        l2top.module.io.l2_tlb_req.resp.valid := isoReset(core.module.io.l2_tlb_req.resp.valid, false.B)
      }
      io.debugTopDown.robHeadPaddr.valid := isoReset(core.module.io.debugTopDown.robHeadPaddr.valid, false.B)
    }

    // XSCore reset = tile reset (via the L2Top reset chain, if any) OR core-only reset; asserted
    // asynchronously, released synchronously to the tile clock
    coreResetCtrl match {
      case Some(ctl) =>
        val coreBaseReset = if (debugOpts.ResetGen && enableL2) l2top.module.reset_core.asBool else reset.asBool
        core.module.reset := withClockAndReset(clock, (coreBaseReset || ctl.io.coreReset).asAsyncReset) {
          ResetGen(io.dft_reset)
        }
        // CoreResetKeepL1: the L1D arrays that survive a core-only reset (coherence meta, error flags, tags)
        // follow the tile reset only, with the same synchroniser, so they are released together with the core
        // on a tile reset
        core.module.io.l1_keep_reset.foreach { _ := withClockAndReset(clock, coreBaseReset.asAsyncReset) {
          ResetGen(io.dft_reset)
        }.asAsyncReset }
      case None =>
        if (debugOpts.ResetGen && enableL2) {
          core.module.reset := l2top.module.reset_core
        }
    }
  }

  lazy val module = new XSTileImp(this)
}
