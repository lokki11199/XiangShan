#!/bin/bash
# Tile isolation test (TESTPLAN section 6): RTL of XSTile from a full XSNoCTop elaboration, XSCore and L2Top replaced by
# the stubs of scripts/make_stubs.py, bench tb_rtl/tile_iso_tb.sv (checks T1..T7).
#
#   scripts/run_tile_iso.sh <full|keep> [TM1|TM2|TM3] [SEED]   one run, one line:
#       TILE CFG=<cfg> : RESULT: PASS|FAIL <T...>
#       TILE CFG=<cfg> MUTANT=<TMn> : CAUGHT <T...> | NOT CAUGHT | SKIPPED (<reason>)
#   scripts/run_tile_iso.sh all [SEED]                          full, keep, TM1 and TM2 on both, TM3 on keep;
#       last line `tile_iso: N unexpected` (exit code N). A SKIPPED mutant is unexpected: a hole, to be reported.
# RTL: $TILE_RTL_BASE/noc_<cfg>/rtl (default <repo>/build/noc_<cfg>/rtl, made by check.sh elab_noc).
# Build: core-reset/verification/build/tile_iso_<cfg>[_<TMn>] (generated stubs in gen/, Verilator in obj/).
# Allow list of T1: tb_rtl/tile_iso_allow.txt (every entry with the DESIGN section that allows it).
cd "$(dirname "$0")/.." || exit 2
V=$PWD
ROOT=$(cd ../.. && pwd)
. scripts/env.sh
BASE=${TILE_RTL_BASE:-$ROOT/build}

one() {  # one CFG MUTANT SEED: prints the result line; return 0 = as expected
  local cfg=$1 mut=$2 seed=${3:-1} R B tag line res bad
  R=$BASE/noc_$cfg/rtl
  tag="TILE CFG=$cfg${mut:+ MUTANT=$mut}"
  [ -d "$R" ] || { echo "$tag : RESULT: FAIL ERROR no RTL in $R (run the elaboration first)"; return 1; }
  B=build/tile_iso_$cfg${mut:+_$mut}
  rm -rf "$B"; mkdir -p "$B/gen" "$B/dut" "$B/inc"
  local XS=""
  if [ -n "$mut" ]; then
    local src; src=$(grep -l '^\s*module\s\+XSTile\b' "$R"/*.sv 2>/dev/null | head -1)
    [ -n "$src" ] || { echo "$tag : SKIPPED (no XSTile.sv in $R)"; return 1; }
    local p; p=$(python3 scripts/tile_mutants.py "$mut" "$src" "$B/XSTile_$mut.sv"); local prc=$?
    if [ $prc -ne 0 ]; then echo "$tag : ${p:-SKIPPED (tile_mutants.py failed)}"; return 1; fi
    echo "$p" > "$B/patch.txt"; XS="--xstile $B/XSTile_$mut.sv"
  fi
  python3 scripts/make_stubs.py "$R" "$cfg" "$B/gen" --allow tb_rtl/tile_iso_allow.txt $XS > "$B/make_stubs.log" 2>&1 ||
    { echo "$tag : RESULT: FAIL ERROR make_stubs.py: $(tail -1 "$B/make_stubs.log")"; return 1; }
  cp "$B/gen/tile_iso_names_$cfg.svh" "$B/inc/tile_iso_names.svh"
  # the RTL files of XSTile without XSCore and L2Top; the list of inline black boxes at the end of a file is cut
  local f files=""
  while read -r f; do
    sed '/^\/\/ ----- 8< ----- FILE "firrtl_black_box_resource_files.f"/,$d' "$f" > "$B/dut/$(basename "$f")"
    files="$files $B/dut/$(basename "$f")"
  done < "$B/gen/tile_iso_files_$cfg.f"
  verilator --binary --timing --assert -j ${VJ:-4} -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
    -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-LATCH -Wno-UNOPTFLAT \
    -Wno-PROCASSINIT -Wno-IMPORTSTAR -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-VARHIDDEN -Wno-TIMESCALEMOD \
    --x-initial unique --x-assign unique -DRANDOMIZE_REG_INIT -DRANDOMIZE_MEM_INIT \
    -I"$B/inc" --top-module tile_iso_tb -Mdir "$B/obj" \
    $files "$B/gen/stub_XSCore_$cfg.sv" "$B/gen/stub_L2Top_$cfg.sv" "$B/gen/tile_iso_dut_$cfg.sv" tb_rtl/tile_iso_tb.sv \
    > "$B/build.log" 2>&1 ||
    { echo "$tag : RESULT: FAIL ERROR Verilator build ($B/build.log: $(grep -m1 '%Error' "$B/build.log"))"; return 1; }
  timeout ${TILE_TIMEOUT:-1800} "$B/obj/Vtile_iso_tb" +SEED=$seed +verilator+seed+$seed +verilator+rand+reset+2 > "$B/run.log" 2>&1
  res=$(grep -E '^RESULT:' "$B/run.log" | tail -1)
  bad=$(grep -E 'Assertion failed|%Error' "$B/run.log" | head -1)
  [ -z "$res" ] && res="RESULT: FAIL no RESULT line${bad:+ ($bad)}"
  if [ -z "$mut" ]; then
    line="$tag : $res${bad:+ ($bad)}"; echo "$line"
    [ "$res" = "RESULT: PASS" ] && [ -z "$bad" ]
  else
    if [ "$res" = "RESULT: PASS" ] && [ -z "$bad" ]; then echo "$tag : NOT CAUGHT"; return 1
    else echo "$tag : CAUGHT ${res#RESULT: FAIL}${bad:+ ($bad)}"; return 0; fi
  fi
}

if [ "$1" = all ]; then
  n=0
  for c in full keep; do one $c "" "$2" || n=$((n+1)); done
  for c in full keep; do for m in TM1 TM2; do one $c $m "$2" || n=$((n+1)); done; done
  one keep TM3 "$2" || n=$((n+1))
  echo "tile_iso: $n unexpected"
  exit $n
fi
[ -n "$1" ] || { sed -n '2,13p' "$0"; exit 2; }
one "$1" "$2" "$3"
