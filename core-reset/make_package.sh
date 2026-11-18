#!/bin/bash
# Builds the delivery package of version v6 (reset of XSCore alone) from the COMMITTED tree (HEAD):
#   build/kmh_core_reset_v6/   and   build/kmh_core_reset_v6.zip
# Rerun it after new results appear in core-reset/verification: README.md is regenerated from them.
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
BASE=7b16188   # branch base (kunminghu-v2); the changed files are byte-identical in upstream c098f99
ORIGC=c098f99
NAME=kmh_core_reset_v6
OUT=$REPO/build/$NAME
CR=$REPO/core-reset
cd "$REPO"
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT/XiangShan" "$OUT/_original/XiangShan" "$OUT/verification"

# 1. changed files of src/ (HEAD) and the same paths at upstream c098f99 (identical to 7b16188, checked below)
n=0
for f in $(git diff --name-only $BASE HEAD -- src/); do
  mkdir -p "$OUT/XiangShan/$(dirname "$f")"
  git show "HEAD:$f" > "$OUT/XiangShan/$f"
  if git cat-file -e "$ORIGC:$f" 2>/dev/null; then
    mkdir -p "$OUT/_original/XiangShan/$(dirname "$f")"
    git show "$ORIGC:$f" > "$OUT/_original/XiangShan/$f"
  fi
  n=$((n+1))
done
echo "changed files: $n"
for f in $(cd "$OUT/_original/XiangShan" && find . -type f | sed 's|^\./||'); do
  git diff --quiet $ORIGC $BASE -- "$f" || { echo "ERROR: $f differs between $ORIGC and $BASE"; exit 1; }
done
echo "originals identical in $ORIGC and $BASE: $(cd "$OUT/_original/XiangShan" && find . -type f | wc -l) files"

# 2. patch
git diff $BASE HEAD --ignore-submodules -- src/ > "$OUT/core-reset.patch"

# 3. PDF (the committed version)
if git cat-file -e HEAD:core-reset/xscore_reset_v6.pdf 2>/dev/null; then git show HEAD:core-reset/xscore_reset_v6.pdf > "$OUT/xscore_reset_v6.pdf"; else echo "WARNING: xscore_reset_v6.pdf is not committed"; fi

# 4. verification (no build/, no *.out, no sby work dirs)
V=$CR/verification; VO=$OUT/verification
for d in model tb tb_rtl rtl elab scripts; do mkdir -p "$VO/$d"; cp -r "$V/$d/." "$VO/$d/"; done
find "$VO" -name __pycache__ -prune -exec rm -rf {} +
mkdir -p "$VO/formal"
for f in fv_boundary.sv fv_adapters.sv run_formal.sh eq_chisel.sv run_equiv.sh; do cp "$V/formal/$f" "$VO/formal/"; done
cp "$V/check.sh" "$V/TESTPLAN.md" "$V/TESTPLAN_deviations.md" "$VO/"
cp "$CR/DESIGN.md" "$OUT/DESIGN.md"
for f in "$V"/results_*.txt "$V"/results_*.log "$V"/regress_summary.txt "$V"/coverage_*.json; do
  [ -f "$f" ] && cp "$f" "$VO/"
done
chmod +x "$VO"/check.sh "$VO"/scripts/*.sh "$VO"/formal/*.sh 2>/dev/null || true

# 5. install.sh
cat > "$OUT/install.sh" <<'EOT'
#!/bin/bash
# Installs the reset of XSCore alone, version v6, into a XiangShan kunminghu-v2 tree (7b16188 or c098f99):
#   - XSCore (core + L1) is reset by debug_reset / hartreset / a cluster request; L2 and the CHI port keep running.
#   - The reset is a level: at least 100 cycles and as long as the request is held.
#   - Default (CoreResetKeepL1 = false): FULL, L1D is reset together with the core and is empty afterwards; the gate
#     in front of L1D answers every Probe with ProbeAck NtoN while the core is in reset. No flush, no sweep.
#   - CoreResetKeepL1 = true: KEEP, meta, error flags and tags of L1D are in the tile reset domain, all arrays are
#     frozen while the core is isolated, a Probe waits in L2.
#   - The isolation of the core reset domain starts at least one cycle before the core reset (state sIso).
#   - Early block of channel A of the non-coherent agents, block of B in the first cycle of sDrain, exact
#     emptiness flags of DCache (DCacheQuiesceUnit).
#   - New files: xiangshan/CoreReset.scala, xiangshan/cache/dcache/mainpipe/QuiesceUnit.scala.
# usage: ./install.sh /path/to/XiangShan [--force]
#   The tree must be clean upstream (7b16188 or c098f99; the 14 changed upstream files are identical in both) or carry
#   an earlier delivery of this work (v4, v5: recognised by markers and replaced as a whole). Files of v6 that were
#   edited by hand, or any other change in the 16 paths, make the installer stop without copying anything:
#   v6 is never mixed with edited or foreign files.
#   --force: overwrite those files as well
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
XS=${1:?usage: ./install.sh /path/to/XiangShan [--force]}
FORCE=0
for a in "${@:2}"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) echo "unknown argument: $a"; exit 1 ;;
  esac
done
[ -f "$XS/src/main/scala/xiangshan/XSTile.scala" ] || { echo "not a XiangShan tree: $XS"; exit 1; }
if grep -q "l2_quiesce_req" "$XS/src/main/scala/xiangshan/XSTile.scala"; then
  echo "This tree has the hw-quiesce patch (reset of the whole tile). This patch is for clean upstream only."
  [ $FORCE = 1 ] || exit 1
fi
SRC="$HERE/XiangShan"; ORIG="$HERE/_original/XiangShan"
# words that only earlier deliveries (v4, v5) contain: flush / sweep unit, metaReset, pulse level
OLD='DCacheFlushUnit|CoreResetLevel|metaReset|l1_meta_reset|l1_flush'
# words that only v6 contains
V6='DCacheQuiesceUnit|l1_keep_reset|core_in_reset|coreResetEnabled|hart_reset|QuiesceUnit'
# any word of the core-reset work (earlier files without a distinguishing word)
ANY='EnableCoreReset|CoreResetCtrl|CoreResetKeepL1|TLQuiesceGate|L1QuiesceIO|l1_quiesce|core_reset_req|core_reset_busy'
bad=0; nold=0; nv6=0; nnew=0
for f in $(cd "$SRC" && find . -type f | sort); do
  t="$XS/$f"
  if [ ! -f "$t" ]; then
    if [ -f "$ORIG/$f" ]; then echo "  MISSING in the tree: $f"; bad=1; else nnew=$((nnew+1)); fi
    continue
  fi
  if cmp -s "$t" "$SRC/$f"; then echo "  already as expected: $f"
  elif [ -f "$ORIG/$f" ] && cmp -s "$t" "$ORIG/$f"; then :
  elif grep -qE "$OLD" "$t"; then echo "  earlier version (v4/v5) of this work: $f"; nold=$((nold+1))
  elif grep -qE "$V6" "$t"; then echo "  v6 file edited by hand (would mix): $f"; nv6=$((nv6+1)); bad=1
  elif grep -qE "$ANY" "$t"; then echo "  earlier version of this work: $f"; nold=$((nold+1))
  else echo "  DIFFERS from upstream and is not an earlier version of this work: $f"; bad=1; fi
done
[ $nold -gt 0 ] && echo "  an earlier version is installed: $nold file(s) will be replaced"
if [ $nold -gt 0 ] && [ $nv6 -gt 0 ]; then echo "  files of an earlier version and of v6 are mixed in the tree"; fi
if [ $bad = 1 ] && [ $FORCE = 0 ]; then
  echo "Nothing copied. Merge by hand (core-reset.patch, made against 7b16188 and applies to c098f99) or rerun with --force."
  exit 1
fi
for f in $(cd "$SRC" && find . -type f | sort); do
  mkdir -p "$XS/$(dirname "$f")"; cp "$SRC/$f" "$XS/$f"; echo "  installed $f"
done
# v4 / v5 had the flush unit file, which v6 does not have and which does not compile against v6
OLDF="$XS/src/main/scala/xiangshan/cache/dcache/mainpipe/FlushUnit.scala"
if [ -f "$OLDF" ] && grep -q "DCacheFlushUnit" "$OLDF"; then rm "$OLDF"; echo "  removed $OLDF (v4/v5 flush unit)"; fi
echo "done. Enable with EnableCoreReset = true in SoCParameters (or 'EnableCoreReset: true' in the YAML config);"
echo "choose the L1D mode with CoreResetKeepL1 (false, default: FULL, L1D reset with the core; true: KEEP, L1D keeps its lines)."
echo "Connect ndmreset to debug_reset, hartreset[i] to hartResetReq and the cluster request to core_reset_req (see README.md)."
EOT
chmod +x "$OUT/install.sh"

# 6. README.md (Russian); the results table is filled from the result files
python3 -I - "$OUT" "$REPO" "$VO" <<'PYEOF'
import sys, re, os, subprocess
out, repo, ver = sys.argv[1:4]
ND = 'нет данных'
def rd(name):
    p = os.path.join(ver, name)
    return open(p, errors='replace').read() if os.path.isfile(p) else None
head = subprocess.check_output(['git', '-C', repo, 'rev-parse', '--short', 'HEAD']).decode().strip()

# ---------- formal f, k (sections f, f2 / k, k2) and adapters
rf = open(os.path.join(ver, 'formal/run_formal.sh')).read()
common = len(re.search(r'local common="([^"]*)"', rf).group(1).split())
extra = {m.group(1): len(m.group(2).split()) for m in re.finditer(r'^\s*(f|k)\) echo "\$common ([^"]*)"', rf, re.M)}
adapter_exp = len(re.search(r'^adapter_mutants="([^"]*)"', rf, re.M).group(1).split())
def sections(t):
    parts = re.split(r'^=== configuration ', t, flags=re.M)[1:]
    return {p.split(':', 1)[0]: p for p in parts}
def sec(t, key):
    s = sections(t).get(key)
    if s is None: return None
    r = {}
    m = re.search(r'prove rstCycles=100.*?: (\w+)\s+\(([\d.]+) sec\)', s); r['p100'] = '%s (%s с)' % (m.group(1), m.group(2)) if m else ND
    m = re.search(r'prove rstCycles=16[^:]*?: (\w+)\s+\(([\d.]+) sec\)', s); r['p16'] = '%s (%s с)' % (m.group(1), m.group(2)) if m else ND
    m = re.search(r'design\s+cover[^:]*: (\w+) \((\d+) reached', s); r['cover'] = '%s, целей: %s' % (m.group(1), m.group(2)) if m else ND
    mut = re.findall(r'^(\S+_MUTANT_\S+)\s+bmc[^:]*: (\w+)', s, re.M)
    exp = common + extra[key[0]] if key in ('f', 'k') else 2
    r['mut'] = '%d / %d' % (sum(1 for _, x in mut if x == 'FAIL'), exp) if mut else ND
    if mut and len(mut) != exp: r['mut'] += ' (строк %d)' % len(mut)
    eq = re.findall(r'^(\S+_MUTANT_\S+)\s+prove: (\w+)', s, re.M)
    r['eq'] = '%d / 2' % sum(1 for _, x in eq if x == 'PASS') if eq else ('—' if key in ('f2', 'k2') else ND)
    return r
def formal_rows(fname, k, k2):
    t = rd(fname)
    if t is None: return None
    a, b = sec(t, k), sec(t, k2)
    m = re.search(r'formal: (\d+) unexpected', t)
    return a, b, ('%s неожиданных' % m.group(1)) if m else 'прогон не завершён'
FF = formal_rows('results_formal_f.txt', 'f', 'f2'); FK = formal_rows('results_formal_k.txt', 'k', 'k2')
def cell(X, i, key):
    if X is None or X[i] is None: return ND
    return X[i][key]
fm_rows = []
for label, key in (('доказательство без границы, rstCycles = 100, isoCycles = 1', 'p100'),
                   ('доказательство без границы, rstCycles = 16, isoCycles = 1', 'p16'),
                   ('cover (цели достижимы)', 'cover'), ('мутанты: найден контрпример', 'mut'),
                   ('эквивалентные мутанты доказаны', 'eq')):
    fm_rows.append('| %s | %s | %s |' % (label, cell(FF, 0, key), cell(FK, 0, key)))
fm_rows.append('| доказательство rstCycles = 16, isoCycles = 2 | %s | %s |' % (cell(FF, 1, 'p16'), cell(FK, 1, 'p16')))
fm_rows.append('| cover C14, isoCycles = 2 | %s | %s |' % (cell(FF, 1, 'cover'), cell(FK, 1, 'cover')))
fm_rows.append('| мутанты isoCycles = 2 (`ISO_SHORT`, `NO_ISO_LEAD`) | %s | %s |' % (cell(FF, 1, 'mut'), cell(FK, 1, 'mut')))
fm_rows.append('| итог прогона | %s | %s |' % (FF[2] if FF else ND, FK[2] if FK else ND))
fm_rows.append('| BMC всей модели | не запускается (заменён доказательствами без границы) | не запускается |')
fmtxt = '\n'.join(fm_rows)

ta = rd('results_formal_adapters.txt')
if ta:
    ad_p = re.search(r'adapters prove[^:]*: (\w+)\s+\(([\d.]+) sec\)', ta)
    ad_m = re.findall(r'^(\S+_MUTANT_\S+)\s+adapters bmc[^:]*: (\w+)', ta, re.M)
    ad_u = re.search(r'adapters: (\d+) unexpected', ta)
    adtxt = 'доказательство без границы: %s; мутанты с контрпримером: %d / %d; неожиданных результатов: %s' % (
        ad_p.group(1) if ad_p else ND, sum(1 for _, x in ad_m if x == 'FAIL'), adapter_exp, ad_u.group(1) if ad_u else ND)
else: adtxt = ND

# ---------- equivalence
eq = rd('results_equiv.txt')
if eq:
    rows = re.findall(r'^(\w+)\s+bmc30: (\w+) [\d.]+s\s+prove: (\w+) ', eq, re.M)
    m = re.search(r'failed miters: (\d+)', eq)
    ok = sum(1 for r in rows if r[1] == 'PASS' and r[2] == 'PASS')
    eqtxt = ('%d / %d миттеров: BMC 30 и доказательство PASS; несовпадающих: %s (%s)' %
             (ok, len(rows), m.group(1) if m else ND, ', '.join(r[0] for r in rows))) if rows else ND
else: eqtxt = ND

# ---------- regression
rs = rd('regress_summary.txt')
def g(p):
    m = re.search(p, rs) if rs else None
    return m.groups() if m else None
reg = {}
if rs:
    m = g(r'design runs: (\d+), PASS (\d+)'); reg['design'] = '%s / %s' % (m[1], m[0]) if m else ND
    m = g(r'naive reset: (\d+), problem reproduced (\d+)'); reg['naive'] = '%s / %s' % (m[1], m[0]) if m else ND
    m = g(r'mutant runs: (\d+), caught (\d+)'); reg['mut'] = '%s / %s' % (m[1], m[0]) if m else ND
    m = g(r'\+EQUIV runs: (\d+), PASS (\d+)'); reg['eq'] = '%s / %s' % (m[1], m[0]) if m else ND
    m = g(r'\+FORMALONLY runs[^:]*: (\d+), caught in simulation (\d+)'); reg['fo'] = '%s прогонов, в симуляции поймано %s (мутант `NO_REQ_IN_ISO` при isoCycles = 1 ловится только формальным P23, как и задумано)' % (m[0], m[1]) if m else ND
    cfg = []
    for m in re.finditer(r'^\s+(\S+)\s+design\s+(\d+) PASS\s+(\d+) \| naive\s+(\d+) reproduced\s+(\d+) \| mutant runs\s+(\d+) caught\s+(\d+) \| \+EQUIV\s+(\d+) PASS\s+(\d+)', rs, re.M):
        cfg.append('| %s | %s / %s | %s / %s | %s / %s | %s / %s |' % (m.group(1), m.group(3), m.group(2), m.group(5), m.group(4), m.group(7), m.group(6), m.group(9), m.group(8)))
    regcfg = '\n'.join(cfg) if cfg else '| %s | | | | |' % ND
else:
    reg = {k: ND for k in ('design', 'naive', 'mut', 'eq', 'fo')}; regcfg = '| %s | | | | |' % ND
def soak(c):
    t = rd('results_soak_%s.log' % c)
    if t is None: return ND
    return '%d / %d' % (len(re.findall(r'^RESULT: PASS$', t, re.M)), len(re.findall(r'^### ', t, re.M)))

# ---------- RTL DCache, tile isolation, elaboration
rt = rd('results_rtl_dcache.txt')
if rt:
    m = re.search(r'rtl_dcache: runs=(\d+) pass=(\d+) fail=(\d+) mutant-runs=(\d+) caught=(\d+)', rt)
    rtl_sum = ('%s / %s прогонов PASS, мутантов поймано %s / %s' % (m.group(2), m.group(1), m.group(5), m.group(4))) if m else ND
    per = []
    for c in ('FULL', 'KEEP', 'KEEP+ISO2'):
        ls = [l for l in rt.splitlines() if l.startswith('RTL CFG=%s ' % c)]
        good = [l for l in ls if re.search(r'CTRL=[^ :+]+ :', l)]
        mutl = [l for l in ls if re.search(r'CTRL=\S*\+\S* :', l)]
        per.append('| %s | %d / %d | %d / %d |' % (c, sum('RESULT: PASS' in l for l in good), len(good), sum('RESULT: FAIL' in l for l in mutl), len(mutl)))
    rtl_cfg = '\n'.join(per)
else: rtl_sum = ND; rtl_cfg = '| %s | | |' % ND
ti = rd('results_tile_iso.txt')
if ti:
    pas = len(re.findall(r'^TILE CFG=\w+ : RESULT: PASS', ti, re.M)); cau = len(re.findall(r'^TILE CFG=\w+ MUTANT=\w+ : CAUGHT', ti, re.M))
    mu = len(re.findall(r'^TILE CFG=\w+ MUTANT=', ti, re.M)); m = re.search(r'tile_iso: (\d+) unexpected', ti)
    tiletxt = 'конфигурации PASS: %d / 2 (FULL, KEEP); мутанты тайла (TM1–TM3) пойманы: %d / %d; неожиданных: %s' % (pas, cau, mu, m.group(1) if m else ND)
else: tiletxt = ND
el = rd('results_elab.txt')
def el_line(p):
    m = re.search(p, el, re.M) if el else None
    return m.group(0) if m else ND
elab_rows = [
    ('XSNoCTop, `EnableCoreReset = false`', r'^elab XSNoCTop off: .*'),
    ('XSNoCTop FULL', r'^elab XSNoCTop full: .*'),
    ('XSNoCTop KEEP', r'^elab XSNoCTop keep: .*'),
    ('структурные проверки (off / full / keep)', None),
    ('I2: идентичность XSNoCTop с 7b16188 при `EnableCoreReset = false`', r'^identity xsnoctop.*'),
    ('I1: идентичность DCacheWrapper (стенд модулей)', r'^identity dcache.*')]
el_txt = []
for lab, p in elab_rows:
    if p is None:
        s = re.findall(r'^structural (\w+): (\w+)', el or '', re.M)
        v = ', '.join('%s %s' % (a, b) for a, b in s) if s else ND
    else: v = el_line(p)
    el_txt.append('| %s | %s |' % (lab, v.replace('|', '/')))
elab_txt = '\n'.join(el_txt)

T = r'''# Сброс одного XSCore по debug reset или запросу кластера (XiangShan Kunminghu V2), версия v6

Сброс ядра (XSCore = ядро + L1) по `ndmreset` / `hartreset` Debug Module или по запросу кластера. L2 (CoupledL2),
CHI-порт, кредиты и LINKACTIVE тайла не сбрасываются и работают. Собрано из коммита `@HEAD@` ветки `core-reset-v6`
(база: kunminghu-v2 = 7b16188; 14 изменённых файлов `src/` совпадают в 7b16188 и c098f99, проверено при сборке пакета,
поэтому пакет ставится на обе ревизии). Описание: `xscore_reset_v6.pdf` и `DESIGN.md`; план и отклонения проверки —
`verification/TESTPLAN.md`, `verification/TESTPLAN_deviations.md`.

## Что это

Две реализации L1D, выбор параметром (в `SoCParameters` и в YAML-конфигурации):

| Параметр | YAML-ключ | По умолчанию | Смысл |
|---|---|---|---|
| `EnableCoreReset` | `EnableCoreReset` | `false` | `false`: RTL идентичен upstream (проверено сравнением полного XSNoCTop с 7b16188). `true`: гейты, изоляция, контроллер `CoreResetCtrl`, `DCacheQuiesceUnit`, порты запроса |
| `CoreResetKeepL1` | `CoreResetKeepL1` | `false` | `false`: **FULL** — полный сброс L1D вместе с ядром: после сброса L1D пуста, пока ядро в сбросе, гейт сам отвечает на каждый Probe `ProbeAck NtoN`. `true`: **KEEP** — L1D сохраняет строки: meta, флаги ошибок и теги в домене сброса тайла, все массивы защищены от записи и чтения (freeze), Probe ждёт в L2. Имеет смысл только с `EnableCoreReset` |

Обхода (flush / sweep) L1D нет ни в одном режиме. `rstCycles` = 100 и `isoCycles` = 1 — аргументы `CoreResetCtrl`,
в `SoCParameters` и YAML не вынесены (для KEEP `isoCycles` не больше 2).

```yaml
EnableCoreReset: true
CoreResetKeepL1: false     # FULL (по умолчанию); true — KEEP
```

Последовательность (шесть состояний): sIdle, sQuiesce (A некогерентных закрыт, DCache опустошается), sDrain (B закрыт,
решение по `quiet` текущего такта), **sIso** (изоляция и freeze включены, сброса ещё нет — опережение не меньше
`isoCycles` тактов), sReset (сброс-уровень не меньше 100 тактов и пока держат запрос), sRelease (изоляция держится до
выхода ядра и frontend из сброса).

## Что изменилось по сравнению с v5

- **По умолчанию полный сброс L1D** (в v5 по умолчанию было сохранение L1D, а вариант без сохранения требовал обхода).
  **Обход (sweep) удалён**: `FlushUnit.scala` заменён на `QuiesceUnit.scala` (`DCacheQuiesceUnit`, только опустошение),
  из `MainPipe` убраны flush-порты; `sFlush` стал `sQuiesce`, `metaReset` — `keepReset` / `l1_keep_reset`.
- **Опережение изоляции (sIso):** изоляция домена сброса ядра начинается не меньше чем за такт до сброса ядра; в KEEP
  freeze включается тогда же. В sIso `l1.req` остаётся 1, Probe держится в обоих режимах.
- **KEEP:** freeze зажимает запись всех четырёх массивов, чтение SRAM тегов и данных и чтение meta / error; на сбросе
  тайла meta, error и tag, `bankedDataArray` остаётся на сбросе ядра.
- **`hartInReset` = `busy`** с первого такта последовательности; `busy` не падает между последовательностями подряд
  (sRelease → sQuiesce напрямую); новый выход `core_in_reset` (сброс XSCore установлен).
- **Запрос:** по синхронизатору на каждый источник (`debug_reset`, отдельный `hart_reset`, `core_reset_req`), ИЛИ после
  них; в XSNoCTop такт тайла пробуждается запросом.
- **Предвыборка:** подсказки L1 → L2 / L3 маскируются и `l2_pf_master_en` = 0 с первого такта (`busy`); добавлены зажимы
  `l2_pmp_resp`, `l2_pf_en`, `iretire` / `itype`.
- **`EnableCoreReset = false` даёт RTL, структурно идентичный upstream** (без `TLTempNode`, все новые порты и модули под
  `Option`).
- Сохранены из v5: сброс-уровень ≥ 100 тактов, раннее закрытие A некогерентных, флаги пустоты DCache, закрытие B с
  первого такта sDrain, решение по `quiet` текущего такта. Лицензия Mulan PSL v2 в двух новых файлах.
- Затронутые файлы (16, 14 изменённых и 2 новых): `SoC.scala`, `YamlParser.scala`, `CoreReset.scala` (новый),
  `QuiesceUnit.scala` (новый), `MainPipe`, `MissQueue`, `WritebackQueue`, `Probe`, `DCacheWrapper`, `FakeDCache`,
  `MemBlock`, `XSCore`, `XSTile`, `XSTileWrap`, `XSNoCTop`, `Top`. Полный список — `core-reset.patch`.

## Установка

```sh
./install.sh /path/to/XiangShan          # дерево на 7b16188 или c098f99 (чистое, либо с v4 / v5 этой доработки)
```

`install.sh` сверяет каждый из 14 существующих файлов с upstream (`_original/`, по содержимому): файл должен совпадать
с upstream, с v6 или быть файлом прошлой версии (v4, v5 — узнаются по меткам, заменяются целиком; старый
`mainpipe/FlushUnit.scala` удаляется). Файлы v6, правленные вручную, и любые чужие изменения в этих путях — отказ без
копирования (v6 не смешивается ни с чем; `--force` — заменить всё равно). Вместо установщика можно применить
`core-reset.patch` (`git apply` или `patch -p1`; патч снят с 7b16188 и применим к c098f99).

## Порты и протокол запроса

| Порт (XSNoCTop / XSTileWrap / XSTile) | Напр. | Что подать |
|---|---|---|
| `debug_reset` | вход, асинхронный уровень | `ndmreset` Debug Module |
| `hartResetReq` (XSTile: `hart_reset`) | вход | `hartreset[i]`; с `EnableCoreReset` сбрасывает только XSCore |
| `core_reset_req` | вход | запрос контроллера сброса кластера или 0 |
| `core_reset_busy` | выход, такт тайла | последовательность идёт (с первого такта до запуска ядра) |
| `core_in_reset` | выход, такт тайла | сброс XSCore **установлен** (только sReset); не «ядро работает» — это только `busy` = 0 |
| `hartIsInReset` (существующий) | выход | на вход Debug Module; равен `busy` |

В XSTop (TileLink L3) три входа привязаны к нулю: сброс только ядра там не выведен, целевой верх — XSNoCTop / XSTileWrap.

- Запрос — **уровень, фиксируется и не отменяется**: один такт в sIdle запускает всю последовательность. Ядро в сбросе,
  пока запрос высокий, но не меньше `rstCycles` = 100 тактов; стартует после снятия запроса, когда `busy` упадёт.
- Держать запрос до `core_reset_busy` = 1 (без `busy` — не меньше 16 тактов тайла: синхронизатор 3 такта, пробуждение
  такта). Короткий запрос при остановленном такте теряется.
- Входы запроса — **только с выходов триггеров**, без комбинационной логики и иголок: иголка запускает полный сброс.
- `reset_vector` менять, пока запрос высокий; значение стабильно от снятия запроса до `busy` = 0.
- Таймаута в контроллере нет. Если L2 не отвечает, последовательность стоит, `busy` = 1, `core_in_reset` = 0; сторожевой
  таймер — на кластере. Запрос во время последовательности выключения питания (`lpState` ≠ sIDLE) не поддержан.
- Запросы некогерентных агентов (MMIO), не прошедшие гейт до начала последовательности, теряются со сбросом; начатые
  завершаются. Зависшее устройство держит `earlyQuiet` = 0 — сброс не начнётся. Закоммиченные, но не записанные в DCache
  store (sbuffer) теряются в обоих режимах.

## Известные ограничения

### FULL (по умолчанию): нарушения TileLink и устаревшая директория L2

Решение пользователя: **описать, не исправлять** (вариант исправления В1 — `DESIGN.md`, раздел 10).

1. **Потеря грязных данных.** L1D с правом T теряет копию без Release / ProbeAckData; `ProbeAck NtoN` по строке, которую
   клиент держал Dirty, формально ложен (TileLink 1.9.3, 9.1.1, 9.3.5, 9.3.6, 4.4).
2. **Устаревшая директория L2.** L2 числит за L1D строки, которых там нет; по NtoN CoupledL2 снимает бит клиента и
   переводит TRUNK → TIP, повторный Acquire обслуживается как попадание.
3. **AcquirePerm (NtoT и BtoT).** DCache на промах store, перезаписывающего всю строку, шлёт `AcquirePerm`; CoupledL2
   отвечает `MakeUnique` — владение без данных, DataStorage не пишется. Спецификация требует помнить «data not valid»
   (9.3.2); CoupledL2 помнит это неявно («строка в TRUNK у клиента»), а сброс L1D и NtoN ломают это допущение.
   - **NtoT, промах в L2 — чужие данные:** в выбранном пути DataStorage остаются данные вытесненной строки. После NtoN L2
     отдаёт их как действительные (SnpOnce, Snp*Fwd, повторный Acquire, Get ICache / PTW): это содержимое другой строки и
     канал утечки между адресами.
   - **BtoT, попадание в BRANCH — потеря записи другого харта:** `MakeUnique` аннулирует копию другого харта без записи в
     память (поведение HN кластера требует проверки); после сброса L2 держит v1 как TIP clean, вытеснение идёт без
     WriteBack: значение откатывается v1 → v0, пропадает закоммиченная запись другого харта.
   Окно: от Grant на AcquirePerm до первого ReleaseData / ProbeAckData этой строки.
4. После сброса L2 делает лишние Probe к строкам, которых в L1D уже нет (по одному на строку).

### KEEP: удержанный Probe останавливает снупы

Нарушений протокола нет, цена — удержание Probe на всё время сброса (`DESIGN.md`, 8.2). Probe к L1D, предложенный в
sDrain … sRelease, ждёт в SourceB, его MSHR занята: снуп HN к строке L1D занимает MSHR и ждёт до конца сброса; MSHR
предвыборки L2 может выбрать жертвой строку L1D (rProbe), и тогда RXSNP встаёт для всех снупов к этому RN. В RTL-симуляции
сработают assert-ы CoupledL2 `STALL_CNT_MAX` = 28000 тактов и `VALID_CNT_MAX` = 400000 тактов. Сделано: маски предвыборки
с `busy` (оба режима). Остаётся: MSHR предвыборки, выделенная до начала последовательности. Требования к кластеру:
сторожевой таймер на длительность сброса; снятие запроса не должно зависеть от транзакции, которой нужен снуп к этому RN
(запись отладчика через SBA при удержанном `ndmreset` — взаимная блокировка; для такой отладки — FULL); удержание
заведомо короче 28000 тактов, если идут assert-ы CoupledL2. Окно Probe между сбросами подряд (sRelease → sQuiesce):
для L2 два сброса выглядят как одно удержание суммарной длины; сторожевой таймер считает от первого запроса.

## Проверка (`verification/`)

Единая точка входа:

```sh
verification/check.sh --quick    # compile, elaboration модулей, I1, smoke (сценарии x FULL/KEEP), formal rstCycles = 16, RTL-тест DCache (FULL, сид 1)
verification/check.sh --full     # плюс formal целиком, эквивалентность RTL <-> моделей, RTL DCache полностью, регрессия, soak,
                                 # полная elaboration XSNoCTop (off / full / keep) и сравнение с 7b16188 (I2)
```

Опции: `--skip-elab-noc`, `--write-results`, `--dirty`. Скрипт отказывается (код 2) работать, если `src/` или
`verification/` не закоммичены или HEAD не запушен (`--dirty` отключает проверку). Нужна раскладка ветки: каталог
`verification/` в `<XiangShan>/core-reset/verification` дерева с установленным патчем. Версии инструментов:
Verilator 5.050, Yosys 0.70 (+ yosys-abc), SymbiYosys 0.70, yices 2.6.5 (`SMT_SOLVER=yices`), mill 0.12.3, firtool 18.0.0
(LLVM 18.0.0git). Инструменты берутся через `scripts/env.sh` (`EDA_PREFIX`, по умолчанию `/opt/eda`, или
`OSS_CAD_SUITE`). Seed-ы редких мутантов подобраны под Verilator 5.050; на другой версии — `scripts/seedsearch.sh`.

**Память.** Полная elaboration XSNoCTop (`elab_noc`): пик около 13,7 ГБ (java + firtool; в прогонах 13570–13688 МБ, JVM_XMX = 7G),
конфигурации строго по очереди и не вместе с регрессией или soak. Остальные шаги умещаются в 15 ГБ; Verilator-сборки
мутантов удаляются после прогона (диск).

## Результаты (из файлов `verification/results_*`, заполнено при сборке пакета)

### Формальная проверка (SymbiYosys / Yosys, abc pdr, `results_formal_f.txt`, `results_formal_k.txt`)

| | FULL (f) | KEEP (k) |
|---|---|---|
@fmtxt@

Адаптеры TileLink (`fv_adapters`, `results_formal_adapters.txt`): @adtxt@.

### Эквивалентность RTL из Chisel и моделей (`results_equiv.txt`)

@eqtxt@

### Регрессия на моделях (`regress_summary.txt`)

| Что | Результат |
|---|---|
| прогоны дизайна PASS | @r_design@ |
| наивный сброс: ошибка воспроизведена | @r_naive@ |
| мутанты пойманы | @r_mut@ |
| эквивалентные мутанты (+EQUIV) PASS | @r_eq@ |
| +FORMALONLY | @r_fo@ |

По конфигурациям (дизайн PASS / наивный воспроизведён / мутанты пойманы / +EQUIV PASS):

| Конфигурация | дизайн | наивный | мутанты | +EQUIV |
|---|---|---|---|---|
@regcfg@

Длинный прогон (soak, 540 прогонов на конфигурацию): FULL @soak_full@ PASS; KEEP @soak_keep@ PASS
(`results_soak_*.log`, покрытие — `coverage_*.json`).

### RTL настоящей DCache (`results_rtl_dcache.txt`)

Итог: @rtl_sum@.

| Конфигурация | прогоны RTL-контроллера PASS | мутанты пойманы |
|---|---|---|
@rtl_cfg@

### Изоляция тайла на RTL XSTile (`results_tile_iso.txt`)

@tiletxt@.

### Elaboration и идентичность (`results_elab.txt`)

| Проверка | Результат |
|---|---|
@elab_txt@

## Состав пакета

- `XiangShan/` — изменённые и новые файлы `src/` деревом (16 файлов);
- `_original/XiangShan/` — те же 14 существующих файлов в upstream c098f99 (совпадают с 7b16188);
- `core-reset.patch` — `git diff 7b16188 HEAD --ignore-submodules -- src/`;
- `install.sh`, `README.md`, `DESIGN.md`, `xscore_reset_v6.pdf`;
- `verification/` — модели (`model`, `tb`), RTL-тест DCache (`tb_rtl`), формальная часть (`formal`), RTL модулей (`rtl`),
  стенды elaboration и эталон идентичности (`elab`), скрипты (`scripts`), `check.sh`, `TESTPLAN.md`,
  `TESTPLAN_deviations.md`, результаты.
'''
sub = dict(HEAD=head, fmtxt=fmtxt, adtxt=adtxt, eqtxt=eqtxt, r_design=reg['design'], r_naive=reg['naive'], r_mut=reg['mut'],
           r_eq=reg['eq'], r_fo=reg['fo'], regcfg=regcfg, soak_full=soak('FULL'), soak_keep=soak('CFG_KEEP'),
           rtl_sum=rtl_sum, rtl_cfg=rtl_cfg, tiletxt=tiletxt, elab_txt=elab_txt)
open(os.path.join(out, 'README.md'), 'w').write(re.sub(r'@(\w+)@', lambda m: sub[m.group(1)], T))
PYEOF

# 7. zip
(cd "$REPO/build" && zip -qr "$NAME.zip" "$NAME")
echo "package: $OUT"; echo "zip: $OUT.zip"
