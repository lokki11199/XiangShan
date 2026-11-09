#!/bin/bash
# Single entry point of the core-reset verification.
#   core-reset/verification/check.sh --quick | --full [--skip-elab-noc] [--write-results] [--dirty]
# Run from anywhere. One line per step: `STEP <name>: PASS|FAIL|SKIP (<time>s) <detail>`; the full log of a step
# is build/check/<name>.log (below this directory). At the end a summary table; exit code = number of failed
# steps, 2 = refused to start. Checks run on the committed and pushed state only: the script refuses to start
# (exit 2) if src/ or core-reset/verification/ has uncommitted changes (build/, results files, local run
# files excepted) or HEAD is not origin/core-reset-v5, unless --dirty is given.
#
# --quick (about 10 min):
#   compile        mill xiangshan.compile                                         ~5 min
#   elab_modules   CoreResetElab (ctrl_keep, ctrl_sweep, gates), extract_rtl.py, rtl/ must equal the committed
#                  rtl/ (the harness is copied into src/ for the run and removed afterwards)   ~3 min
#   smoke          scenarios 1 2 3 5 6 7, seed 1, KEEP and CFG_SWEEP, each RESULT: PASS      ~1 min
#   formal_quick   QUICK=1 formal/run_formal.sh k s (prove rstCycles=16 only)               ~20 s
# --full: the quick steps plus
#   formal         formal/run_formal.sh k s (k and s in parallel)                           ~1.5 h
#   equiv          formal/run_equiv.sh (Chisel RTL vs models)                               minutes
#   regress        scripts/regress.sh + regress_summary.py                                  ~1 h
#   soak           scripts/soak.sh "" and CFG_SWEEP (parallel), coverage.py                 ~1 h
#   elab_noc       full elaboration of XSNoCTop, KEEP then SWEEP, never together with regress/soak
#                  (memory): `make verilog` ~25 min per configuration, ~9 GB peak; skipped by --skip-elab-noc
# Result files of the package (results_*.txt, coverage_*.json, regress_summary.txt) are written only with
# --write-results; otherwise the same output goes to build/check. (regress.sh / soak.sh keep their own
# results_regress / results_soak_<cfg>.log convention for the soak logs.)
# Tools: scripts/env.sh (OSS_CAD_SUITE, else EDA_PREFIX=/opt/eda, plus /opt/fv/bin for yices).
# mill: scripts/mill_retry.sh retries on Maven Central HTTP 429 / download errors (Google mirror).
# Environment: JVM_XMX (default 7G) for the XSNoCTop elaboration.
VER=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$VER/../.." && pwd)
LOG=$VER/build/check
MODE=""; SKIP_NOC=0; WRITE=0; DIRTY=0
for a in "$@"; do
  case $a in
    --quick) MODE=quick;; --full) MODE=full;; --skip-elab-noc) SKIP_NOC=1;;
    --write-results) WRITE=1;; --dirty) DIRTY=1;;
    *) echo "unknown option $a"; MODE="";; esac
done
[ -z "$MODE" ] && { echo "usage: check.sh --quick | --full [--skip-elab-noc] [--write-results] [--dirty]"; exit 2; }
cd "$ROOT" || exit 2
. "$VER/scripts/env.sh"

# ---- state of the tree
HEAD=$(git rev-parse --short HEAD); ORIGIN=$(git rev-parse --short origin/core-reset-v5 2>/dev/null)
echo "HEAD $HEAD, origin/core-reset-v5 ${ORIGIN:-unknown}: $([ "$HEAD" = "$ORIGIN" ] && echo "HEAD is pushed" || echo "HEAD differs from origin")"
CH=$(git status --porcelain -- src core-reset/verification | grep -vE '/build/|results_|coverage_|regress_summary|seedsearch|soak_|ALLDONE|\.out$|\.before$|\.resume$')
if [ $DIRTY = 0 ]; then
  [ -n "$CH" ] && { echo "refused: uncommitted changes (commit and push first, or --dirty):"; echo "$CH"; exit 2; }
  [ "$HEAD" != "$ORIGIN" ] && { echo "refused: HEAD is not pushed to origin/core-reset-v5 (or --dirty)"; exit 2; }
fi
mkdir -p "$LOG"
HARNESS=$ROOT/src/main/scala/xiangshan/CoreResetElabHarness.scala
ELAB=$ROOT/build/core_reset_elab
if [ $WRITE = 1 ]; then RES=$VER; else RES=$LOG; fi

# ---- step machinery: a step is a function; its last line `DETAIL: ...` in the log is shown
NAMES=(); STAT=(); fails=0
step() {  # step NAME FUNCTION
  local n=$1 t0=$SECONDS rc d
  ( "$2" ) > "$LOG/$n.log" 2>&1; rc=$?
  d=$(grep '^DETAIL: ' "$LOG/$n.log" | tail -1 | sed 's/^DETAIL: //')
  local s=PASS; [ $rc -ne 0 ] && { s=FAIL; fails=$((fails+1)); }
  [ $rc -eq 0 ] || [ -n "$d" ] || d="see build/check/$n.log"
  NAMES+=("$n"); STAT+=("$s")
  echo "STEP $n: $s ($((SECONDS-t0))s) $d"
}
skip() { NAMES+=("$1"); STAT+=(SKIP); echo "STEP $1: SKIP (0s) $2"; }
ok() { local i; for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$1" ] && [ "${STAT[$i]}" = PASS ] && return 0; done; return 1; }

s_compile() { MILL_LOG=$LOG/compile.mill "$VER/scripts/mill_retry.sh" xiangshan.compile || { echo "DETAIL: mill xiangshan.compile failed"; return 1; }
  echo "DETAIL: xiangshan.compile OK"; }

s_elab_modules() {
  [ -e "$HARNESS" ] && { echo "DETAIL: $HARNESS already exists (leftover?), not touching it"; return 1; }
  cp "$VER/elab/CoreResetElabHarness.scala" "$HARNESS" || return 1
  trap 'rm -f "$HARNESS"' EXIT INT TERM
  rm -rf "$ELAB"
  "$VER/scripts/mill_retry.sh" xiangshan.runMain xiangshan.CoreResetElab "$ELAB" ctrl_keep,ctrl_sweep,gates \
    || { echo "DETAIL: CoreResetElab failed"; return 1; }
  rm -f "$HARNESS"
  rm -rf "$LOG/rtl"; mkdir -p "$LOG/rtl"
  python3 "$VER/scripts/extract_rtl.py" "$ELAB" "$LOG/rtl" || { echo "DETAIL: extract_rtl.py failed"; return 1; }
  if diff -r "$LOG/rtl" "$VER/rtl"; then echo "DETAIL: 3 modules elaborated, rtl/ is current"
  else echo "DETAIL: rtl/ is stale, rerun formal/run_equiv.sh with a fresh extract"; return 1; fi
}

s_smoke() {
  local bad=0 cfg S out
  for cfg in "" CFG_SWEEP; do
    # the first run builds build/obj[_cfg]; the rest runs in parallel once the binary exists
    out=$("$VER/scripts/run.sh" 1 1 "$cfg" 2>&1); echo "== ${cfg:-KEEP} SCEN 1"; echo "$out" | tail -5
    echo "$out" | grep -q '^RESULT: PASS$' || { bad=$((bad+1)); echo "FAILED ${cfg:-KEEP} SCEN 1"; }
    for S in 2 3 5 6 7; do
      ( "$VER/scripts/run.sh" $S 1 "$cfg" > "$LOG/smoke_${cfg:-KEEP}_$S.out" 2>&1 ) &
    done
    wait
    for S in 2 3 5 6 7; do
      f=$LOG/smoke_${cfg:-KEEP}_$S.out; echo "== ${cfg:-KEEP} SCEN $S"; tail -3 "$f"
      grep -q '^RESULT: PASS$' "$f" || { bad=$((bad+1)); echo "FAILED ${cfg:-KEEP} SCEN $S"; }
    done
  done
  echo "DETAIL: 12 runs, $bad failed"; [ $bad = 0 ]
}

s_formal_quick() { QUICK=1 "$VER/formal/run_formal.sh" k s; local rc=$?; echo "DETAIL: run_formal exit code $rc (unexpected results)"; return $rc; }

s_formal() {
  ( "$VER/formal/run_formal.sh" k > "$RES/results_formal_k.txt" 2>&1; echo $? > "$LOG/formal_k.rc" ) &
  ( "$VER/formal/run_formal.sh" s > "$RES/results_formal_s.txt" 2>&1; echo $? > "$LOG/formal_s.rc" ) &
  wait
  tail -3 "$RES/results_formal_k.txt" "$RES/results_formal_s.txt"
  local k s; k=$(cat "$LOG/formal_k.rc"); s=$(cat "$LOG/formal_s.rc")
  echo "DETAIL: unexpected results k=$k s=$s"; [ "$k$s" = 00 ]
}

s_equiv() { "$VER/formal/run_equiv.sh" "$ELAB" | tee "$RES/results_equiv.txt"; local rc=${PIPESTATUS[0]}
  echo "DETAIL: $rc miter(s) not PASS"; return $rc; }

s_regress() {
  "$VER/scripts/regress.sh" > "$RES/results_regress.txt" 2>&1
  python3 "$VER/scripts/regress_summary.py" "$RES/results_regress.txt" | tee "$RES/regress_summary.txt"; local rc=${PIPESTATUS[0]}
  echo "DETAIL: regress_summary exit $rc"; return $rc
}

s_soak() {
  # both binaries are built one after the other, then the two soaks run in parallel
  "$VER/scripts/run.sh" 1 1 "" > /dev/null 2>&1; "$VER/scripts/run.sh" 1 1 CFG_SWEEP > /dev/null 2>&1
  # soak.sh overwrites verification/results_soak_<cfg>.log: without --write-results keep the committed ones
  local c
  if [ $WRITE = 0 ]; then
    for c in KEEP CFG_SWEEP; do [ -f "$VER/results_soak_$c.log" ] && cp -p "$VER/results_soak_$c.log" "$LOG/results_soak_$c.log.committed"; done
  fi
  ( "$VER/scripts/soak.sh" "" > "$LOG/soak_KEEP.out" 2>&1 ) &
  ( "$VER/scripts/soak.sh" CFG_SWEEP > "$LOG/soak_CFG_SWEEP.out" 2>&1 ) &
  wait
  local bad=0 SL
  for c in KEEP CFG_SWEEP; do
    SL=$VER/results_soak_$c.log
    if [ $WRITE = 0 ]; then   # new log to build/check, committed one back
      mv -f "$SL" "$LOG/results_soak_$c.log"; SL=$LOG/results_soak_$c.log
      [ -f "$LOG/results_soak_$c.log.committed" ] && cp -p "$LOG/results_soak_$c.log.committed" "$VER/results_soak_$c.log"
    fi
    tail -3 "$LOG/soak_$c.out"
    grep -q "^soak .* pass=[0-9]* fail=0$" "$LOG/soak_$c.out" || bad=$((bad+1))
    python3 "$VER/scripts/coverage.py" "$SL" > "$RES/coverage_$c.json"
  done
  echo "DETAIL: $bad configuration(s) with failures"; [ $bad = 0 ]
}

# Full elaboration of XSNoCTop for one configuration (keep|sweep). `make verilog` runs the JVM and firtool one
# after the other; on a 16 GB machine the JVM is OOM-killed while firtool runs. XSTop.fir is written before
# that, so firtool is rerun alone on it with the options TopMain passes (see Top.scala/TopMain, Makefile
# FPGA_MEM_ARGS + SIM_ARGS/RELEASE_ARGS; seen in the "Command being timed" line of the elaboration log):
#   firtool XSTop.fir -warn-on-unprocessed-annotations -output-annotation-file circt.anno.json
#     --repl-seq-mem --repl-seq-mem-file=XSTop.sv.conf -O=release --disable-annotation-unknown
#     --lowering-options=explicitBitcast,disallowLocalVariables,disallowPortDeclSharing,locationInfoStyle=none
#     --ignore-read-enable-mem --split-verilog -o=<dir>/rtl
# with firtool 1.62.1 from ~/.cache/llvm-firtool.
noc_one() {
  local cfg=$1 B=$ROOT/build/noc_$1 rc
  rm -rf "$B"
  make verilog CONFIG=XSNoCTopConfig YAML_CONFIG=core-reset/verification/elab/xsnoctop_$cfg.yml BUILD_DIR=./build/noc_$cfg JVM_XMX=${JVM_XMX:-7G}
  rc=$?
  if [ $rc -ne 0 ] && [ -f "$B/rtl/XSTop.fir" ]; then
    echo "make failed (rc $rc), XSTop.fir exists: rerun firtool alone"
    FT=$(ls -d ~/.cache/llvm-firtool/*/bin/firtool 2>/dev/null | tail -1); [ -z "$FT" ] && FT=firtool
    "$FT" "$B/rtl/XSTop.fir" -warn-on-unprocessed-annotations -output-annotation-file "$B/rtl/circt.anno.json" \
      --repl-seq-mem --repl-seq-mem-file=XSTop.sv.conf -O=release --disable-annotation-unknown \
      --lowering-options=explicitBitcast,disallowLocalVariables,disallowPortDeclSharing,locationInfoStyle=none \
      --ignore-read-enable-mem --split-verilog -o="$B/rtl"
    rc=$?
  fi
  [ $rc -ne 0 ] && { echo "elaboration of $cfg failed"; return 1; }
  # structural checks (results_elab.txt)
  local R=$B/rtl bad=0 t n
  t=$(ls "$R"/XSTop.sv "$R"/XSTop.v 2>/dev/null | head -1)
  for p in io_debug_reset io_core_reset_req io_core_reset_busy; do
    grep -q "$p" "$t" || { echo "XSTop lacks port $p"; bad=1; }; done
  t=$(grep -l '^module XSTile\b' "$R"/*.sv 2>/dev/null | head -1)
  [ -n "$t" ] || { echo "XSTile module not found"; bad=1; }
  if [ -n "$t" ]; then
    grep -q 'CoreResetCtrl' "$t" || { echo "XSTile lacks CoreResetCtrl"; bad=1; }
    grep -q 'TLResetIsolation' "$t" || { echo "XSTile lacks TLResetIsolation"; bad=1; }
    n=$(grep -cE '^\s*TLQuiesceGate(_[0-9]+)?\s' "$t"); [ "$n" = 5 ] || { echo "XSTile has $n TLQuiesceGate instances, expected 5"; bad=1; }
  fi
  grep -lq 'DCacheFlushUnit' "$R"/*DCache*.sv 2>/dev/null || grep -lq 'DCacheFlushUnit' "$R"/*.sv 2>/dev/null || { echo "no DCacheFlushUnit in the RTL"; bad=1; }
  [ $bad = 0 ] && echo "structural checks $cfg: OK"
  return $bad
}
s_elab_noc() {
  local bad=0 c
  for c in keep sweep; do echo "=== XSNoCTop $c"; noc_one $c || bad=$((bad+1)); done
  echo "DETAIL: $bad of 2 configurations failed"; [ $bad = 0 ]
}

# ---- run
step compile s_compile
if ok compile; then step elab_modules s_elab_modules; else skip elab_modules "no compile"; fi
step smoke s_smoke
step formal_quick s_formal_quick
if [ $MODE = full ]; then
  step formal s_formal
  if [ -d "$ELAB" ]; then step equiv s_equiv; else skip equiv "no elaboration output (elab_modules)"; fi
  step regress s_regress
  step soak s_soak
  if [ $SKIP_NOC = 1 ]; then skip elab_noc "--skip-elab-noc"; else step elab_noc s_elab_noc; fi
fi

echo; echo "summary (HEAD $HEAD):"
for i in "${!NAMES[@]}"; do printf '  %-14s %s\n' "${NAMES[$i]}" "${STAT[$i]}"; done
echo "failed steps: $fails"
exit $fails
