#!/bin/bash
# Seed search for the mutants that simulation hits only now and then: finds the first 5 catching scen:seed
# (scenarios 2 and 5, seeds 1..30) and writes scripts/rare_seeds.txt, one line per configuration and mutant:
#   <KEEP|CFG_SWEEP> <MUTANT> <scen:seed> <scen:seed> ...      (read by scripts/regress.sh)
#   MUTANTS="M1 CFG_SWEEP:M2 ..."   overrides the list; an item is MUTANT (both configurations) or CFG:MUTANT
#   (CFG: KEEP | CFG_SWEEP). Entries of other mutants stay in the file.
cd "$(dirname "$0")/.."
OUT=scripts/rare_seeds.txt
DEFAULT="GATE_MUTANT_CUT_A+NO_CTRL_ASSERT FLUSH_MUTANT_NO_WBQ_WAIT+NO_CTRL_ASSERT KEEP:FLUSH_MUTANT_NO_MP_WAIT FLUSH_MUTANT_NO_BLOCK FLUSH_MUTANT_NO_BLOCK+NO_CTRL_ASSERT"
NEW=$(mktemp)
for ITEM in ${MUTANTS:-$DEFAULT}; do
  case "$ITEM" in
    *:*) CFGS=${ITEM%%:*}; M=${ITEM#*:} ;;
    *)   CFGS="KEEP CFG_SWEEP"; M=$ITEM ;;
  esac
  for N in $CFGS; do
    C=$N; [ "$N" = KEEP ] && C=""
    D=$C${C:++}$M; found=""; n=0
    for S in 2 5; do for SEED in $(seq 1 30); do
      [ $n -ge 5 ] && break 2
      r=$(timeout 300 scripts/run.sh $S $SEED "$D" 2>&1 | grep -cE "ERROR|%Error|TIMEOUT|RESULT: FAIL")
      if [ "$r" != 0 ]; then found="$found $S:$SEED"; n=$((n+1)); fi
    done; done
    echo "$N $M$found" | tee -a $NEW
  done
done
# merge: old entries of the mutants not searched this time stay
{ [ -f $OUT ] && awk 'NR == FNR { k[$1 " " $2] = 1; next } !(($1 " " $2) in k)' $NEW $OUT; cat $NEW; } > $OUT.tmp && mv $OUT.tmp $OUT
rm -f $NEW
