# Сброс XSCore без сброса L2 — дизайн v6

Ветка `core-reset-v6`, база `kunminghu-v2` = 7b16188 (CoupledL2 55d8e69). Документ — спецификация для
исполнителя и ревьюера. Номера строк XiangShan — по 7b16188, CoupledL2 — по 55d8e69, TileLink — по
спецификации 1.9.3 (`[@раздел]`). Код v5 доступен как `git show core-reset-v5:<путь>`; там, где v6 берёт
его без изменений, это сказано явно.

Редакция 2 (16.11.2026): учтены независимое ревью и решения пользователя —
`core-reset/review/DESIGN_review_1.md`; сводка — раздел 12.

Обозначения режимов: **FULL** — `CoreResetKeepL1 = false` (по умолчанию), **KEEP** — `CoreResetKeepL1 = true`.

---

## 1. Требования и параметры

### 1.1. Требования (решение пользователя 15.11.2026)

1. Сбрасывается только XSCore (ядро + L1) по `ndmreset` / `hartreset` Debug Module или по запросу кластера.
   L2 (CoupledL2, tl2chi) и CHI-порт тайла работают, кредиты и LINKACTIVE не меняются.
2. FULL (по умолчанию): L1D после сброса пуста (meta, error, tag — на сбросе ядра, как в upstream). Пока ядро в
   сбросе, гейт L1D сам отвечает на каждый Probe `ProbeAck NtoN`. Обхода (sweep / flush) нет вообще.
3. KEEP: всё состояние, нужное для целостности строк L1D, — в домене сброса тайла; Probe к L1D во время
   сброса держится; массивы защищены от записи (freeze).
4. Изоляция домена сброса ядра включается **не меньше чем за один такт до** установки сброса ядра.
5. Из v5 остаются: сброс-уровень (пока держат запрос, не меньше `rstCycles` = 100 тактов); раннее закрытие A
   некогерентных агентов с первого такта последовательности; точные флаги пустоты DCache; закрытие B с
   первого такта sDrain и решение по `quiet` текущего такта.
6. DCache опустошается перед сбросом в обоих режимах (нет незавершённых Acquire / Release / GrantAck /
   ProbeAck; MissQueue, WritebackQueue, MainPipe, ProbeQueue пусты), но строки не обходятся.

### 1.2. Параметры

| Параметр | Где | По умолчанию | Что строит |
|---|---|---|---|
| `EnableCoreReset` | `SoCParameters` (`system/SoC.scala`, после `EnablePowerDown`, стр. 144), `HasSoCParameter`; ключ YAML `EnableCoreReset` (`top/YamlParser.scala`) | `false` | `false` — RTL upstream без изменений (см. 5.0). `true` — гейты, `TLResetIsolation`, `CoreResetCtrl`, `DCacheQuiesceUnit`, порты запроса |
| `CoreResetKeepL1` | там же; ключ YAML `CoreResetKeepL1` | **`false`** (в v5 было `true`) | `false` — FULL: массивы L1D на сбросе ядра, `ackProbe`. `true` — KEEP: meta / error / tag на сбросе тайла, `holdProbe`, `freeze` (запись всех массивов, чтение SRAM и meta / error). Имеет смысл только с `EnableCoreReset` |
| `rstCycles` | аргумент `CoreResetCtrl` | 100 | минимальная длина сброса, `require(100 ≤ rstCycles < 255)` [@3.2.2] |
| `isoCycles` | аргумент `CoreResetCtrl` | 1 | опережение изоляции, тактов; `require(1 ≤ isoCycles ≤ 16)`, для KEEP — `require(isoCycles ≤ 2)` (см. 4.3) |

`rstCycles` и `isoCycles` в `SoCParameters` и YAML не выносятся (решение 16.11.2026).

### 1.3. Имена (изменение относительно v5; приняты 16.11.2026)

Flush в v6 нет, поэтому: состояние `sFlush` → **`sQuiesce`**; `DCacheFlushUnit` → **`DCacheQuiesceUnit`**; файл
`mainpipe/FlushUnit.scala` → **`mainpipe/QuiesceUnit.scala`**; `flushBlock` → `quiesceBlock`; порт
`metaReset` / `l1_meta_reset` → `keepReset` / `l1_keep_reset` (на нём три массива: meta, error, tag). Новое
состояние **`sIso`**. Глоссарий `CLAUDE.md` дополнить: «опережение изоляции (sIso)», sQuiesce вместо sFlush.

---

## 2. Контроллер `CoreResetCtrl`

Модуль в домене такта и сброса тайла. `class CoreResetCtrl(keepL1: Boolean, rstCycles: Int = 100, isoCycles: Int = 1)`;
`require(rstCycles >= 100 && rstCycles < 255)`, `require(isoCycles >= 1 && isoCycles <= 16)`,
`require(!keepL1 || isoCycles <= 2)`.

### 2.1. Состояния и переходы

```
sIdle    --req-->                                              sQuiesce  (busy := 1)
sQuiesce --l1Done && earlyQuiet-->                             sDrain
sDrain   --gatesQuiet && l1Done && l1Idle (тот же такт)-->     sIso      (isolate := 1, cnt := 0)
sIso     --cnt == isoCycles-1-->                               sReset    (coreReset := 1, cnt := 0)
sReset   --cnt >= rstCycles && !req-->                         sRelease  (coreReset := 0, releasing := 1)
sRelease --coreUp && !req-->                                   sIdle     (isolate := 0, releasing := 0, busy := 0)
sRelease --coreUp &&  req-->                                   sQuiesce  (isolate := 0, releasing := 0; busy остаётся 1)
```

Регистры (все `RegInit`, сброс тайла): `state` (6 значений), `cnt` (8 бит), `busy`, `isolate`, `coreReset`,
`releasing`. Квалификаторы сигналов из домена ядра — только регистры (`isolate`, `releasing`), а не декод
`state`: декод многобитного `state` может дать иголку на переходе, а квалификатор RDC обязан быть без иголок.

```scala
val l1Done = io.l1.done && !isolate              // core reset domain: looked at only while the core runs
val l1Idle = io.l1.idle && !isolate
val coreUp = releasing && io.l1.alive && !io.coreInReset   // core reset domain: only at the synchronous release

switch (state) {
  is (sIdle)    { when (io.req) { state := sQuiesce; busy := true.B } }
  is (sQuiesce) { when (l1Done && io.earlyQuiet) { state := sDrain } }
  is (sDrain)   { when (io.gatesQuiet && l1Done && l1Idle) { state := sIso; isolate := true.B; cnt := 0.U } }
  is (sIso)     { cnt := cnt + 1.U
                  when (cnt === (isoCycles - 1).U) { state := sReset; coreReset := true.B; cnt := 0.U } }
  is (sReset)   { when (cnt < rstCycles.U) { cnt := cnt + 1.U }
                  when (cnt >= rstCycles.U && !io.req) { state := sRelease; coreReset := false.B; releasing := true.B } }
  is (sRelease) { when (coreUp) { isolate := false.B; releasing := false.B
                    when (io.req) { state := sQuiesce } .otherwise { state := sIdle; busy := false.B } } }
}
```

### 2.2. Выходы по состояниям

| Выход | Выражение | sIdle | sQuiesce | sDrain | sIso | sReset | sRelease |
|---|---|---|---|---|---|---|---|
| `busy`, `hartInReset`, `earlyBlock` | регистр `busy` | 0 | 1 | 1 | 1 | 1 | 1 |
| `l1.req` | `sQuiesce \|\| sDrain \|\| sIso` | 0 | 1 | 1 | 1 | 0 | 0 |
| `gateBlock` (A L1D) | `sDrain \|\| isolate` | 0 | 0 | 1 | 1 | 1 | 1 |
| `holdProbe`, FULL | `sDrain \|\| sIso` | 0 | 0 | 1 | 1 | 0 | 0 |
| `ackProbe`, FULL | `sReset \|\| sRelease` | 0 | 0 | 0 | 0 | 1 | 1 |
| `holdProbe`, KEEP | `sDrain \|\| isolate` | 0 | 0 | 1 | 1 | 1 | 1 |
| `ackProbe`, KEEP | `false.B` | 0 | 0 | 0 | 0 | 0 | 0 |
| `isolate` | регистр | 0 | 0 | 0 | 1 | 1 | 1 |
| `l1.freeze` | KEEP: `isolate`; FULL: `false.B` | 0 | 0 | 0 | 1 / 0 | 1 / 0 | 1 / 0 |
| `coreReset`, `inReset` | регистр `coreReset` | 0 | 0 | 0 | 0 | 1 | 0 |

Пояснения:

- **sQuiesce** (бывший sFlush). A некогерентных закрыт (`earlyBlock`), DCache блокирует store / atomic / CMO /
  новые промахи и доводит начатое (`l1.req`). B открыт: Get некогерентного агента к строке, которую L1D
  держит в TRUNK / TIP, ждёт в CoupledL2 Probe к L1D, поэтому выход — только при `earlyQuiet` (v5, §4.2).
- **sDrain**. A L1D и B закрыты с первого такта (`holdProbe` — функция `state`). Решение — по `quiet`
  текущего такта. В обоих режимах Probe в sDrain **держится**: L1D ещё держит строки, отвечать за неё нельзя,
  а пускать новый Probe — значит не выйти из sDrain.
- **sIso**. Изоляция и freeze включены, сброса ещё нет. Ядро живо, но снаружи его уже не видно. `l1.req`
  остаётся 1: иначе DCache сняла бы блокировку и store из sbuffer вошёл бы в MainPipe за такт до сброса.
  Probe держится и в FULL: гейт отвечает NtoN только тогда, когда L1D действительно сбрасывается.
- **sReset**. `coreReset = 1` не меньше `rstCycles + 1` тактов и до снятия запроса.
- **sRelease**. `coreReset = 0`, цепочка ResetGen ядра выходит из сброса синхронно; изоляция держится до
  `coreUp` (DCache вне сброса и frontend вне сброса — последний в цепочке, `Frontend.scala:452`).

### 2.3. Опережение изоляции: времянка (isoCycles = 1)

```
такт            T-1     T       T+1     T+2 ...  X       X+1 ...  U       U+1
state           sDrain  sDrain  sIso    sReset   sReset  sRelease sRelease sIdle
gatesQuiet&done   0       1      1       -        -        -        -       -
isolate (рег.)    0       0      1       1        1        1        1       0
freeze (KEEP)     0       0      1       1        1        1        1       0
coreReset (рег.)  0       0      0       1        1        0        0       0
сброс ядра        0       0      0      асинхр.↑  1      синхр.↓ по цепочке ResetGen
alive, !feReset   1       1      1       0        0        0        1       1
req               -       -      -       -        0        -        -       -
```

- Фронт T→T+1: `isolate := 1`. Весь такт T+1 зажимы (гейты, `isoReset` / `isoHold`, freeze) стоят, а ядро ещё
  не в сбросе: его выходы меняются только синхронно. На фронте T+1→T+2 триггеры тайла захватывают уже
  зажатые значения.
- Фронт T+1→T+2: `coreReset := 1`. Сеть сброса ядра (`ResetGen` в XSTile, `ResetGen.scala:28–44`: установка
  асинхронная, снятие через 3 триггера) поднимается после этого фронта; выходы ядра меняются в такте T+2
  в произвольный момент — зажимы стоят уже полный такт.
- Запись, зарегистрированная на один такт позже s3 (`L1CohMetaArray` — `s1_way_wen`,
  `AsynchronousMetaArray.scala:117–122`; `BankedDataArray` — `wen_reg`, `BankedDataArray.scala:940–945`;
  SRAM DCache — `latency = 1`), от s3 в такте T-1 фиксируется на фронте T→T+1. В такте решения T freeze = 0,
  так что запись проходит; до асинхронного сброса остаётся ещё такт T+1. Замечание ревью v5 про «нулевой
  запас» снято: запас теперь `isoCycles` тактов.
- Снятие: фронт X→X+1 `coreReset := 0`; ядро выходит из сброса синхронно, по цепочке
  XSTile → MemBlock → {DCache, backend} → frontend (по 3 такта на ступень). В такте U контроллер видит
  `alive = 1` и `resetInFrontend = 0` (оба значения установились на фронте, начинающем U, или раньше); на
  фронте U→U+1 `isolate := 0`. Изоляция снимается не раньше чем через полный такт после выхода последнего
  домена ядра из сброса.

### 2.4. Запрос, `busy`, `hartInReset` (находки ревью (b), (e))

- **Запрос — уровень, фиксируется и не отменяется.** Один такт `req` в sIdle запускает всю
  последовательность. Это оставлено намеренно: запрос сброса, который увидели, обязан закончиться сбросом
  (отладчик, поднявший и сразу снявший `ndmreset`, ждёт `havereset`). Сброс снимается, когда `req = 0` и
  прошло `rstCycles`.
- **`hartInReset` = `busy`** — с первого такта последовательности, а не с sReset. В окне sQuiesce / sDrain
  отладчик больше не видит «харт не в сбросе». Для Debug Module rocket-chip это даёт: `haveResetBitRegs`
  взводится сразу (`Debug.scala:1009–1011`), `haltedBitRegs` и `resumeReqRegs` чистятся (`:1317–1326`),
  halt-on-reset держит debug-прерывание до выхода (`:954–960`); ревью подтвердило корректность. Харт при
  этом ещё несколько тактов работает — наружу это не выходит: A некогерентных закрыт, store в DCache не идут.
- **`inReset`** подключён: новый выход тайла `core_in_reset` = «сброс XSCore **установлен**» (регистр
  `coreReset`, только sReset). Он падает в начале sRelease, а ядро выходит из сброса ещё ~20 тактов (цепочка
  ResetGen) — «ядро работает» означает только `busy` = 0. Кластеру сигнал нужен, чтобы отличить
  «опустошение» от «сброс установлен» (сторожевой таймер). Правило для `reset_vector` — в 8.1.
- **Иголка на запросе.** Запрос не отменяется, поэтому иголка на асинхронном входе запускает полный сброс:
  входы запроса подаются только с выходов триггеров (8.1).
- **`busy` без провала.** Переход sRelease → sQuiesce при `req = 1` — напрямую, `busy` и `hartInReset`
  остаются 1; в v5 между двумя последовательностями подряд `busy` падал на такт.
- Таймаута в контроллере нет (см. 8.1).

### 2.5. Assert-ы и инварианты

```scala
assert(busy === (state =/= sIdle))
assert(isolate === (state === sIso || state === sReset || state === sRelease))
assert(coreReset === (state === sReset))
assert(releasing === (state === sRelease))
assert(!coreReset || RegNext(isolate, false.B), "XSCore reset without an isolation lead")
assert(!isolate || io.gatesQuiet, "TileLink traffic between XSCore and L2 while XSCore is isolated")
assert(!(RegNext(isolate, false.B) && !isolate) || RegNext(releasing && !coreReset, false.B))
```

Формальные свойства (взамен / в дополнение к P1–P20 v5): `coreReset` поднимается, только если `isolate` стоял
`isoCycles` предыдущих тактов; `isolate` падает только из sRelease при `coreUp`; между sDrain-решением и
`coreReset` ни одно сообщение не пересекает гейт; `l1.req = 1` во всём sIso.

---

## 3. `TLQuiesceGate` и `TLResetIsolation`

Берутся из v5 (`core-reset-v5:src/main/scala/xiangshan/CoreReset.scala`) с тремя изменениями.

1. **Зажим B по `isolate`** (новое). В v5 B при изоляции закрывали только `holdB` / `ackB` — декоды `state`.
   Теперь первым стоит зажим от регистра:

   ```scala
   in.b <> out.b; out.c <> in.c; out.e <> in.e
   when (io.isolate) {                       // RDC qualifier: a register
     in.c.ready := false.B; out.c.valid := false.B
     in.e.ready := false.B; out.e.valid := false.B
     in.b.valid := false.B; out.b.ready := false.B
   }
   when (io.holdB) { in.b.valid := false.B; out.b.ready := false.B }
   when (io.ackB || ackPending) { in.b.valid := false.B; out.b.ready := takeB }
   // ackPending / ackProbe / ProbeAck NtoN — как в v5
   ```

   Порядок `when` существен (last connect): `out.b.ready` при `isolate` не зависит от `in.b.ready` ни в одной
   ветви — либо 0, либо `takeB` (регистры гейта).
2. **Комментарии**: sweep убрать. `ackB` (FULL): L1D сбрасывается вместе с ядром, строк не отдаёт; NtoN — то,
   что ответила бы сброшенная L1D; директория L2 до этого ответа устарела (раздел 7.2). `holdB` (KEEP и
   sDrain / sIso в FULL): Probe ждёт в L2.
3. **Заголовок файла**: лицензия Mulan PSL v2 (находка (f)), описание последовательности — по разделу 2.

Без изменений: `class TLQuiesceGate(val gateName: String, val early: Boolean)`, `gname` (не `name`),
`require(!(early && hasBCE))`, блокировка A только на границе сообщения (`io.block && aFirst`), зажим A / D
по `isolate`, счётчики `reqs`, `grants`, `probes`, `releases`, `quiet`, `takeB = ackB && !holdB && !ackPending`,
`assert(!(ackB && holdB))`, `assert(!isolate || holdB || ackB)`; `TLResetIsolation` целиком.

Что гейт делает с Probe:

| | sQuiesce | sDrain, sIso | sReset, sRelease | после |
|---|---|---|---|---|
| FULL | проходит к DCache | держится в L2 (`holdB`) | гейт принимает и отвечает `ProbeAck NtoN` (`ackB`), по одному | проходит к пустой DCache → NtoN |
| KEEP | проходит к DCache | держится (`holdB`) | держится (`holdB`) | проходит к DCache с сохранёнными строками |

`ackPending` может пережить конец последовательности (L2 долго не берёт C): B и C ядра закрыты, пока ответ
не ушёл (`when (io.ackB || ackPending)`), в счётчики `quiet` он не входит — это сообщение гейта, а не ядра.

---

## 4. DCache без flush

### 4.1. Что исчезает из v5

- Весь обход: состояния `sSweep`, `sWait`, регистры `set` / `way` / `inflight`, порты `pipe_req` / `pipe_resp`,
  параметр `sweep` в `FlushUnit.scala`.
- В `MainPipe.scala` — всё, кроме `busy`: поле `MainPipeReq.flush`, порты `flush_req` / `flush_resp`,
  `withFlush`, пятый вход арбитра, `flush_need_data`, `s1_flush*`, `flush_update_meta`, `flush_wb`,
  `s3_flush_can_go`, правки `io.wb`, `access_flag_write`, `opType.release`.
- В `DCacheWrapper.scala` — `mainPipe.io.flush_req` / `flush_resp`.
- В `WritebackQueue.scala`, `MissQueue.scala`, `Probe.scala` правки v5 остаются (флаги пустоты).

### 4.2. Что остаётся: `DCacheQuiesceUnit` (опустошение)

```scala
class L1QuiesceIO extends Bundle {
  val req    = Output(Bool())   // level: drain L1D and keep it blocked (no store, atomic, CMO, new miss)
  val freeze = Output(Bool())   // KEEP: XSCore is isolated, no access to the arrays that survive (0 in FULL)
  val done   = Input(Bool())    // drained; stays high while req is high
  val idle   = Input(Bool())    // all four emptiness flags, this cycle
  val alive  = Input(Bool())    // the DCache control logic is out of reset
}

class DCacheQuiesceUnit(implicit p: Parameters) extends DCacheModule {
  val io = IO(new Bundle {
    val quiesce = Flipped(new L1QuiesceIO)
    val block = Output(Bool())
    val mq_empty = Input(Bool()); val wbq_empty = Input(Bool())
    val mp_empty = Input(Bool()); val pq_empty  = Input(Bool())
  })
  val sIdle :: sDrain :: sDone :: Nil = Enum(3)
  val state = RegInit(sIdle)
  val idle = io.mq_empty && io.wbq_empty && io.mp_empty && io.pq_empty
  switch (state) {
    is (sIdle)  { when (io.quiesce.req) { state := sDrain } }
    is (sDrain) { when (!io.quiesce.req) { state := sIdle } .elsewhen (idle) { state := sDone } }
    is (sDone)  { when (!io.quiesce.req) { state := sIdle } }
  }
  io.block := state =/= sIdle
  io.quiesce.done := state === sDone
  io.quiesce.idle := idle
  val alive = RegInit(false.B); alive := true.B
  io.quiesce.alive := alive
  XSPerfAccumulate("l1_quiesce", state === sIdle && io.quiesce.req)
  XSPerfAccumulate("l1_quiesce_cycles", state === sDrain)
}
```

Одинаков для FULL и KEEP. Флаги — как в v5:

| Флаг | Выражение |
|---|---|
| `mq_empty` | `!Cat(entries.map(_.io.busy)).orR && !miss_req_pipe_reg.reg_valid() && cmo_unit.io.req.ready`; `MissEntry.io.busy := req_valid` |
| `wbq_empty` | `!Cat(entries.map(_.io.block_addr.valid)).orR` |
| `mp_empty` | `!(s1_valid \|\| s2_valid \|\| s3_valid)` (`MainPipe.io.busy`) |
| `pq_empty` | `!Cat(entries.map(_.io.block_addr.valid)).orR && !selected_req_valid` |

После `done` занятой DCache может сделать только Probe (B открыт до sDrain); поэтому контроллеру нужен и
`idle` текущего такта, и `quiet` гейта (он покрывает ProbeAck в `l1d_to_l2_buffer`).

В FULL опустошение нужно не ради строк, а ради протокола и одинаковой логики: начатый Acquire должен
получить Grant и GrantAck, ReleaseData не должна оборваться между beat-ами, ответ не должен прийти в
сброшенное ядро. Грязные строки при этом не спасаются (раздел 7.2).

### 4.3. KEEP: что переходит в домен сброса тайла

Решение 16.11.2026: на сбросе тайла — **meta, error, tag** (как в v5 после a43a292); `bankedDataArray`
остаётся на сбросе ядра. Массив на сбросе тайла — это `<array>.reset := io.keepReset.get` в `DCacheImp`.
Сигнал `keepReset` строится в XSTile отдельным `ResetGen` от базового сброса тайла (без `coreReset`).

| Состояние DCache | Реализация | KEEP | Почему |
|---|---|---|---|
| `metaArray` (`L1CohMetaArray`) | триггеры `RegInit`, 2 бита на путь (`AsynchronousMetaArray.scala:67–71`) | **сброс тайла**; freeze записи и `read.valid` | состояние когерентности — это и есть «L1D держит строку» |
| `errorArray` (`L1ErrorMetaArray`) | триггеры `RegInit` (`AsynchronousMetaArray.scala:204–208`) | **сброс тайла**; freeze записи и `read.valid` | флаги denied / corrupt принадлежат сохранённым строкам |
| `tagArray` (`DuplicatedTagArray`) | SRAM `shouldReset = false`; `TagSRAMBank.rst_cnt` — `RegInit`, после сброса пишет нули во все наборы (`TagArray.scala:66–75`) | **сброс тайла**; freeze записи и чтения | иначе сброс ядра стирает теги при сохранённой meta (критическая находка ревью v5, a43a292) |
| `bankedDataArray` (`BankedDataArray`; с WPU — `SramedDataArray`) | SRAM `shouldReset = false`; ступень записи `wen_reg` (`BankedDataArray.scala:940–945`) | сброс ядра (как upstream); freeze записи и чтения | SRAM сброса не имеет и данные хранит сама. Перенос модуля на сброс тайла не нужен и создал бы пересечения `rst_core` → `rst_tile` без квалификатора (регистры адресов чтения и конфликтов банков, MBIST — находка 3 ревью). Защиту содержимого даёт зажим разрешений на границе модуля |
| `prefetchArray`, `accessArray` | триггеры | сброс ядра | подсказки предвыборки; после сброса «не предвыбрано / не использовано», на корректность не влияют |
| `replacer` (`DCacheWrapper.scala:1675`) | регистры политики | сброс ядра | выбор жертвы; вытеснение действительной строки идёт через Release независимо от истории |
| WPU (`dwpuParam.enWPU`, по умолчанию `false`, `Parameters.scala:261`) | предсказатель пути | сброс ядра | предсказание проверяется тегом |
| резервирование LR/SC (MainPipe) | регистры | сброс ядра | после сброса резервирования нет — так и должно быть |
| MissQueue, WritebackQueue, ProbeQueue, MainPipe, `l1d_to_l2_buffer` | регистры | сброс ядра | пусты в точке сброса (флаги пустоты, `quiet` гейта) |
| `bloomFilter`, `counterFilter`, мониторы предвыборки, `CtrlUnit` | регистры | сброс ядра | статистика и регистры инъекции ошибок |
| sbuffer | регистры | сброс ядра | закоммиченные, но не записанные в DCache store теряются, как при любом сбросе; L2 их не видела |

Freeze (`io.quiesce.freeze`, KEEP, регистр `isolate` домена тайла) — всё в `DCacheImp` и только при
`io.keepReset.isDefined`:

```scala
io.keepReset.foreach { r =>
  metaArray.reset := r; errorArray.reset := r; tagArray.reset := r
  when (io.quiesce.get.freeze) {
    metaArray.io.write.foreach(_.valid := false.B)
    metaArray.io.read.foreach(_.valid := false.B)
    errorArray.io.write.foreach(_.valid := false.B)
    errorArray.io.read.foreach(_.valid := false.B)
    tagArray.io.write.valid := false.B
    tagArray.io.read.foreach(_.valid := false.B)
    bankedDataArray.io.write.valid := false.B
    bankedDataArray.io.write_dup.foreach(_.valid := false.B)
    bankedDataArray.io.read.foreach(_.valid := false.B)
    bankedDataArray.io.readline.valid := false.B
  }
}
```

Блок ставится **после** всех `<>`-соединений этих портов — после цикла `DCacheWrapper.scala:1332–1340`
(последнее соединение `bankedDataArray.io.read(i)`), иначе его перекроют.

Что даёт каждый зажим:

- **Запись** meta / error / tag — вход ступени записи (`s0_way_wen`, `AsynchronousMetaArray.scala:109–122`;
  `wen` SRAM тегов, `TagArray.scala:81`) не зависит от логики ядра.
- **Запись данных.** Зажат вход ступени (`io.write.valid`, `io.write_dup(i).valid`); сами триггеры ступени
  (`write_valid_dup_reg`, `RegNext(io.write.valid, false.B)`, `BankedDataArray.scala:697–701, 942`) остаются в
  домене ядра. Они равны 0 с такта решения (MainPipe пуст) и получают 0 весь sIso; асинхронный сброс ставит
  их в 0 — значение не меняется, WE SRAM статичен. Это пересечение без квалификатора после триггера,
  оформляется исключением R6 (а).
- **Чтение SRAM тегов и данных.** SRAM однопортовые (`singlePort = true`), CE = `ren || wen`. Чтение формируют
  LoadPipe — они работают до самого сброса. При асинхронной установке сброса `ren` и адрес меняются в
  произвольный момент такта; для SRAM, содержимое которой обязано пережить сброс, это нарушение setup / hold
  на CE и адресе (типовые модели компилируемой SRAM при этом портят содержимое; допущение о библиотеке
  памяти, в RTL-симуляции эффекта нет). Зажим `read.valid` / `readline.valid` на границе модуля держит
  CE = 0 за `isoCycles` тактов до сброса.
- **`read.valid` meta / error.** Регистры ответа — без сброса, внутри модулей `rst_tile`
  (`RegEnable(…, read.valid)`, `AsynchronousMetaArray.scala:97–101`); при зажатом `read.valid` они не
  захватывают индекс из логики ядра, и в модули на сбросе тайла не остаётся путей без квалификатора.

`SramedDataArray` (ветка `dwpuParam.enWPU`) проверен: разрешения чтения банков строятся из тех же
`io.read(i).valid` и `io.readline.valid` (`BankedDataArray.scala:516–533`), ступень записи — из тех же
`io.write.valid` / `io.write_dup(i).valid` (`:391–397, 602–608`); зажимы на границе действуют так же, отдельной
логики не нужно.

Ограничение `isoCycles ≤ 2` для KEEP (находка 5 ревью). В sIso чтение SRAM зажато, а LoadPipe ещё работают:
запрос s0 остаётся без ответа, s1 сравнивает теги по выходу SRAM, который модель не обязана держать
(`holdRead = false`). При `isoCycles` = 1 и 2 такой s1 либо уже в сбросе, либо его assert
(`LoadPipe.scala:277`, `RegNext`) оценивается в сбросе; при `isoCycles ≥ 3` он сработал бы в живом ядре.
Наружу результаты таких load не выходят в любом случае (A закрыт, выходы ядра изолированы).

Assert-ы в `DCacheImp` (из v5, условие — наличие блока):

```scala
assert(!(io.quiesce.get.freeze && (tag_write_arb.io.out.valid || dataWriteArb.io.out.valid)),
  "DCache: L1D array write while XSCore is isolated")
assert(!(io.quiesce.get.done && wb.io.req.fire && wb.io.req.bits.voluntary),
  "DCache: Release started after the drain reported done")
```

---

## 5. Изменения по файлам (относительно 7b16188)

16 файлов, как в v5; `FlushUnit.scala` заменён на `QuiesceUnit.scala`, `MainPipe.scala` сокращается до порта
`busy`. Подмодули (CoupledL2, utility, rocket-chip) не меняются.

### 5.0. `EnableCoreReset = false` — структурная идентичность upstream (находка (d))

Решение: при `EnableCoreReset = false` Chisel порождает то же RTL, что 7b16188. Всё новое — под
`Option.when(EnableCoreReset)` / `if (EnableCoreReset)`; постоянно существующих портов, модулей и входов
арбитров нет. Правила:

- новые порты — `Option.when(...)(...)`, обращения через `.foreach` / `.map`;
- новые модули — `Option.when(...)(Module(...))`;
- изменённые соединения — `opt.foreach { x => when (x) { ... } }` поверх исходного соединения, исходная
  строка не трогается;
- в diplomacy — без `TLTempNode()` (решение 16.11.2026): `if (EnableCoreReset) a := gate := b else a := b`,
  где ветвь `else` — исходная строка upstream дословно; так же для `TLResetIsolation` и мостов предвыборки;
- в `HasDCacheParameters` (`DCacheWrapper.scala:90`) добавить
  `def coreResetEnabled = p(SoCParamsKey).EnableCoreReset` и
  `def coreResetKeepL1 = coreResetEnabled && p(SoCParamsKey).CoreResetKeepL1` — ими пользуются все модули и
  bundle DCache (импорт `SoCParamsKey` в файлах `mainpipe/` не нужен). Имена намеренно не совпадают с
  `val EnableCoreReset` / `CoreResetKeepL1` из `HasSoCParameter`: `HasDCacheParameters` подмешан во многие
  классы вне DCache (PTW, LSQ, триггеры CSR), совпадение имён `val` и `def` в двух trait дало бы конфликт.

Проверка идентичности — сравнение полного XSNoCTop с эталоном 7b16188 (раздел 9).

### 5.1. `system/SoC.scala`

После `EnablePowerDown: Boolean = false` (стр. 144) — запятая и два параметра с комментарием (по-английски):

```scala
  // Reset of XSCore (core + L1) alone, L2 and the CHI port keep running (see xiangshan/CoreReset.scala)
  EnableCoreReset: Boolean = false,
  // false: L1D is reset with the core and is empty afterwards (dirty lines are lost); a Probe offered while
  //        the core is in reset is answered by the gate in front of L1D (ProbeAck NtoN)
  // true : L1D keeps its lines: meta, error flags and tags are in the tile reset domain; they and the data
  //        SRAMs are not accessed while the core is isolated; a Probe offered meanwhile waits in L2
  CoreResetKeepL1: Boolean = false
```

В `HasSoCParameter` после `EnablePowerDown` (стр. 218): `val EnableCoreReset = soc.EnableCoreReset`,
`val CoreResetKeepL1 = soc.CoreResetKeepL1`.

### 5.2. `top/YamlParser.scala`

`YamlConfig`: после `EnablePowerDown: Option[Boolean],` (стр. 62) — `EnableCoreReset: Option[Boolean],`
`CoreResetKeepL1: Option[Boolean],`. После блока `EnablePowerDown` (стр. 217–221) — два блока `alter` по тому же
образцу (`copy(EnableCoreReset = enable)`, `copy(CoreResetKeepL1 = keep)`). Как в v5.

### 5.3. `xiangshan/cache/dcache/mainpipe/QuiesceUnit.scala` (новый)

Заголовок Mulan PSL v2; `package xiangshan.cache`; `L1QuiesceIO` и `DCacheQuiesceUnit` — код раздела 4.2.
Заголовочный комментарий: зачем опустошение (управляющая логика DCache сбрасывается, в точке сброса должна
быть пуста), четыре флага, три состояния, отличие FULL / KEEP (только в `DCacheImp`). Слова flush / sweep не
использовать.

### 5.4. `mainpipe/MainPipe.scala`

Только (после `atomic_resp`, стр. 138, и рядом с `io.meta_write.valid`, стр. 906):

```scala
    // a request (of any kind) is in s1, s2 or s3 (DCacheQuiesceUnit)
    val busy = Option.when(coreResetEnabled)(Output(Bool()))
  ...
  io.busy.foreach(_ := s1_valid || s2_valid || s3_valid)
```

### 5.5. `mainpipe/MissQueue.scala`

- `MissEntry.io` (после `wfi`, стр. 469): `val busy = Option.when(coreResetEnabled)(Output(Bool()))`;
  рядом со стр. 656: `io.busy.foreach(_ := req_valid)`.
- `MissQueue.io` (после `wfi`, стр. 1053): `val empty = Option.when(coreResetEnabled)(Output(Bool()))`;
  после стр. 1239:
  `io.empty.foreach(_ := !Cat(entries.map(_.io.busy.get)).orR && !miss_req_pipe_reg.reg_valid() && cmo_unit.io.req.ready)`.

### 5.6. `mainpipe/WritebackQueue.scala`

`WritebackQueue.io`: `val empty = Option.when(coreResetEnabled)(Output(Bool()))`; перед `TLArbiter.robin` (стр. 388):
`io.empty.foreach(_ := !Cat(entries.map(_.io.block_addr.valid)).orR)`.

### 5.7. `mainpipe/Probe.scala`

`ProbeQueue.io` (после `update_resv_set`, стр. 134): `val empty = Option.when(coreResetEnabled)(Output(Bool()))`;
после стр. 207: `io.empty.foreach(_ := !Cat(entries.map(_.io.block_addr.valid)).orR && !selected_req_valid)`.

### 5.8. `cache/dcache/DCacheWrapper.scala`

1. `HasDCacheParameters`: два `def` из 5.0 (`coreResetEnabled`, `coreResetKeepL1`).
2. `DCacheIO` (после `wfi`, стр. 854):
   ```scala
   val quiesce   = Option.when(coreResetEnabled)(Flipped(new L1QuiesceIO))
   val keepReset = Option.when(coreResetKeepL1)(Input(AsyncReset()))
   ```
3. `DCacheImp` (после `wb`, стр. 1049):
   ```scala
   val quiesceUnit  = Option.when(coreResetEnabled)(Module(new DCacheQuiesceUnit))
   val quiesceBlock = quiesceUnit.map(_.io.block)
   quiesceUnit.foreach { u =>
     u.io.quiesce <> io.quiesce.get
     u.io.mq_empty  := missQueue.io.empty.get
     u.io.wbq_empty := wb.io.empty.get
     u.io.mp_empty  := !mainPipe.io.busy.get
     u.io.pq_empty  := probeQueue.io.empty.get
   }
   ```
4. WFI (стр. 1063, строка `io.wfi <> missQueue.io.wfi` остаётся), после неё:
   `quiesceBlock.foreach { b => when (b) { missQueue.io.wfi.wfiReq := false.B } }` — запрос WFI держит
   неотправленные Acquire в MissQueue (`MissQueue.scala:352`, `:831`, `:1248`), опустошение иначе не кончится.
5. Блокировки — каждая сразу после исходного соединения, в виде `quiesceBlock.foreach { b => when (b) { ... } }`:
   - после стр. 1534 (`missQueue.io.req`, `queryMQ`, `cmo_req`):
     `missQueue.io.req.valid := false.B; missReqArb.io.out.ready := false.B;`
     `missReadyGen.io.queryMQ.foreach(_.ready := false.B); missQueue.io.cmo_req.valid := false.B; io.cmoOpReq.ready := false.B`;
   - после стр. 1586: `mainPipe.io.store_req.valid := false.B; io.lsu.store.req.ready := false.B`;
   - после стр. 1592: `mainPipe.io.atomic_req.valid := false.B; io.lsu.atomics.req.ready := false.B`.
   Load-ы по попаданию не блокируются; Probe обслуживаются.
6. KEEP: блок `io.keepReset.foreach { ... }` раздела 4.3 — после стр. 1340 (после цикла 1332–1340, то есть
   после всех соединений массивов).
7. Assert-ы раздела 4.3: первый — внутри `io.keepReset.foreach`, второй — внутри `io.quiesce.foreach`
   (после `wb.io.req <> mainPipe.io.wb`, стр. 1612).

### 5.9. `cache/dcache/FakeDCache.scala`

После `io := DontCare`:

```scala
  io.quiesce.foreach { q =>          // no cache, nothing to drain
    q.done := q.req
    q.idle := true.B
    val alive = RegInit(false.B); alive := true.B
    q.alive := alive
  }
```

### 5.10. `mem/MemBlock.scala`

`MemBlockInlinedImp.io` (после `wfi`, стр. 371):

```scala
    val l1_quiesce    = Option.when(p(SoCParamsKey).EnableCoreReset)(Flipped(new L1QuiesceIO))
    val l1_keep_reset = Option.when(p(SoCParamsKey).EnableCoreReset && p(SoCParamsKey).CoreResetKeepL1)(Input(AsyncReset()))
```

После стр. 635: `dcache.io.quiesce.foreach(_ <> io.l1_quiesce.get)`,
`dcache.io.keepReset.foreach(_ := io.l1_keep_reset.get)`. `MemBlockImp.io` — `cloneType` внутреннего, сам
подхватит. Дерево сброса (стр. 2100–2127) не меняется: `dcache` остаётся в `rightResetTree`, а три массива
(meta, error, tag) получают `keepReset` уже внутри `DCacheImp`.

### 5.11. `xiangshan/XSCore.scala`

`import xiangshan.cache.L1QuiesceIO`. В `XSCoreImp.io` (после `dft_reset`, стр. 119) — те же два `Option`-порта
`l1_quiesce`, `l1_keep_reset`; после стр. 210: `memBlock.io.l1_quiesce.foreach(_ <> io.l1_quiesce.get)`,
`memBlock.io.l1_keep_reset.foreach(_ := io.l1_keep_reset.get)`.

### 5.12. `xiangshan/CoreReset.scala` (новый)

Заголовок Mulan PSL v2. Содержимое: `QuiesceGateIO`, `TLQuiesceGate` / `Imp`, `TLResetIsolation` / `Imp` — из v5 с
правками раздела 3; `CoreResetCtrlIO` (поля v5: `req, busy, inReset, hartInReset, l1, coreInReset, earlyBlock,
gateBlock, holdProbe, ackProbe, isolate, earlyQuiet, gatesQuiet, coreReset`) и `CoreResetCtrl` — код разделов
2.1, 2.2, 2.5. Заголовочный комментарий переписать: два режима (FULL по умолчанию), шесть состояний,
опережение изоляции, правила RDC (раздел 6.3).

### 5.13. `xiangshan/XSTile.scala`

Основа — v5 (`git show core-reset-v5:src/main/scala/xiangshan/XSTile.scala`); ниже — полный перечень с
отличиями v6 (помечены **v6**).

Diplomacy (`XSTile`). `TLTempNode()` из v5 не используется: каждое соединение — `if / else`, ветвь `else` —
строка upstream без изменений.

```scala
val coreGates = scala.collection.mutable.ListBuffer[TLQuiesceGate]()
private def coreGate(name: String, early: Boolean) = {      // called only with EnableCoreReset
  val g = LazyModule(new TLQuiesceGate(name, early)); coreGates += g; g.node
}
val coreIsolations = scala.collection.mutable.ListBuffer[TLResetIsolation]()
private def coreIsolation() = { val i = LazyModule(new TLResetIsolation); coreIsolations += i; i.node }

coreParams.dcacheParametersOpt.map { _ =>
  if (EnableCoreReset) {
    l2top.inner.misc_l2_pmu := l2top.inner.l1d_logger := coreGate("l1d", early = false) := memBlock.dcache_port :=
      memBlock.l1d_to_l2_buffer.node := memBlock.dcache.clientNode
  } else {
    l2top.inner.misc_l2_pmu := l2top.inner.l1d_logger := memBlock.dcache_port :=
      memBlock.l1d_to_l2_buffer.node := memBlock.dcache.clientNode
  }
}
```

- Так же, по одному `if / else`: `l1i` (`early = true`, стр. 70 — гейт между `l1i_logger` и `icache_node`); `ptw`
  (`early = true`, стр. 72 — между `l2top.inner.ptw_to_l2_buffer.node` и `memBlock.ptw_to_l2_buffer.node`);
  `i_mmio` (`early = true`, стр. 95 — между `i_mmio_buffer.node` и `instr_uncache_node`); `d_mmio`
  (`early = true`, стр. 99); `coreIsolation()` на `icachectrl` (стр. 97, внутри `if (soc.EnableICacheCtrl)`).
- Мосты предвыборки L1 → L2 и L1 → L3: при `EnableCoreReset` разрезаны на `BundleBridgeSink` +
  `BundleBridgeSource` (`l2_pf_iso`, `l3_pf_iso`), как в v5; без него — исходные строки (стр. 47, 76–83).

`XSTileImp.io` — новые порты (`Option.when(EnableCoreReset)`):

| Порт | Напр. | Смысл |
|---|---|---|
| `debug_reset` | in | уровень, асинхронный, с выхода триггера: `ndmreset` Debug Module |
| `hart_reset` | in | **v6**: уровень, асинхронный: `hartreset` этого харта (в v5 складывался с `debug_reset` до синхронизатора) |
| `core_reset_req` | in | уровень, асинхронный: контроллер сброса кластера |
| `core_reset_busy` | out | домен такта тайла: последовательность идёт (регистр `busy`) |
| `core_in_reset` | out | **v6**: домен такта тайла: сброс XSCore **установлен** (регистр `coreReset`, только sReset); не «ядро в сбросе» — см. 2.4 |

Контроллер (`XSTileImp`):

```scala
val coreResetCtrl = Option.when(EnableCoreReset)(Module(new CoreResetCtrl(CoreResetKeepL1)))
coreResetCtrl.foreach { ctl =>
  // every asynchronous source has its own synchroniser; they are combined after it  (v6, finding (c))
  val reqs = Seq(io.debug_reset.get, io.hart_reset.get, io.core_reset_req.get)
    .map(AsyncResetSynchronizerShiftReg(_, 3, 0))
  ctl.io.req := reqs.reduce(_ || _)
  io.core_reset_busy.get := ctl.io.busy
  io.core_in_reset.get := ctl.io.inReset
  core.module.io.l1_quiesce.get <> ctl.io.l1
  coreGates.foreach { g =>
    g.module.io.block   := (if (g.early) ctl.io.earlyBlock else ctl.io.gateBlock)
    g.module.io.holdB   := ctl.io.holdProbe
    g.module.io.ackB    := ctl.io.ackProbe
    g.module.io.isolate := ctl.io.isolate
  }
  coreIsolations.foreach(_.module.io.isolate := ctl.io.isolate)
  ctl.io.earlyQuiet := coreGates.filter(_.early).map(_.module.io.quiet).foldLeft(true.B)(_ && _)
  ctl.io.gatesQuiet := (coreGates.map(_.module.io.quiet) ++ coreIsolations.map(_.module.io.quiet)).foldLeft(true.B)(_ && _)
  ctl.io.coreInReset := core.module.io.resetInFrontend
}
```

Без `EnableCoreReset` портов `l1_quiesce` нет — ветка `case None` из v5 с константами не нужна (**v6**).

Сброс ядра (вместо стр. 231–233):

```scala
coreResetCtrl match {
  case Some(ctl) =>
    val coreBaseReset = if (debugOpts.ResetGen && enableL2) l2top.module.reset_core.asBool else reset.asBool
    core.module.reset := withClockAndReset(clock, (coreBaseReset || ctl.io.coreReset).asAsyncReset) { ResetGen(io.dft_reset) }
    core.module.io.l1_keep_reset.foreach { _ :=
      withClockAndReset(clock, coreBaseReset.asAsyncReset) { ResetGen(io.dft_reset) }.asAsyncReset }
  case None =>
    if (debugOpts.ResetGen && enableL2) { core.module.reset := l2top.module.reset_core }   // upstream, unchanged
}
```

Изоляция боковых сигналов: `iso`, `isoReset(x, r)`, `isoHold(x)` — как в v5; полная таблица — раздел 6.2.
Отличия **v6** от v5:

- `addr_valid` обоих мостов предвыборки: `isoReset(addr_valid, false.B) && !ctl.io.busy` — маска с первого
  такта последовательности (находка (a)); `l2_pf_en` — `isoHold`.
- `pfCtrlFromCore`: `isoHold(core.module.io.l2PfCtrl)`, затем
  `when (ctl.io.busy) { l2top.module.io.pfCtrlFromCore.l2_pf_master_en := false.B }` — предвыборки L2 на время
  последовательности выключены в обоих режимах (находка (a); решение 16.11.2026).
- `l2_pmp_resp`: при `iso` — «запрет» (все поля `PMPRespBundle` в 1). CoupledL2 читает `pmp_resp` на такт
  позже `resp.valid` (`BestOffsetPrefetch.scala:515–530`): ответ, прошедший в последнем такте sDrain, в такте
  sIso отбрасывается как исключение, а не принимается с нулевым PMP (находка (f)).
- трасса: дополнительно `groups(i).bits.iretire` и `groups(i).bits.itype` → 0 при `iso` (в `L2Top.scala:297–298`
  они захватываются `RegNext` без `valid`; находка (f)).
- `io.hartIsInReset := l2top.module.io.hartIsInReset.toTile || ctl.io.hartInReset` — как в v5, но
  `hartInReset` теперь `busy`.

### 5.14. `xiangshan/XSTileWrap.scala`

- Порты `XSTileWrapImp.io` (`Option.when(EnableCoreReset)`): `debug_reset`, `core_reset_req` (in),
  `core_reset_busy`, `core_in_reset` (out). `hartResetReq` остаётся (upstream).
- Стр. 109:
  ```scala
  val reset_sync = if (EnableCoreReset) withClockAndReset(clock, reset)(ResetGen(io.dft_reset))
                   else withClockAndReset(clock, (reset.asBool || io.hartResetReq).asAsyncReset)(ResetGen(io.dft_reset))
  ```
  С `EnableCoreReset` `hartResetReq` сбрасывает только XSCore.
- Соединения: `tile.module.io.debug_reset.foreach(_ := io.debug_reset.get)`,
  `tile.module.io.hart_reset.foreach(_ := io.hartResetReq)` (**v6**: без ИЛИ до синхронизатора),
  `tile.module.io.core_reset_req.foreach(_ := io.core_reset_req.get)`, выходы — наружу.

### 5.15. `top/XSNoCTop.scala`

- `tileio` (после `nodeID`, стр. 248): `debug_reset`, `core_reset_req` (in), `core_reset_busy`, `core_in_reset`
  (out) — `Option.when(socParams.EnableCoreReset)`; соединения с `core_with_l2.module.io` после стр. 262.
- `buildLowPower`, ветка `if (socParams.WFIClockGate)` (стр. 167). Синхронизаторы строятся только при
  `EnableCoreReset` (**v6**: в v5 синхронизатор константы строился всегда):
  ```scala
  val coreResetWake = Option.when(socParams.EnableCoreReset) {
    withClockAndReset(clock, cpuReset_sync) {
      Seq(tileio.debug_reset.get, tileio.hartResetReq, tileio.core_reset_req.get, core.io.core_reset_busy.get)
        .map(AsyncResetSynchronizerShiftReg(_, 3, 0)).reduce(_ || _)       // one synchroniser per source
    }
  }
  wfiState := withClockAndReset(clock, cpuReset_sync) {
    coreResetWake.map(w => WfiStateNext(wfiState, isWFI && !w, isNormal, flitpend || w, false.B))
      .getOrElse(WfiStateNext(wfiState, isWFI, isNormal, flitpend, false.B))
  }
  ```
  Запрос будит остановленный такт Core+L2 как flit и не даёт остановить его до конца последовательности
  (в FULL гейт отвечает на Probe во время сброса — такт нужен).

### 5.16. `top/Top.scala`

XSTop создаёт `XSTile` напрямую (`Top.scala:105`), без XSTileWrap. После стр. 494 (`reset_mtvec`) три входа
привязать к нулю: `core.module.io.debug_reset.foreach(_ := false.B)`,
`core.module.io.hart_reset.foreach(_ := false.B)`, `core.module.io.core_reset_req.foreach(_ := false.B)`; выходы
`core_reset_busy`, `core_in_reset` не подключать. `hartreset` Debug Module в XSTop по-прежнему сбрасывает весь
тайл (`Top.scala:617–621`, upstream): сброс только ядра в XSTop не выведен, целевой верх — XSNoCTop / XSTileWrap.

---

## 6. Изоляция домена сброса ядра

### 6.1. TileLink

| Ребро | Роль ядра | Адаптер | Что зажато при `isolate` |
|---|---|---|---|
| l1d (TL-C) | клиент | `TLQuiesceGate("l1d", early = false)` | к L2: `a.valid`, `c.valid`, `e.valid` = 0 (C — кроме ProbeAck самого гейта), `d.ready` = 0, `b.ready` = 0 / `takeB`; к ядру: `b.valid`, `d.valid` = 0, `a.ready`, `c.ready`, `e.ready` = 0 |
| l1i, ptw, i_mmio, d_mmio (TL-UL) | клиент | `TLQuiesceGate(_, early = true)` | `a.valid` = 0, `d.ready` = 0; к ядру `d.valid` = 0, `a.ready` = 0 |
| icachectrl (TL-UL) | менеджер | `TLResetIsolation` | к ядру `a.valid` = 0, `d.ready` = 0; к тайлу `a.ready` = 0, `d.valid` = 0 |

Поля `bits` квалифицированы своим `valid` и отдельно не зажимаются. Регистры управления DCache
(`EnableDCacheCtrl`) подключены к `uncache_xbar` внутри MemBlock (`MemBlock.scala:286–290`) и границу не
пересекают.

### 6.2. Боковые сигналы (выходы `XSCoreImp.io` и мосты)

Все зажимы — в `XSTileImp`, все — от регистра `isolate`, то есть с первого такта sIso (за `isoCycles` тактов
до сброса) и до первого такта после sRelease. `isoReset(x, r) = Mux(iso, r, x)`,
`isoHold(x) = Mux(iso, RegEnable(x, !iso), x)`.

| Сигнал ядра | Потребитель в домене тайла | Зажим |
|---|---|---|
| `cpu_halt` | L2Top `RegNext` → порт; `l2.io_cpu_halt` (`L2Top.scala:276`, `:372`); XSNoCTop `isWFI` | `isoReset(_, false.B)` |
| `cpu_critical_error` | L2Top `RegNext` → порт | `isoReset(_, false.B)` |
| `msiAck`, `teemsiAck` | IMSIC, четырёхфазное рукопожатие (`ChiselAIA/…/IMSIC.scala:184–192, 771–797`) | `isoReset(_, false.B)`; hold дал бы зависание моста |
| `resetInFrontend` | L2Top `hartIsInReset` (`:314–316`); `CoreResetCtrl.coreInReset` | в L2Top — `isoReset(_, true.B)`; в контроллере — квалификатор `releasing` |
| `traceCoreInterface.toEncoder.groups(i).valid` | L2Top `RegNext`, `RegEnable` (`:286–306`) | `isoReset(_, false.B)` |
| `...groups(i).bits.iretire`, `.itype` | L2Top `RegNext` без valid | `isoReset(_, 0.U)` (**v6**) |
| `...groups(i).bits.iaddr`, `.ilastsize`, `priv`, `trap` | L2Top `RegEnable` по `valid` | не нужен (enable зажат) |
| `...toEncoder.mstatus` | L2Top `RegNext` | `isoHold` |
| `beu_errors.{icache,dcache,uncache}.ecc_error.valid` | BusErrorUnit | `isoReset(_, false.B)`; `bits` — по valid |
| `l2_flush_en` | L2 (`l2.io.l2Flush`), порт тайла | `isoReset(_, false.B)` |
| `power_down_en` | в XSTile не подключён (`XSCore.scala:97`, `dontTouch`) | — |
| `l2PfCtrl` | префетчер L2 | `isoHold`; `l2_pf_master_en` = 0 при `busy` (**v6**) |
| мост L1 → L2 `PrefetchRecv.addr_valid` | префетчер L2 (`CoupledL2.scala:385`) | `isoReset(_, false.B) && !busy` (**v6**) |
| мост `PrefetchRecv.l2_pf_en` | в CoupledL2 55d8e69 не используется (`CoupledL2.scala:383–388`) | `isoHold` (**v6**) |
| мост `PrefetchRecv.addr`, `pf_source` | по `addr_valid` | — |
| мост L1 → L3 `huancun.PrefetchRecv` (если есть L3) | L3 | как L1 → L2 |
| `l2_tlb_req.req.ready`, `.resp.valid` | префетчер L2 (ядро — ответчик) | `isoReset(_, false.B)`; `resp.bits` — по valid |
| `l2_pmp_resp` | префетчер L2, на такт позже `resp.valid` | `isoReset(_, все поля 1)` (**v6**) |
| `debugTopDown.robHeadPaddr.valid` | L2 TopDown, порт тайла | `isoReset(_, false.B)`; `bits` — по valid |
| `debugTopDown.robTrueCommit` | L2 TopDown | `isoHold` |
| `l1_quiesce.done`, `.idle` | `CoreResetCtrl` | `&& !isolate` в контроллере |
| `l1_quiesce.alive` | `CoreResetCtrl` | `&& releasing` |

Функциональная маска, не изоляция: `core.module.io.l2_tlb_req.req.valid := false.B` при `busy` (вход ядра;
запросов трансляции от L2 во время последовательности нет).

Входы ядра (прерывания через `IntBuffer` тайла, `msiInfo`, `clintTime`, `reset_vector`, `l2_hint`,
`perfEvents`, `l2_flush_done`, DFT) изоляции не требуют. `XSCoreBase.csrOut` (`XSCore.scala:64`) никуда не
подключён. Пересечения через `BoringUtils` / ChiselDB / DiffTest / `XSPerf` — только симуляция, не
изолируются.

### 6.3. Правила RDC (для инструмента)

- **Домены.** `rst_core` — выход `ResetGen` в XSTile и вся цепочка ResetGen под ним; источник —
  `coreBaseReset || coreReset`, оба слагаемых — выходы триггеров такта тайла. Установка асинхронная, снятие
  синхронное. `rst_tile` — сброс тайла (`reset_sync` в XSTileWrap, цепочка L2Top). Такт один.
- **R1.** Любой путь из триггера `rst_core` в триггер или память `rst_tile` (или без сброса, но в логике
  тайла) проходит через вентиль с квалификатором `isolate` (в KEEP для массивов — `freeze`, тот же регистр).
- **R2.** Квалификаторы — регистры `rst_tile`: `isolate`, `releasing`. Декод `state` квалификатором не служит.
- **R3. Опережение.** `isolate` = 1 не меньше `isoCycles` ≥ 1 полных тактов до фронта `coreReset` (assert
  раздела 2.5, формальное свойство).
- **R4. Снятие.** `isolate` падает не раньше чем через полный такт после того, как `alive` = 1 и
  `resetInFrontend` = 0; оба меняются синхронно (снятие сброса синхронизовано ResetGen).
- **R5. KEEP, память.** Модули meta / error / tag — на `rst_tile`; `bankedDataArray` — на `rst_core`. Все входы
  разрешения зажаты `freeze` на границе модулей: запись — всех четырёх массивов, чтение — SRAM тегов и
  данных, `read.valid` — meta и error. Адрес и данные квалифицированы разрешением (CE = 0 ⇒ SRAM не
  обращается; при `EnableClockGate` её такт загейчен).
- **R6. Оставшиеся пересечения (исключения, перечень полный).**
  - (а) **WE SRAM данных**: `wen_reg` (`BankedDataArray.scala:940–945`; `SramedDataArray` — `:602–608`) — функция
    триггеров домена ядра (`RegNext(io.write.valid, false.B)` на `rst_core`, `write_valid_dup_reg`,
    `write_bank_mask_reg`, `write_div_addr_dup_reg` без сброса). Квалификатор стоит до триггера, а не после.
    Обоснование: D-входы зажаты `freeze` с sIso, значение 0 с такта решения, асинхронный сброс значение не
    меняет — сигнал статичен. Подтверждается assert-ом «нет записи при freeze» и формальным свойством.
  - (б) **Адрес и данные SRAM** тегов и данных — комбинационно от триггеров ядра; квалифицированы CE / WE = 0.
  - (в) **Выходы массивов** (ответы чтения meta / error / tag / data) идут в логику `rst_core`, которая в это
    время в сбросе; в домен тайла не возвращаются.
  - (г) **Регистры MBIST-цепочки массива тегов** (`MbistPipeline` в `DuplicatedTagArray`, `TagArray.scala:128`) —
    на `rst_tile` (как в v5); их входы — DFT-сигналы тайла, не логика ядра. Режим MBIST — только при общем
    сбросе.
  - (д) В FULL массивы остаются на `rst_core`, R5 не применяется.
  - (е) OR на пути сброса `coreBaseReset || coreReset`: в работе `coreReset` меняется, только когда
    `coreBaseReset` = 0; при установке сброса тайла оба меняются асинхронно, иголка на OR безвредна — `ResetGen`
    снимает сброс только после трёх фронтов.
- **Вход в ядро.** Сигналы тайл → ядро не изолируются: приёмник в сбросе, а при снятии сброса они синхронны.

---

## 7. Обоснование по TileLink 1.9.3

### 7.1. На что опирается каждый механизм

| Механизм | Правило | Пункт 1.9.3 |
|---|---|---|
| Сброс одной стороны связи через адаптер (гейт), без запросов без ответа в момент сброса | «a TileLink-to-TileLink adapter is needed … ensure that there are no unanswered TileLink requests when one half of the crossing is reset» | [@3.2.3] |
| Сброс ≥ 100 тактов, valid = 0; valid можно поднять после первого фронта без сброса | `rstCycles` ≥ 100; гейт держит `b.valid`, `d.valid` к ядру в 0 от sIso до конца sRelease | [@3.2.2] |
| Сброс устанавливается асинхронно, снимается синхронно | `ResetGen` | [@3.2, таблица сигналов] |
| Закрытие A только на границе сообщения | beat-ы разных сообщений не перемежаются; начатый burst доводится | [@4], [@4.1], правило 2 [@5] |
| Снятие `b.valid` к ядру и `b.ready` к L2 в первом такте sDrain | отправитель вправе снять valid непринятого beat-а на следующем такте; ready = 0 — beat не принят | [@4.1], «retract a beat» [@5.1] |
| Probe, принятый в последнем такте sQuiesce, обязан получить ProbeAck до сброса | агент отвечает на принятый запрос; менеджер ждёт ProbeAck на каждый Probe | правило 3.ii [@5], [@9.2] |
| Grant → GrantAck до сброса (счётчик `grants`) | Grant — и ответ, и запрос | [@9.3.9], [@5] |
| Release → ReleaseAck до сброса (счётчик `releases`) | идентификатор занят до ответа | [@6.4] |
| A закрыт, C / D / E идут | приоритет каналов A < B < C < D < E | [@2.2] |
| Удержание Probe (KEEP; sDrain / sIso в FULL) | предложенный beat должен быть принят «eventually» — длительность не ограничена, но конечна | правило 3.i [@5] |
| `ProbeAck NtoN` от гейта (FULL) | ProbeAck несёт Shrink или Report; NtoN — Report; поля `source`, `address`, `size` — из Probe, `corrupt` = 0 | [@9.3.5], табл. 36, [@9.1.4], табл. 31 |
| Probe к клиенту без прав законен и прав не меняет | «Probing Master Agents to cap their permissions at a more permissive level than they currently have is allowed» | [@9.3.3] |
| Нет ProbeAckData с NtoN | гейт данных не шлёт | [@9.3.6] |

### 7.2. Известные нарушения режима FULL

Пользователь о них знает и выбрал FULL по умолчанию; в документации пакета они обязательны.

1. **Потеря грязных данных.** L1D с правом T теряет копию без Release / ProbeAckData. Спецификация уменьшает
   права клиента только сообщениями ([@9.1.1], [@9.3.5], [@9.3.10]) и требует вернуть грязные данные
   ([@9.3.6]; «master agents that cache blocks of data must always restore permissions to their slave upon
   request» [@4.4]). Отчёт NtoN по строке, которую клиент держал Dirty, формально ложен: строка возвращается
   к значению в L2 / памяти.
2. **Устаревшая директория L2.** L2 числит за L1D строки, которых там нет. На проводе всё законно (NtoN на
   Probe, Acquire NtoB / NtoT при промахе), а корректность — свойство менеджера. Для CoupledL2 55d8e69: по
   NtoN MSHR снимает бит клиента и переводит TRUNK → TIP (`tl2chi/MSHR.scala:1098–1112`) и продолжает со
   своей копией из DataStorage / releaseBuf; повторный Acquire сброшенной L1D обслуживается как попадание
   (анализ старого патча, §1.3.2–1.3.3, та же ревизия CoupledL2).
3. **AcquirePerm (NtoT и BtoT).** DCache на промах store, перезаписывающего всю строку, шлёт `AcquirePerm`
   вместо `AcquireBlock` (`MainPipe.scala:850` — `full_overwrite`; `MissQueue.scala:845`, `:265`). CoupledL2 в
   обоих случаях посылает `MakeUnique` (`tl2chi/MSHR.scala:380–381`, `:390`) — владение без данных. По `Comp`
   `gotDirty := false` (`:1206–1214`), строка записывается в директорию как TRUNK, клиент = 1, `dirty` = 0
   (`:776–777`). Спецификация требует от менеджера помнить «data not valid» до ReleaseData / ProbeAckData
   [@9.3.2]; CoupledL2 помнит это неявно — «строка в TRUNK у клиента». Сброс L1D и `ProbeAck NtoN` ломают это
   допущение: строка становится TIP clean без клиента (`:1098–1112`). Два случая:
   - **NtoT, промах в L2 — чужие данные.** DataStorage при `MakeUnique` не пишется (`:492` —
     `mp_release.dsWen := !req_acquirePerm`; `:804` — `mp_grant.dsWen` только при `gotGrantData`): в выбранном
     пути остаются данные вытесненной строки. После NtoN L2 выдаёт их как действительные: в ответ на SnpOnce,
     через DCT (Snp\*Fwd, данные из releaseBuf), при повторном Acquire, на Get от ICache / PTW. Это не
     «старое значение», а содержимое **другой** строки (и канал утечки между адресами).
   - **BtoT, попадание в BRANCH — потеря записи другого харта.** При попадании в BRANCH с `needT` CoupledL2
     идёт в HN (`tl2chi/MainPipe.scala:236` — `acquire_on_hit_s3`) тем же `MakeUnique`. Сценарий: харт X
     записал строку A (у X — UD, в памяти v0); наше ядро её прочитало (X → SD, у нас SC со значением v1);
     store на всю строку → `AcquirePerm BtoT` → `MakeUnique`; HN аннулирует копию X без записи в память
     (по CHI — SnpMakeInvalid; поведение HN кластера требует проверки). L1D пишет v2. Сброс ядра, NtoN: L2
     держит v1 как TIP **clean**; вытеснение чистой строки идёт без WriteBack (`tl2chi/MSHR.scala:357` —
     `isWriteBackFull` требует `meta.dirty`). Пока строка в L2, читатели видят v1; после вытеснения — v0 из
     памяти. Пропадает не только наша запись v2, но и **закоммиченная запись другого харта** v1, причём
     немонотонно (v1 → v0).

   Окно в обоих случаях: от Grant на AcquirePerm до первого ReleaseData / ProbeAckData этой строки. Решение
   пользователя 16.11.2026: **не исправлять, описать** (здесь и в PDF). Вариант исправления — В1 (раздел 10).
4. **Probe в sDrain / sIso держится, а не отвечается.** Нарушением не является (правило 3.i), длительность —
   единицы тактов.

В KEEP нарушений протокола нет; цена — удержание Probe на всё время сброса (раздел 8.2).

---

## 8. Ограничения и требования к интеграции

### 8.1. Общие

- **Нет таймаута.** Если L2 не отвечает (нет Grant / ReleaseAck) или Probe не завершается, последовательность
  стоит в sQuiesce / sDrain, `busy` = 1, `core_in_reset` = 0. Сторожевой таймер — на кластере.
- **Протокол запроса.** Уровень; держать до `core_reset_busy` = 1 (если `busy` не используется — не меньше
  16 тактов тайла: синхронизатор 3 такта, с `WFIClockGate` ещё пробуждение такта). Запрос не отменяется.
  Сброс длится, пока запрос высокий, но не меньше `rstCycles`; ядро стартует после снятия запроса, когда
  `busy` упадёт.
- **Входы запроса — только с выходов триггеров** (находка 12 ревью). `debug_reset`, `hartResetReq`,
  `core_reset_req` асинхронны к такту тайла, но не должны иметь иголок: запрос не отменяется, и иголка,
  пойманная синхронизатором, запускает полный сброс ядра. Комбинационная логика перед входом запрещена.
- **`reset_vector`.** Менять, пока запрос высокий; значение должно быть стабильным **от снятия запроса до
  `busy` = 0**. `core_in_reset` означает только «сброс установлен» и падает в начале sRelease, а ядро
  выходит из сброса ещё ~20 тактов; к тому же вектор доходит до ядра через `DelayN(5)` (`L2Top.scala:255, 266`).
- **CDC запроса** (находка (c)): у каждого источника свой синхронизатор, ИЛИ — после. Синхронизаторы тайла
  стоят на (возможно остановленном) такте тайла; XSNoCTop будит такт своими синхронизаторами на свободном
  такте. Короткий запрос при остановленном такте теряется — отсюда требование «держать до `busy`». Интегратор,
  ставящий XSTile / XSTileWrap без XSNoCTop, обязан сам разбудить такт по запросу и держать его до конца
  последовательности (в FULL гейт отвечает на Probe в сбросе).
- **Питание.** Запрос во время последовательности выключения (`lpState` ≠ sIDLE, `XSNoCTop.scala:109–130`)
  не поддержан: `l2_flush_en` и `cpu_halt` при изоляции зажаты в 0, а у `lpStateNext` нет перехода назад в
  sIDLE (`utils/LowPowerState.scala:44–51`) — автомат питания остаётся в промежуточном состоянии,
  восстановление — только сбросом тайла. Кластер не должен запрашивать сброс ядра после `l2_flush_en`.
- **MMIO.** Запросы некогерентных агентов, не прошедшие гейт до начала последовательности, теряются со
  сбросом, включая закоммиченный MMIO store в ожидании гейта. Начатые — завершаются (`earlyQuiet`).
- **Зависшее устройство.** MMIO-запрос без ответа держит `earlyQuiet` = 0 — сброс не начнётся.
- **MSI.** Рукопожатие с IMSIC четырёхфазное; `msiAck` = 0 при изоляции безопасен. MSI, принятые ядром до
  сброса, теряются вместе с interrupt file ядра (он сбрасывается).
- **XSTop** (TileLink L3) — порты привязаны к нулю, сброс только ядра не выведен (5.16).
- **Новая логика в DCache.** Любая новая очередь или конвейер, способные держать транзакцию, требуют флага
  пустоты в `DCacheQuiesceUnit`.
- **Трассировка, BEU, TopDown** во время изоляции молчат; `mstatus`, `robTrueCommit`, `l2PfCtrl` — последние
  значения до сброса.

### 8.2. KEEP: удержанный Probe останавливает снупы (находка (a))

Probe к L1D, предложенный в sDrain … sRelease, ждёт в SourceB; его MSHR занята всё это время.

- Снуп HN к строке L1D (TRUNK, либо любой с клиентом для SnpUnique\* / SnpCleanInvalid / SnpMakeInvalid\*)
  занимает MSHR и ждёт до конца сброса. Каждый следующий такой снуп — ещё одна MSHR; когда свободных нет,
  RXSNP встаёт (вывод независимого ревью v5; условия Probe сверены по `tl2chi/MainPipe.scala`, исчерпание
  MSHR — нет).
- MSHR предвыборки L2 может выбрать жертвой строку L1D (директория не избегает путей с клиентом,
  `Directory.scala:272–287`) и послать rProbe; снуп HN к этой жертве встаёт в RXSNP по `replaceBlockSnp`
  (`tl2chi/RXSNP.scala:82–87`), а RXSNP — одна очередь: за ним встают **все** снупы к этому RN, в том числе
  к строкам, которых в L1D нет.
- В RTL-симуляции сработают assert-ы CoupledL2: `STALL_CNT_MAX` = 28000 тактов (`RXSNP.scala:124`) и
  `VALID_CNT_MAX` = 400000 тактов (`MSHR.scala:1460`).

Что сделано в базовом варианте (оба режима, RTL одинаков):

1. подсказки предвыборки L1 → L2 и L1 → L3 маскируются с первого такта последовательности (`busy`), а не с
   `isolate`;
2. `l2_pf_master_en` = 0 при `busy`: BOP, TP и приёмник подсказок L2 новых запросов не создают
   (`Prefetcher.scala:241–244`);
3. запросы трансляции L2 → TLB ядра маскируются при `busy` (v5).

Что остаётся: MSHR предвыборки, выделенная до начала последовательности, может дойти до rProbe уже во время
сброса (жертва выбирается при заполнении); очередь `pftQueue` допускает несколько запросов после маски.
Сигнала «L2 без предвыборок в полёте» у CoupledL2 нет; без её изменения окно не закрыть.

**Последовательности подряд** (находка 4 ревью; решение 16.11.2026 — только описать). Если запрос поднят
снова до конца sRelease, контроллер идёт sRelease → sQuiesce напрямую. B при этом открыт только на время
sQuiesce — 3–5 тактов, если DCache и некогерентные агенты пусты. Удержанные Probe успевают дойти до DCache
(и должны получить ответ до выхода из sDrain), но новые Probe и стоящий RXSNP переходят во второй сброс:
для L2 и HN два сброса подряд выглядят как одно удержание суммарной длины. Сторожевой таймер кластера должен
считать от первого запроса; между запросами полезна пауза, достаточная для разбора очереди снупов.

**Требование к кластеру для KEEP:** сторожевой таймер на длительность сброса (`core_reset_busy`,
`core_in_reset`); снятие запроса не должно зависеть от транзакции, которой нужен снуп к этому RN (запись
отладчика через SBA при удержанном `ndmreset` — взаимная блокировка); удержание заведомо короче 28000 тактов,
если симуляция идёт с assert-ами CoupledL2. Для отладки через SBA при удержанном сбросе — FULL. Таймаута и
удержания вне сброса (В4, В8) в базовом варианте нет (решение 16.11.2026).

### 8.3. FULL

Раздел 7.2. Дополнительно: всё, что ядро записало и не вытеснило из L1D, пропадает (и sbuffer — в обоих
режимах); после сброса L2 делает лишние Probe к строкам, которых в L1D уже нет (по одному на строку).

---

## 9. Следствия для проверки

- Конфигурации: `""` = FULL (по умолчанию) и `CFG_KEEP`; SWEEP удалить из моделей, стенда, скриптов, YAML
  elaboration (`xsnoctop_sweep.yml` → `xsnoctop_full.yml`).
- Модель L2 для FULL: директория устаревает; табло должно допускать NtoN по строке, которую L2 числит за
  L1D, и повторный Acquire такой строки. Потеря грязных данных — ожидаемое расхождение, эталон данных
  сравнивается с копией L2.
- Новые направленные проверки и мутанты:

  | Функция v6 | Свойство / сценарий | Мутант |
  |---|---|---|
  | опережение изоляции ≥ `isoCycles` | `coreReset` ↑ ⇒ `isolate` стоял `isoCycles` тактов; в sIso ни одно сообщение не пересекает гейт | `NO_ISO_LEAD` (isolate и coreReset на одном фронте) |
  | снятие изоляции после выхода ядра | `isolate` ↓ только при `alive && !feReset` тактом раньше | `ISO_EARLY_DROP` (v5) |
  | `l1.req` в sIso | store не входит в MainPipe в sIso | `NO_REQ_IN_ISO` |
  | FULL: ответ гейта только в sReset / sRelease | Probe в sDrain / sIso держится | `ACK_IN_ISO` |
  | KEEP: freeze с sIso | нет записи массивов, чтения SRAM и `read.valid` meta / error при `freeze` | `LATE_FREEZE`, `NO_READ_FREEZE` |
  | `hartInReset` с первого такта | P: `hartInReset === busy` | `LATE_HART_IN_RESET` |
  | `busy` без провала; KEEP: Probe между сбросами подряд | последовательности подряд (sRelease → sQuiesce) | — (cover) |
  | маска предвыборки с `busy` | `addr_valid` = 0, `l2_pf_master_en` = 0 при `busy` | `PF_MASK_LATE` |

  Мутанты v5 `NO_EARLY_BLOCK`, `NO_EARLY_QUIET`, `LATE_HOLDB`, `STALE_QUIET`, `NO_MP_WAIT`, `NO_WBQ_WAIT`,
  `NO_DRAIN`, `NO_FE_WAIT`, `RESET_EARLY` сохраняются; мутанты обхода — удалить.
- **Опустошение на RTL настоящей DCache** (находка 2 ревью; обязательное требование к архитектуре тестов).
  В v5 флаги пустоты и блокировки проверялись только на модели `cr_dcache`. В v6 — прогон RTL
  `DCacheWrapper` + `TLQuiesceGate` (l1d) + `CoreResetCtrl` с моделью L2, в обоих режимах, с направленными
  случаями: запрос приходит при **промахе AMO** (в том числе LR / SC и AMOCAS в MainPipe и MissQueue), при
  **CBO** в `cmo_unit`, при **запросе WFI** с неотправленным Acquire, при **Probe в последнем такте
  sQuiesce** и в первом такте sDrain. Проверяется: `done` и `idle` не поднимаются раньше конца транзакции,
  после `done` не стартует Release, в точке сброса нет открытых транзакций по счётчикам гейта.
- **Идентичность при `EnableCoreReset = false`** (находка 7 ревью). Обязательная проверка в `--full`: полный
  XSNoCTop с `EnableCoreReset = false` на v6 сравнивается с XSNoCTop на 7b16188 (те же YAML и аргументы).
  Эталон 7b16188 генерируется один раз; в ветке хранится его хеш (по файлам SystemVerilog, после удаления
  комментариев с путями и номерами строк), а не сам RTL. В `--quick` — то же сравнение на стенде модулей
  (`DCacheWrapper`, стенд гейтов): быстрый сигнал, идентичности XSTile / XSTileWrap / XSNoCTop он не доказывает.
- KEEP и SRAM: в модели SRAM DCache — проверка «нет обращения при `freeze`» и «содержимое до и после сброса
  совпадает»; прогон с `isoCycles` = 1 и 2.

---

## 10. Варианты (не входят в базовый дизайн; решения 16.11.2026 — не включать)

| № | Вариант | Что закрывает | Цена |
|---|---|---|---|
| В1 | FULL: не слать `AcquirePerm` вообще (NtoT и BtoT) — `Mux(full_overwrite && !noPerm, acquirePerm, acquireBlock)` в `MissQueue.scala:265` и `:845`, `noPerm = EnableCoreReset && !CoreResetKeepL1`. **Не включён** (решение 16.11.2026), остаётся вариантом | 7.2 п. 3, оба случая: CoupledL2 вместо MakeUnique шлёт ReadUnique (`tl2chi/MSHR.scala:377–391`) и получает данные с передачей грязной копии (обработка PassDirty по коду не сверялась); после NtoN в L2 действительное прежнее значение (v1), грязная строка вытесняется с WriteBack. Остаётся только потеря собственных записей ядра | ReadUnique с данными на каждый промах полной перезаписи (memset / memcpy); две строки в DCache, CoupledL2 не меняется |
| В2 | CoupledL2: бит «данные недействительны» в директории после MakeUnique; по NtoN такая строка → INVALID | 7.2 п. 3 без потери производительности | изменение CoupledL2 (чужой код) |
| В3 | Обход (sweep) v5 | 7.2 п. 1–3 | снят решением пользователя |
| В4 | KEEP + удержание вне сброса (sHold старого патча): ядро вне сброса, стоит, DCache отвечает на Probe; после снятия запроса — второй короткий сброс | 8.2: Probe ждёт не дольше `rstCycles` + выход | возврат импульсного механизма, убранного в v5 |
| В5 | CoupledL2: выход «нет MSHR предвыборки»; sDrain ждёт его | остаток 8.2 (rProbe предвыборки) | изменение CoupledL2 |
| В6 | «Липкий» захват запроса на свободном такте в XSNoCTop | короткий запрос при остановленном такте | логика вне тайла; интегратору без XSNoCTop не помогает |
| В7 | Отмена запроса до sIso (возврат в sIdle при `!req`) | (b), если нужна отмена | отладчик, снявший `ndmreset` рано, не получит сброса |
| В8 | Таймаут опустошения с выходом ошибки | 8.1, зависшая L2 / устройство | что делать по таймауту — решает кластер; сбрасывать ядро с открытыми транзакциями нельзя |
| В9 | `isoCycles`, `rstCycles` в `SoCParameters` / YAML | настройка без правки кода | два параметра; отклонён (в YAML не выносить) |

---

## 11. Решения по находкам ревью v5

| Находка | Решение v6 |
|---|---|
| (a) major, KEEP: удержанный Probe останавливает все снупы | маска подсказок и `l2_pf_master_en` с `busy`; остаток — ограничение и требование сторожевого таймера (8.2); В4, В5 — варианты |
| (b) запрос фиксируется; `hartInReset` поздно | фиксация оставлена как семантика запроса сброса; `hartInReset` = `busy` с первого такта (2.4) |
| (c) ИЛИ до синхронизатора; синхронизатор на остановленном такте | по синхронизатору на источник (XSTile, XSNoCTop), отдельный порт `hart_reset`; протокол «держать до `busy`» (8.1); В6 — вариант |
| (d) без `EnableCoreReset` RTL не идентичен upstream | `Option` / `if`, без `TLTempNode`: структурная идентичность (5.0); проверка — сравнение полного XSNoCTop с эталоном 7b16188 (9) |
| (e) `inReset` не подключён; провал `busy` | выход тайла `core_in_reset`; прямой переход sRelease → sQuiesce (2.4) |
| (f) `l2_pmp_resp`, `l2_pf_en`, `iretire` / `itype` не изолированы; нет лицензии | зажимы в таблице 6.2; заголовок Mulan PSL v2 в двух новых файлах |
| ревью v5: запись в массивы на фронте `coreReset` (нулевой запас) | запас `isoCycles` тактов (2.3) |
| ревью v5: теги на сбросе ядра в KEEP | `tagArray` на сбросе тайла, как в a43a292; в v6 добавлен зажим чтения SRAM тегов и данных и `read.valid` meta / error (4.3); `bankedDataArray` остаётся на сбросе ядра |

---

## 12. Решения 16.11.2026

Открытых вопросов нет. Ревью дизайна и решения пользователя — `core-reset/review/DESIGN_review_1.md`.

| Вопрос / находка ревью | Решение | Где в документе |
|---|---|---|
| Q1, находка 1: AcquirePerm в FULL | В1 не включать; описать оба случая — NtoT (чужие данные) и BtoT (потеря записи другого харта, v1 → v0) | 7.2 п. 3, 10 |
| Q2, находка 3: KEEP и массив данных | на сбросе тайла только meta / error / tag; freeze зажимает запись всех массивов, чтение SRAM тегов и данных и `read.valid` meta / error; `bankedDataArray` — на сбросе ядра | 4.3, 5.8, 6.3 (R5, R6) |
| Q3, находка 5: `isoCycles` | 1 по умолчанию; для KEEP `require(isoCycles ≤ 2)`; в YAML не выносить | 1.2, 2, 4.3 |
| Q4, находка 6: порты | набор принят; `core_in_reset` = «сброс установлен»; `reset_vector` стабилен от снятия запроса до `busy` = 0 | 2.4, 5.13, 8.1 |
| Q5, находка 9: `hartInReset = busy` | принято | 2.4 |
| Q6: переименования | приняты | 1.3 |
| Q7: `l2_pf_master_en` = 0 при `busy` | в обоих режимах | 5.13, 8.2 |
| Q8, находка 4: KEEP, удержание Probe | сторожевой таймер на кластере; окно Probe между сбросами подряд — только описать | 8.2 |
| Q9, находка 7: идентичность RTL | без `TLTempNode`; полный XSNoCTop против эталона 7b16188 (хеш) в `--full`, стенд модулей в `--quick` | 5.0, 5.13, 9 |
| Q10, находка 11: питание | ограничение; восстановление — только сбросом тайла | 8.1 |
| находка 2: опустошение настоящей DCache | RTL-тест `DCacheWrapper` + гейт (AMO-промах, CBO, WFI, Probe в последнем такте sQuiesce) | 9 |
| находка 8: MSI | оговорка снята: рукопожатие четырёхфазное, MSI до сброса теряются с interrupt file | 6.2, 8.1 |
| находка 10: место блока freeze | после стр. 1340 | 4.3, 5.8 |
| находка 12: иголка на запросе | входы запроса — только с выходов триггеров | 2.4, 8.1 |
