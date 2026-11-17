/***************************************************************************************
* Elaboration harness for the core-only reset (verification only, not part of the patch).
* Copy elab/*.scala into src/main/scala/xiangshan/ (CoreResetDCacheHarness.scala, CoreResetIdentElab.scala and
* this file; the three compile together) and run, one target per JVM when the target holds SRAMs:
*   mill -i xiangshan.runMain xiangshan.CoreResetElab <outdir> [ctrl_full,ctrl_keep,...]
* Targets (each into its own directory <outdir>/<target>), TESTPLAN section 3.1:
*   ctrl_full, ctrl_keep, ctrl_full_iso2, ctrl_keep_iso2 : CoreResetCtrl(keepL1, isoCycles = 1 | 2)
*   gates      : a TL-C client -> TLQuiesceGate("l1d", early = false) -> manager,
*                a TL-UL client -> TLQuiesceGate("l1i", early = true) -> manager,
*                a TL-UL client -> TLResetIsolation -> manager (asynchronous reset, as in XSTile)
*   quiesce    : DCacheQuiesceUnit (Parameters of XSNoCTopConfig with EnableCoreReset)
*   dcache_full, dcache_keep : the RTL test bench of the DCache (CoreResetDCacheHarness.scala); only one per JVM
*   ident_dcache             : the bench of the identity check (CoreResetIdentElab.scala)
* The RTL of ctrl / gates / quiesce is cut by scripts/extract_rtl.py into rtl/ and compared with the models
* (formal/eq_chisel.sv, formal/run_equiv.sh).
* mill packs three binaries of the ready-to-run submodule as resources; when the submodule is not checked out,
* empty files ready-to-run/riscv64-{nemu-interpreter-dual,nemu-interpreter,spike}-so are enough for elaboration.
***************************************************************************************/

package xiangshan

import chisel3._
import utility.Constantin
import circt.stage.ChiselStage
import org.chipsalliance.cde.config.Parameters
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.tilelink._

class CoreResetGatesHarness(implicit p: Parameters) extends LazyModule {
  private def manager(name: String, acquire: Boolean) = TLManagerNode(Seq(TLSlavePortParameters.v1(
    managers = Seq(TLSlaveParameters.v1(
      address = Seq(AddressSet(0x0, 0xffff)),
      regionType = if (acquire) RegionType.CACHED else RegionType.UNCACHED,
      supportsAcquireT = if (acquire) TransferSizes(1, 16) else TransferSizes.none,
      supportsAcquireB = if (acquire) TransferSizes(1, 16) else TransferSizes.none,
      supportsGet = TransferSizes(1, 16),
      supportsPutFull = TransferSizes(1, 16),
      supportsPutPartial = TransferSizes(1, 16)
    )),
    beatBytes = 8,
    endSinkId = if (acquire) 16 else 0
  )))(ValName(name))
  private def client(name: String, probe: Boolean) = TLClientNode(Seq(TLMasterPortParameters.v1(
    clients = Seq(TLMasterParameters.v1(
      name = name,
      sourceId = IdRange(0, 16),
      supportsProbe = if (probe) TransferSizes(1, 16) else TransferSizes.none
    ))
  )))(ValName(name))

  val c0 = client("l1d", probe = true)
  val m0 = manager("l2_c", acquire = true)
  val g0 = LazyModule(new TLQuiesceGate("l1d", early = false))
  m0 := g0.node := c0

  val c1 = client("l1i", probe = false)
  val m1 = manager("l2_ul", acquire = false)
  val g1 = LazyModule(new TLQuiesceGate("l1i", early = true))
  m1 := g1.node := c1

  val c2 = client("mmio", probe = false)
  val m2 = manager("icachectrl", acquire = false)
  val iso = LazyModule(new TLResetIsolation)
  m2 := iso.node := c2

  val c0io = InModuleBody { c0.makeIOs() }
  val m0io = InModuleBody { m0.makeIOs() }
  val c1io = InModuleBody { c1.makeIOs() }
  val m1io = InModuleBody { m1.makeIOs() }
  val c2io = InModuleBody { c2.makeIOs() }
  val m2io = InModuleBody { m2.makeIOs() }

  lazy val module = new LazyModuleImp(this) with RequireAsyncReset {
    val g0io = IO(new QuiesceGateIO)
    val g1io = IO(new QuiesceGateIO)
    val isoio = IO(new Bundle {
      val isolate = Input(Bool())
      val quiet = Output(Bool())
    })
    g0.module.io <> g0io
    g1.module.io <> g1io
    iso.module.io <> isoio
  }
}

object CoreResetElab {
  private val firtoolOpts = Array("-O=release", "--disable-annotation-unknown",
    "--lowering-options=explicitBitcast,disallowLocalVariables,disallowPortDeclSharing,locationInfoStyle=none")
  private val all = Seq("ctrl_full", "ctrl_keep", "ctrl_full_iso2", "ctrl_keep_iso2", "gates", "quiesce")

  /** Parameters of XSNoCTopConfig with the core reset enabled (for DCacheQuiesceUnit). */
  private def coreResetParams(keep: Boolean): Parameters = {
    val (c, _, _) = top.ArgParser.parse(Array("--config", "XSNoCTopConfig", "--fpga-platform", "--dfx", "false"))
    c.alter((site, here, up) => {
      case system.SoCParamsKey => up(system.SoCParamsKey).copy(EnableCoreReset = true, CoreResetKeepL1 = keep)
      case XSCoreParamsKey => up(XSTileKey).head
    })
  }

  def main(args: Array[String]): Unit = {
    val outDir = args.headOption.getOrElse("build/core_reset_elab")
    val targets = if (args.length > 1) args(1).split(",").toSeq else all
    // a configuration only for the Parameters the TileLink nodes of the gates need
    lazy val (config, _, _) = top.ArgParser.parse(Array("--config", "MinimalConfig", "--num-cores", "1"))
    def ctrl(name: String, keep: Boolean, iso: Int): Unit =
      ChiselStage.emitSystemVerilogFile(new CoreResetCtrl(keepL1 = keep, isoCycles = iso),
        Array("--target-dir", s"$outDir/$name"), firtoolOpts)
    targets.foreach {
      case "ctrl_full"      => ctrl("ctrl_full", keep = false, iso = 1)
      case "ctrl_keep"      => ctrl("ctrl_keep", keep = true, iso = 1)
      case "ctrl_full_iso2" => ctrl("ctrl_full_iso2", keep = false, iso = 2)
      case "ctrl_keep_iso2" => ctrl("ctrl_keep_iso2", keep = true, iso = 2)
      case "gates" =>
        val h = DisableMonitors(p => LazyModule(new CoreResetGatesHarness()(p)))(config)
        ChiselStage.emitSystemVerilogFile(h.module, Array("--target-dir", s"$outDir/gates"), firtoolOpts)
      case "quiesce" =>
        Constantin.init(false)
        ChiselStage.emitSystemVerilogFile(new xiangshan.cache.DCacheQuiesceUnit()(coreResetParams(false)),
          Array("--target-dir", s"$outDir/quiesce"), firtoolOpts)
      case "dcache_full" => CoreResetDCacheElab.emit(s"$outDir/dcache_full", keep = false)
      case "dcache_keep" => CoreResetDCacheElab.emit(s"$outDir/dcache_keep", keep = true)
      case "ident_dcache" => CoreResetIdentElab.emit(s"$outDir/ident_dcache")
      case t => println(s"CoreResetElab: unknown target $t")
    }
  }
}
