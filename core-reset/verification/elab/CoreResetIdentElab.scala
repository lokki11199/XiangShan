/***************************************************************************************
* DCacheWrapper bench for the identity check of the RTL (verification only, not part of the patch).
* It uses nothing but the API of upstream XiangShan (7b16188): the same file is copied into src/main/scala/xiangshan/
* of the v6 tree and of the reference worktree of 7b16188, so the two trees elaborate the very same bench.
*   mill -i xiangshan.runMain xiangshan.CoreResetIdentElab <outdir>
* Writes the .sv files of <outdir>/ident_dcache: DCacheWrapper with XSNoCTopConfig (EnableCoreReset is not touched: false in
* v6 by default, absent in 7b16188), the TL port of the L2 side and the DCacheIO as ports. With
* EnableCoreReset = false the two trees must give the same RTL (TESTPLAN section 7;
* scripts/rtl_normalize.py compares them).
***************************************************************************************/

package xiangshan

import chisel3._
import circt.stage.ChiselStage
import org.chipsalliance.cde.config.Parameters
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.tilelink._
import system.SoCParamsKey
import utility.{ChiselDB, Constantin}
import xiangshan.cache._

class CoreResetIdentDCache(implicit p: Parameters) extends LazyModule {
  override lazy val desiredName = "IdentDCacheHarness"
  private val l2p = p(XSCoreParamsKey).L2CacheParamsOpt.get
  private val blockSize = TransferSizes(64, 64)

  val l2Node = TLManagerNode(Seq(TLSlavePortParameters.v1(
    managers = Seq(TLSlaveParameters.v1(
      address = Seq(AddressSet(0x0L, 0xffffffffffffL)),
      regionType = RegionType.CACHED,
      supportsAcquireT = blockSize,
      supportsAcquireB = blockSize,
      supportsArithmetic = TransferSizes(1, 32),
      supportsLogical = TransferSizes(1, 32),
      supportsGet = TransferSizes(1, 64),
      supportsPutFull = TransferSizes(1, 64),
      supportsPutPartial = TransferSizes(1, 64),
      supportsHint = TransferSizes(1, 64),
      fifoId = None
    )),
    beatBytes = 32,
    minLatency = 2,
    responseFields = l2p.respField,
    requestKeys = l2p.reqKey,
    endSinkId = 256
  )))(ValName("l2"))

  val dcw = LazyModule(new DCacheWrapper)
  l2Node := dcw.clientNode
  val ctrlClient = dcw.uncacheNode.map { n =>
    val c = TLClientNode(Seq(TLMasterPortParameters.v1(
      clients = Seq(TLMasterParameters.v1(name = "ctrl", sourceId = IdRange(0, 1)))
    )))(ValName("ctrl"))
    n := c
    c
  }
  val l2io = InModuleBody { l2Node.makeIOs() }

  lazy val module = new LazyModuleImp(this) with RequireAsyncReset {
    val io = IO(new DCacheIO)
    io <> dcw.module.io
    ctrlClient.foreach { c =>
      val (cb, _) = c.out.head
      cb.a.valid := false.B
      cb.a.bits := DontCare
      cb.d.ready := true.B
    }
  }
}

object CoreResetIdentElab {
  private val firtoolOpts = Array("-O=release", "--disable-annotation-unknown",
    "--lowering-options=explicitBitcast,disallowLocalVariables,disallowPortDeclSharing,locationInfoStyle=none")

  /** Also usable as the elab target ident_dcache (dir = <outdir>/ident_dcache). */
  def emit(dir: String): Unit = {
    val (config0, _, _) = top.ArgParser.parse(Array("--config", "XSNoCTopConfig", "--fpga-platform", "--dfx", "false"))
    val config = config0.alter((site, here, up) => {
      case XSCoreParamsKey => up(XSTileKey).head
    })
    Constantin.init(false)
    ChiselDB.init(false)
    val h = DisableMonitors(p => LazyModule(new CoreResetIdentDCache()(p)))(config)
    ChiselStage.emitSystemVerilogFile(h.module, Array("--target-dir", dir), firtoolOpts)
  }

  def main(args: Array[String]): Unit = {
    val outDir = args.headOption.getOrElse("build/core_reset_elab")
    emit(s"$outDir/ident_dcache")
  }
}
