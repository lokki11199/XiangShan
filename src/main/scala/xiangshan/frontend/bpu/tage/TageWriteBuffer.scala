// Copyright (c) 2024-2026 Beijing Institute of Open Source Chip (BOSC)
// Copyright (c) 2020-2026 Institute of Computing Technology, Chinese Academy of Sciences
// Copyright (c) 2020-2021 Peng Cheng Laboratory
//
// XiangShan is licensed under Mulan PSL v2.
// You can use this software according to the terms and conditions of the Mulan PSL v2.
// You may obtain a copy of Mulan PSL v2 at:
//          https://license.coscl.org.cn/MulanPSL2
//
// THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
// EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
// MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
//
// See the Mulan PSL v2 for more details.

package xiangshan.frontend.bpu.tage

import chisel3._
import chisel3.util._
import org.chipsalliance.cde.config.Parameters
import utility.ReplacementPolicy
import utility.XSPerfAccumulate
import utility.XSPerfHistogram
import xiangshan.frontend.bpu.TageTableInfo

// One buffer belongs to one bank/way. Clean snapshots remain available for prediction and training bypass.
class TageWriteBuffer(
    numEntries: Int,
    nameSuffix: String = ""
)(implicit p: Parameters, info: TageTableInfo) extends TageModule {
  require(numEntries >= 1)

  class TageWriteBufferIO extends TageBundle {
    val write: Valid[WriteBufferWriteReq]        = Flipped(Valid(new WriteBufferWriteReq))
    val drain: DecoupledIO[TageWriteBufferDrain] = Decoupled(new TageWriteBufferDrain)

    val lookupSetIdx: UInt                        = Input(UInt(SetIdxWidth.W))
    val lookupResp:   Valid[TageWriteBufferEntry] = Output(Valid(new TageWriteBufferEntry))

    val resetUseful: Bool = Input(Bool())

    val full:      Bool = Output(Bool())
    val overwrite: Bool = Output(Bool())
  }
  val io: TageWriteBufferIO = IO(new TageWriteBufferIO)

  private val entries     = RegInit(VecInit.fill(numEntries)(0.U.asTypeOf(new TageWriteBufferEntry)))
  private val valid       = RegInit(VecInit.fill(numEntries)(false.B))
  private val entryDirty  = RegInit(VecInit.fill(numEntries)(false.B))
  private val usefulDirty = RegInit(VecInit.fill(numEntries)(false.B))
  private val dirty       = VecInit(entryDirty.zip(usefulDirty).map { case (entry, useful) => entry || useful })

  private val nextEntries     = WireInit(entries)
  private val nextValid       = WireInit(valid)
  private val nextEntryDirty  = WireInit(entryDirty)
  private val nextUsefulDirty = WireInit(usefulDirty)

  private val lookupSetIdx = RegNext(io.lookupSetIdx, 0.U)
  private val lookupHits = VecInit(entries.zip(valid).map { case (entry, valid) =>
    valid && entry.setIdx === lookupSetIdx
  })
  assert(PopCount(lookupHits) <= 1.U, "TageWriteBuffer lookup must match at most one entry")
  io.lookupResp.valid := lookupHits.asUInt.orR
  io.lookupResp.bits  := Mux1H(lookupHits, entries)

  // Search from the next slot after the last successful drain.
  private val nextDrainStartIdx = RegInit(0.U(math.max(1, log2Ceil(numEntries)).W))
  private val drainCandidates = VecInit(dirty.zipWithIndex.map { case (pending, idx) =>
    pending && idx.U >= nextDrainStartIdx
  })
  private val drainIdx = Mux(drainCandidates.asUInt.orR, PriorityEncoder(drainCandidates), PriorityEncoder(dirty))
  io.drain.valid            := dirty.asUInt.orR
  io.drain.bits.setIdx      := entries(drainIdx).setIdx
  io.drain.bits.data        := entries(drainIdx).data
  io.drain.bits.entryDirty  := entryDirty(drainIdx)
  io.drain.bits.usefulDirty := usefulDirty(drainIdx)
  io.full                   := dirty.asUInt.andR

  // The drain writes the old snapshot. A simultaneous update below retains any newly changed fields.
  when(io.drain.fire) {
    nextDrainStartIdx         := Mux(drainIdx === (numEntries - 1).U, 0.U, drainIdx + 1.U)
    nextEntryDirty(drainIdx)  := false.B
    nextUsefulDirty(drainIdx) := false.B
  }

  private val setHits = VecInit(entries.zip(valid).map { case (entry, valid) =>
    valid && entry.setIdx === io.write.bits.setIdx
  })
  assert(!io.write.valid || PopCount(setHits) <= 1.U, "TageWriteBuffer must retain one snapshot per set")
  private val hitIdx = OHToUInt(setHits)
  private val hit    = setHits.asUInt.orR && entries(hitIdx).data.entry.tag === io.write.bits.data.entry.tag

  private val replacer = ReplacementPolicy.fromString("plru", numEntries)
  private val victim = Mux(
    setHits.asUInt.orR,
    hitIdx,
    // A successful drain frees its slot at this edge; reuse it before discarding another dirty entry.
    Mux(!io.full, PriorityEncoder(dirty.map(!_)), Mux(io.drain.fire, drainIdx, replacer.way))
  )
  private val writeAccess = Wire(Valid(UInt(log2Ceil(numEntries).W)))
  writeAccess.valid := io.write.valid
  writeAccess.bits  := Mux(hit, hitIdx, victim)
  // Protect recently trained snapshots, including hits that accumulate updates before draining.
  replacer.access(Seq(writeAccess))

  when(io.write.valid) {
    when(!hit) {
      // Prefer the existing slot for a different tag at the same set. A miss has no SRAM copy to compare against.
      nextEntries(victim).setIdx := io.write.bits.setIdx
      nextEntries(victim).data   := io.write.bits.data
      nextValid(victim)          := true.B
      nextEntryDirty(victim)     := true.B
      nextUsefulDirty(victim)    := true.B
    }.otherwise {
      val old     = entries(hitIdx).data
      val updated = WireInit(io.write.bits.data)
      updated.entry.takenCtr := Mux(
        io.write.bits.allocate,
        io.write.bits.data.entry.takenCtr,
        old.entry.takenCtr.getUpdate(
          io.write.bits.actualTaken,
          en = io.write.bits.updateTakenCtr
        )
      )
      updated.usefulCtr := Mux(
        io.write.bits.allocate,
        io.write.bits.data.usefulCtr,
        old.usefulCtr.getIncrease(en = io.write.bits.incUseful)
      )
      val drained       = io.drain.fire && drainIdx === hitIdx
      val entryChanged  = old.entry.asUInt =/= updated.entry.asUInt
      val usefulChanged = old.usefulCtr =/= updated.usefulCtr
      nextEntries(hitIdx).data := updated
      nextEntryDirty(hitIdx)   := (entryDirty(hitIdx) && !drained) || entryChanged
      nextUsefulDirty(hitIdx)  := (usefulDirty(hitIdx) && !drained) || usefulChanged
    }
  }

  // Useful reset takes priority over writes, preserving both the entry and its pending SRAM update.
  when(io.resetUseful) {
    for (slot <- 0 until numEntries) {
      nextEntries(slot).data.usefulCtr.value := 0.U
      nextUsefulDirty(slot)                  := false.B
    }
  }

  entries     := nextEntries
  valid       := nextValid
  entryDirty  := nextEntryDirty
  usefulDirty := nextUsefulDirty

  io.overwrite := io.write.valid && io.full && !hit && !(io.drain.fire && victim === drainIdx)

  private val namePrefix = s"${nameSuffix}_writeBuffer"
  XSPerfAccumulate(s"${namePrefix}_hit_not_written", io.write.valid && hit && dirty(hitIdx))
  XSPerfAccumulate(s"${namePrefix}_hit_written", io.write.valid && hit && !dirty(hitIdx))
  XSPerfAccumulate(s"${namePrefix}_hit", io.write.valid && hit)
  XSPerfAccumulate(s"${namePrefix}_not_hit", io.write.valid && !hit)
  XSPerfAccumulate(s"${namePrefix}_is_full", io.write.valid && io.full)
  XSPerfAccumulate(s"${namePrefix}_entry_dirty", PopCount(entryDirty))
  XSPerfAccumulate(s"${namePrefix}_useful_dirty", PopCount(usefulDirty))
  XSPerfHistogram(s"${namePrefix}_useful", PopCount(dirty), io.drain.ready, 0, numEntries)
}
