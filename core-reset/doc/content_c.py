"""Sections 5 and 6: fragments of the patch with explanations (v6)."""
from reportlab.platypus import PageBreak, Spacer

from pdflib import H, P, bullets, table, box, cap, patch_frag
import diagrams

DC = 'src/main/scala/xiangshan/cache/dcache/'
MP = DC + 'mainpipe/'
X = 'src/main/scala/xiangshan/'


def fr(path, start, end=None, n=None, cb=0, title=None):
    out = []
    if title:
        out.append(P(title, 'small'))
    out.append(patch_frag(path, start, end, n, cb))
    out.append(Spacer(1, 4))
    return out


def section5(C):
    s = [PageBreak(), H(1, '5. DCache без обхода')]
    s.append(P('Файлы в `src/main/scala/xiangshan/cache/dcache/`. Фрагменты взяты из патча как есть (`git diff 7b16188 HEAD -- src/`). '
               'В v6 из DCache исчез весь обход v5: состояния sSweep и sWait, регистры `set` / `way` / `inflight`, порты `pipe_req` / '
               '`pipe_resp`, в MainPipe — поле `MainPipeReq.flush`, порты `flush_req` / `flush_resp`, пятый вход арбитра, '
               '`flush_need_data`, `s1_flush*`, `flush_update_meta`, `flush_wb`, `s3_flush_can_go`. От MainPipe осталось одно поле '
               '`busy`. Правки WritebackQueue, MissQueue и Probe — только флаги пустоты. Остаются и одинаковы в FULL и KEEP: '
               '`DCacheQuiesceUnit`, флаги, блокировки; различие режимов — в `DCacheImp` (5.3).'))
    s.append(H(2, '5.1. mainpipe/QuiesceUnit.scala — интерфейс и автомат опустошения (новый файл)'))
    s.append(diagrams.fsm_quiesce())
    s.append(cap('Рис. 8. `DCacheQuiesceUnit`: три состояния. `block` = (state ≠ sIdle); `done` = sDone; `idle` — четыре флага в текущем такте.'))
    s += fr(MP + 'QuiesceUnit.scala', 'class L1QuiesceIO', 'val alive  = Input', title='Интерфейс контроллер ↔ DCache:')
    s += fr(MP + 'QuiesceUnit.scala', 'val sIdle :: sDrain :: sDone', 'io.quiesce.alive := alive', title='Автомат и выходы:')
    s.append(table([
        ['Сигнал', 'Смысл'],
        ['`req` (контроллер → DCache)', 'уровень: опустошить DCache и держать заблокированной (нет store, atomic, CMO, новых промахов)'],
        ['`freeze` (контроллер → DCache)', 'KEEP: XSCore изолирован, к массивам, переживающим сброс, обращений нет (в FULL всегда 0)'],
        ['`done` (DCache → контроллер)', 'опустошена; держится, пока `req` = 1; контроллер смотрит `done && !isolate`'],
        ['`idle` (DCache → контроллер)', 'четыре флага пустоты в текущем такте; после `done` занятой DCache может сделать только Probe (B открыт до sDrain)'],
        ['`alive` (DCache → контроллер)', 'регистр домена ядра: 0 в сбросе, 1 с первого такта после него; контроллер смотрит `alive` только в sRelease'],
    ], [1.6, 4.2]))
    s.append(Spacer(1, 4))
    s += box('Почему так: done и idle', [
        '`done` фиксирует, что опустошение закончилось, и держится до снятия `req`: блокировка не должна «отпустить» DCache между решением и '
        'сбросом. `idle` — тот же набор флагов в текущем такте, нужный потому, что после `done` Probe (B ещё открыт) может занять ProbeQueue или '
        'MainPipe; контроллер в такте решения требует и `done`, и `idle`, и `quiet` гейта (он покрывает ProbeAck в `l1d_to_l2_buffer`). '
        'Автомат не знает про FULL и KEEP: опустошение нужно в обоих режимах ради протокола (4.2).',
    ])
    s.append(H(2, '5.2. Флаги пустоты: MissQueue, WritebackQueue, ProbeQueue, MainPipe'))
    s.append(table([
        ['Флаг', 'Выражение', 'Что покрывает'],
        ['`mq_empty`', '`!entries.busy.orR && !miss_req_pipe_reg.reg_valid() && cmo_unit.io.req.ready`; `MissEntry.busy := req_valid`', 'все записи промахов (Acquire до GrantAck), запрос в регистре приёма, CMO в работе'],
        ['`wbq_empty`', '`!entries.block_addr.valid.orR`', 'каждый Release получил ReleaseAck; ProbeAck отправлены'],
        ['`mp_empty`', '`!(s1_valid | s2_valid | s3_valid)` (`MainPipe.io.busy`)', 'ни одного запроса в конвейере'],
        ['`pq_empty`', '`!entries.block_addr.valid.orR && !selected_req_valid`', 'ProbeQueue и регистр выбора перед MainPipe'],
    ], [0.7, 2.7, 2.4]))
    s += fr(MP + 'MissQueue.scala', 'this entry holds a miss', n=3, title='MissQueue.scala:')
    s += fr(MP + 'MissQueue.scala', 'no miss entry in use', n=2)
    s += fr(MP + 'MissQueue.scala', 'io.empty.foreach', n=1)
    s += fr(MP + 'WritebackQueue.scala', 'no Release / ProbeAck in progress', n=2, title='WritebackQueue.scala:')
    s += fr(MP + 'WritebackQueue.scala', 'io.empty.foreach', n=1)
    s += fr(MP + 'Probe.scala', 'no Probe in an entry', n=2, title='Probe.scala:')
    s += fr(MP + 'Probe.scala', 'io.empty.foreach', n=1)
    s += fr(MP + 'MainPipe.scala', 'a request (of any kind)', n=2, title='MainPipe.scala:')
    s += fr(MP + 'MainPipe.scala', 'io.busy.foreach', n=1)
    s += box('Почему так: флаги, а не ожидание 16 тактов; pq_empty избыточен, но оставлен', [
        'Ожидание 16 тактов без новых транзакций (v4) — не доказательство, что очередь пуста: Acquire, ждущий Grant, живёт сотни тактов. Флаги '
        'точны: запись MissQueue занята до GrantAck, запись WritebackQueue — до ReleaseAck. Мутанты `NO_MP_WAIT`, `NO_WBQ_WAIT`, `NO_MQ_WAIT`, '
        '`NO_BLOCK` убирают слагаемое или блокировку и ловятся (7.4).',
        '`QUIESCE_MUTANT_NO_PQ_WAIT` не вводится: `pq_empty` избыточен при `quiet` гейта (Probe в буфере B и в ProbeQueue уже посчитан '
        'счётчиком `probes` до своего ProbeAck), мутант был бы эквивалентен. Анализ, не эксперимент.',
        '<b>Новая логика в DCache.</b> Любая новая очередь или конвейер, способные держать транзакцию, требуют своего флага в `DCacheQuiesceUnit`.',
    ])
    s.append(H(2, '5.3. DCacheWrapper.scala — подключение, блокировки, KEEP: массивы на сбросе тайла и freeze'))
    s += fr(DC + 'DCacheWrapper.scala', 'reset of XSCore alone (see xiangshan/CoreReset.scala)', n=5, title='Параметры, общие для всех модулей DCache (`HasDCacheParameters`):')
    s += fr(DC + 'DCacheWrapper.scala', 'drain before a reset of XSCore alone', n=4, title='Порты `DCacheIO`: `quiesce` — при `EnableCoreReset`, `keepReset` — только в KEEP:')
    s += fr(DC + 'DCacheWrapper.scala', 'val quiesceUnit', 'u.io.pq_empty', title='Автомат и подключение флагов в `DCacheImp`:')
    s += fr(DC + 'DCacheWrapper.scala', 'a WFI request holds unsent Acquires', n=2, title='WFI: без маски неотправленные Acquire остаются в MissQueue, и опустошение не кончится:')
    s += fr(DC + 'DCacheWrapper.scala', 'drain: no new miss', 'io.cmoOpReq.ready := false.B', title='Блокировка новых промахов и CMO:')
    s += fr(DC + 'DCacheWrapper.scala', 'drain: stores wait', 'io.lsu.store.req.ready := false.B', title='Блокировка store; atomics — аналогично:')
    s.append(P('<b>KEEP: массивы на сбросе тайла и freeze.</b> Всё в `DCacheImp` и только при `io.keepReset.isDefined`. Сигнал `keepReset` строится в XSTile '
               'отдельным `ResetGen` от базового сброса тайла (без `coreReset`). Блок стоит после всех `<>`-соединений этих портов '
               '(иначе их перекроют: last connect wins).'))
    s += fr(DC + 'DCacheWrapper.scala', 'io.keepReset.foreach { r =>', 'L1D array write while XSCore is isolated', title='KEEP:')
    s.append(table([
        ['Зажим при `freeze`', 'Что даёт'],
        ['запись meta / error / tag', 'вход ступени записи (`s0_way_wen`; `wen` SRAM тегов) не зависит от логики ядра'],
        ['запись данных (`write.valid`, `write_dup.valid`)', 'зажат вход ступени; сами триггеры ступени (`wen_reg`, `write_valid_dup_reg`) остаются в домене ядра — равны 0 с такта решения и весь sIso, '
         'асинхронный сброс их значения не меняет, WE SRAM статичен. Исключение R6 (а)'],
        ['чтение SRAM тегов и данных (`read.valid`, `readline.valid`)', 'SRAM однопортовые, CE = `ren | wen`; чтение формируют LoadPipe, которые работают до сброса. При асинхронной установке сброса `ren` и адрес '
         'меняются в произвольный момент: для SRAM, содержимое которой должно пережить сброс, это нарушение setup / hold на CE (допущение о библиотеке памяти). Зажим держит CE = 0 за `isoCycles` тактов до сброса'],
        ['`read.valid` meta / error', 'регистры ответа без сброса внутри модулей на сбросе тайла (`RegEnable(…, read.valid)`) не захватывают индекс из логики ядра: путей без квалификатора в модули на сбросе тайла не остаётся'],
    ], [1.8, 4.0]))
    s.append(Spacer(1, 4))
    s += box('Почему так: bankedDataArray остаётся на сбросе ядра', [
        'Решение пользователя 16.11.2026 (ревью дизайна, находка 3). Перенос модуля данных на сброс тайла функционально не обязателен — SRAM сброса '
        'не имеет и данные хранит сама — и создал бы пересечения `rst_core → rst_tile` без квалификатора (регистры адресов чтения и конфликтов банков, '
        'MBIST-цепочка). Защиту содержимого даёт зажим разрешений на границе модуля.',
        '`SramedDataArray` (ветка WPU, `enWPU = false` по умолчанию) проверен по коду: разрешения чтения и записи строятся из тех же `io.read(i).valid`, '
        '`io.readline.valid`, `io.write.valid`; зажимы на границе действуют так же. В RTL-тесте он не собирается.',
        '<b>Ограничение `isoCycles ≤ 2` для KEEP.</b> В sIso чтение SRAM зажато, а LoadPipe ещё работают: запрос s0 остаётся без ответа, s1 сравнивает теги по '
        'выходу SRAM, который модель не обязана держать. При `isoCycles` = 1 и 2 такой s1 либо уже в сбросе, либо его assert (`LoadPipe.scala:277`) оценивается '
        'в сбросе; при ≥ 3 сработал бы в живом ядре. Наружу результаты таких load не выходят в любом случае (A закрыт, выходы ядра изолированы). Поэтому `require`.',
    ])
    s += fr(DC + 'DCacheWrapper.scala', 'no voluntary Release may start', n=4, title='Второй assert (после `done` не начинается Release):')
    s.append(H(2, '5.4. FakeDCache.scala — заглушка'))
    s += fr(X + 'cache/dcache/FakeDCache.scala', 'io.quiesce.foreach', n=7)
    s.append(P('Без DCache опустошать нечего: `done := req`, `idle := 1`, `alive` — регистр, как в настоящей. Допущение A10 формальной модели учитывает '
               'эту разницу: `done` у `DCacheQuiesceUnit` держится ещё такт после падения `req`, у заглушки — нет.', 'small'))
    return s


def section6(C):
    s = [PageBreak(), H(1, '6. Ядро, тайл и верхний уровень')]
    s.append(H(2, '6.1. xiangshan/CoreReset.scala — TLQuiesceGate и TLResetIsolation'))
    s.append(P('Новый файл, лицензия Mulan PSL v2. `class TLQuiesceGate(val gateName: String, val early: Boolean)` — поле называется `gateName`, не `name` '
               '(в v4 имя конфликтовало с `LazyModule.name`; `require(!(early && hasBCE))`: ранний гейт только на TL-UL ребре).'))
    s += fr(X + 'CoreReset.scala', 'class QuiesceGateIO', 'val quiet   = Output(Bool())', title='Интерфейс гейта:')
    s.append(table([
        ['Вход', 'Действие'],
        ['`block`', 'A закрыт, но только на границе сообщения (`io.block && aFirst`): начатый Put доводится'],
        ['`holdB`', 'Probe ждёт в L2: `b.ready` к L2 и `b.valid` к ядру падают в том же такте (снятие `valid` непринятого beat-а законно [@4.1]); L2 продолжает предлагать'],
        ['`ackB`', 'FULL: гейт принимает Probe и отвечает `ProbeAck NtoN` (`source`, `address`, `size` — из Probe, `corrupt` = 0); один Probe за раз; регистры `ackPending`, `ackProbe`'],
        ['`isolate`', 'регистр контроллера: C, E valid и B ready ядра не смотрятся, ядру ничего не предлагается (A, D тоже)'],
        ['`quiet`', 'через ребро ничего не идёт и не ожидается: счётчики `reqs`, `grants`, `probes`, `releases` равны 0, нет сообщения на середине'],
    ], [0.8, 5.0]))
    s += fr(X + 'CoreReset.scala', 'isolation of B, C and E, from a register', 'out.b.ready := false.B', title='Зажим B по регистру `isolate` (новое в v6):')
    s += fr(X + 'CoreReset.scala', 'holdB: a Probe waits in L2', 'ackPending := false.B', title='`holdB`, `ackB`, ответ гейта:')
    s += box('Почему так: зажим B первым и порядок when', [
        'В v5 при изоляции B закрывали только `holdB` и `ackB` — декоды `state`. Теперь первым стоит зажим от регистра `isolate`: он безусловный. '
        'Порядок `when` существен (последнее присваивание побеждает): `out.b.ready` при `isolate` не зависит от `in.b.ready` ни в одной ветви — либо 0, либо `takeB` '
        '(регистры гейта). Формальная проверка локальности — `fv_adapters` (7.2).',
        '`ackPending` может пережить конец последовательности (L2 долго не берёт C): B и C ядра закрыты, пока ответ не ушёл; в счётчики `quiet` он не входит — это сообщение гейта, а не ядра.',
        '`assert(!(ackB && holdB))` и `assert(!isolate | holdB | ackB)`: B не бывает открыт при изоляции.',
    ])
    s.append(table([
        ['Что гейт делает с Probe', 'sQuiesce', 'sDrain, sIso', 'sReset, sRelease', 'после'],
        ['FULL', 'проходит к DCache', 'держится в L2 (`holdB`)', 'гейт принимает и отвечает NtoN (`ackB`), по одному', 'проходит к пустой DCache → NtoN'],
        ['KEEP', 'проходит к DCache', 'держится (`holdB`)', 'держится (`holdB`)', 'проходит к DCache с сохранёнными строками'],
    ], [0.6, 1.0, 1.2, 2.0, 1.4]))
    s.append(Spacer(1, 4))
    s += fr(X + 'CoreReset.scala', 'class TLResetIsolation', 'lazy val module = new TLResetIsolationImp', title='`TLResetIsolation` — адаптер на ребре icachectrl (ядро — менеджер):')
    s.append(H(2, '6.2. xiangshan/CoreReset.scala — CoreResetCtrl'))
    s += fr(X + 'CoreReset.scala', 'class CoreResetCtrl(keepL1', 'val coreUp = releasing', title='Параметры, регистры, квалификаторы:')
    s += fr(X + 'CoreReset.scala', 'switch (state) {', 'is (sRelease) {', title='Переходы (комментарии файла опущены не были):')
    s += fr(X + 'CoreReset.scala', 'the registers follow the state', 'isolation dropped outside sRelease', title='Assert-ы (в симуляции; в формальных свойствах — P16, P21, P22):')
    s += fr(X + 'CoreReset.scala', 'io.busy := busy', 'io.coreReset := coreReset', title='Выходы:')
    s.append(P('`require(rstCycles >= 100 && rstCycles < 255)`, `require(isoCycles >= 1 && isoCycles <= 16)`, `require(!keepL1 | isoCycles <= 2)`. '
               '`rstCycles` и `isoCycles` в `SoCParameters` и YAML не выносятся (решение 16.11.2026).', 'small'))
    s.append(H(2, '6.3. mem/MemBlock.scala, xiangshan/XSCore.scala — проброс до DCache'))
    s += fr(X + 'mem/MemBlock.scala', 'val l1_quiesce', n=3, title='MemBlock.scala:')
    s += fr(X + 'mem/MemBlock.scala', 'dcache.io.quiesce.foreach', n=2)
    s += fr(X + 'XSCore.scala', 'val l1_quiesce', n=3, title='XSCore.scala:')
    s.append(P('Дерево сброса MemBlock не менялось: `dcache` остаётся в `rightResetTree`, а три массива (meta, error, tag) получают `keepReset` уже внутри `DCacheImp`.', 'small'))
    s.append(H(2, '6.4. xiangshan/XSTile.scala — гейты, порты, контроллер, сбросы'))
    s += fr(X + 'XSTile.scala', 'val coreGates =', 'private def coreIsolation', title='Гейты на рёбрах (diplomacy без `TLTempNode`: `if / else`, ветвь `else` — строка upstream дословно):')
    s += fr(X + 'XSTile.scala', 'if (EnableCoreReset) {', 'memBlock.l1d_to_l2_buffer.node := memBlock.dcache.clientNode', n=12, cb=0)
    s.append(P('Так же по одному `if / else`: `l1i` (ранний), `ptw` (ранний), `i_mmio` (ранний), `d_mmio` (ранний), `TLResetIsolation` на `icachectrl`; мосты '
               'предвыборки L1 → L2 и L1 → L3 разрезаны на `BundleBridgeSink` + `BundleBridgeSource`, чтобы изолировать их в XSTileImp.'))
    s.append(table([
        ['Порт `XSTileImp.io`', 'Напр.', 'Смысл'],
        ['`debug_reset`', 'вход', 'уровень, асинхронный, с выхода триггера: `ndmreset` Debug Module'],
        ['`hart_reset`', 'вход', 'уровень, асинхронный: `hartreset` этого харта (в v5 складывался с `debug_reset` до синхронизатора)'],
        ['`core_reset_req`', 'вход', 'уровень, асинхронный: контроллер сброса кластера'],
        ['`core_reset_busy`', 'выход', 'домен такта тайла: последовательность идёт (регистр `busy`)'],
        ['`core_in_reset`', 'выход', 'домен такта тайла: сброс XSCore установлен (регистр `coreReset`, только sReset)'],
    ], [1.3, 0.6, 3.9]))
    s.append(Spacer(1, 4))
    s += fr(X + 'XSTile.scala', 'val coreResetCtrl = Option.when', 'ctl.io.coreInReset :=', title='Контроллер: синхронизатор на источник, гейты, тишина:')
    s += fr(X + 'XSTile.scala', 'XSCore reset = tile reset', 'ResetGen(io.dft_reset)', n=14, title='Сброс ядра и сброс массивов KEEP:')
    s += box('Почему так: синхронизатор на источник и два ResetGen', [
        '`ndmreset`, `hartreset` и запрос кластера асинхронны к такту тайла; ИЛИ до синхронизатора давал бы иголку на асинхронном входе, а запрос не отменяется — '
        'иголка запускала бы полный сброс. Поэтому у каждого источника свой синхронизатор, ИЛИ — после.',
        '`core.module.reset` = `ResetGen(coreBaseReset || coreReset)`; `keepReset` = `ResetGen(coreBaseReset)` без `coreReset` — те же три триггера, массивы KEEP выходят из '
        'сброса тайла вместе с ядром, но сброс ядра их не трогает. OR на пути сброса безвреден: в работе `coreReset` меняется, только когда `coreBaseReset` = 0, а при '
        'установке сброса тайла `ResetGen` снимает сброс только после трёх фронтов.',
    ])
    s.append(H(2, '6.5. Изоляция боковых сигналов ядра (таблица)'))
    s.append(P('Все зажимы — в `XSTileImp`, все — от регистра `isolate`: с первого такта sIso (за `isoCycles` тактов до сброса) и до первого такта после sRelease. '
               '`isoReset(x, r) = Mux(iso, r, x)`; `isoHold(x) = Mux(iso, RegEnable(x, !iso), x)`. Новое в v6 помечено.'))
    s.append(table([
        ['Сигнал ядра', 'Потребитель в домене тайла', 'Зажим'],
        ['`cpu_halt`, `cpu_critical_error`', 'L2Top `RegNext` → порт; `l2.io_cpu_halt`; `isWFI` XSNoCTop', '`isoReset(_, 0)`'],
        ['`msiAck`, `teemsiAck`', 'IMSIC, четырёхфазное рукопожатие', '`isoReset(_, 0)`; hold дал бы зависание моста'],
        ['`resetInFrontend`', 'L2Top `hartIsInReset`; контроллер `coreInReset`', 'в L2Top `isoReset(_, 1)`; в контроллере квалификатор `releasing`'],
        ['trace: `groups(i).valid`', 'L2Top `RegNext`, `RegEnable`', '`isoReset(_, 0)`'],
        ['trace: `bits.iretire`, `bits.itype` <i>(v6)</i>', 'L2Top `RegNext` без valid', '`isoReset(_, 0)`'],
        ['trace: `iaddr`, `ilastsize`, `priv`, `trap`', 'L2Top `RegEnable` по valid', 'не нужен (enable зажат)'],
        ['trace: `mstatus`', 'L2Top `RegNext`', '`isoHold`'],
        ['`beu_errors.{icache,dcache,uncache}.ecc_error.valid`', 'BusErrorUnit', '`isoReset(_, 0)`'],
        ['`l2_flush_en`', 'L2, порт тайла', '`isoReset(_, 0)`'],
        ['`power_down_en`', 'в XSTile не подключён', '—'],
        ['`l2PfCtrl`', 'префетчер L2', '`isoHold`; `l2_pf_master_en` = 0 при `busy` <i>(v6)</i>'],
        ['мост L1 → L2 `PrefetchRecv.addr_valid` <i>(v6)</i>', 'префетчер L2', '`isoReset(_, 0) && !busy` (маска с первого такта)'],
        ['мост `PrefetchRecv.l2_pf_en` <i>(v6)</i>', 'в CoupledL2 55d8e69 не используется', '`isoHold`'],
        ['мост L1 → L3 `huancun.PrefetchRecv`', 'L3 (если есть)', 'как L1 → L2'],
        ['`l2_tlb_req.req.ready`, `.resp.valid`', 'префетчер L2 (ядро — ответчик)', '`isoReset(_, 0)`; `ready` ещё `&& !busy`'],
        ['`l2_pmp_resp` <i>(v6)</i>', 'префетчер L2, на такт позже `resp.valid`', '`isoReset(_, все поля 1)`: ответ последнего такта sDrain в sIso отбрасывается как исключение'],
        ['`debugTopDown.robHeadPaddr.valid`, `robTrueCommit`', 'L2 TopDown, порт тайла', '`isoReset(_, 0)`; `isoHold`'],
        ['`l1_quiesce.done`, `.idle`, `.alive`', '`CoreResetCtrl`', '`&& !isolate`; `&& releasing` (в контроллере)'],
    ], [1.9, 1.9, 2.0]))
    s.append(P('Функциональная маска, не изоляция: `core.module.io.l2_tlb_req.req.valid := false.B` при `busy`. Входы ядра (прерывания, `msiInfo`, `clintTime`, '
               '`reset_vector`, `l2_hint`, `perfEvents`, DFT) изоляции не требуют: приёмник в сбросе, а при снятии сброса сигналы синхронны. Пересечения через BoringUtils / ChiselDB / DiffTest / XSPerf — '
               'только симуляция, не изолируются.', 'small'))
    s.append(H(2, '6.6. Правила RDC (для инструмента)'))
    s.append(table([
        ['Правило', 'Содержание'],
        ['R1', 'Любой путь из триггера `rst_core` в триггер или память `rst_tile` (или без сброса, но в логике тайла) проходит через вентиль с квалификатором `isolate` (в KEEP для массивов — `freeze`, тот же регистр)'],
        ['R2', 'Квалификаторы — регистры `rst_tile`: `isolate`, `releasing`. Декод `state` квалификатором не служит'],
        ['R3. Опережение', '`isolate` = 1 не меньше `isoCycles` ≥ 1 полных тактов до фронта `coreReset` (assert контроллера, формальное свойство P21)'],
        ['R4. Снятие', '`isolate` падает не раньше чем через полный такт после того, как `alive` = 1 и `resetInFrontend` = 0 (P22)'],
        ['R5. KEEP, память', 'модули meta / error / tag — на `rst_tile`; `bankedDataArray` — на `rst_core`. Все входы разрешения зажаты `freeze` на границе модулей; адрес и данные квалифицированы разрешением'],
        ['R6. Оставшиеся исключения', '(а) WE SRAM данных: `wen_reg` — функция триггеров ядра, квалификатор до триггера; значение 0 с такта решения, асинхронный сброс его не меняет. (б) Адрес и данные SRAM комбинационно от триггеров ядра, CE / WE = 0. '
         '(в) Выходы массивов идут в логику ядра, которая в сбросе. (г) Регистры MBIST-цепочки массива тегов — на `rst_tile`, входы — DFT-сигналы; MBIST только при общем сбросе. (д) В FULL R5 не применяется. '
         '(е) OR на пути сброса `coreBaseReset || coreReset` безвреден (см. выше)'],
    ], [1.0, 4.8]))
    s.append(Spacer(1, 4))
    s.append(diagrams.iso_timing())
    s.append(cap('Рис. 9. Изоляция относительно сброса ядра: `isolate` и `freeze` стоят до `coreReset` и после его снятия; в sReset ≥ 100 тактов и до снятия запроса. Рис. 5 — тот же момент крупно.'))
    s.append(H(2, '6.7. XSTileWrap, XSNoCTop, Top'))
    s += fr(X + 'XSTileWrap.scala', 'val reset_sync = if (EnableCoreReset)', n=3, title='XSTileWrap.scala: с `EnableCoreReset` `hartResetReq` сбрасывает только XSCore:')
    s += fr('src/main/scala/top/XSNoCTop.scala', 'val coreResetWake', 'WfiStateNext(wfiState, isWFI, isNormal', title='XSNoCTop.scala: запрос будит остановленный такт Core + L2:')
    s += fr('src/main/scala/top/Top.scala', 'core.module.io.debug_reset', n=4, title='Top.scala: XSTop создаёт XSTile напрямую — входы запроса привязаны к нулю:')
    s.append(P('`hartreset` Debug Module в XSTop по-прежнему сбрасывает весь тайл (upstream): сброс только ядра в XSTop не выведен, целевой верх — XSNoCTop / XSTileWrap.', 'small'))
    s.append(H(2, '6.8. system/SoC.scala, top/YamlParser.scala — параметры'))
    s += fr('src/main/scala/system/SoC.scala', 'Reset of XSCore (core + L1) alone', n=9)
    s.append(P('`HasSoCParameter`: `val EnableCoreReset = soc.EnableCoreReset`, `val CoreResetKeepL1 = soc.CoreResetKeepL1`. В YAML — ключи `EnableCoreReset`, `CoreResetKeepL1` '
               '(по образцу `EnablePowerDown`). По умолчанию `EnableCoreReset = false`, `CoreResetKeepL1 = false` (в v5 было `true`).', 'small'))
    return s
