#!/bin/bash
# Formal proof of TLQuiesceGate + TLResetIsolation + CoreResetCtrl (v6, models one-to-one with CoreReset.scala).
# Configurations (CoreResetKeepL1, isoCycles):
#   f   FULL  (CoreResetKeepL1 = false, default)   isoCycles = 1
#   k   KEEP  (CFG_KEEP)                           isoCycles = 1
#   f2  FULL, isoCycles = 2 (ISO2)                 k2  KEEP, isoCycles = 2 (CFG_KEEP ISO2)
# and the mode `adapters`: fv_adapters.sv (the isolation of the three adapters alone, free control inputs).
#   ./run_formal.sh [f|k|f2|k2|adapters ...]     (default: f k)
# `f` runs f and then f2, `k` runs k and then k2 (the lines of f2 / k2 follow those of f / k; results_formal_f.txt /
# results_formal_k.txt); an explicit f2 / k2 runs only that one.
# For each of f, k: prove (abc pdr, unbounded) with rstCycles = 100 (the default of CoreResetCtrl) and with 16;
# with rstCycles = 16 (RST16, shorter traces): covers, and every mutant that applies to the configuration must fail
# within 60 cycles (bmc); the equivalent mutants (see EQUIV) must pass the unbounded proof.
# f2, k2: prove with rstCycles = 16, cover C14, mutants CTRL_MUTANT_ISO_SHORT and CTRL_MUTANT_NO_ISO_LEAD.
# adapters: prove, then 10 mutants (bmc 30, then pdr), none equivalent.
# Engines: prove = abc pdr; mutants (bmc) = abc bmc3 (BMC_ENGINE=smtbmc selects smtbmc + SMT solver instead);
# a mutant not caught within the depth (60; adapters 30) or MUT_TIMEOUT (300 s) is rerun with abc pdr (prove mode,
# reported with "(pdr)"). A mutant that abc refutes without naming the assertion is rerun with smtbmc to the depth of
# the failing step to get the label.
# Covers (default, COVER_ENGINE=assert): each cover Cn is run as the assertion !(Cn) (COVER_AS_ASSERT,
# COVER_ONLY=n) in prove mode with abc pdr: FAIL = cover reached ("step" = length of the trace found by pdr, not
# necessarily the shortest), PASS = not reachable (error). COVER_ENGINE=smtbmc: sby cover mode, depth 120.
# There is no separate design bmc: the unbounded proofs cover every depth (bmc 40 with abc / yices does not
# finish) and the covers show that the assumptions are satisfiable.
# Needs SymbiYosys (sby), yosys, yosys-abc and an SMT solver for yosys-smtbmc: tools from ../scripts/env.sh
# (OSS_CAD_SUITE or /opt/eda). Solver: SMT_SOLVER (default yices if installed, else boolector, else z3).
# QUICK=1: only the prove with rstCycles = 16 of f and k (no f2 / k2, no prove 100, covers, mutants, EQUIV); in the
# `adapters` mode only the prove.
# PROVE_TIMEOUT (default 3600 s): wall-clock limit of every prove; a timeout is an unexpected result (TIMEOUT).
# Exit code = number of unexpected results.
# Result lines (parsed by doc/results.py):
#   design prove rstCycles=16 isoCycles=2 (abc pdr, unbounded): PASS  (12.3 sec)      (isoCycles=1: no such field)
#   adapters prove (abc pdr, unbounded): PASS  (4.1 sec)
#   GATE_MUTANT_NO_ISO_B             adapters bmc : FAIL at cycle 3  L1_tlc_isolation
cd "$(dirname "$0")"
. ../scripts/env.sh
SMT=${SMT_SOLVER:-$(if command -v yices-smt2 >/dev/null; then echo yices; elif command -v boolector >/dev/null; then echo boolector; else echo z3; fi)}
echo "tools: $(yosys -V 2>/dev/null | cut -d'(' -f1), abc pdr, smtbmc $SMT"
PROVE_TIMEOUT=${PROVE_TIMEOUT:-3600}
MUT_TIMEOUT=${MUT_TIMEOUT:-300}   # wall-clock limit (s) of the bmc run of one mutant; then abc pdr
TOP=fv_boundary                    # top module and file of the current mk() runs
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
read -formal -sv -DFORMAL $defs $TOP.sv
prep -top $TOP
[files]
../model/cr_ctl_models.sv
$TOP.sv
EOT
}
res() { tail -1 "$1/status" 2>/dev/null | awk '{print $1}'; }
proveit() {  # proveit NAME: runs the sby file with the prove timeout, prints the result word
  timeout $PROVE_TIMEOUT sby -f $1.sby >/dev/null 2>&1; local rc=$?
  if [ $rc = 124 ]; then echo TIMEOUT; else res $1; fi
}
ptime() { grep -o "Time = *[0-9.]* sec" $1/logfile.txt 2>/dev/null | tail -1 | sed "s/Time = *//"; }
cfgdefs() { case $1 in f) echo "";; k) echo "CFG_KEEP";; f2) echo "ISO2";; k2) echo "CFG_KEEP ISO2";; esac; }
cfgname() { case $1 in f) echo "FULL";; k) echo "KEEP";; f2) echo "FULL iso2";; k2) echo "KEEP iso2";; esac; }
mutants() {
  local common="CTRL_MUTANT_NO_DRAIN CTRL_MUTANT_STALE_QUIET CTRL_MUTANT_NO_L1_IDLE CTRL_MUTANT_NO_ALIVE CTRL_MUTANT_NO_FE_WAIT CTRL_MUTANT_NO_EARLY_QUIET CTRL_MUTANT_NO_EARLY_BLOCK CTRL_MUTANT_LATE_HOLDB CTRL_MUTANT_NO_HOLD_IN_RELEASE CTRL_MUTANT_RESET_EARLY CTRL_MUTANT_ISO_LATE CTRL_MUTANT_ISO_EARLY_DROP CTRL_MUTANT_NO_ISO_LEAD CTRL_MUTANT_NO_REQ_IN_ISO CTRL_MUTANT_LATE_HART_IN_RESET CTRL_MUTANT_BUSY_GAP CTRL_MUTANT_IN_RESET_WIDE GATE_MUTANT_ALWAYS_QUIET GATE_MUTANT_CUT_A GATE_MUTANT_NO_ISO_C GATE_MUTANT_NO_ISO_D GATE_MUTANT_NO_ISO_E ISO_MUTANT_NO_ISO"
  case $1 in
    f) echo "$common GATE_MUTANT_NO_ACKB GATE_MUTANT_ACK_PARAM CTRL_MUTANT_NOKEEP_HOLDB CTRL_MUTANT_ACK_IN_ISO";;       # 27
    k) echo "$common GATE_MUTANT_NO_HOLDB CTRL_MUTANT_LATE_FREEZE";;                                                   # 25
    f2|k2) echo "CTRL_MUTANT_ISO_SHORT CTRL_MUTANT_NO_ISO_LEAD";;
  esac
}
adapter_mutants="GATE_MUTANT_NO_ISO_A GATE_MUTANT_NO_ISO_B GATE_MUTANT_NO_ISO_C GATE_MUTANT_NO_ISO_D GATE_MUTANT_NO_ISO_E GATE_MUTANT_ALWAYS_QUIET GATE_MUTANT_CUT_A GATE_MUTANT_ACK_PARAM ISO_MUTANT_NO_ISO ISO_MUTANT_ALWAYS_QUIET"
covers() {  # covers CFG: the covers of the configuration (C3 KEEP only; C7, C13 FULL only; C14 iso2 only)
  case $1 in
    f) echo "1 2 4 5 6 7 8 9 10 11 12 13";;
    k) echo "1 2 3 4 5 6 8 9 10 11 12";;
    f2|k2) echo "14";;
  esac
}
# equivalent mutants: channel A is also closed by the gate's block (high from sDrain on, and the drain leaves A at
# a message boundary); TLResetIsolation.quiet duplicates the counter of the client-side gate (only the core's own
# MMIO reaches the ICache control registers). Both are kept in the design as explicit masks. (GATE_MUTANT_NO_ISO_B
# is equivalent here too, by P17, but it is run only in the adapters mode, where it must fail: user decision, not
# added to this frozen list.)
EQUIV="GATE_MUTANT_NO_ISO_A ISO_MUTANT_ALWAYS_QUIET"
fails=0

# mutant_run NAME_PREFIX DEFINES MUTANT DEPTH WHICH: bmc (depth) then pdr; prints one result line, counts unexpected
mutant_run() {
  local pre=$1 D=$2 m=$3 depth=$4 which=$5 n r why step tag
  n=${pre}_mut_$(echo $m | tr 'A-Z' 'a-z')
  rm -rf $n; mk $n "$D $m" bmc $depth; timeout $MUT_TIMEOUT sby -f $n.sby >/dev/null 2>&1; r=$(res $n)
  why=$(grep -o "Assert failed in $TOP: [A-Za-z0-9_]*" $n/logfile.txt | head -4 | sed 's/.*: //' | sort -u | tr '\n' ' ')
  step=$(grep -o "Checking assertions in step [0-9]*" $n/logfile.txt | tail -1 | grep -o "[0-9]*$")
  if [ "$BMC_ENG" = "abc bmc3" ] && [ "$r" = FAIL ]; then
    step=$(frames $n)
    if [ -z "$why" ] && [ -n "$step" ]; then   # label: short smtbmc rerun up to the failing step
      mk ${n}_lbl "$D $m" bmc $((step+1)) "smtbmc $SMT"; sby -f ${n}_lbl.sby >/dev/null 2>&1
      why=$(grep -o "Assert failed in $TOP: [A-Za-z0-9_]*" ${n}_lbl/logfile.txt | head -4 | sed 's/.*: //' | sort -u | tr '\n' ' ')
    fi
  fi
  tag="${which}bmc "
  if [ "$r" != FAIL ]; then   # not caught within the depth / the time limit: unbounded run
    mk ${n}_pdr "$D $m" prove; r=$(proveit ${n}_pdr); tag="${which}bmc $depth clean or >${MUT_TIMEOUT}s, (pdr)"
    step=$(frames ${n}_pdr)
    why=$(grep -o "Assert failed in $TOP: [A-Za-z0-9_]*" ${n}_pdr/logfile.txt | head -4 | sed 's/.*: //' | sort -u | tr '\n' ' ')
    if [ "$r" = FAIL ] && [ -z "$why" ] && [ -n "$step" ]; then
      mk ${n}_lbl "$D $m" bmc $((step+1)) "smtbmc $SMT"; sby -f ${n}_lbl.sby >/dev/null 2>&1
      why=$(grep -o "Assert failed in $TOP: [A-Za-z0-9_]*" ${n}_lbl/logfile.txt | head -4 | sed 's/.*: //' | sort -u | tr '\n' ' ')
    fi
  fi
  printf "%-32s %s: %s at cycle %s  %s\n" "$m" "$tag" "$r" "$step" "$why"
  [ "$r" = FAIL ] || fails=$((fails+1))
}

run_cfg() {  # run_cfg CFG
  local c=$1 D R RD D16 n k m r cov ok f
  D=$(cfgdefs $c)
  echo "=== configuration $c: $(cfgname $c)${D:+ (-D $D)}"
  case $c in f2|k2) local rsts="16";; *) local rsts=$([ -n "$QUICK" ] && echo 16 || echo 100 16);; esac
  for R in $rsts; do
    RD=$D; [ $R = 16 ] && RD="$D RST16"
    mk ${c}_prove$R "$RD" prove; r=$(proveit ${c}_prove$R)
    case $c in f2|k2) local isof=" isoCycles=2";; *) local isof="";; esac
    echo "design prove rstCycles=$R$isof (abc pdr, unbounded): $r  ($(ptime ${c}_prove$R))"; [ "$r" = PASS ] || fails=$((fails+1))
  done
  D16="$D RST16"
  [ -n "$QUICK" ] && return
  [ "$c" = f ] || [ "$c" = k ] && echo "design      bmc: not run (the unbounded proofs with abc pdr cover every depth; the assumptions are shown satisfiable by the covers reached)"
  if [ "${COVER_ENGINE:-assert}" = assert ]; then
    # covers as assertions (abc pdr): FAIL = the cover is reached
    cov=""; ok=1
    for k in $(covers $c); do
      n=${c}_cov$k; mk $n "$D16 COVER_AS_ASSERT COVER_ONLY=$k" prove; r=$(proveit $n)
      f=$(frames $n)
      if [ "$r" = FAIL ]; then cov="$cov C$k step $f,"; else ok=0; cov="$cov C$k NOT-REACHED($r),"; fi
    done
    echo "design      cover (as assert, abc pdr; step = length of the trace found by pdr, not necessarily the shortest): $([ $ok = 1 ] && echo PASS || echo FAIL) ($(echo "$cov" | tr ',' '\n' | grep -c ' step') reached:$cov)"; [ $ok = 1 ] || fails=$((fails+1))
  else
    mk ${c}_cover "$D16" cover; sby -f ${c}_cover.sby >/dev/null 2>&1; r=$(res ${c}_cover)
    # the engine log lists every cover reached (the summary shows only the first five)
    cov=$(grep "engine_0: ##.*Reached cover statement" ${c}_cover/logfile.txt | sed 's/.*in step \([0-9]*\) at fv_boundary: \(.*\)/\2 step \1/')
    echo "design      cover : $r ($(echo "$cov" | grep -c step) reached: $(echo "$cov" | tr '\n' ',' ))"; [ "$r" = PASS ] || fails=$((fails+1))
  fi
  for m in $(mutants $c); do mutant_run $c "$D16" $m 60 ""; done
  case $c in f2|k2) return;; esac
  for m in $EQUIV; do
    n=${c}_eq_$(echo $m | tr 'A-Z' 'a-z')
    mk $n "$D $m" prove; r=$(proveit $n)
    printf "%-32s prove: %s (equivalent mutant, expected PASS)\n" "$m" "$r"
    [ "$r" = PASS ] || fails=$((fails+1))
  done
}

run_adapters() {
  local r m n f0=$fails
  TOP=fv_adapters
  echo "=== adapters: fv_adapters (isolation of the three adapters, free control inputs)"
  mk adapters_prove "" prove; r=$(proveit adapters_prove)
  echo "adapters prove (abc pdr, unbounded): $r  ($(ptime adapters_prove))"; [ "$r" = PASS ] || fails=$((fails+1))
  if [ -z "$QUICK" ]; then
    for m in $adapter_mutants; do mutant_run adapters "" $m 30 "adapters "; done
    echo "adapters: $((fails-f0)) unexpected result(s)"
  fi
  TOP=fv_boundary
}

CFGS=${*:-f k}
mode_adapters=0; ran_cfg=0
for c in $CFGS; do
  case $c in
    adapters) mode_adapters=1;;
    f|k) ran_cfg=1; run_cfg $c; [ -z "$QUICK" ] && case " $CFGS " in *" ${c}2 "*) ;; *) run_cfg ${c}2;; esac;;
    f2|k2) ran_cfg=1; run_cfg $c;;
    *) echo "unknown configuration $c (f k f2 k2 adapters)"; fails=$((fails+1));;
  esac
done
[ $mode_adapters = 1 ] && run_adapters
[ $ran_cfg = 1 ] && echo "formal: $fails unexpected result(s)"
exit $fails
