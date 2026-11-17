#!/bin/bash
# Long random run of one configuration; the summary lines of every run go to results_soak_<cfg>.log,
# scripts/coverage.py adds them up.
#   scripts/soak.sh [FULL|CFG_KEEP]     (default FULL; "" means FULL)
#   scenarios 1-3, seeds 31..130                      300 runs
#   scenarios 1-3 with +SLOW, seeds 11..40             90 runs
#   scenario 5 (in-flight triggers), seeds 21..70      50 runs
#   scenarios 6 (directed Probes), 7 (long debug holds), 8 (sequences in a row), 9 (request dropped in every state),
#   seeds 11..35                                      100 runs
# = 540 runs; the last line: soak <cfg> pass=N fail=N.
# Do not start it while another process builds the same configuration (regress.sh builds mutants only).
cd "$(dirname "$0")/.."
N=${1:-FULL}; C=$N; [ "$N" = FULL ] && C=""
B=build/obj${C:+_$C}/Vcr_tb
[ -x $B ] || scripts/run.sh 1 1 "$C" > /dev/null
LOG=results_soak_$N.log
P=0; F=0; : > $LOG
one() {  # SCEN SEED [PLUSARGS]
  out=$(timeout 600 $B +SCEN=$1 +SEED=$2 $3 +verilator+seed+$2 +verilator+rand+reset+2 2>&1)
  echo "### SCEN=$1 SEED=$2 $3" >> $LOG
  echo "$out" | grep -E "^(config|final|txmon|probe-sb|triggers|directed|debug-hold|drain|iso:|b2b:|req-drop:|full:|RESULT)" >> $LOG
  if echo "$out" | grep -q "^RESULT: PASS$"; then P=$((P+1)); else F=$((F+1)); echo "FAIL $N SCEN=$1 SEED=$2 $3"; fi
}
for S in 1 2 3; do for SEED in $(seq 31 130); do one $S $SEED; done; done
for S in 1 2 3; do for SEED in $(seq 11 40); do one $S $SEED +SLOW; done; done
for SEED in $(seq 21 70); do one 5 $SEED; done
for S in 6 7 8 9; do for SEED in $(seq 11 35); do one $S $SEED; done; done
echo "soak $N pass=$P fail=$F"
