#!/bin/bash
# Full regression (v6) over the configurations of CoreResetKeepL1 and isoCycles: "" = FULL (the default), CFG_KEEP,
# and the isoCycles = 2 ones: ISO2 (FULL) and CFG_KEEP+ISO2. Names in the result lines: CFG=FULL, CFG=CFG_KEEP,
# CFG=ISO2, CFG=CFG_KEEP+ISO2. Every run prints one line; a correct design gives RESULT: PASS everywhere, the naive
# reset and every mutant run must report an error, the runs marked +EQUIV (mutants that cannot be observed) must PASS.
#   per configuration FULL and CFG_KEEP (93 runs each):
#   - random traffic: scenarios 1-3 x seeds 1-15, and with +SLOW x seeds 1-5
#   - SCEN 5: the procedure starts while a transaction of each class C1..C15 is in flight (10 seeds)
#   - SCEN 6: directed Probes (nine cases) (5 seeds)
#   - SCEN 7: debug reset held for a long time with snoops during the hold (5 seeds)
#   - SCEN 8: sequences in a row (5 seeds); SCEN 9: the request dropped / raised in every state (5 seeds)
#   - SCEN 4: the naive reset (errors expected, 3 seeds)
#   isoCycles = 2: CFG_KEEP+ISO2 scenarios 2, 5, 6, 8 x seeds 1-3 (12 runs), ISO2 scenarios 2, 6 x seeds 1-3 (6 runs)
#   204 design runs in all (6 naive). Then the mutants of TESTPLAN 4.4 (each run must report an error); the rare ones
#   (simulation hits them only with some seeds) run on the scen:seed lists of scripts/rare_seeds.txt (made by
#   scripts/seedsearch.sh on this Verilator version).
#   RESUME=<earlier results file>: a run already listed there is not repeated (its line is copied)
#   SKIP_DESIGN=1 / SKIP_MUTANTS=1: only the other half
# Every core-side model drives random outputs for 1..4 cycles after the core reset is asserted (reset domain
# crossing); the isolation must hide them.
# Runs are sequential: the Verilator build of one configuration must never be made by two processes at once.
cd "$(dirname "$0")/.."
RARE=scripts/rare_seeds.txt
EQ=""   # set to "+EQUIV" for the expected-equivalent mutants (frozen list, TESTPLAN 4.7); "+FORMALONLY": a mutant that is
        # silent in simulation but proved by a formal property (listed by regress_summary.py, not counted as a hole of the frozen list)
cfgname() { case "$1" in "") echo FULL;; *) echo "$1";; esac; }
run() {  # CFG SCEN SEED [DEFINES] [PLUSARGS]
  local N; N=$(cfgname "$1"); local D=$1${4:+${1:++}$4}
  local K="CFG=$N SCEN=$2 SEED=$3 ${5:+$5 }${4:+MUTANT=$4 }${EQ:+$EQ }${FO:+$FO }:"
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
  local C=$1 M=$2 L P N; N=$(cfgname "$C")
  L=$(awk -v c="$N" -v m="$M" '$1 == c && $2 == m { for (i = 3; i <= NF; i++) printf "%s ", $i }' $RARE 2>/dev/null)
  if [ -z "$L" ]; then echo "CFG=$N MUTANT=$M : SKIPPED (no entry in $RARE, run scripts/seedsearch.sh)"; return; fi
  for P in $L; do run "$C" ${P%%:*} ${P##*:} $M; done
}
if [ -z "$SKIP_DESIGN" ]; then
  for C in "" CFG_KEEP; do
    for S in 1 2 3; do for SEED in $(seq 1 15); do run "$C" $S $SEED; done; done
    for S in 1 2 3; do for SEED in $(seq 1 5); do run "$C" $S $SEED "" +SLOW; done; done
    for SEED in $(seq 1 10); do run "$C" 5 $SEED; done
    for S in 6 7 8 9; do for SEED in $(seq 1 5); do run "$C" $S $SEED; done; done
    for SEED in 1 2 3; do run "$C" 4 $SEED; done
  done
  for S in 2 5 6 8; do for SEED in 1 2 3; do run CFG_KEEP+ISO2 $S $SEED; done; done
  for S in 2 6; do for SEED in 1 2 3; do run ISO2 $S $SEED; done; done
fi
[ -n "$SKIP_MUTANTS" ] && exit 0
# ---- mutants (each run must report an error)
for C in "" CFG_KEEP; do
  # quiet flag of the gates, the drain, early block / early quiet, stale quiet, B closed late
  mut "$C" GATE_MUTANT_ALWAYS_QUIET 2
  mut "$C" GATE_MUTANT_ALWAYS_QUIET+NO_CTRL_ASSERT 5
  mut "$C" CTRL_MUTANT_NO_DRAIN 2
  mut "$C" CTRL_MUTANT_NO_DRAIN+NO_CTRL_ASSERT 2
  mut "$C" CTRL_MUTANT_NO_FE_WAIT 2
  mut "$C" CTRL_MUTANT_NO_HOLD_IN_RELEASE+NO_CTRL_ASSERT 6
  # reset domain crossing: isolation of C, E, D, the ICache control edge; isolate one cycle late / dropped with the
  # reset / not leading the reset
  for M in GATE_MUTANT_NO_ISO_C GATE_MUTANT_NO_ISO_E ISO_MUTANT_NO_ISO CTRL_MUTANT_ISO_LATE+NO_CTRL_ASSERT \
           CTRL_MUTANT_ISO_EARLY_DROP+NO_CTRL_ASSERT CTRL_MUTANT_NO_ISO_LEAD+NO_CTRL_ASSERT; do
    mut "$C" $M 2
  done
  mut "$C" CTRL_MUTANT_STALE_QUIET 6
  mut "$C" CTRL_MUTANT_LATE_HOLDB 6
  mut "$C" CTRL_MUTANT_NO_EARLY_BLOCK "2 5"
  mut "$C" CTRL_MUTANT_NO_EARLY_QUIET "2 5"
  mut "$C" CTRL_MUTANT_RESET_EARLY "3 7"
  # NO_REQ_IN_ISO: with isoCycles = 1 the DCache block drops a cycle after l1.req, that is in sReset: invisible in simulation,
  # caught by P23 (formal); the ISO2 configurations below see it (S18)
  FO="+FORMALONLY"; mut "$C" CTRL_MUTANT_NO_REQ_IN_ISO "2 5"; FO=""
  mut "$C" CTRL_MUTANT_LATE_HART_IN_RESET 1
  mut "$C" CTRL_MUTANT_BUSY_GAP 8
  mut "$C" CTRL_MUTANT_IN_RESET_WIDE 1
  # rare in simulation: these seeds hit them (scripts/seedsearch.sh)
  rare "$C" GATE_MUTANT_CUT_A+NO_CTRL_ASSERT
  rare "$C" QUIESCE_MUTANT_NO_WBQ_WAIT+NO_CTRL_ASSERT
  rare "$C" QUIESCE_MUTANT_NO_BLOCK
  rare "$C" QUIESCE_MUTANT_NO_BLOCK+NO_CTRL_ASSERT
  rare "$C" QUIESCE_MUTANT_NO_MP_WAIT
  rare "$C" QUIESCE_MUTANT_NO_MQ_WAIT
  # expected equivalent (frozen list, TESTPLAN 4.7): the DCache idle flag is redundant with done + the gates' quiet;
  # NO_ALIVE: in XSTile the frontend is the last of the ResetGen chain, after the DCache, so waiting for the frontend
  # also covers alive (the formal proof catches it: its environment allows any order)
  EQ="+EQUIV"; mut "$C" CTRL_MUTANT_NO_L1_IDLE "2 6"; mut "$C" CTRL_MUTANT_NO_ALIVE 5; EQ=""
done
# FULL: Probes answered by the gate in sReset / sRelease only, tags and meta cleared with the core
for M in GATE_MUTANT_NO_ACKB CTRL_MUTANT_NOKEEP_HOLDB CTRL_MUTANT_ACK_IN_ISO NOKEEP_MUTANT_META_KEPT; do mut "" $M "2 6"; done
mut "" GATE_MUTANT_ACK_PARAM "6 7"
# KEEP: Probes held, meta / error / tag on the tile reset, accesses of the surviving arrays masked by freeze
mut CFG_KEEP GATE_MUTANT_NO_HOLDB "2 6"
mut CFG_KEEP META_MUTANT_CORE_RESET 2
mut CFG_KEEP META_MUTANT_CORE_RESET+NO_FREEZE_CHECK "2 6 7"
for M in TAG_MUTANT_CORE_RESET FREEZE_MUTANT_NO_SRAM_MASK FREEZE_MUTANT_NO_READ_MASK CTRL_MUTANT_LATE_FREEZE; do mut CFG_KEEP $M "2 6"; done
# isoCycles = 2: the isolation must last two cycles
mut CFG_KEEP+ISO2 CTRL_MUTANT_ISO_SHORT 2
mut ISO2 CTRL_MUTANT_ISO_SHORT 2
mut CFG_KEEP+ISO2 CTRL_MUTANT_NO_REQ_IN_ISO 2
mut ISO2 CTRL_MUTANT_NO_REQ_IN_ISO 2
