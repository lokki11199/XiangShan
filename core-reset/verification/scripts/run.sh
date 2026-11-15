#!/bin/bash
# usage: scripts/run.sh SCEN SEED [DEFINE[+DEFINE...]] [extra plusargs]
#   configuration: "" (KEEP) or CFG_SWEEP; mutants and options are defines joined with "+"
#   TRACE_BUILD=1 scripts/run.sh 6 1 "" +VCD +VCD_TO=50000   -> build/wave.vcd
# The Verilator build of one configuration (build/obj_<defines>) is made once and redone in place when a source
# file is newer than the binary; never build the same
# configuration from two processes at the same time (build it first, then run in parallel).
set -e
cd "$(dirname "$0")/.."
. scripts/env.sh
S=$1; SEED=${2:-1}; M=${3:-}; shift; shift; [ $# -gt 0 ] && shift; EXTRA="$*"
OBJ=build/obj${M:+_$M}${TRACE_BUILD:+_trace}
DEFS=$(echo "$M" | tr '+' ' ' | sed -E 's/([^ ]+)/-D\1/g')
mkdir -p build
SRC="model/cr_ctl_models.sv model/cr_dcache.sv model/cr_env_models.sv tb/cr_monitors.sv tb/cr_tb.sv"
STALE=0; for f in $SRC; do [ $f -nt $OBJ/Vcr_tb ] && STALE=1; done
if [ ! -x $OBJ/Vcr_tb ] || [ $STALE = 1 ]; then
  verilator --binary --timing ${TRACE_BUILD:+--trace} -j 2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE $DEFS --top-module cr_tb -Mdir $OBJ \
    $SRC > $OBJ.log 2>&1 || { grep -E "%Error" $OBJ.log | head -40; exit 1; }
fi
$OBJ/Vcr_tb +SCEN=$S +SEED=$SEED +verilator+seed+$SEED +verilator+rand+reset+2 $EXTRA
