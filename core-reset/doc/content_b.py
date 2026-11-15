"""Sections 2, 3 and 4."""
from reportlab.platypus import PageBreak, Spacer

from pdflib import H, P, bullets, numbered, table, box, cap
import diagrams

FILES = {
    'src/main/scala/xiangshan/CoreReset.scala': ('новый: `TLQuiesceGate` (ранний / обычный, ответчик на Probe, изоляция), '
                                                 '`TLResetIsolation`, `CoreResetCtrl(keepL1, rstCycles = 100)`', '6.1–6.3'),
    'src/main/scala/xiangshan/cache/dcache/mainpipe/FlushUnit.scala': ('новый: `L1QuiesceIO` (`req`, `freeze`, `done`, '
                                                                       '`idle`, `alive`), `DCacheFlushUnit` (опустошение '
                                                                       'по флагам, обход)', '5.1'),
    'src/main/scala/xiangshan/cache/dcache/mainpipe/MissQueue.scala': ('`MissEntry.busy`, `MissQueue.empty` '
                                                                       '(с регистром приёма и CMO)', '5.2'),
    'src/main/scala/xiangshan/cache/dcache/mainpipe/WritebackQueue.scala': ('`WritebackQueue.empty`', '5.3'),
    'src/main/scala/xiangshan/cache/dcache/mainpipe/Probe.scala': ('новый в патче: `ProbeQueue.empty` (записи и '
                                                                   'регистр выбора)', '5.4'),
    'src/main/scala/xiangshan/cache/dcache/mainpipe/MainPipe.scala': ('запрос flush (обход): порт, арбитр, тег и состояние '
                                                                      'пути, Release и инвалидация в s3; `busy` = s1..s3', '5.5'),
    'src/main/scala/xiangshan/cache/dcache/DCacheWrapper.scala': ('порты `quiesce`, `metaReset`; флаги пустоты; '
                                                                  '`tagArray`, `metaArray`, `errorArray` на сбросе тайла; '
                                                                  'маски записи `freeze`; блокировки; маска WFI; две проверки', '5.6'),
    'src/main/scala/xiangshan/cache/dcache/FakeDCache.scala': ('заглушка: `quiesce.done`, `idle`, `alive`', '5.7'),
    'src/main/scala/xiangshan/mem/MemBlock.scala': ('проброс `l1_quiesce`, `l1_meta_reset` до DCache', '6.4'),
    'src/main/scala/xiangshan/XSCore.scala': ('проброс `l1_quiesce`, `l1_meta_reset`', '6.4'),
    'src/main/scala/xiangshan/XSTile.scala': ('порты, синхронизаторы, гейты на 5 рёбрах и `TLResetIsolation`, контроллер, '
                                              'изоляция всех выходов ядра, `hartIsInReset`, сбросы ядра и массивов L1D', '6.5'),
    'src/main/scala/xiangshan/XSTileWrap.scala': ('порты, `hartResetReq` → `debug_reset`', '6.6'),
    'src/main/scala/top/XSNoCTop.scala': ('внешние порты, пробуждение такта на время последовательности', '6.6'),
    'src/main/scala/top/Top.scala': ('заглушки портов в XSTop', '6.6'),
    'src/main/scala/system/SoC.scala': ('параметры `EnableCoreReset`, `CoreResetKeepL1`', '6.7'),
    'src/main/scala/top/YamlParser.scala': ('ключи YAML `EnableCoreReset`, `CoreResetKeepL1`', '6.7'),
}


def section2(C):
    s = [PageBreak(), H(1, '2. Понятия и модули')]
    s.append(H(2, '2.1. TileLink между ядром и L2'))
    s.append(P('TileLink — протокол шины из rocket-chip. Связь «клиент → менеджер» (здесь: кэш L1 → L2) состоит из пяти '
               'независимых каналов, у каждого свой valid/ready. TL-UL — только A и D (простые чтения и записи); TL-C — '
               'все пять, с кэшируемыми копиями и правами N (нет), B (чтение), T (запись). Приоритет каналов: '
               '«A &lt; B &lt; C &lt; D &lt; E» [TL 1.8.1 2.2, с. 12], и ответ всегда идёт по каналу с более высоким '
               'приоритетом, чем запрос [TL 1.8.1 5.1, с. 30]: ответ на Probe (C) не может ждать канала A.'))
    s.append(table([
        ['Канал', 'Направление', 'Сообщения, которые встречаются здесь'],
        ['A', 'ядро → L2', 'Get, PutFullData (ICache, PTW, MMIO); AcquireBlock / AcquirePerm (промах DCache); '
         'CBOClean / CBOFlush / CBOInval (cbo.*)'],
        ['B', 'L2 → DCache', 'Probe (toN — отдать строку, toB — понизить до чтения)'],
        ['C', 'DCache → L2', 'ProbeAck / ProbeAckData (ответ на Probe, отчёт TtoN, BtoN, TtoB, NtoN ...); Release / '
         'ReleaseData (добровольное вытеснение)'],
        ['D', 'L2 → ядро', 'AccessAck / AccessAckData, Grant / GrantData, ReleaseAck, CBOAck'],
        ['E', 'DCache → L2', 'GrantAck (подтверждение Grant)'],
    ], [0.6, 1.1, 4.0]))
    s.append(Spacer(1, 4))
    s.append(P('Транзакция завершена, только когда прошли все её сообщения: запрос требует ответа, Grant — одновременно '
               'ответ и запрос [TL 1.8.1 5.1, с. 29]. Гейт считает именно эти пары (счётчики внутри `quiet`):'))
    s.append(table([
        ['Пара', 'Что значит незавершённость', 'Счётчик гейта'],
        ['запрос A → ответ D', 'менеджер (L2, MMIO-мост) обрабатывает запрос, ответ придёт в ядро', '`reqs`'],
        ['Grant → GrantAck', 'MSHR L2 ждёт подтверждения; до GrantAck L2 не шлёт Probe по этой строке [TL 1.8.1 9.2, с. 68]',
         '`grants`'],
        ['Probe → ProbeAck', 'MSHR L2 ждёт ответа L1, чтобы ответить на снуп HN или вытеснить строку [TL 1.8.1 9.2, с. 67]',
         '`probes`'],
        ['Release → ReleaseAck', 'L2 записывает данные и директорию; до ReleaseAck DCache не отвечает на Probe к этой строке и '
         'не шлёт по ней Acquire [TL 1.8.1 9.2, с. 69]', '`releases`'],
    ], [1.2, 3.8, 0.9]))
    s.append(Spacer(1, 4))
    s.append(P('<b>Отчёт NtoN.</b> ProbeAck несёт параметр из категорий Shrink или Report [TL 1.8.1 9.3.5, табл. 36, с. 76]: '
               'Shrink — права уменьшились (TtoB, TtoN, BtoN), Report — не изменились, ответ лишь сообщает текущие (TtoT, '
               'BtoB, NtoN) [TL 1.8.1 9.1.4, табл. 31, с. 65–66]. NtoN значит «прав нет». Probe с уровнем выше, чем права '
               'клиента, законен и прав не меняет [TL 1.8.1 9.3.3, с. 74], поэтому клиент без копии на любой Probe '
               'отвечает NtoN. NtoN от клиента, которого директория ещё числит владельцем, бывает и в обычной работе — в '
               'гонке Release и Probe [TL 1.8.1 9.2, с. 69] (ProbeAck NtoN законен). Этим ответом пользуется гейт в режиме '
               'SWEEP. В Release и ReleaseData NtoN запрещён [TL 1.9.3 9.3.10, с. 81], [TL 1.9.3 9.3.11, с. 82], в '
               'ProbeAckData — тоже [TL 1.9.3 9.3.6, с. 79].'))
    s.append(P('<b>Многотактные сообщения.</b> Сообщения с данными строки (GrantData, ProbeAckData, ReleaseData, AccessAckData) '
               'идут двумя beat по 32 Б; на MMIO-рёбрах шина 8 Б. Beat-ы разных сообщений в канале не перемежаются '
               '[TL 1.8.1 4, с. 18], [TL 1.8.1 4.2, с. 21]. `edge.firstlast(канал)` из rocket-chip даёт `first` и `last`.'))
    s.append(P('<b>Удержание канала.</b> Пока `ready` = 0, beat не принят: «If ready is LOW, the receiver must not process the '
               'beat and the sender must not consider the beat processed.» [TL 1.8.1 4.1, с. 18]. Получатель может держать '
               'так beat долго, но не бесконечно: предложенный beat должен когда-нибудь быть принят [TL 1.8.1 5, с. 28]. '
               'Так ждёт Probe с KEEP, пока ядро в сбросе. Отправитель же может снять `valid` непринятого beat-а: «a sender may '
               'raise valid and then lower it on the following cycle, even if the message was not accepted on the previous '
               'cycle.» [TL 1.8.1 4.1, с. 19] — так гейт закрывает канал A и снимает Probe к ядру (`holdB`).'))
    s.append(P('Пункты спецификации TileLink 1.8.1, на которые ссылается документ (цитаты дословные); пункты 1.9.3 — в 1.3.2:'))
    s.append(table([
        ['Пункт', 'Текст спецификации', 'Где'],
        ['[TL 1.8.1 2.2, с. 12] приоритет каналов', '«The prioritization of messages across channels is A &lt; B &lt; C &lt; D '
         '&lt; E, in order of increasing priority.»', '2.1'],
        ['[TL 1.8.1 3.2.2, с. 14] сброс', '«Before deasserting reset, a_valid, c_valid, and e_valid must be driven LOW by the '
         'master, while b_valid and d_valid must be driven LOW by the slave.» «The valid signals must be driven LOW for at '
         'least 100 cycles while reset is asserted.» «Ready, control, and data signals are free to take any value during '
         'reset.»', '1.6, 4.4'],
        ['[TL 1.8.1 3.2.3, с. 14] пересечение доменов', '«a TileLink-to-TileLink adapter is needed which acts as a slave in one '
         'domain and a master in the other domain.» «It is highly recommended that a crossing carefully coordinates with the '
         'rest of the SoC to ensure that there are no unanswered TileLink requests when one half of the crossing is reset or '
         'depowered.»', '1, 4.3, 6.1'],
        ['[TL 1.8.1 4, с. 18] управление потоком', '«It is forbidden in TileLink to interleave the beats of different messages '
         'on a channel.»', '1, 2.1'],
        ['[TL 1.8.1 4.1, с. 18–19] ready / valid', '«If ready is LOW, the receiver must not process the beat and the sender must '
         'not consider the beat processed.» «Note that a sender may raise valid and then lower it on the following cycle, even '
         'if the message was not accepted on the previous cycle.»', '1.5, 4.4, 6.1'],
        ['[TL 1.8.1 5, с. 28] свобода от взаимных блокировок', 'правило 2: «Agents must eventually present all beats of a '
         'received message»; правило 3: «Unless they have a higher priority message in flight or unanswered» — 3.i «Agents '
         'must eventually accept a presented beat», 3.ii «Agents must eventually answer a received request message»',
         '1.4, 4.4'],
        ['[TL 1.8.1 5.1, с. 29–30] термины', '«A request message requires a response message.» «Notice that Grants are both '
         'request and response messages.»', '1, 2.1'],
        ['[TL 1.8.1 6.4, с. 43] идентификаторы', '«Each outstanding request identifier of a channel in a particular link must be '
         'unique»', '1, 4.2, 4.3'],
        ['[TL 1.8.1 9.2, с. 67–69] транзакции TL-C', '«The slave waits to receive a ProbeAck for every Probe that was sent.» '
         '«Once the Grant is issued, the slave should not issue Probes on that block until it receives a GrantAck.» '
         '«Masters must continue to process and respond to Probes even with an outstanding Grant pending in the network.» '
         '«The slave must accept the voluntary Release as well as any overtaken ProbeAcks»', '1.3, 2.1, 6.1'],
        ['[TL 1.8.1 9.3.3, с. 74] Probe', '«Probing Master Agents to cap their permissions at a more permissive level than they '
         'currently have is allowed, and does not result in a permissions change.»', '2.1'],
        ['[TL 1.8.1 9.3.5, табл. 36, с. 76] ProbeAck', '«A ProbeAck message is a response message used by a Master Agent to '
         'acknowledge the receipt of a Probe.» c_param: «Shrink or Report (TtoB, TtoN, BtoN, TtoT, BtoB, NtoN).»',
         '1.3, 6.1'],
        ['[TL 1.8.1 9.3.9, с. 79] GrantAck', '«The GrantAck response message is used by the Master Agent to provide a final '
         'acknowledgment of transaction completion»', '4.2'],
    ], [1.5, 3.6, 0.7]))
    s.append(P('<b>Diplomacy.</b> Механизм rocket-chip, которым соединяются TileLink-узлы: `a := b` создаёт ребро, параметры '
               'согласуются автоматически. `TLAdapterNode` — узел-адаптер, вставляемый в ребро; на нём построены гейт и '
               '`TLResetIsolation`. `TLTempNode` — пустой узел-заглушка, который diplomacy убирает (без `EnableCoreReset` '
               'рёбра соединяются как в upstream).'))
    s.append(H(2, '2.2. Debug Module и его сбросы'))
    s.append(table([
        ['Понятие', 'Что это'],
        ['Debug Module (DM)', 'блок отладки RISC-V (спецификация RISC-V Debug): управляется отладчиком через JTAG (DTM), умеет '
         'останавливать харты, выполнять абстрактные команды, читать и писать память'],
        ['`dmcontrol.ndmreset`', 'сброс всего, кроме DM: отладчик пишет 1, затем 0. Что именно сбрасывается, решает платформа; '
         'здесь — XSCore каждого тайла (L2 и CHI работают)'],
        ['`dmcontrol.hartreset`', 'сброс выбранных хартов, по той же схеме 1 → 0'],
        ['`hartIsInReset`', 'вход DM от харта: «харт в сбросе». По нему DM выставляет липкий бит havereset '
         '(`dmstatus.anyhavereset` / `allhavereset`), отладчик сбрасывает его записью `ackhavereset`'],
        ['`haltreq`, `resethaltreq`', 'просьба остановить харт; с `resethaltreq` харт останавливается на первой команде после '
         'сброса. DM доводит это до ядра прерыванием отладки (`debug_int`); с этим патчем не связано'],
        ['SBA (system bus access)', 'доступ DM к памяти через системную шину, без участия харта. Обычно так загружают программу; '
         'запись в строку, которая есть в L1D, вызывает снуп'],
        ['`hartResetReq` (XSTileWrap, XSNoCTop)', 'в upstream — вход сброса всего тайла от DM hartreset. С `EnableCoreReset` он '
         'запускает этот механизм (объединяется с `debug_reset`)'],
    ], [1.5, 4.3]))
    s.append(H(2, '2.3. Домены сброса'))
    s.append(P('Домен сброса — множество регистров, сбрасываемых одним сигналом. Такт везде один, но есть пересечение '
               'доменов сброса: сигналы из домена, который сейчас сбрасывается, в домен, который работает. Запрос '
               '`debug_reset` приходит из домена DM — он асинхронный и проходит синхронизатор.'))
    s.append(table([
        ['Домен', 'Что в нём', 'Сбрасывается'],
        ['тайла', 'L2Top (L2, MMIO-мост, CHI-порт), гейты, `TLResetIsolation`, `CoreResetCtrl`, синхронизаторы запросов, '
         'регистры изоляции в XSTile; с KeepL1 — ещё `metaArray`, `errorArray` и `tagArray` DCache (со счётчиком '
         'инициализации тегов)', 'только сбросом тайла'],
        ['ядра', 'всё остальное в XSCore: Frontend, Backend, MemBlock, управляющая логика DCache (MainPipe, MissQueue, '
         'WBQ, ProbeQueue, DCacheFlushUnit); в режиме SWEEP — и `metaArray`, `errorArray`, `tagArray`',
         'сбросом тайла или `coreReset`'],
        ['SRAM', 'массивы данных DCache и ICache (и теги — сами макросы SRAM)', 'никогда (содержимое не сбрасывается)'],
    ], [0.7, 3.8, 1.3]))
    s.append(P('Сброс в XiangShan формирует ResetGen: установка асинхронная (регистры сбрасываются сразу), снятие синхронное '
               '— через цепочку триггеров, чтобы все регистры вышли из сброса в одном такте. Из-за асинхронной установки '
               'сигналы ядра в домен тайла на время сброса изолируются (раздел 1.6).'))
    s.append(H(2, '2.4. Справочник модулей'))
    rows = [['Модуль', 'Что это и зачем нужен']]
    rows += [
        ['XSTileWrap', 'Обёртка тайла: синхронизирует сбросы и асинхронные входы, выводит порты в XSNoCTop. Здесь `hartResetReq` '
         'объединяется с `debug_reset`, и он больше не сбрасывает весь тайл.'],
        ['XSTile', 'Тайл: XSCore + L2Top. Сюда вставлены гейты, контроллер, синхронизаторы запросов, формирование сброса ядра '
         '(и с KeepL1 — сброса массивов L1D) и `hartIsInReset`.'],
        ['XSCore', 'Ядро: Frontend (выборка, ICache), Backend (ROB, исполнение, CSR), MemBlock. Новое: `l1_quiesce`, '
         '`l1_meta_reset`.'],
        ['L2Top', 'Обёртка L2: CoupledL2, MMIO-крестовина и MMIO-мост в CHI, логгеры и буферы TileLink, CHI-порт.'],
        ['CoupledL2', 'Кэш L2, инклюзивный по отношению к L1D. Директория хранит состояние строки (INVALID, BRANCH, TRUNK — '
         'право записи у L1, TIP — L2 владелец) и биты клиентов. MSHR — записи незавершённых транзакций L2. Не меняется.'],
        ['MemBlock', 'Подсистема памяти ядра: LoadUnit / StoreUnit, LSQ, sbuffer, DCache, TLB, PTW, Uncache, предвыборка L1. '
         'Содержит `l1d_to_l2_buffer` между DCache и гейтом (домен сброса ядра).'],
        ['DCache (L1D)', 'Кэш данных L1: 64 КБ, 4 пути × 256 наборов, строка 64 Б, write-back, VIPT. TL-C-клиент L2. Внутри — '
         'MainPipe, MissQueue, WritebackQueue, ProbeQueue и массивы.'],
        ['`metaArray`, `errorArray`, `tagArray`', 'Состояние каждой строки (N, B, T, Dirty), её флаги ошибок и теги; запись — только из s3 '
         'MainPipe. С KeepL1 — на сбросе тайла.'],
        ['`bankedDataArray`', 'SRAM данных; сбросом не очищается.'],
        ['MainPipe', 'Конвейер DCache (s0–s3): запись из sbuffer, атомики, установка строки после промаха, Probe, вытеснение. '
         'Новое: запрос flush (вытеснение заданного пути набора) и выход `busy` = s1..s3.'],
        ['MissQueue / MissEntry', '16 записей промахов: Acquire → Grant(Data) → установка строки → GrantAck. Новое: `empty`.'],
        ['WritebackQueue (WBQ)', '18 записей: Release / ReleaseData и ProbeAck / ProbeAckData; запись Release живёт до ReleaseAck. '
         'Новое: `empty`.'],
        ['ProbeQueue', '8 записей: принимает Probe из канала B и передаёт их в MainPipe через регистр выбора. Новое: `empty`.'],
        ['sbuffer, AtomicsUnit', 'Буфер зафиксированных записей и исполнитель AMO / LR / SC; пишут через MainPipe.'],
        ['ICache, PTW / L2TLB', 'Кэш команд и обход таблиц страниц; к L2 обращаются только Get. ICache после сброса ядра пуст '
         '(`valid_array` — RegInit).'],
        ['Uncache, instr uncache', 'Некэшируемые обращения данных (`d_mmio`) и выборка команд из MMIO (`i_mmio`).'],
        ['BPU', 'Предсказатель переходов; в сбросе записывает reset vector в начальный адрес выборки.'],
        ['L2-предвыборщик, `l2_tlb_req`', 'Предвыборщик BOP в CoupledL2 переводит виртуальные адреса через TLB ядра.'],
        ['ResetGen', 'Генератор сброса XiangShan: асинхронная установка, синхронное снятие. Цепочка ядра: MemBlock → Backend → '
         'Frontend (frontend выходит последним: `resetInFrontend`).'],
        ['AsyncResetSynchronizerShiftReg', 'Синхронизатор асинхронного уровня в домен такта (3 триггера, rocket-chip).'],
        ['WFI clock gate (XSNoCTop)', 'При `WFIClockGate` такт Core + L2 отключается, пока ядро в WFI; запрос сброса и '
         '`core_reset_busy` его будят.'],
        ['`TLQuiesceGate` (новый)', 'TileLink-адаптер на ребре ядро → L2Top: закрывает A (рано для некогерентных, с sDrain для l1d), '
         'держит B (`holdB`) или сам отвечает на Probe NtoN (`ackB`), изолирует сторону ядра, выдаёт `quiet`: через ребро ничего '
         'не идёт и не ожидается.'],
        ['`TLResetIsolation` (новый)', 'TileLink-адаптер на ребре L2Top → регистры ICache ctrl (менеджер в ядре): изоляция и '
         'счётчик запросов без ответа; выход `quiet`.'],
        ['`DCacheFlushUnit` (новый)', 'Автомат в DCache: блокирует новые операции, ждёт флаги пустоты и (SWEEP) обходит все строки '
         'запросами flush через MainPipe.'],
        ['`L1QuiesceIO` (новый)', 'Интерфейс контроллер ↔ DCache: `req`, `freeze` → / ← `done`, `idle`, `alive`.'],
        ['`CoreResetCtrl` (новый)', 'Автомат последовательности: sFlush → sDrain → sReset → sRelease. Регистры `closed` (= `isolate`), '
         '`coreReset`, `hartInReset`. Параметры `keepL1`, `rstCycles`.'],
    ]
    s.append(table(rows, [1.4, 4.4]))
    return s


def section3(C):
    s = [H(1, '3. Где находятся изменения')]
    s.append(diagrams.tile_structure())
    s.append(cap('Рис. 3. XSTile с изменениями. Оранжевым — гейты (домен тайла), красным — домен сброса ядра и контроллер; двойные '
                 'стрелки — TileLink-рёбра. Ребро icachectrl идёт из MMIO-крестовины L2Top обратно в ядро через '
                 '`TLResetIsolation`. Остальные выходы ядра изолируются в XSTile (1.6).'))
    rows = [['Файл (`src/main/scala/...`)', 'Что изменено', '+ / −', '§']]
    for path, a, d in C.stat:
        desc, sec = FILES.get(path, ('', ''))
        short = path.replace('src/main/scala/', '')
        rows.append(['`%s`' % short, desc, '+%d / −%d' % (a, d), sec])
    s.append(table(rows, [2.1, 2.9, 0.7, 0.6]))
    s.append(P('Всё новое вне DCache генерируется только при `EnableCoreReset = true` (по умолчанию `false`); без него XSTile '
               'соединяет ядро и L2Top как в upstream, без масок. В DCache автомат есть всегда, но при `quiesce.req = 0` он не '
               'активен, и синтез убирает его как постоянную логику; обход (запросы flush) генерируется только при '
               '`EnableCoreReset` и `CoreResetKeepL1 = false` — иначе вход flush MainPipe получает константу 0; порт '
               '`metaReset`, перенос массивов (`metaArray`, `errorArray`, `tagArray`) в домен тайла и маски `freeze` — только при '
               '`EnableCoreReset` и `CoreResetKeepL1`. `CoreResetKeepL1` передаётся контроллеру как Scala-параметр: его ветви '
               'выбираются при генерации. В гейте неиспользуемый вход (`holdB` в SWEEP, `ackB` с KEEP) получает константу 0, и '
               'синтез убирает его логику.'))
    return s


def section4(C):
    s = [PageBreak(), H(1, '4. Последовательность событий')]
    s.append(P('Автомат `CoreResetCtrl` и его выходы — на рис. 4 и в таблице под ним; общая схема по фазам — на рис. 5; '
               'диаграммы KEEP и SWEEP — на рис. 6 и 7. Фазы 1–3 одинаковы во всех конфигурациях; различия по '
               '`CoreResetKeepL1` — обход L1D в фазе 2 и то, что происходит с L1D и с Probe во время сброса.'))
    s.append(diagrams.fsm_ctrl())
    s.append(cap('Рис. 4. Состояния `CoreResetCtrl` (5 штук) и значения выходов. Все выходы — функции регистров состояния: '
                 '`holdProbe`, `gateBlock`, `earlyBlock` меняются в том же такте, что и состояние.'))
    s.append(table([
        ['Выход', 'sIdle', 'sFlush', 'sDrain', 'sReset', 'sRelease'],
        ['`l1.req` (DCache заблокирована)', '0', '1', '1', '0', '0'],
        ['`earlyBlock` (A некогерентных закрыт)', '0', '1', '1', '1', '1'],
        ['`gateBlock` (A l1d закрыт)', '0', '0', '1', '1', '1'],
        ['`holdProbe` (B держится) — KEEP', '0', '0', '1', '1', '1'],
        ['`holdProbe` — SWEEP', '0', '0', '1', '0', '0'],
        ['`ackProbe` (гейт отвечает NtoN) — SWEEP', '0', '0', '0', '1', '1'],
        ['`l1.freeze` (массивы не пишутся) — KEEP', '0', '0', '0', '1', '1'],
        ['`isolate` (= `closed`)', '0', '0', '0', '1', '1'],
        ['`coreReset`', '0', '0', '0', '1 (регистр, с переходом)', '0'],
        ['`hartInReset` → `hartIsInReset`', '0', '0', '0', '1', '1'],
        ['`busy` → `core_reset_busy`', '0', '1', '1', '1', '1'],
    ], [2.4, 0.5, 0.5, 0.5, 0.9, 0.7]))
    s.append(P('`isolate`, `ackProbe` (SWEEP), `l1.freeze` (KEEP) и `gateBlock` после sDrain — функции одного регистра `closed`: он '
               'поднимается на том же фронте, что и `coreReset`. `holdProbe` в sDrain — функция регистра `state`.', 'small'))
    s.append(Spacer(1, 4))
    s.append(diagrams.phases_timeline())
    s.append(cap('Рис. 5. Общая схема: что закрыто и открыто в каждом состоянии.'))
    s.append(diagrams.seq_keep())
    s.append(cap('Рис. 6. Последовательность KEEP: Probe от L2 держится с первого такта sDrain и до выхода ядра из сброса.'))
    s.append(diagrams.seq_sweep())
    s.append(cap('Рис. 7. Последовательность SWEEP: обход отдаёт строки L2 (Release / ReleaseData), в сбросе на Probe отвечает гейт.'))

    # ---------------- 4.1
    s.append(H(2, '4.1. Фаза 1: запрос'))
    s += bullets([
        'Источник — `debug_reset` (DM: ndmreset или hartreset этого харта), `core_reset_req` (кластер) или `hartResetReq` в '
        'XSTileWrap (тот же hartreset в upstream-подключении). Каждый вход тайла проходит 3-триггерный синхронизатор в такт '
        'тайла (`AsyncResetSynchronizerShiftReg`); запрос контроллера — ИЛИ синхронизированных входов.',
        'В XSNoCTop любой запрос и `core_reset_busy` будят отключённый в WFI такт и не дают отключить его снова.',
        '`CoreResetCtrl` переходит sIdle → sFlush, поднимает `busy`, `l1.req` и `earlyBlock`. Пока `busy` = 1, запросы '
        'L2-предвыборщика к TLB ядра (`l2_tlb_req`) закрыты.',
    ])
    s += box('Почему так: синхронизаторы в XSTile, пробуждение такта, закрытие l2_tlb_req сразу', [
        '<b>Синхронизаторы.</b> `ndmreset` и `hartreset` формирует Debug Module в своём такте, поэтому для тайла это '
        'асинхронный уровень; без синхронизации фронт может попасть в окно setup / hold. Синхронизатор стоит в самом '
        'XSTile, чтобы порт был безопасен при любом способе подключения тайла.',
        '<b>Пробуждение такта.</b> При `WFIClockGate` такт ядра и L2 отключается, пока ядро в WFI. Опустошение, счётчики гейтов, '
        'контроллер, ответы на Probe (DCache или гейт) работают от этого такта: без него последовательность встанет до '
        'выхода ядра из WFI, то есть, возможно, навсегда.',
        '<b>l2_tlb_req.</b> Предвыборщик L2 переводит адреса через TLB ядра. Этот TLB неблокирующий: ответ приходит через '
        'фиксированное число тактов. Если перестать подавать запросы с первого такта последовательности, к моменту сброса '
        'ни одного ответа в пути не будет; BOP запрос без ответа просто повторит позже.',
    ])
    # ---------------- 4.2
    s.append(H(2, '4.2. Фаза 2: sFlush — опустошение DCache и раннее закрытие A'))
    s.append(P('`DCacheFlushUnit` переходит sIdle → sDrain и поднимает `block`. С этого такта:'))
    s += bullets([
        'записи из sbuffer и атомики не входят в MainPipe, CMO не принимаются;',
        'новые промахи не попадают в MissQueue: загрузки переигрываются, запись, успевшая войти в MainPipe и промахнуться, '
        'возвращается в sbuffer, запросы предвыборки L1 отбрасываются;',
        'снято WFI-удержание промахов (`wfiReq` для MissQueue маскируется);',
        'загрузки-попадания продолжают читать DCache; Probe от L2 обслуживаются всё время (канал B открыт);',
        'в то же время гейты некогерентных агентов закрыли A (`earlyBlock`): начатые запросы получают ответы, новые ждут '
        'перед гейтом.',
    ])
    s.append(P('Автомат ждёт `idle` — четыре флага пустоты (1.5.3): MissQueue, WritebackQueue, MainPipe, ProbeQueue. С KEEP затем '
               'sDone: `l1.done` = 1. В режиме SWEEP — обход:'))
    s += bullets([
        '`sSweep`: каждый такт, когда MainPipe принимает, автомат выдаёт запрос flush на пару (набор, путь) — сначала все наборы '
        'пути 0, затем пути 1 и т. д., всего 1024 запроса. Соседние запросы — в разные наборы, поэтому проверка конфликта '
        'набора MainPipe их не задерживает. У flush самый низкий приоритет: Probe от L2 обслуживаются раньше.',
        'MainPipe читает тег и состояние пути. Строка в N завершает запрос сразу. Действительная строка уходит в WritebackQueue '
        'как добровольный Release (чистая) или ReleaseData (грязная) с параметром TtoN / BtoN, а в `metaArray` в том же такте '
        'пишется N.',
        '`sWait`: ни одного запроса flush в MainPipe (`inflight === 0`) и `idle` — каждый Release получил ReleaseAck. Затем '
        'sDone: `l1.done` = 1. L1D пуста, директория L2 не числит за ней ничего.',
    ])
    s.append(P('Блокировка остаётся, пока `l1.req` = 1. Контроллер уходит из sFlush при `l1Done && earlyQuiet` (1.5.1).'))
    s += box('Почему так: зачем опустошать DCache, если её всё равно сбросят', [
        'Обход отдаёт строки, но сбрасывается и управляющая логика DCache — всё, что она делала, теряется. Опасные случаи для L2: '
        '(а) запись MissQueue получила GrantData, но ещё не отправила GrantAck — MSHR L2 ждёт GrantAck вечно '
        '[TL 1.8.1 5.1, с. 29], [TL 1.8.1 9.3.9, с. 79]; (б) WritebackQueue начала ReleaseData и успела отправить один beat — '
        'SinkC ждёт второй beat вечно ([TL 1.8.1 5, с. 28]); или Release отправлен целиком, а ReleaseAck придёт в сброшенное '
        'ядро, которое этого Release уже не помнит ([TL 1.8.1 6.4, с. 43]); (в) вытеснение, запущенное промахом, отправит '
        'Release в такте сброса — гейт этого Release ещё не видел, когда разрешал сброс. Пустые очереди при заблокированных '
        'промахах и записях означают, что новый Release начаться не может, а все начатые завершены.',
        'Опустошение перед обходом нужно и ему самому: промах, установивший строку после того, как обход прошёл её набор, оставил '
        'бы в L1D строку, о которой знает L2. С KEEP сохраняются только массивы: вытеснение уже записало в meta состояние N, а '
        'Release ещё лежит в WritebackQueue — после сброса L1 строку не держит, а L2 по-прежнему считает её TRUNK; запись из '
        'sbuffer в s3 пишет данные и состояние Dirty в одном такте — сброс посреди даст несогласованную строку, которая '
        'переживёт сброс.',
    ])
    s += box('Почему так: обход ждёт последнего ReleaseAck; Probe во время обхода безопасны', [
        'Release — запрос, ReleaseAck — ответ на него [TL 1.9.3 9.3.12, с. 82]. Пока ответа нет, запись WBQ занята, и сбросить ядро '
        'нельзя: ReleaseAck пришёл бы в сброшенное ядро, а source ID оставался бы «занятым» [TL 1.8.1 6.4, с. 43]. До '
        'ReleaseAck DCache и не ответит на Probe к этой строке [TL 1.9.3 9.2, с. 70].',
        'Probe идёт в MainPipe раньше flush (более высокий приоритет) и по той же строке не встречается с ним в конвейере: '
        'MainPipe не пускает два запроса к одному набору в соседние стадии. Если Probe пришёл, когда Release строки уже в WBQ, '
        'он ждёт ReleaseAck и отвечает NtoN — обычная гонка Release и Probe [TL 1.9.3 9.2, с. 71]. Если строку раньше забрал '
        'Probe (toN), обход видит N и проходит мимо. В любом порядке L2 получает данные ровно один раз.',
        'Зачем WritebackQueue, если Release считает гейт: гейт видит только то, что пересекло границу; Release, который '
        'сформирован и лежит в WBQ, но ещё не отправлен (канал C занят), он не видит. Пустая WBQ значит, что все Release '
        'отправлены и подтверждены, а все ProbeAck отправлены.',
    ])
    # ---------------- 4.3
    s.append(H(2, '4.3. Фаза 3: sDrain — опустошение границы ядро / L2'))
    s.append(P('Контроллер переходит sFlush → sDrain: `gateBlock` закрывает канал A гейта l1d (на границе сообщения), а '
               '`holdProbe` закрывает B в том же такте. Некогерентные гейты уже закрыты и тихи (`earlyQuiet`), DCache сообщила '
               '`l1.done`. Контроллер ждёт одного: `gatesQuiet && l1Done && l1Idle` в такте решения — в нём же переход в sReset. '
               'Обычно это первый такт sDrain. Открытым может остаться только Probe, принятый l1d-гейтом в последнем такте '
               'sFlush: его ProbeAck идёт через буфер `l1d_to_l2_buffer`, `probes` гейта ≠ 0 держит `quiet` низким, пока ответ '
               'не пройдёт.'))
    s += box('Почему так: ждать ответов на Get и MMIO, проверка в такте перехода, Probe в ожидании не считается', [
        'Ответ, пришедший после выхода из сброса, ядро примет за ответ на новый запрос с тем же source ID и получит чужие данные '
        'или команды: идентификатор занят, пока на запрос не ответили [TL 1.8.1 6.4, с. 43]. MMIO-мост в L2 может ждать второй '
        'beat записи. Поэтому все запросы, пересёкшие границу, должны завершиться до сброса: «no unanswered TileLink requests '
        'when one half of the crossing is reset» [TL 1.8.1 3.2.3, с. 14].',
        'Решение по `quiet` текущего такта: если переходить в sReset по значению прошлого такта, Probe, принятый l1d-гейтом в '
        'последнем такте sFlush, проскакивает — следующим тактом ядро в сбросе, ProbeAck потерян, MSHR L2 ждёт его вечно '
        '(мутант `STALE_QUIET`, раздел 7.2).',
        'Probe, предложенный L2, но не принятый, в `quiet` не входит: он закрыт `holdProbe` с первого такта sDrain и ждёт в L2 '
        '(KEEP) либо получит ответ гейта (SWEEP). Гейты и их счётчики — в домене тайла и не сбрасываются вместе с ядром.',
    ])
    # ---------------- 4.4
    s.append(H(2, '4.4. Фаза 4: sReset — сброс XSCore'))
    s += bullets([
        'Контроллер переходит в sReset и поднимает `coreReset`: асинхронно сбрасывается всё внутри XSCore. С KEEP — кроме '
        '`metaArray`, `errorArray`, `tagArray` DCache; в режиме SWEEP — и они (L1D уже пуста). Данные в SRAM не меняются. '
        '`hartInReset` = 1.',
        'На том же фронте поднимается `isolate` (регистр `closed`): гейты и `TLResetIsolation` больше не смотрят на valid и ready '
        'ядра, XSTile подставляет вместо выходов ядра значения сброса или удержанные значения (1.6).',
        'Канал B к ядру закрыт: с KEEP `holdProbe` = 1 (гейты держат Probe в L2) и `l1.freeze` = 1 (запись в массивы L1D '
        'замаскирована); в режиме SWEEP `ackProbe` = 1 — гейт l1d сам принимает Probe и отвечает ProbeAck NtoN.',
        '<b>Длина:</b> не меньше `rstCycles` = 100 тактов и до снятия запроса: выход из sReset — при `cnt >= rstCycles && !req`. '
        'Это правило TileLink [TL 1.8.1 3.2.2] (100 тактов с valid = 0).',
        'L2 работает. Снуп HN к строке, которую директория числит за L1D (только KEEP): Probe ждёт в гейте. Снупы к остальным '
        'строкам — в режиме SWEEP ко всем — L2 обслуживает сама.',
        'В симуляции проверяется: через гейты в ядро и из ядра ничего не проходит (assert `gatesQuiet` в контроллере), а '
        'изоляция покрывает сброс (assert `!coreReset || closed`).',
    ])
    s += box('Почему так: KEEP — держать Probe, а не отвечать; SWEEP — ответ гейта; зачем freeze', [
        '<b>KEEP.</b> Отвечать некому: ProbeQueue, MainPipe и WritebackQueue в сбросе, а ответ может требовать данных, которые есть '
        'только в L1D. Если пустить Probe в ProbeQueue, которая сбрасывается, он пропадёт, и L2 будет ждать ProbeAck вечно. Пока '
        '`ready` = 0, Probe не принят [TL 1.8.1 4.1, с. 18] и ждёт в L2 (SourceB); после сброса он уходит в ядро — то есть '
        'принят за конечное время, как требует правило 3.i [TL 1.8.1 5, с. 28], если запрос снимут.',
        '<b>SWEEP.</b> К сбросу L1D уже пуста: обход отдал все строки, директория L2 её не числит. Любой Probe, пришедший в sReset '
        'или sRelease, относится к строке, которой у L1D нет, поэтому честный ответ клиента — ProbeAck NtoN: Probe к клиенту '
        'без прав законен и прав не меняет [TL 1.8.1 9.3.3, с. 74], ответ — Report NtoN [TL 1.9.3 9.3.5, с. 78]. Данные '
        'L2 уже получила при обходе, поэтому её копия актуальна (1.3.3, 1.3.4).',
        '<b>freeze (KEEP).</b> Записи в `metaArray`, `errorArray` и SRAM тегов и данных приходят из s3 MainPipe, а MainPipe в '
        'сбросе. Опустошение гарантирует, что в момент сброса записи нет. Но асинхронная установка сброса — момент, когда выходы '
        'регистров домена ядра переключаются не по такту (1.6), а разрешение записи SRAM у `BankedDataArray` выходит из регистра '
        'этого домена. Маска `freeze` — тот же регистр `closed`, что и `isolate`, — гарантирует, что ни такты установки, ни такты '
        'снятия сброса ничего не запишут в массивы, которые должны пережить сброс.',
    ])
    # ---------------- 4.5
    s.append(H(2, '4.5. Фаза 5: sRelease — выход из сброса'))
    s += bullets([
        '`coreReset` = 0 при `cnt >= rstCycles && !req`; ResetGen снимает сброс ядра синхронно, по цепочке MemBlock → Backend → '
        'Frontend.',
        'Контроллер в sRelease ждёт `l1.alive` и выход frontend из сброса (`!coreInReset`, где `coreInReset` = `resetInFrontend` — '
        'последний в цепочке ResetGen). `alive` — регистр в `DCacheFlushUnit`, равный 0, пока DCache в сбросе, и 1 с первого такта '
        'после него. Каналы A и B к ядру закрыты всё это время, `isolate` = 1. Оба сигнала контроллер смотрит только в sRelease: '
        'снятие сброса синхронное, и в этом состоянии выходы ядра меняются только по фронту.',
        'Затем `closed := 0`, `hartInReset := 0`, sIdle: гейты открыты, `core_reset_busy` = 0.',
    ])
    s += box('Почему так: зачем ждать alive и frontend', [
        'Сброс внутри XSCore расходится по цепочкам ResetGen, и DCache выходит из сброса через неизвестное заранее число тактов '
        'после `coreReset = 0`. Если открыть канал B раньше, ожидавший Probe (или, в режиме SWEEP, новый Probe) попадёт в '
        'ProbeQueue, которая ещё в сбросе, и пропадёт. `alive` — прямое свидетельство, что DCache работает. Frontend выходит '
        'последним: пока он в сбросе, ядро ещё не готово; кроме того, ядро, открытое до выхода frontend, могло бы послать первую '
        'выборку в закрытый гейт. Мутант `NO_FE_WAIT` ловится свойством P20 и симуляцией.',
    ])
    # ---------------- 4.6
    s.append(H(2, '4.6. Фаза 6: ядро работает'))
    s += bullets([
        'sIdle: гейты открыты, `busy` = 0, `hartIsInReset` = 0.',
        'Ядро выбирает команды с текущего reset vector. С KEEP первые загрузки к сохранённым строкам — попадания в L1D, Probe, '
        'ждавший в L2, получает ответ из «горячей» L1D. В режиме SWEEP — промахи; L2 отдаёт данные, которые получила при обходе.',
        'Если отладчик просил остановку на сбросе (`resethaltreq` или `haltreq`), прерывание отладки ждёт ядро, и харт останавливается '
        'на первой команде.',
        'Если запрос снова поднят в sRelease, последовательность начинается заново из sIdle (один сброс на запрос).',
    ])
    # ---------------- 4.7
    s.append(H(2, '4.7. Сводка: чего ждём и что сломается без этого'))
    s.append(table([
        ['Чего ждём / что делаем', 'Где', 'Что сломается без этого'],
        ['флаги пустоты DCache (MissQueue, WBQ, MainPipe, ProbeQueue)', 'DCacheFlushUnit, sDrain; `l1.idle` в контроллере',
         'MSHR L2 ждёт GrantAck; ReleaseData оборвана; (KEEP) строка наполовину установлена, неотправленный Release пропал с данными'],
        ['обход всех (набор, путь), Release с данными грязных строк (SWEEP)', 'DCacheFlushUnit, MainPipe, sSweep',
         'грязные данные L1D потеряны; после AcquirePerm L2 отдаёт данные другого адреса'],
        ['последний ReleaseAck (SWEEP)', 'DCacheFlushUnit, sWait', 'ReleaseAck в сброшенное ядро; Release, ещё лежащий в WBQ, пропал '
         'вместе с данными'],
        ['A некогерентных закрыт с sFlush; `earlyQuiet` при выходе', 'гейты ранние, CoreResetCtrl, sFlush',
         'запросы продолжают приходить (длиннее опустошение); без тишины B закроется раньше, чем L2 дождётся Probe для Get — Get '
         'без ответа'],
        ['B закрыт с первого такта sDrain', 'гейт l1d, `holdProbe`', 'Probe, принятый после решения, теряется сбросом; MSHR L2 ждёт вечно'],
        ['`gatesQuiet && l1Done && l1Idle` текущего такта', 'CoreResetCtrl, sDrain', 'MSHR L2 ждёт GrantAck / ProbeAck вечно; Probe '
         'последнего такта sFlush потерян; старый ответ примется за новый'],
        ['isolate с того же фронта, что и сброс', 'CoreResetCtrl `closed`, гейты, TLResetIsolation, XSTile',
         'выход ядра, меняющийся не по такту, защёлкнут в тайле: метастабильность, ложный valid, лишний beat'],
        ['канал B закрыт: держится (KEEP) или ответ гейта (SWEEP)', 'гейт, sReset / sRelease', 'Probe в сбрасываемую ProbeQueue '
         'пропал, L2 ждёт вечно'],
        ['запись в массивы замаскирована (KEEP)', 'DCacheWrapper, `freeze`', 'meta, тег или данные испорчены в такт установки или '
         'снятия сброса'],
        ['теги на сбросе тайла (KEEP)', 'DCacheWrapper, `tagArray.reset`', 'теги стёрты при сбросе ядра, meta сохранена — порча данных'],
        ['сброс не короче 100 тактов', 'CoreResetCtrl, sReset', 'нарушение правила TileLink 3.2.2 для связей внутри ядра'],
        ['сброс до снятия запроса', 'CoreResetCtrl, sReset', 'ядро выходит из сброса, пока его держат'],
        ['`alive` и выход frontend', 'CoreResetCtrl, sRelease', 'Probe ушёл в DCache, ещё не вышедшую из сброса; ядро открыто, пока '
         'frontend в сбросе'],
        ['запись массивов: нулевой запас между решением и `coreReset`', 'CoreResetCtrl, DCacheFlushUnit', 'запись s3 предыдущего такта '
         'попала бы под сброс'],
    ], [1.9, 1.6, 2.3]))
    return s
