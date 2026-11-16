# План проверки сброса XSCore v6 (архитектура тестов)

Ветка `core-reset-v6`, база 7b16188. Вход — `core-reset/DESIGN.md` (редакция 2, 16.11.2026), решения пользователя
`core-reset/review/DESIGN_review_1.md`, среда проверки v5, перенесённая в эту ветку (`core-reset/verification/`),
описание v5 — `core-reset/HANDOFF_v5.md` §6, результаты v5 — ветка `core-reset-v5` (`results_*.txt`).
Документ — задание исполнителю (Sonnet medium): что строить, что проверять, в каком порядке, какие файлы и
форматы. Код проверки здесь не пишется, только его спецификация.

Обозначения: **FULL** — `CoreResetKeepL1 = false` (по умолчанию; в моделях — без define), **KEEP** —
`CoreResetKeepL1 = true` (define `CFG_KEEP`), **ISO2** — `isoCycles = 2` (define `ISO2`). Буквы конфигураций
формальной части: `f` (FULL), `k` (KEEP), `f2`, `k2` (то же с `ISO2`). Состояния контроллера и их коды во всех
моделях, мониторах и скриптах (числа, не enum — урок v5):

| код | 0 | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| состояние | sIdle | sQuiesce | sDrain | sIso | sReset | sRelease |

Фазы Probe в `cr_probe_sb` — те же коды (0 idle … 5 sRelease). Слова flush / sweep / SWEEP из среды проверки
убираются (кроме истории в комментариях «v5»); префикс мутантов DCache `FLUSH_MUTANT_*` → `QUIESCE_MUTANT_*`.

---

## 0. Что меняется относительно v5 (кратко)

1. Конфигурации: `""` = FULL, `CFG_KEEP` = KEEP; `CFG_SWEEP` удаляется отовсюду (модели, стенд, скрипты,
   `elab/xsnoctop_sweep.yml` → `elab/xsnoctop_full.yml`). Добавляется `ISO2`.
2. Контроллер: шесть состояний (новое sIso), регистры `isolate`, `releasing`, переход sRelease → sQuiesce,
   `hartInReset = busy`, `l1.req` в sIso, freeze с sIso.
3. DCache: только опустошение (`DCacheQuiesceUnit`, три состояния), обхода нет; в KEEP freeze зажимает и чтение
   SRAM тегов / данных и `read.valid` meta / error.
4. Модель L2 для FULL: устаревшая директория, ожидаемые расхождения данных (7.2 п. 1–3) — считаются, а не
   прощаются молча.
5. Новые виды проверки: `fv_adapters` (локальная изоляция адаптеров без допущений о декодах), RTL-тест
   настоящей `DCacheWrapper` + гейт + контроллер, тест изоляции тайла на RTL `XSTile` с заглушками `XSCore` /
   `L2Top`, идентичность RTL при `EnableCoreReset = false` с эталоном 7b16188.

---

## 1. Цели и трассировка

### 1.1. Таблица трассировки (функция → проверки → мутанты)

Колонки: **F** — формальные свойства (`fv_boundary` P*, `fv_adapters` L*), **S** — проверки моделирования
(раздел 4.2) и сценарии, **R** — RTL-тест DCache (раздел 5: проверки K*, случаи D*), **T** — тест тайла и
структурные проверки (раздел 6). Мутант без префикса — `CTRL_MUTANT_*`.

| # | Функция (DESIGN) | F | S | R / T | Мутанты |
|---|---|---|---|---|---|
| 1 | Сброс-уровень: ≥ `rstCycles`, до снятия запроса (1.1.5, 2.1) | P13, P14, P8B, C6 | S6, S7; SCEN 3, 7, 9 | — | `RESET_EARLY` |
| 2 | Запрос фиксируется, не отменяется; снятие / подъём в любом состоянии (2.4) | все P при свободном `req`; C12 | S12; SCEN 9 | D12 | `RESET_EARLY` |
| 3 | Раннее закрытие A некогерентных с первого такта (1.1.5) | P9 | S3; SCEN 5 | — | `NO_EARLY_BLOCK` |
| 4 | Выход из sQuiesce только при тишине некогерентных (2.2) | P10 | S4; SCEN 5 | — | `NO_EARLY_QUIET` |
| 5 | B закрыт с первого такта sDrain (1.1.5) | P18 | S5; SCEN 6 сл. 4 | D9 | `LATE_HOLDB`, `GATE_MUTANT_NO_HOLDB` (k) |
| 6 | Решение по `quiet` текущего такта (1.1.5) | P1, P19 | S1; SCEN 6 сл. 5 | D8, K1 | `STALE_QUIET` |
| 7 | Флаги пустоты DCache, опустошение без обхода (4.2) | P19 (через `l1.done/idle`) | S1, S19; SCEN 5 (C1–C14) | D1–D11, K1–K3 | `NO_DRAIN`, `NO_L1_IDLE`*, `QUIESCE_MUTANT_NO_MP_WAIT`, `_NO_WBQ_WAIT`, `_NO_MQ_WAIT`, `_NO_BLOCK` |
| 8 | Опережение изоляции ≥ `isoCycles`; в sIso ничего не пересекает гейт (1.1.4, 2.3, R3) | P21, P2, P1 | S9, S2 | K6; T5 | `NO_ISO_LEAD`, `ISO_LATE`, `ISO_SHORT` (f2, k2) |
| 9 | Снятие изоляции только после `alive && !feReset` тактом раньше (2.3, R4) | P22, P16, P20, P7 | S8, S10 | T5 | `ISO_EARLY_DROP`, `NO_FE_WAIT`, `NO_ALIVE`* |
| 10 | `l1.req` = 1 во всём sIso (2.2) | P23 | S18 | K4 | `NO_REQ_IN_ISO` |
| 11 | FULL: гейт отвечает NtoN только в sReset / sRelease, ровно один ProbeAck на Probe, по одному; Probe в sDrain / sIso держится (2.2, 3) | P8N, P12 (все), P3, P17; C5, C7, C11, C13 | S13, S21; SCEN 6 сл. 0, 1, 4, 6, 7; SCEN 7 | K7, D9, D10 | `ACK_IN_ISO`, `NOKEEP_HOLDB`, `NO_HOLD_IN_RELEASE`, `GATE_MUTANT_NO_ACKB`, `GATE_MUTANT_ACK_PARAM` |
| 12 | KEEP: Probe держится с sDrain до конца sRelease, потом доходит до L1D (2.2, 3) | P17, P8, P3, P7; C3, C5, C11 | S14; SCEN 6, 7, 8 | D9, D10 | `GATE_MUTANT_NO_HOLDB`, `NO_HOLD_IN_RELEASE` |
| 13 | KEEP: freeze с sIso — запись всех массивов, чтение SRAM тегов / данных, `read.valid` meta / error (4.3, R5) | P24 | S15; SCEN 5 C13 | K5, D13 | `LATE_FREEZE`, `FREEZE_MUTANT_NO_READ_MASK` (= NO_READ_FREEZE), `FREEZE_MUTANT_NO_SRAM_MASK` |
| 14 | KEEP: meta / error / tag переживают сброс (4.3) | — | S16, S20; SCEN 2, 6 сл. 2, 7 | K8; структурная проверка E2 | `META_MUTANT_CORE_RESET`, `TAG_MUTANT_CORE_RESET` |
| 15 | FULL: L1D пуста после сброса (1.1.2) | — | S17 | K8; E2 | `NOKEEP_MUTANT_META_KEPT` |
| 16 | FULL: известные нарушения 7.2 п. 1–3 (не ошибка, учёт) | — | S20, S21 (счётчики `full.*`) | K10 | — (ожидаемое расхождение) |
| 17 | `hartInReset` = `busy` с первого такта (2.4) | P11 | S11 | T5 | `LATE_HART_IN_RESET` |
| 18 | `busy` без провала: sRelease → sQuiesce при `req` (2.4) | P25; C10 | S12; SCEN 8 | D12 | `BUSY_GAP` |
| 19 | `core_in_reset` = «сброс установлен», только sReset (2.4) | P6 | S10 | T5 | `IN_RESET_WIDE` |
| 20 | Изоляция TileLink-рёбер (6.1) | P15, P17; L1–L3 | S2 | K6; T1 | `GATE_MUTANT_NO_ISO_A`/`_B`/`_C`/`_D`/`_E`, `ISO_MUTANT_NO_ISO` |
| 21 | `quiet` гейтов и `TLResetIsolation` честен (3) | P5; L4 | S1 | K1 | `GATE_MUTANT_ALWAYS_QUIET`, `ISO_MUTANT_ALWAYS_QUIET` |
| 22 | A закрывается только на границе сообщения (3) | P4; L5 | — (редкий) | — | `GATE_MUTANT_CUT_A` |
| 23 | Изоляция боковых сигналов (таблица 6.2) | — | — | T1, T2 | TM2 `NO_SIDEBAND_ISO` |
| 24 | Маски предвыборки и запросов TLB при `busy` (5.13, 8.2) | — | — | T3, T4 | TM1 `PF_MASK_LATE` |
| 25 | KEEP: `l1_keep_reset` только от сброса тайла (5.13) | — | — | T6; E2 | TM3 `KEEP_RESET_WITH_CORE` |
| 26 | Синхронизатор на каждый источник запроса (5.13) | — | — | T7 | — |
| 27 | `EnableCoreReset = false` — RTL совпадает с 7b16188 (5.0) | — | — | I1 (`--quick`), I2 (`--full`) | — (сравнение с эталоном) |
| 28 | Иголка на запросе / CDC (8.1) | — | — | — | только описание (ограничение интеграции) |

`*` — ожидаемо эквивалентные в моделировании (замороженный список, раздел 4.7); в формальной части оба ловятся.

### 1.2. Короткая версия для `CLAUDE.md` §5 (заменяет таблицу v5)

| Функция | Свойство / сценарий | Мутант |
|---|---|---|
| сброс-уровень, ≥ 100 тактов | P13, P14, SCEN 9 | `RESET_EARLY` |
| раннее закрытие A некогерентных | P9 | `NO_EARLY_BLOCK` |
| выход из sQuiesce при тишине некогерентных | P10 | `NO_EARLY_QUIET` |
| B закрыт с первого такта sDrain | P18, SCEN 6 сл. 4 | `LATE_HOLDB` |
| решение по `quiet` текущего такта | P1, P19, SCEN 6 сл. 5 | `STALE_QUIET` |
| флаги пустоты, опустошение | P19, SCEN 5, RTL D1–D11 | `NO_MP_WAIT`, `NO_WBQ_WAIT`, `NO_MQ_WAIT`, `NO_DRAIN` |
| опережение изоляции | P21, S9 | `NO_ISO_LEAD`, `ISO_SHORT` |
| снятие изоляции после выхода ядра | P22, P20 | `ISO_EARLY_DROP`, `NO_FE_WAIT` |
| `l1.req` в sIso | P23, S18, K4 | `NO_REQ_IN_ISO` |
| FULL: NtoN только в sReset / sRelease | P12, P8N, K7 | `ACK_IN_ISO`, `NO_ACKB`, `ACK_PARAM` |
| KEEP: freeze с sIso (запись и чтение) | P24, S15, K5 | `LATE_FREEZE`, `NO_READ_MASK` |
| `hartInReset` = `busy` | P11 | `LATE_HART_IN_RESET` |
| `busy` без провала | P25, SCEN 8 | `BUSY_GAP` |
| маски предвыборки, боковые сигналы | T1–T4 (RTL тайла) | `PF_MASK_LATE`, `NO_SIDEBAND_ISO` |
| идентичность при `EnableCoreReset = false` | I1, I2 | — |

### 1.3. Чего план не проверяет (ограничения, писать в PDF)

- Нарушения 7.2 п. 3 (AcquirePerm BtoT при попадании в BRANCH, потеря записи другого харта) — модели однохартовые,
  HN нет; только описание (решение пользователя 16.11.2026). NtoT-случай (чужие данные) виден в моделях как
  ожидаемое расхождение и считается (`full.foreign_lines`).
- Метастабильность и иголки асинхронных входов запроса (8.1) — синхронизаторы проверяются только структурно
  (T7); RDC как временной анализ — дело инструмента RDC по правилам 6.3 (в плане — только R3 / R4 как свойства
  P21 / P22 и функциональные следствия).
- Логика пробуждения такта в XSNoCTop (`coreResetWake`, 5.15) — только сборка и ревью Chisel, без моделирования.
- Ядро целиком (LSU, sbuffer, frontend) в RTL не моделируется: RTL-тест берёт только DCache, гейт и контроллер.
- `SramedDataArray` (WPU, `enWPU = false` по умолчанию) в RTL-тесте не собирается (раздел 5.8).

---

## 2. Формальная часть

### 2.1. Модели (`model/cr_ctl_models.sv`)

**`cr_ctrl #(KEEP = 0, RST_CYCLES = 100, ISO_CYCLES = 1)`** — один к одному с DESIGN 2.1–2.2 (заменяет v5,
`cr_ctl_models.sv:211–337`). Порты: v5 с переименованием `l1_flush_req` → `l1_req`, `l1_flush_done` → `l1_done`;
`st[2:0]` по кодам выше. Регистры `state, cnt, busy_r, iso_r, crst_r, rel_r`. Выходы:
`busy = hart_in_reset = early_block = busy_r`; `in_reset = core_reset = crst_r`; `isolate = iso_r`;
`l1_req = state ∈ {1,2,3}`; `gate_block = (state == 2) || iso_r`; FULL: `hold_probe = state ∈ {2,3}`,
`ack_probe = state ∈ {4,5}`; KEEP: `hold_probe = (state == 2) || iso_r`, `ack_probe = 0`;
`l1_freeze = KEEP && iso_r`. `l1_done_m = l1_done && !iso_r`, `l1_idle_m = l1_idle && !iso_r`,
`core_up = rel_r && l1_alive && !core_in_reset`. Самопроверки (`ifndef FORMAL`, `ifndef NO_CTRL_ASSERT`) — пять
assert-ов DESIGN 2.5 как `$error`.

Мутанты (`define`; один `define` = одна неверная деталь):

| Мутант | Что делает | Новый? |
|---|---|---|
| `NO_DRAIN` | sDrain → sIso без ожидания | v5 |
| `STALE_QUIET` | решение по `gates_quiet` прошлого такта | v5 |
| `NO_L1_IDLE` | `l1_idle_m = 1` | v5 |
| `NO_ALIVE` | `core_up` без `l1_alive` | v5 |
| `NO_FE_WAIT` | `core_up` без `!core_in_reset` | v5 |
| `NO_EARLY_QUIET` | выход из sQuiesce без `early_quiet` | v5 |
| `NO_EARLY_BLOCK` | `early_block = state==2 \|\| iso_r` | v5 |
| `LATE_HOLDB` | B закрыт со второго такта sDrain | v5 |
| `NO_HOLD_IN_RELEASE` | FULL: `ack_probe = state==4`; KEEP: `hold_probe = state ∈ {2,3,4}` | v5 (смысл тот же) |
| `RESET_EARLY` | выход из sReset без `!req` | v5 |
| `ISO_LATE` | `iso_r` поднимается тактом позже `crst_r` | v5 |
| `ISO_EARLY_DROP` | `iso_r := 0` на переходе sReset → sRelease | v5 |
| `NOKEEP_HOLDB` | FULL: держит Probe в sReset / sRelease вместо ответа | v5 |
| `NO_ISO_LEAD` | sDrain → sReset: `iso_r` и `crst_r` на одном фронте | **новый** |
| `ISO_SHORT` | sIso всегда 1 такт (игнорирует `ISO_CYCLES`); только f2 / k2 | **новый** |
| `NO_REQ_IN_ISO` | `l1_req = state ∈ {1,2}` | **новый** |
| `ACK_IN_ISO` | FULL: `hold_probe = state==2`, `ack_probe = iso_r` | **новый** |
| `LATE_FREEZE` | KEEP: `l1_freeze = crst_r \|\| rel_r` | **новый** |
| `LATE_HART_IN_RESET` | `hart_in_reset = state ∈ {4,5}` (как v5) | **новый** |
| `BUSY_GAP` | sRelease → всегда sIdle (как v5: провал `busy` на такт) | **новый** |
| `IN_RESET_WIDE` | `in_reset = state ∈ {4,5}` | **новый** |

**`cr_gate`** (`cr_ctl_models.sv:27–161`): добавить зажим B по `isolate` перед `hold_b` / `ack_b` (DESIGN 3 п. 1):
`ib_valid = ob_valid && !iso_b && !hb && !(ab || pend)`; `ob_ready = (ab || pend) ? take_b : (ib_ready && !hb && !iso_b)`
(при `iso_b` и без `ab/pend` — 0). Новый мутант `GATE_MUTANT_NO_ISO_B` (`iso_b = 0`). CBO (раздел 2.2, A9):
`has_data` A — только PutFull (как сейчас); `d_rack` — только ReleaseAck; новых правок счётчиков не нужно.
Убрать текст про sweep из комментариев.

**`cr_iso`** — без изменений.

**`cr_quiesce`** (новый, один к одному с DESIGN 4.2): входы `req, mq_empty, wbq_empty, mp_empty, pq_empty`, выходы
`block, done, idle, alive`; состояния 0 sIdle, 1 sDrain, 2 sDone; `alive` — регистр, 0 в сбросе, 1 со следующего
такта. Мутанты `QUIESCE_MUTANT_NO_MP_WAIT`, `_NO_WBQ_WAIT`, `_NO_MQ_WAIT` убирают слагаемое из `idle` (и выход
`idle`, и переход в sDone — как v5). Используется в `cr_dcache` (вместо flush unit) и в миттере `eq_quiesce`.

### 2.2. `formal/fv_boundary.sv` — изменения

Структура v5 сохраняется: гейты g0 (TL-C), g1 (UL), g2 + `cr_iso` (icachectrl), контроллер, синхронизатор
сброса ядра (2 триггера), frontend на 2 такта позже, независимые счётчики транзакций. Изменения:

- Параметры: `KEEP` из `CFG_KEEP` (по умолчанию 0), `RST` из `RST16`, `ISO` из `ISO2` (1 / 2).
- `st` — 6 кодов; `s_quiesce`, `s_iso` вместо `s_flush`.
- Вход `l1_req_q` (регистр) для допущения A10.
- Новые трекеры: `iso_run` (подряд идущие такты `isolate`, насыщение 8 бит), `isolate_q`, `alive_q`,
  `core_in_reset_q`, `busy_q`, `l1_req_q`, `st_q`.

#### Допущения среды (полный перечень; каждое — не сильнее гарантии дизайна)

| # | Допущение | Обоснование |
|---|---|---|
| A1 | Опкоды: L2 на D — Grant, GrantData, ReleaseAck, CBOAck (кодируется 2); UL D — AccessAck(Data); ядро (вне окна свободы) — A: AcquireBlock / AcquirePerm / CBO (кодируется 5); C: ProbeAck(Data), Release(Data); UL A: PutFull / Get | TileLink 1.9.3 табл. опкодов; DCache шлёт CBO (`MissQueue.scala` CMOUnit, `Edges.scala:377`, опкоды 12–14, ответ CBOAck 8) — в v5 не было, **новое** |
| A2 | Beat-ы одного сообщения сохраняют опкод | TileLink [@4.1] |
| A3 | Ответ только на открытый запрос (Grant ↔ Acquire, ReleaseAck ↔ Release, CBOAck ↔ CBO, AccessAck ↔ Get/Put, GrantAck ↔ Grant, ProbeAck ↔ Probe) | TileLink [@5]; CBOAck — **новое** |
| A4 | Не больше 5 открытых транзакций каждого вида | конечные source ID |
| A5 | **Окно свободы ядра** `core_free = !rst && (s_iso \|\| (core_rst && s_reset))`: все выходы ядра (TL, `l1_done`, `l1_idle`, `alive`, `fe_any`) произвольны каждый такт | sReset — RDC (как v5). **sIso добавлено намеренно**: ядро там живо, но изолировано; разрешить ему всё — слабее реальности, доказательство сильнее |
| A6 | В сбросе ядра вне окна свободы (сброс тайла, sRelease, пока синхронизатор держит): `valid` = 0, `alive` = 0, `done` = 0; `idle` свободен | значения сброса регистров DCache / LSU |
| A7 | Frontend выходит из сброса на 2 такта позже остального ядра; `core_in_reset` контроллера = `fe_any` в окне свободы, иначе `fe_rst` | цепочка ResetGen, frontend последний (`Frontend.scala:452`) |
| A8 | DCache не начинает новый Release вне sIdle / sQuiesce | assert DCacheImp «Release started after the drain reported done» (DESIGN 4.3), проверяется RTL-тестом (K3) и S19 |
| A9 | (снято) v5 `l1_done → l1_req` | было сильнее RTL на такт: `DCacheQuiesceUnit` держит sDone в такте, где `req` упал |
| A10 | `l1_done → (l1_req \|\| l1_req_q)` | `DCacheQuiesceUnit`: sDone требует `req` в прошлом такте; `FakeDCache`: `done := req` в том же такте (DESIGN 5.9) — допущение — их объединение (**исправление v5**) |
| A11 | `alive` = 0 в сбросе, поднимается не позже 6 тактов после выхода из сброса синхронизатора, не упорядочен с frontend, дальше держится | урок v5: граница 3 маскировала мутант; 6 тактов покрывают разницу ступеней ResetGen |
| A12 | До первой последовательности ядро работает (`alive` = 1) | нормальная работа |
| A13 | `req`, `l_b_v` (Probe от L2), `ready` всех каналов — свободны; **нет** допущения стабильности `valid` | TileLink [@4.1] разрешает снять непринятый beat |
| A14 | `l1_idle` свободен всегда | флаг текущего такта, не обещает ничего |

Допущения v5, требующие `!core_rst`, переписать на `!core_free && !core_rst` (A5 / A6).

#### Свойства (assert; номера v5 сохранены там, где смысл тот же)

| P | Метка (assert) | Формула (словами / SV) | v6 |
|---|---|---|---|
| P1 | `P1_reset_point_clean` | `(s_iso \|\| s_reset) → nothing_outstanding` | + sIso |
| P2 | `P2_nothing_crosses` | `(s_iso \|\| s_reset \|\| s_release) → !any_fire` | + sIso |
| P3 | `P3_no_probe_to_reset` | `(core_rst \|\| s_iso \|\| s_reset \|\| s_release) → !c_b_v` | + sIso |
| P4 | `P4_a_message_not_cut` | как v5 | = |
| P5 | `P5_quiet_is_sound` | все `quiet` → `nothing_outstanding` | = |
| P6 | `P6_reset_only_in_reset` | `core_reset == s_reset && in_reset == core_reset` | усилено (`core_in_reset`) |
| P7 | `P7_no_probe_before_alive` | как v5 | = |
| P8 | `P8_b_closed_only_in_procedure`, `P8B_closed_bounded_after_req` | B закрыт → `s_drain..s_release`; граница `RST + ISO + 16` | + sIso |
| P8N | `P8N_held_only_in_drain_iso`, `P8N_taken_at_once`, `P8N_ack_offered` | FULL: `hold_probe == (s_drain \|\| s_iso)`; в sReset / sRelease Probe берётся сразу, если нет `ack_pend`; ожидающий ProbeAck всегда предложен | изм. |
| P9 | `P9_no_new_noncoherent` | как v5 | = |
| P10 | `P10_noncoherent_quiet_in_drain` | как v5 | = |
| P11 | `P11_hart_in_reset_is_busy` | `hart_in_reset == busy && busy == !s_idle` | изм. |
| P12 | `_one_at_a_time`, `_ack_is_NtoN`, `_ack_follows_probe`, `_not_inside_c_msg`, `_only_without_keep`, **`_take_only_in_reset`** | v5 + новое: `fbg → (s_reset \|\| s_release)` | + |
| P13 | `P13_reset_until_req_drops` | как v5 | = |
| P14 | `P14_reset_at_least_rst` | как v5 | = |
| P15 | `P15_isolation_tile_side`, `_core_side` | как v5 (теперь с первого такта sIso) | = |
| P16 | `P16_isolation_covers_reset`, `P16_isolation_only_in_procedure` | `(core_reset \|\| cr_q2) → isolate`; `isolate == (s_iso \|\| s_reset \|\| s_release)` | изм. |
| P17 | `P17_b_closed_when_isolated` | как v5 | = |
| P18 | `P18_b_held_from_first_drain_cycle` | как v5 | = |
| P19 | `P19_decision_after_done_idle` | `isolate && !isolate_q → l1_done_q && l1_idle_q && gq_q` (все `quiet` прошлого такта) | изм. (точка решения, не сброс) |
| P20 | `P20_run_only_after_frontend` | как v5 | = |
| P21 | `P21_iso_lead` | `core_reset && !core_reset_q → iso_run >= ISO` (`iso_run` — подряд такты `isolate` до текущего) | **новое** (R3) |
| P22 | `P22_iso_drop_after_core_up` | `isolate_q && !isolate → st_q == 5 && alive_q && !core_in_reset_q` | **новое** (R4) |
| P23 | `P23_l1_req_through_iso` | `l1_req == (s_quiesce \|\| s_drain \|\| s_iso)` | **новое** |
| P24 | `P24_freeze_from_iso` | `l1_freeze == (KEEP && isolate)` | **новое** |
| P25 | `P25_no_busy_gap` | `!(st_q == 5 && s_idle && req_q)` и `busy_q && !busy → st_q == 5 && !req_q` | **новое** |

Итого 25 номеров, 37 меток assert. P23, P24, P11, P6 — «контрактные» свойства (переформулировка спецификации
выхода): без них мутанты `NO_REQ_IN_ISO`, `LATE_FREEZE`, `LATE_HART_IN_RESET`, `IN_RESET_WIDE` в этой модели
среды не видны (среда A5 произвольна в sIso; DCache нет). Их функциональные следствия проверяются в
моделировании (S15, S18, S11) и RTL-тесте (K4, K5).

#### Покрытия (cover; в прогоне — как assert `!(Cn)` через pdr, урок v5)

| C | Что достигается | Конфигурации |
|---|---|---|
| C1, C2 | транзакции в полёте на старте → сброс (v5) | f, k |
| C3 | Probe удержан в сбросе, потом доставлен (v5) | k (в f — через гейт, см. C7) |
| C4 | возврат в sIdle (v5) | f, k |
| C5 | Probe в первом такте sDrain: KEEP — удержан, доставлен после; FULL — удержан, ответ гейта в sReset | f, k (в v5 только KEEP) |
| C6 | долгий сброс (`RST + 24`) и запуск (v5) | f, k |
| C7 | ответ гейта в сбросе, затем запуск (v5) | f |
| C8 | icachectrl в полёте на старте (v5) | f, k |
| C9 | мусор ядра в сбросе, затем запуск (v5) | f, k |
| C10 | **две последовательности подряд**: два подъёма `core_reset`, `busy` = 1 всё время между ними | f, k |
| C11 | **Probe предложен в sIso**: держится, затем FULL — ответ гейта, KEEP — доставка после | f, k |
| C12 | **запрос снят в sQuiesce**, последовательность всё равно дошла до sReset и до sIdle | f, k |
| C13 | **`ack_pend` пережил sIdle**, потом B снова открыт (Probe к ядру) | f |
| C14 | **sIso длится 2 такта**, затем sReset | f2, k2 |

#### Конфигурации и прогоны

| Конф. | define | Что |
|---|---|---|
| f | — | prove RST100, prove RST16, covers (RST16), мутанты (RST16), EQUIV |
| k | `CFG_KEEP` | то же |
| f2 | `ISO2` | prove RST16, C14, мутанты `ISO_SHORT`, `NO_ISO_LEAD` |
| k2 | `CFG_KEEP ISO2` | то же |

Мутанты `fv_boundary` (все должны упасть; RST16; abc bmc3 глубина 60, лимит 300 с, затем pdr — как v5):
- общие (23): `NO_DRAIN, STALE_QUIET, NO_L1_IDLE, NO_ALIVE, NO_FE_WAIT, NO_EARLY_QUIET, NO_EARLY_BLOCK,
  LATE_HOLDB, NO_HOLD_IN_RELEASE, RESET_EARLY, ISO_LATE, ISO_EARLY_DROP, NO_ISO_LEAD, NO_REQ_IN_ISO,
  LATE_HART_IN_RESET, BUSY_GAP, IN_RESET_WIDE` (`CTRL_MUTANT_*`), `GATE_MUTANT_ALWAYS_QUIET, _CUT_A, _NO_ISO_C,
  _NO_ISO_D, _NO_ISO_E`, `ISO_MUTANT_NO_ISO`;
- f (+4 = 27): `GATE_MUTANT_NO_ACKB, GATE_MUTANT_ACK_PARAM, CTRL_MUTANT_NOKEEP_HOLDB, CTRL_MUTANT_ACK_IN_ISO`;
- k (+2 = 25): `GATE_MUTANT_NO_HOLDB, CTRL_MUTANT_LATE_FREEZE`;
- f2, k2: `CTRL_MUTANT_ISO_SHORT`, `CTRL_MUTANT_NO_ISO_LEAD`.

Ожидаемо эквивалентные (замороженный список v5, prove должен пройти): `GATE_MUTANT_NO_ISO_A`,
`ISO_MUTANT_ALWAYS_QUIET` — без изменений. `GATE_MUTANT_NO_ISO_B` в `fv_boundary` **не запускается** (по P17 он
здесь эквивалентен; добавлять его в замороженный список — только решением пользователя, вопрос В1 раздела 11);
он убивается в `fv_adapters`.

### 2.3. `formal/fv_adapters.sv` (новый)

Цель — показать, что изоляция **локальна**: она держится регистром `isolate` сама, без допущений о декодах
`holdB` / `ackB` / `block` (правило R2; DESIGN 3 п. 1 «`out.b.ready` при `isolate` не зависит от `in.b.ready` ни
в одной ветви»). Это закрывает два эквивалентных мутанта v5 и даёт мутанту `NO_ISO_B` наблюдаемость.

Состав: `cr_gate #(1)` (TL-C), `cr_gate #(0)` (UL), `cr_iso`; все управляющие входы (`block, hold_b, ack_b,
isolate`) — **свободны**, без допущения `isolate → hold_b || ack_b` и без `!(hold_b && ack_b)`. TL-допущения —
A1–A4 на обеих сторонах. Свойства:

| L | Свойство |
|---|---|
| L1 | TL-C гейт, `isolate`: к L2 `a.valid = 0`, `e.valid = 0`, `d.ready = 0`, `c.valid → pend`, `b.ready == ((ack_b \|\| pend) && take_b)`; к ядру `b.valid = 0`, `d.valid = 0`, `a/c/e.ready = 0` |
| L2 | UL гейт, `isolate`: `a.valid = 0`, `d.ready = 0`, к ядру `d.valid = 0`, `a.ready = 0` |
| L3 | `cr_iso`, `isolate`: к ядру `a.valid = 0`, `d.ready = 0`; к тайлу `a.ready = 0`, `d.valid = 0` |
| L4 | `quiet` **каждого** адаптера → на его ребре нет открытых транзакций и половинок сообщений |
| L5 | A режется только на границе сообщения (`block` свободен) |
| L6 | ответ гейта: один в полёте, ProbeAck NtoN, адрес = адрес принятого Probe, не внутри C ядра |

Мутанты (все должны упасть): `GATE_MUTANT_NO_ISO_A, _NO_ISO_B, _NO_ISO_C, _NO_ISO_D, _NO_ISO_E, _ALWAYS_QUIET,
_CUT_A, _ACK_PARAM`, `ISO_MUTANT_NO_ISO, ISO_MUTANT_ALWAYS_QUIET` — 10. Эквивалентных нет.

### 2.4. `formal/run_formal.sh` — изменения

- `cfgdefs`: `f → ""`, `k → CFG_KEEP`, `f2 → ISO2`, `k2 → "CFG_KEEP ISO2"`; `cfgname`: FULL / KEEP / FULL iso2 /
  KEEP iso2. Аргументы по умолчанию — `f k`; `f2`, `k2` запускаются из того же вызова после `f`, `k`, их строки
  пишутся в файлы `results_formal_f.txt` / `results_formal_k.txt` соответственно.
- Списки мутантов — раздел 2.2; `EQUIV` — без изменений.
- Новый режим `adapters`: `./run_formal.sh adapters` — prove `fv_adapters` + 10 мутантов (bmc 30, затем pdr).
- `QUICK=1`: prove RST16 для f и k + prove `fv_adapters`.
- `PROVE_TIMEOUT` (по умолчанию 3600 с) на каждый prove; TIMEOUT = неожиданный результат.
- Строки вывода — формат v5 (его разбирает `doc/results.py`), плюс:
  ```
  design prove rstCycles=16 isoCycles=2 (abc pdr, unbounded): PASS  (12.3 sec)
  adapters prove (abc pdr, unbounded): PASS  (4.1 sec)
  GATE_MUTANT_NO_ISO_B             adapters bmc : FAIL at cycle 3  L1_tlc_isolation
  ```
  Для `isoCycles=1` строка остаётся как в v5 (без поля `isoCycles`). `doc/results.py` — ключ prove `(rst, iso)`.

---

## 3. Эквивалентность RTL ↔ модели

### 3.1. Цели elaboration (`elab/CoreResetElabHarness.scala`, `xiangshan.CoreResetElab`)

| Цель | Что | Модуль после `extract_rtl.py` |
|---|---|---|
| `ctrl_full` | `CoreResetCtrl(keepL1 = false)` | `CoreResetCtrl_full` |
| `ctrl_keep` | `CoreResetCtrl(keepL1 = true)` | `CoreResetCtrl_keep` |
| `ctrl_full_iso2` | `CoreResetCtrl(false, isoCycles = 2)` | `CoreResetCtrl_full_iso2` |
| `ctrl_keep_iso2` | `CoreResetCtrl(true, isoCycles = 2)` | `CoreResetCtrl_keep_iso2` |
| `gates` | как v5 (TL-C гейт, UL гейт, `TLResetIsolation`) | `TLQuiesceGate`, `TLQuiesceGate_1`, `TLResetIsolation` |
| `quiesce` | `DCacheQuiesceUnit` (Parameters из `XSNoCTopConfig` + `EnableCoreReset`) | `DCacheQuiesceUnit` |
| `dcache_full`, `dcache_keep` | RTL-тест, раздел 5.2 (в `build/`, не в `rtl/`) | — |
| `ident_dcache` | идентичность, раздел 7 (вызов кода из `elab/CoreResetIdentElab.scala`) | — |

`rtl/` (вырезанные модули ctrl / gates / quiesce) коммитится, как в v5; `check.sh` сравнивает свежую выборку с
закоммиченной, игнорируя номера строк `*.scala:N` в сообщениях assert.

### 3.2. Миттеры (`formal/eq_chisel.sv`, `formal/run_equiv.sh`)

| Миттер | Верх | Параметры | Сравнивается |
|---|---|---|---|
| `ctrl_full` | `eq_ctrl` | `KEEP 0 ISO 1` | все 11 выходов `cr_ctrl` каждый такт, кроме первого |
| `ctrl_keep` | `eq_ctrl` | `KEEP 1 ISO 1` | то же |
| `ctrl_full_iso2` | `eq_ctrl` | `KEEP 0 ISO 2` | то же |
| `ctrl_keep_iso2` | `eq_ctrl` | `KEEP 1 ISO 2` | то же |
| `gate_c` | `eq_gate_c` | — | v5 + **RTL-only** assert-ы на ответ гейта: при `pend` `oc.opcode = ProbeAck`, `param = NtoN`, `source / address / size` = принятого Probe, `corrupt = 0` |
| `gate_ul` | `eq_gate_ul` | — | как v5 |
| `iso` | `eq_iso` | — | как v5 |
| `quiesce` | `eq_quiesce` (новый) | — | `block, done, idle, alive` |

Кодирование опкодов в `eq_chisel.sv`: добавить CBO (модель A 5 ↔ RTL 12–14) и CBOAck (модель D 2 ↔ RTL 8);
`chparam -set KEEP .. -set ISO_CYCLES .. eq_ctrl` (в `run_equiv.sh` — поле параметров списка). Движки v5: bmc 30
(smtbmc yices) + prove (abc pdr). Вывод — формат v5 (8 строк + `failed miters: N`).

---

## 4. Моделирование (Verilator, модели)

### 4.1. Изменения моделей

**`cr_dcache.sv`** (`model/cr_dcache.sv:1–480`):
1. Удалить обход: `K_FLUSH`, `F_SWEEP/F_WAIT`, `fset/fway/inflight`, мутанты `SWEEP_*`, `NO_SWEEP`. Блок
   опустошения — экземпляр `cr_quiesce` (раздел 2.1), выходы `flush_*` → `quiesce_done`, `quiesce_idle`, `block`.
2. Массивы: KEEP — `st` (meta) на `meta_rst` (сброс тайла), `tg` / `dat` (SRAM) без сброса; FULL — `st` и `tg`
   на сбросе ядра (`TagSRAMBank.rst_cnt` обнуляет теги), `dat` без сброса.
3. **Модель обращений к массивам** (новое): сигналы такта `tag_rd, tag_wr, data_rd, data_wr, meta_rd, meta_wr`
   (+ адрес). Источники: поиск load (случайные load каждый такт, пока ядро вне сброса — и в sQuiesce / sDrain /
   sIso), чтение s1 MainPipe, запись s3 и refill (запись — через ступень на такт позже s3, как `s1_way_wen` /
   `wen_reg`). KEEP: каждое разрешение зажимается `freeze` на входе («граница модуля»). Мутанты:
   `FREEZE_MUTANT_NO_SRAM_MASK` (запись не зажата; v5), **`FREEZE_MUTANT_NO_READ_MASK`** (чтение tag / data и
   `meta_rd` не зажаты; это NO_READ_FREEZE дизайна).
4. **Модель гонки асинхронного сброса**: в первых 1–4 тактах сброса ядра (GARBAGE, как v5) случайные
   разрешения и адреса; они маскируются только `freeze && freeze_q` (квалификатор должен стоять до фронта
   сброса). Так `NO_ISO_LEAD` в KEEP портит массивы и ловится S16, а не только контрактом.
5. Выход для проверки `arr_access` = любое из шести разрешений после зажима; счётчики `iso.loads_clamped`
   (load в sIso / sReset, чтение не выполнено), `iso.garbage_masked`.
6. `QUIESCE_MUTANT_NO_BLOCK` (бывший `FLUSH_MUTANT_NO_BLOCK`): store проходят при `block`.
7. (желательно, если укладывается) CBO: команда `cbo.clean/flush/inval` через MissQueue-модель как отдельный
   запрос A (опкод 5), ответ CBOAck; `mq_empty` ждёт его. Без CBO — SCEN 5 C14 пропускается (`SKIPPED` в логе).
8. Мутанты v5 `META_MUTANT_CORE_RESET`, `TAG_MUTANT_CORE_RESET` (KEEP) — без изменений;
   `NOKEEP_MUTANT_META_KEPT` (FULL: meta переживает сброс) — **теперь должен ловиться** (обхода нет, L1D не пуста).

**`cr_env_models.sv`, `cr_l2`** (`:146–378`): режим FULL (параметр `KEEP` из стенда):
1. В точке сброса (FULL) для каждой строки, которую директория числит за L1D: `stale[i] = 1`.
2. Acquire строки со `stale` — законен (CoupledL2 обслуживает как попадание, DESIGN 7.2 п. 2); снимает `stale`,
   счётчик `full.reacquire_stale`. Ошибка «Acquire строки, которую клиент уже держит» — только при `!stale`.
3. ProbeAck NtoN по строке со `stale` — законен (директория → N), счётчик `full.nton_stale`.
4. `poison` (AcquirePerm, `:252–291`): в FULL GrantData / Get-ответ отравленной строки после сброса — не
   `$error`, а счётчик `full.foreign_grant` (DESIGN 7.2 п. 3, NtoT); в KEEP — ошибка, как в v5.

**`cr_tb.sv` — эталон данных** (`golden`): в точке сброса FULL строки, грязные в L1D, получают
`golden[i] := mem[i]` (потеря записи, 7.2 п. 1, счётчик `full.lost_dirty`); строки, грязные **и** отравленные,
получают `golden_valid[i] := 0` (значение не определено, `full.foreign_lines`); `golden_valid` возвращается в 1
при следующей полной записи строки (store на всю строку или ReleaseData / ProbeAckData). Все проверки данных
пропускают строки с `!golden_valid` и считают пропуски (`full.skipped_checks`). В KEEP `golden_valid` всегда 1.

**Поток команд ядра**: `traffic_en` для DCache — `traffic_en && !core_rst` (в v5 было `&& !hart_in_reset`; в v6
`hartInReset = busy` выключил бы load с первого такта sQuiesce и сделал проверку зажима чтения пустой).

### 4.2. Проверки стенда (S1–S23)

| S | Проверка | Где | v6 |
|---|---|---|---|
| S1 | в точке сброса: L2 без открытых транзакций, гейты / изоляция тихие, буферы B / C пусты, `busy_true` DCache = 0 | `cr_tb` | = |
| S2 | в sIso / sReset / sRelease ни одного beat-а на стороне ядра и ничего от ядра на стороне тайла (кроме ProbeAck гейта) | `cr_tb`, `cr_txmon` | + sIso |
| S3 | после старта ни одного нового запроса некогерентных | `cr_tb`, `cr_txmon` | = |
| S4 | при входе в sDrain ничего некогерентного не открыто | `cr_tb` | = |
| S5 | ни один Probe не проходит гейт L1D в sDrain и sIso | `cr_tb`, `cr_txmon` | + sIso |
| S6 | сброс ≥ `RST_CYCLES` | `cr_tb` | = |
| S7 | выход из сброса только после снятия запроса | `cr_tb` | = |
| S8 | конец последовательности только при frontend вне сброса; `isolate` падает только на такт после `alive && !fe_rst` | `cr_tb` | + |
| S9 | **опережение**: подъём сброса ядра от контроллера только если `isolate` стоял `ISO_CYCLES` тактов подряд | `cr_tb` | новое |
| S10 | `isolate` только в sIso / sReset / sRelease и всегда, пока сброс ядра в синхронизаторе; `in_reset` только в sReset | `cr_tb` | изм. |
| S11 | `hart_in_reset == busy` каждый такт | `cr_tb` | изм. |
| S12 | один сброс на зафиксированный запрос; при повторном запросе до `coreUp` — переход sRelease → sQuiesce и `busy` без провала | `cr_tb` (SCEN 8, 9) | новое |
| S13 | FULL: гейт берёт Probe только в sReset / sRelease; предложенный тогда Probe берётся сразу, если нет `ack_pend`; на каждый — ровно один ProbeAck NtoN гейта | `cr_tb`, `cr_txmon` | изм. |
| S14 | KEEP: гейт не отвечает никогда; Probe ждёт в sReset / sRelease; удержанный доставляется после | `cr_probe_sb`, SCEN 6 / 7 | = |
| S15 | KEEP: `arr_access == 0`, пока `isolate` (запись и чтение всех массивов) | `cr_dcache` | новое (вместо «meta не меняется при freeze» — та оставлена как вторая) |
| S16 | KEEP: строки L1D (meta + tag + data) после сброса совпадают с директорией L2 и эталоном (`check_lines`) | `cr_tb` | = |
| S17 | FULL: L1D пуста после сброса (meta N, теги 0) | `cr_tb` | изм. (было для sweep) |
| S18 | DCache не принимает store / AMO / CMO / новый промах со второго такта последовательности до сброса ядра (по состоянию контроллера, не по `l1_req`) | `cr_dcache` | новое |
| S19 | после `done` не начинается Release | `cr_txmon` | = |
| S20 | данные: эталон vs L1D / L2 (KEEP строго; FULL с учётом `golden_valid`, счётчики `full.*`) | `cr_tb` | изм. |
| S21 | отчёт ProbeAck vs директория L2 (FULL: NtoN законен для `stale`) | `cr_probe_sb` | изм. |
| S22 | Probe не ждёт дольше 200 тактов вне сброса (KEEP: такты sReset / sRelease не считаются) | `cr_probe_sb` | = |
| S23 | load-попадания = эталону (FULL: кроме `!golden_valid`) | `cr_tb` | изм. |

Ошибка стенда v5 (SCEN 6 seed 24, `quiet_env` без MainPipe) — исправление сохранить.

### 4.3. Сценарии

Номера v5 сохраняются; добавляются 8 и 9. `+SLOW` по умолчанию в SCEN 5–9.

| SCEN | Что | Изменения v6 |
|---|---|---|
| 1 | три сброса (короткий запрос) на фоне трафика и снупов | = |
| 2 | 12 сбросов подряд со случайными паузами | = |
| 3 | запрос случайной длины (2..2000) ×4 | = |
| 4 | наивный сброс без последовательности (ошибки ожидаются) | = |
| 5 | старт последовательности в момент транзакции класса C1–C12 (v5) | + **C13**: load читает SRAM в такте решения (KEEP: зажим чтения в sIso); **C14**: CBO в полёте (если CBO в модели); **C15**: Probe предложен в такте решения |
| 6 | направленные Probe строк L1D (грязная / чистая T / B, toN / toB) | случаи 0–5 v5 (5 — «последний такт sQuiesce») + **6** — предложен в первом такте sIso (с ISO2 — и во втором), **7** — в такте решения (последний такт sDrain), **8** — в такте `coreUp` (последний такт sRelease) |
| 7 | долгий `debug_reset` (2000..20000) со снупами | FULL: снупы строк, бывших в L1D, отвечает гейт NtoN сразу (данные L2; потеря грязных — учёт); KEEP — как v5 |
| 8 | **сбросы подряд**: запрос снят в sReset после `rstCycles` и снова поднят (а) в sRelease до `coreUp`, (б) ровно в такте `coreUp`, (в) через такт после sIdle (для сравнения: обычный провал), (г) не снимается (одна длинная). По 3 раза каждый | новое |
| 9 | **снятие / подъём запроса в каждом состоянии**: импульс 1 такт в sIdle; снятие в sQuiesce, sDrain, sIso, в sReset до и после `rstCycles`, в sRelease; повторный подъём в sReset до `rstCycles` | новое |

Ожидаемый исход SCEN 6 по случаям (проверяется стендом):

| Случай | FULL | KEEP |
|---|---|---|
| 0 sReset, 1 sRelease | гейт сразу, NtoN; грязная строка — `full.lost_dirty` | ждёт до конца sRelease, отвечает L1D с данными |
| 2 после | пустая DCache, NtoN | L1D с данными (строка «горячая») |
| 3 старт sQuiesce, 5 последний такт sQuiesce | L1D до сброса, с данными; sDrain ждёт ProbeAck | так же |
| 4 первый такт sDrain, 6 sIso, 7 такт решения | держится; в sReset — гейт NtoN | держится; после — L1D с данными |
| 8 такт `coreUp` | если принят в sRelease — гейт; иначе пустая DCache — NtoN | L1D после, с данными |

Строки лога SCEN 6 (формат v5 + новые):
```
directed: start-of-sQuiesce offered-in-sQuiesce=N later=N
directed: first-cycle-of-sDrain offered-in-sDrain=N transition-later=N
directed: last-cycle-of-sQuiesce offered-in-sQuiesce=N later=N
directed: first-cycle-of-sIso offered-in-sIso=N later=N
directed: decision-cycle offered-in-decision=N later=N
directed: coreup-cycle offered-in-sRelease=N later=N
```

### 4.4. Регрессия (`scripts/regress.sh`)

Имена конфигураций в строках результатов: `CFG=FULL`, `CFG=CFG_KEEP`, `CFG=ISO2`, `CFG=CFG_KEEP+ISO2`.

Проекты (design) на конфигурацию FULL и CFG_KEEP:

| Набор | Сиды | Прогонов |
|---|---|---|
| SCEN 1, 2, 3 | 1–15 | 45 |
| SCEN 1, 2, 3 +SLOW | 1–5 | 15 |
| SCEN 5 | 1–10 | 10 |
| SCEN 6 | 1–5 | 5 |
| SCEN 7 | 1–5 | 5 |
| SCEN 8 | 1–5 | 5 |
| SCEN 9 | 1–5 | 5 |
| SCEN 4 (наивный, ошибки ожидаются) | 1–3 | 3 |

= 93 на конфигурацию; плюс `CFG_KEEP+ISO2`: SCEN 2, 5, 6, 8 × сиды 1–3 = 12; `ISO2`: SCEN 2, 6 × 1–3 = 6. Всего
**204** прогона проекта (из них 6 наивных).

Мутанты (каждый прогон обязан сообщить ошибку; сиды 1–3, если не сказано иначе):

| Мутант | Конфиг. | SCEN |
|---|---|---|
| `GATE_MUTANT_ALWAYS_QUIET`; `+NO_CTRL_ASSERT` | обе | 2; 5 |
| `CTRL_MUTANT_NO_DRAIN`; `+NO_CTRL_ASSERT` | обе | 2 |
| `CTRL_MUTANT_NO_FE_WAIT` | обе | 2 |
| `CTRL_MUTANT_NO_HOLD_IN_RELEASE+NO_CTRL_ASSERT` | обе | 6 |
| `GATE_MUTANT_NO_ISO_C`, `_NO_ISO_E`, `ISO_MUTANT_NO_ISO`, `CTRL_MUTANT_ISO_LATE+NO_CTRL_ASSERT`, `CTRL_MUTANT_ISO_EARLY_DROP+NO_CTRL_ASSERT`, `CTRL_MUTANT_NO_ISO_LEAD+NO_CTRL_ASSERT` | обе | 2 |
| `CTRL_MUTANT_STALE_QUIET`, `CTRL_MUTANT_LATE_HOLDB` | обе | 6 |
| `CTRL_MUTANT_NO_EARLY_BLOCK`, `CTRL_MUTANT_NO_EARLY_QUIET` | обе | 2, 5 |
| `CTRL_MUTANT_RESET_EARLY` | обе | 3, 7 |
| `CTRL_MUTANT_NO_REQ_IN_ISO` | обе | 2, 5 |
| `CTRL_MUTANT_LATE_HART_IN_RESET` | обе | 1 |
| `CTRL_MUTANT_BUSY_GAP` | обе | 8 |
| `CTRL_MUTANT_IN_RESET_WIDE` | обе | 1 |
| `QUIESCE_MUTANT_NO_MQ_WAIT` | обе | 5 |
| `GATE_MUTANT_CUT_A+NO_CTRL_ASSERT`, `QUIESCE_MUTANT_NO_WBQ_WAIT+NO_CTRL_ASSERT`, `QUIESCE_MUTANT_NO_BLOCK`, `+NO_CTRL_ASSERT`, `QUIESCE_MUTANT_NO_MP_WAIT` | обе | редкие: `rare_seeds.txt` |
| `GATE_MUTANT_NO_ACKB`, `CTRL_MUTANT_NOKEEP_HOLDB`, `CTRL_MUTANT_ACK_IN_ISO`, `NOKEEP_MUTANT_META_KEPT` | FULL | 2, 6 |
| `GATE_MUTANT_ACK_PARAM` | FULL | 6, 7 |
| `GATE_MUTANT_NO_HOLDB` | KEEP | 2, 6 |
| `META_MUTANT_CORE_RESET`; `+NO_FREEZE_CHECK` | KEEP | 2; 2 6 7 |
| `TAG_MUTANT_CORE_RESET`, `FREEZE_MUTANT_NO_SRAM_MASK`, `FREEZE_MUTANT_NO_READ_MASK`, `CTRL_MUTANT_LATE_FREEZE` | KEEP | 2, 6 |
| `CTRL_MUTANT_ISO_SHORT` | `CFG_KEEP+ISO2`, `ISO2` | 2 |

Ожидаемо эквивалентные (`+EQUIV`, прогон обязан пройти): `CTRL_MUTANT_NO_L1_IDLE` (обе, SCEN 2 и 6),
`CTRL_MUTANT_NO_ALIVE` (обе, SCEN 5). Точные числа прогонов мутантов считает скрипт; после первого полного прогона
они замораживаются (раздел 12).

Редкие мутанты: сиды v5 подобраны под Verilator 5.049 и под модель v5 — **недействительны**. Перед первой
регрессией — `scripts/seedsearch.sh` (список `DEFAULT` с новыми именами, конфигурации FULL и KEEP, сценарии 2 и
5, сиды 1–30, по 5 ловящих); новый `rare_seeds.txt` коммитится и попадает в результаты и PDF. Мутант без
найденного сида — строка `SKIPPED` и запись в отчёт как дыра (не прятать).

### 4.5. Длинный прогон (`scripts/soak.sh FULL|CFG_KEEP`)

| Набор | Сиды | Прогонов |
|---|---|---|
| SCEN 1–3 | 31–130 | 300 |
| SCEN 1–3 +SLOW | 11–40 | 90 |
| SCEN 5 | 21–70 | 50 |
| SCEN 6 | 11–35 | 25 |
| SCEN 7 | 11–35 | 25 |
| SCEN 8 | 11–35 | 25 |
| SCEN 9 | 11–35 | 25 |

= 540 на конфигурацию; файлы `results_soak_FULL.log`, `results_soak_CFG_KEEP.log`, итоговая строка
`soak <cfg> pass=N fail=N`. Обе конфигурации — параллельно, после того как бинарники собраны по очереди.

### 4.6. Строки лога и ключи покрытия (`scripts/coverage.py`)

Ключи v5 сохраняются с переименованием `sFlush` → `sQuiesce`; `dir.swept_*`, `final.releases-during-quiesce` (с
обходом) — удалить. Новые строки (печать в `finish`) и ключи:

| Строка лога | Ключи JSON |
|---|---|
| `iso: phases=N cycles=N loads-clamped=N garbage-masked=N sram-access-in-iso=N` | `iso.*` (`sram-access-in-iso` в KEEP обязан быть 0, в FULL > 0 — непустота проверки) |
| `b2b: direct=N gap=N probes-across=N` | `b2b.*` (SCEN 8: `direct` > 0; KEEP: `probes-across` — Probe, удержанный через два сброса) |
| `req-drop: sIdle-pulse=N sQuiesce=N sDrain=N sIso=N sReset-early=N sReset-late=N sRelease=N reraise-in-sReset=N` | `req_drop.*` |
| `full: lost-dirty=N foreign-lines=N foreign-grant=N nton-stale=N reacquire-stale=N gate-acks=N skipped-checks=N` | `full.*` (только FULL) |
| `directed: …` (раздел 4.3) | `dir.<case>.offered`, `dir.<case>.later` |
| `triggers hit/missed: C1..C15` | `trig_hit.C*`, `trig_miss.C*` |

Порядок разбора в `coverage.py`: специальные `directed:`-строки — **до** общего `directed:` (урок v5).

### 4.7. Мутанты моделирования: правила

- Список ожидаемо эквивалентных заморожен: `CTRL_MUTANT_NO_L1_IDLE`, `CTRL_MUTANT_NO_ALIVE` (обе конфигурации).
  Из списка v5 вместе с обходом уходят `NOKEEP_MUTANT_META_KEPT` (sweep) и `FLUSH_MUTANT_NO_MP_WAIT` (sweep): в
  FULL v6 обхода нет, оба должны ловиться. Новых эквивалентных нет.
- `QUIESCE_MUTANT_NO_PQ_WAIT` **не вводится**: `pq_empty` избыточен при `quiet` гейта (Probe в буфере B и в
  ProbeQueue уже посчитан счётчиком `probes` гейта до своего ProbeAck) — мутант был бы эквивалентен; вопрос
  пользователю не нужен, фиксируется в PDF как анализ.
- Немой мутант (не пойман) — дыра: сообщить координатору, не подгонять сиды молча.

---

## 5. RTL-тест настоящей DCache (новое, находка 2 ревью)

### 5.1. Цель

Проверить опустошение, флаги пустоты, блокировки и freeze на **настоящем** RTL `DCacheWrapper` (Chisel v6) вместе
с RTL `TLQuiesceGate("l1d")` и `CoreResetCtrl`, против модели L2 (TL-C ответчик), в FULL и KEEP (в KEEP ещё
`isoCycles = 2`). Модель `cr_dcache` проверяет алгоритм; этот тест — что Chisel его реализует.

### 5.2. Harness (Chisel, цели `dcache_full`, `dcache_keep`)

`class CoreResetDCacheHarness(keep: Boolean)(implicit p: Parameters) extends LazyModule`, в
`elab/CoreResetElabHarness.scala`:

- **Parameters**: `ArgParser.parse(Array("--config", "XSNoCTopConfig", "--fpga-platform", "--dfx", "false"))`
  (как `make verilog`, **без** `--remove-assert`), затем `alter`: `SoCParamsKey` → `EnableCoreReset = true`,
  `CoreResetKeepL1 = keep`; `XSCoreParamsKey => up(XSTileKey).head` (как `XSNoCTop.scala:207`). Перед
  elaboration `Constantin.init(false)`, `ChiselDB.init(false)` (как `Top.scala:648–651`), `DisableMonitors`.
- **Diplomacy**: `dcache = LazyModule(new DCacheWrapper)`; `buf = LazyModule(new TLBuffer)` (как
  `l1d_to_l2_buffer`, `MemBlock.scala:267`, домен ядра); `gate = LazyModule(new TLQuiesceGate("l1d", early =
  false))`; менеджер `l2 = TLManagerNode(...)` с параметрами L2 — скопировать `managerPortParams` CoupledL2
  (`coupledL2/src/main/scala/coupledL2/CoupledL2.scala:258–279`: `beatBytes = 32`, `endSinkId`, `responseFields`,
  `requestKeys`), чтобы ширины source / sink / user / echo совпали с продуктом; `l2 := gate.node := buf.node :=
  dcache.clientNode`; `l2.makeIOs()`. `dcache.uncacheNode` (CtrlUnit, `EnableDCacheCtrl = true` по умолчанию) —
  к фиктивному `TLClientNode`, внутри harness `a.valid := false.B`, `d.ready := true.B`.
- **Сброс** (как XSTile, DESIGN 5.13): `module.reset` = сброс тайла (`RequireAsyncReset`);
  `coreRst = ResetGen(reset || io.core_reset)` → `dcache.module.reset`, `buf.module.reset`, драйверы;
  KEEP: `dcache.module.io.keepReset.get := ResetGen(reset)`; `io.core_in_reset` = ещё одна ступень `ResetGen`
  после `coreRst` (имитация frontend, последнего в цепочке).
- **Контроллера внутри нет**: порты `core_reset` (in), `quiesce` (`Flipped(L1QuiesceIO)` наружу: `req, freeze`
  in, `done, idle, alive` out), `gate` (`QuiesceGateIO`), `core_in_reset` (out). Контроллер ставит стенд — RTL
  `CoreResetCtrl_*` из `rtl/` (по умолчанию) или модель `cr_ctrl` (`+define+CTRL_MODEL`, для мутантов; модель
  доказанно эквивалентна, раздел 3).
- **Упрощённые драйверы** (в домене сброса ядра, внутри harness), остальные входы `DCacheIO` — константы:
  - store (`io.lsu.store`): `st_req_{valid,ready,addr,data[511:0],mask[63:0],id}`, `cmd = M_XWR`,
    `vaddr = addr`; ответы `st_resp_{hit,replay}_valid, id`;
  - atomics (`io.lsu.atomics`): `amo_req_{valid,ready,cmd,addr,data,mask,cmp}` → `MainPipeReq` заполняется **как
    `AtomicsUnit.scala:496–538`** (`source = AMO_SOURCE`, `word_idx`, `amo_data`, `amo_mask`, `amo_cmp`,
    `vaddr = addr`); ответ `amo_resp_{valid,data,miss,replay}`; `block_lr` наружу;
  - CMO: `io.cmoOpReq` / `io.cmoOpResp` напрямую;
  - WFI: `wfi_req` (in), `wfi_safe` (out);
  - load: один порт `io.lsu.load(0)`: `ld_req_{valid,ready,addr}`; s1: `s1_paddr_dup_* = vaddr` прошлого такта,
    `s1_kill = s2_kill = 0`; ответ `ld_resp_{valid,hit,miss,replay,data[63:0]}`. Остальные load-порты — `valid = 0`;
  - `l2_hint.valid = 0`, `lqEmpty = 1`, `force_write = 0`, `l2_pf_store_only = 0`, `sms_agt_evict_req.ready = 1`,
    `debugRolling`, `debugTopDown` — 0.
- Harness пишет `params.svh` рядом с RTL: `nSets, nWays, blockBytes, beatBytes, sourceBits, sinkBits, addrBits,
  nMissEntries, LRSCCycles` — стенд берёт их оттуда, числа не вписываются руками.
- Вывод: `build/core_reset_elab/dcache_<cfg>/` (весь каталог target-dir, включая inline-blackbox `ClockGate.sv`).
  В `rtl/` не коммитится.

### 5.3. Стенд (`tb_rtl/`)

| Файл | Что |
|---|---|
| `tb_rtl/dcache_tb.sv` | верх: такт, сброс тайла, DUT, контроллер (RTL или модель), `rtl_l2`, сценарий, проверки K*, отчёт |
| `tb_rtl/rtl_l2.sv` | TL-C ответчик (ширины из `params.svh`): директория клиента N / B / T по строке, данные 512 бит, `poison` после AcquirePerm, `stale` (FULL), очередь Probe (toN / toB, направленные и случайные), CBO: если строка у L1D — Probe (flush / inval → toN, clean → toB), затем CBOAck; управляемые задержки Grant / ReleaseAck / CBOAck; независимый счётчик транзакций на стороне L2; проверки протокола (опкоды, параметры, beat-ы, source / sink, NtoN без данных, ProbeAck на Probe) |
| `tb_rtl/dcache_drv.sv` | задачи сценария: store (с повтором по replay), AMO, LR / SC, AMOCAS, CBO, WFI, load, ожидание ответов; эталон данных по байтам |
| `tb_rtl/gen/mem_probes_<cfg>.svh` | генерируется `scripts/mem_probes.py` (раздел 5.5, K5) |
| `scripts/run_rtl_dcache.sh CFG CASE SEED [DEFINES]` | сборка `build/rtl_<cfg>[_defs]` (один раз на конфигурацию, никогда из двух процессов) и прогон |

Адресное пространство: 2–3 набора DCache × (nWays + 2) тегов (из `params.svh`), чтобы были вытеснения и
Release. Verilator: `--binary --timing --assert -j 4`, `+define+RANDOMIZE_REG_INIT +define+RANDOMIZE_MEM_INIT`,
`+verilator+rand+reset+2`; лог ищется на `Assertion failed`, `%Error`, `[ERROR]`.

### 5.4. Случаи (D1–D13) и случайный режим (R)

Все — в FULL и KEEP; D8–D10, D13 и R ещё в KEEP+ISO2. «Запрос» = подъём `req` контроллера.

| D | Случай | Как ставится | Что ожидается сверх K* |
|---|---|---|---|
| D1 | промах store (AcquireBlock) в полёте | запрос в такте, когда `rtl_l2` принял Acquire; Grant задержан на k ∈ {0, 5, 40} | `done` после GrantAck; KEEP: строка T dirty после сброса |
| D2 | store на всю строку (AcquirePerm) в полёте | то же | FULL: после сброса строка отравлена — `full.foreign_lines` (7.2 п. 3); KEEP: ProbeAckData = данные store |
| D3 | промах AMO (`amoadd.d`) | запрос при Acquire AMO | ответ AMO выдан до `done`; KEEP: строка с результатом AMO |
| D4 | LR (промах), затем запрос, затем SC | LR → запрос → после сброса SC | SC после сброса — неуспех (резервирования нет); Probe строки в sQuiesce во время окна LR/SC задерживается не дольше `LRSCCycles` |
| D5 | промах `amocas.d` (и `amocas.q`, если включён в конфигурации) | как D3 | как D3 |
| D6 | CBO clean / flush / inval к грязной строке L1D | запрос при приёме CBO в `rtl_l2`; `rtl_l2` шлёт Probe строки (B открыт в sQuiesce) | `done` после CBOAck; ProbeAckData с данными |
| D7 | WFI с неотправленным Acquire | `wfi_req = 1`, промах store (Acquire удержан WFI), запрос | Acquire уходит в sQuiesce (блокировка снимает `wfiReq`), последовательность завершается за ≤ 2000 тактов |
| D8 | Probe в последнем такте sQuiesce | `rtl_l2` поднимает `b.valid` в такте `busy && l1.req && !gate_block && l1.done` (условие перехода, только по портам) | Probe принят DCache, sDrain ждёт ProbeAck, sIso только после |
| D9 | Probe в первом такте sDrain | `b.valid` в первом такте `gate_block && !isolate` | держится; FULL: ответ гейта NtoN в sReset (`full.lost_dirty` для грязной); KEEP: после — L1D с данными |
| D10 | Probe в sIso, в sReset, в sRelease | по фазе | FULL: гейт NtoN, ровно один; KEEP: держится до конца sRelease |
| D11 | Release в полёте | вытеснение грязной строки (store в полный набор), ReleaseAck задержан | `done` после ReleaseAck |
| D12 | запросы подряд | повторный подъём в sRelease до `coreUp`; плюс импульс 1 такт в sIdle | sRelease → sQuiesce, `busy` без провала; импульс даёт полную последовательность |
| D13 | load через sIso | load каждый такт с последнего такта sDrain до сброса | KEEP: `sram_access_in_iso = 0`; FULL: `> 0` (непустота зондов K5) |
| R | случайная смесь store / AMO / CBO / load / Probe и запросов | сиды | все K* |

### 5.5. Проверки (K1–K11)

| K | Проверка |
|---|---|
| K1 | точка сброса (подъём `core_reset`): `gate.quiet` и независимый счётчик `rtl_l2` — ничего не открыто (Acquire, Grant без GrantAck, Release без ReleaseAck, Probe без ProbeAck, CBO без CBOAck), нет половины сообщения |
| K2 | подъём `l1.done`: все транзакции DCache закончены по счётчику `rtl_l2`, ответы store / AMO / CBO выданы; в такте решения `l1.idle = 1` |
| K3 | после `done` не начинается Release (счётчик `rtl_l2` + assert DCacheImp) |
| K4 | со второго такта `l1.req` до сброса ядра: ни одного `fire` на `st_req`, `amo_req`, `cmoOpReq`, ни одного нового Acquire |
| K5 | KEEP: пока `isolate`, на зондах из `mem_probes.svh` нет обращений: (а) границы модулей — `tagArray.io_read_*_valid`, `io_write_valid`, `bankedDataArray.io_read_*_valid`, `io_readline_valid`, `io_write_valid`, `io_write_dup_*_valid`, `metaArray/errorArray.io_read_*_valid`, `io_write_*_valid`; (б) сами память — все экземпляры `*_ext` под `tagArray` и `bankedDataArray`: `R*_en`, `W*_en`, `RW*_en` = 0 (это и CE, и исключение R6 (а) — `wen_reg`). `mem_probes.py` строит пути из иерархии RTL; если найдено 0 зондов памяти тегов или данных — FAIL (не пустая проверка) |
| K6 | в sIso / sReset / sRelease ничего не пересекает гейт ни в одну сторону (кроме ProbeAck гейта в FULL) |
| K7 | FULL: гейт берёт Probe только в sReset / sRelease; на каждый — ровно один ProbeAck NtoN с `source / address / size` Probe, `corrupt = 0`, без данных; KEEP: гейт не берёт Probe никогда |
| K8 | после последовательности: FULL — L1D пуста (Probe → NtoN, load → промах); KEEP — строки целы: отчёт ProbeAck совпадает с директорией `rtl_l2`, ProbeAckData = эталону, load-попадание = эталону, store в строку T — попадание без Acquire |
| K9 | ни один assert RTL (DCache, гейт, контроллер, XS assert) не сработал |
| K10 | данные: эталон vs L2 / L1D; FULL — с учётом 7.2 (`full.lost_dirty`, `full.foreign_lines`), KEEP — строго |
| K11 | протокол на стороне L2 (`rtl_l2`): опкоды, параметры, beat-ы, source / sink, Release не NtoN, ProbeAckData не NtoN |

### 5.6. Мутанты RTL-теста (через модель контроллера)

Chisel не мутируется. Контроллер заменяется моделью `cr_ctrl` (`+define+CTRL_MODEL`), мутант — тем же `define`,
что в моделировании. Должны ловиться (сиды 1–3, случай):

| Мутант | Конфиг. | Случай | Кто ловит |
|---|---|---|---|
| `CTRL_MUTANT_NO_DRAIN` | обе | D1, D11 | K1 / K9 |
| `CTRL_MUTANT_STALE_QUIET` | обе | D8 | K1 |
| `CTRL_MUTANT_LATE_HOLDB` | обе | D9 | K6 |
| `CTRL_MUTANT_NO_REQ_IN_ISO` | обе | R, D13 | K4 (KEEP ещё K5 / K9) |
| `CTRL_MUTANT_NO_ISO_LEAD` | обе | D1 | assert контроллера (RTL) и проверка S9-аналога в стенде |
| `CTRL_MUTANT_ACK_IN_ISO` | FULL | D10 | K7 |
| `CTRL_MUTANT_LATE_FREEZE` | KEEP | D13 | K5 |

Плюс контрольный прогон «без мутанта, с моделью» (`CTRL_MODEL` без мутанта) — PASS: подмена контроллера сама по
себе ничего не ломает.

### 5.7. Результаты

`results_rtl_dcache.txt`, строка на прогон:
```
RTL CFG=FULL CASE=D8 SEED=1 CTRL=rtl : RESULT: PASS  probes=12 gate-acks=3 lost-dirty=1 foreign=0 sram-in-iso=0 cycles=41234
RTL CFG=KEEP CASE=D13 SEED=2 CTRL=model+CTRL_MUTANT_LATE_FREEZE : RESULT: FAIL ERROR K5 ...
```
итог: `rtl_dcache: runs=N pass=N fail=N mutant-runs=M caught=M`. Прогон: FULL, KEEP, KEEP+ISO2 × D1–D13 × сиды
1–3 + R × сиды 1–10 + мутанты (≈ 7 × 3 × конфигурации).

### 5.8. Ограничения RTL-теста

Нет LSU / sbuffer / предвыборки (MemBlock), load упрощены (один порт, без replay-логики LSU); L2 — модель с одним
клиентом, без CHI и HN; параметры только `XSNoCTopConfig` (WPU выключен — `SramedDataArray` не собирается;
DESIGN 4.3 проверил его зажимы по коду); `isoCycles ≥ 3` в KEEP запрещён `require` — по желанию координатора
отрицательный опыт: модель `cr_ctrl` с `ISO_CYCLES = 3` + KEEP RTL, ожидается assert `LoadPipe.scala:277`
(не входит в `check.sh`).

---

## 6. Тайл: изоляция боковых сигналов и структура (`tile_iso`, `--full`)

### 6.1. Идея

RTL `XSTile` из полной elaboration XSNoCTop (FULL и KEEP) моделируется Verilator-ом с **заглушками** вместо
`XSCore` и `L2Top` (оба не инлайнятся: `XSCore.scala:62`, `L2Top.scala:402`). Заглушка ядра выдаёт мусор на всех
выходах, пока `isolate`; стенд требует, чтобы ни один вход `L2Top` и ни один выход `XSTile` при этом не менялся
(кроме разрешённых). Так таблица 6.2 проверяется целиком, без знания имён каждого сигнала.

### 6.2. Сборка

- `scripts/make_stubs.py <rtl_dir> <cfg>`: из заголовков модулей `XSCore` и `L2Top` (`build/noc_<cfg>/rtl/`)
  генерирует `tb_rtl/gen/stub_XSCore_<cfg>.sv`, `stub_L2Top_<cfg>.sv` (те же имена модулей и порты) и
  `tile_iso_dut_<cfg>.sv` (обёртка XSTile со всеми портами); собирает транзитивное замыкание модулей XSTile без
  поддеревьев XSCore и L2Top.
- Заглушка ядра: TL-выходы вне изоляции — `valid = 0`, `ready = 1`; под изоляцией — случайные; боковые выходы —
  случайные всегда (по имени: `l1_quiesce_done = req` с задержкой, `l1_quiesce_idle = 1`, `l1_quiesce_alive` =
  регистр после её сброса, `resetInFrontend` = её сброс + 4 такта; первые 1–4 такта её сброса — мусор).
- Заглушка L2Top: выходы — константы стенда (Probe нет; `hartIsInReset.toTile = 0`); входы — в монитор.
- Стенд читает `isolate` / `busy` контроллера по XMR (`dut.coreResetCtrl.io_isolate`, имя ищет скрипт).

### 6.3. Проверки (T1–T7)

| T | Проверка |
|---|---|
| T1 | со второго такта `isolate` до его конца: все входы `L2Top` и выходы `XSTile` стабильны; разрешены только `core_in_reset` (и всё, что скрипт найдёт и координатор внесёт в allowlist с ссылкой на DESIGN) |
| T2 | значения зажимов в первом такте `isolate` по таблице 6.2 (по шаблонам имён): `cpu_halt`, `cpu_critical_error`, `msiAck`, `l2_flush_en`, `beu_errors.*.valid`, trace `valid`, `iretire`, `itype`, `robHeadPaddr.valid`, `l2_tlb_req.req.ready`, `.resp.valid` — 0; `resetInFrontend` в L2Top — 1; `l2_pmp_resp` — все 1 |
| T3 | пока `busy`: `addr_valid` моста предвыборки на входе L2Top = 0 и `l2_pf_master_en` = 0 при 1 от ядра |
| T4 | пока `busy`: `l2_tlb_req.req.valid` на входе ядра = 0 |
| T5 | порт сброса заглушки ядра поднимается только после ≥ 1 такта `isolate`; `isolate` падает только после такта `alive && !resetInFrontend`; `core_in_reset` = только sReset; `core_reset_busy` и `hartIsInReset` = `busy` |
| T6 | KEEP: `l1_keep_reset` ядра не поднимается во время последовательности, поднимается при сбросе тайла; FULL: порта нет |
| T7 | каждый вход (`debug_reset`, `hart_reset`, `core_reset_req`) сам запускает последовательность через 3 такта синхронизатора; одновременные — одну |

Мутанты тайла (патч текста сгенерированного `XSTile.sv`, `scripts/tile_mutants.py`; **best effort**: патч
обязан примениться ровно один раз, иначе `SKIPPED` с причиной и запись в отчёт как дыра): TM1 `PF_MASK_LATE`
(убрать `!busy` из `addr_valid`), TM2 `NO_SIDEBAND_ISO` (убрать зажим `cpu_halt`), TM3 `KEEP_RESET_WITH_CORE`
(KEEP: `l1_keep_reset` от сброса ядра). Ловятся T3, T1 / T2, T6.

### 6.4. Структурные проверки elaboration (E1–E3, расширение v5 `noc_one`)

- E1 (FULL, KEEP): порты XSTop `io_debug_reset`, `io_core_reset_req`, `io_core_reset_busy`, `io_core_in_reset`;
  в XSTile — `CoreResetCtrl`, `TLResetIsolation`, 5 `TLQuiesceGate`; в DCache — `DCacheQuiesceUnit`.
- E2: KEEP — `metaArray`, `errorArray`, `tagArray` получают `io_keepReset`, `bankedDataArray` — сброс DCache; FULL —
  порта `keepReset` нет, все массивы на сбросе DCache.
- E3 (`EnableCoreReset = false`): ни одного вхождения `CoreReset|Quiesce|keepReset|core_reset_req|core_in_reset`
  во всём RTL (быстрая проверка до сравнения хешей, раздел 7).

---

## 7. Идентичность RTL при `EnableCoreReset = false`

### 7.1. Нормализация (`scripts/rtl_normalize.py <rtl_dir> > manifest`)

1. Файлы `*.sv`, `*.v`, `*.svh`, `*.conf` (без `*.fir`, `*.anno.json`, `filelist.f`).
2. Удалить все комментарии `//…` и `/*…*/` вне строковых литералов (`make verilog` дописывает в `XSTop.sv`
   `git log -n 1; git diff` комментариями — `Makefile:282–283`; заголовок CIRCT).
3. `([A-Za-z0-9_]+\.scala):\d+(:\d+)?` → `\1:N` (сообщения assert / printf).
4. В `CommitIDModule*.sv` и `PrintCommitIDModule*.sv` — числовые литералы `\d+'h[0-9a-fA-F]+` → `<CONST>`:
   туда зашит SHA коммита и флаг dirty (`CommitIDModule.scala:41–51`, ресурс `gitStatus` из `build.sc:342–358`).
5. Пустые строки и пробелы в конце строк — убрать. Манифест: `sha256  путь` по отсортированным путям + итоговая
   строка `TOTAL <sha256 манифеста> files=N`.

Перед первым использованием — **проверка детерминизма**: две генерации на одном коммите → одинаковые манифесты.
Иначе нормализацию расширить и описать.

### 7.2. Эталон 7b16188 (генерируется один раз)

`scripts/make_ident_ref.sh` (запуск — с разрешения пользователя, вопрос В3):
- `git worktree add <scratch>/ref7b16188 7b16188`; подмодули — симлинки на подмодули основного дерева (между
  7b16188 и v6 они не меняются); пустые файлы `ready-to-run/*-so`; свой `out/` mill.
- Цель `ident_dcache` (`elab/CoreResetIdentElab.scala` — только API upstream, копируется в `src/main/scala/xiangshan/`
  на время прогона и удаляется): `DCacheWrapper` при `XSNoCTopConfig`, тот же `firtoolOpts`, что v5 harness.
- Полный XSNoCTop: `make verilog CONFIG=XSNoCTopConfig` **без** `YAML_CONFIG` (YamlParser 7b16188 не знает новых
  ключей; на v6 без YAML `EnableCoreReset = false` — значение по умолчанию), `JVM_XMX=7G`, при OOM — повтор firtool
  отдельно (рецепт `check.sh` v5).
- Результат — `elab/ident_ref_7b16188.txt`: заголовок (коммит, конфигурация, аргументы, версия firtool, дата),
  `TOTAL` для `xsnoctop` и `dcache`, полный манифест по файлам (для поиска различий). RTL не хранится.
- worktree удаляется только с разрешения пользователя.

### 7.3. Проверки

- **I1** (`--quick`, шаг `ident_modules`): `ident_dcache` на HEAD → манифест → сравнение `TOTAL dcache`. Сигнал
  быстрый; идентичности XSTile / XSTileWrap / XSNoCTop не доказывает (DESIGN 9).
- **I2** (`--full`, внутри `elab_noc`): XSNoCTop без YAML на HEAD → E3 → манифест → сравнение с `TOTAL xsnoctop`;
  при расхождении — список отличающихся файлов (diff манифестов) в `results_elab.txt`. Версия firtool другая —
  `SKIP` с причиной, не PASS.

---

## 8. `check.sh`: состав, время, память, файлы

Ветка в проверке состояния: `origin/core-reset-v6` (в v5 файле — `core-reset-v5`, `check.sh:8, 44–49`).

### 8.1. `--quick` (≈ 25 мин)

| Шаг | Что | Время |
|---|---|---|
| `compile` | `mill xiangshan.compile` | ~5 мин |
| `elab_modules` | один `runMain CoreResetElab`: `ctrl_full, ctrl_keep, ctrl_full_iso2, ctrl_keep_iso2, gates, quiesce, dcache_full, dcache_keep, ident_dcache`; `extract_rtl.py`; `rtl/` = закоммиченному | ~6 мин |
| `ident_modules` | I1 | <1 мин |
| `smoke` | SCEN 1 2 3 5 6 7 8 9, сид 1, FULL и KEEP (16 прогонов; первая сборка по очереди, остальные параллельно) | ~3 мин |
| `formal_quick` | `QUICK=1 run_formal.sh f k` + `adapters` prove | ~1 мин |
| `rtl_dcache_smoke` | FULL: D1–D13, сид 1 (сборка Verilator `build/rtl_FULL`) | ~10 мин |

### 8.2. `--full` (≈ 7–8 ч)

| Шаг | Что | Время | Память / CPU |
|---|---|---|---|
| quick-шаги | | 25 мин | |
| `formal` | `run_formal.sh f` ‖ `run_formal.sh k` (f2 / k2 внутри), затем `adapters` | ~2 ч | 2 CPU, < 2 ГБ |
| `equiv` | `run_equiv.sh`, 8 миттеров | ~10 мин | |
| `rtl_dcache` | KEEP, KEEP+ISO2 сборки по очереди, затем прогоны раздела 5.7 (≤ 3 параллельно, разные конфигурации) | ~45 мин | сборка ≈ 3–5 ГБ (оценка, замерить) |
| `regress` | `regress.sh` + `regress_summary.py` | ~1,5 ч | 1 CPU |
| `soak` | `soak.sh ""` ‖ `soak.sh CFG_KEEP` | ~1,5 ч | 2 CPU |
| `elab_noc` | XSNoCTop: off (I2), full, keep — строго по очереди, E1–E3 | ~1,5 ч | ~9 ГБ пик, **одна** задача на машине |
| `tile_iso` | T1–T7 на full и keep + TM1–TM3 | ~15 мин | |

Правила: `elab_noc` никогда не параллельно с `regress`, `soak`, `rtl_dcache`; одну конфигурацию Verilator не
собирать из двух процессов (сначала все базовые сборки по очереди, потом параллельные прогоны). Опции: v5
(`--skip-elab-noc`, `--write-results`, `--dirty`) + `--skip-rtl` (пропустить `rtl_dcache*`, `tile_iso`).

### 8.3. Файлы результатов (контракт для `doc/results.py`)

| Файл | Формат |
|---|---|
| `results_formal_f.txt`, `results_formal_k.txt` | v5 + строки `isoCycles=2` и `adapters` (раздел 2.4) |
| `results_adapters.txt` | `adapters prove …`, 10 строк мутантов, `adapters: N unexpected result(s)` |
| `results_equiv.txt` | v5, 8 строк, `failed miters: N` |
| `results_regress.txt`, `regress_summary.txt` | v5; конфигурации `FULL`, `CFG_KEEP`, `ISO2`, `CFG_KEEP+ISO2` |
| `results_soak_FULL.log`, `results_soak_CFG_KEEP.log`, `coverage_FULL.json`, `coverage_CFG_KEEP.json` | v5 + ключи раздела 4.6 |
| `results_rtl_dcache.txt` | раздел 5.7 |
| `results_tile_iso.txt` | `TILE CFG=<full|keep> : RESULT: PASS|FAIL <T-нарушения>`; `TILE CFG=… MUTANT=TM1 : CAUGHT|NOT CAUGHT|SKIPPED (<причина>)`; `tile_iso: N unexpected` |
| `results_elab.txt` | **генерирует `check.sh`** (в v5 писался руками): `elab XSNoCTop <off|full|keep>: PASS|FAIL (Chisel m:ss, firtool m:ss, N files)`; `structural <cfg>: OK | <нарушения>`; `identity xsnoctop (EnableCoreReset=false vs 7b16188): IDENTICAL|DIFFERENT|SKIP (N files, total <sha12>) [список]`; `identity dcache (module bench): …` |
| `rare_seeds.txt` | v5 (`<FULL|CFG_KEEP> <MUTANT> scen:seed…`) |

`doc/results.py` обновляет отдельная задача (PDF): конфигурации, ключ prove `(rst, iso)`, новые файлы.

---

## 9. Порядок работы исполнителя

Каждый шаг: исполнитель пишет код и делает **только синтаксическую проверку**; координатор смотрит дифф,
коммитит, пушит; затем тот же исполнитель запускает прогоны. Не коммитить, не пушить, не трогать `src/`, не
собирать `build/obj*` одной конфигурации параллельно.

| Шаг | Что | Синтаксическая проверка | Прогон после push |
|---|---|---|---|
| 1 | `cr_ctl_models.sv`: `cr_ctrl` v6, `cr_gate` (зажим B, `NO_ISO_B`), `cr_quiesce` | `verilator --lint-only` со всеми define мутантов по одному; `yosys -p "read -formal -sv -DFORMAL …"` | — |
| 2 | `fv_boundary.sv` v6, `fv_adapters.sv`, `run_formal.sh` | `yosys read -formal; prep -top …` для f, k, f2, k2, adapters; `bash -n` | `QUICK=1 run_formal.sh f k`, `adapters`; затем полный `f k` — разбор |
| 3 | `cr_dcache.sv`, `cr_env_models.sv` (`cr_l2` FULL), `cr_tb.sv`, `cr_monitors.sv`: S1–S23, SCEN 8, 9, SCEN 6 сл. 6–8, SCEN 5 C13–C15 | `verilator --lint-only` FULL, KEEP, ISO2 | smoke обе конфигурации; разбор |
| 4 | `run.sh`, `regress.sh`, `soak.sh`, `seedsearch.sh`, `coverage.py`, `regress_summary.py`, yml-переименование | `bash -n`, `python3 -m py_compile` | `seedsearch.sh` → коммит `rare_seeds.txt` → `regress` → `soak` |
| 5 | (после коммита Chisel v6) `CoreResetElabHarness.scala` (цели раздела 3.1), `extract_rtl.py`, `eq_chisel.sv` (+ `eq_quiesce`, ISO, CBO), `run_equiv.sh` | `mill xiangshan.compile` с harness в `src/` (потом убрать); `yosys read` миттеров | elaboration, коммит `rtl/`, `run_equiv.sh` |
| 6 | RTL-тест: `CoreResetDCacheHarness`, `tb_rtl/*`, `mem_probes.py`, `run_rtl_dcache.sh` | elaboration `dcache_full/keep`; `verilator --lint-only` стенда | D1–D13 FULL сид 1, затем всё раздела 5.7 |
| 7 | идентичность: `CoreResetIdentElab.scala`, `rtl_normalize.py`, `make_ident_ref.sh` | `py_compile`, `bash -n`; проверка детерминизма на `ident_dcache` | (с разрешения) эталон 7b16188 → коммит `ident_ref_7b16188.txt` |
| 8 | `tile_iso`: `make_stubs.py`, `tb_rtl/tile_iso_tb.sv`, `run_tile_iso.sh`, `tile_mutants.py` | на RTL первой `elab_noc` | T1–T7, TM1–TM3 |
| 9 | `check.sh` (шаги раздела 8, ветка v6, `results_elab.txt`) | `bash -n`; `check.sh --quick --dirty` на машине без изменений `src/` | `check.sh --quick`, затем `--full --write-results` |
| 10 | первый полный прогон → координатор заполняет раздел 12, пользователь утверждает эталоны | — | — |

Шаги 1–4 не зависят от Chisel v6 и могут идти параллельно его реализации; 5–9 — после.

---

## 10. Риски

| Риск | Что делать |
|---|---|
| Отдельная elaboration `DCacheWrapper` падает на недостающих ключах Parameters (DPI Constantin / ChiselDB, `DebugOptionsKey`, `PerfCounterOptionsKey`, MBIST) | ArgParser как `make verilog`, `Constantin.init(false)`, `ChiselDB.init(false)`, `--dfx false`; MBIST выключен; при нужде — `alter` по ключу из сообщения |
| Verilator-сборка DCache долгая / тяжёлая; `ClockGate` (inline, защёлка); макросы firtool для assert | замерить в шаге 6; `-Wno-LATCH`; макросы `STOP_COND_`, `ASSERT_VERBOSE_COND_` по умолчанию |
| Имена экземпляров памяти после firtool меняются | зонды K5 генерируются скриптом из RTL; 0 найденных → FAIL |
| Недетерминизм firtool / встроенные данные сборки | проверка детерминизма 7.1; нормализация описывается в PDF |
| Эталон 7b16188: worktree, симлинки подмодулей, отдельный `out/` (~2 ГБ, ~30 мин, 9 ГБ ОЗУ) | только с разрешения пользователя (вопрос В3); один раз |
| pdr с sIso и ISO = 2 сходится дольше v5 (v5: 88 / 113 с для RST100) | `PROVE_TIMEOUT`; при TIMEOUT — сообщить, не ослаблять свойства |
| Слишком широкая среда A5 (свобода в sIso) даёт ложные контрпримеры | разбирать трассу; сужать только с обоснованием по коду DCache, записать в таблицу допущений |
| Модель FULL с устаревшей директорией прячет настоящие ошибки | `stale` / `golden_valid` только для строк, бывших в L1D в точке сброса; все остальные проверки строгие; счётчики `full.*` в отчёте |
| Патчи RTL тайла (TM1–TM3) не находят шаблон | `SKIPPED` с причиной, дыра в отчёте; не переписывать проверку под патч |
| KEEP: логика ядра читает массивы в sRelease (зажим → неожиданный ответ) | RTL-тест видит только DCache; при срабатывании assert — находка для координатора |
| Сиды редких мутантов | `seedsearch.sh` до регрессии; список в результатах и PDF |

---

## 11. Вопросы пользователю

- **В1.** `GATE_MUTANT_NO_ISO_B` запускать только в `fv_adapters` (там он обязан падать), в `fv_boundary` не
  запускать и в замороженный список эквивалентных не добавлять? (По умолчанию — да.)
- **В2.** RTL-тест DCache в `--quick` (FULL, D1–D13, сид 1) удлиняет `--quick` с ~10 до ~25 мин. Оставить или
  перенести целиком в `--full`?
- **В3.** Эталон 7b16188: создать git worktree во временном каталоге (симлинки подмодулей, свой `out/` ~2 ГБ),
  один прогон ~30 мин / 9 ГБ; затем удалить worktree. Разрешить?
- **В4.** Мутанты тайла как текстовые патчи сгенерированного `XSTile.sv` (best effort, `SKIPPED` при несовпадении
  шаблона) — приемлемо?
- **В5.** CBO в моделях: в формальной части — включаем (дёшево); в `cr_dcache` — по возможности (SCEN 5 C14),
  без него CBO проверяется только RTL-тестом (D6). Согласны?

---

## 12. Эталоны (заполняет координатор после первого полного прогона; утверждает пользователь)

Замораживаются: формальная часть — PASS всех prove (время — справочно), список достигнутых covers, для каждого
мутанта FAIL + метка свойства (такт — для bmc-мутантов), EQUIV PASS; эквивалентность — 8/8; регрессия — числа
прогонов и PASS / caught по конфигурациям; soak — `pass` по конфигурациям и минимумы покрытия (каждый случай SCEN
6, каждый триггер SCEN 5, `b2b.direct`, `req_drop.*`, `iso.loads_clamped` > 0; `iso.sram-access-in-iso` = 0 в
KEEP); RTL-тест — runs / pass / caught; тайл — T1–T7 PASS, TM CAUGHT; идентичность — IDENTICAL и `TOTAL`
эталона; elaboration — число файлов. Расхождение с эталоном описывается, эталон не подгоняется.

| Величина | FULL | KEEP | Дата / коммит |
|---|---|---|---|
| prove RST100 / RST16 / iso2 | | | |
| covers достигнуто | | | |
| мутанты formal: всего / FAIL | | | |
| adapters: prove / мутанты FAIL | | | |
| equiv | | | |
| regress design / PASS | | | |
| regress мутанты / caught; EQUIV / PASS | | | |
| soak pass | | | |
| rtl_dcache runs / pass / caught | | | |
| tile_iso | | | |
| identity xsnoctop / dcache | | | |
