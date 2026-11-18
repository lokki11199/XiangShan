#!/bin/bash
# Single entry point of the core-reset verification (v6, TESTPLAN section 8).
#   core-reset/verification/check.sh --quick | --full [--skip-elab-noc] [--skip-rtl] [--write-results] [--dirty]
# Run from anywhere. One line per step: `STEP <name>: PASS|FAIL|SKIP (<time>s) <detail>`; the full log of a step is
# build/check/<name>.log (below this directory). At the end a summary table; exit code = number of failed steps,
# 2 = refused to start. Checks run on the committed and pushed state only: the script refuses to start (exit 2) if
# src/ or core-reset/verification/ has uncommitted changes (build/, result files, local run files excepted; the
# elaboration harnesses of elab/ copied into src/ unchanged are tolerated) or HEAD is not origin/core-reset-v6,
# unless --dirty is given.
#
# --quick (about 25 min):
#   compile          mill xiangshan.compile                                                          ~5 min
#   elab_modules     CoreResetElab ctrl_full, ctrl_keep, ctrl_full_iso2, ctrl_keep_iso2, gates, quiesce (one JVM),
#                    extract_rtl.py, rtl/ must equal the committed rtl/; the RTL DCache benches dcache_full,
#                    dcache_keep (scripts/run_rtl_dcache.sh elab, one JVM each)                       ~6 min
#   ident_modules    I1: the DCacheWrapper bench (EnableCoreReset = false) vs TOTAL dcache of
#                    elab/ident_ref_7b16188.txt (SKIP when the reference is missing)                 ~2 min
#   smoke            scenarios 1 2 3 5 6 7 8 9, seed 1, FULL and CFG_KEEP (16 runs; each configuration built
#                    once, then the runs in parallel)                                                 ~3 min
#   formal_quick     QUICK=1 formal/run_formal.sh f k, QUICK=1 formal/run_formal.sh adapters        ~1 min
#   rtl_dcache_smoke RTL DCache test, FULL, D1..D13, seed 1 (build build/rtl_full)                   ~10 min
# --full: the quick steps plus
#   formal           formal/run_formal.sh f || formal/run_formal.sh k (f2 / k2 inside), then adapters  ~2 h
#   equiv            formal/run_equiv.sh (8 miters, Chisel RTL vs models)                            ~10 min
#   rtl_dcache       FULL, KEEP, KEEP+ISO2: D1..D13 (KEEP+ISO2: D8 D9 D10 D13) x seeds 1-3, R x seeds 1-10, the
#                    controller-model runs and mutants of TESTPLAN 5.6; base builds one after the other, then the
#                    three configurations in parallel; mutant builds removed after their runs           ~45 min
#   regress          scripts/regress.sh + regress_summary.py                                         ~1.5 h
#   soak             scripts/soak.sh FULL || CFG_KEEP, coverage.py                                    ~1.5 h
#   elab_noc         XSNoCTop off (EnableCoreReset = false, no YAML: I2 and E3), full, keep - strictly one after
#                    the other and never together with another step (~9 GB peak); E1..E3; writes results_elab.txt;
#                    skipped by --skip-elab-noc
#   tile_iso         scripts/run_tile_iso.sh all on build/noc_full, build/noc_keep (T1..T7, TM1..TM3)  ~15 min
# --skip-rtl skips rtl_dcache_smoke, rtl_dcache and tile_iso.
# Result files of the package (results_*.txt, coverage_*.json, regress_summary.txt, results_soak_*.log) are written
# into this directory only with --write-results; otherwise the same output goes to build/check.
# Tools: scripts/env.sh (OSS_CAD_SUITE, else EDA_PREFIX=/opt/eda, plus /opt/fv/bin for yices).
# mill: scripts/mill_retry.sh retries on Maven Central HTTP 429 / download errors (Google mirror).
# Environment: JVM_XMX (default 7G) for the XSNoCTop elaboration.
VER=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$VER/../.." && pwd)
LOG=$VER/build/check
BRANCH=core-reset-v6
MODE=""; SKIP_NOC=0; SKIP_RTL=0; WRITE=0; DIRTY=0
for a in "$@"; do
  case $a in
    --quick) MODE=quick;; --full) MODE=full;; --skip-elab-noc) SKIP_NOC=1;; --skip-rtl) SKIP_RTL=1;;
    --write-results) WRITE=1;; --dirty) DIRTY=1;;
    *) echo "unknown option $a"; MODE="";; esac
done
[ -z "$MODE" ] && { echo "usage: check.sh --quick | --full [--skip-elab-noc] [--skip-rtl] [--write-results] [--dirty]"; exit 2; }
cd "$ROOT" || exit 2
. "$VER/scripts/env.sh"

# ---- state of the tree
HEAD=$(git rev-parse --short HEAD); ORIGIN=$(git rev-parse --short origin/$BRANCH 2>/dev/null)
echo "HEAD $HEAD, origin/$BRANCH ${ORIGIN:-unknown}: $([ "$HEAD" = "$ORIGIN" ] && echo "HEAD is pushed" || echo "HEAD differs from origin")"
# harnesses of elab/ copied into src/ (untracked, identical to elab/) are not changes of the tree
harness_copy() { local f=$1 b; b=$(basename "$f"); [ -f "$VER/elab/$b" ] && cmp -s "$ROOT/$f" "$VER/elab/$b"; }
CH=""
while IFS= read -r ln; do
  [ -z "$ln" ] && continue
  f=${ln:3}
  case "$ln" in "?? src/"*) harness_copy "$f" && continue;; esac
  echo "$f" | grep -qE '/build/|/results_|/coverage_|regress_summary|seedsearch|soak_|\.out$|/rtl_logs/|tb_rtl/gen/' && continue
  CH="$CH$ln"$'\n'
done < <(git status --porcelain -- src core-reset/verification)
if [ $DIRTY = 0 ]; then
  [ -n "$CH" ] && { echo "refused: uncommitted changes (commit and push first, or --dirty):"; printf '%s' "$CH"; exit 2; }
  [ "$HEAD" != "$ORIGIN" ] && { echo "refused: HEAD is not pushed to origin/$BRANCH (or --dirty)"; exit 2; }
fi
mkdir -p "$LOG"
SRCDIR=$ROOT/src/main/scala/xiangshan
ELAB=$ROOT/build/core_reset_elab
VELAB=$VER/build/core_reset_elab              # where scripts/run_rtl_dcache.sh expects the DCache benches
REF=$VER/elab/ident_ref_7b16188.txt
if [ $WRITE = 1 ]; then RES=$VER; else RES=$LOG; fi

# ---- step machinery: a step is a function; its last line `DETAIL: ...` in the log is shown
NAMES=(); STAT=(); fails=0
step() {  # step NAME FUNCTION
  local n=$1 t0=$SECONDS rc d
  ( "$2" ) > "$LOG/$n.log" 2>&1; rc=$?
  d=$(grep '^DETAIL: ' "$LOG/$n.log" | tail -1 | sed 's/^DETAIL: //')
  local s=PASS
  if [ $rc -eq 3 ]; then s=SKIP; elif [ $rc -ne 0 ]; then s=FAIL; fails=$((fails+1)); fi
  [ $rc -eq 0 ] || [ -n "$d" ] || d="see build/check/$n.log"
  NAMES+=("$n"); STAT+=("$s")
  echo "STEP $n: $s ($((SECONDS-t0))s) $d"
}
skip() { NAMES+=("$1"); STAT+=(SKIP); echo "STEP $1: SKIP (0s) $2"; }
ok() { local i; for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$1" ] && [ "${STAT[$i]}" = PASS ] && return 0; done; return 1; }

s_compile() { MILL_LOG=$LOG/compile.mill "$VER/scripts/mill_retry.sh" xiangshan.compile || { echo "DETAIL: mill xiangshan.compile failed"; return 1; }
  echo "DETAIL: xiangshan.compile OK"; }

# copy the harnesses of elab/ into src/ (they compile together); remove only those this step copied
HCOPIED=()
harness_in() {
  local f b
  for f in "$VER"/elab/*.scala; do
    b=$(basename "$f")
    if [ -e "$SRCDIR/$b" ]; then
      cmp -s "$SRCDIR/$b" "$f" || { echo "DETAIL: $SRCDIR/$b exists and differs from elab/ (leftover?), not touching it"; return 1; }
    else cp "$f" "$SRCDIR/$b" || return 1; HCOPIED+=("$SRCDIR/$b"); fi
  done
}
harness_out() { local f; for f in "${HCOPIED[@]}"; do rm -f "$f"; done; HCOPIED=(); }

s_elab_modules() {
  harness_in || return 1
  trap harness_out EXIT INT TERM
  rm -rf "$ELAB"
  "$VER/scripts/mill_retry.sh" xiangshan.runMain xiangshan.CoreResetElab "$ELAB" ctrl_full,ctrl_keep,ctrl_full_iso2,ctrl_keep_iso2,gates,quiesce \
    || { echo "DETAIL: CoreResetElab failed"; return 1; }
  harness_out
  rm -rf "$LOG/rtl"; mkdir -p "$LOG/rtl"
  python3 "$VER/scripts/extract_rtl.py" "$ELAB" "$LOG/rtl" || { echo "DETAIL: extract_rtl.py failed"; return 1; }
  # compare with the committed rtl/, ignoring source line numbers inside the assert messages
  local N='s/([A-Za-z0-9_]+)\.scala:[0-9]+(:[0-9]+)?/\1.scala:N/g' f
  rm -rf "$LOG/rtl_n" "$LOG/rtl_c"; mkdir -p "$LOG/rtl_n" "$LOG/rtl_c"
  for f in "$LOG"/rtl/*; do sed -E "$N" "$f" > "$LOG/rtl_n/$(basename "$f")"; done
  for f in "$VER"/rtl/*; do sed -E "$N" "$f" > "$LOG/rtl_c/$(basename "$f")"; done
  local nmod; nmod=$(ls "$LOG"/rtl | wc -l)
  if ! diff -r "$LOG/rtl_n" "$LOG/rtl_c"; then
    echo "DETAIL: rtl/ is stale, rerun formal/run_equiv.sh with a fresh extract"; return 1
  fi
  # the RTL test benches of the DCache (one JVM per target, the script copies its own harness)
  "$VER/scripts/run_rtl_dcache.sh" elab full keep || { echo "DETAIL: $nmod modules current; elaboration of the DCache benches failed"; return 1; }
  echo "DETAIL: $nmod modules elaborated, rtl/ current; DCache benches full, keep elaborated"
}

ref_total() {  # ref_total xsnoctop|dcache: "<sha> files=N" of the reference, empty if there is none
  [ -f "$REF" ] && grep "^TOTAL $1 " "$REF" | head -1 | cut -d' ' -f3-
}
ref_section() {  # ref_section xsnoctop|dcache OUT: the manifest lines of one section of the reference as a plain manifest
  awk -v s="[$1]" '/^\[/ { on = ($0 == s); next } on' "$REF" > "$2"
}

s_ident_modules() {
  local want got
  want=$(ref_total dcache)
  [ -z "$want" ] && { echo "identity dcache (module bench): SKIP (no $REF: scripts/make_ident_ref.sh reference)" | tee -a "$LOG/identity.txt"; echo "DETAIL: SKIP, no reference"; return 3; }
  got=$("$VER/scripts/make_ident_ref.sh" head-dcache "$LOG/ident" | tail -1 | sed 's/^TOTAL //')
  [ -z "$got" ] && { echo "DETAIL: elaboration of the identity bench failed"; return 1; }
  if [ "$got" = "$want" ]; then
    echo "identity dcache (module bench): IDENTICAL (${got#* }, total ${got:0:12})" | tee -a "$LOG/identity.txt"
    echo "DETAIL: I1 IDENTICAL (${got:0:12})"
  else
    python3 "$VER/scripts/rtl_normalize.py" "$LOG/ident/ident_dcache" > "$LOG/ident_dcache.manifest"
    echo "identity dcache (module bench): DIFFERENT (${got#* }, total ${got:0:12}, reference ${want:0:12}) $(ref_section dcache "$LOG/ref_dcache.manifest"; python3 "$VER/scripts/rtl_normalize.py" --diff "$LOG/ident_dcache.manifest" "$LOG/ref_dcache.manifest" | head -20 | tr '\n' ' ')" | tee -a "$LOG/identity.txt"
    echo "DETAIL: I1 DIFFERENT"; return 1
  fi
}

s_smoke() {
  local bad=0 cfg S n f
  for cfg in "" CFG_KEEP; do
    n=${cfg:-FULL}
    # the first run builds build/obj[_cfg]; the rest runs in parallel once the binary exists
    "$VER/scripts/run.sh" 1 1 "$cfg" > "$LOG/smoke_${n}_1.out" 2>&1
    for S in 2 3 5 6 7 8 9; do ( "$VER/scripts/run.sh" $S 1 "$cfg" > "$LOG/smoke_${n}_$S.out" 2>&1 ) & done
    wait
    for S in 1 2 3 5 6 7 8 9; do
      f=$LOG/smoke_${n}_$S.out; echo "== $n SCEN $S: $(grep -E '^RESULT' "$f")"
      grep -q '^RESULT: PASS$' "$f" || { bad=$((bad+1)); echo "FAILED $n SCEN $S: $(grep -m2 ERROR "$f")"; }
    done
  done
  echo "DETAIL: 16 runs, $bad failed"; [ $bad = 0 ]
}

s_formal_quick() {
  QUICK=1 "$VER/formal/run_formal.sh" f k; local a=$?
  QUICK=1 "$VER/formal/run_formal.sh" adapters; local b=$?
  echo "DETAIL: unexpected results: f k $a, adapters $b"; [ $a = 0 ] && [ $b = 0 ]
}

RTL_CASES="D1 D2 D3 D4 D5 D6 D7 D8 D9 D10 D11 D12 D13"
rtl_line_ok() { echo "$1" | grep -q ': RESULT: PASS'; }
s_rtl_dcache_smoke() {
  [ -f "$VELAB/dcache_full/params.svh" ] || { echo "DETAIL: no DCache bench elaboration (elab_modules)"; return 1; }
  local c l bad=0 n=0
  for c in $RTL_CASES; do
    l=$("$VER/scripts/run_rtl_dcache.sh" FULL $c 1); echo "$l"; n=$((n+1))
    rtl_line_ok "$l" || bad=$((bad+1))
  done
  echo "DETAIL: FULL D1..D13 seed 1: $n runs, $bad failed"; [ $bad = 0 ]
}

s_formal() {
  ( "$VER/formal/run_formal.sh" f > "$RES/results_formal_f.txt" 2>&1; echo $? > "$LOG/formal_f.rc" ) &
  ( "$VER/formal/run_formal.sh" k > "$RES/results_formal_k.txt" 2>&1; echo $? > "$LOG/formal_k.rc" ) &
  wait
  "$VER/formal/run_formal.sh" adapters > "$RES/results_formal_adapters.txt" 2>&1; echo $? > "$LOG/formal_a.rc"
  tail -2 "$RES/results_formal_f.txt" "$RES/results_formal_k.txt" "$RES/results_formal_adapters.txt"
  local f k a; f=$(cat "$LOG/formal_f.rc"); k=$(cat "$LOG/formal_k.rc"); a=$(cat "$LOG/formal_a.rc")
  echo "DETAIL: unexpected results f=$f k=$k adapters=$a"; [ "$f$k$a" = 000 ]
}

s_equiv() { "$VER/formal/run_equiv.sh" "$ELAB" | tee "$RES/results_equiv.txt"; local rc=${PIPESTATUS[0]}
  echo "DETAIL: $rc miter(s) not PASS"; return $rc; }

# RTL DCache test, the full set of TESTPLAN 5.7; one configuration per background loop (a build is never shared)
rtl_cfg_suite() {  # CFG OUT
  local cfg=$1 out=$2 c s cases mcases m tag
  : > "$out"
  cases=$RTL_CASES; [ "$cfg" = KEEP+ISO2 ] && cases="D8 D9 D10 D13"
  for s in 1 2 3; do for c in $cases; do "$VER/scripts/run_rtl_dcache.sh" "$cfg" $c $s >> "$out"; done; done
  for s in $(seq 1 10); do "$VER/scripts/run_rtl_dcache.sh" "$cfg" R $s >> "$out"; done
  [ "$cfg" = KEEP+ISO2 ] && return
  # the controller model without a mutant (must PASS), then the mutants (must be caught)
  for s in 1 2 3; do for c in D1 R; do "$VER/scripts/run_rtl_dcache.sh" "$cfg" $c $s CTRL_MODEL >> "$out"; done; done
  for m in "CTRL_MUTANT_NO_DRAIN:D1 D11" "CTRL_MUTANT_STALE_QUIET:D8" "CTRL_MUTANT_LATE_HOLDB:D9" \
           "CTRL_MUTANT_NO_REQ_IN_ISO:R D13" "CTRL_MUTANT_NO_ISO_LEAD:D1" "FULL/CTRL_MUTANT_ACK_IN_ISO:D10" \
           "KEEP/CTRL_MUTANT_LATE_FREEZE:D13"; do
    mcases=${m#*:}; m=${m%%:*}
    case $m in */*) [ "${m%%/*}" = "$cfg" ] || continue; m=${m#*/};; esac
    for s in 1 2 3; do for c in $mcases; do "$VER/scripts/run_rtl_dcache.sh" "$cfg" $c $s CTRL_MODEL+$m >> "$out"; done; done
    tag=$(echo "$cfg" | tr 'A-Z' 'a-z'); rm -rf "$VER/build/rtl_${tag}_CTRL_MODEL+$m" "$VER/build/rtl_${tag}_CTRL_MODEL+$m".{lock,log}
  done
}
s_rtl_dcache() {
  [ -f "$VELAB/dcache_full/params.svh" ] && [ -f "$VELAB/dcache_keep/params.svh" ] || { echo "DETAIL: no DCache bench elaboration (elab_modules)"; return 1; }
  local c
  # base builds one after the other (a build takes several GB), then the three configurations in parallel
  for c in FULL KEEP KEEP+ISO2; do "$VER/scripts/run_rtl_dcache.sh" "$c" D1 1 > /dev/null; done
  for c in FULL KEEP KEEP+ISO2; do ( rtl_cfg_suite "$c" "$LOG/rtl_dcache_$c.txt" ) & done
  wait
  cat "$LOG"/rtl_dcache_FULL.txt "$LOG"/rtl_dcache_KEEP.txt "$LOG"/rtl_dcache_KEEP+ISO2.txt > "$RES/results_rtl_dcache.txt"
  local runs pass mr caught
  runs=$(grep -c 'CTRL=rtl \|CTRL=model :' "$RES/results_rtl_dcache.txt")
  pass=$(grep -E 'CTRL=(rtl|model) :' "$RES/results_rtl_dcache.txt" | grep -c ': RESULT: PASS')
  mr=$(grep -c 'CTRL=model+' "$RES/results_rtl_dcache.txt")
  caught=$(grep 'CTRL=model+' "$RES/results_rtl_dcache.txt" | grep -vc ': RESULT: PASS')
  echo "rtl_dcache: runs=$runs pass=$pass fail=$((runs-pass)) mutant-runs=$mr caught=$caught" | tee -a "$RES/results_rtl_dcache.txt"
  grep -E 'CTRL=(rtl|model) :' "$RES/results_rtl_dcache.txt" | grep -v ': RESULT: PASS' | head -20
  grep 'CTRL=model+' "$RES/results_rtl_dcache.txt" | grep ': RESULT: PASS' | sed 's/^/NOT CAUGHT /' | head -20
  echo "DETAIL: runs=$runs pass=$pass mutant-runs=$mr caught=$caught"
  [ "$runs" = "$pass" ] && [ "$mr" = "$caught" ] && [ "$runs" -gt 0 ]
}

s_regress() {
  "$VER/scripts/regress.sh" > "$RES/results_regress.txt" 2>&1
  python3 "$VER/scripts/regress_summary.py" "$RES/results_regress.txt" | tee "$RES/regress_summary.txt"; local rc=${PIPESTATUS[0]}
  echo "DETAIL: regress_summary exit $rc"; return $rc
}

s_soak() {
  # both binaries are built one after the other, then the two soaks run in parallel
  "$VER/scripts/run.sh" 1 1 "" > /dev/null 2>&1; "$VER/scripts/run.sh" 1 1 CFG_KEEP > /dev/null 2>&1
  # soak.sh writes verification/results_soak_<cfg>.log: without --write-results keep the committed ones
  local c
  if [ $WRITE = 0 ]; then
    for c in FULL CFG_KEEP; do [ -f "$VER/results_soak_$c.log" ] && cp -p "$VER/results_soak_$c.log" "$LOG/results_soak_$c.log.committed"; done
  fi
  ( "$VER/scripts/soak.sh" FULL > "$LOG/soak_FULL.out" 2>&1 ) &
  ( "$VER/scripts/soak.sh" CFG_KEEP > "$LOG/soak_CFG_KEEP.out" 2>&1 ) &
  wait
  local bad=0 SL
  for c in FULL CFG_KEEP; do
    SL=$VER/results_soak_$c.log
    if [ $WRITE = 0 ]; then   # new log to build/check, committed one back
      mv -f "$SL" "$LOG/results_soak_$c.log"; SL=$LOG/results_soak_$c.log
      [ -f "$LOG/results_soak_$c.log.committed" ] && cp -p "$LOG/results_soak_$c.log.committed" "$VER/results_soak_$c.log"
    fi
    tail -1 "$LOG/soak_$c.out"
    grep -q "^soak .* pass=[0-9]* fail=0$" "$LOG/soak_$c.out" || bad=$((bad+1))
    python3 "$VER/scripts/coverage.py" "$SL" > "$RES/coverage_$c.json"
  done
  echo "DETAIL: $(tail -qn1 "$LOG"/soak_FULL.out "$LOG"/soak_CFG_KEEP.out | tr '\n' ' ')"; [ $bad = 0 ]
}

# Full elaboration of XSNoCTop for one configuration: off (EnableCoreReset = false, no YAML: the identity I2 and E3),
# full or keep (elab/xsnoctop_<cfg>.yml). `make verilog` runs the JVM and firtool one after the other; on a 16 GB machine
# the JVM may be OOM-killed while firtool runs. XSTop.fir is written before that, so firtool is rerun alone on it with the
# options TopMain passes (Makefile FPGA_MEM_ARGS + SIM_ARGS / RELEASE_ARGS), firtool from ~/.cache/llvm-firtool.
# Times: Chisel = until XSTop.fir is written, firtool = after it.
firtool_bin() { local f; f=$(ls -d ~/.cache/llvm-firtool/*/bin/firtool 2>/dev/null | tail -1); echo "${f:-firtool}"; }
fmt_t() { printf '%d:%02d' $(($1/60)) $(($1%60)); }
noc_one() {  # noc_one CFG: elaboration + structural check; appends the lines of results_elab.txt to $LOG/elab_lines.txt
  local cfg=$1 B=$ROOT/build/noc_$1 rc t0 tf t1 yml="" nf st
  rm -rf "$B"
  [ "$cfg" != off ] && yml="YAML_CONFIG=core-reset/verification/elab/xsnoctop_$cfg.yml"
  t0=$(date +%s)
  # TIME_CMD= : the Makefile wraps mill in GNU `time -avp`, which a container may lack
  make verilog CONFIG=XSNoCTopConfig $yml BUILD_DIR=./build/noc_$cfg JVM_XMX=${JVM_XMX:-7G} TIME_CMD=
  rc=$?
  if [ $rc -ne 0 ] && [ -f "$B/rtl/XSTop.fir" ]; then
    echo "make failed (rc $rc), XSTop.fir exists: rerun firtool alone"
    "$(firtool_bin)" "$B/rtl/XSTop.fir" -warn-on-unprocessed-annotations -output-annotation-file "$B/rtl/circt.anno.json" \
      --repl-seq-mem --repl-seq-mem-file=XSTop.sv.conf -O=release --disable-annotation-unknown \
      --lowering-options=explicitBitcast,disallowLocalVariables,disallowPortDeclSharing,locationInfoStyle=none \
      --ignore-read-enable-mem --split-verilog -o="$B/rtl"
    rc=$?
  fi
  t1=$(date +%s); tf=$t1; [ -f "$B/rtl/XSTop.fir" ] && tf=$(stat -c %Y "$B/rtl/XSTop.fir")
  nf=$(find "$B/rtl" -name '*.sv' -o -name '*.v' 2>/dev/null | wc -l)
  if [ $rc -ne 0 ]; then
    echo "elab XSNoCTop $cfg: FAIL (Chisel $(fmt_t $((tf-t0))), firtool $(fmt_t $((t1-tf))), $nf files)" >> "$LOG/elab_lines.txt"; return 1
  fi
  echo "elab XSNoCTop $cfg: PASS (Chisel $(fmt_t $((tf-t0))), firtool $(fmt_t $((t1-tf))), $nf files)" >> "$LOG/elab_lines.txt"
  st=$(python3 "$VER/scripts/elab_struct.py" "$B/rtl" "$cfg"); rc=$?
  echo "$st"; echo "$st" >> "$LOG/elab_lines.txt"
  [ "$cfg" = off ] && rm -f "$B/rtl/XSTop.fir"     # the identity needs the SystemVerilog only (disk)
  return $rc
}
ident_xsnoctop() {  # I2 on build/noc_off
  local want got fv rv
  want=$(ref_total xsnoctop)
  if [ -z "$want" ]; then echo "identity xsnoctop (EnableCoreReset=false vs 7b16188): SKIP (no $REF)"; return 3; fi
  fv=$("$(firtool_bin)" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  rv=$(grep '^# firtool:' "$REF" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$rv" ] && [ "$fv" != "$rv" ]; then
    echo "identity xsnoctop (EnableCoreReset=false vs 7b16188): SKIP (firtool $fv, reference made with $rv)"; return 3
  fi
  python3 "$VER/scripts/rtl_normalize.py" "$ROOT/build/noc_off/rtl" > "$LOG/noc_off.manifest"
  got=$(tail -1 "$LOG/noc_off.manifest" | sed 's/^TOTAL //')
  if [ "$got" = "$want" ]; then
    echo "identity xsnoctop (EnableCoreReset=false vs 7b16188): IDENTICAL (${got#* }, total ${got:0:12})"
  else
    echo "identity xsnoctop (EnableCoreReset=false vs 7b16188): DIFFERENT (${got#* }, total ${got:0:12}, reference ${want:0:12}) $(ref_section xsnoctop "$LOG/ref_xsnoctop.manifest"; python3 "$VER/scripts/rtl_normalize.py" --diff "$LOG/noc_off.manifest" "$LOG/ref_xsnoctop.manifest" | head -20 | tr '\n' ' ')"
    return 1
  fi
}
s_elab_noc() {
  local bad=0 c l rc
  : > "$LOG/elab_lines.txt"
  for c in off full keep; do
    echo "=== XSNoCTop $c"; noc_one $c || bad=$((bad+1))
    if [ $c = off ] && [ -d "$ROOT/build/noc_off/rtl" ]; then
      l=$(ident_xsnoctop); rc=$?; echo "$l"; echo "$l" >> "$LOG/elab_lines.txt"; [ $rc = 1 ] && bad=$((bad+1))
    fi
  done
  # results_elab.txt: elaboration and structure lines, then the identity lines (I2 above, I1 from ident_modules)
  { echo "# check.sh elab_noc, HEAD $HEAD, $(date -u +%Y-%m-%dT%H:%M:%SZ), firtool $("$(firtool_bin)" --version 2>&1 | head -1)"
    cat "$LOG/elab_lines.txt"
    [ -f "$LOG/identity.txt" ] && grep '^identity dcache' "$LOG/identity.txt" | tail -1
  } > "$RES/results_elab.txt"
  cat "$RES/results_elab.txt"
  echo "DETAIL: $bad failure(s) in off, full, keep"; [ $bad = 0 ]
}

s_tile_iso() {
  [ -d "$ROOT/build/noc_full/rtl" ] && [ -d "$ROOT/build/noc_keep/rtl" ] || { echo "DETAIL: SKIP, no RTL of build/noc_full / noc_keep (elab_noc)"; return 3; }
  TILE_RTL_BASE=$ROOT/build "$VER/scripts/run_tile_iso.sh" all | tee "$RES/results_tile_iso.txt"; local rc=${PIPESTATUS[0]}
  echo "DETAIL: $(tail -1 "$RES/results_tile_iso.txt")"; return $rc
}

# ---- run
step compile s_compile
if ok compile; then step elab_modules s_elab_modules; else skip elab_modules "no compile"; fi
if ok compile; then step ident_modules s_ident_modules; else skip ident_modules "no compile"; fi
step smoke s_smoke
step formal_quick s_formal_quick
if [ $SKIP_RTL = 1 ]; then skip rtl_dcache_smoke "--skip-rtl"
elif ok elab_modules; then step rtl_dcache_smoke s_rtl_dcache_smoke; else skip rtl_dcache_smoke "no elab_modules"; fi
if [ $MODE = full ]; then
  step formal s_formal
  if [ -d "$ELAB" ]; then step equiv s_equiv; else skip equiv "no elaboration output (elab_modules)"; fi
  if [ $SKIP_RTL = 1 ]; then skip rtl_dcache "--skip-rtl"
  elif ok elab_modules; then step rtl_dcache s_rtl_dcache; else skip rtl_dcache "no elab_modules"; fi
  step regress s_regress
  step soak s_soak
  if [ $SKIP_NOC = 1 ]; then skip elab_noc "--skip-elab-noc"; else step elab_noc s_elab_noc; fi
  if [ $SKIP_RTL = 1 ]; then skip tile_iso "--skip-rtl"; else step tile_iso s_tile_iso; fi
fi

echo; echo "summary (HEAD $HEAD):"
for i in "${!NAMES[@]}"; do printf '  %-17s %s\n' "${NAMES[$i]}" "${STAT[$i]}"; done
echo "failed steps: $fails"
exit $fails
