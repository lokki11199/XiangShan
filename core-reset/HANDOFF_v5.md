# Сброс XSCore по debug reset — версия v5 (передача работы)

Этот файл передаёт работу из чата claude.ai в Claude Code. Всё, что сделано в облачном окружении для v5, утеряно
при его перезапуске. Здесь записаны требования, принятые решения, найденные ловушки и план, чтобы сделать v5
заново на основе последней выданной версии (v4).

Пользователь пишет по-русски; отвечать и писать документацию по-русски. Код, комментарии в коде и сообщения
коммитов — по-английски, в стиле существующего кода.

---

## 1. Контекст

- Пользователь интегрирует **XiangShan Kunminghu V2 XSTile** (XSCore + CoupledL2) в собственный **CHI-кластер**.
- Задача: сбрасывать **только XSCore (ядро + L1)** — по debug reset (`ndmreset` / `hartreset` Debug Module) или по
  запросу кластера. L2 и CHI-порт тайла продолжают работать, когерентность не нарушается.
- Базовая ревизия XiangShan: **`c098f99`** (kunminghu-v2). Все патчи — относительно неё.
- Спецификации TileLink: 1.8.1 и 1.9.3 (`TileLink_Spec_1.9.3.pdf` есть у пользователя).

### Входные данные

Последняя выданная версия — **v4**, архив `kmh_core_reset_sweep.zip`:

```
kmh_core_reset_sweep/
  XiangShan/src/main/scala/...   полные изменённые файлы (v4)
  _original/XiangShan/...        те же файлы upstream c098f99
  core-reset.patch               git diff от c098f99
  install.sh                     установщик (сверяет дерево, узнаёт прошлые версии по меткам)
  README.md
  xscore_reset_sweep_iso.pdf     документация v4 (~80 стр.)
  verification/                  model/, tb/, formal/, scripts/, results_*
```

Начать так: клон XiangShan на `c098f99` с подмодулями → `./install.sh <дерево>` из архива v4 → коммит
«v4» → ветка `core-reset-v5`. Скрипты генерации PDF v4 **не сохранились** — есть только сам PDF (см. раздел 7).

---

## 2. Запрос пользователя (дословно, это и есть задача v5)

> Сгенерируй новый патч и описание со следующими изменениями: Убери механизм импульсного сброса. Если ядро в
> сбросе, гейт либо блокирует транзакцию (L2 ждет ответ на Probe) в случае сохранения metaArray, либо сам
> отвечает в случае flush. Добавь начало блокировки канала A для некогерентных Master-агентов ядра в состоянии
> sFlush везде, где можно. Убери везде, где можно, ожидание в 16 тактов, добавь вместо этого флаги пустоты и
> используй их. В sDrain гейт должен максимально быстро блокировать канал B.

Результат: новый патч от c098f99, полные файлы, `_original/`, установщик, README, проверка (модели, тестбенч,
формальная часть, скрипты, результаты), **новый PDF на русском в привычном стиле**, zip, краткое резюме по-русски
(обязательно сказать, компилируется ли Chisel).

---

## 3. Что было в v4 (от чего уходим)

- `CoreResetCtrl(keepL1, level, rstCycles = 100, releaseCycles = 8)`, состояния
  `sIdle, sFlush, sDrain, sReset, sRelease, sHold` — импульсный сброс (100 тактов + sHold + повторный импульс) или
  уровень (`CoreResetLevel`).
- Все гейты (l1d, l1i, ptw, i_mmio, d_mmio) закрывают A только в sDrain (`gateBlock`).
- sDrain ждёт **16 тактов подряд** `gatesIdle && l1Done`; `idle` гейта включает «L2 не предлагает Probe»
  (`b.valid`). B держится (KEEP) / отвечается гейтом (sweep) только с sReset.
- `DCacheFlushUnit` (FlushUnit.scala): счётчик `quiet` на 16 тактов в sDrain и sWait.
- sRelease ждёт `releaseCycles` ≥ 8.
- **v4 не компилировалась**: в `TLQuiesceGate(val name: String)` член `name` конфликтует с `LazyModule.name`
  (и `private val name = outer.name` в Imp). Об этом нужно сказать пользователю.

---

## 4. Дизайн v5 (решено и было реализовано, компилировалось)

### 4.1. Автомат CoreResetCtrl — только уровень

```
sIdle   --req-->                                         sFlush
sFlush  --l1Done && earlyQuiet-->                        sDrain
sDrain  --gatesQuiet && l1Done && l1Idle (тот же такт)--> sReset   (coreReset:=1, hartInReset:=1, closed:=1, cnt:=0)
sReset  --cnt >= rstCycles && !req-->                    sRelease (coreReset:=0)
sRelease--l1.alive && !coreInReset-->                    sIdle    (closed:=0, hartInReset:=0)
```

```scala
class CoreResetCtrl(keepL1: Boolean, rstCycles: Int = 100) extends Module {
  val sIdle :: sFlush :: sDrain :: sReset :: sRelease :: Nil = Enum(5)
  require(rstCycles >= 100 && rstCycles < 255, "TileLink 1.8.1, 3.2.2: at least 100 cycles of reset")
  // l1.* приходят из домена сброса ядра: маскировать регистром closed
  val l1Done = io.l1.done && !closed
  val l1Idle = io.l1.idle && !closed
  val coreUp = io.l1.alive && !io.coreInReset && state === sRelease
  ...
  io.l1.req     := state === sFlush || state === sDrain
  io.l1.freeze  := (if (keepL1) closed else false.B)
  io.earlyBlock := state =/= sIdle                       // A некогерентных: с sFlush
  io.gateBlock  := state === sDrain || closed            // A L1D: с sDrain
  io.holdProbe  := (if (keepL1) state === sDrain || closed else state === sDrain)
  io.ackProbe   := (if (keepL1) false.B else closed)
  io.isolate    := closed
}
```

- Нет sHold, нет импульса, нет `releaseCycles`, нет счётчиков тишины. Сброс держится, пока держат запрос, но не
  меньше `rstCycles` = 100 (TL 1.8.1 §3.2.2).
- `holdProbe` / `ackProbe` — комбинационно от состояния (регистр `state`): B закрывается **в первом же такте
  sDrain**. Гейт снимает `b.ready` к L2 и `b.valid` к ядру в том же такте — законно по TL 1.8.1 §4.1 (valid
  непринятого beat-а можно снять).
- Решение в sDrain — по `quiet` **текущего такта** (не регистровому): иначе Probe, принятый в последнем такте
  sFlush, проскакивает (мутант `CTRL_MUTANT_STALE_QUIET`).
- Assert-ы: `gatesQuiet` в sReset; `closed === (sReset || sRelease)`; `!coreReset || closed`.
- `CoreResetCtrlIO`: `req, busy, inReset, hartInReset, l1 (L1QuiesceIO), coreInReset (In), earlyBlock,
  gateBlock, holdProbe, ackProbe, isolate, earlyQuiet (In), gatesQuiet (In), coreReset`.

### 4.2. Почему A некогерентных можно закрыть в sFlush, а B — только после их тишины

- l1i, ptw, i_mmio, d_mmio — некогерентные (TL-UL): закрыть их A с первого такта sFlush безопасно, их запросы
  после сброса никому не нужны.
- **CoupledL2: Get к строке, которую L1D держит в TRUNK/TIP, ждёт Probe toB к L1D.** Поэтому B нельзя закрыть,
  пока у некогерентных открыт хоть один Get → выход из sFlush ждёт `earlyQuiet` (все ранние гейты quiet).
- A L1D закрывается только в sDrain: в sFlush DCache ещё делает Release (sweep) и отвечает на Probe.
- После sFlush с `l1Done && earlyQuiet` в sDrain может быть открыт только Probe, принятый L1D-гейтом в последнем
  такте sFlush (его ProbeAck ещё идёт через буфер `l1d_to_l2_buffer`). sDrain ждёт его — обычно 1 такт, с
  медленной L2 до ~80 тактов в симуляции.

### 4.3. TLQuiesceGate / TLResetIsolation (CoreReset.scala)

- `class TLQuiesceGate(val gateName: String, val early: Boolean)`; в Imp `private val gname = outer.gateName`
  (**не `name`!**). `require(!(outer.early && hasBCE))` — ранние гейты только на TL-UL рёбрах.
- `QuiesceGateIO { block, holdB, ackB, isolate: Input; quiet: Output }` — **`idle` (с `b.valid`) удалён**.
- `quiet = reqs === 0 && aFirst && dFirst && (для TL-C: grants === 0 && probes === 0 && releases === 0 && cFirst)`;
  `io.quiet := quiets.reduce(_ && _)`. Счётчики гейта покрывают и содержимое буфера `l1d_to_l2_buffer`
  (поэтому нужен `quiet` гейта, а не только флаг DCache).
- Логика `ackB` / `ackPending` (ответ ProbeAck NtoN) — как в v4.
- `TLResetIsolation`: выход переименован `idle` → `quiet`.

### 4.4. Точные флаги пустоты DCache вместо 16 тактов

| Файл | Изменение |
|---|---|
| `FlushUnit.scala` | `L1QuiesceIO` + `val idle = Input(Bool())` (направление — как у остальных полей bundle); порты `DCacheFlushUnit` + `mp_empty`, `pq_empty`; `val idle = io.mq_empty && io.wbq_empty && io.mp_empty && io.pq_empty`; счётчик `quiet` удалён; sDrain → по `idle`; sWait → `when (inflight === 0.U && idle) { state := sDone }`; `io.flush.idle := idle`; заголовочный комментарий обновить |
| `MainPipe.scala` | `val busy = Output(Bool())` рядом с flush-портами; `io.busy := s1_valid \|\| s2_valid \|\| s3_valid` |
| `Probe.scala` (ProbeQueue) | **новый изменённый файл**: `val empty = Output(Bool())`; `io.empty := !Cat(entries.map(_.io.block_addr.valid)).orR && !selected_req_valid` |
| `MissQueue.scala` | `io.empty := ... && !miss_req_pipe_reg.reg_valid() && cmo_unit.io.req.ready` |
| `DCacheWrapper.scala` | `flushUnit.io.mp_empty := !mainPipe.io.busy`; `flushUnit.io.pq_empty := probeQueue.io.empty` |
| `FakeDCache.scala` | `io.quiesce.idle := true.B` |

`l1.idle` в контроллере с нынешним DCache избыточен (в sDone занят может быть только путь Probe, а каждый Probe
считает гейт) — оставлен как прямое требование (формальное свойство P19).

### 4.5. XSTile и прочее

- `coreGate(name, early)`: l1d — `early = false`; l1i, ptw, i_mmio, d_mmio — `early = true`.
- `new CoreResetCtrl(CoreResetKeepL1)`.
- `g.module.io.block := (if (g.early) ctl.io.earlyBlock else ctl.io.gateBlock)`.
- `ctl.io.earlyQuiet := coreGates.filter(_.early).map(_.module.io.quiet).foldLeft(true.B)(_ && _)`.
- `ctl.io.gatesQuiet := (coreGates.map(_.module.io.quiet) ++ coreIsolations.map(_.module.io.quiet)).foldLeft(true.B)(_ && _)`.
- `ctl.io.coreInReset := core.module.io.resetInFrontend` (последний в цепочке ResetGen memBlock → backend →
  frontend; маскируется структурно, как `l1.*`).
- Комментарии про импульс убрать (XSTile, XSTileWrap).
- `SoC.scala`: `CoreResetLevel` удалить (комментарий влить в `CoreResetKeepL1`).
- `YamlParser.scala`: `CoreResetLevel` удалить (circe `Configuration.default.withDefaults` игнорирует
  неизвестные ключи — старые YAML не ломаются).
- Порты тайла не меняются.

Итог: изменённые файлы относительно c098f99 (16): `system/SoC.scala`, `top/{Top,XSNoCTop,YamlParser}.scala`,
`xiangshan/{CoreReset (new), XSCore, XSTile, XSTileWrap}.scala`, `mem/MemBlock.scala`,
`cache/dcache/{DCacheWrapper,FakeDCache}.scala`,
`cache/dcache/mainpipe/{FlushUnit (new), MainPipe, MissQueue, WritebackQueue, Probe}.scala`.

---

## 5. Сборка Chisel

- mill 0.12.3 (через coursier из Maven Central; бывают 429 — повторять). Scala 2.13.15, Chisel 6.7, firtool 1.62.1
  (скачивается автоматически в `~/.cache/llvm-firtool`).
- Воркеру mill нужна память: `.mill-jvm-opts` в корне дерева, например
  `-Xmx2500m -Xss64m -XX:+UseParallelGC -Djvm-xmx=5200m -Djvm-xss=256m` (не включать в патч).
- `mill xiangshan.compile` — должно пройти.
- **Полная elaboration XSNoCTop** в облаке не уместилась в 6 ГБ (без `espresso` минимизатор декодеров Chisel
  очень прожорлив). Локально её стоит сделать для обеих конфигураций — это важнейшая непроверенная часть
  (соединения XSTile). Сборка `espresso` из исходников — по желанию пользователя.
- **Стенд elaboration** `CoreResetElabHarness.scala` (временно в `src/main/scala/xiangshan/`, в патч не входит,
  в архив — в `verification/elab/`): object `xiangshan.CoreResetElab <outdir> [список]`, цели
  `ctrl_keep, ctrl_sweep, gates, dcache_keep, dcache_sweep` (`dcache_sweep` — отдельным запуском JVM из-за
  глобального состояния SramHelper). Детали, на которых спотыкались:
  - `gates`: `TLClientNode` / `TLManagerNode`, g0 = l1d (`early = false`, TL-C), g1 = l1i (`early = true`),
    TLResetIsolation; менеджер `TransferSizes(1, 16)`, beat 8; модуль `with RequireAsyncReset`.
  - `dcache_*`: `DCacheWrapper` + менеджер + клиент ICache ctrl, `with RequireAsyncReset`,
    `ClockGate.genTeSrc` `cgen := 0`, `SramHelper.genBroadCastBundleTop() := 0`.
  - конфиг: `top.ArgParser.parse(Array("--config","MinimalConfig","--num-cores","1"))`, затем `alter` с
    `EnableCoreReset` / `CoreResetKeepL1` и `XSCoreParamsKey`.
  - разные target-dir для каждой цели.
- `scripts/extract_rtl.py <outdir> [rtl]` вырезает из вывода: `CoreResetCtrl` (keep/sweep), `TLQuiesceGate`,
  `TLQuiesceGate_1`, `TLResetIsolation` → `verification/rtl/`; `TLMonitor` заменяются заглушками
  (`rtl/TLMonitor_stubs.sv`, только порты).

---

## 6. Проверка (verification/) — изменения относительно v4

Инструменты: Verilator 5.049, Yosys 0.70 + SymbiYosys, `yosys-abc` (PDR), Boolector для BMC/cover.
Конфигурации: только **KEEP** (по умолчанию, `""`) и **CFG_SWEEP**. LEVEL/PULSE удалить отовсюду
(run.sh, regress, soak, coverage, regress_summary, run_formal: конфиги `k`, `s`).

### 6.1. model/cr_ctl_models.sv

- `cr_gate`: без `idle`; мутант `GATE_MUTANT_ALWAYS_QUIET`.
- `cr_iso`: выход `quiet`; мутант `ISO_MUTANT_ALWAYS_QUIET`.
- `cr_ctrl #(KEEP, RST_CYCLES)`: порты `l1_idle, core_in_reset, early_block, early_quiet`; автомат как в 4.1.
  Мутанты: `CTRL_MUTANT_{ISO_LATE, ISO_EARLY_DROP, NO_ALIVE, NO_FE_WAIT, NO_EARLY_QUIET, NO_DRAIN, STALE_QUIET,
  NO_L1_IDLE, RESET_EARLY, NO_EARLY_BLOCK, LATE_HOLDB, NO_HOLD_IN_RELEASE, NOKEEP_HOLDB}`.

### 6.2. model/cr_env_models.sv

- **cr_dcache** переписан: MainPipe 3 стадии (виды K_PROBE / K_STORE / K_FLUSH), проверка конфликта набора,
  `pq_v` + регистр выбора `pq_sel`, слот ProbeAck `pa`, задержка записи в s3 `dw_busy` 0..2 такта (0..6 с SLOW),
  точный `idle` (те же 4 флага, что в RTL), выход `flush_idle`, `busy_true` (настоящее состояние для проверки
  стенда), мутант `FLUSH_MUTANT_NO_MP_WAIT`. Хелперы `mp_line_busy(addr, skip)`, `can_alloc(addr, vw_rnd, skip, vw)`;
  `wb_conflict` учитывает `pa`; BtoT-апгрейд проверяет `wb_conflict`; flush в s3 **не** ждёт ProbeQueue.
- **cr_buf1**: одноместный буфер в домене сброса ядра (с мусором на выходе в сбросе) — модель
  `l1d_to_l2_buffer` на B и C.
- **cr_l2**: Get некогерентного клиента к строке L1D в T ждёт Probe toB (`ul_np`, выход `n_get_probe`);
  проверка Acquire ослаблена, если для строки в полёте Probe (Acquire может обогнать ProbeAck через буфер C —
  это законно, CoupledL2 так и делает).

Ошибки моделей, найденные по ходу (не повторять): промах store не аллоцировался (`mp_line_busy` видел сам себя →
параметр `skip`); Acquire раньше ProbeAck той же строки (`wb_conflict` + `pa`); BtoT до ProbeAck; взаимная
блокировка flush в s3 ↔ Probe в PQ (убрано ожидание PQ); `//`-комментарий внутри условия ломал синтаксис;
иерархическая ссылка на enum → числа.

### 6.3. tb/cr_tb.sv, tb/cr_monitors.sv

- Без LEVEL. `fe_rst` — цепочка 4 флопов после сброса ядра (frontend выходит позже `alive`; иначе мутант
  `NO_FE_WAIT` не ловится). `u_bufb` / `u_bufc` между DCache и гейтом 0 (провода `db_*`, `dc_*`).
  Гейты g1/g2: `block = early_block`.
- Новые проверки: ни одного нового некогерентного запроса после начала последовательности; ничего некогерентного
  не открыто в sDrain; ни одного Probe через гейт в sDrain; конец последовательности только с frontend вне
  сброса; выход из сброса только после снятия запроса; буферы пусты и `busy_true = 0` в точке сброса; ровно
  один сброс на запрос (`check_resets`).
- Строка статистики: `drain: sDrain-phases= longest-sDrain= probes-held-in-sDrain= get-probes=`.
- SCEN 6 — 6 направленных случаев (0–5): 3 — снуп в начале sFlush; **4 — первый такт sDrain**; **5 — последний
  такт sFlush** (условие `u_dc.fst == 1 && KEEP || u_dc.fst == 3 && u_dc.inflight == 0`). Строки
  `directed: first-cycle-of-sDrain offered-in-sDrain=… transition-later=…` и
  `directed: last-cycle-of-sFlush offered-in-sFlush=… later=…`.
- KEEP `debug_hold`: один Probe ждёт.
- txmon: проверки «Probe в sDrain», «некогерентный старт после начала», «некогерентный открыт на входе в sDrain».
  probe_sb: `WAIT_IN_RESET(KEEP)`, 5 фаз.
- **Ошибка стенда, найденная длинным прогоном sweep (SCEN 6 seed 24):** `quiet_env` ждал тишины DCache без
  MainPipe, и эталон строки B запоминался, пока store в s3 ждал BtoT-апгрейда. Исправление:
  ```systemverilog
  while ((l2_busy || u_l2.prb_v || u_dc.busy_true || db_v || cc_v) && i < 20000) begin @(posedge clk); i++; end
  ```

### 6.4. formal/

- `fv_boundary.sv`: входы `l1_idle`, `fe_free`; цепочка fe (frontend на 2 такта позже); свойства P1–P20
  (новые/изменённые: P5 quiet корректен, P8 B закрыт только в процедуре, P8B ограничение после снятия запроса,
  P8N Probe держится только в sDrain (sweep), **P9** нет новых некогерентных запросов, **P10** некогерентные
  тихи в sDrain, P13, P14, **P18** B держится с первого такта sDrain, **P19** точка сброса после `done && idle`,
  **P20** запуск только вне сброса frontend); cover C1–C9.
- `run_formal.sh [k|s]`: prove (abc pdr) для `rstCycles` 100 и 16, bmc 40, cover, мутанты (bmc 60, rst 16),
  эквивалентные мутанты `GATE_MUTANT_NO_ISO_A`, `ISO_MUTANT_ALWAYS_QUIET` должны доказываться.
- `eq_chisel.sv` + `run_equiv.sh`: miter-ы `eq_ctrl` (keep/sweep), `eq_gate_c`, `eq_gate_ul`, `eq_iso` — RTL из
  Chisel ↔ модели, bmc 30 + prove.

Ожидаемые результаты (так было до сброса окружения): k — prove100 PASS (~53 с), prove16 PASS (~3,5 с), bmc PASS,
cover 8/8; s — аналогично; все мутанты FAIL (например NO_DRAIN → P19 такт 4, STALE_QUIET → P1 такт 4,
NO_EARLY_BLOCK → P9 такт 2, NO_EARLY_QUIET → P10 такт 3, LATE_HOLDB → P18 такт 3, NO_FE_WAIT → P20 такт 24,
RESET_EARLY → P13 такт 21); эквивалентность 5/5 PASS (секунды).

### 6.5. scripts/

- `regress.sh`: конфиги `""` и `CFG_SWEEP`; сценарии 1–3 × 15, +SLOW × 5, 5 × 10, 6 × 5, 7 × 5, 4 × 3 (наивный);
  мутанты, в т. ч. `NO_HOLDB` на SCEN 6, `STALE_QUIET` на SCEN 6, `LATE_HOLDB` на SCEN 6, `NO_EARLY_*` на 2/5.
  **`CTRL_MUTANT_NO_DRAIN` в sweep — на SCEN 6** (на SCEN 2 он иногда эквивалентен: после обхода в sDrain открыт
  только Probe последнего такта sFlush). Редкие мутанты на подобранных seed-ах: CUT_A K `2:1 2:3 2:4 2:10 2:11`,
  S `2:1 2:2 2:3 2:4 2:5`; NO_WBQ_WAIT K `5:1 5:2 5:3 5:5 5:6`; NO_MP_WAIT K `2:3 2:12 2:14 5:1 5:6`.
  Ожидаемо проходящие (`+EQUIV`): `NO_L1_IDLE` (обе), `NO_MP_WAIT` (sweep).
- `soak.sh`, `coverage.py` (ключи `drain.*`, `dir.drain_first_cycle`, `dir.flush_last_cycle` — последний
  разбирать **до** общего `directed:`), `regress_summary.py`, `seedsearch.sh` (env `MUTANTS`),
  `extract_rtl.py`.
- **Не запускать сборку Verilator одной конфигурации из двух процессов одновременно** (regress и soak собирали
  `build/obj` параллельно → испорченный бинарник, все прогоны FAIL). Сначала собрать `build/obj` и
  `build/obj_CFG_SWEEP`, потом запускать параллельно.

Ожидаемо: длинный прогон 490/490 на конфигурацию; самая длинная sDrain ~80 тактов (SLOW).

---

## 7. Документация (PDF)

Скрипты генерации v4 потеряны: PDF придётся собирать заново (Python + reportlab, кириллический шрифт DejaVu).
Основа текста — `xscore_reset_sweep_iso.pdf` (v4): `pdftotext -layout`, затем переработать под v5.

### Стиль (обязательно)

- Русский язык, подробно: каждый модуль и фрагмент кода объяснён; фрагменты патча с подсветкой (зелёный —
  добавлено, красный — удалено, серый — контекст).
- Блок-схемы и диаграммы последовательностей; врезки «Почему так» с обоснованием.
- Ссылки на TileLink: 1.8.1 — `[[раздел|стр.]]` **синим**, 1.9.3 — `[[@раздел|стр.]]` **зелёным**.
  Используемые: приоритет каналов A<B<C<D<E [[2.2|12]], снятие valid непринятого beat-а (1.8.1 §4.1, стр. 19),
  правило прогресса 3.i [[5|28]], 100 тактов сброса §3.2.2, адаптер §3.2.3, ProbeAck NtoN законен.

### Структура (как в v4, обновить)

1. Задача и что изменилось (таблица изменений; таблица KEEP / SWEEP); 1.3 обход L1D, AcquirePerm, как CoupledL2
   принимает Release и ProbeAck; **1.4 сброс-уровень**; **1.5 раннее закрытие A, быстрое закрытие B, флаги
   пустоты** (1.5.1–1.5.3, включая зависимость Get → Probe в CoupledL2); 1.6 изоляция домена сброса (таблица
   всех сигналов).
2. Понятия TileLink и Debug Module; справочник модулей.
3. Где изменения (таблица файлов: Probe.scala 5.4, MainPipe 5.5, DCacheWrapper 5.6, FakeDCache 5.7).
4. Последовательность (фазы 4.1–4.7) с диаграммами: общая, KEEP, SWEEP; автомат (5 состояний); диаграмма
   изоляции «sReset (≥ 100 тактов и до снятия запроса)».
5. Изменения DCache (FlushUnit, флаги, Probe.scala, MainPipe busy, DCacheWrapper, FakeDCache).
6. CoreReset.scala (гейт, изоляция, контроллер), XSTile, YAML.
7. Проверка: 7.1 Chisel (компиляция, elaboration модулей, эквивалентность); 7.2 формально (таблица P1–P20,
   результаты k/s, таблица мутантов с контрпримерами); 7.3 симуляция (сценарии, проверки, таблица KEEP/SWEEP,
   мутанты, эквивалентные в симуляции, врезка «что нашла сама проверка» — включая ошибку стенда из 6.3);
   7.4 временные диаграммы.
8. Подключение (порты, Debug Module, выбор KEEP/SWEEP — SWEEP для отладки через SBA; время без 16 тактов).
9. Ограничения (полная elaboration не сделана; KEEP — возможна взаимная блокировка со снупом при удержании;
   зависшее устройство; новые места в DCache требуют флага; и т. д.).
10. Отличия от v4 (таблица) и состав архива.

### Временные диаграммы (из VCD, сборка tb с трассировкой)

1. **Sweep, SCEN 1 seed 1**: вся последовательность (earlyBlock, quiet некогерентных, DCacheFlushUnit,
   l1.done, строк в L1D / в директории, события C/D/B, gateBlock, holdProbe, ackProbe, isolate, сброс ядра,
   сброс frontend, l1.alive). Было: запрос-импульс в такте 6, sFlush 6–42, sDrain 43 (1 такт), sReset 44–144,
   sRelease 145–151.
2. **KEEP, SCEN 6 seed 1, случай 5** (Probe в последнем такте sFlush), крупно ~30 тактов: Probe принят в
   последнем такте sFlush, sDrain ждёт его ProbeAckData через буфер C (было 10 тактов), затем сброс.
3. **KEEP, SCEN 6 seed 1, случай 4** (Probe toN к грязной строке в первом такте sDrain): Probe держится весь
   сброс, после запуска — ProbeAckData из горячей L1D. События B «ждёт» рисовать битом `lb_v`, а не
   событиями по тактам (иначе полосатость); выход буфера B маскировать во время сброса (мусор).
4. **Момент установки сброса крупно** (тот же сброс): holdProbe с первого такта sDrain, L2 предлагает Probe,
   B ready = 0; coreReset и isolate на одном фронте; случайные выходы ядра замаскированы на стороне тайла.

---

## 8. Пакет

```
kmh_core_reset_v5/
  XiangShan/...            изменённые файлы (без стенда elaboration и .mill-jvm-opts)
  _original/XiangShan/...  upstream c098f99 (включая Probe.scala)
  core-reset.patch         git diff c098f99 --ignore-submodules
  install.sh               из v4 с правками: заголовок (уровень, ранний A, флаги), Probe.scala — новый
                           изменяемый файл, финальные echo без CoreResetLevel; метки MARK покрывают
                           MainPipe/Probe через «DCacheFlushUnit»
  README.md                что изменилось, параметр, установка, подключение, сборка, таблица результатов k/s
  xscore_reset_v5.pdf
  verification/            model, tb, formal (fv_boundary, run_formal, eq_chisel, run_equiv), rtl, elab,
                           scripts, results_*, coverage_*.json
```

Затем zip и краткое резюме пользователю по-русски: Chisel компилируется (v4 не компилировалась — конфликт `name`);
модули elaborate-ятся; эквивалентность RTL ↔ моделям доказана; полная elaboration XSNoCTop не сделана (если так и
останется); итоговые цифры формальной проверки, регрессии и длинных прогонов.

---

## 9. Порядок работы

1. Клон XiangShan `c098f99` (+ подмодули), установка v4, ветка `core-reset-v5`.
2. Изменения Chisel по разделу 4 → `mill xiangshan.compile` → стенд elaboration → полная elaboration XSNoCTop
   (KEEP и SWEEP).
3. `verification/` по разделу 6 → smoke (сценарии 1, 2, 3, 5, 6, 7 для обеих конфигураций) → formal k, s →
   `extract_rtl.py` + `run_equiv.sh` → regress → soak (не собирать параллельно!).
4. VCD и временные диаграммы → PDF → пакет → zip → резюме.
