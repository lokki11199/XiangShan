#!/bin/bash
# Formal proof of TLQuiesceGate + TLResetIsolation + CoreResetCtrl (v5, models one-to-one with CoreReset.scala),
# for the two configurations of CoreResetKeepL1:
#   k   KEEP   (default)
#   s   sweep  (CFG_SWEEP)
# For each: prove (abc pdr, unbounded) with rstCycles = 100 (the default of CoreResetCtrl) and with 16;
# with rstCycles = 16 (RST16, shorter traces): cover, and every mutant that
# applies to the configuration must fail within 60 cycles (bmc); the equivalent mutants (see EQUIV) must pass
# the unbounded proof.
#   ./run_formal.sh [k|s ...]       (default: both)
# Engines: prove = abc pdr; mutants (bmc 60) = abc bmc3 (BMC_ENGINE=smtbmc selects smtbmc + SMT solver instead);
# a mutant not caught within 60 cycles is rerun with abc pdr (prove mode, reported with "(pdr)"). A mutant that abc
# refutes without naming the assertion is rerun with smtbmc to the depth of the failing step to get the label.
# Covers (default, COVER_ENGINE=assert): each cover Cn is run as the assertion !(Cn) (COVER_AS_ASSERT,
# COVER_ONLY=n) in prove mode with abc pdr: FAIL = cover reached ("step" = length of the trace found by pdr, not
# necessarily the shortest), PASS = not reachable (error). COVER_ENGINE=smtbmc: sby cover mode, depth 120.
# There is no separate design bmc: the unbounded proofs cover every depth (bmc 40 with abc / yices does not
# finish) and the covers show that the assumptions are satisfiable.
# Needs SymbiYosys (sby), yosys, yosys-abc and an SMT solver for yosys-smtbmc: tools from ../scripts/env.sh
# (OSS_CAD_SUITE or /opt/eda). Solver: SMT_SOLVER (default yices if installed, else boolector, else z3).
# Exit code = number of unexpected results.
cd "$(dirname "$0")"
. ../scripts/env.sh
SMT=${SMT_SOLVER:-$(if command -v yices-smt2 >/dev/null; then echo yices; elif command -v boolector >/dev/null; then echo boolector; else echo z3; fi)}
echo "tools: $(yosys -V 2>/dev/null | cut -d'(' -f1), abc pdr, smtbmc $SMT"
frames() {  # frames DIR: length of the counterexample (abc log, else the trace)
  local f; f=$(grep -o "asserted in frame [0-9]*" $1/logfile.txt | head -1 | grep -o "[0-9]*$")
  [ -z "$f" ] && [ -f $1/engine_0/trace.vcd ] && f=$(grep -c '^#' $1/engine_0/trace.vcd)
  echo "$f"
}
BMC_ENG="abc bmc3"; [ "$BMC_ENGINE" = smtbmc ] && BMC_ENG="smtbmc $SMT"
mk() {  # mk NAME DEFINES MODE [DEPTH [ENGINE]]
  local defs=""; for d in $2; do defs="$defs -D$d"; done
  cat > "$1.sby" <<EOT
[options]
mode $3
$( [ "$3" = cover ] && echo "depth 120" )
$( [ "$3" = bmc ] && echo "depth ${4:-60}" )
[engines]
$( if [ -n "$5" ]; then echo "$5"; elif [ "$3" = prove ]; then echo "abc pdr"; elif [ "$3" = bmc ]; then echo "$BMC_ENG"; else echo "smtbmc $SMT"; fi )
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
  echo "design      bmc: not run (the unbounded proofs with abc pdr cover every depth; the assumptions are shown satisfiable by the covers reached)"
  if [ "${COVER_ENGINE:-assert}" = assert ]; then
    # covers as assertions (abc pdr): FAIL = the cover is reached
    cov=""; ok=1
    for k in 1 2 3 4 5 6 7 8 9; do
      [ $k = 5 ] && [ $c = s ] && continue; [ $k = 7 ] && [ $c = k ] && continue
      n=${c}_cov$k; mk $n "$D16 COVER_AS_ASSERT COVER_ONLY=$k" prove; sby -f $n.sby >/dev/null 2>&1
      f=$(frames $n)
      if [ "$(res $n)" = FAIL ]; then cov="$cov C$k step $f,"; else ok=0; cov="$cov C$k NOT-REACHED($(res $n)),"; fi
    done
    echo "design      cover (as assert, abc pdr; step = length of the trace found by pdr, not necessarily the shortest): $([ $ok = 1 ] && echo PASS || echo FAIL) ($(echo "$cov" | tr ',' '\n' | grep -c ' step') reached:$cov)"; [ $ok = 1 ] || fails=$((fails+1))
  else
    mk ${c}_cover "$D16" cover; sby -f ${c}_cover.sby >/dev/null 2>&1; r=$(res ${c}_cover)
    # the engine log lists every cover reached (the summary shows only the first five)
    cov=$(grep "engine_0: ##.*Reached cover statement" ${c}_cover/logfile.txt | sed 's/.*in step \([0-9]*\) at fv_boundary: \(.*\)/\2 step \1/')
    echo "design      cover : $r ($(echo "$cov" | grep -c step) reached: $(echo "$cov" | tr '\n' ',' ))"; [ "$r" = PASS ] || fails=$((fails+1))
  fi
  for m in $(mutants $c); do
    n=${c}_mut_$(echo $m | tr 'A-Z' 'a-z')
    mk $n "$D16 $m" bmc; sby -f $n.sby >/dev/null 2>&1; r=$(res $n)
    why=$(grep -o "Assert failed in fv_boundary: [A-Za-z0-9_]*" $n/logfile.txt | head -4 | sed 's/.*: //' | sort -u | tr '\n' ' ')
    step=$(grep -o "Checking assertions in step [0-9]*" $n/logfile.txt | tail -1 | grep -o "[0-9]*$")
    if [ "$BMC_ENG" = "abc bmc3" ] && [ "$r" = FAIL ]; then
      step=$(frames $n)
      if [ -z "$why" ] && [ -n "$step" ]; then   # label: short smtbmc rerun up to the failing step
        mk ${n}_lbl "$D16 $m" bmc $((step+1)) "smtbmc $SMT"; sby -f ${n}_lbl.sby >/dev/null 2>&1
        why=$(grep -o "Assert failed in fv_boundary: [A-Za-z0-9_]*" ${n}_lbl/logfile.txt | head -4 | sed 's/.*: //' | sort -u | tr '\n' ' ')
      fi
    fi
    tag="bmc "
    if [ "$r" != FAIL ]; then   # not caught within 60 cycles: unbounded run
      mk ${n}_pdr "$D16 $m" prove; sby -f ${n}_pdr.sby >/dev/null 2>&1; r=$(res ${n}_pdr); tag="bmc 60 clean, (pdr)"
      step=$(frames ${n}_pdr)
      why=$(grep -o "Assert failed in fv_boundary: [A-Za-z0-9_]*" ${n}_pdr/logfile.txt | head -4 | sed 's/.*: //' | sort -u | tr '\n' ' ')
      if [ "$r" = FAIL ] && [ -z "$why" ] && [ -n "$step" ]; then
        mk ${n}_lbl "$D16 $m" bmc $((step+1)) "smtbmc $SMT"; sby -f ${n}_lbl.sby >/dev/null 2>&1
        why=$(grep -o "Assert failed in fv_boundary: [A-Za-z0-9_]*" ${n}_lbl/logfile.txt | head -4 | sed 's/.*: //' | sort -u | tr '\n' ' ')
      fi
    fi
    printf "%-32s %s: %s at cycle %s  %s\n" "$m" "$tag" "$r" "$step" "$why"
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
