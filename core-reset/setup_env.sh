#!/bin/bash
# XiangShan core-reset: cloud environment setup (about 16 min on 4 CPUs on first run, seconds afterwards).
# Builds from git tags: Verilator v5.050, Yosys v0.70 (+abc), SymbiYosys v0.70, espresso v2.4;
# venv with yices (SMT solver for smtbmc); mill 0.12.3 jar; repo submodules (not ready-to-run) and stubs.
# Idempotent: every section is skipped when its result exists. No secrets. A failing section only prints a line.
# Run as root from the directory that holds the repository checkout XiangShan.
export DEBIAN_FRONTEND=noninteractive
EDA_PREFIX=${EDA_PREFIX:-/opt/eda}; SRC_DIR=${SRC_DIR:-/opt/src}; FV_DIR=${FV_DIR:-/opt/fv}
MILL_DIR=${MILL_DIR:-/opt/mill}; BIN_DIR=${BIN_DIR:-/usr/local/bin}
REPO=XiangShan; MILL_VER=0.12.3; MILL_SHA1=9e2bd55d01428d0e14e93327bcb94e7d6cd0fdc0
MILL_URL=https://repo1.maven.org/maven2/com/lihaoyi/mill-dist/$MILL_VER/mill-dist-$MILL_VER.jar
MILL_MIRROR=https://maven-central.storage-download.googleapis.com/maven2/com/lihaoyi/mill-dist/$MILL_VER/mill-dist-$MILL_VER.jar
J=${SETUP_JOBS:-4}
mkdir -p "$SRC_DIR" "$EDA_PREFIX" "$BIN_DIR" || true
export PATH=$EDA_PREFIX/bin:$PATH

clone() { [ -d "$SRC_DIR/$1" ] || git clone --depth 1 --branch "$2" "${@:4}" "$3" "$SRC_DIR/$1"; }

apt_deps() {
  local p="git perl make autoconf g++ flex bison ccache libfl2 libfl-dev zlib1g-dev help2man libgoogle-perftools-dev \
numactl clang lld libreadline-dev gawk tcl-dev libffi-dev pkg-config libboost-system-dev libboost-filesystem-dev \
cmake python3-venv python3-click curl ca-certificates"
  command -v java >/dev/null 2>&1 || p="$p default-jdk-headless"
  dpkg -s $p >/dev/null 2>&1 && return 0
  apt-get update -qq; apt-get install -y -qq --no-install-recommends $p
}
espresso() {
  [ -x "$BIN_DIR/espresso" ] && return 0
  clone espresso v2.4 https://github.com/chipsalliance/espresso || return 1
  cmake -S "$SRC_DIR/espresso" -B "$SRC_DIR/espresso/build" -DCMAKE_BUILD_TYPE=Release &&
  cmake --build "$SRC_DIR/espresso/build" --parallel $J &&
  install -m 755 "$SRC_DIR/espresso/build/espresso" "$BIN_DIR/espresso"
}
verilator() {
  [ -x "$EDA_PREFIX/bin/verilator" ] && return 0
  clone verilator v5.050 https://github.com/verilator/verilator || return 1
  (cd "$SRC_DIR/verilator" && autoconf && ./configure --prefix="$EDA_PREFIX" && make -j$J && make install)
}
yosys() {
  [ -x "$EDA_PREFIX/bin/yosys" ] && [ -x "$EDA_PREFIX/bin/yosys-abc" ] && return 0
  clone yosys v0.70 https://github.com/YosysHQ/yosys --recurse-submodules --shallow-submodules || return 1
  (cd "$SRC_DIR/yosys" && cmake -B build . -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$EDA_PREFIX" \
    -DYOSYS_ENABLE_UNIT_TESTS=OFF -DYOSYS_WITHOUT_SLANG=ON -DBUILD_SHARED_LIBS=OFF &&
   cmake --build build --parallel $J && cmake --install build --strip)
}
sby() {
  [ -x "$EDA_PREFIX/bin/sby" ] && return 0
  clone sby v0.70 https://github.com/YosysHQ/sby || return 1
  (cd "$SRC_DIR/sby" && make install PREFIX="$EDA_PREFIX")
}
venv_yices() {
  [ -x "$FV_DIR/bin/yices-smt2" ] && return 0
  python3 -m venv "$FV_DIR" && "$FV_DIR/bin/pip" install -q yices-solver
}
mill() {
  local jar="$MILL_DIR/mill-$MILL_VER.jar"
  if ! { [ -f "$jar" ] && [ "$(sha1sum "$jar" | cut -d' ' -f1)" = "$MILL_SHA1" ]; }; then
    mkdir -p "$MILL_DIR"; rm -f "$jar.part"
    for u in "$MILL_URL" "$MILL_MIRROR" "$MILL_URL" "$MILL_MIRROR"; do
      curl -fsSL --retry 3 -o "$jar.part" "$u" && [ "$(sha1sum "$jar.part" | cut -d' ' -f1)" = "$MILL_SHA1" ] && break
      rm -f "$jar.part"; sleep 10
    done
    [ -f "$jar.part" ] || return 1
    mv "$jar.part" "$jar"
  fi
  chmod +x "$jar" && ln -sf "$jar" "$BIN_DIR/mill"
}
repo() {
  [ -d "$REPO/.git" ] || return 1
  local m
  m=$(git -C "$REPO" config -f .gitmodules --get-regexp '^submodule\..*\.path$' | cut -d' ' -f2 | grep -vx ready-to-run)
  git -C "$REPO" submodule update --init --recursive -- $m || return 1
  mkdir -p "$REPO/ready-to-run"
  for f in nemu-interpreter-dual nemu-interpreter spike; do
    [ -e "$REPO/ready-to-run/riscv64-$f-so" ] || : > "$REPO/ready-to-run/riscv64-$f-so"
  done
  [ -e "$REPO/.mill-jvm-opts" ] ||
    printf '%s\n' -Xmx2500m -Xss64m -XX:+UseParallelGC -Djvm-xmx=5200m -Djvm-xss=256m > "$REPO/.mill-jvm-opts"
}

for s in apt_deps espresso verilator yosys sby venv_yices mill repo; do
  t0=$(date +%s); echo "setup: $s start"
  $s && echo "setup: $s ok ($(( $(date +%s) - t0 )) s)" || echo "setup: $s failed"
done
echo "setup: done"
exit 0
