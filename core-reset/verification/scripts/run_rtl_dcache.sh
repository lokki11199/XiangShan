#!/bin/bash
# RTL test of the real DCache with the real gate and the controller (TESTPLAN section 5).
#
#   scripts/run_rtl_dcache.sh elab [full] [keep]        elaboration of the Chisel bench (elab/CoreResetDCacheHarness.scala)
#                                                       into build/core_reset_elab/dcache_<full|keep>; both by default.
#                                                       The bench is copied into src/main/scala/xiangshan/ for the run
#                                                       and removed after (always). Then the checks of the port table
#                                                       (scripts/dcache_ports.py check) and the probes (mem_probes.py).
#   scripts/run_rtl_dcache.sh CFG CASE SEED [DEFINES]   one run; prints one line:
#       RTL CFG=<cfg> CASE=<case> SEED=<n> CTRL=<rtl|model[+mutant]> : RESULT: PASS ...|FAIL ERROR ...
#   CFG     FULL | KEEP | KEEP+ISO2 | FULL+ISO2   (ISO2: isoCycles = 2: controller CoreResetCtrl_*_iso2, define ISO2)
#   CASE    D1 .. D13 | R
#   DEFINES the controller model and its mutants, `+` separated, e.g. CTRL_MODEL+CTRL_MUTANT_LATE_FREEZE
#           (CTRL_MODEL alone = model without a mutant); without CTRL_MODEL the RTL controller from rtl/ is used.
# The Verilator build of one configuration (build/rtl_<cfg>[_<defines>]) is made once, under a lock (a second process
# waits instead of building the same directory), and redone when a source is newer than the binary. Never from two
# processes without the lock: do not remove it.
# env: RTL_TIMEOUT (seconds per run, 1800), VJ (Verilator -j, 4), NOCHECK=1 (skip the port-table check)
cd "$(dirname "$0")/.." || exit 2
V=$PWD
ROOT=$(cd ../.. && pwd)
. scripts/env.sh
ELAB=build/core_reset_elab

if [ "$1" = elab ]; then
  shift
  TARGETS=${*:-full keep}
  BENCH=CoreResetDCacheHarness.scala
  cp elab/$BENCH "$ROOT/src/main/scala/xiangshan/$BENCH" || exit 2
  trap 'rm -f "$ROOT/src/main/scala/xiangshan/$BENCH"' EXIT
  MILL_LOG=build/elab_dcache.log scripts/mill_retry.sh xiangshan.runMain xiangshan.CoreResetDCacheElab "$V/$ELAB" "$(echo $TARGETS | tr ' ' ',')" || exit 1
  rm -f "$ROOT/src/main/scala/xiangshan/$BENCH"
  rc=0
  for t in $TARGETS; do
    D=$ELAB/dcache_$t
    [ -f $D/params.svh ] || { echo "no $D/params.svh: the bench did not write the sizes"; rc=1; continue; }
    python3 scripts/dcache_ports.py check $D/params.svh $D || rc=1
    mkdir -p tb_rtl/gen
    python3 scripts/mem_probes.py $D $t tb_rtl/gen/mem_probes_$t.svh || rc=1
  done
  exit $rc
fi

CFG=$1; CASE=$2; SEED=${3:-1}; DEFS=${4:-}
[ -n "$CFG" ] && [ -n "$CASE" ] || { sed -n '2,20p' "$0"; exit 2; }
BASE=${CFG%%+*}; ISO2=0; [ "$CFG" != "$BASE" ] && [ "${CFG#*+}" = ISO2 ] && ISO2=1
case "$BASE" in FULL) T=full ;; KEEP) T=keep ;; *) echo "unknown CFG $CFG"; exit 2 ;; esac
TAG=$T; [ $ISO2 = 1 ] && TAG=${T}_iso2
D=$ELAB/dcache_$T
[ -f $D/params.svh ] || { echo "RTL CFG=$CFG CASE=$CASE SEED=$SEED : RESULT: FAIL ERROR no elaboration of the bench ($D); run: $0 elab"; exit 1; }

MODEL=0; case "+$DEFS+" in *+CTRL_MODEL+*) MODEL=1 ;; esac
if [ $MODEL = 1 ]; then CTRL="model"; [ -n "${DEFS#CTRL_MODEL}" ] && CTRL="model${DEFS#CTRL_MODEL}"; else CTRL=rtl; fi
DEFLIST=$(echo "$DEFS" | tr '+' ' ')
[ $ISO2 = 1 ] && DEFLIST="$DEFLIST ISO2"
OBJ=build/rtl_${TAG}${DEFS:+_$DEFS}
LOGDIR=build/rtl_logs; mkdir -p $LOGDIR build
LOG=$LOGDIR/${TAG}_${CASE}_${SEED}${DEFS:+_$DEFS}.log

# ---- build, once, under a lock
exec 9>$OBJ.lock
flock 9
SRC_TB="tb_rtl/rtl_l2.sv tb_rtl/dcache_tb.sv tb_rtl/dcache_drv.sv scripts/dcache_ports.py scripts/mem_probes.py"
STALE=0
for f in $SRC_TB $D/params.svh $(ls $D/*.sv $D/*.v 2>/dev/null) $(ls rtl/CoreResetCtrl_*.sv 2>/dev/null) model/cr_ctl_models.sv; do
  [ -f "$f" ] && [ "$f" -nt $OBJ/Vdcache_tb ] && STALE=1
done
if [ ! -x $OBJ/Vdcache_tb ] || [ $STALE = 1 ]; then
  rm -rf $OBJ; mkdir -p $OBJ/inc
  cp $D/params.svh $OBJ/inc/params.svh
  python3 scripts/dcache_ports.py decl $OBJ/inc/params.svh $OBJ/inc/dut_decl.svh &&
  python3 scripts/dcache_ports.py inst $OBJ/inc/params.svh $OBJ/inc/dut_inst.svh || { echo "RTL CFG=$CFG CASE=$CASE SEED=$SEED CTRL=$CTRL : RESULT: FAIL ERROR port table"; exit 1; }
  if [ -z "$NOCHECK" ]; then
    python3 scripts/dcache_ports.py check $OBJ/inc/params.svh $D > $OBJ/ports_check.log 2>&1 ||
      { cat $OBJ/ports_check.log; echo "RTL CFG=$CFG CASE=$CASE SEED=$SEED CTRL=$CTRL : RESULT: FAIL ERROR the port table does not match the RTL"; exit 1; }
  fi
  python3 scripts/mem_probes.py $D $T $OBJ/inc/mem_probes.svh > $OBJ/probes.log 2>&1 ||
    { cat $OBJ/probes.log; echo "RTL CFG=$CFG CASE=$CASE SEED=$SEED CTRL=$CTRL : RESULT: FAIL ERROR no memory probes (K5 would be empty)"; exit 1; }
  mkdir -p tb_rtl/gen; cp $OBJ/inc/mem_probes.svh tb_rtl/gen/mem_probes_$T.svh
  CTLMOD=CoreResetCtrl_$T; [ $ISO2 = 1 ] && CTLMOD=${CTLMOD}_iso2
  DUT_FILES=$(ls $D/*.sv $D/*.v 2>/dev/null | grep -v '/params.svh$')
  if [ $MODEL = 1 ]; then CTL_FILES=model/cr_ctl_models.sv; CTL_DEF=; else CTL_FILES=rtl/$CTLMOD.sv; CTL_DEF=-DCTRL_MOD=$CTLMOD; fi
  VDEFS=$(for d in $DEFLIST; do printf -- '-D%s ' "$d"; done)
  verilator --binary --timing --assert -j ${VJ:-4} -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
    -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-LATCH -Wno-UNOPTFLAT \
    -Wno-PROCASSINIT -Wno-IMPORTSTAR -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-VARHIDDEN \
    --x-initial unique --x-assign unique -DRANDOMIZE_REG_INIT -DRANDOMIZE_MEM_INIT $VDEFS $CTL_DEF \
    -I$OBJ/inc -Itb_rtl -Irtl --top-module dcache_tb -Mdir $OBJ \
    tb_rtl/rtl_l2.sv $DUT_FILES $CTL_FILES tb_rtl/dcache_tb.sv > $OBJ.log 2>&1 ||
    { grep -E "%Error" $OBJ.log | head -30; echo "RTL CFG=$CFG CASE=$CASE SEED=$SEED CTRL=$CTRL : RESULT: FAIL ERROR Verilator build ($OBJ.log)"; exit 1; }
fi
flock -u 9

# ---- run
timeout ${RTL_TIMEOUT:-1800} $OBJ/Vdcache_tb +CASE=$CASE +SEED=$SEED +verilator+seed+$SEED +verilator+rand+reset+2 > $LOG 2>&1
RC=$?
RES=$(grep -E "^RESULT:" $LOG | tail -1)
# K9: asserts of the RTL (DCache, gate, controller, XS assert) and Verilator errors
K9=$(grep -E "Assertion failed|%Error|\[ERROR\]|Assertion .*failed|\\\$fatal|Fatal" $LOG | head -1)
FIRST=$(grep -E "^ERROR " $LOG | head -1)
if [ -n "$K9" ]; then
  echo "RTL CFG=$CFG CASE=$CASE SEED=$SEED CTRL=$CTRL : RESULT: FAIL ERROR K9 $K9"
elif [ -z "$RES" ]; then
  echo "RTL CFG=$CFG CASE=$CASE SEED=$SEED CTRL=$CTRL : RESULT: FAIL ERROR no RESULT line (rc=$RC${FIRST:+; $FIRST})"
elif echo "$RES" | grep -q "RESULT: PASS"; then
  echo "RTL CFG=$CFG CASE=$CASE SEED=$SEED CTRL=$CTRL : $RES"
else
  echo "RTL CFG=$CFG CASE=$CASE SEED=$SEED CTRL=$CTRL : RESULT: FAIL ERROR ${FIRST:-$RES}"
fi
