#!/bin/bash
# Long random run of one configuration; the summary lines of every run go to results_soak_<cfg>.log,
# scripts/coverage.py adds them up.
#   scripts/soak.sh [CFG]      CFG: "" (KEEP) | CFG_SWEEP
#   scenarios 1-3, seeds 31..130                      300 runs
#   scenarios 1-3 with +SLOW, seeds 11..40             90 runs
#   scenario 5 (in-flight triggers), seeds 21..70      50 runs
#   scenario 6 (directed Probes), seeds 11..35         25 runs
#   scenario 7 (long debug holds), seeds 11..35        25 runs
# Do not start it while another process builds the same configuration (regress.sh builds mutants only).
cd "$(dirname "$0")/.."
C=$1
B=build/obj${C:+_$C}/Vcr_tb
[ -x $B ] || scripts/run.sh 1 1 "$C" > /dev/null
LOG=results_soak_${C:-KEEP}.log
P=0; F=0; : > $LOG
one() {  # SCEN SEED [PLUSARGS]
  out=$(timeout 600 $B +SCEN=$1 +SEED=$2 $3 +verilator+seed+$2 +verilator+rand+reset+2 2>&1)
  echo "### SCEN=$1 SEED=$2 $3" >> $LOG
  echo "$out" | grep -E "^(config|final|txmon|probe-sb|triggers|directed|debug-hold|drain|RESULT)" >> $LOG
  if echo "$out" | grep -q "^RESULT: PASS$"; then P=$((P+1)); else F=$((F+1)); echo "FAIL ${C:-KEEP} SCEN=$1 SEED=$2 $3"; fi
}
for S in 1 2 3; do for SEED in $(seq 31 130); do one $S $SEED; done; done
for S in 1 2 3; do for SEED in $(seq 11 40); do one $S $SEED +SLOW; done; done
for SEED in $(seq 21 70); do one 5 $SEED; done
for SEED in $(seq 11 35); do one 6 $SEED; done
for SEED in $(seq 11 35); do one 7 $SEED; done
echo "soak ${C:-KEEP} pass=$P fail=$F"
