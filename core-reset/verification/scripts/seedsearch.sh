#!/bin/bash
# Seed search for the mutants that simulation hits only now and then: finds the first 5 catching scen:seed
# (scenarios 2 and 5, seeds 1..30) and writes scripts/rare_seeds.txt, one line per configuration and mutant:
#   <FULL|CFG_KEEP> <MUTANT> <scen:seed> <scen:seed> ...      (read by scripts/regress.sh)
# The seeds depend on the model and on the Verilator version (v5 lists are not valid): run this before the first
# regression on a new machine / version, commit the new file and put it in the results and the PDF.
#   MUTANTS="M1 CFG_KEEP:M2 ..."   overrides the list; an item is MUTANT (both configurations) or CFG:MUTANT
#   (CFG: FULL | CFG_KEEP). Entries of other mutants stay in the file. A mutant without a catching seed gets a
#   line without seeds (regress.sh prints SKIPPED: a hole, report it).
cd "$(dirname "$0")/.."
OUT=scripts/rare_seeds.txt
DEFAULT="GATE_MUTANT_CUT_A+NO_CTRL_ASSERT QUIESCE_MUTANT_NO_WBQ_WAIT+NO_CTRL_ASSERT QUIESCE_MUTANT_NO_MP_WAIT QUIESCE_MUTANT_NO_BLOCK QUIESCE_MUTANT_NO_BLOCK+NO_CTRL_ASSERT"
NEW=$(mktemp)
for ITEM in ${MUTANTS:-$DEFAULT}; do
  case "$ITEM" in
    *:*) CFGS=${ITEM%%:*}; M=${ITEM#*:} ;;
    *)   CFGS="FULL CFG_KEEP"; M=$ITEM ;;
  esac
  for N in $CFGS; do
    C=$N; [ "$N" = FULL ] && C=""
    D=$C${C:++}$M; found=""; n=0
    # QUIESCE_MUTANT_NO_MP_WAIT is the rarest one: scenarios 2, 3, 5, seeds 1..120
    SCS="2 5"; SDS="$(seq 1 30)"
    case "$M" in QUIESCE_MUTANT_NO_MP_WAIT) SCS="5 2 3"; SDS="$(seq 1 120)";; esac
    for S in $SCS; do for SEED in $SDS; do
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
