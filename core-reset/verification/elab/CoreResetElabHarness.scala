/***************************************************************************************
* Elaboration harness for the core-only reset (verification only, not part of the patch).
* Copy into src/main/scala/xiangshan/ and run:
*   mill -i xiangshan.runMain xiangshan.CoreResetElab <outdir> [ctrl_keep,ctrl_sweep,gates]
* Targets (each into its own directory <outdir>/<target>):
*   ctrl_keep  : CoreResetCtrl(keepL1 = true)
*   ctrl_sweep : CoreResetCtrl(keepL1 = false)
*   gates      : a TL-C client -> TLQuiesceGate("l1d", early = false) -> manager,
*                a TL-UL client -> TLQuiesceGate("l1i", early = true) -> manager,
*                a TL-UL client -> TLResetIsolation -> manager (asynchronous reset, as in XSTile)
* The RTL of these modules is compared with the SystemVerilog models (verification/formal/eq_chisel.sv).
* mill packs three binaries of the ready-to-run submodule as resources; when the submodule is not checked out,
* empty files ready-to-run/riscv64-{nemu-interpreter-dual,nemu-interpreter,spike}-so are enough for elaboration.
***************************************************************************************/

package xiangshan

import chisel3._
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

object CoreResetElab extends App {
  val outDir = args.headOption.getOrElse("build/core_reset_elab")
  val targets = if (args.length > 1) args(1).split(",").toSeq else Seq("ctrl_keep", "ctrl_sweep", "gates")
  val firtoolOpts = Array("-O=release", "--disable-annotation-unknown",
    "--lowering-options=explicitBitcast,disallowLocalVariables,disallowPortDeclSharing,locationInfoStyle=none")
  // a configuration only for the Parameters the TileLink nodes need
  val (config, _, _) = top.ArgParser.parse(Array("--config", "MinimalConfig", "--num-cores", "1"))

  targets.foreach {
    case "ctrl_keep" =>
      ChiselStage.emitSystemVerilogFile(new CoreResetCtrl(keepL1 = true), Array("--target-dir", s"$outDir/ctrl_keep"), firtoolOpts)
    case "ctrl_sweep" =>
      ChiselStage.emitSystemVerilogFile(new CoreResetCtrl(keepL1 = false), Array("--target-dir", s"$outDir/ctrl_sweep"), firtoolOpts)
    case "gates" =>
      val h = DisableMonitors(p => LazyModule(new CoreResetGatesHarness()(p)))(config)
      ChiselStage.emitSystemVerilogFile(h.module, Array("--target-dir", s"$outDir/gates"), firtoolOpts)
    case t => println(s"CoreResetElab: unknown target $t")
  }
}
