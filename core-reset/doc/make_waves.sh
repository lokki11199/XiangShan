#!/bin/bash
# VCD files for the timing diagrams of core-reset/doc/make_pdf.py (section 7.8): short traced simulations of the
# verification testbench (TRACE_BUILD=1 builds go to verification/build/obj_*_trace, separate from the regression
# builds; one build and one run at a time). The windows are found from events, not from fixed cycle numbers:
# The testbench dumps about 40000 signals and Verilator ignores +VCD_FROM, so a run writes a big VCD from cycle 0 to
# +VCD_TO; vcd.py extract finds the event in it and writes a small VCD (the 60 signals of the diagrams, a window of
# 100-250 cycles around the event) next to it, then the big file is deleted.
#   w1_full_scen1.vcd   FULL (the default configuration, ""), SCEN 1, seed 1: the first complete sequence. Pass 1 (no dump) finds the time of the
#                       first core reset in the log (+TRACE=0 prints "core reset"); the run stops 250 cycles after it;
#                       vcd.py takes the first sequence sIdle -> sQuiesce ... sRelease -> sIdle.
#   w2_keep_case5.vcd   KEEP, SCEN 6, seed 1: a directed Probe of case 5 (last cycle of sQuiesce). Pass 1 lists the
#                       directed Probes (#DIR lines with their start cycle); the candidates of case 5 (dirty line toN
#                       first) are run one by one up to 400 cycles after their start, and vcd.py picks the first one
#                       in which the gate really took the Probe in the last cycle of sQuiesce (after the start cycle).
#   w3_keep_case4.vcd   the same for case 4 (Probe offered in the first cycle of sDrain, not taken, held through the
#                       reset, answered by the hot L1D after it). The zoom on the isolation lead and the moment of the
#                       reset (sDrain -> sIso -> sReset, diagram 4) is made from this file.
# One build and one run at a time; run only when nothing else builds or simulates (disk, memory, CPU).
# Usage: core-reset/doc/make_waves.sh   (from anywhere). Output: core-reset/verification/build/waves/ (ignored by git)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../verification"
OUT=build/waves
mkdir -p "$OUT"
LOG=$OUT/make_waves.log
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
trace() { TRACE_BUILD=1 scripts/run.sh "$@"; }     # SCEN SEED CFG extra-plusargs

# ---- 1. FULL, SCEN 1, seed 1
say "== w1: FULL SCEN 1 seed 1, pass 1 (no dump)"
# v6 testbench prints no "core reset" line: dump up to cycle W1_TO (default 6000, enough for the first of the three
# sequences of SCEN 1; raise it if "no sequence in the window"), vcd.py finds the first complete sequence itself.
TO=${W1_TO:-6000}
say "run up to cycle $TO"
if true; then
  trace 1 1 "" +VCD +VCD_TO=$TO +VCD_FILE=$OUT/big.vcd > $OUT/w1.log 2>&1 || true
  python3 "$HERE/vcd.py" extract full1 $OUT/big.vcd $OUT/w1_full_scen1.vcd 2>&1 | tee -a "$LOG" || true
  rm -f $OUT/big.vcd
fi

# ---- 2, 3. KEEP, SCEN 6, seed 1: directed Probes of cases 5 and 4
say "== KEEP SCEN 6 seed 1, pass 1 (no dump)"
trace 6 1 CFG_KEEP +VCD +VCD_FROM=2000000000 > $OUT/w23_pass1.log 2>&1 || true
pick() {  # CASE NAME : first candidate that satisfies the check
  local CASE=$1 NAME=$2 found=0 line start
  # candidates: dirty lines toN first (kind=3 cap=2), then the other kinds
  for pat in "kind=3 cap=2" "kind=3 cap=1" "kind=2 cap=2" "kind=2 cap=1" "kind=1 cap=2"; do
    while read -r line; do
      start=$(echo "$line" | sed 's/.*start-cycle=\([0-9]*\).*/\1/')
      say "case $CASE candidate: $line"
      trace 6 1 CFG_KEEP +VCD +VCD_TO=$((start + 400)) +VCD_FILE=$OUT/big.vcd > $OUT/cand.log 2>&1 || true
      if python3 "$HERE/vcd.py" extract case$CASE $OUT/big.vcd $OUT/$NAME.vcd $((start - 5)) 2>&1 | tee -a "$LOG" | grep -q '^OK'; then
        echo "$line" > $OUT/$NAME.txt; found=1; break 2
      fi
    done < <(grep "^#DIR .* when=$CASE $pat " $OUT/w23_pass1.log)
  done
  [ $found = 1 ] || say "case $CASE: no candidate satisfied the check"
}
pick 5 w2_keep_case5
pick 4 w3_keep_case4
rm -f $OUT/big.vcd $OUT/cand.vcd
say "done: $(ls $OUT/w*.vcd 2>/dev/null | tr '\n' ' ')"
