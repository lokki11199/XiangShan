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

package xiangshan.cache

import chisel3._
import chisel3.util._
import org.chipsalliance.cde.config.Parameters
import utility._

/** Interface between CoreResetCtrl (tile reset domain) and the DCache (core reset domain), see CoreReset.scala.
  * Only for a reset of XSCore alone (EnableCoreReset). */
class L1QuiesceIO extends Bundle {
  val req    = Output(Bool())   // level: drain L1D and keep it blocked (no store, atomic, CMO, new miss)
  val freeze = Output(Bool())   // CoreResetKeepL1: XSCore is isolated, no access to the arrays that survive (0 otherwise)
  val done   = Input(Bool())    // drained; stays high while req is high
  val idle   = Input(Bool())    // all four emptiness flags, this cycle
  val alive  = Input(Bool())    // the DCache control logic is out of reset
}

/** Drain of the DCache before a reset of XSCore alone.
  *
  * The control logic of the DCache (MissQueue, WritebackQueue, ProbeQueue, MainPipe) is reset with the core, so
  * at the reset point it must hold no transaction: no Acquire waiting for its Grant or GrantAck, no Release
  * waiting for its ReleaseAck or cut between two beats, no Probe on its way to MainPipe. The lines themselves are
  * not touched here, FULL and KEEP differ only in DCacheImp (what the reset does to the arrays).
  *
  * While req is high the unit blocks new stores, atomics, CMOs and misses (block); loads that hit and Probes
  * are still served. Three states: sIdle, sDrain (wait for the four emptiness flags), sDone (done stays high until
  * req drops). The flags are exact, there is no waiting time:
  *   mq_empty : no MissEntry in use, no request in the MissQueue enqueue register, no CMO in progress
  *   wbq_empty: no WritebackQueue entry in use (every Release got its ReleaseAck)
  *   mp_empty : no request in MainPipe s1, s2, s3
  *   pq_empty : no ProbeQueue entry in use and no request on its way to MainPipe
  * idle is the same four flags in the current cycle: after done only a Probe can make the DCache busy again
  * (channel B is open until CoreResetCtrl leaves sDrain), so CoreResetCtrl looks at idle once more.
  */
class DCacheQuiesceUnit(implicit p: Parameters) extends DCacheModule {
  val io = IO(new Bundle {
    val quiesce = Flipped(new L1QuiesceIO)
    val block = Output(Bool())
    val mq_empty = Input(Bool())
    val wbq_empty = Input(Bool())
    val mp_empty = Input(Bool())
    val pq_empty = Input(Bool())
  })

  val sIdle :: sDrain :: sDone :: Nil = Enum(3)
  val state = RegInit(sIdle)
  val idle = io.mq_empty && io.wbq_empty && io.mp_empty && io.pq_empty

  switch (state) {
    is (sIdle) {
      when (io.quiesce.req) { state := sDrain }
    }
    is (sDrain) {
      when (!io.quiesce.req) { state := sIdle }
        .elsewhen (idle) { state := sDone }
    }
    is (sDone) {
      when (!io.quiesce.req) { state := sIdle }
    }
  }

  io.block := state =/= sIdle
  io.quiesce.done := state === sDone
  io.quiesce.idle := idle
  // a register of the core reset domain: 0 while the core is in reset, 1 once the DCache logic runs
  val alive = RegInit(false.B)
  alive := true.B
  io.quiesce.alive := alive

  XSPerfAccumulate("l1_quiesce", state === sIdle && io.quiesce.req)
  XSPerfAccumulate("l1_quiesce_cycles", state === sDrain)
}
