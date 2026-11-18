#!/bin/bash
# Identity of the RTL with EnableCoreReset = false against upstream 7b16188 (TESTPLAN section 7).
#
#   scripts/make_ident_ref.sh reference          the reference: temporary git worktree of 7b16188, elaboration of
#                                                the DCacheWrapper bench and of the full XSNoCTop (XSNoCTopConfig,
#                                                no YAML), manifests -> elab/ident_ref_7b16188.txt. Run once, WITH THE
#                                                USER'S PERMISSION (worktree, own mill out/ ~2 GB, ~30 min, ~9 GB RAM).
#   scripts/make_ident_ref.sh remove-worktree    git worktree remove (only with the user's permission)
#   scripts/make_ident_ref.sh head-dcache <dir>  the same DCacheWrapper bench on the current tree (HEAD, check I1);
#                                                RTL in <dir>/ident_dcache, manifest on stdout
#   scripts/make_ident_ref.sh determinism        two generations of the bench on one commit must give one manifest
#
# env: REF (worktree, default /tmp/ref7b16188), JVM_XMX (default 7G), COURSIER_REPOSITORIES (Maven mirror as in
# mill_retry.sh). The RTL of the reference is not kept: elab/ident_ref_7b16188.txt holds its normalised manifest.
# The bench (elab/CoreResetIdentElab.scala) is copied into src/main/scala/xiangshan/ for the run and removed after.
HERE=$(cd "$(dirname "$0")" && pwd)
V=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$V/../.." && pwd)
REF=${REF:-/tmp/ref7b16188}
REF_COMMIT=7b16188
BENCH=CoreResetIdentElab.scala
export COURSIER_REPOSITORIES="${COURSIER_REPOSITORIES:-ivy2Local|https://maven-central.storage-download.googleapis.com/maven2|central}"

firtool_bin() {
  local f; f=$(ls -d ~/.cache/llvm-firtool/*/bin/firtool 2>/dev/null | tail -1)
  echo "${f:-firtool}"
}

# elaboration of the bench in tree $1 (mill root), RTL into $2/ident_dcache; the bench file is always removed
elab_bench() {
  local tree=$1 out=$2 rc
  mkdir -p "$out"
  cp "$V/elab/$BENCH" "$tree/src/main/scala/xiangshan/$BENCH"
  MILL_ROOT="$tree" "$HERE/mill_retry.sh" xiangshan.runMain xiangshan.CoreResetIdentElab "$out"
  rc=$?
  rm -f "$tree/src/main/scala/xiangshan/$BENCH"
  return $rc
}

case "${1:-}" in
head-dcache)
  OUT=${2:?usage: make_ident_ref.sh head-dcache <dir>}
  rm -rf "$OUT/ident_dcache"
  elab_bench "$ROOT" "$OUT" >&2 || { echo "elaboration of the bench failed" >&2; exit 1; }
  python3 "$HERE/rtl_normalize.py" "$OUT/ident_dcache" | tail -1
  ;;

determinism)
  T=${2:-$ROOT/core-reset/verification/build/ident_det}
  rm -rf "$T"; mkdir -p "$T"
  for i in 1 2; do
    elab_bench "$ROOT" "$T/run$i" >/dev/null 2>"$T/run$i.log" || { echo "run $i failed, see $T/run$i.log"; exit 1; }
    python3 "$HERE/rtl_normalize.py" "$T/run$i/ident_dcache" > "$T/manifest$i.txt"
  done
  if cmp -s "$T/manifest1.txt" "$T/manifest2.txt"; then
    echo "determinism: IDENTICAL ($(tail -1 "$T/manifest1.txt"))"
  else
    echo "determinism: DIFFERENT; files:"; python3 "$HERE/rtl_normalize.py" --diff "$T/manifest1.txt" "$T/manifest2.txt"
    exit 1
  fi
  ;;

remove-worktree)
  git -C "$ROOT" worktree remove --force "$REF" && echo "removed $REF"
  ;;

reference)
  set -e
  OUTFILE=$V/elab/ident_ref_7b16188.txt
  [ -e "$REF" ] && { echo "$REF exists: remove it first (remove-worktree) or set REF"; exit 2; }
  git -C "$ROOT" rev-parse --verify -q "$REF_COMMIT^{commit}" >/dev/null || { echo "no commit $REF_COMMIT"; exit 2; }
  git -C "$ROOT" worktree add --detach "$REF" "$REF_COMMIT"
  # submodules: symlinks to those of the main tree, valid only when they point at the same commit in both trees
  cd "$ROOT"
  while read -r sm; do
    [ "$sm" = ready-to-run ] && continue
    a=$(git rev-parse "$REF_COMMIT:$sm" 2>/dev/null || true); b=$(git rev-parse "HEAD:$sm" 2>/dev/null || true)
    [ "$a" = "$b" ] || { echo "submodule $sm differs between $REF_COMMIT ($a) and HEAD ($b): symlink is not valid"; exit 3; }
    rm -rf "$REF/$sm"; ln -s "$ROOT/$sm" "$REF/$sm"
  done < <(git config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}')
  # mill packs three binaries of ready-to-run as resources; empty files are enough for elaboration
  mkdir -p "$REF/ready-to-run"
  for f in riscv64-nemu-interpreter-dual-so riscv64-nemu-interpreter-so riscv64-spike-so; do : > "$REF/ready-to-run/$f"; done
  [ -f "$ROOT/.mill-jvm-opts" ] && cp "$ROOT/.mill-jvm-opts" "$REF/.mill-jvm-opts"
  T0=$(date +%s)
  echo "=== DCacheWrapper bench on $REF_COMMIT"
  elab_bench "$REF" "$REF/build/ref_elab"
  echo "=== XSNoCTop on $REF_COMMIT (no YAML_CONFIG: the YamlParser of $REF_COMMIT does not know the new keys)"
  cd "$REF"
  rm -rf build/noc_ref
  for try in 1 2 3; do
    # TIME_CMD= : the Makefile wraps mill in GNU `time -avp`, which a container may lack
    make verilog CONFIG=XSNoCTopConfig BUILD_DIR=./build/noc_ref JVM_XMX=${JVM_XMX:-7G} TIME_CMD= 2>&1 | tee build/noc_ref.log
    rc=${PIPESTATUS[0]}
    [ $rc -eq 0 ] && break
    if [ -f build/noc_ref/rtl/XSTop.fir ]; then
      echo "make failed (rc $rc), XSTop.fir exists: rerun firtool alone"
      "$(firtool_bin)" build/noc_ref/rtl/XSTop.fir -warn-on-unprocessed-annotations \
        -output-annotation-file build/noc_ref/rtl/circt.anno.json \
        --repl-seq-mem --repl-seq-mem-file=XSTop.sv.conf -O=release --disable-annotation-unknown \
        --lowering-options=explicitBitcast,disallowLocalVariables,disallowPortDeclSharing,locationInfoStyle=none \
        --ignore-read-enable-mem --split-verilog -o=build/noc_ref/rtl && { rc=0; break; }
    fi
    grep -q "response code: 429\|download error" build/noc_ref.log || break
    sleep $((try * 30))
  done
  [ $rc -eq 0 ] || { echo "elaboration of XSNoCTop failed (rc $rc)"; exit 1; }
  # manifests
  python3 "$HERE/rtl_normalize.py" "$REF/build/noc_ref/rtl" > "$REF/build/noc_ref.manifest"
  python3 "$HERE/rtl_normalize.py" "$REF/build/ref_elab/ident_dcache" > "$REF/build/dcache_ref.manifest"
  {
    echo "# identity reference: RTL of upstream $REF_COMMIT, EnableCoreReset absent (RTL not stored, normalised manifest only)"
    echo "# commit:  $(git -C "$REF" rev-parse HEAD)"
    echo "# xsnoctop: make verilog CONFIG=XSNoCTopConfig (no YAML_CONFIG) JVM_XMX=${JVM_XMX:-7G}"
    echo "# dcache:   mill xiangshan.runMain xiangshan.CoreResetIdentElab (XSNoCTopConfig --fpga-platform --dfx false)"
    echo "# firtool:  $("$(firtool_bin)" --version 2>&1 | head -2 | tr '\n' ' ')"
    echo "# date:     $(date -u +%Y-%m-%dT%H:%M:%SZ), elaboration $(( $(date +%s) - T0 )) s"
    echo "# normalisation: scripts/rtl_normalize.py"
    echo "TOTAL xsnoctop $(tail -1 "$REF/build/noc_ref.manifest" | cut -d' ' -f2-)"
    echo "TOTAL dcache $(tail -1 "$REF/build/dcache_ref.manifest" | cut -d' ' -f2-)"
    echo "[xsnoctop]"; head -n -1 "$REF/build/noc_ref.manifest"
    echo "[dcache]";   head -n -1 "$REF/build/dcache_ref.manifest"
  } > "$OUTFILE"
  echo "wrote $OUTFILE"; grep '^TOTAL' "$OUTFILE"
  echo "worktree $REF kept: remove it with '$0 remove-worktree' (with the user's permission)"
  ;;

*)
  sed -n '2,15p' "$0"; exit 2
  ;;
esac
