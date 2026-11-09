#!/bin/bash
# VCD files for the timing diagrams of core-reset/doc/make_pdf.py (section 7.4): short traced simulations of the
# verification testbench (TRACE_BUILD=1 builds go to verification/build/obj_*_trace, separate from the regression
# builds; one build and one run at a time). The windows are found from events, not from fixed cycle numbers:
#   w1_sweep_scen1.vcd  CFG_SWEEP, SCEN 1, seed 1: the first complete sequence. Pass 1 (no dump) finds the time of the
#                       first core reset in the log (+TRACE=0 prints "core reset"); the window starts 1600 cycles
#                       before it (the sweep takes about 1100) and ends 250 cycles after it; vcd.py checks that the
#                       window holds a whole sequence sIdle -> sFlush ... sRelease -> sIdle.
#   w2_keep_case5.vcd   KEEP, SCEN 6, seed 1: a directed Probe of case 5 (last cycle of sFlush). Pass 1 lists the
#                       directed Probes (#DIR lines with their start cycle); the candidates of case 5 (dirty line toN
#                       first) are run one by one with a window of 400 cycles from their start, and vcd.py picks the
#                       first one in which the gate really took the Probe in the last cycle of sFlush.
#   w3_keep_case4.vcd   the same for case 4 (Probe offered in the first cycle of sDrain, not taken, held through the
#                       reset, answered by the hot L1D after it). The zoom on the moment of the reset (diagram 4) is
#                       made from this file.
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

# ---- 1. SWEEP, SCEN 1, seed 1
say "== w1: CFG_SWEEP SCEN 1 seed 1, pass 1 (no dump)"
trace 1 1 CFG_SWEEP +TRACE=0 +VCD +VCD_FROM=2000000000 > $OUT/w1_pass1.log 2>&1 || true
T=$(grep -m1 "T core reset" $OUT/w1_pass1.log | sed 's/^\[\([0-9]*\)\].*/\1/')
if [ -z "$T" ]; then say "no core reset in the log of pass 1"; else
  CYC=$((T / 10000))
  FROM=$((CYC - 1600)); [ $FROM -lt 1 ] && FROM=1
  TO=$((CYC + 250))
  say "first core reset at cycle ~$CYC, window $FROM..$TO"
  trace 1 1 CFG_SWEEP +VCD +VCD_FROM=$FROM +VCD_TO=$TO +VCD_FILE=$OUT/w1_sweep_scen1.vcd > $OUT/w1.log 2>&1 || true
  python3 "$HERE/vcd.py" check sweep1 $OUT/w1_sweep_scen1.vcd | tee -a "$LOG" || true
fi

# ---- 2, 3. KEEP, SCEN 6, seed 1: directed Probes of cases 5 and 4
say "== KEEP SCEN 6 seed 1, pass 1 (no dump)"
trace 6 1 "" +VCD +VCD_FROM=2000000000 > $OUT/w23_pass1.log 2>&1 || true
pick() {  # CASE NAME : first candidate that satisfies the check
  local CASE=$1 NAME=$2 found=0 line start
  # candidates: dirty lines toN first (kind=3 cap=2), then the other kinds
  for pat in "kind=3 cap=2" "kind=3 cap=1" "kind=2 cap=2" "kind=2 cap=1" "kind=1 cap=2"; do
    while read -r line; do
      start=$(echo "$line" | sed 's/.*start-cycle=\([0-9]*\).*/\1/')
      say "case $CASE candidate: $line"
      trace 6 1 "" +VCD +VCD_FROM=$((start - 3)) +VCD_TO=$((start + 400)) +VCD_FILE=$OUT/cand.vcd > $OUT/cand.log 2>&1 || true
      if python3 "$HERE/vcd.py" check case$CASE $OUT/cand.vcd | tee -a "$LOG" | grep -q '^OK'; then
        mv $OUT/cand.vcd $OUT/$NAME.vcd; echo "$line" > $OUT/$NAME.txt; found=1; break 2
      fi
    done < <(grep "^#DIR .* when=$CASE $pat " $OUT/w23_pass1.log)
  done
  [ $found = 1 ] || say "case $CASE: no candidate satisfied the check"
}
pick 5 w2_keep_case5
pick 4 w3_keep_case4
rm -f $OUT/cand.vcd
say "done: $(ls $OUT/*.vcd 2>/dev/null | tr '\n' ' ')"
