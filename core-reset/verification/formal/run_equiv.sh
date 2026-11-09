#!/usr/bin/env bash
# Formal equivalence: Chisel RTL (rtl/) vs hand-written models, 5 miters of formal/eq_chisel.sv.
# usage: formal/run_equiv.sh [elab_outdir]     (default /home/user/XiangShan/build/core_reset_elab)
# For every miter: sby bmc (depth 30, smtbmc/yices) and sby prove (abc pdr). One result line per miter.
# Exit code = number of miters for which bmc or prove did not end in PASS (0 = all equivalent).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VER=$(cd "$HERE/.." && pwd)
ELAB=${1:-/home/user/XiangShan/build/core_reset_elab}
DEPTH=${DEPTH:-30}
. "$VER/scripts/env.sh"

need_extract=0
for f in CoreResetCtrl_keep CoreResetCtrl_sweep TLQuiesceGate TLQuiesceGate_1 TLResetIsolation; do
  [ -s "$VER/rtl/$f.sv" ] || need_extract=1
done
if [ $need_extract = 1 ]; then
  python3 "$VER/scripts/extract_rtl.py" "$ELAB" "$VER/rtl" || exit 255
fi

RTL=$(ls "$VER"/rtl/*.sv)
cd "$HERE" || exit 255

# run_sby <name> <mode> <top> <chparam-or-empty>; prints "RESULT seconds"
run_sby() {
  local name=$1 mode=$2 top=$3 chp=$4 t0 t1 rc res engine
  if [ "$mode" = bmc ]; then
    engine="smtbmc yices"; local opts="mode bmc
depth $DEPTH"
  else
    engine="abc pdr"; local opts="mode prove"
  fi
  {
    echo "[options]"; echo "$opts"; echo "multiclock off"
    echo "[engines]"; echo "$engine"
    echo "[script]"
    echo "read -formal -sv -DSYNTHESIS -DFORMAL $(for f in $RTL; do printf '%s ' "$(basename "$f")"; done) cr_ctl_models.sv eq_chisel.sv"
    [ -n "$chp" ] && echo "chparam -set $chp $top"
    echo "prep -top $top"
    echo "[files]"
    for f in $RTL; do echo "$f"; done
    echo "$VER/model/cr_ctl_models.sv"
    echo "$HERE/eq_chisel.sv"
  } > "$HERE/sby_${name}_${mode}.sby"
  t0=$(date +%s.%N)
  sby -f "$HERE/sby_${name}_${mode}.sby" > "$HERE/sby_${name}_${mode}.log" 2>&1
  rc=$?
  t1=$(date +%s.%N)
  case $rc in 0) res=PASS ;; 2) res=FAIL ;; 4) res=TIMEOUT ;; *) res="ERROR($rc)" ;; esac
  printf '%s %.1fs' "$res" "$(echo "$t1 - $t0" | bc -l)"
  [ "$res" = PASS ] && return 0 || return 1
}

fails=0
while IFS='|' read -r name top chp; do
  b=$(run_sby "$name" bmc "$top" "$chp"); rb=$?
  p=$(run_sby "$name" prove "$top" "$chp"); rp=$?
  printf '%-10s bmc%d: %-16s prove: %s\n' "$name" "$DEPTH" "$b" "$p"
  [ $rb -ne 0 ] || [ $rp -ne 0 ] && fails=$((fails + 1))
done <<LIST
ctrl_keep|eq_ctrl|KEEP 1
ctrl_sweep|eq_ctrl|KEEP 0
gate_c|eq_gate_c|
gate_ul|eq_gate_ul|
iso|eq_iso|
LIST
echo "failed miters: $fails"
exit $fails
