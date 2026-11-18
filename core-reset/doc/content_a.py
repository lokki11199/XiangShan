"""Title page and section 1 of the document (v6)."""
from reportlab.platypus import PageBreak, Spacer

from pdflib import H, P, bullets, numbered, table, box, cap, text_block, S, CONTENT_W
import diagrams

ND = 'нет данных'


def _cov(C, cfg, key):
    c = C.cov.get(cfg)
    if not c or key not in c:
        return ND
    return str(c[key])


def verif_summary(C):
    """The 'Итог проверки' cell of the title table, from the results files."""
    out = []
    for key, nm in (('f', 'FULL'), ('k', 'KEEP')):
        f = C.formal.get(key)
        if not f or not f['main']['prove']:
            out.append('формально %s: %s' % (nm, ND))
            continue
        m = f['main']
        p100, p16 = m['prove'].get((100, 1)), m['prove'].get((16, 1))
        mt = m['mutants']
        out.append('формально %s: prove 100 — %s%s, prove 16 — %s%s; cover %s; мутантов с контрпримером %d' % (
            nm, p100[0] if p100 else ND, (' (%s с)' % C.fnum(p100[1])) if p100 else '',
            p16[0] if p16 else ND, (' (%s с)' % C.fnum(p16[1])) if p16 else '',
            ('%d' % m['cover'][1]) if m['cover'] else ND, sum(1 for x in mt if x[1] == 'FAIL')))
    a = C.adapters
    if a and a['prove']:
        out.append('fv_adapters: prove %s, мутантов %d' % (list(a['prove'].values())[0][0], len(a['mutants'])))
    e = C.eq
    if e and e['rows']:
        okc = sum(1 for r in e['rows'] if r[2] == 'PASS' and r[4] == 'PASS')
        out.append('эквивалентность RTL ↔ модели: %d из %d миттеров PASS' % (okc, len(e['rows'])))
    else:
        out.append('эквивалентность RTL ↔ модели: %s' % ND)
    r = C.reg
    if r:
        d = sum(c['design'] for c in r['cfg'].values())
        dp = sum(c['design_pass'] for c in r['cfg'].values())
        m = sum(c['mut'] for c in r['cfg'].values())
        mc = sum(c['mut_caught'] for c in r['cfg'].values())
        out.append('регрессия: прогонов дизайна %d / %d PASS, мутантов %d / %d пойманы%s' % (
            dp, d, mc, m, '' if r['complete'] else ' (регрессия не завершена)'))
    else:
        out.append('регрессия: %s' % ND)
    sf, sk = C.soak.get('FULL'), C.soak.get('CFG_KEEP')
    if sf and sk:
        out.append('длинный прогон: FULL %d / %d, KEEP %d / %d' % (sf['pass'], sf['runs'], sk['pass'], sk['runs']))
    else:
        out.append('длинный прогон: %s' % ND)
    rd = C.rtl_dcache
    if rd and rd['summary']:
        sm = rd['summary']
        out.append('RTL-тест DCache: %d из %d PASS, мутантов %d из %d' % (sm[1], sm[0], sm[4], sm[3]))
    else:
        out.append('RTL-тест DCache: %s' % ND)
    t = C.tile
    if t:
        out.append('тест изоляции тайла: неожиданных результатов %s' % (t['unexpected'] if t['unexpected'] is not None else ND))
    else:
        out.append('тест изоляции тайла: %s' % ND)
    return '; '.join(out)


def front(C):
    s = []
    s.append(P('Сброс XSCore без сброса L2: полный сброс L1D по умолчанию, сохранение L1D по параметру, без обхода', 'title'))
    s.append(P('Подробное описание изменений в XiangShan Kunminghu V2 (версия v6, ветка core-reset-v6, база 7b16188). Сброс '
               'приходит от Debug Module (ndmreset, hartreset) или от кластера и сбрасывает только ядро с L1; L2 и CHI-порт '
               'тайла работают. Параметр CoreResetKeepL1 выбирает: по умолчанию (FULL) L1D сбрасывается вместе с ядром и после '
               'сброса пуста, а пока ядро в сбросе, гейт сам отвечает на каждый Probe ответом ProbeAck NtoN; с параметром '
               '(KEEP) L1D сохраняет строки, Probe ждёт в L2. Обхода (sweep, flush) нет: DCache только опустошается от '
               'транзакций. Изоляция домена сброса ядра включается не меньше чем за такт до сброса (состояние sIso). Сброс — '
               'уровень, не короче 100 тактов. Из v5 сохранены раннее закрытие A некогерентных агентов, быстрое закрытие B и '
               'флаги пустоты DCache.', 'subtitle'))
    st = C.stat
    nf = len(st)
    na = sum(a for _, a, _ in st)
    nd = sum(d for _, _, d in st)
    rows = [
        ['Что', 'Где'],
        ['XiangShan kunminghu-v2, база 7b16188',
         ('%d файлов `src/`, +%d / −%d строк (`git diff 7b16188 HEAD -- src/`); CoupledL2 и другие подмодули не меняются' % (nf, na, nd))
         if nf else ND],
        ['Режимы L1D (параметр `CoreResetKeepL1`)',
         '`false` (по умолчанию) — FULL: L1D на сбросе ядра, пуста после сброса, грязные строки теряются; Probe в сбросе отвечает '
         'гейт (ProbeAck NtoN). `true` — KEEP: meta, error и теги L1D на сбросе тайла, запись и чтение массивов зажаты (freeze), '
         'Probe держится в L2. Включает механизм параметр `EnableCoreReset` (по умолчанию `false`: RTL как upstream)'],
        ['Порты',
         '`debug_reset` (ndmreset), `hart_reset` (hartreset этого харта; в XSTileWrap это `hartResetReq`), `core_reset_req` '
         '(кластер) — входы-уровни; `core_reset_busy` = последовательность идёт; `core_in_reset` = сброс XSCore установлен (только '
         'sReset). У XSTile, XSTileWrap и XSNoCTop'],
        ['Последовательность',
         'шесть состояний: sIdle → sQuiesce → sDrain → sIso → sReset → sRelease. Опережение изоляции `isoCycles` = 1 такт '
         '(для KEEP не больше 2). Запрос — уровень, фиксируется и не отменяется'],
        ['Probe во время сброса',
         'FULL: в sDrain и sIso держится в L2; в sReset и sRelease гейт принимает его и отвечает NtoN, по одному. KEEP: держится с '
         'первого такта sDrain до конца sRelease, потом доходит до L1D с сохранёнными строками'],
        ['Длина сброса', '`rstCycles` = 100 тактов и до снятия запроса ([@3.2.2])'],
        ['Из v5 сохранено',
         'раннее закрытие A некогерентных агентов с первого такта (`earlyBlock`, `earlyQuiet`); закрытие B с первого такта sDrain '
         'и решение по `quiet` текущего такта; четыре флага пустоты DCache'],
        ['Новые файлы', '`xiangshan/CoreReset.scala` (TLQuiesceGate, TLResetIsolation, CoreResetCtrl), '
                        '`cache/dcache/mainpipe/QuiesceUnit.scala` (L1QuiesceIO, DCacheQuiesceUnit)'],
        ['Итог проверки', verif_summary(C)],
    ]
    s.append(table(rows, [1.15, 3.85]))
    s.append(Spacer(1, 6))
    s.append(P('<b>Как читать документ.</b> Раздел 1 — задача, что изменилось относительно v5, два режима и сохранённые решения. '
               'Раздел 2 — понятия TileLink и Debug Module, справочник модулей. Раздел 3 — где изменения (16 файлов). Раздел 4 — '
               'последовательность: автомат, таблица выходов, временная диаграмма опережения изоляции, диаграммы FULL и KEEP. '
               'Раздел 5 — DCache без обхода. Раздел 6 — CoreReset.scala, XSTile, порты, изоляция боковых сигналов и правила RDC. '
               'Раздел 7 — проверка (в том числе «что нашла сама проверка»). Раздел 8 — подключение. Раздел 9 — ограничения, '
               'обязательные к прочтению (потеря грязных данных, AcquirePerm). Раздел 10 — отличия от v5 и состав пакета. '
               'Ссылки на TileLink — зелёные, номера разделов по версии 1.9.3 (<b>[@3.2.2]</b> и т. п.). Фрагменты патча: зелёным — '
               'добавленные строки, красным — удалённые, серым — контекст.'))
    elab_lines = C.ident or []
    el = C.elab
    s += box('Важно: что проверено и чего нет', [
        'Chisel-код v6 компилируется без ошибок и предупреждений (`mill xiangshan.compile`), полная elaboration XSNoCTop в трёх '
        'вариантах — без `EnableCoreReset`, FULL и KEEP — проходит (раздел 7.1); при `EnableCoreReset = false` RTL всего XSNoCTop '
        'совпадает с RTL 7b16188 по хешу нормализованных файлов SystemVerilog.' if el else
        'Результат полной elaboration XSNoCTop: ' + ND + '.',
        '<b>FULL содержит известные нарушения протокола и потерю данных</b> (раздел 9.1): грязные строки L1D пропадают, директория '
        'L2 устаревает, а строки, взятые через AcquirePerm, могут быть выданы с чужими данными. Это решение пользователя '
        '(16.11.2026): описать, не исправлять. Вариант исправления В1 — в разделе 9.1.',
        'Проверка идёт на моделях контроллера, гейтов и DCache, на RTL настоящей DCache и на RTL XSTile с заглушками XSCore и '
        'L2Top; всё ядро целиком в RTL не моделируется.',
    ], 'warn')
    return s


def section1(C):
    s = []
    s.append(PageBreak())
    s.append(H(1, '1. Задача и что изменилось относительно v5'))
    s.append(P('XiangShan Kunminghu V2 состоит из ядра XSCore (frontend, backend, MemBlock с L1D) и L2Top (кэш L2 CoupledL2, '
               'MMIO-крестовина, CHI-порт к интерконнекту). Нужно сбрасывать <b>только XSCore</b> — по `ndmreset` или `hartreset` '
               'Debug Module и по запросу кластера — не трогая L2, кредиты CHI и LINKACTIVE. Ядро и L2 общаются по TileLink, и '
               'сброс посреди транзакции ломает L2: MSHR ждёт GrantAck или ProbeAck, которых не будет, оборванная ReleaseData '
               'блокирует SinkC, снуп от HN остаётся без ответа. Поэтому граница сначала опустошается, на время сброса через '
               'неё ничего не ходит, а всё, что выходит из домена сброса ядра, изолируется на стороне тайла.'))
    s.append(H(2, '1.1. Что изменилось относительно v5'))
    s.append(table([
        ['', 'v5', 'v6'],
        ['Режим по умолчанию', 'KEEP (L1D сохраняется), SWEEP — по параметру', '<b>FULL: полный сброс L1D</b>; KEEP — по параметру `CoreResetKeepL1 = true`'],
        ['Обход L1D (sweep, flush)', 'в SWEEP: 1024 запроса flush через MainPipe, Release каждой строки', '<b>нет вообще</b>: MainPipe, WritebackQueue и MissQueue без правок под обход; грязные строки FULL теряются'],
        ['DCache перед сбросом', 'опустошение + обход (SWEEP)', 'только опустошение (`DCacheQuiesceUnit`, 3 состояния): по четырём флагам пустоты, без обхода'],
        ['Состояния контроллера', 'sIdle, sFlush, sDrain, sReset, sRelease', 'sIdle, <b>sQuiesce</b>, sDrain, <b>sIso</b>, sReset, sRelease'],
        ['Изоляция', 'регистр `closed` поднимается на том же фронте, что сброс ядра (нулевой запас записи в массивы)', '<b>опережение изоляции</b>: `isolate` стоит `isoCycles` ≥ 1 полных тактов до `coreReset`; зажим B по регистру `isolate`'],
        ['KEEP: что на сбросе тайла', 'meta, error, теги; freeze — запись', 'то же; freeze зажимает ещё чтение SRAM тегов и данных и `read.valid` meta / error; `bankedDataArray` на сбросе ядра'],
        ['`hartInReset`', 'с sReset', '= `busy`, с первого такта последовательности'],
        ['Запрос', 'ИЛИ трёх источников до синхронизатора', 'синхронизатор на каждый источник (`debug_reset`, `hart_reset`, `core_reset_req`), ИЛИ после'],
        ['Выход тайла', '`core_reset_busy`', '+ `core_in_reset` (сброс XSCore установлен)'],
        ['Предвыборка и боковые сигналы', 'часть без зажима', 'маска предвыборки L1 → L2 / L3 и `l2_pf_master_en` = 0 с первого такта (`busy`); зажаты `l2_pmp_resp`, `iretire`, `itype`, `l2_pf_en`'],
        ['`EnableCoreReset = false`', 'RTL с лишними портами и `TLTempNode`', '<b>структурно идентичен 7b16188</b>: всё новое под `Option` / `if`; проверено сравнением хешей'],
        ['Имена', 'sFlush, DCacheFlushUnit, `metaReset`', 'sQuiesce, DCacheQuiesceUnit, `keepReset` (три массива)'],
    ], [1.0, 1.9, 2.9]))
    s.append(Spacer(1, 4))
    s.append(P('<b>Сохранено из v5</b> (решения пользователя 15.11.2026): сброс-уровень не короче 100 тактов; раннее закрытие A '
               'некогерентных агентов (ICache, PTW, i_mmio, d_mmio) с первого такта последовательности; закрытие B с первого такта '
               'sDrain и решение по `quiet` текущего такта; флаги пустоты DCache вместо ожидания 16 тактов.'))
    s.append(H(2, '1.2. Два режима L1D: один параметр'))
    s.append(table([
        ['', 'FULL (`CoreResetKeepL1 = false`, по умолчанию)', 'KEEP (`CoreResetKeepL1 = true`)'],
        ['Что с L1D при сбросе', 'массивы (meta, error, теги, управляющая логика) сбрасываются вместе с ядром; после сброса L1D пуста', 'meta, error, теги на сбросе тайла, данные — SRAM без сброса; строки целы'],
        ['Грязные строки', '<b>теряются</b> (раздел 9.1)', 'остаются; L2 заберёт их Probe-ом после сброса'],
        ['Probe в sDrain, sIso', 'держится в L2 (`holdB`)', 'держится в L2'],
        ['Probe в sReset, sRelease', 'принимает гейт, отвечает `ProbeAck NtoN` (`ackB`), по одному', 'держится в L2 (`holdB`), гейт не отвечает никогда'],
        ['Массивы под freeze', 'нет (порта `keepReset` нет)', 'запись всех четырёх массивов, чтение SRAM тегов и данных, `read.valid` meta / error = 0 с sIso'],
        ['Директория L2', 'устаревает: L2 числит строки за L1D, которых там нет', 'остаётся верной'],
        ['Соблюдение TileLink', 'нарушения 7.2 (раздел 9.1)', 'нарушений нет; цена — снупы ждут конца сброса (9.2)'],
        ['Когда выбирать', 'всегда, когда допустима потеря незаписанных строк L1D; сброс не блокирует снупы; годится для отладки через SBA при удержанном сбросе', 'когда L1D нельзя терять, а кластер умеет ограничить длительность сброса сторожевым таймером'],
    ], [1.0, 2.5, 2.5]))
    s.append(Spacer(1, 4))
    s += box('Почему так', [
        'Решение пользователя 15.11.2026: по умолчанию — полный сброс L1D, обход убран. Обход в v5 стоил тысячи запросов flush через '
        'MainPipe и правок в трёх очередях DCache и спасал данные ценой сложности; без него сброс короче и RTL меньше. Платой '
        'становятся нарушения протокола FULL, которые пользователь принял и просил описать (раздел 9.1).',
        'Из-за этой цены KEEP остаётся в одной строке параметра: он не требует ничего от L2 и не нарушает TileLink, но удержание Probe '
        'на время сброса переносит ожидание на снупы HN (9.2).',
    ])
    s.append(H(2, '1.3. KEEP: что в L1D переживает сброс ядра'))
    s.append(table([
        ['Состояние DCache', 'Реализация', 'KEEP', 'Почему'],
        ['`metaArray`', 'триггеры `RegInit`, 2 бита на путь', '<b>сброс тайла</b>; freeze записи и `read.valid`', 'состояние когерентности = «L1D держит строку»'],
        ['`errorArray`', 'триггеры `RegInit`', '<b>сброс тайла</b>; freeze записи и `read.valid`', 'флаги denied / corrupt принадлежат сохранённым строкам'],
        ['`tagArray`', 'SRAM без сброса; счётчик `rst_cnt` (`RegInit`) после сброса пишет нули во все наборы', '<b>сброс тайла</b>; freeze записи и чтения', 'иначе сброс ядра стирает теги при сохранённой meta (дефект v4)'],
        ['`bankedDataArray`', 'SRAM без сброса, ступень записи `wen_reg`', 'сброс ядра (как upstream); freeze записи и чтения', 'SRAM данных хранит сама; перенос модуля создал бы пересечения `rst_core → rst_tile` без квалификатора. Защита — зажим на границе модуля'],
        ['`prefetchArray`, `accessArray`, `replacer`, WPU, резервирование LR/SC', 'триггеры', 'сброс ядра', 'подсказки и политика, на корректность не влияют'],
        ['MissQueue, WritebackQueue, ProbeQueue, MainPipe, `l1d_to_l2_buffer`', 'регистры', 'сброс ядра', 'пусты в точке сброса (флаги пустоты, `quiet`)'],
        ['sbuffer', 'регистры', 'сброс ядра', 'закоммиченные, но не записанные store теряются, как при любом сбросе; L2 их не видела'],
    ], [1.2, 1.8, 1.4, 2.0]))
    s.append(H(2, '1.4. Сброс-уровень, запрос, `busy`, `hartInReset`'))
    s.extend(bullets([
        '<b>Сброс — уровень.</b> XSCore в сбросе, пока держат запрос, но не меньше `rstCycles` = 100 тактов с valid = 0 [@3.2.2]. Ядро стартует после снятия запроса, когда `busy` упадёт.',
        '<b>Запрос фиксируется и не отменяется.</b> Один такт `req` в sIdle запускает всю последовательность: отладчик, поднявший и сразу снявший `ndmreset`, ждёт `havereset`. Поэтому входы запроса должны идти только с выходов триггеров: иголка, пойманная синхронизатором, запускает полный сброс.',
        '<b>`hartInReset` = `busy`</b> — с первого такта последовательности (в v5 — с sReset). Для Debug Module rocket-chip: `haveResetBitRegs` взводится сразу, `haltedBitRegs` и `resumeReqRegs` чистятся, halt-on-reset держит debug-прерывание до выхода. Ядро ещё несколько тактов работает, наружу это не выходит: A некогерентных закрыт, store в DCache не идут.',
        '<b>`core_in_reset`</b> = «сброс XSCore установлен» (регистр `coreReset`, только sReset). Он падает в начале sRelease, а ядро выходит из сброса ещё около 20 тактов; «ядро работает» означает только `busy` = 0.',
        '<b>`busy` без провала.</b> Если запрос снова поднят до конца sRelease, контроллер идёт sRelease → sQuiesce напрямую; в v5 между двумя последовательностями `busy` падал на такт.',
    ]))
    s.append(H(2, '1.5. Раннее закрытие A, быстрое закрытие B, флаги пустоты, опережение изоляции'))
    s.append(P('<b>Раннее закрытие A некогерентных агентов.</b> Запросы ICache, PTW, i_mmio и d_mmio после сброса бесполезны, поэтому '
               'канал A этих гейтов закрывается с первого такта последовательности (`earlyBlock` = `busy`), только на границе '
               'сообщения. Выход из sQuiesce ждёт тишины этих гейтов (`earlyQuiet`): в CoupledL2 Get некогерентного агента к строке, '
               'которую L1D держит в TRUNK / TIP, ждёт Probe к L1D, поэтому B должен оставаться открытым, пока такие Get не '
               'завершились. Это зависимость Get → Probe.'))
    s.append(P('<b>Быстрое закрытие B.</b> `holdProbe` — функция регистра состояния: B закрыт с первого такта sDrain (снятие `b.valid` '
               'непринятого beat-а законно [@4.1]). Решение sDrain → sIso принимается по `quiet` <b>текущего</b> такта: счётчики гейта '
               'уже включают Probe, принятый в последнем такте sQuiesce (его ProbeAck идёт через `l1d_to_l2_buffer`).'))
    s.append(P('<b>Флаги пустоты</b> (вместо ожидания 16 тактов в v4): `mq_empty`, `wbq_empty`, `mp_empty`, `pq_empty` — точные признаки '
               'MissQueue (включая принятый запрос и CMO), WritebackQueue, MainPipe s1–s3, ProbeQueue (включая регистр выбора). '
               'Подробности — раздел 5.'))
    s.append(P('<b>Опережение изоляции (новое в v6).</b> Состояние sIso между sDrain и sReset держит `isolate` и `freeze` включёнными '
               'минимум `isoCycles` полных тактов до сброса. В v5 регистр изоляции поднимался на том же фронте, что и сброс ядра: '
               'запись, зарегистрированная ступенью позже s3 (`s1_way_wen`, `wen_reg`), фиксировалась ровно на этом фронте — запас '
               'был нулевой. Теперь запас равен `isoCycles` тактам.'))
    s.append(diagrams.phases_timeline())
    s.append(cap('Рис. 1. Что открыто и закрыто в каждом состоянии; ширина столбцов условная.'))
    s.append(H(2, '1.6. Изоляция домена сброса ядра'))
    s.append(P('Сброс ядра устанавливается асинхронно (ResetGen синхронизует только снятие), поэтому в момент установки выходы ядра '
               'меняются в произвольный момент такта: пересечение доменов сброса (RDC). Регистр `isolate` домена тайла зажимает на '
               'стороне тайла все сигналы, идущие из домена ядра: TileLink — в гейтах и `TLResetIsolation`, боковые сигналы '
               '(`cpu_halt`, `msiAck`, трассу, ECC-ошибки, `l2_flush_en`, предвыборку, PMP-ответы) — в XSTile, массивы L1D (KEEP) — '
               'через freeze. Полная таблица — раздел 6.2, правила RDC — 6.3.'))
    return s
