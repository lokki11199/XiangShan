#!/bin/bash
# Full regression over the two configurations (CoreResetKeepL1): "" (KEEP) and CFG_SWEEP. Every run prints one
# line; a correct design gives RESULT: PASS everywhere, the naive reset and every mutant run must report an
# error, the runs marked +EQUIV (mutants that cannot be observed) must PASS.
#   per configuration:
#   - random traffic: scenarios 1-3 x seeds 1-15, and with +SLOW x seeds 1-5
#   - SCEN 5: the procedure starts while a transaction of each class C1..C12 is in flight (10 seeds)
#   - SCEN 6: directed Probes (sReset, sRelease, after, start of sFlush, first cycle of sDrain, last cycle of
#     sFlush) (5 seeds)
#   - SCEN 7: debug reset held for a long time with snoops during the hold (5 seeds)
#   - SCEN 4: the naive reset (errors expected)
#   - mutants that apply to the configuration; the rare ones (simulation hits them only with some seeds) run on
#     the scen:seed lists of scripts/rare_seeds.txt (made by scripts/seedsearch.sh)
#   RESUME=<earlier results file>: a run already listed there is not repeated (its line is copied)
# Every core-side model drives random outputs for 1..4 cycles after the core reset is asserted (reset domain
# crossing); the isolation must hide them.
# Runs are sequential: the Verilator build of one configuration must never be made by two processes at once.
cd "$(dirname "$0")/.."
RARE=scripts/rare_seeds.txt
EQ=""   # set to "+EQUIV" for the expected-equivalent mutants
run() {  # CFG SCEN SEED [DEFINES] [PLUSARGS]
  local N=${1:-KEEP} D=$1${4:+${1:++}$4}
  local K="CFG=$N SCEN=$2 SEED=$3 ${5:+$5 }${4:+MUTANT=$4 }${EQ:+$EQ }:"
  if [ -n "$RESUME" ] && [ -f "$RESUME" ] && grep -qF -- "$K" "$RESUME"; then grep -F -- "$K" "$RESUME" | head -1; return; fi
  local R rc
  R=$(timeout 600 scripts/run.sh $2 $3 "$D" $5 2>&1); rc=$?
  R=$(echo "$R" | grep -E "^RESULT|TIMEOUT|%Error|ERROR|^final" | grep -v "Verilog \$stop" | tr '\n' ' ' | cut -c1-300)
  [ $rc = 124 ] && R="TIMEOUT(600s) $R"
  echo "$K $R"
}
mut() {  # CFG MUTANT "SCEN..." [SEEDS]: the mutant on each listed scenario, seeds 1-3 by default
  local C=$1 M=$2 SC=$3 SEEDS=${4:-1 2 3} S SEED
  for SEED in $SEEDS; do for S in $SC; do run "$C" $S $SEED $M; done; done
}
rare() {  # CFG MUTANT: scen:seed list from scripts/rare_seeds.txt
  local C=$1 M=$2 L P
  L=$(awk -v c="${C:-KEEP}" -v m="$M" '$1 == c && $2 == m { for (i = 3; i <= NF; i++) printf "%s ", $i }' $RARE 2>/dev/null)
  if [ -z "$L" ]; then echo "CFG=${C:-KEEP} MUTANT=$M : SKIPPED (no entry in $RARE, run scripts/seedsearch.sh)"; return; fi
  for P in $L; do run "$C" ${P%%:*} ${P##*:} $M; done
}
for C in "" CFG_SWEEP; do
  for S in 1 2 3; do for SEED in $(seq 1 15); do run "$C" $S $SEED; done; done
  for S in 1 2 3; do for SEED in $(seq 1 5); do run "$C" $S $SEED "" +SLOW; done; done
  for SEED in $(seq 1 10); do run "$C" 5 $SEED; done
  for SEED in $(seq 1 5); do run "$C" 6 $SEED; done
  for SEED in $(seq 1 5); do run "$C" 7 $SEED; done
  for SEED in 1 2 3; do run "$C" 4 $SEED; done
done
# ---- mutants (each run must report an error)
for C in "" CFG_SWEEP; do
  # quiet flag of the gates; the drain (KEEP: SCEN 2; sweep: SCEN 6, on SCEN 2 it may be equivalent there: after
  # the sweep only the Probe of the last cycle of sFlush is open in sDrain); stores in the flush
  mut "$C" GATE_MUTANT_ALWAYS_QUIET 2
  mut "$C" GATE_MUTANT_ALWAYS_QUIET+NO_CTRL_ASSERT 5
  case "$C" in "") ND=2 ;; *) ND=6 ;; esac
  mut "$C" CTRL_MUTANT_NO_DRAIN $ND
  mut "$C" CTRL_MUTANT_NO_DRAIN+NO_CTRL_ASSERT $ND
  mut "$C" FLUSH_MUTANT_NO_BLOCK 2
  mut "$C" FLUSH_MUTANT_NO_BLOCK+NO_CTRL_ASSERT 2
  # alive (DCache) and frontend reset waited for in sRelease
  mut "$C" CTRL_MUTANT_NO_ALIVE 5
  mut "$C" CTRL_MUTANT_NO_FE_WAIT 2
  # Probes held / answered until the end of sRelease
  mut "$C" CTRL_MUTANT_NO_HOLD_IN_RELEASE+NO_CTRL_ASSERT 6
  # reset domain crossing: isolation of C, E, D, the ICache control edge; isolate one cycle late / dropped with
  # the reset request
  for M in GATE_MUTANT_NO_ISO_C GATE_MUTANT_NO_ISO_E ISO_MUTANT_NO_ISO CTRL_MUTANT_ISO_LATE+NO_CTRL_ASSERT CTRL_MUTANT_ISO_EARLY_DROP+NO_CTRL_ASSERT; do
    mut "$C" $M 2
  done
  # flags of v5: quiet of the previous cycle, B closed late, early block / early quiet, reset leaves early
  mut "$C" CTRL_MUTANT_STALE_QUIET 6
  mut "$C" CTRL_MUTANT_LATE_HOLDB 6
  mut "$C" CTRL_MUTANT_NO_EARLY_BLOCK "2 5"
  mut "$C" CTRL_MUTANT_NO_EARLY_QUIET "2 5"
  mut "$C" CTRL_MUTANT_RESET_EARLY "3 7"
  # rare in simulation: these seeds hit them (scripts/seedsearch.sh)
  rare "$C" GATE_MUTANT_CUT_A+NO_CTRL_ASSERT
  rare "$C" FLUSH_MUTANT_NO_WBQ_WAIT+NO_CTRL_ASSERT
  # expected equivalent: the DCache idle flag is redundant with done + the gates' quiet
  EQ="+EQUIV"; mut "$C" CTRL_MUTANT_NO_L1_IDLE "2 6"; EQ=""
done
# KEEP: Probes held, meta on the tile reset, writes of the surviving arrays masked by freeze
mut "" GATE_MUTANT_NO_HOLDB "2 6"
mut "" META_MUTANT_CORE_RESET 2
mut "" META_MUTANT_CORE_RESET+NO_FREEZE_CHECK "2 6 7"
mut "" FREEZE_MUTANT_NO_SRAM_MASK "2 6"
rare "" FLUSH_MUTANT_NO_MP_WAIT
# sweep: every line released (with its data, all ways, the last ReleaseAck waited for); the gate answers NtoN
for M in FLUSH_MUTANT_NO_SWEEP FLUSH_MUTANT_SWEEP_NO_DATA FLUSH_MUTANT_SWEEP_ONE_WAY GATE_MUTANT_NO_ACKB CTRL_MUTANT_NOKEEP_HOLDB NOKEEP_MUTANT_META_KEPT; do
  mut CFG_SWEEP $M 2
done
mut CFG_SWEEP FLUSH_MUTANT_NO_SWEEP 6
mut CFG_SWEEP FLUSH_MUTANT_SWEEP_NO_WAIT 2
mut CFG_SWEEP FLUSH_MUTANT_SWEEP_NO_WAIT+NO_CTRL_ASSERT 5
mut CFG_SWEEP GATE_MUTANT_ACK_PARAM 5
# expected equivalent in the sweep: the MainPipe is empty after the sweep wait
EQ="+EQUIV"; mut CFG_SWEEP FLUSH_MUTANT_NO_MP_WAIT "2 5"; EQ=""
