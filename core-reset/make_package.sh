#!/bin/bash
# Builds the delivery package of version v5 (reset of XSCore alone) from the COMMITTED tree (HEAD):
#   build/kmh_core_reset_v5/   and   build/kmh_core_reset_v5.zip
# Rerun it after new results appear in core-reset/verification: README.md is regenerated from them.
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
BASE=7b16188   # branch base (kunminghu-v2); the changed files are byte-identical in upstream c098f99
ORIGC=c098f99
NAME=kmh_core_reset_v5
OUT=$REPO/build/$NAME
CR=$REPO/core-reset
cd "$REPO"
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT/XiangShan" "$OUT/_original/XiangShan" "$OUT/verification"

# 1. changed files of src/ (HEAD) and the same paths at upstream
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

# 2. patch
git diff $BASE HEAD --ignore-submodules -- src/ > "$OUT/core-reset.patch"

# 3. PDF
if [ -f "$CR/xscore_reset_v5.pdf" ]; then cp "$CR/xscore_reset_v5.pdf" "$OUT/"; else echo "WARNING: xscore_reset_v5.pdf missing"; fi

# 4. verification (no build/, no *.out, no sby work dirs)
V=$CR/verification; VO=$OUT/verification
for d in model tb rtl elab scripts; do mkdir -p "$VO/$d"; cp -r "$V/$d/." "$VO/$d/"; done
find "$VO" -name __pycache__ -prune -exec rm -rf {} +
mkdir -p "$VO/formal"
for f in fv_boundary.sv run_formal.sh eq_chisel.sv run_equiv.sh; do cp "$V/formal/$f" "$VO/formal/"; done
cp "$V/check.sh" "$VO/"
for f in "$V"/results_*.txt "$V"/results_*.log "$V"/regress_summary.txt "$V"/coverage_*.json; do
  [ -f "$f" ] && cp "$f" "$VO/"
done
chmod +x "$VO"/check.sh "$VO"/scripts/*.sh "$VO"/formal/*.sh 2>/dev/null || true

# 5. install.sh
cat > "$OUT/install.sh" <<'EOT'
#!/bin/bash
# Installs the reset of XSCore alone (L2 and the CHI port keep running; debug_reset port; option CoreResetKeepL1:
# keep L1D / sweep L1D into L2; the reset is a level, at least 100 cycles; isolation of the core reset domain;
# early block of channel A of the non-coherent agents in sFlush, block of B in the first cycle of sDrain, exact
# emptiness flags instead of waiting times; the tag array of L1D on the tile reset with CoreResetKeepL1)
# into a XiangShan kunminghu-v2 tree.
# usage: ./install.sh /path/to/XiangShan [--force]
#   The tree may be clean upstream (c098f99) or carry an earlier version of this core-reset work (any of the
#   earlier deliveries: its files are recognised by their markers and replaced as a whole). This version also
#   changes files that earlier versions left alone (Probe.scala, MainPipe.scala, CtrlBlock, frontend, LoadUnit, ...).
#   --force: overwrite files that are neither upstream nor an earlier version of this work
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
# words that only the core-reset work puts into these files (covers every changed file of earlier versions)
MARK='DCacheFlushUnit|EnableCoreReset|CoreResetCtrl|CoreResetKeepL1|CoreResetLevel|TLQuiesceGate|L1QuiesceIO|quiesce|metaReset|l1_quiesce|core_reset_req|core_reset_busy'
bad=0; nearlier=0; nnew=0
for f in $(cd "$SRC" && find . -type f | sort); do
  t="$XS/$f"
  if [ ! -f "$t" ]; then
    if [ -f "$ORIG/$f" ]; then echo "  MISSING in the tree: $f"; bad=1; else nnew=$((nnew+1)); fi
    continue
  fi
  if cmp -s "$t" "$SRC/$f"; then echo "  already as expected: $f"
  elif [ -f "$ORIG/$f" ] && cmp -s "$t" "$ORIG/$f"; then :
  elif grep -qE "$MARK" "$t"; then echo "  earlier version of this work: $f"; nearlier=$((nearlier+1))
  else echo "  DIFFERS from upstream and is not an earlier version of this work: $f"; bad=1; fi
done
[ $nearlier -gt 0 ] && echo "  an earlier version is installed: $nearlier file(s) will be replaced"
if [ $bad = 1 ] && [ $FORCE = 0 ]; then
  echo "Nothing copied. Merge by hand (core-reset.patch against c098f99) or rerun with --force."
  exit 1
fi
for f in $(cd "$SRC" && find . -type f | sort); do
  mkdir -p "$XS/$(dirname "$f")"; cp "$SRC/$f" "$XS/$f"; echo "  installed $f"
done
echo "done. Enable with EnableCoreReset = true in SoCParameters (or 'EnableCoreReset: true' in the YAML config);"
echo "choose the implementation with CoreResetKeepL1 (true: keep L1D, default; false: sweep L1D into L2)."
echo "Connect ndmreset | hartreset[i] to debug_reset of the tile (see the PDF, section 8)."
EOT
chmod +x "$OUT/install.sh"

# 6. README.md (Russian) from the template; the tables are filled from the results files
python3 -I - "$OUT" "$REPO" "$VO" <<'PYEOF'
import sys, re, os, subprocess
out, repo, ver = sys.argv[1:4]
ND = 'нет данных'
def rd(name):
    p = os.path.join(ver, name)
    return open(p, errors='replace').read() if os.path.isfile(p) else None
head = subprocess.check_output(['git', '-C', repo, 'rev-parse', '--short', 'HEAD']).decode().strip()

# ---- formal
run_formal = open(os.path.join(ver, 'formal/run_formal.sh')).read()
common = len(re.search(r'common="([^"]*)"', run_formal).group(1).split())
extra = {}
for m in re.finditer(r'^\s*([ks]\)) echo "\$common ([^"]*)";;', run_formal, re.M):
    extra[m.group(1)[0]] = len(m.group(2).split())
def formal(c):
    t = rd('results_formal_%s.txt' % c)
    if t is None: return None
    # only the part of the configuration (the file holds one)
    r = {}
    m = re.search(r'prove rstCycles=100.*?: (\w+)\s+\(([\d.]+) sec\)', t); r['p100'] = '%s (%s с)' % (m.group(1), m.group(2)) if m else ND
    m = re.search(r'prove rstCycles=16.*?: (\w+)\s+\(([\d.]+) sec\)', t); r['p16'] = '%s (%s с)' % (m.group(1), m.group(2)) if m else ND
    r['bmc'] = 'не запускался (доказательства abc pdr без ограничения глубины)' if re.search(r'design\s+bmc: not run', t) else ND
    m = re.search(r'cover[^:]*: (\w+) \((\d+) reached', t); r['cover'] = '%s (%s целей, abc pdr)' % (m.group(1), m.group(2)) if m else ND
    mut = re.findall(r'^(\S+_MUTANT_\S+)\s+bmc[^:]*: (\w+)', t, re.M)
    exp = common + extra[c]
    if mut:
        got = sum(1 for _, s in mut if s == 'FAIL')
        r['mut'] = '%d / %d' % (got, exp) + ('' if len(mut) == exp else ' (прогон не завершён: %d из %d)' % (len(mut), exp))
    else: r['mut'] = ND
    eq = re.findall(r'^(\S+_MUTANT_\S+)\s+prove: (\w+)', t, re.M)
    r['eq'] = '%d / 2' % sum(1 for _, s in eq if s == 'PASS') if eq else ND
    m = re.search(r'formal: (\d+) unexpected', t); r['fin'] = ('неожиданных результатов: ' + m.group(1)) if m else 'прогон не завершён'
    return r
F = {c: formal(c) for c in 'ks'}
def fv(c, key):
    return F[c][key] if F[c] else ND

# ---- regression
rs = rd('regress_summary.txt')
R = {}
if rs:
    for m in re.finditer(r'^\s+(KEEP|CFG_SWEEP)\s+design\s+(\d+) PASS\s+(\d+) \| naive\s+(\d+) reproduced\s+(\d+) \| mutant runs\s+(\d+) caught\s+(\d+) \| \+EQUIV\s+(\d+) PASS\s+(\d+)', rs, re.M):
        R[m.group(1)] = [int(x) for x in m.groups()[1:]]
def rg(c, i, j): return '%d / %d' % (R[c][j], R[c][i]) if c in R else ND

# ---- soak
def soak(c):
    t = rd('results_soak_%s.log' % c)
    if t is None: return ND
    runs = len(re.findall(r'^### ', t, re.M)); p = len(re.findall(r'^RESULT: PASS$', t, re.M))
    s = '%d / %d' % (p, runs)
    if runs < 490: s += ' (из 490, прогон не завершён)'
    return s

# ---- equivalence RTL <-> models
eq = rd('results_equiv.txt')
if eq:
    rows = re.findall(r'^(\w+)\s+bmc30: (\w+) [\d.]+s\s+prove: (\w+) ', eq, re.M)
    eqtxt = '\n'.join('| `%s` | %s | %s |' % r for r in rows)
    m = re.search(r'failed miters: (\d+)', eq)
    eqsum = 'Итог: ' + (('несовпадающих миттеров: %s из %d' % (m.group(1), len(rows))) if m else 'прогон не завершён')
else:
    eqtxt = '| %s | | |' % ND; eqsum = ND
elab = rd('results_elab.txt')
elabtxt = ('```\n' + elab.strip() + '\n```') if elab else ND

tpl = open(os.path.join(os.path.dirname(os.path.abspath(out)), 'README.tpl'), errors='replace').read() if False else None
T = r'''# Сброс одного XSCore по debug reset: уровень, сохранение L1D или обход (XiangShan Kunminghu V2), версия v5

Сброс ядра (XSCore + L1) по `ndmreset` / `hartreset` Debug Module или по запросу кластера. L2 и CHI-порт тайла
работают. Сброс — уровень: ядро в сбросе, пока держат запрос, и не меньше 100 тактов. Один параметр
(`CoreResetKeepL1`) выбирает, что делать с L1D; все управляющие сигналы из домена сброса ядра изолированы на
стороне тайла. Подробное описание: `xscore_reset_v5.pdf`. Собрано из коммита `@HEAD@` ветки `core-reset-v5`
(база: kunminghu-v2 = 7b16188; изменённые файлы в нём и в c098f99 одинаковы).

## Что изменилось в v5

- **Импульсный сброс удалён, остался только уровень.** Параметр `CoreResetLevel` убран. Ядро остаётся в сбросе,
  пока запрос поднят, но не меньше `rstCycles` = 100 тактов (TileLink 1.8.1, 3.2.2: valid = 0 не меньше 100 тактов
  на сбрасываемом канале).
- **Ранний блок канала A** для некогерентных агентов ядра (ICache, PTW, MMIO инструкций и данных; TL-UL) уже в
  состоянии `sFlush`: их запросы после сброса не нужны. Канал B остаётся открытым, пока не завершатся все такие
  запросы (Get некогерентного агента может потребовать Probe строки L1D).
- **Канал B закрывается в первом такте `sDrain`** (шлюз опускает ready на B и valid в сторону ядра): Probe ждут в
  L2. В `sDrain` попадает самое большее один Probe, принятый в последнем такте `sFlush`.
- **Точные флаги пустоты вместо ожиданий по 16 тактов.** DCache (MainPipe, Probe, MissQueue, WritebackQueue,
  FlushUnit) выдаёт флаги «пусто / ожидающих нет»; контроллер выходит из `sDrain` в тот же такт, когда выполнены
  все условия (обычно в первом).
- **Массив тегов L1D на сбросе тайла при `CoreResetKeepL1 = true`.** Это дефект v4, найденный при ревью: счётчик
  инициализации массива тегов при сбросе ядра стирал теги, хотя данные и meta оставались. Теперь теги на сбросе
  тайла, а запись в теги и данные маскируется (`freeze`) на время сброса.
- **Конфликт имени `TLQuiesceGate` исправлен.** v4 не компилировалась (конфликт `name`); **v5 компилируется**.
- Затронутые файлы (16): `Probe.scala` (новый изменяемый файл: Probe на время сброса), `MainPipe`, `MissQueue`, `WritebackQueue`,
  `FlushUnit` (новый), `DCacheWrapper`, `FakeDCache`, `CoreReset` (новый), `XSCore`, `XSTile`, `XSTileWrap`, `XSNoCTop`, `Top`,
  `YamlParser`, `SoC`, `MemBlock`. Полный список — `core-reset.patch`.

## Параметр (`SoCParameters`, действует при `EnableCoreReset = true`)

| `CoreResetKeepL1` | Что делает |
|---|---|
| `true` (по умолчанию), **KEEP** | L1D сохраняет строки: meta, флаги ошибок и теги на сбросе тайла, данные без сброса; запись во все массивы под `freeze`. L2 забирает грязные данные обычным Probe; Probe во время сброса ждёт в L2 (шлюз держит канал B). Директория L2 остаётся точной. После сброса L1D «горячая». |
| `false`, **SWEEP** | перед сбросом L1D отдаёт каждую строку в L2 (Release / ReleaseData через MainPipe), затем сбрасывается вместе с ядром. Данные не теряются, директория L2 не знает о копии в L1D. Probe во время сброса (CoupledL2 его не пришлёт) шлюз отвечает ProbeAck NtoN. Цена: обход L1D (около 1024 тактов плюс Release) перед сбросом. |

Варианта «полный сброс L1D без обхода» нет: строка, полученная DCache через AcquirePerm (запись всей строки), есть
только в L1D, а у L2 на её месте данные другого адреса (TileLink 1.9.3, 9.3.2).

Включение, например, в YAML:

```yaml
EnableCoreReset: true
CoreResetKeepL1: false     # SWEEP; true (по умолчанию) — KEEP
```

или `up(SoCParamsKey).copy(EnableCoreReset = true, CoreResetKeepL1 = false)`.

## Установка

```sh
./install.sh /path/to/XiangShan          # чистый upstream c098f99 или дерево с любой прошлой версией этой доработки (v1–v4)
```

`install.sh` сверяет каждый файл с upstream (`_original/`): файл должен совпадать с upstream или быть файлом одной
из прошлых версий этой доработки (они узнаются по меткам и заменяются целиком). Иначе установщик ничего не
копирует и сообщает, какой файл изменён у вас (`--force` — заменить всё равно). Вместо установщика можно применить
`core-reset.patch` к чистому c098f99 (`git apply` или `patch -p1`).

## Подключение (порты не изменились)

| Порт (XSNoCTop / XSTileWrap / XSTile) | Направление | Что подать |
|---|---|---|
| `debug_reset` | вход, асинхронный уровень | `ndmreset \| hartreset[i]` от Debug Module |
| `core_reset_req` | вход, асинхронный уровень | запрос контроллера сброса кластера или 0 |
| `core_reset_busy` | выход, такт тайла | 1 от запроса до запуска ядра |
| `hartResetReq` (существующий) | вход | с `EnableCoreReset` действует как `debug_reset` |
| `hartIsInReset` (существующий) | выход | на вход DM `hartIsInReset[i]` |

`ndmreset` не подавать на основной сброс тайла: он сбросит L2 и CHI-порт. Если XSTile подключён напрямую и у вас
своё отключение такта, такт тайла должен идти, пока запрос или `core_reset_busy` = 1. Контроллер сам
выдерживает минимум в 100 тактов; дольше ядро остаётся в сбросе, пока запрос поднят.
При KEEP и удержанном запросе снуп к строке из L1D ждёт снятия запроса: если отладчик при удержанном сбросе пишет
через SBA в такую строку, возможна взаимная блокировка; с SWEEP такой ситуации нет.

## Сборка

Сборка как в upstream XiangShan (`make verilog` с вашей конфигурацией; `EnableCoreReset` и `CoreResetKeepL1`
задаются в YAML или в `SoCParameters`). Компилируется (`mill xiangshan.compile`).
Стенд elaboration отдельных модулей — `verification/elab/`.

## Результаты проверки (`verification/`)

Проверяются модели на SystemVerilog, построчно повторяющие `CoreReset.scala` (шлюз `TLQuiesceGate`,
`TLResetIsolation`, контроллер `CoreResetCtrl`), поведенческие модели DCache, L2 и клиентов; эквивалентность
сгенерированного из Chisel RTL и моделей доказана отдельно (`formal/run_equiv.sh`). Таблица заполняется из файлов
`verification/results_*` при сборке пакета.

| | KEEP (`CoreResetKeepL1 = true`) | SWEEP (`CoreResetKeepL1 = false`) |
|---|---|---|
| формально: доказательство без границы, rstCycles = 100 | @k_p100@ | @s_p100@ |
| формально: доказательство без границы, rstCycles = 16 | @k_p16@ | @s_p16@ |
| формально: BMC всей модели | @k_bmc@ | @s_bmc@ |
| формально: cover (как assert) | @k_cover@ | @s_cover@ |
| формально: мутанты, найден контрпример | @k_mut@ | @s_mut@ |
| формально: эквивалентные мутанты доказаны | @k_eq@ | @s_eq@ |
| формально: итог прогона | @k_fin@ | @s_fin@ |
| регрессия: прогоны дизайна PASS | @k_r_good@ | @s_r_good@ |
| регрессия: наивный сброс — ошибка воспроизведена | @k_r_naive@ | @s_r_naive@ |
| регрессия: мутанты пойманы | @k_r_mut@ | @s_r_mut@ |
| регрессия: +EQUIV мутанты PASS | @k_r_eq@ | @s_r_eq@ |
| длинный прогон (soak) PASS | @k_soak@ | @s_soak@ |

Эквивалентность RTL (из Chisel) и моделей (`results_equiv.txt`, BMC 30 и доказательство):

| миттер | BMC 30 | доказательство |
|---|---|---|
@eqtxt@

@eqsum@

Elaboration (`results_elab.txt`): @elabtxt@

## Как запускать проверки

Нужны Verilator 5.050, Yosys 0.70, SymbiYosys 0.70 (`sby`, `yosys-abc`) и SMT-решатель yices для
`yosys-smtbmc` (`SMT_SOLVER=yices`; иначе boolector или z3). Инструменты берутся из `scripts/env.sh`:
`OSS_CAD_SUITE=/путь/к/oss-cad-suite` или `EDA_PREFIX` (по умолчанию `/opt/eda`), затем из `PATH`.

```sh
cd verification
scripts/run.sh 7 1 "CFG_SWEEP"              # один прогон: сценарий, seed, конфигурация и мутанты через "+"
scripts/regress.sh > results_regress.txt    # регрессия по всем конфигурациям (RESUME=<файл> — продолжить)
python3 scripts/regress_summary.py results_regress.txt > regress_summary.txt
scripts/soak.sh                             # длинный прогон KEEP -> results_soak_KEEP.log
scripts/soak.sh CFG_SWEEP                   # то же для SWEEP; не запускать параллельно со сборкой той же конфигурации
python3 scripts/coverage.py results_soak_CFG_SWEEP.log
formal/run_formal.sh k                      # формально: KEEP (s — SWEEP; без аргументов обе)
formal/run_formal.sh s > results_formal_s.txt
formal/run_equiv.sh                         # эквивалентность RTL и моделей (RTL: scripts/extract_rtl.py)
```

Сценарии: 1–3 случайный трафик (3 — запрос уровнем), 4 наивный сброс (ошибки ожидаются), 5 запуск в момент
открытой транзакции каждого класса, 6 направленные Probe, 7 отладчик держит сброс 2000–20 000 тактов со снупами.
`+SLOW` — медленная L2, `+NOSPUR` — без лишних Probe; макрос `NO_GARBAGE` — без случайных выходов ядра в сбросе.
Verilator 5.050 (oss-cad-suite с 5.049 был недоступен; seed-ы редких мутантов подобраны на 5.050, `scripts/rare_seeds.txt`):
на другой версии редкие мутанты могут не проявиться — `scripts/seedsearch.sh` подберёт новые; формальная проверка ловит их всегда.

## Состав пакета

- `XiangShan/` — изменённые и новые файлы `src/` (деревом);
- `_original/XiangShan/` — те же файлы в upstream c098f99 (новых файлов там нет);
- `core-reset.patch` — `git diff 7b16188 HEAD --ignore-submodules -- src/` (применяется и к c098f99);
- `install.sh`, `xscore_reset_v5.pdf`, `verification/`.
'''
sub = {'HEAD': head, 'eqtxt': eqtxt, 'eqsum': eqsum, 'elabtxt': elabtxt}
for c, n in (('k', 'k'), ('s', 's')):
    for key in ('p100', 'p16', 'bmc', 'cover', 'mut', 'eq', 'fin'):
        sub['%s_%s' % (n, key)] = fv(c, key)
for c, n in (('KEEP', 'k'), ('CFG_SWEEP', 's')):
    sub[n + '_r_good'] = rg(c, 0, 1); sub[n + '_r_naive'] = rg(c, 2, 3)
    sub[n + '_r_mut'] = rg(c, 4, 5); sub[n + '_r_eq'] = rg(c, 6, 7)
    sub[n + '_soak'] = soak(c)
txt = re.sub(r'@(\w+)@', lambda m: sub[m.group(1)], T)
open(os.path.join(out, 'README.md'), 'w').write(txt)
PYEOF

# 7. zip
(cd "$REPO/build" && zip -qr "$NAME.zip" "$NAME")
echo "package: $OUT"; echo "zip: $OUT.zip"
