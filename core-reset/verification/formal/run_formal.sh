#!/bin/bash
# Formal proof of TLQuiesceGate + TLResetIsolation + CoreResetCtrl (v5, models one-to-one with CoreReset.scala),
# for the two configurations of CoreResetKeepL1:
#   k   KEEP   (default)
#   s   sweep  (CFG_SWEEP)
# For each: prove (abc pdr, unbounded) with rstCycles = 100 (the default of CoreResetCtrl) and with 16;
# with rstCycles = 16 (RST16, shorter traces): bmc 40 (assumptions satisfiable), cover, and every mutant that
# applies to the configuration must fail within 60 cycles (bmc); the equivalent mutants (see EQUIV) must pass
# the unbounded proof.
#   ./run_formal.sh [k|s ...]       (default: both)
# Needs SymbiYosys (sby), yosys, yosys-abc and an SMT solver for yosys-smtbmc: tools from ../scripts/env.sh
# (OSS_CAD_SUITE or /opt/eda). Solver: SMT_SOLVER (default yices if installed, else boolector, else z3).
# Exit code = number of unexpected results.
cd "$(dirname "$0")"
. ../scripts/env.sh
SMT=${SMT_SOLVER:-$(if command -v yices-smt2 >/dev/null; then echo yices; elif command -v boolector >/dev/null; then echo boolector; else echo z3; fi)}
echo "tools: $(yosys -V 2>/dev/null | cut -d'(' -f1), abc pdr, smtbmc $SMT"
mk() {  # mk NAME DEFINES MODE [DEPTH]
  local defs=""; for d in $2; do defs="$defs -D$d"; done
  cat > "$1.sby" <<EOT
[options]
mode $3
$( [ "$3" = cover ] && echo "depth 120" )
$( [ "$3" = bmc ] && echo "depth ${4:-60}" )
[engines]
$( [ "$3" = prove ] && echo "abc pdr" || echo "smtbmc $SMT" )
[script]
read -formal -sv -DFORMAL $defs cr_ctl_models.sv
read -formal -sv -DFORMAL $defs fv_boundary.sv
prep -top fv_boundary
[files]
../model/cr_ctl_models.sv
fv_boundary.sv
EOT
}
res() { tail -1 "$1/status" 2>/dev/null | awk '{print $1}'; }
cfgdefs() { case $1 in k) echo "";; s) echo "CFG_SWEEP";; esac; }
cfgname() { case $1 in k) echo "KEEP";; s) echo "sweep";; esac; }
mutants() {
  local common="CTRL_MUTANT_NO_DRAIN CTRL_MUTANT_STALE_QUIET CTRL_MUTANT_NO_L1_IDLE CTRL_MUTANT_NO_ALIVE CTRL_MUTANT_NO_FE_WAIT CTRL_MUTANT_NO_EARLY_QUIET CTRL_MUTANT_NO_EARLY_BLOCK CTRL_MUTANT_LATE_HOLDB CTRL_MUTANT_NO_HOLD_IN_RELEASE CTRL_MUTANT_RESET_EARLY CTRL_MUTANT_ISO_LATE CTRL_MUTANT_ISO_EARLY_DROP GATE_MUTANT_ALWAYS_QUIET GATE_MUTANT_CUT_A GATE_MUTANT_NO_ISO_C GATE_MUTANT_NO_ISO_D GATE_MUTANT_NO_ISO_E ISO_MUTANT_NO_ISO"
  case $1 in
    k) echo "$common GATE_MUTANT_NO_HOLDB";;
    s) echo "$common GATE_MUTANT_NO_ACKB GATE_MUTANT_ACK_PARAM CTRL_MUTANT_NOKEEP_HOLDB";;
  esac
}
# equivalent mutants: channel A is also closed by the gate's block (high from sDrain on, and the drain leaves A at
# a message boundary); TLResetIsolation.quiet duplicates the counter of the client-side gate (only the core's own
# MMIO reaches the ICache control registers). Both are kept in the design as explicit masks.
EQUIV="GATE_MUTANT_NO_ISO_A ISO_MUTANT_ALWAYS_QUIET"
fails=0
CFGS=${*:-k s}
for c in $CFGS; do
  D=$(cfgdefs $c)
  echo "=== configuration $c: $(cfgname $c)${D:+ (-D $D)}"
  for R in 100 16; do
    RD=$D; [ $R = 16 ] && RD="$D RST16"
    mk ${c}_prove$R "$RD" prove; sby -f ${c}_prove$R.sby >/dev/null 2>&1; r=$(res ${c}_prove$R)
    echo "design prove rstCycles=$R (abc pdr, unbounded): $r  ($(grep -o "Time = *[0-9.]* sec" ${c}_prove$R/logfile.txt | tail -1 | sed "s/Time = *//"))"; [ "$r" = PASS ] || fails=$((fails+1))
  done
  D16="$D RST16"
  mk ${c}_bmc "$D16" bmc 40; sby -f ${c}_bmc.sby >/dev/null 2>&1; r=$(res ${c}_bmc)
  echo "design      bmc 40: $r (assumptions satisfiable: $(grep -q PREUNSAT ${c}_bmc/logfile.txt && echo NO || echo yes))"; [ "$r" = PASS ] || fails=$((fails+1))
  mk ${c}_cover "$D16" cover; sby -f ${c}_cover.sby >/dev/null 2>&1; r=$(res ${c}_cover)
  # the engine log lists every cover reached (the summary shows only the first five)
  cov=$(grep "engine_0: ##.*Reached cover statement" ${c}_cover/logfile.txt | sed 's/.*in step \([0-9]*\) at fv_boundary: \(.*\)/\2 step \1/')
  echo "design      cover : $r ($(echo "$cov" | grep -c step) reached: $(echo "$cov" | tr '\n' ',' ))"; [ "$r" = PASS ] || fails=$((fails+1))
  for m in $(mutants $c); do
    n=${c}_mut_$(echo $m | tr 'A-Z' 'a-z')
    mk $n "$D16 $m" bmc; sby -f $n.sby >/dev/null 2>&1; r=$(res $n)
    why=$(grep -o "Assert failed in fv_boundary: [A-Za-z0-9_]*" $n/logfile.txt | head -4 | sed 's/.*: //' | sort -u | tr '\n' ' ')
    step=$(grep -o "Checking assertions in step [0-9]*" $n/logfile.txt | tail -1 | grep -o "[0-9]*$")
    printf "%-32s bmc : %s at cycle %s  %s\n" "$m" "$r" "$step" "$why"
    [ "$r" = FAIL ] || fails=$((fails+1))
  done
  for m in $EQUIV; do
    n=${c}_eq_$(echo $m | tr 'A-Z' 'a-z')
    mk $n "$D $m" prove; sby -f $n.sby >/dev/null 2>&1; r=$(res $n)
    printf "%-32s prove: %s (equivalent mutant, expected PASS)\n" "$m" "$r"
    [ "$r" = PASS ] || fails=$((fails+1))
  done
done
echo "formal: $fails unexpected result(s)"
exit $fails
