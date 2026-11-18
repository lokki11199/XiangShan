"""Sections 2, 3 and 4 (v6)."""
from reportlab.platypus import PageBreak, Spacer

from pdflib import H, P, bullets, numbered, table, box, cap
import diagrams

FILES = {
    'src/main/scala/xiangshan/CoreReset.scala': ('новый: `TLQuiesceGate` (ранний / обычный; `holdB`, `ackB`, зажим по `isolate`), '
                                                 '`TLResetIsolation`, `CoreResetCtrl(keepL1, rstCycles = 100, isoCycles = 1)`', '4, 6.1'),
    'src/main/scala/xiangshan/cache/dcache/mainpipe/QuiesceUnit.scala': ('новый: `L1QuiesceIO` (`req`, `freeze`, `done`, '
                                                                         '`idle`, `alive`), `DCacheQuiesceUnit` (3 состояния)', '5.1'),
    'src/main/scala/xiangshan/cache/dcache/mainpipe/MissQueue.scala': ('`MissEntry.busy`, `MissQueue.empty`', '5.2'),
    'src/main/scala/xiangshan/cache/dcache/mainpipe/WritebackQueue.scala': ('`WritebackQueue.empty`', '5.3'),
    'src/main/scala/xiangshan/cache/dcache/mainpipe/Probe.scala': ('`ProbeQueue.empty`', '5.4'),
    'src/main/scala/xiangshan/cache/dcache/mainpipe/MainPipe.scala': ('только выход `busy` (есть запрос в s1, s2 или s3)', '5.5'),
    'src/main/scala/xiangshan/cache/dcache/DCacheWrapper.scala': ('`coreResetEnabled`, `coreResetKeepL1`; порты `quiesce`, `keepReset`; '
                                                                  'флаги; блокировки; маска WFI; KEEP: массивы на сбросе тайла и freeze; два assert', '5.6'),
    'src/main/scala/xiangshan/cache/dcache/FakeDCache.scala': ('заглушка: `quiesce.done`, `idle`, `alive`', '5.7'),
    'src/main/scala/xiangshan/mem/MemBlock.scala': ('проброс `l1_quiesce`, `l1_keep_reset` до DCache', '6.4'),
    'src/main/scala/xiangshan/XSCore.scala': ('проброс `l1_quiesce`, `l1_keep_reset`', '6.4'),
    'src/main/scala/xiangshan/XSTile.scala': ('порты, синхронизатор на источник, гейты на 5 рёбрах и `TLResetIsolation` (`if / else`), '
                                              'контроллер, изоляция боковых сигналов (6.2), сброс ядра и `keepReset`', '6.5'),
    'src/main/scala/xiangshan/XSTileWrap.scala': ('порты; `hartResetReq` сбрасывает только XSCore', '6.6'),
    'src/main/scala/top/XSNoCTop.scala': ('внешние порты; пробуждение такта на время последовательности', '6.6'),
    'src/main/scala/top/Top.scala': ('входы запроса XSTop привязаны к нулю', '6.6'),
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
               'FULL. В Release и ReleaseData NtoN запрещён [TL 1.9.3 9.3.10, с. 81], [TL 1.9.3 9.3.11, с. 82], в '
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
    s.append(P('Пункты спецификации TileLink, на которые ссылается документ (номера разделов — по версии 1.9.3; тексты цитат — по спецификации, как они приведены в документе v4: текст 1.9.3 в этой среде не проверялся):'))
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
               '`TLResetIsolation`. Без `EnableCoreReset` рёбра соединяются строками upstream дословно: `if (EnableCoreReset) a := gate := b else a := b`, '
               '`TLTempNode` не используется.'))
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
         'запускает этот механизм (отдельный вход `hart_reset` тайла, свой синхронизатор)'],
    ], [1.5, 4.3]))
    s.append(H(2, '2.3. Домены сброса'))
    s.append(P('Домен сброса — множество регистров, сбрасываемых одним сигналом. Такт везде один, но есть пересечение '
               'доменов сброса: сигналы из домена, который сейчас сбрасывается, в домен, который работает. Запрос '
               '`debug_reset` приходит из домена DM — он асинхронный и проходит синхронизатор.'))
    s.append(table([
        ['Домен', 'Что в нём', 'Сбрасывается'],
        ['тайла', 'L2Top (L2, MMIO-мост, CHI-порт), гейты, `TLResetIsolation`, `CoreResetCtrl`, синхронизаторы запросов, '
         'регистры изоляции в XSTile; в KEEP — ещё `metaArray`, `errorArray` и `tagArray` DCache (со счётчиком '
         'инициализации тегов)', 'только сбросом тайла'],
        ['ядра', 'всё остальное в XSCore: Frontend, Backend, MemBlock, управляющая логика DCache (MainPipe, MissQueue, '
         'WBQ, ProbeQueue, DCacheQuiesceUnit); в режиме FULL — и `metaArray`, `errorArray`, `tagArray`, `bankedDataArray` — как массивы',
         'сбросом тайла или `coreReset`'],
        ['SRAM', 'массивы данных DCache и ICache (и теги — сами макросы SRAM)', 'никогда (содержимое не сбрасывается; в FULL L1D пуста потому, что сброшены meta и теги)'],
    ], [0.7, 3.8, 1.3]))
    s.append(P('Сброс в XiangShan формирует ResetGen: установка асинхронная (регистры сбрасываются сразу), снятие синхронное '
               '— через цепочку триггеров, чтобы все регистры вышли из сброса в одном такте. Из-за асинхронной установки '
               'сигналы ядра в домен тайла на время сброса изолируются (раздел 1.6).'))
    s.append(H(2, '2.4. Справочник модулей'))
    rows = [['Модуль', 'Что это и зачем нужен']]
    rows += [
        ['XSTileWrap', 'Обёртка тайла: синхронизирует сбросы и асинхронные входы, выводит порты в XSNoCTop. С `EnableCoreReset` '
         '`hartResetReq` сбрасывает только XSCore (через `hart_reset` тайла), а не весь тайл.'],
        ['XSTile', 'Тайл: XSCore + L2Top. Сюда вставлены гейты, контроллер, синхронизаторы запросов, формирование сброса ядра '
         '(и в KEEP — сброса массивов L1D), изоляция боковых сигналов и `hartIsInReset`.'],
        ['XSCore', 'Ядро: Frontend (выборка, ICache), Backend (ROB, исполнение, CSR), MemBlock. Новое: `l1_quiesce`, `l1_keep_reset`.'],
        ['L2Top', 'Обёртка L2: CoupledL2, MMIO-крестовина и MMIO-мост в CHI, логгеры и буферы TileLink, CHI-порт.'],
        ['CoupledL2', 'Кэш L2, инклюзивный по отношению к L1D. Директория хранит состояние строки (INVALID, BRANCH, TRUNK — '
         'право записи у L1, TIP — L2 владелец) и биты клиентов. MSHR — записи незавершённых транзакций L2. Не меняется.'],
        ['MemBlock', 'Подсистема памяти ядра: LoadUnit / StoreUnit, LSQ, sbuffer, DCache, TLB, PTW, Uncache, предвыборка L1. '
         'Содержит `l1d_to_l2_buffer` между DCache и гейтом (домен сброса ядра).'],
        ['DCache (L1D)', 'Кэш данных L1: 64 КБ, 4 пути × 256 наборов, строка 64 Б, write-back, VIPT. TL-C-клиент L2. Внутри — '
         'MainPipe, MissQueue, WritebackQueue, ProbeQueue и массивы.'],
        ['`metaArray`, `errorArray`, `tagArray`', 'Состояние каждой строки (N, B, T, Dirty), её флаги ошибок и теги. В KEEP — на сбросе тайла.'],
        ['`bankedDataArray`', 'SRAM данных; сбросом не очищается, в обоих режимах на сбросе ядра; в KEEP защищён зажимом freeze.'],
        ['MainPipe', 'Конвейер DCache (s0–s3): запись из sbuffer, атомики, установка строки после промаха, Probe, вытеснение. '
         'Новое: только выход `busy` = s1..s3.'],
        ['MissQueue / MissEntry', '16 записей промахов: Acquire → Grant(Data) → установка строки → GrantAck; CMO. Новое: `empty`.'],
        ['WritebackQueue (WBQ)', '18 записей: Release / ReleaseData и ProbeAck / ProbeAckData; запись Release живёт до ReleaseAck. Новое: `empty`.'],
        ['ProbeQueue', '8 записей: принимает Probe из канала B и передаёт их в MainPipe через регистр выбора. Новое: `empty`.'],
        ['sbuffer, AtomicsUnit', 'Буфер зафиксированных записей и исполнитель AMO / LR / SC; пишут через MainPipe.'],
        ['ICache, PTW / L2TLB', 'Кэш команд и обход таблиц страниц; к L2 обращаются только Get. ICache после сброса ядра пуст.'],
        ['Uncache, instr uncache', 'Некэшируемые обращения данных (`d_mmio`) и выборка команд из MMIO (`i_mmio`).'],
        ['L2-предвыборщик, `l2_tlb_req`', 'Предвыборщик BOP в CoupledL2 переводит виртуальные адреса через TLB ядра и получает подсказки '
         'предвыборки L1 (`PrefetchRecv`).'],
        ['ResetGen', 'Генератор сброса XiangShan: асинхронная установка, синхронное снятие (3 триггера). Цепочка ядра: MemBlock → Backend → '
         'Frontend (frontend выходит последним: `resetInFrontend`).'],
        ['AsyncResetSynchronizerShiftReg', 'Синхронизатор асинхронного уровня в домен такта (3 триггера, rocket-chip).'],
        ['WFI clock gate (XSNoCTop)', 'При `WFIClockGate` такт Core + L2 отключается, пока ядро в WFI; любой запрос сброса и '
         '`core_reset_busy` его будят.'],
        ['`TLQuiesceGate` (новый)', 'TileLink-адаптер на ребре ядро → L2Top: закрывает A (рано для некогерентных, с sDrain для l1d), '
         'держит B (`holdB`) или сам отвечает на Probe NtoN (`ackB`), зажимает сторону ядра по `isolate`, выдаёт `quiet`.'],
        ['`TLResetIsolation` (новый)', 'TileLink-адаптер на ребре L2Top → регистры ICache ctrl (менеджер в ядре): изоляция и счётчик запросов; `quiet`.'],
        ['`DCacheQuiesceUnit` (новый)', 'Автомат в DCache: блокирует новые операции и ждёт четыре флага пустоты. Обхода нет.'],
        ['`L1QuiesceIO` (новый)', 'Интерфейс контроллер ↔ DCache: `req`, `freeze` → / ← `done`, `idle`, `alive`.'],
        ['`CoreResetCtrl` (новый)', 'Автомат последовательности: sQuiesce → sDrain → sIso → sReset → sRelease. Регистры `busy`, `isolate`, '
         '`coreReset`, `releasing`.'],
    ]
    s.append(table(rows, [1.4, 4.4]))
    return s


def section3(C):
    s = [H(1, '3. Где находятся изменения')]
    s.append(diagrams.tile_structure())
    s.append(cap('Рис. 2. XSTile с изменениями. Оранжевым — гейты (домен тайла), красным — домен сброса ядра и контроллер; двойные '
                 'стрелки — TileLink-рёбра. Ребро icachectrl идёт из MMIO-крестовины L2Top обратно в ядро через '
                 '`TLResetIsolation`. Остальные выходы ядра изолируются в XSTile (6.2).'))
    rows = [['Файл (`src/main/scala/...`)', 'Что изменено', '+ / −', '§']]
    for path, a, d in C.stat:
        desc, sec = FILES.get(path, ('', ''))
        short = path.replace('src/main/scala/', '')
        rows.append(['`%s`' % short, desc, '+%d / −%d' % (a, d), sec])
    s.append(table(rows, [2.1, 2.9, 0.7, 0.6]))
    s.append(P('Всё новое генерируется только при `EnableCoreReset = true` (по умолчанию `false`). Правило — структурная идентичность '
               'upstream: новые порты — `Option.when(...)`, новые модули — `Option.when(...)(Module(...))`, изменённые соединения — '
               '`opt.foreach { x => when (x) { ... } }` поверх исходной строки, в diplomacy — `if (EnableCoreReset) a := gate := b else a := b`, '
               'где ветвь `else` — строка upstream дословно. В `HasDCacheParameters` добавлены `coreResetEnabled` и '
               '`coreResetKeepL1`; имена намеренно отличаются от `EnableCoreReset` / `CoreResetKeepL1` из `HasSoCParameter`: '
               'trait `HasDCacheParameters` подмешан во многие классы вне DCache (PTW, LSQ, CSR), одинаковые `val` и `def` дали бы конфликт. '
               'Идентичность проверена сравнением полного XSNoCTop с 7b16188 (раздел 7.1). `CoreResetKeepL1` передаётся контроллеру как '
               'Scala-параметр: ветви выбираются при генерации.'))
    return s


def section4(C):
    s = [PageBreak(), H(1, '4. Последовательность событий')]
    s.append(P('Автомат `CoreResetCtrl` и его выходы — на рис. 3 и в таблице под ним; общая схема по состояниям — на рис. 1 (раздел 1); времянка опережения изоляции — на рис. 5; диаграммы FULL и KEEP — на рис. 6 и 7. Состояния sQuiesce, sDrain, '
               'sIso одинаковы в обоих режимах; различие по `CoreResetKeepL1` — что происходит с L1D и с Probe во время сброса.'))
    s.append(diagrams.fsm_ctrl())
    s.append(cap('Рис. 3. Состояния `CoreResetCtrl` (6 штук). Регистры (все `RegInit`, сброс тайла): `state`, `cnt` (8 бит), `busy`, `isolate`, '
                 '`coreReset`, `releasing`. Квалификаторы сигналов домена ядра — только регистры `isolate` и `releasing`, а не декод `state`: декод '
                 'многобитного регистра может дать иголку на переходе.'))
    s.append(table([
        ['Выход', 'sIdle', 'sQuiesce', 'sDrain', 'sIso', 'sReset', 'sRelease'],
        ['`busy`, `hartInReset`, `earlyBlock`', '0', '1', '1', '1', '1', '1'],
        ['`l1.req` (DCache блокирована)', '0', '1', '1', '1', '0', '0'],
        ['`gateBlock` (A l1d закрыт)', '0', '0', '1', '1', '1', '1'],
        ['`holdProbe` — FULL', '0', '0', '1', '1', '0', '0'],
        ['`ackProbe` — FULL', '0', '0', '0', '0', '1', '1'],
        ['`holdProbe` — KEEP', '0', '0', '1', '1', '1', '1'],
        ['`ackProbe` — KEEP', '0', '0', '0', '0', '0', '0'],
        ['`isolate`', '0', '0', '0', '1', '1', '1'],
        ['`l1.freeze` — KEEP (FULL всегда 0)', '0', '0', '0', '1', '1', '1'],
        ['`coreReset`, `inReset` (`core_in_reset`)', '0', '0', '0', '0', '1', '0'],
    ], [2.4, 0.5, 0.7, 0.55, 0.45, 0.55, 0.7]))
    s.append(P('`l1.req` остаётся 1 в sIso: иначе DCache сняла бы блокировку, и store из sbuffer вошёл бы в MainPipe за такт до сброса. '
               '`holdProbe` в sDrain и sIso — в обоих режимах: L1D ещё держит строки, отвечать за неё нельзя, а пускать новый Probe — значит '
               'не выйти из sDrain. Сигналы из домена ядра в контроллере квалифицированы регистрами: `l1Done = done && !isolate`, '
               '`l1Idle = idle && !isolate`, `coreUp = releasing && alive && !resetInFrontend`.', 'small'))
    s.append(Spacer(1, 4))
    s.append(diagrams.iso_lead_timing())
    s.append(cap('Рис. 5. Опережение изоляции, isoCycles = 1. На фронте T → T+1 `isolate := 1`; весь такт T+1 зажимы стоят, а ядро ещё не в сбросе '
                 '(его выходы меняются только синхронно); `coreReset := 1` на фронте T+1 → T+2, асинхронная установка сброса видна '
                 'после него. Снятие: `isolate := 0` на фронте U → U+1, не раньше чем через полный такт после выхода последнего домена ядра.'))
    s.append(diagrams.seq_full())
    s.append(cap('Рис. 6. Последовательность FULL: грязные строки не спасаются, в сбросе на Probe отвечает гейт.'))
    s.append(diagrams.seq_keep())
    s.append(cap('Рис. 7. Последовательность KEEP: Probe от L2 держится с первого такта sDrain и до конца sRelease.'))

    s.append(H(2, '4.1. Фаза 1: запрос'))
    s += bullets([
        'Источники — `debug_reset` (ndmreset), `hart_reset` (hartreset этого харта), `core_reset_req` (кластер). У каждого свой 3-триггерный '
        'синхронизатор (`AsyncResetSynchronizerShiftReg`) в такт тайла, ИЛИ — после синхронизаторов: ИЛИ до синхронизатора давал бы '
        'иголки на асинхронных входах.',
        'Входы запроса должны идти только с выходов триггеров: запрос не отменяется, и иголка, пойманная синхронизатором, запускает полный сброс.',
        'В XSNoCTop любой запрос и `core_reset_busy` будят отключённый WFI такт и не дают отключить его снова: опустошение, счётчики и '
        'ответы на Probe работают от этого такта.',
        '`CoreResetCtrl`: sIdle → sQuiesce, `busy` := 1, `hartInReset` = `busy`. С этого такта маскируются подсказки предвыборки L1 → L2 / L3 '
        '(`addr_valid`), `l2_pf_master_en` = 0 и запросы L2-предвыборщика к TLB ядра (`l2_tlb_req`).',
    ])
    s += box('Почему так: маска предвыборки с первого такта, hartInReset = busy', [
        'MSHR предвыборки L2 может выбрать жертвой строку L1D (директория не избегает путей с клиентом) и послать rProbe; а в KEEP Probe во время '
        'сброса держится, и снуп HN к такой жертве встаёт в RXSNP. Поэтому подсказки и мастер-флаг предвыборки выключаются с первого такта, а не с `isolate`. '
        'Остаток (MSHR, выделенная до начала последовательности) описан в 9.2.',
        '`hartInReset` = `busy`: в окне sQuiesce / sDrain отладчик больше не видит «харт не в сбросе». Ядро при этом ещё несколько тактов работает, '
        'но наружу ничего не выходит.',
    ])
    s.append(H(2, '4.2. Фаза 2: sQuiesce — опустошение DCache и раннее закрытие A'))
    s.append(P('`DCacheQuiesceUnit` переходит sIdle → sDrain и поднимает `block`. С этого такта:'))
    s += bullets([
        'записи из sbuffer, атомики и CMO не входят в DCache; новые промахи не попадают в MissQueue (запрос переигрывается); '
        'WFI-удержание промахов (`wfiReq`) снято, иначе неотправленные Acquire не ушли бы;',
        'загрузки-попадания продолжают работать; Probe обслуживаются всё время (B открыт);',
        'гейты некогерентных агентов закрыли A (`earlyBlock`): начатые запросы получают ответы, новые ждут перед гейтом.',
    ])
    s.append(P('Автомат ждёт `idle` — все четыре флага пустоты, затем sDone: `l1.done` = 1 (держится, пока `req` = 1). Обхода нет: строки не '
               'трогаются ни в FULL, ни в KEEP. Контроллер уходит из sQuiesce при `l1Done && earlyQuiet`.'))
    s += box('Почему так: зачем опустошать DCache, если её всё равно сбросят', [
        'Грязные строки в FULL не спасаются, но опустошение нужно ради протокола: (а) запись MissQueue получила GrantData, но не отправила GrantAck — '
        'MSHR L2 ждёт вечно [@5.1], [@9.3.9]; (б) WritebackQueue начала ReleaseData и отправила один beat — SinkC ждёт второй [@5]; '
        'или Release отправлен целиком, а ReleaseAck придёт в сброшенное ядро [@6.4]; (в) вытеснение, запущенное промахом, отправит Release в такте '
        'сброса. В KEEP добавляется целостность строк: запись из sbuffer в s3 пишет данные и Dirty в одном такте — сброс посреди даст '
        'несогласованную строку, которая переживёт сброс.',
        'Блокировка не трогает загрузки-попадания: они читают DCache и не создают транзакций.',
    ])
    s.append(H(2, '4.3. Фаза 3: sDrain — опустошение границы ядро / L2'))
    s.append(P('Контроллер переходит sQuiesce → sDrain: `gateBlock` закрывает A гейта l1d (на границе сообщения), `holdProbe` закрывает B в том же такте. '
               'Некогерентные гейты уже тихи, DCache сообщила `l1.done`. Контроллер ждёт `gatesQuiet && l1Done && l1Idle` — всё в одном такте '
               'решения, в нём же переход в sIso. Обычно это первый такт sDrain. Открытым может остаться только Probe, принятый l1d-гейтом в '
               'последнем такте sQuiesce: его ProbeAck идёт через `l1d_to_l2_buffer`, `probes` гейта ≠ 0 держит `quiet` низким, пока ответ '
               'не пройдёт.'))
    s += box('Почему так: решение по quiet текущего такта; ждать ответов на Get и MMIO', [
        'Если переходить по значению прошлого такта, Probe последнего такта sQuiesce проскакивает: следующим тактом ядро в sIso, ProbeAck потерян, '
        'MSHR L2 ждёт вечно (мутант `STALE_QUIET`, 7.2). Ответ, пришедший после выхода из сброса, ядро приняло бы за ответ на новый запрос с тем же '
        'source ID [@6.4]; «no unanswered TileLink requests when one half of the crossing is reset» [@3.2.3].',
        'Probe, предложенный L2, но не принятый, в `quiet` не входит: он закрыт `holdProbe` и ждёт в L2.',
    ])
    s.append(H(2, '4.4. Фаза 4: sIso — опережение изоляции'))
    s += bullets([
        '`isolate` := 1 (и `freeze` в KEEP) на фронте sDrain → sIso. Гейты, `TLResetIsolation`, зажимы XSTile и freeze стоят; ядро живо, но снаружи его '
        'уже не видно. Длится `isoCycles` тактов (1 по умолчанию; для KEEP `require(isoCycles <= 2)`, 7.2).',
        '`l1.req` = 1: DCache остаётся заблокированной. `holdProbe` = 1: Probe держится и в FULL (гейт отвечает NtoN только тогда, когда L1D действительно '
        'сбрасывается).',
        'Запись, зарегистрированная на один такт позже s3 (`s1_way_wen` у meta, `wen_reg` у данных, `latency = 1` у SRAM), от s3 в последнем такте '
        'sDrain фиксируется на фронте перед sIso; в такте решения freeze = 0, запись проходит, до асинхронного сброса остаётся ещё такт sIso.',
    ])
    s += box('Почему так: зачем ещё один такт', [
        'В v5 `closed` поднимался на том же фронте, что и сброс ядра: зажимы и асинхронная установка совпадали, запас записи был нулевой, и между решением '
        'и сбросом нельзя было вставить задержку. В v6 в sIso выходы ядра меняются ещё только синхронно, поэтому триггеры тайла на следующем фронте '
        'захватывают уже зажатые значения; запас — `isoCycles` тактов. Assert контроллера: `!coreReset || RegNext(isolate)`.',
    ])
    s.append(H(2, '4.5. Фаза 5: sReset — сброс XSCore'))
    s += bullets([
        '`coreReset` := 1: асинхронно сбрасывается всё внутри XSCore. FULL — вместе с массивами L1D (L1D пуста после сброса). KEEP — кроме meta, error и '
        'tag (на сбросе тайла); данные в SRAM не меняются. `core_in_reset` = 1.',
        'Канал B к ядру закрыт: FULL — гейт l1d принимает Probe и отвечает ProbeAck NtoN (`ackProbe`), по одному за раз; KEEP — Probe держится (`holdProbe`), '
        'гейт не отвечает никогда.',
        '<b>Длина:</b> не меньше `rstCycles` = 100 тактов и до снятия запроса: выход — при `cnt >= rstCycles && !req` [@3.2.2].',
        'L2 работает. В KEEP снуп HN к строке L1D ждёт (9.2); в FULL L2 отвечает на снупы сама по устаревшей директории (9.1).',
    ])
    s += box('Почему так: FULL — ответ гейта; KEEP — держать Probe', [
        '<b>FULL.</b> L1D сбрасывается вместе с ядром и строк не отдаёт; NtoN — то, что ответила бы сброшенная L1D. Probe к клиенту без прав законен и прав не '
        'меняет [@9.3.3]; ответ — Report NtoN [@9.3.5]. Формально NtoN по строке, которую клиент держал Dirty, ложен — это нарушение 9.1.',
        '<b>KEEP.</b> Отвечать некому: ProbeQueue, MainPipe и WritebackQueue в сбросе, а ответ может требовать данных только из L1D. Пока `ready` = 0, Probe не '
        'принят [@4.1] и ждёт в L2 (SourceB); после сброса уходит в ядро — принят за конечное время, как требует правило 3.i [@5], если запрос снимут.',
        '<b>freeze (KEEP).</b> Зажимает запись всех четырёх массивов, чтение SRAM тегов и данных и `read.valid` meta / error с sIso (раздел 5.3).',
    ])
    s.append(H(2, '4.6. Фаза 6: sRelease — выход из сброса'))
    s += bullets([
        '`coreReset` := 0, `releasing` := 1; ResetGen снимает сброс ядра синхронно, по цепочке XSTile → MemBlock → {DCache, backend} → frontend '
        '(по 3 такта на ступень). `core_in_reset` падает сразу, ядро выходит из сброса ещё ~20 тактов.',
        'Контроллер ждёт `coreUp = releasing && alive && !resetInFrontend`. `alive` — регистр `DCacheQuiesceUnit`, 0 пока DCache в сбросе; `resetInFrontend` — '
        'последний в цепочке. `isolate` держится; на фронте после `coreUp` он падает.',
        'Если `req` = 1: sRelease → sQuiesce напрямую, `busy` остаётся 1. Иначе sIdle, `busy` := 0.',
        'Запрос, поднятый и снятый внутри sRelease раньше такта `coreUp`, теряется: контроллер смотрит `req` в sRelease только в этом такте. Запрос, который '
        'должен дать следующий сброс, держат, пока контроллер не покинет sRelease (SCEN 9, TESTPLAN_deviations п. 14).',
    ])
    s += box('Почему так: зачем ждать alive и frontend', [
        'DCache выходит из сброса через неизвестное число тактов. Если открыть B раньше, ожидающий Probe попадёт в ProbeQueue, которая ещё в сбросе, и пропадёт. '
        'Frontend выходит последним: пока он в сбросе, ядро не готово. Мутанты `NO_ALIVE`, `NO_FE_WAIT` ловятся свойствами P22, P20.',
    ])
    s.append(H(2, '4.7. Ядро работает'))
    s += bullets([
        'sIdle: гейты открыты, `busy` = 0, `hartIsInReset` = 0. Ядро выбирает команды с текущего reset vector; значение должно быть стабильным от снятия запроса до `busy` = 0 (8.2).',
        'KEEP: первые загрузки к сохранённым строкам — попадания; ожидавший Probe получает ответ из «горячей» L1D. FULL: все обращения — промахи; L2 отдаёт '
        'свои данные, а директория L2 до первого Probe устарела (9.1).',
        'Если отладчик просил остановку на сбросе (`resethaltreq`), харт останавливается на первой команде.',
    ])
    s.append(H(2, '4.8. Сводка: чего ждём и что сломается без этого'))
    s.append(table([
        ['Чего ждём / что делаем', 'Где', 'Что сломается без этого'],
        ['флаги пустоты DCache', 'DCacheQuiesceUnit; `l1.idle` в контроллере', 'MSHR L2 ждёт GrantAck; ReleaseData оборвана; (KEEP) строка установлена наполовину'],
        ['A некогерентных закрыт с sQuiesce; `earlyQuiet` при выходе', 'ранние гейты, CoreResetCtrl', 'запросы продолжают приходить; без тишины B закроется раньше, чем L2 дождётся Probe для Get'],
        ['B закрыт с первого такта sDrain', 'гейт l1d, `holdProbe`', 'Probe, принятый после решения, теряется сбросом; MSHR L2 ждёт вечно'],
        ['`gatesQuiet && l1Done && l1Idle` текущего такта', 'CoreResetCtrl, sDrain', 'ответ на Probe последнего такта потерян; старый ответ примется за новый'],
        ['`isolate` на `isoCycles` тактов раньше `coreReset`', 'CoreResetCtrl, sIso', 'выход ядра, меняющийся не по такту, защёлкнут в тайле; запись в массив на фронте сброса'],
        ['Probe держится (KEEP) / ответ гейта (FULL) в сбросе', 'гейт, sReset / sRelease', 'Probe в сбрасываемую ProbeQueue пропал, L2 ждёт вечно'],
        ['freeze записи и чтения (KEEP)', 'DCacheImp', 'meta, тег или данные испорчены асинхронной установкой сброса'],
        ['теги на сбросе тайла (KEEP)', '`tagArray.reset`', 'сброс ядра стирает теги при сохранённой meta — порча данных'],
        ['сброс не короче 100 тактов и до снятия запроса', 'sReset', 'нарушение [@3.2.2]; ядро выходит из сброса, пока его держат'],
        ['`alive` и выход frontend', 'sRelease', 'Probe в DCache, не вышедшую из сброса; ядро открыто, пока frontend в сбросе'],
        ['`busy` без провала, `hartInReset` = `busy`', 'CoreResetCtrl', 'отладчик видит «харт не в сбросе» в середине последовательности'],
    ], [1.9, 1.6, 2.3]))
    return s
