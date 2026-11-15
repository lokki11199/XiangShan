"""Sections 5 and 6: fragments of the patch with explanations."""
from reportlab.platypus import PageBreak, Spacer

from pdflib import H, P, bullets, table, box, cap, patch_frag

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
    s = [PageBreak(), H(1, '5. Изменения в DCache')]
    s.append(P('Файлы в каталоге `src/main/scala/xiangshan/cache/dcache/`. Все фрагменты взяты из патча как есть '
               '(`git diff 7b16188 HEAD -- src/`); зелёным — добавленные строки, красным — удалённые, серым — контекст; '
               'в левой колонке — номер строки в новом файле. Автомат генерируется всегда, но неактивен, пока '
               '`quiesce.req = 0`; без `EnableCoreReset` XSTile подаёт на него константу 0, и синтез убирает автомат. Обход '
               'генерируется только в режиме SWEEP: иначе вход flush MainPipe получает константу 0.'))
    # 5.1
    s.append(H(2, '5.1. mainpipe/FlushUnit.scala — интерфейс, автомат и обход (новый файл)'))
    s.append(P('Интерфейс контроллер ↔ DCache и автомат. Заголовочный комментарий файла описывает флаги пустоты и последовательность; '
               'ниже — код.'))
    s += fr(MP + 'FlushUnit.scala', 'class L1QuiesceIO', 'val alive  = Input(Bool())', title='L1QuiesceIO: пять сигналов')
    s += bullets([
        '`req` — уровень от контроллера: опустошать (и обойти) L1D и держать её заблокированной; `freeze` — сброс ядра установлен или '
        'снимается: массивы, переживающие сброс, не писать (только KEEP, иначе 0); `done` — нет промахов, Release и записей в '
        'полёте (и L1D пуста при обходе); `idle` — флаги пустоты всех очередей и MainPipe сейчас; `alive` — управляющая логика '
        'DCache вышла из сброса.',
    ])
    s += fr(MP + 'FlushUnit.scala', 'val sIdle :: sDrain :: sSweep :: sWait :: sDone', 'is (sDone)', n=60,
            title='DCacheFlushUnit: флаги пустоты, автомат, обход')
    s += bullets([
        '`idle` = `mq_empty && wbq_empty && mp_empty && pq_empty`: точное состояние всей управляющей логики. В sDrain автомат ждёт '
        '`idle` (запись, принятая перед блокировкой, ещё в MainPipe — `mp_empty`; промах или Release держат свои очереди '
        'до Grant / ReleaseAck). Счётчика тихих тактов нет.',
        'В sSweep на каждый принятый MainPipe запрос flush счётчики (`set`, `way`) идут way-major: соседние запросы — в разные '
        'наборы. sWait ждёт `inflight === 0 && idle`: последний запрос flush покинул MainPipe, каждый Release получил ReleaseAck.',
        '`alive` — регистр, который сбрасывается вместе с DCache: 0 в сбросе, 1 с первого такта после. Контроллер ждёт его в sRelease.',
        'В KEEP состояния sSweep и sWait недостижимы (assert); запросы flush не выдаются (`io.pipe_req.valid` — константа 0).',
    ])
    s += fr(MP + 'FlushUnit.scala', 'val r = io.pipe_req.bits', 'r.flush := true.B', title='Запрос flush: поля MainPipeReq')
    s.append(P('Запрос flush помечен `r.flush`, адрес набора идёт через `vaddr`, путь — one-hot в `replace_way_en`; адрес строки '
               'MainPipe берёт сам из тега, который читает на s1. Остальные поля — нейтральные (не store, не AMO, не Probe, не '
               'промах).'))
    s.append(diag_flush())
    # 5.2
    s.append(H(2, '5.2. mainpipe/MissQueue.scala — признак «MissQueue пуста»'))
    s += fr(MP + 'MissQueue.scala', 'this entry holds a miss', n=2, cb=1, title='MissEntry: запись занята')
    s += fr(MP + 'MissQueue.scala', 'io.busy := req_valid', n=1, cb=0)
    s += fr(MP + 'MissQueue.scala', 'no miss entry in use, nothing in the enqueue pipeline register', n=2, cb=1,
            title='MissQueue.empty: порт и выражение')
    s += fr(MP + 'MissQueue.scala', 'io.empty := !Cat(entries.map', n=1)
    s.append(P('`empty` выражает три места, где может находиться промах: запись (`busy` = `req_valid`), регистр приёма '
               '`miss_req_pipe_reg` (запрос, разрешённый в этом такте и ещё не занявший запись, — раньше это окно закрывали '
               '16 тактами) и CMO-блок (`cmo_unit.io.req.ready`: ready = нет CMO в процессе).'))
    # 5.3
    s.append(H(2, '5.3. mainpipe/WritebackQueue.scala — признак «WBQ пуста»'))
    s += fr(MP + 'WritebackQueue.scala', 'no Release / ProbeAck in progress', n=2, cb=1)
    s += fr(MP + 'WritebackQueue.scala', 'io.empty := !Cat', n=1)
    s.append(P('Запись WBQ занята (`state =/= s_invalid`) от приёма Release / ProbeAck до его завершения: Release — до ReleaseAck, '
               'ProbeAck — до отправки последнего beat. Пуста — значит все Release подтверждены, а все ProbeAck ушли.'))
    # 5.4
    s.append(H(2, '5.4. mainpipe/Probe.scala — признак «ProbeQueue пуста» (новый изменённый файл)'))
    s += fr(MP + 'Probe.scala', 'no Probe in an entry or in the register', n=2, cb=1)
    s += fr(MP + 'Probe.scala', 'io.empty := !Cat', n=1, cb=3)
    s.append(P('Probe находится либо в одной из записей (`block_addr.valid`), либо в регистре выбора `selected_req_valid` перед '
               'MainPipe, куда его кладёт арбитр. Без этого флага Probe, ещё не вошедший в MainPipe, остался бы невидимым '
               'для `mp_empty` и для `done`.'))
    # 5.5
    s.append(H(2, '5.5. mainpipe/MainPipe.scala — запрос flush (обход) и признак busy'))
    s.append(P('Обход идёт тем же путём, что вытеснение при промахе: MainPipe читает тег и состояние указанного пути, и если строка '
               'действительна, отправляет её в WritebackQueue и в том же такте пишет в `metaArray` состояние N.'))
    s += fr(MP + 'MainPipe.scala', 'flush: voluntarily release the line', n=2, cb=1, title='Поле запроса')
    s += fr(MP + 'MainPipe.scala', 'L1 flush-all sweep (DCacheFlushUnit)', n=7, title='Порты flush_req, flush_resp, busy')
    s += fr(MP + 'MainPipe.scala', 'only the flush port may carry a flush request', 'flush_req_in // lowest', title='Арбитр: flush — самый низкий приоритет')
    s += bullets([
        'У четырёх других источников (Probe, refill, store, atomic) поле `flush` принудительно 0 (`withFlush`), чтобы мусорное '
        'значение DontCare не превратило их в flush.',
    ])
    s += fr(MP + 'MainPipe.scala', 'dirtiness is only known in s1', n=3, title='s0: flush всегда читает всю строку')
    s += fr(MP + 'MainPipe.scala', 'flush: the way is given by the request', 'val s1_tag = Mux(s1_flush', title='s1: тег и состояние пути берутся из пути запроса')
    s += fr(MP + 'MainPipe.scala', 'val s2_can_go_to_s3 =', n=1, title='s2: flush идёт в s3, как replace')
    s += fr(MP + 'MainPipe.scala', 'flush of a valid line: invalidate it', 'flush_update_meta) &&', title='s3: инвалидация строки')
    s += fr(MP + 'MainPipe.scala', 'val flush_wb =', n=1, title='s3: Release / ReleaseData строки')
    s += fr(MP + 'MainPipe.scala', 'flush: an invalid way finishes at once', 's3_flush_can_go', title='s3: когда flush уходит из s3')
    s += fr(MP + 'MainPipe.scala', 'io.flush_resp := s3_fire', n=2, title='flush_resp и busy')
    s += fr(MP + 'MainPipe.scala', 'flush: the line is invalidated in the same cycle', n=2, title='Запись в WritebackQueue')
    s += bullets([
        'Недействительный путь (`state === Nothing`) завершается в s3 сразу: Release не создаётся, `meta_write` не нужен.',
        'Действительный путь: `flush_wb` включает запись в WBQ, `voluntary` = 1 (Release, а не ProbeAck), `hasData` — для '
        'грязной строки (в `alwaysReleaseData` — для любой действительной); параметр `miss_shrink_param` — TtoN / BtoN из '
        'состояния строки. Одновременно `meta_write` пишет N (`new_coh` проваливается в `ClientMetadata.onReset`).',
        '`flush_resp` — импульс на выходе s3 запроса flush: по нему `inflight` во FlushUnit уменьшается.',
        '`busy` = s1_valid || s2_valid || s3_valid: флаг пустоты MainPipe `mp_empty` — отрицание этого выхода. Он нужен не обходу, а '
        'любой причине, по которой в конвейере может оказаться запрос (запись, принятая перед блокировкой, Probe).',
        'Тот же проход по MainPipe используется во всех режимах как защита: запись в массивы данных и meta из s3 после блокировки '
        'исключена флагами пустоты, остальное — assert-ы в DCacheWrapper.',
    ])
    # 5.6
    s.append(H(2, '5.6. DCacheWrapper.scala — подключение, флаги, теги на сбросе тайла, блокировки'))
    s += fr(DC + 'DCacheWrapper.scala', 'drain before a reset of XSCore alone', n=6, title='Порты DCacheIO: quiesce и metaReset')
    s += fr(DC + 'DCacheWrapper.scala', 'CoreResetKeepL1 = false: before the core reset the flush unit', n=5,
            title='Экземпляр DCacheFlushUnit (sweep = EnableCoreReset && !CoreResetKeepL1)')
    s += fr(DC + 'DCacheWrapper.scala', 'A WFI request holds unsent Acquires', 'flushUnit.io.pipe_resp', title='Маска WFI, флаги пустоты, обход через MainPipe')
    s += bullets([
        '`mp_empty` = `!mainPipe.io.busy`, `pq_empty` = `probeQueue.io.empty`, `mq_empty` = `missQueue.io.empty`, `wbq_empty` = '
        '`wb.io.empty`. Это единственные связи флагов; больше в контроллере ничего не ждёт «16 тактов».',
        'WFI-удержание промахов снимается, пока автомат активен: иначе промах, придержанный в MissQueue по `wfiReq`, никогда бы не ушёл '
        'и очередь не опустела бы; ROB при этом остаётся в WFI.',
    ])
    s += fr(DC + 'DCacheWrapper.scala', 'Reset of XSCore alone that keeps L1D', 'tagArray.reset := r',
            title='KEEP: массивы на сбросе тайла — теги, meta, error')
    s.append(P('`io.metaReset` — асинхронный сброс тайла (порт `l1_meta_reset`, формируется в XSTile тем же `ResetGen`, что и сброс '
               'ядра, но без `coreReset`). Три строки присваивания — самое важное: `metaArray`, `errorArray` и (исправление, найденное '
               'ревью) `tagArray` переводятся с сброса ядра на сброс тайла. Без `tagArray.reset := r` счётчик `rst_cnt` обёртки '
               '`TagSRAMBank` стирал бы теги при каждом сбросе ядра.'))
    s += fr(DC + 'DCacheWrapper.scala', 'when (io.quiesce.freeze) {', n=4, title='freeze: запись в meta')
    s += fr(DC + 'DCacheWrapper.scala', 'tagArray.io.write.valid := false.B', n=3, cb=6,
            title='freeze: запись в теги и данные')
    s += fr(DC + 'DCacheWrapper.scala', 'flush: no new miss (load/store/prefetch/AMO) and no CMO', 'io.cmoOpReq.ready := false.B',
            title='Блокировки: новые промахи и CMO')
    s += fr(DC + 'DCacheWrapper.scala', 'flush: stores wait in the sbuffer', 'io.lsu.store.req.ready := false.B',
            title='Блокировка записей из sbuffer')
    s += fr(DC + 'DCacheWrapper.scala', 'flush: atomics (AMO, LR/SC) wait as well', 'io.lsu.atomics.req.ready := false.B',
            title='Блокировка атомиков')
    s += fr(DC + 'DCacheWrapper.scala', 'core-only reset with CoreResetKeepL1: freeze masks the writes', 'DCache: Release started after the drain reported done',
            title='Две проверки (assert)')
    s += bullets([
        'Первая проверка: пока `freeze`, ни арбитр записи тегов, ни арбитр записи данных не должны даже пытаться писать: опустошение '
        'гарантирует, что MainPipe пуст. Вторая: после `done` DCache не начинает добровольных Release.',
        'Блокировки гарантируют, что после `block` ничто новое не войдёт: загрузки-попадания читают как раньше, а всё, что пишет, '
        'меняет meta или отправляет Release, — ждёт в sbuffer / LSU, откуда переигрывается после сброса.',
    ])
    # 5.7
    s.append(H(2, '5.7. FakeDCache.scala — заглушка'))
    s += fr(DC + 'FakeDCache.scala', 'no cache, nothing to drain or flush', n=7)
    s.append(P('Для конфигурации без DCache (`FakeDCache`) нечего опустошать: `done` = `req`, `idle` = 1, `alive` — регистр, поднятый '
               'на первом такте. Контроллер не ждёт напрасно.'))
    return s


def diag_flush():
    import diagrams
    return diagrams.fsm_flush()


def section6(C):
    s = [PageBreak(), H(1, '6. Изменения в ядре, тайле и верхнем уровне')]
    CR = X + 'CoreReset.scala'
    # 6.1
    s.append(H(2, '6.1. xiangshan/CoreReset.scala — TLQuiesceGate (новый файл)'))
    s.append(P('Гейт — TileLink-адаптер на ребре ядро → L2Top. Он пропускает сообщения как есть, кроме случаев, когда закрыт канал A '
               '(`block`), Probe держится (`holdB`) или отвечается самим гейтом (`ackB`), либо ядро изолировано (`isolate`); он '
               'считает транзакции, пересекающие его, и сообщает `quiet`. Вместе с `CoreResetCtrl` и опустошением DCache это '
               'адаптер [TL 1.8.1 3.2.3, с. 14].'))
    s += fr(CR, 'class QuiesceGateIO extends Bundle', 'val quiet   = Output(Bool())', title='QuiesceGateIO: четыре входа и выход quiet')
    s += bullets([
        '`quiet` = ничего не открыто через границу и нет сообщения на середине; Probe, предложенный L2, но не принятый, в `quiet` '
        'не входит — он держится или отвечается гейтом. Поля `idle` с `b.valid` (v4) больше нет.',
    ])
    s += fr(CR, 'class TLQuiesceGate(val gateName: String, val early: Boolean)', 'lazy val module', title='Класс гейта: gateName, early')
    s += fr(CR, 'private val gname = outer.gateName', 'require(!(outer.early && hasBCE))', n=8, title='Реализация: gname и require')
    s.append(P('<b>`gateName` вместо `name`</b>: `LazyModule` уже имеет член `name`, поэтому поле v4 `val name` не компилировалось. '
               '<b>`early`</b> — гейт некогерентного агента (TL-UL), его канал A закрыт с начала последовательности (`earlyBlock`); '
               'иначе — с sDrain (`gateBlock`). <b>`require`</b> запрещает ранний гейт на ребре TL-C: когерентный запрос нельзя '
               'остановить в начале, DCache ещё делает Release и отвечает на Probe.'))
    s += fr(CR, '// holdB: a Probe waits in L2', 'assert(!(io.ackB && io.holdB)', title='Каналы B и C: holdB и ackB')
    s += bullets([
        '`holdB`: `in.b.valid` и `out.b.ready` падают в том же такте, где поднимается `holdB`: непринятый beat можно снять '
        '[TL 1.8.1 4.1, с. 19]; L2 продолжает предлагать Probe (SourceB). Probe — однобитное сообщение.',
        '`ackB`: гейт принимает один Probe за раз (`ackPending`), запоминает его (`ackProbe`) и отвечает `edgeOut.ProbeAck(…, NtoN)`: '
        'source, адрес и размер копируются из Probe, как требует [TL 1.9.3 9.3.5, с. 78]. C ядра в это время закрыт '
        '(`in.c.ready := false`).',
        'assert-ы: Probe не держится и не отвечается одновременно; пока `isolate`, канал B закрыт.',
    ])
    s += fr(CR, '// isolation of C and E', 'out.e.valid := false.B', n=9, title='Изоляция C и E')
    s += fr(CR, 'message boundaries (each firstlast call', 'in.d.valid := false.B', title='Блокировка A на границе сообщения и изоляция A, D')
    s += fr(CR, 'def counter(inc: Bool', 'io.quiet := quiets.reduce', title='Счётчики и quiet')
    s += bullets([
        'Блокировка A — только при `aFirst` (на границе сообщения): многобитное Put не обрывается (формальное свойство P4).',
        '`quiet = reqs === 0 && aFirst && dFirst && (grants === 0 && probes === 0 && releases === 0 && cFirst)` для TL-C; для TL-UL — '
        'без блока BCE. Счётчики считают сообщения там, где они пересекают гейт: сообщение, ещё лежащее в `l1d_to_l2_buffer`, '
        'тоже учтено — поэтому нужен `quiet` гейта, а не только флаг DCache.',
    ])
    # 6.2
    s.append(H(2, '6.2. xiangshan/CoreReset.scala — TLResetIsolation (новое)'))
    s.append(P('Адаптер на ребре, где менеджер находится внутри ядра (регистры ICache ctrl, путь: MMIO ядра → гейт → буфер MMIO-'
               'крестовины L2Top → `TLResetIsolation` → ядро). Пока ядро в сбросе или выходит из него, ему ничего не предлагается и '
               'ни один его сигнал (`A ready`, `D valid`) не доходит до тайла. Достижимы здесь только собственные обращения ядра '
               'к этим регистрам, которые уже проходят гейты `i_mmio` / `d_mmio`; `quiet` сообщает контроллеру то же, что гейт.'))
    s += fr(CR, 'class TLResetIsolationImp', 'io.quiet := quiets.foldLeft', title='TLResetIsolation: изоляция A, D и счётчик запросов')
    s += bullets([
        'Выход `quiet` переименован из `idle` (v4). Assert `!(isolate && reqs =/= 0)` проверяет, что к сбросу ничего не висит.',
        'Мутант `ISO_MUTANT_ALWAYS_QUIET` (quiet всегда 1) эквивалентен: запрос к этим регистрам уже учтён гейтом клиента (7.2).',
    ])
    # 6.3
    s.append(H(2, '6.3. xiangshan/CoreReset.scala — CoreResetCtrl'))
    s += fr(CR, 'class CoreResetCtrlIO extends Bundle', 'val coreReset   = Output(Bool())', title='Интерфейс контроллера')
    s += fr(CR, 'class CoreResetCtrl(keepL1: Boolean, rstCycles: Int = 100)', 'val closed = RegInit(false.B)',
            title='Контроллер: параметры, регистры')
    s += fr(CR, 'the inputs from the DCache and the frontend come from the core reset domain', 'val coreUp =',
            title='Входы из домена сброса ядра: маскирование регистром closed')
    s += fr(CR, 'switch (state) {', 'assert(!coreReset || closed', title='Автомат и assert-ы')
    s += fr(CR, 'io.busy := state =/= sIdle', 'io.coreReset := coreReset', title='Выходы — функции регистров')
    s += bullets([
        '`l1Done`, `l1Idle` маскируются `!closed`: они приходят из домена сброса ядра и в sReset (когда сброс установлен '
        'асинхронно) могли бы быть произвольными; `coreUp` (`alive && !coreInReset && sRelease`) смотрится только в sRelease, когда '
        'снятие синхронно.',
        '`sFlush → sDrain` — `l1Done && earlyQuiet`; `sDrain → sReset` — `gatesQuiet && l1Done && l1Idle` в том же такте (с '
        '`coreReset := 1`, `hartInReset := 1`, `closed := 1`); `sReset → sRelease` — `cnt >= rstCycles && !req`; `sRelease → '
        'sIdle` — `coreUp`.',
        'Комментарий в sDrain фиксирует инвариант нулевого запаса (1.5.3): между решением и `coreReset` ничего добавлять нельзя.',
        '`require(rstCycles >= 100 && rstCycles < 255)`: счётчик 8-битный; 100 — правило TileLink 3.2.2.',
        'Assert-ы: `gatesQuiet` в sReset; `closed ≡ sReset || sRelease`; `coreReset ⇒ closed`. Их проверяют симуляция и формально '
        '(P1, P16).',
    ])
    # 6.4
    s.append(H(2, '6.4. mem/MemBlock.scala, xiangshan/XSCore.scala — проброс до DCache'))
    s += fr(X + 'XSCore.scala', 'L1 DCache quiesce before a reset of XSCore alone', 'l1_meta_reset', n=5, title='XSCore: порты')
    s += fr(X + 'XSCore.scala', 'memBlock.io.l1_quiesce <> io.l1_quiesce', n=2, title='XSCore: соединение с MemBlock')
    s += fr(X + 'mem/MemBlock.scala', 'dcache.io.quiesce <> io.l1_quiesce', n=2, title='MemBlock → DCache')
    s.append(P('Два порта прокладываются без изменений логики: `l1_quiesce` (L1QuiesceIO, с `Flipped`) и `l1_meta_reset` (асинхронный '
               'сброс тайла, существует только при `EnableCoreReset && CoreResetKeepL1`).'))
    # 6.5
    s.append(H(2, '6.5. xiangshan/XSTile.scala — гейты, изоляция, контроллер, сбросы'))
    XT = X + 'XSTile.scala'
    s += fr(XT, 'One TLQuiesceGate on every TileLink edge from XSCore to L2Top', 'TLTempNode()', n=1, title='coreGate: гейт на каждое ребро')
    s += fr(XT, 'L1 to l1_xbar', 'ptw_to_l2_buffer.node', n=12, title='Вставка гейтов в рёбра (l1d — early = false, остальные — true)')
    s += fr(XT, 'core-only reset sequencer (tile clock', 'core.module.io.l1_quiesce.freeze := false.B', title='Контроллер и связи с гейтами')
    s.append(P('Для каждого гейта: `block` = `earlyBlock` (если `g.early`) или `gateBlock`; `holdB` = `holdProbe`, `ackB` = `ackProbe`, '
               '`isolate` = `isolate`. `earlyQuiet` — И `quiet` ранних гейтов, `gatesQuiet` — всех гейтов и `TLResetIsolation`. '
               '`coreInReset` = `resetInFrontend` ядра: последний в цепочке ResetGen (MemBlock → Backend → Frontend), он маскируется '
               'структурно, как `l1.*`.'))
    s += fr(XT, 'isolation of the outputs of XSCore (EnableCoreReset)', 'def isoHold', title='isoReset и isoHold')
    s += fr(XT, 'status levels, 0 in reset', 'io.hartIsInReset :=', title='Изоляция выходов: состояние, MSI, hartIsInReset')
    s += fr(XT, 'XSCore reset = tile reset (via the L2Top reset chain', 'core.module.reset := l2top.module.reset_core', title='Сбросы ядра и массивов L1D')
    s += bullets([
        'Сброс ядра = (сброс тайла через цепочку L2Top, если есть) ИЛИ `coreReset`, асинхронная установка, синхронное снятие (`ResetGen`). '
        'Сброс массивов L1D (`l1_meta_reset`) — только сброс тайла, тот же синхронизатор.',
        'Мосты предвыборки разрезаны на приёмник и источник (`BundleBridgeSink` / `BundleBridgeSource`) ради изоляции `addr_valid`.',
        'Запросы L2-предвыборщика к TLB ядра (`l2_tlb_req.req.valid`) закрыты, пока `busy`; ответы изолируются.',
    ])
    # 6.6
    s.append(H(2, '6.6. xiangshan/XSTileWrap.scala, top/XSNoCTop.scala, top/Top.scala'))
    s += fr(X + 'XSTileWrap.scala', 'reset of XSCore (core + L1) alone, L2 and CHI keep running', 'val core_reset_busy', title='XSTileWrap: порты')
    s += fr(X + 'XSTileWrap.scala', 'hartResetReq resets the whole tile, or only XSCore', 'val reset_sync', title='hartResetReq больше не сбрасывает тайл')
    s += fr(X + 'XSTileWrap.scala', 'core-only reset requests: synchronised in XSTile', 'io.core_reset_busy.foreach', title='Запросы')
    s += fr('src/main/scala/top/XSNoCTop.scala', 'A core-only reset needs the Core+L2 clock', 'WfiStateNext(wfiState, isWFI && !coreResetWake',
            title='XSNoCTop: пробуждение такта')
    s += fr('src/main/scala/top/XSNoCTop.scala', 'reset of XSCore alone, L2 and CHI keep running', 'val core_reset_busy', title='XSNoCTop: порты')
    s += fr('src/main/scala/top/Top.scala', 'core.module.io.debug_reset.foreach', n=2, title='XSTop: заглушки')
    s.append(P('Порты тайла и XSNoCTop не изменились относительно v4. В XSNoCTop запрос или `core_reset_busy` будят отключённый в WFI '
               'такт и не дают его отключить, пока последовательность не закончилась.'))
    # 6.7
    s.append(H(2, '6.7. system/SoC.scala, top/YamlParser.scala — параметры'))
    s += fr('src/main/scala/system/SoC.scala', 'Reset of XSCore (core + L1) only', 'CoreResetKeepL1: Boolean = true', title='SoCParameters')
    s += fr('src/main/scala/top/YamlParser.scala', 'EnableCoreReset: Option[Boolean]', 'CoreResetKeepL1: Option[Boolean]', title='YamlConfig')
    s.append(P('`CoreResetLevel` удалён из `SoCParameters` и `YamlConfig` (комментарий влит в описание `CoreResetKeepL1`). YAML-ключ '
               '`CoreResetLevel` в старых конфигурациях игнорируется (circe `withDefaults`): старые YAML не ломаются.'))
    return s
