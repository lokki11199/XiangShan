/***************************************************************************************
* RTL test bench of the real DCache for the core-only reset (verification only, not part of the patch).
* Copy into src/main/scala/xiangshan/ and run:
*   mill -i xiangshan.runMain xiangshan.CoreResetDCacheElab <outdir> [full,keep]
* Targets (each into <outdir>/dcache_<target>):
*   full : DCacheWrapper + TLBuffer (l1d_to_l2_buffer) + TLQuiesceGate("l1d"), CoreResetKeepL1 = false
*   keep : the same, CoreResetKeepL1 = true (meta / error / tag arrays on the tile reset)
* TESTPLAN section 5.2. There is no CoreResetCtrl inside: the stand (tb_rtl/dcache_tb.sv) puts the RTL
* CoreResetCtrl_* (verification/rtl) or the model cr_ctrl next to it. The harness only
*   - builds the reset tree of XSTile around the DCache: tile reset for the gate and the keep-reset of the
*     arrays, core reset (tile reset || core_reset) for the DCache, the buffer and the drivers;
*   - turns the bundles of DCacheIO into flat ports the stand can drive (store, atomics, CMO, WFI, load);
*   - exposes the TL-C port of the L2 side (manager node "l2", parameters of CoupledL2);
*   - writes params.svh (sizes the stand reads from the elaboration, so no number is typed by hand).
* DCache inputs that are not driven by a flat port are constants (valid = 0, ready = 1).
***************************************************************************************/

package xiangshan

import chisel3._
import chisel3.util._
import _root_.circt.stage.ChiselStage
import org.chipsalliance.cde.config.Parameters
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.tilelink._
import system.SoCParamsKey
import utility.{ChiselDB, Constantin, ResetGen}
import xiangshan.cache._

object CoreResetDCacheHarness {
  // where params.svh goes (set by CoreResetDCacheElab before the module is built)
  var paramsPath: Option[String] = None
}

class CoreResetDCacheHarness(keep: Boolean)(implicit p: Parameters) extends LazyModule
  with HasXSParameter
  with HasDCacheParameters
  with MemoryOpConstants {
  override lazy val desiredName = "CoreResetDCacheHarness"
  private val self = this

  private val l2p = p(XSCoreParamsKey).L2CacheParamsOpt.get
  private val blockSize = TransferSizes(cfg.blockBytes, cfg.blockBytes)
  private val atomSize = TransferSizes(1, 32)
  private val accessSize = TransferSizes(1, cfg.blockBytes)

  // the L2 side: what CoupledL2 (TL2CHICoupledL2.managerParameters) offers to a client
  val l2Node = TLManagerNode(Seq(TLSlavePortParameters.v1(
    managers = Seq(TLSlaveParameters.v1(
      address = Seq(AddressSet(0x0L, 0xffffffffffffL)),
      regionType = RegionType.CACHED,
      supportsAcquireT = blockSize,
      supportsAcquireB = blockSize,
      supportsArithmetic = atomSize,
      supportsLogical = atomSize,
      supportsGet = accessSize,
      supportsPutFull = accessSize,
      supportsPutPartial = accessSize,
      supportsHint = accessSize,
      fifoId = None
    )),
    beatBytes = 32,
    minLatency = 2,
    responseFields = l2p.respField,
    requestKeys = l2p.reqKey,
    endSinkId = 256
  )))(ValName("l2"))

  val dcw = LazyModule(new DCacheWrapper)
  val l1dBuf = LazyModule(new TLBuffer)                       // as l1d_to_l2_buffer in MemBlock
  val l1dGate = LazyModule(new TLQuiesceGate("l1d", early = false))
  l2Node := l1dGate.node := l1dBuf.node := dcw.clientNode

  // the control registers of the DCache (CtrlUnit): a client that never sends
  val ctrlClient = dcw.uncacheNode.map { n =>
    val c = TLClientNode(Seq(TLMasterPortParameters.v1(
      clients = Seq(TLMasterParameters.v1(name = "ctrl", sourceId = IdRange(0, 1)))
    )))(ValName("ctrl"))
    n := c
    c
  }

  val l2io = InModuleBody { l2Node.makeIOs() }

  lazy val module = new LazyModuleImp(this) with RequireAsyncReset {
    val d = dcw.module

    // ---------------------------------------------------------------- reset tree (as XSTile / MemBlock)
    val core_reset    = IO(Input(Bool()))      // level, tile clock, from CoreResetCtrl.coreReset
    val core_in_reset = IO(Output(Bool()))     // the "frontend" reset: the last stage of the chain
    // tile reset || core reset, asynchronous assertion, synchronous release (ResetGen of the core in XSTile)
    val coreRst: AsyncReset = withClockAndReset(clock, (reset.asBool || core_reset).asAsyncReset) { ResetGen(None) }
    val frontRst: AsyncReset = withClockAndReset(clock, coreRst) { ResetGen(None) }
    core_in_reset := frontRst.asBool
    d.reset := coreRst
    l1dBuf.module.reset := coreRst
    d.io.keepReset.foreach { r =>
      r := withClockAndReset(clock, reset.asBool.asAsyncReset) { ResetGen(None) }   // tile reset only (no core reset)
    }

    // ---------------------------------------------------------------- controller side
    val quiesce = IO(Flipped(new L1QuiesceIO))     // req, freeze: in; done, idle, alive: out
    val gate    = IO(new QuiesceGateIO)            // block, holdB, ackB, isolate: in; quiet: out
    quiesce <> d.io.quiesce.get
    l1dGate.module.io <> gate

    // ---------------------------------------------------------------- flat ports of the stand
    // store (sbuffer): one line per request
    val st_req_valid = IO(Input(Bool()))
    val st_req_ready = IO(Output(Bool()))
    val st_req_addr  = IO(Input(UInt(PAddrBits.W)))
    val st_req_data  = IO(Input(UInt((cfg.blockBytes * 8).W)))
    val st_req_mask  = IO(Input(UInt(cfg.blockBytes.W)))
    val st_req_id    = IO(Input(UInt(reqIdWidth.W)))
    val st_hit_valid    = IO(Output(Bool()))
    val st_hit_id       = IO(Output(UInt(reqIdWidth.W)))
    val st_replay_valid = IO(Output(Bool()))
    val st_replay_id    = IO(Output(UInt(reqIdWidth.W)))
    // atomics (AtomicsUnit)
    val amo_req_valid = IO(Input(Bool()))
    val amo_req_ready = IO(Output(Bool()))
    val amo_cmd       = IO(Input(UInt(M_SZ.W)))
    val amo_addr      = IO(Input(UInt(PAddrBits.W)))        // byte address
    val amo_data      = IO(Input(UInt(QuadWordBits.W)))
    val amo_mask      = IO(Input(UInt(QuadWordBytes.W)))
    val amo_cmp       = IO(Input(UInt(QuadWordBits.W)))
    val amo_resp_valid  = IO(Output(Bool()))
    val amo_resp_data   = IO(Output(UInt(QuadWordBits.W)))
    val amo_resp_miss   = IO(Output(Bool()))
    val amo_resp_replay = IO(Output(Bool()))
    val amo_resp_id     = IO(Output(UInt(reqIdWidth.W)))   // SC: success
    val amo_block_lr    = IO(Output(Bool()))
    // CMO (cbo.clean / flush / inval)
    val cmo_req_valid  = IO(Input(Bool()))
    val cmo_req_ready  = IO(Output(Bool()))
    val cmo_opcode     = IO(Input(UInt(3.W)))               // 0 clean, 1 flush, 2 inval
    val cmo_address    = IO(Input(UInt(64.W)))
    val cmo_resp_valid = IO(Output(Bool()))
    val cmo_resp_ready = IO(Input(Bool()))
    val cmo_resp_address = IO(Output(UInt(64.W)))
    val cmo_resp_err   = IO(Output(Bool()))
    // WFI
    val wfi_req  = IO(Input(Bool()))
    val wfi_safe = IO(Output(Bool()))
    // load: one port; s1 paddr is the address of the previous cycle
    val ld_req_valid = IO(Input(Bool()))
    val ld_req_ready = IO(Output(Bool()))
    val ld_req_addr  = IO(Input(UInt(PAddrBits.W)))
    val ld_resp_valid  = IO(Output(Bool()))
    val ld_resp_miss   = IO(Output(Bool()))
    val ld_resp_replay = IO(Output(Bool()))
    val ld_resp_data   = IO(Output(UInt(64.W)))
    val ld_s2_hit      = IO(Output(Bool()))

    // ---------------------------------------------------------------- DCache inputs: constants
    d.io.lsu.load.foreach(_ := DontCare)
    d.io.lsu.sta.foreach(_ := DontCare)
    d.io.lsu.forward_mshr.foreach(_ := DontCare)
    d.io.lsu.store.req.bits := DontCare
    d.io.lsu.atomics.req.bits := DontCare
    d.io.cmoOpReq.bits := DontCare
    d.io.debugRolling := DontCare
    d.io.debugTopDown.robHeadVaddr := DontCare
    d.io.l2_hint.bits := DontCare
    d.io.hartId := 0.U
    d.io.l2_pf_store_only := false.B
    d.io.lqEmpty := true.B
    d.io.force_write := false.B
    d.io.sms_agt_evict_req.ready := true.B
    d.io.debugTopDown.robHeadVaddr.valid := false.B
    d.io.debugTopDown.robHeadOtherReplay := false.B
    d.io.l2_hint.valid := false.B
    d.io.lsu.sta.foreach { s => s.req.valid := false.B; s.resp.ready := true.B }
    d.io.lsu.forward_mshr.foreach(_.valid := false.B)
    d.io.lsu.load.foreach { l => l.req.valid := false.B; l.resp.ready := true.B }
    ctrlClient.foreach { c =>
      val (cb, _) = c.out.head
      cb.a.valid := false.B
      cb.a.bits := DontCare
      cb.d.ready := true.B
    }

    // ---------------------------------------------------------------- drivers (core reset domain)
    withClockAndReset(clock, coreRst) {
      // store
      val sreq = d.io.lsu.store.req
      sreq.valid := st_req_valid
      sreq.bits.cmd := M_XWR
      sreq.bits.addr := st_req_addr
      sreq.bits.vaddr := st_req_addr
      sreq.bits.data := st_req_data
      sreq.bits.mask := st_req_mask
      sreq.bits.id := st_req_id
      st_req_ready := sreq.ready
      st_hit_valid := d.io.lsu.store.main_pipe_hit_resp.valid
      st_hit_id := d.io.lsu.store.main_pipe_hit_resp.bits.id
      st_replay_valid := d.io.lsu.store.replay_resp.valid
      st_replay_id := d.io.lsu.store.replay_resp.bits.id

      // atomics: the request is filled as AtomicsUnit.scala does
      val areq = d.io.lsu.atomics.req
      areq.valid := amo_req_valid
      val pr = areq.bits
      pr.miss := false.B
      pr.probe := false.B
      pr.probe_need_data := false.B
      pr.source := self.AMO_SOURCE.U
      pr.cmd := amo_cmd
      pr.addr := self.get_block_addr(amo_addr)
      pr.vaddr := self.get_block_addr(amo_addr)
      pr.word_idx := self.get_word(amo_addr)
      pr.amo_data := amo_data
      pr.amo_mask := amo_mask
      pr.amo_cmp := amo_cmp
      pr.miss_fail_cause_evict_btot := false.B
      amo_req_ready := areq.ready
      amo_resp_valid := d.io.lsu.atomics.resp.valid
      amo_resp_data := d.io.lsu.atomics.resp.bits.data
      amo_resp_miss := d.io.lsu.atomics.resp.bits.miss
      amo_resp_replay := d.io.lsu.atomics.resp.bits.replay
      amo_resp_id := d.io.lsu.atomics.resp.bits.id
      amo_block_lr := d.io.lsu.atomics.block_lr

      // CMO
      d.io.cmoOpReq.valid := cmo_req_valid
      d.io.cmoOpReq.bits.opcode := cmo_opcode
      d.io.cmoOpReq.bits.address := cmo_address
      cmo_req_ready := d.io.cmoOpReq.ready
      cmo_resp_valid := d.io.cmoOpResp.valid
      d.io.cmoOpResp.ready := cmo_resp_ready
      cmo_resp_address := d.io.cmoOpResp.bits.address
      cmo_resp_err := d.io.cmoOpResp.bits.nderr || d.io.cmoOpResp.bits.denied || d.io.cmoOpResp.bits.corrupt

      // WFI
      d.io.wfi.wfiReq := wfi_req
      wfi_safe := d.io.wfi.wfiSafe

      // load (port 0): s0 = request, s1 = paddr of the previous cycle, no kills
      val l0 = d.io.lsu.load(0)
      l0.req.valid := ld_req_valid
      l0.req.bits.cmd := M_XRD
      l0.req.bits.vaddr := ld_req_addr
      l0.req.bits.vaddr_dup := ld_req_addr
      l0.req.bits.data := 0.U
      l0.req.bits.mask := Fill(l0.req.bits.mask.getWidth, 1.U(1.W))
      l0.req.bits.id := 0.U
      l0.req.bits.instrtype := self.LOAD_SOURCE.U
      l0.req.bits.isFirstIssue := true.B
      l0.req.bits.debug_robIdx := 0.U
      l0.pf_source := 0.U
      l0.s1_kill_data_read := false.B
      l0.s1_kill := false.B
      l0.s2_kill := false.B
      l0.s0_pc := 0.U
      l0.s1_pc := 0.U
      l0.s2_pc := 0.U
      l0.replacementUpdated := false.B
      l0.is128Req := false.B
      val s1addr = RegNext(ld_req_addr, 0.U)
      l0.s1_paddr_dup_lsu := s1addr
      l0.s1_paddr_dup_dcache := s1addr
      ld_req_ready := l0.req.ready
      ld_resp_valid := l0.resp.valid
      ld_resp_miss := l0.resp.bits.miss
      ld_resp_replay := l0.resp.bits.replay
      ld_resp_data := l0.resp.bits.data(63, 0)
      ld_s2_hit := l0.s2_hit
    }

    // ---------------------------------------------------------------- sizes for the stand
    CoreResetDCacheHarness.paramsPath.foreach { path =>
      val (_, e) = l2Node.in.head
      val lines = Seq(
        "NSETS"        -> self.DCacheSets,
        "NWAYS"        -> self.DCacheWays,
        "BLOCK_BYTES"  -> self.cfg.blockBytes,
        "BEAT_BYTES"   -> e.manager.beatBytes,
        "SRC_BITS"     -> e.bundle.sourceBits,
        "SNK_BITS"     -> e.bundle.sinkBits,
        "ADDR_BITS"    -> e.bundle.addressBits,
        "SIZE_BITS"    -> e.bundle.sizeBits,
        "PADDR_BITS"   -> self.PAddrBits,
        "VADDR_BITS"   -> self.VAddrBits,
        "NMISS"        -> self.cfg.nMissEntries,
        "NREL"         -> self.cfg.nReleaseEntries,
        "REL_ID_BASE"  -> self.releaseIdBase,
        "CMO_SOURCE"   -> (self.cfg.nMissEntries + 1),
        "REQ_ID_BITS"  -> self.reqIdWidth,
        "AMO_SOURCE"   -> self.AMO_SOURCE,
        "LRSC_CYCLES"  -> self.LRSCCycles,
        "QUAD_BITS"    -> self.QuadWordBits,
        "KEEP"         -> (if (keep) 1 else 0)
      )
      val text = "// written by CoreResetDCacheHarness: sizes of the elaborated DCache\n" +
        lines.map { case (n, v) => s"localparam int $n = $v;\n" }.mkString
      java.nio.file.Files.write(java.nio.file.Paths.get(path), text.getBytes("UTF-8"))
    }
  }
}

object CoreResetDCacheElab extends App {
  val outDir = args.headOption.getOrElse("build/core_reset_elab")
  val targets = if (args.length > 1) args(1).split(",").toSeq else Seq("full", "keep")
  val firtoolOpts = Array("-O=release", "--disable-annotation-unknown",
    "--lowering-options=explicitBitcast,disallowLocalVariables,disallowPortDeclSharing,locationInfoStyle=none")

  /** One configuration into <outDir>/<dir>; also usable as the elab target dcache_full / dcache_keep. */
  def emit(dir: String, keep: Boolean): Unit = {
    // as `make verilog` for XSNoCTop: no --remove-assert (the asserts of the DCache and the gate are the test)
    val (config0, _, _) = top.ArgParser.parse(Array("--config", "XSNoCTopConfig", "--fpga-platform", "--dfx", "false"))
    val config = config0.alter((site, here, up) => {
      case SoCParamsKey => up(SoCParamsKey).copy(EnableCoreReset = true, CoreResetKeepL1 = keep)
      case XSCoreParamsKey => up(XSTileKey).head
    })
    Constantin.init(false)
    ChiselDB.init(false)
    new java.io.File(dir).mkdirs()
    CoreResetDCacheHarness.paramsPath = Some(s"$dir/params.svh")
    val h = DisableMonitors(p => LazyModule(new CoreResetDCacheHarness(keep)(p)))(config)
    ChiselStage.emitSystemVerilogFile(h.module, Array("--target-dir", dir), firtoolOpts)
  }

  targets.foreach {
    case "full" => emit(s"$outDir/dcache_full", keep = false)
    case "keep" => emit(s"$outDir/dcache_keep", keep = true)
    case t => println(s"CoreResetDCacheElab: unknown target $t")
  }
}
