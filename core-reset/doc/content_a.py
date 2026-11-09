"""Title page and section 1 of the document."""
from reportlab.platypus import PageBreak, Spacer, KeepTogether

from pdflib import (H, P, bullets, numbered, table, box, cap, patch_frag, src_anchor, text_block, S, CONTENT_W,
                    diff_stat)
import diagrams

ND = 'нет данных'
MP = 'src/main/scala/xiangshan/cache/dcache/mainpipe/'
L2 = 'coupledL2/src/main/scala/coupledL2/'


def verif_summary(C):
    """The 'Итог проверки' cell of the title table, from the results files."""
    out = []
    for cfg, nm in (('k', 'KEEP'), ('s', 'SWEEP')):
        f = C.formal.get(cfg)
        if not f or not f['prove']:
            out.append('формально %s: %s' % (nm, ND))
            continue
        p100 = f['prove'].get(100)
        p16 = f['prove'].get(16)
        mut = f['mutants']
        mt = ('мутантов с контрпримером %d / %d' % (sum(1 for m in mut if m[1] == 'FAIL'), len(mut))) if mut else \
            'мутанты: %s' % ND
        cv = ('cover %d' % f['cover'][1]) if f['cover'] else 'cover: %s' % ND
        out.append('формально %s: prove 100 — %s%s, prove 16 — %s%s; %s; %s' % (
            nm, p100[0] if p100 else ND, (' (%s с)' % C.fnum(p100[1])) if p100 else '', p16[0] if p16 else ND,
            (' (%s с)' % C.fnum(p16[1])) if p16 else '', cv, mt))
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
            dp, d, mc, m, '' if r['complete'] else ' (регрессия не завершена на момент сборки)'))
    else:
        out.append('регрессия: %s' % ND)
    sk, ss = C.soak.get('KEEP'), C.soak.get('CFG_SWEEP')
    if sk and ss:
        out.append('длинный прогон: KEEP %d / %d, SWEEP %d / %d' % (sk['pass'], sk['runs'], ss['pass'], ss['runs']))
    else:
        out.append('длинный прогон: %s' % ND)
    return '; '.join(out)


def front(C):
    s = []
    s.append(P('Сброс XSCore по debug reset: сброс-уровень, сохранение L1D или её обход, ранняя блокировка A, '
               'флаги пустоты', 'title'))
    s.append(P('Подробное описание каждого изменения в XiangShan Kunminghu V2 (версия v5). Сброс приходит от Debug '
               'Module (ndmreset, hartreset) или от кластера и сбрасывает только ядро с L1; L2 и CHI-порт тайла '
               'работают. Параметр CoreResetKeepL1 выбирает: L1D сохраняет строки (Probe ждёт в L2) или перед сбросом '
               'отдаёт их все в L2 обходом (Probe отвечает гейт). Сброс — уровень: ядро в сбросе, пока держат запрос, '
               'не меньше 100 тактов. Каналы A некогерентных агентов закрываются с первого такта sFlush, канал B — '
               'с первого такта sDrain; ожидание в 16 тактов заменено флагами пустоты. Все сигналы из домена сброса '
               'ядра изолированы на стороне тайла.', 'subtitle'))
    st = C.stat
    nf = len(st)
    na = sum(a for _, a, _ in st)
    nd = sum(d for _, _, d in st)
    new_files = 'xiangshan/CoreReset.scala (TLQuiesceGate, TLResetIsolation, CoreResetCtrl), ' \
                'cache/dcache/mainpipe/FlushUnit.scala (L1QuiesceIO, DCacheFlushUnit)'
    rows = [
        ['Что', 'Где'],
        ['XiangShan kunminghu-v2, база 7b16188',
         '%d файлов `src/`, +%d / −%d строк (git diff 7b16188 HEAD); новый патч от c098f99 даёт то же дерево '
         '(изменяемые файлы совпадают)' % (nf, na, nd) if nf else ND],
        ['Порты',
         '`debug_reset` (ndmreset / hartreset), `core_reset_req` (кластер), `core_reset_busy` у XSTile, XSTileWrap и '
         'XSNoCTop; `hartResetReq` с `EnableCoreReset` — тоже `debug_reset`. Порты не изменились относительно v4'],
        ['Параметр `CoreResetKeepL1`',
         '`true` (по умолчанию): L1D сохраняет строки, L2 забирает грязные данные Probe-ом после сброса. `false`: '
         'обход (sweep) — L1D отдаёт каждую строку в L2 (Release / ReleaseData), затем сбрасывается вместе с ядром. '
         'Параметр один: `CoreResetLevel` удалён, сброс всегда уровень'],
        ['Probe во время сброса',
         'KEEP: Probe держится в L2 (гейт: `b.ready` = 0, к ядру `b.valid` = 0) весь сброс; с первого такта sDrain. '
         'SWEEP: в sDrain держится, в сбросе гейт сам отвечает ProbeAck NtoN (с CoupledL2 такой Probe не приходит: '
         'директория L1D не числит)'],
        ['Длина сброса',
         '`rstCycles` = 100 тактов и до снятия запроса (TileLink [TL 1.8.1 3.2.2], 100 тактов с valid = 0)'],
        ['Ранний A, быстрый B',
         'канал A некогерентных агентов (ICache, PTW, i_mmio, d_mmio) закрыт с первого такта sFlush; A l1d — с sDrain; '
         'канал B закрыт с первого такта sDrain (`holdProbe` — функция регистра состояния); выход sFlush ждёт '
         'тишины ранних гейтов (`earlyQuiet`)'],
        ['Флаги пустоты',
         'ожидание 16 тактов подряд заменено четырьмя точными флагами DCache (`mq_empty`, `wbq_empty`, `mp_empty`, '
         '`pq_empty`); выход из sDrain в sReset — в том же такте по `gatesQuiet && l1Done && l1Idle`'],
        ['Изоляция (RDC)',
         'регистр `isolate` (= `closed`), поднятый на том же фронте, что и сброс ядра: маскирует valid и держит '
         'уровни всех сигналов из домена сброса ядра — в гейтах, в `TLResetIsolation`, в XSTile и (KEEP) в записи '
         'массивов L1D (`freeze`)'],
        ['Новые файлы', new_files],
        ['Изменённые файлы',
         'MainPipe (запрос flush, `busy`), Probe.scala (`ProbeQueue.empty`), MissQueue, WritebackQueue, DCacheWrapper '
         '(флаги, `tagArray` на сбросе тайла, маски записи), FakeDCache, MemBlock, XSCore, XSTile, XSTileWrap, XSNoCTop, '
         'Top, SoC, YamlParser. CoupledL2 не меняется'],
        ['Итог проверки', verif_summary(C)],
    ]
    s.append(table(rows, [1.15, 3.85]))
    s.append(Spacer(1, 6))
    s.append(P('<b>Как читать документ.</b> Раздел 1 — задача, один параметр и две конфигурации; что происходит с L1D '
               'в каждой; обход и то, как CoupledL2 принимает Release и ответ на Probe; сброс-уровень (1.4); '
               'раннее закрытие A, быстрое закрытие B и флаги пустоты (1.5); изоляция домена сброса (1.6). Раздел 2 — '
               'понятия TileLink и Debug Module, справочник модулей. Раздел 3 — где изменения. Раздел 4 — '
               'последовательность событий с диаграммами и объяснением, зачем ждать каждого условия. Разделы 5 и 6 — '
               'каждое изменение в коде: фрагмент патча (зелёным — добавленные строки, красным — удалённые, серым — '
               'неизменённый контекст) и объяснение. Раздел 7 — проверка (в том числе временные диаграммы из VCD), '
               'раздел 8 — подключение и выбор конфигурации, раздел 9 — ограничения, раздел 10 — отличия от v4 и '
               'состав пакета. Ссылки на TileLink: синие — версия 1.8.1, зелёные — 1.9.3; номера разделов и страниц '
               'взяты из документа v4.'))
    # important
    elab = C.elab
    if elab:
        el = elab.strip().splitlines()
        elab_txt = 'Полная elaboration XSNoCTop (стенд `verification/elab`, YAML только с ключами сброса): ' + \
                   ' '.join(x.strip() for x in el[:6])
    else:
        elab_txt = 'Полная elaboration XSNoCTop (все соединения XSTile на реальных модулях) не выполнена: ' \
                   'файл результатов `results_elab.txt` отсутствует.'
    s += box('Важно: Chisel компилируется; статус полной elaboration', [
        'Chisel-код v5 компилируется (`mill xiangshan.compile`; проверено на коммитах, перечисленных в '
        '`CLAUDE.md`). <b>Версия v4 не компилировалась:</b> в `TLQuiesceGate(val name: String)` член `name` '
        'конфликтовал с `LazyModule.name`. В v5 поле называется `gateName`.',
        elab_txt + ' Модули `CoreResetCtrl` (KEEP и SWEEP), гейты и изоляция elaborate-ятся стендом '
        '(из его вывода получен RTL для проверки эквивалентности, раздел 7.1); соединения XSTile и DCache в '
        'целом проверены компиляцией и ревью, но не прогоном всего XSNoCTop, пока результата полной elaboration нет.',
    ], 'warn')
    return s


def section1(C):
    s = []
    s.append(Spacer(1, 8))
    s.append(H(1, '1. Задача и общая идея'))
    s.append(P('Нужно сбросить только XSCore — ядро вместе с L1 (DCache, ICache), TLB и PTW, — а L2 (CoupledL2) и '
               'CHI-порт тайла оставить работающими. Сброс приходит от Debug Module (сброс системы `ndmreset` или сброс '
               'харта `hartreset`) или от контроллера сброса кластера. CHI не затрагивается: кредиты, LINKACTIVE и '
               'SYSCO не меняются, кластер сброса не видит.'))
    s.append(P('Ядро и L2 общаются по TileLink (раздел 2.1). Если просто подать сброс работающему ядру, ломаются '
               'четыре вещи:'))
    s += numbered([
        '<b>Незавершённые транзакции.</b> L2 ждёт от ядра GrantAck или ProbeAck, а сброшенное ядро не ответит. '
        'Запись MSHR в L2 висит вечно, вместе с ней и снупы HN. По спецификации менеджер ждёт ProbeAck на каждый '
        'Probe [TL 1.8.1 9.2, с. 67], агент обязан ответить на каждый принятый запрос [TL 1.8.1 5, с. 28], а Grant — '
        'тоже запрос, на него отвечает GrantAck [TL 1.8.1 5.1, с. 29]. Ответ, пришедший после сброса, ядро примет '
        'за ответ на свой новый запрос с тем же source ID: идентификатор занят, пока на запрос не ответили '
        '[TL 1.8.1 6.4, с. 43].',
        '<b>Сообщение «на середине».</b> Строка 64 Б идёт по шине 32 Б двумя тактами передачи (beat). Если сброс '
        'попал между ними, приёмник ждёт второй beat, которого не будет: у CoupledL2 встаёт SinkC. Beat-ы разных '
        'сообщений в канале не перемежаются [TL 1.8.1 4, с. 18], и все beat-ы начатого сообщения должны прийти '
        '[TL 1.8.1 5, с. 28].',
        '<b>L1D и директория L2 расходятся.</b> CoupledL2 инклюзивна: в её директории у каждой строки L1D стоит '
        'бит «копия в L1D» и права этой копии. DCache — write-back: строку с правом T она меняет только у себя. '
        'Если после сброса DCache пуста, грязные данные потеряны, а L2 продолжает считать, что L1 держит строку. '
        'По спецификации права клиента уменьшаются только сообщениями — Release [TL 1.8.1 9.1.1, с. 64] или '
        'ProbeAck в ответ на Probe [TL 1.8.1 9.3.5, с. 76]; сброс L1D не посылает ни того, ни другого. После '
        'AcquirePerm у L2 нет даже старой копии (раздел 1.3.1).',
        '<b>Выходы ядра в момент сброса.</b> Установка сброса асинхронная: регистры ядра сбрасываются не по '
        'фронту такта, и его выходы в домен тайла (valid TileLink, подтверждения MSI, сигналы состояния) '
        'меняются в произвольный момент. Триггер тайла, защёлкнувший такой сигнал, может уйти в метастабильность '
        '(раздел 1.6).',
    ])
    s.append(P('Первые две проблемы решаются одинаково во всех конфигурациях: граница ядро / L2 опустошается до сброса, '
               'и во время сброса через неё ничего не проходит (гейты `TLQuiesceGate`, автомат `CoreResetCtrl`, '
               'автомат `DCacheFlushUnit`). Так спецификация и советует сбрасывать одну сторону связи: через адаптер, '
               'у которого две стороны сбрасываются раздельно, и без запросов без ответа в момент сброса '
               '[TL 1.8.1 3.2.3, с. 14]. Гейт — такой адаптер. Третья проблема решается по-разному — это и выбирает '
               'параметр `CoreResetKeepL1`: L1D либо сохраняет строки, либо перед сбросом отдаёт их все в L2. '
               'Четвёртую решает изоляция: на время сброса все выходы ядра заменяются на стороне тайла значениями, не '
               'зависящими от ядра.'))
    s.append(P('<b>Ссылки на спецификацию.</b> Пометка вида [TL 1.8.1 3.2.2, с. 14] (синяя) — раздел 3.2.2 на '
               'странице 14 спецификации «SiFive TileLink Specification», версия 1.8.1 (2020); [TL 1.9.3 3.2.2, с. 15] '
               '(зелёная) — тот же раздел в последней версии 1.9.3, на странице 15. Цитаты из спецификации даны по-'
               'английски. Все пункты, на которые ссылается документ, — в таблице раздела 2.1; пункты, на которых '
               'держится обход, — ещё и в разделе 1.3.2.'))

    # ------------------------------------------------------------------ 1.1
    s.append(H(2, '1.1. Что изменилось относительно v4; один параметр и две конфигурации'))
    s.append(P('v5 исправляет и упрощает v4 по запросу: убран импульсный сброс; если ядро в сбросе, гейт либо блокирует '
               'транзакцию (L2 ждёт ответ на Probe) при сохранении metaArray, либо сам отвечает при обходе; канал A '
               'некогерентных агентов закрывается как можно раньше (в sFlush); ожидание 16 тактов заменено флагами '
               'пустоты; в sDrain канал B закрывается максимально быстро.'))
    rows = [
        ['Что', 'v4', 'v5'],
        ['Компиляция', 'не компилировалась: `TLQuiesceGate.name` конфликтует с `LazyModule.name`',
         'компилируется; поле называется `gateName`'],
        ['Режимы сброса', 'импульс (100 тактов, sHold, второй импульс) или уровень (`CoreResetLevel`)',
         'только уровень: ≥ `rstCycles` = 100 тактов и до снятия запроса; sHold, второй импульс, `releaseCycles` '
         'и `CoreResetLevel` удалены'],
        ['Состояния `CoreResetCtrl`', 'sIdle, sFlush, sDrain, sReset, sRelease, sHold', 'sIdle, sFlush, sDrain, sReset, '
         'sRelease'],
        ['Канал A', 'все 5 гейтов закрывают A только в sDrain', 'некогерентные (ICache, PTW, i_mmio, d_mmio) — с первого '
         'такта sFlush (`earlyBlock`); l1d — с sDrain (`gateBlock`)'],
        ['Канал B (Probe)', 'держится / отвечается только с sReset', 'закрыт с первого такта sDrain (`holdProbe`); в '
         'sReset и sRelease: держится (KEEP) или отвечает гейт (SWEEP, `ackProbe`)'],
        ['Выход из sFlush', 'по `l1.done`', '`l1Done && earlyQuiet`: тишина ранних гейтов (зависимость Get → Probe в '
         'CoupledL2, 1.5.1)'],
        ['Выход из sDrain', '16 тактов подряд `gatesIdle && l1Done`; `idle` гейта включал `b.valid` L2',
         'в том же такте `gatesQuiet && l1Done && l1Idle`; `QuiesceGateIO` без `idle`, есть только `quiet`'],
        ['Опустошение DCache', 'MissQueue и WBQ пусты 16 тактов подряд', 'флаги пустоты `mq_empty`, `wbq_empty`, '
         '`mp_empty`, `pq_empty` (1.5.3); новое: `MainPipe.busy`, `ProbeQueue.empty` (файл Probe.scala)'],
        ['sRelease', '≥ 8 тактов и `alive`', '`l1.alive` и выход frontend из сброса (`resetInFrontend`), без счётчика'],
        ['Теги L1D при KEEP', 'стирались при каждом сбросе ядра (`TagSRAMBank.rst_cnt`): дефект, найденный ревью',
         '`tagArray` на сбросе тайла вместе с `metaArray` и `errorArray`'],
        ['Параметры', '`CoreResetKeepL1`, `CoreResetLevel`', 'только `CoreResetKeepL1`'],
        ['Порты', '`debug_reset`, `core_reset_req`, `core_reset_busy`', 'без изменений'],
    ]
    s.append(table(rows, [1.0, 2.0, 2.4]))
    s.append(Spacer(1, 6))
    s.append(P('Одна и та же последовательность подходит обеим конфигурациям; различается подготовка L1D и то, что '
               'происходит с Probe, пока ядро в сбросе.'))
    rows = [
        ['', 'CoreResetKeepL1 = true (KEEP)', 'CoreResetKeepL1 = false (SWEEP)'],
        ['L1D после сброса ядра', 'все строки с прежними правами и данными («горячая»)',
         'пуста; всё отдано в L2 до сброса'],
        ['директория L2 после сброса', 'верна: L1D держит то же, что до сброса', 'верна: за L1D не числится ничего'],
        ['домен сброса `metaArray`, `errorArray`, `tagArray`', 'тайла (порт `l1_meta_reset`)', 'ядра — как в upstream'],
        ['подготовка к сбросу', 'опустошение DCache (флаги пустоты): десятки тактов',
         'опустошение и обход: Release / ReleaseData всех действительных строк (≥ 1024 запросов flush) и ожидание '
         'последнего ReleaseAck'],
        ['Probe в sDrain', 'держится в L2 с первого такта (`holdProbe`)', 'держится с первого такта (`holdProbe`)'],
        ['Probe в sReset и sRelease', 'держится в L2 весь сброс; после выхода ядра доходит до DCache и получает ответ '
         'из «горячей» L1D', 'отвечает гейт: ProbeAck NtoN (`ackProbe`)'],
        ['маска записи `freeze` (meta, error, теги, данные)', 'да (`closed`)', 'не нужна (`freeze` = 0)'],
        ['снупы HN во время сброса', 'к строке из L1D ждут конца сброса; к остальным L2 отвечает сама',
         'не ждут (L2 отвечает сама)'],
        ['когда выбирать', 'нужна горячая L1D; при сбросе никто не обращается к кэшируемой этим ядром памяти',
         'отладка через SBA при удержанном сбросе; самая безопасная для отладчика схема'],
    ]
    s.append(table(rows, [1.3, 2.1, 2.1]))
    s.append(P('Параметр имеет смысл только при `EnableCoreReset = true`. Формальная и симуляционная проверка '
               '(раздел 7) проведены для обеих конфигураций.', 'small'))

    # ------------------------------------------------------------------ 1.2
    s.append(H(2, '1.2. CoreResetKeepL1 = true: что в L1D переживает сброс ядра'))
    s.append(P('L1D ничего не забывает при сбросе ядра. Это возможно благодаря устройству DCache: данные лежат в SRAM '
               'без сброса, а состояние строк, флаги ошибок и теги переведены на сброс тайла.'))
    rows = [
        ['Массив DCache', 'Что хранит', 'Реализация', 'Сброс ядра: KEEP', 'Сброс ядра: SWEEP'],
        ['`tagArray`', 'физические теги + ECC', 'SRAM (`shouldReset = false`), но обёртка `TagSRAMBank` имеет '
         'счётчик инициализации `rst_cnt`, который после сброса пишет нули во все наборы',
         '<b>на сбросе тайла</b>: `tagArray.reset := l1_meta_reset`; не меняется; запись под `freeze`',
         'на сбросе ядра, как в upstream (не важно)'],
        ['`bankedDataArray`', 'данные строк', 'SRAM, `shouldReset = false`', 'не меняется (запись под `freeze`)',
         'не меняется (не важно)'],
        ['`metaArray` (L1CohMetaArray)', 'состояние строки N / B / T / Dirty', 'триггеры, `RegInit`',
         'сохраняется (сброс тайла; запись под `freeze`)', '→ N (строки уже отданы)'],
        ['`errorArray` (L1ErrorMetaArray)', 'флаги denied / corrupt от L2', 'триггеры, `RegInit`',
         'сохраняется (сброс тайла; запись под `freeze`)', '→ 0'],
        ['`accessArray`, `prefetchArray`, замещение, WPU', 'подсказки для предвыборки и замещения', 'триггеры',
         '→ 0', '→ 0'],
    ]
    s.append(table(rows, [1.1, 1.0, 1.6, 1.4, 1.0]))
    s.append(Spacer(1, 4))
    s += box('Что нашла проверка: теги стирались (дефект v4, исправлен в v5)', [
        'Ревью Chisel выявило дефект, унаследованный от v4: `TagSRAMBank` — обёртка над SRAM — после сброса её '
        'домена записывает нули во все наборы (счётчик `rst_cnt`, он в домене сброса ядра). При KEEP `metaArray` '
        'сохранялась, а теги стирались при каждом сбросе ядра: строка оставалась «действительной» с тегом 0 — '
        'порча данных. Исправление: `tagArray` — на сброс тайла (`tagArray.reset := r`, DCacheWrapper), как '
        '`metaArray` и `errorArray`. В моделях добавлен мутант `TAG_MUTANT_CORE_RESET` (раздел 7.3).',
    ], 'bad')
    s.append(P('Исходный код счётчика (файл не менялся, `TagArray.scala`):', 'small'))
    s.append(src_anchor('src/main/scala/xiangshan/cache/dcache/meta/TagArray.scala',
                        [('class TagSRAMBank', 0, 0), ('val rst_cnt', 0, 10)]))
    s.append(Spacer(1, 4))
    s.append(P('«Холодной» DCache делает только сброс 2048 бит состояния и счётчика тегов. Если эти биты (и флаги ошибок) '
               'сбрасывать только вместе с тайлом, после сброса ядра DCache видит все свои строки с прежними правами, в '
               'том числе грязные. Директория L2 по-прежнему верна, данные не теряются, кэш остаётся тёплым, а L2 '
               'забирает грязные данные из L1D обычным Probe.'))
    s.append(P('Сбрасываются управляющая логика DCache (MainPipe, MissQueue, WritebackQueue, ProbeQueue) и всё ядро. '
               'Поэтому в момент сброса эта логика должна быть свободна (флаги пустоты, 1.5.3), а Probe от L2, пришедший '
               'во время сброса, должен подождать: ответить на него без L1D нельзя — данные строки, возможно, только '
               'там. Разрешения записи во все четыре массива формирует управляющая логика ядра, поэтому на время '
               'сброса и его снятия они закрыты `freeze` из домена тайла (разделы 1.6 и 5.5). Запись в массивы '
               'данных и meta проходит одну регистровую стадию: этот инвариант нулевого запаса описан в 1.5.3.'))

    # ------------------------------------------------------------------ 1.3
    s.append(H(2, '1.3. CoreResetKeepL1 = false: обход L1D (sweep), затем сброс вместе с ядром'))
    s.append(P('Перед сбросом DCache отдаёт в L2 каждую действительную строку — тем же путём, каким вытесняет строку '
               'при промахе: MainPipe читает тег и состояние строки, посылает добровольный Release (чистая строка) или '
               'ReleaseData (грязная) и в том же такте пишет в `metaArray` состояние N. Обход идёт по всем парам '
               '(набор, путь): 256 наборов × 4 пути = 1024 запроса. Затем DCache сбрасывается вместе с ядром — '
               '`metaArray` и `errorArray` на сбросе ядра, как в upstream. Значит:'))
    s += bullets([
        '<b>Данные не теряются.</b> Грязная строка уходит в L2 сообщением ReleaseData с параметром TtoN, чистая — '
        'Release TtoN (была T) или BtoN (была B) [TL 1.9.3 9.3.10, с. 81], [TL 1.9.3 9.3.11, с. 82]. Строки в '
        'состоянии N обход пропускает: Release с NtoN запрещён [TL 1.9.3 9.3.10, с. 81].',
        '<b>Директория L2 точна.</b> Каждый Release снимает бит клиента; после последнего ReleaseAck CoupledL2 не '
        'числит за L1D ни одной строки (раздел 1.3.3).',
        '<b>Probe во время сброса по-прежнему отвечает гейт:</b> ProbeAck NtoN [TL 1.9.3 9.3.5, с. 78] — правдивый '
        'отчёт пустой L1D. С CoupledL2 такой Probe не приходит: он посылается только строке с битом клиента, а их не '
        'осталось. Ответчик — страховка для менеджера, который пробует клиента без копии (TileLink это допускает, '
        'раздел 1.3.2).',
        '<b>Опустошение границы остаётся</b> — оно нужно протоколу, а не строкам: начатый Acquire должен получить '
        'GrantAck, ReleaseData не должна оборваться между beat-ами, ответ не должен прийти в сброшенное ядро '
        '[TL 1.9.3 3.2.3, с. 15].',
        '<b>Цена — время:</b> около 1024 тактов на запросы flush (один запрос за такт, если MainPipe принимает), Release '
        'только для действительных строк (данные — только у грязных) и ожидание последнего ReleaseAck. После сброса '
        'L1D пуста, первые обращения ядра — промахи; данные L2 получила при обходе.',
    ])
    s.append(table([
        ['', 'CoreResetKeepL1 = true (keep)', 'CoreResetKeepL1 = false (sweep)'],
        ['данные грязных строк', 'остаются в L1D, L2 заберёт их Probe', 'в L2 (ReleaseData при обходе)'],
        ['Probe, пока ядро в сбросе', 'ждёт в L2 (гейт держит канал B)', 'гейт отвечает NtoN (с CoupledL2 не приходит)'],
        ['что переживает сброс ядра', '`metaArray`, `errorArray`, `tagArray` (сброс тайла); данные (SRAM, запись под '
         '`freeze`)', 'ничего (как в upstream)'],
    ], [1.2, 2.2, 2.2]))

    s.append(H(3, '1.3.1. Почему полный сброс L1D невозможен: AcquirePerm'))
    s.append(P('Если L1D просто сбросить вместе с ядром (без обхода), строки и грязные данные теряются, а устаревшую '
               'директорию L2 исправлял бы первый Probe (ответ NtoN). Это корректно, только если у L2 есть '
               'действительная, пусть и старая, копия каждой строки L1D. DCache XiangShan этого не гарантирует: запись '
               'целой строки при промахе получает права без данных — сообщением AcquirePerm.'))
    s.append(P('XiangShan, cache/dcache/mainpipe/MainPipe.scala: промах записи, покрывающей всю строку', 'small'))
    s.append(src_anchor(MP + 'MainPipe.scala', [('miss_req.full_overwrite :=', 0, 0)]))
    s.append(P('XiangShan, cache/dcache/mainpipe/MissQueue.scala: AcquirePerm вместо AcquireBlock', 'small'))
    s.append(src_anchor(MP + 'MissQueue.scala', [('val acquirePerm = edge.AcquirePerm', 0, 7),
                                                  ('io.mem_acquire.bits := Mux(full_overwrite', -0, 0)]))
    s.append(P('`full_overwrite` — запись из sbuffer покрывает все 64 байта строки (`store_mask.andR`). Тогда MissEntry '
               'посылает AcquirePerm (право T без данных), получает Grant без данных и пишет строку целиком: в L1D '
               'строка Dirty, а у L2 действительных данных нет. CoupledL2 поступает так же: AcquirePerm превращается в '
               'CHI MakeUnique (права без данных), и в DataStorage ничего не пишется:'))
    s.append(P('coupledL2/tl2chi/MSHR.scala: AcquirePerm → MakeUnique; Grant без записи DataStorage', 'small'))
    s.append(src_anchor(L2 + 'tl2chi/MSHR.scala', [('AcquirePerm NtoT', 0, 1), ('mp_grant.tagWen :=', 0, 1)]))
    s.append(P('`dsWen` задачи Grant равен 1 только при `gotGrantData` (данные пришли от HN) — у MakeUnique их нет. Тег '
               'пишется (`tagWen`), директория получает TRUNK с битом клиента, а в DataStorage остаётся содержимое '
               'пути от прежней строки — данные другого адреса. Спецификация прямо требует от менеджера помнить об '
               'этом:'))
    s.append(table([
        ['Пункт TileLink 1.9.3', 'Текст'],
        ['[TL 1.9.3 9.3.2, с. 75] AcquirePerm', '«AcquirePerm must be only used in situations where no copy of the data is '
         'required to complete the initiating operation. The primary example is the case where the block is being '
         'acquired in order to be entirely overwritten.» «For a Slave Agent to maintain coherence on a block after '
         'AcquirePerm, the Slave Agent must track "data not valid" until the Master Agent performs an evict using '
         'ReleaseData, responds with ProbeAckData to a ProbeBlock, or writes all bytes dirty in the whole block using '
         'PutFullData.»'],
        ['[TL 1.9.3 9.3.6, с. 79] ProbeAckData', '«It is illegal to use the NtoN permission transition in a ProbeAckData '
         'message, as it is illegal for a Master Agent to hold dirty data in the N state.»'],
    ], [1.3, 4.2]))
    s.append(Spacer(1, 4))
    s.append(P('Полный сброс L1D нарушает этот договор. Единственная действительная копия строки — грязная строка в '
               'L1D — исчезает без ReleaseData и без ProbeAckData. L1D после сброса действительно в N и на Probe честно '
               'отвечает NtoN, но L2 ждёт данных («data not valid»). По ProbeAck NtoN CoupledL2 переводит строку '
               'TRUNK → TIP (шаг 6 раздела 1.3.4) и с этого момента считает своей копией то, что лежит в DataStorage, — '
               'данные другого адреса. Дальше они уйдут HN в ответе на снуп или при вытеснении либо ядру в GrantData: '
               'тихая порча памяти, а не просто потеря последних записей. Поэтому вариант без KeepL1 — обход: строка '
               'после AcquirePerm грязная и уходит в L2 ReleaseData, как и требует [TL 1.9.3 9.3.2, с. 75].'))
    s += box('Почему так: обход, а не полный сброс или «сброс с правкой директории»', [
        'Исправить это на стороне L2 (например, считать NtoN на строку TRUNK признаком потери данных) нельзя: данных всё '
        'равно нет нигде. Обход сохраняет и данные, и протокол: он пользуется только обычными сообщениями TileLink '
        '(Release, ReleaseData) и обычным путём вытеснения MainPipe, без изменений в CoupledL2. Цена — около тысячи '
        'тактов до сброса и небольшое изменение MainPipe (раздел 5.5). Проверка v4 этого не ловила: модель DCache '
        'промахивалась только AcquireBlock. Теперь модель DCache шлёт AcquirePerm на промах записи всей строки, а '
        'модель L2 после такого Grant помечает свою копию недействительной (poison) и сообщает об ошибке, если когда-'
        'нибудь её отдаст.',
    ])

    s.append(H(3, '1.3.2. На какие пункты спецификации TileLink опирается обход'))
    s.append(P('Пункты TileLink 1.9.3 — последней версии (зелёные ссылки; страницы — по PDF), в скобках — тот же пункт '
               'версии 1.8.1 (синие ссылки), если он там есть. Цитаты дословные.'))
    rows = [
        ['Утверждение', 'Пункт', 'Текст спецификации'],
        ['Release — добровольный запрос мастера на понижение прав; параметр — Shrink или Report без NtoN',
         '[TL 1.9.3 9.3.10, с. 81], табл. 41', '«A Release message is a request message used by a Master Agent to voluntarily '
         'downgrade its permissions on a cached data block.» c_param: «Shrink (TtoB, TtoN, BtoN) or Report sans NtoN '
         '(TtoT, BtoB).»'],
        ['Строку в N обход не трогает: Release NtoN запрещён', '[TL 1.9.3 9.3.10, с. 81]', '«It is illegal to use the NtoN '
         'permission transition in a Release message, as a Master Agent with no permission to a block should have no '
         'reason to report on its permission to that block.»'],
        ['Грязная строка — ReleaseData, тоже без NtoN', '[TL 1.9.3 9.3.11, с. 82]', '«A ReleaseData message is a request '
         'message used by a Master Agent to voluntarily downgrade its permissions on a cached data block. and write '
         'back dirty data to the managing Slave Agent.»'],
        ['Строка после AcquirePerm перестаёт быть «data not valid» именно по ReleaseData', '[TL 1.9.3 9.3.2, с. 75]',
         '«until the Master Agent performs an evict using ReleaseData»'],
        ['На каждый Release менеджер отвечает ReleaseAck; обход ждёт последнего', '[TL 1.9.3 9.3.12, с. 82]',
         '«A ReleaseAck message is a response message used by a Slave Agent to acknowledge the receipt of a '
         'Release[Data], and is in turn used to ensure global serialization of operations by the Slave Agent.»'],
        ['После Release мастер не отвечает на Probe к этой строке и не шлёт по ней Acquire до ReleaseAck',
         '[TL 1.9.3 9.2, с. 70] ([TL 1.8.1 9.2, с. 69])', '«Once the Release is issued, the master should not issue a '
         'ProbeAck, ProbeAckData, Acquire, Get, Put, ArithmeticData, LogicalData, or further Release on the block '
         'until it receives a ReleaseAck from the slave acknowledging completion of the writeback.»'],
        ['Гонка Release и Probe: менеджер принимает и Release, и обогнавший ProbeAck', '[TL 1.9.3 9.2, с. 71] '
         '([TL 1.8.1 9.2, с. 69])', '«The slave must accept the voluntary Release as well as any overtaken ProbeAcks '
         'resulting from Probe messages that have already been processed by the master before the Release was sent»'],
        ['Ответ гейта в сбросе: NtoN — Report, допустим на любой Probe', '[TL 1.9.3 9.3.5, с. 78], табл. 36',
         'c_param: «Shrink (TtoB, TtoN, BtoN) or Report (TtoT, BtoB, NtoN).» «the latter reports what they were and '
         'continue to be.»'],
        ['Сбросить одну сторону связи можно через адаптер и без запросов без ответа', '[TL 1.9.3 3.2.3, с. 15] '
         '([TL 1.8.1 3.2.3, с. 14])', '«a TileLink-to-TileLink adapter is needed which acts as a slave in one domain '
         'and a master in the other domain.» «ensure that there are no unanswered TileLink requests when one half of '
         'the crossing is reset or depowered.»'],
        ['Сброс связи: valid = 0 не меньше 100 тактов', '[TL 1.9.3 3.2.2, с. 15] ([TL 1.8.1 3.2.2, с. 14])',
         '«The valid signals must be driven LOW for at least 100 cycles while reset is asserted.» «Ready, control, and '
         'data signals are free to take any value during reset.»'],
    ]
    s.append(table(rows, [1.5, 1.35, 3.0]))

    s.append(H(3, '1.3.3. Как CoupledL2 принимает Release и ReleaseData обхода'))
    s.append(P('Для L2 обход — серия обычных добровольных вытеснений из L1D. Путь: SinkC (канал C) → RequestArb → '
               'MainPipe банка; ответ ReleaseAck уходит через GrantBuffer в канал D. Код — CoupledL2 55d8e69, вариант '
               'tl2chi (номера строк — по этой ревизии).'))
    s.append(P('coupledL2/SinkC.scala: Release(Data) — в буфер задач, данные — в dataBuf', 'small'))
    s.append(src_anchor(L2 + 'SinkC.scala', [('val isRelease = io.c.bits.opcode(1)', 0, 1),
                                              ('when (io.c.fire && isRelease) {', 0, 12),
                                              ('when (io.c.fire && isRelease && last)', 0, 10)]))
    s.append(P('coupledL2/tl2chi/MainPipe.scala: директория, DataStorage и ReleaseAck для Release(Data)', 'small'))
    s.append(src_anchor(L2 + 'tl2chi/MainPipe.scala', [('sink_resp_s3.bits.opcode := ReleaseAck', 1, 1),
                                                        ('val wen_c = sinkC_req_s3', 0, 0),
                                                        ('val metaW_s3_c = MetaEntry(', 0, 8)]))
    s += bullets([
        '`isRelease = opcode(1)` (Release 6, ReleaseData 7): сообщение становится задачей MainPipe, данные '
        'ReleaseData — в `dataBuf` (оба beat-а). Ответы на Probe (opcode 4, 5) идут другим путём — откликом MSHR '
        '(раздел 1.3.4).',
        '`metaW_s3_c` — новая запись директории: `clients = !isToN(param)` — для TtoN и BtoN бит L1D снимается; '
        '`state` — TIP, если L1D отдаёт T, иначе прежнее; `dirty` — если пришли данные (`wen_c`).',
        '`wen_c` — запись в DataStorage: ReleaseData от владельца T с попаданием в директорию. Так L2 получает '
        'последние данные строки, в том числе строки, взятой AcquirePerm («data not valid» снят, '
        '[TL 1.9.3 9.3.2, с. 75]).',
        'Ответ — `sink_resp_s3` с `opcode = ReleaseAck`, `param = 0`. По нему DCache освобождает запись WritebackQueue; '
        'обход `DCacheFlushUnit` ждёт, пока WBQ пуста (`idle`).',
        'После обхода у каждой строки, которую держала L1D, бит клиента снят — директория L2 точна, и снупы HN к этим '
        'строкам L2 обслуживает сама, без Probe.',
    ])

    s.append(H(3, '1.3.4. Как и в каких модулях CoupledL2 обрабатывает ответ на Probe'))
    s.append(P('Ответы на Probe нужны обеим конфигурациям: во время опустошения и обхода Probe обслуживает DCache '
               '(ProbeAck или ProbeAckData), а пока ядро в сбросе, Probe либо ждёт (KEEP), либо получает ответ гейта '
               '(SWEEP, NtoN). L2 состоит из нескольких банков (Slice); Probe и ответ на него обрабатывает банк, '
               'которому принадлежит адрес строки.'))
    s.append(table([
        ['Модуль (файл)', 'Роль в обработке ProbeAck'],
        ['MainPipe (tl2chi/MainPipe.scala)', 'по записи директории решает, нужен ли Probe, и выделяет MSHR; заранее '
         'копирует строку из DataStorage в releaseBuf; в конце пишет директорию и данные и отправляет ответ HN'],
        ['MSHR (tl2chi/MSHR.scala, 16 штук)', 'ведёт транзакцию: выставляет Probe, ждёт ProbeAck, по нему меняет свою '
         'копию записи директории (meta), затем ставит задачу в MainPipe'],
        ['SourceB (SourceB.scala, внутри MSHRCtl)', 'очередь Probe в канал B на 4 записи; не пускает Probe к строке, '
         'на Grant которой ещё нет GrantAck'],
        ['SinkC (SinkC.scala)', 'приёмник канала C: ProbeAck и ProbeAckData превращает в отклик `resp`, данные '
         'ProbeAckData — в запись releaseBuf'],
        ['MSHRCtl (tl2chi/MSHRCtl.scala)', 'по адресу находит MSHR, которая ждёт ответа, передаёт ей отклик и даёт '
         'номер записи releaseBuf'],
        ['releaseBuf (MSHRBuffer.scala)', 'по строке данных на каждую MSHR: сначала копия из DataStorage, '
         'ProbeAckData её перезаписывает; отсюда берутся данные для ответа HN, вытеснения или Grant'],
    ], [1.5, 3.9]))
    s.append(Spacer(1, 4))
    s.append(diagrams.sequence('Пример: снуп SnpUnique от HN к строке, которую директория числит за L1D, и ответ NtoN',
                               ['HN (CHI)', 'MainPipe L2', 'MSHR', 'SourceB', 'SinkC, MSHRCtl', 'гейт l1d / DCache'], [
        ('msg', 0, 1, 'SnpUnique (RXSNP → RequestArb)', diagrams.BLUE, None),
        ('msg', 1, 2, 'шаг 1: s3: клиент есть → MSHR; строка → releaseBuf', diagrams.INK, None),
        ('msg', 2, 3, 'шаг 2: задача Probe toN', diagrams.INK, None),
        ('msg', 3, 5, 'Probe toN (канал B), если нет Grant без GrantAck', diagrams.GREEN, None),
        ('msg', 5, 4, 'шаг 3: ProbeAck NtoN (канал C): гейт (sweep, сброс) или DCache', diagrams.GREEN, None),
        ('msg', 4, 2, 'шаги 4–5: resps.sinkC (по адресу)', diagrams.INK, None),
        ('msg', 2, 2, 'шаг 6: клиентов 0, TRUNK → TIP', diagrams.INK, None),
        ('msg', 2, 1, 'шаг 7: задача mp_probeack', diagrams.INK, None),
        ('msg', 1, 0, 'шаг 8: SnpResp / SnpRespData (данные L2)', diagrams.BLUE, None),
    ]))
    s.append(cap('Рис. 1. Путь Probe и ответа на него в банке CoupledL2. Остальные источники Probe (вытеснение из L2, '
                 'Get от ICache, alias, CBO) идут тем же путём; отличается задача MSHR на шаге 7.'))
    s.append(P('<b>Шаг 1. Нужен ли Probe — MainPipe, стадия s3.</b>', 'body'))
    s.append(src_anchor(L2 + 'tl2chi/MainPipe.scala', [('val need_probe_s3_a =', 0, 5),
                                                        ('val need_pprobe_s3_b_snpToN =', 0, 5)]))
    s += bullets([
        '`need_pprobe_s3_b_snpToN` — снуп HN, который отнимает строку: Probe нужен, если строка есть в директории и у '
        'неё есть клиент. Снупы, понижающие до B, и SnpOnce / Query / Stash шлют Probe только строке TRUNK.',
        '`need_probe_s3_a` — Get (ICache, PTW) или CBO к строке с клиентом; для Get и CBOClean — только TRUNK: L2 нужна '
        'последняя копия. Это зависимость Get → Probe, из-за которой выход sFlush ждёт тишины ранних гейтов (1.5.1).',
        'Вытеснение из L2: MSHR промаха получает от директории жертву; если у жертвы есть клиент — `s_rprobe = 0`.',
        '`need_write_releaseBuf`: если клиент может ответить без данных, MainPipe заранее читает строку из DataStorage '
        'и пишет её в releaseBuf своей MSHR: на ProbeAck без данных releaseBuf уже держит копию L2.',
    ])
    s.append(P('<b>Шаги 2–3. Probe в канал B — MSHR, MSHRCtl, SourceB; ответ — гейт или DCache.</b>'))
    s.append(src_anchor(L2 + 'tl2chi/MSHR.scala', [('io.tasks.source_b.valid :=', 0, 0), ('val b_task = {', 0, 22)]))
    s.append(src_anchor(L2 + 'SourceB.scala', [('val conflictMask =', 0, 4), ('p.rdy := RegNext(true.B)', 1, 1)]))
    s += bullets([
        '`b_task.param`: для снупа — по типу снупа (toB, toN, иначе toT); для Get и CBOClean к TRUNK — toB; для '
        'вытеснения, alias и остальных CBO — toN.',
        'SourceB держит Probe (`rdy = 0`), пока по той же строке есть Grant без GrantAck: «Once the Grant is issued, the '
        'slave should not issue Probes on that block until it receives a GrantAck.» [TL 1.8.1 9.2, с. 68].',
        'Ответ: вне сброса отвечает DCache (ProbeQueue → MainPipe → WritebackQueue; для строки, которой нет, — ProbeAck '
        'NtoN); в сбросе (SWEEP) гейт l1d формирует `edgeOut.ProbeAck(probe, NtoN)` по [TL 1.9.3 9.3.5, с. 78]. '
        'CoupledL2 source ответа не смотрит (шаги 4 и 5), поэтому оба варианта равноценны.',
    ])
    s.append(P('<b>Шаги 4–5. Приём ответа — SinkC; чей это ответ — MSHRCtl.</b>'))
    s.append(src_anchor(L2 + 'SinkC.scala', [('io.resp.valid := io.c.valid', 0, 6), ('val probeAckDataBuf = RegEnable', 0, 6),
                                              ('io.c.ready := !isRelease', 0, 0)]))
    s.append(src_anchor(L2 + 'tl2chi/MSHRCtl.scala', [('val resp_sinkC_match_vec', 0, 4), ('io.releaseBufWriteId :=', 0, 0)]))
    s += bullets([
        '`io.c.ready` для ProbeAck всегда 1 (`!isRelease`): SinkC никогда не задерживает ответы на Probe.',
        '`io.resp` комбинационный: из адреса — tag и set; opcode, param; `last`; `dirty = opcode(0)`; `denied` и '
        '`corrupt` — из `c.corrupt`. Поля source и size не используются.',
        'MSHR ищется по адресу, не по source: она занята, ждёт ответа на канале C (`w_c_resp`), совпадают набор и тег. '
        'Данные ProbeAckData пишутся в releaseBuf записи, найденной тем же вектором совпадений.',
    ])
    s.append(P('<b>Шаг 6. Что меняет ответ — MSHR, обработка c_resp.</b>'))
    s.append(src_anchor(L2 + 'tl2chi/MSHR.scala', [('val c_resp = io.resps.sinkC', 0, 24)]))
    s.append(src_anchor(L2 + 'Consts.scala', [('def isToN(param: UInt)', 0, 9)]))
    s += bullets([
        'Любой ProbeAck(Data) ставит `w_*probeackfirst/last`. ProbeAckData: `probeDirty = 1`, `meta.dirty = 1`.',
        '`isToN(param)` — TtoN, BtoN и NtoN: бит клиента снимается, TRUNK → TIP (L2 — единственный владелец). После '
        'NtoN L2 продолжает со своей копией — поэтому эта копия обязана быть верной; после AcquirePerm без '
        'ReleaseData это не так (раздел 1.3.1).',
    ])
    s.append(table([
        ['Ответ клиента', 'meta.clients', 'meta.state', 'Данные в releaseBuf'],
        ['ProbeAck NtoN (гейт, пустая DCache)', '0', 'TRUNK → TIP, иначе как было', 'копия из DataStorage'],
        ['ProbeAck TtoN (чистая T)', '0', 'TRUNK → TIP', 'копия из DataStorage'],
        ['ProbeAck BtoN', '0', 'как было (TIP / BRANCH)', 'копия из DataStorage'],
        ['ProbeAckData TtoN (грязная)', '0', 'TRUNK → TIP; `probeDirty = 1`', 'данные L1D'],
        ['ProbeAck(Data) TtoB, BtoB', '1', 'TRUNK → TIP', 'с данными — L1D, иначе копия'],
    ], [2.2, 0.9, 1.7, 1.3]))
    s.append(Spacer(1, 4))
    s.append(P('<b>Главное следствие.</b> Для MSHR ответ NtoN неотличим от ответа чистой L1D, которая отдала строку T без '
               'данных (TtoN): одна и та же ветка кода — L2 продолжает со своей копией. Это безопасно, только если '
               'копия L2 актуальна. В режиме sweep так и есть: всё, что L1D меняла, она отдала ReleaseData до сброса, '
               'а после обхода директория её вообще не числит.'))
    s.append(P('<b>Шаги 7–8. Задача MSHR в MainPipe и запись директории.</b> Ни одна задача, зависящая от ответа, не '
               'начнётся до него: ответ HN (`mp_probeack_valid`) ждёт `w_pprobeacklast`; вытеснение и Grant — '
               '`w_rprobeacklast`. Для отнимающего снупа строка становится INVALID, клиентов нет; для понижающего — '
               'BRANCH. Грязность после NtoN — только грязность L2; `dsWen = 0` без `probeDirty`, DataStorage не пишется; '
               'данные для HN читаются из releaseBuf (копия L2). Ответ — SnpResp или SnpRespData с данными L2.'))
    s.append(src_anchor(L2 + 'tl2chi/MSHR.scala', [('val mp_probeack_valid =', 0, 0), ('mp_probeack.dsWen :=', 0, 0)]))
    s += box('Почему гейт по-прежнему отвечает NtoN, если с CoupledL2 Probe не придёт', [
        'Гейт — адаптер на границе сброса [TL 1.9.3 3.2.3, с. 15]: он не должен полагаться на то, как устроен '
        'менеджер. TileLink разрешает Probe клиенту без копии, ответ — Report NtoN [TL 1.9.3 9.3.5, с. 78]; держать '
        'такой Probe весь сброс (а сброс держат сколько угодно) значило бы задерживать снуп HN без причины. Ответ '
        'пустой L1D известен заранее, и гейт даёт его сам. В проверке L2 нарочно иногда пробует строки, которых нет '
        'в директории (раздел 7.3).',
    ])

    # ------------------------------------------------------------------ 1.4
    s.append(H(2, '1.4. Сброс-уровень: ядро в сбросе, пока держат запрос'))
    s.append(P('Debug Module держит `ndmreset` или `hartreset` столько, сколько решит отладчик: бит в `dmcontrol` '
               'остаётся 1, пока отладчик не запишет 0 (это могут быть миллионы тактов). Контроллер держит '
               '`coreReset`, пока запрос высокий, но не меньше `rstCycles` = 100 тактов, и отпускает ядро один раз — '
               'после снятия запроса. Состояния sHold и второго импульса нет.'))
    s += bullets([
        '<b>Probe с KEEP</b> держится в L2 — не только в сбросе, а с первого такта sDrain — и доходит до DCache после '
        'выхода ядра из сброса. Грязная строка отвечает ProbeAckData из «горячей» L1D.',
        '<b>Probe со SWEEP</b> в sDrain держится (DCache ещё есть, но новый Probe ей уже не нужен: строки отданы), в '
        'sReset и sRelease гейт сам отвечает ProbeAck NtoN. Снупы HN L2 обслуживает сама (директория L1D не числит); '
        'риска блокировки нет.',
        '<b>Что исчезло:</b> состояние sHold (ядро вне сброса, но стоит), второй импульс после снятия запроса, '
        '`releaseCycles` (≥ 8 тактов в sRelease), `CoreResetLevel`, счётчики 16 тактов тишины.',
        'Ядро стартует ровно после снятия запроса и с текущим reset vector.',
    ])
    s += box('Почему так: с KEEP ожидание Probe в сбросе допустимо, но у него есть цена', [
        'Пока `ready` = 0, beat просто не принят [TL 1.8.1 4.1, с. 18]; длину ожидания спецификация не ограничивает, но '
        'требует, чтобы предложенный beat когда-нибудь был принят, если его не задерживает сообщение с более высоким '
        'приоритетом (правило 3.i, [TL 1.8.1 5, с. 28]). Здесь оно выполняется, если запрос когда-нибудь снимут. '
        'Есть и системное ограничение: снуп HN, ждущий Probe, держит запись в HN, а с ней — всех, кто обращается к '
        'той же строке. Если снятие запроса зависит от такой строки (запись через SBA отладчиком), ожидание '
        'бесконечно — взаимная блокировка: отладчик держит сброс и пишет программу в память через системную шину DM; '
        'адрес лежит в L1D; HN шлёт снуп, L2 — Probe; Probe ждёт в гейте, пока ядро в сбросе; запись SBA ждёт снуп; '
        'отладчик ждёт запись и не снимает сброс. Поэтому с KEEP ответственность за то, чтобы никто не ждал строку L1D '
        'во время сброса, лежит на системе; для отладки через SBA есть SWEEP (раздел 8).',
    ], 'warn')

    # ------------------------------------------------------------------ 1.5
    s += section15(C)
    s += section16(C)
    return s


def section15(C):
    s = []
    s.append(H(2, '1.5. Раннее закрытие A, быстрое закрытие B, флаги пустоты'))
    s.append(P('Три решения v5, которые сокращают подготовку к сбросу и делают её точной. Диаграмма — в 4.1; '
               'сигналы автомата — в 4.4; временные диаграммы реальных прогонов — в 7.4.'))
    s.append(H(3, '1.5.1. Некогерентные агенты: A закрыт с первого такта sFlush; зависимость Get → Probe'))
    s.append(P('ICache, PTW, `i_mmio` и `d_mmio` — некогерентные клиенты (TL-UL: только каналы A и D). Их запросы после '
               'сброса никому не нужны, а начатый запрос должен получить ответ до сброса. Поэтому гейты этих рёбер '
               '(`early = true`) закрывают канал A с первого такта sFlush (`earlyBlock` = состояние ≠ sIdle) — на границе '
               'сообщения, чтобы не оборвать многобитное Put. Гейт l1d (TL-C) закрывает A только с sDrain: в sFlush '
               'DCache ещё делает Release (обход) и отвечает на Probe.'))
    s.append(P('<b>Зависимость Get → Probe в CoupledL2.</b> Get некогерентного агента к строке, которую L1D держит в '
               'TRUNK / TIP, ждёт в L2 Probe toB к L1D (`need_probe_s3_a`, 1.3.4). Значит, пока у некогерентного агента '
               'открыт хоть один Get, канал B закрывать нельзя: Probe не дойдёт, Get не получит ответа, а сброс без '
               'ответа на Get недопустим. Поэтому выход из sFlush ждёт `earlyQuiet` (все ранние гейты quiet) — и '
               'только после этого B закрывается (в sDrain). Это одна из причин, по которой B нельзя закрыть вместе с '
               'ранним A.'))
    s += box('Почему так: A некогерентных — рано, B — только после их тишины', [
        'Закрыть A некогерентных с первого такта безопасно и полезно: новые запросы только удлиняли бы '
        'опустошение. Нельзя то же самое сделать с B и с A l1d: L1D ещё должна ответить на Probe (в том числе по '
        'требованию незавершённого Get) и вернуть Release. Мутант `NO_EARLY_BLOCK` (A не закрыт рано) ловится '
        'свойством P9 и симуляцией; мутант `NO_EARLY_QUIET` (выход из sFlush без тишины ранних гейтов) — P10.',
    ])
    s.append(H(3, '1.5.2. B закрыт с первого такта sDrain; решение по quiet текущего такта'))
    s.append(P('`holdProbe` — комбинационная функция регистра состояния (`state === sDrain` или `closed`), поэтому '
               'канал B закрывается в первом же такте sDrain, а не на такт позже, когда «решение» дошло бы через '
               'регистр. Гейт снимает `b.ready` к L2 и `b.valid` к ядру в том же такте; снятие `valid` непринятого '
               'beat-а законно: «a sender may raise valid and then lower it on the following cycle, even if the message '
               'was not accepted on the previous cycle.» [TL 1.8.1 4.1, с. 19]. L2 продолжает предлагать Probe (SourceB '
               'держит его), и он будет принят после сброса (KEEP) или получит ответ гейта (SWEEP).'))
    s.append(P('Решение sDrain → sReset принимается по `quiet` <b>текущего такта</b> (`gatesQuiet && l1Done && l1Idle`, '
               'комбинационно из счётчиков гейтов), а не по регистровому значению: иначе Probe, принятый в последнем '
               'такте sFlush, проскакивает (мутант `STALE_QUIET`). Что остаётся открытым в sDrain: только Probe, принятый '
               'гейтом l1d в последнем такте sFlush — его ProbeAck идёт через буфер `l1d_to_l2_buffer` (между DCache и '
               'гейтом), счётчик `probes` гейта его видит, и sDrain ждёт его (диаграмма 7.4, случай 5).'))
    cv = C.cov.get('KEEP')
    cs = C.cov.get('CFG_SWEEP')
    def dr(c, k):
        return str(c.get(k)) if c and k in c else ND
    s.append(table([
        ['Из длинных прогонов (soak), число', 'KEEP', 'SWEEP'],
        ['фаз sDrain', dr(cv, 'drain.sDrain-phases'), dr(cs, 'drain.sDrain-phases')],
        ['самая длинная sDrain, тактов', dr(cv, 'drain.longest-sDrain'), dr(cs, 'drain.longest-sDrain')],
        ['Probe удержано в sDrain', dr(cv, 'drain.probes-held-in-sDrain'), dr(cs, 'drain.probes-held-in-sDrain')],
        ['Get, ждавших Probe (get-probes)', dr(cv, 'drain.get-probes'), dr(cs, 'drain.get-probes')],
        ['направленный Probe в 1-м такте sDrain: предложен в sDrain / позже', '%s / %s' % (
            dr(cv, 'dir.drain_first_cycle.offered'), dr(cv, 'dir.drain_first_cycle.later')), '%s / %s' % (
            dr(cs, 'dir.drain_first_cycle.offered'), dr(cs, 'dir.drain_first_cycle.later'))],
        ['направленный Probe в последнем такте sFlush: попал / позже', '%s / %s' % (
            dr(cv, 'dir.flush_last_cycle.offered'), dr(cv, 'dir.flush_last_cycle.later')), '%s / %s' % (
            dr(cs, 'dir.flush_last_cycle.offered'), dr(cs, 'dir.flush_last_cycle.later'))],
    ], [3.0, 1.2, 1.2]))
    s.append(P('Обычно sDrain длится 1 такт (флаги пустоты уже подняты в sFlush); с Probe последнего такта sFlush — '
               'пока его ProbeAck(Data) пройдёт через буфер C; с медленной L2 — до десятков тактов. Числа — из файлов '
               '`coverage_*.json` (сумма по прогонам сценариев 1–7 в модели).', 'small'))
    s.append(H(3, '1.5.3. Флаги пустоты вместо 16 тактов'))
    s.append(P('В v4 DCache и контроллер ждали 16 тактов подряд тишины, чтобы поймать «окна», в которых признак пустоты '
               'мог на такт оказаться ложным. В v5 каждая часть управляющей логики DCache даёт <b>точный</b> признак: '
               'что-то находится в ней ровно тогда, когда признак низкий. Тогда ждать нечего.'))
    s.append(table([
        ['Флаг', 'Структура и выражение', 'Почему точен'],
        ['`mq_empty`', 'MissQueue: `!busy_i` по 16 записям (`busy = req_valid`), `!miss_req_pipe_reg.reg_valid()`, '
         '`cmo_unit.io.req.ready`', 'запись занята с приёма промаха до установки строки и GrantAck; регистр '
         'между приёмом и записью (в нём запрос между «разрешён» и «занял запись») учтён отдельно; CMO — в unit'],
        ['`wbq_empty`', 'WritebackQueue: `!block_addr.valid_i` по записям (`state =/= s_invalid`)', 'запись живёт от '
         'приёма Release / ProbeAck до ReleaseAck (Release) или последнего beat (ProbeAck): пуста — значит все Release '
         'подтверждены, все ProbeAck отправлены'],
        ['`mp_empty`', 'MainPipe: `!(s1_valid || s2_valid || s3_valid)` (`MainPipe.io.busy`)', 'запрос, принятый '
         'на s0, покидает свою очередь на том же фронте, на котором встаёт `s1_valid`: между очередью и стадиями '
         'запроса нет; значит, запись из sbuffer / AMO / Probe / flush учтена либо очередью, либо `busy`'],
        ['`pq_empty`', 'ProbeQueue: `!block_addr.valid_i` по записям и `!selected_req_valid` (`ProbeQueue.empty`)',
         'Probe находится в записи или в регистре выбора перед MainPipe — других мест нет'],
    ], [0.8, 2.3, 2.7]))
    s.append(Spacer(1, 4))
    s.append(P('`DCacheFlushUnit.idle` = все четыре флага. Выходы: sDrain → sSweep / sDone по `idle`; sWait → sDone по '
               '`inflight === 0 && idle`; `l1.idle` = `idle` — в контроллере. Новые места состояния в DCache, которые '
               'держат что-либо до сброса, требуют собственного флага (раздел 9).'))
    s += box('Инвариант нулевого запаса: запись в массивы данных и meta и момент coreReset', [
        'Флаги не покрывают одну регистровую стадию записи массивов данных (`BankedDataArray`) и meta '
        '(`AsynchronousMetaArray`): запись, вызванная `s3_fire` в предыдущем такте, фиксируется в массиве на фронте, '
        'который заканчивает такт решения. Это тот же фронт, на котором поднимается регистр `coreReset`, а установка '
        'сброса асинхронна: запись успевает пройти до сброса. Следствие: между решением sDrain → sReset и поднятием '
        '`coreReset` нельзя добавлять задержку (регистр, ожидание) — запись попала бы под сброс (KEEP: испорченная '
        'строка переживает сброс). Инвариант записан в комментариях `CoreResetCtrl` и `DCacheFlushUnit`.',
        '`l1.idle` в контроллере с нынешним DCache избыточен (в sDone занят может быть только путь Probe, а каждый '
        'Probe считает гейт): он оставлен как прямое требование — свойство P19; мутант `NO_L1_IDLE` ожидаемо '
        'эквивалентен в симуляции.',
    ], 'warn')
    return s


def section16(C):
    s = []
    s.append(H(2, '1.6. Изоляция домена сброса ядра (пересечение доменов сброса)'))
    s.append(P('Сброс ядра формирует ResetGen: `withClockAndReset(clock, (coreBaseReset || coreReset).asAsyncReset) '
               '{ ResetGen() }`. Его установка асинхронная: регистр `coreReset` контроллера переключается по фронту '
               'такта, а дальше сброс идёт по дереву без участия такта — через асинхронные входы триггеров ResetGen '
               'XSTile и следующих ResetGen внутри ядра (MemBlock → Backend → Frontend). Синхронизировано только снятие. '
               'Значит, после фронта, на котором поднялся `coreReset`, регистры XSCore сбрасываются в разные, заранее не '
               'известные моменты, а вместе с ними меняются — и могут дребезжать — выходы ядра. Статический анализ '
               'проверяет для асинхронного сброса только recovery / removal на снятии; путь «установка сброса → выход '
               'ядра → триггер тайла» им не покрыт. Это классическая задача пересечения доменов сброса (RDC); решают её '
               'изоляцией: на стороне принимающего домена сигнал заменяется значением, которое не зависит от '
               'сбрасываемого домена.'))
    s.append(diagrams.iso_timing())
    s.append(cap('Рис. 2. Сброс ядра и изоляция: sReset длится не меньше 100 тактов и до снятия запроса. '
                 '`coreReset` и `isolate` поднимаются на одном фронте (E0); сброс внутри ядра приходит позже и в неизвестный '
                 'момент, выходы ядра в это время произвольны («мусор»), после изоляции тайл видит значение сброса без '
                 'глитчей.'))
    s.append(P('<b>Принцип.</b> `isolate` — регистр `closed` контроллера: ставится на том же фронте, что и `coreReset` '
               '(переход sDrain → sReset), и снимается при выходе из sRelease (`l1.alive && !coreInReset`), когда DCache и '
               'frontend уже вне сброса. Это регистр тайла, поэтому сам он не дребезжит. Асинхронный путь начинается с '
               'того же регистра `coreReset`, поэтому раньше E0 + t_cq ни один выход ядра измениться не может; `isolate` к '
               'этому времени тоже переключился, путь от него до маски — обычный синхронный. Снятие сброса синхронно, '
               'поэтому выходы ядра после него меняются только по фронтам, и `isolate` можно снять после выхода DCache и '
               'frontend из сброса.'))
    s.append(P('<b>Какое значение подставлять.</b> Для каждого управляющего выхода ядра — одно из двух: значение в сбросе '
               '(`isoReset`): valid — 0, подтверждения рукопожатий (`msiAck`) — 0, «frontend в сбросе» — 1, признаки '
               'состояния (`cpu_halt`, `cpu_critical_error`, `l2_flush_en`) — 0; или значение до сброса (`isoHold`, '
               '`RegEnable(x, !isolate)`) — для уровней конфигурации без рукопожатия (настройки предвыборщика L2, '
               '`mstatus` для трассы, `robTrueCommit`). Поле данных, которое читают только вместе с valid, отдельной '
               'изоляции не требует. Входы ядра (прерывания через IntBuffer, `msiInfo`, `clintTime`, reset vector, '
               '`hartId`, `l2_hint`, `perfEvents`) изоляции не требуют: их формирует домен тайла синхронно.'))
    s += box('Почему msiAck — значение сброса, а не удержание', [
        'Доставка MSI в IMSIC ядра — четырёхфазное рукопожатие уровнями: мост поднимает `vld_req`, IMSIC в CSR ядра '
        'отвечает `vld_ack = vld_req` (регистр), мост ждёт фронта `vld_ack` и снимает запрос. Если бы `msiAck` '
        'удерживался равным 1 весь сброс, а запрос к этому моменту уже снова стоял, ядро после сброса подняло бы '
        '`vld_ack` из 0 в 1 за один такт — ещё под удержанием, — и после снятия изоляции мост увидел бы постоянную 1 без '
        'фронта и ждал бы вечно. Значение сброса (0) показывает мосту то же, что показал бы сброс ядра. (Прерывания, уже '
        'принятые IMSIC ядра, теряются при сбросе ядра в любом случае: файл прерываний — часть ядра.)',
    ])
    s.append(P('<b>Где стоит изоляция.</b> Все сигналы из домена сброса ядра в домен тайла (сверено с XSTile v5):'))
    rows = [
        ['Сигнал (из ядра)', 'Вид', 'Изоляция, пока isolate = 1', 'Где'],
        ['TileLink l1d: A valid, C valid, E valid, D ready, B ready', 'TL-C, ядро — клиент',
         'A — `block` и `isolate`; C, E — valid = 0 (собственный ProbeAck гейта проходит); D ready = 0; B — `holdB` (KEEP) '
         'или `ackB` (SWEEP)', 'TLQuiesceGate (6.1)'],
        ['TileLink l1i, ptw, i_mmio, d_mmio: A valid, D ready', 'TL-UL, ядро — клиент',
         'A valid = 0, D ready = 0; к ядру D valid = 0', 'TLQuiesceGate'],
        ['TileLink icachectrl: A ready, D valid', 'TL-UL, ядро — менеджер',
         'к ядру A valid = 0; к тайлу A ready = 0, D valid = 0', 'TLResetIsolation (6.2)'],
        ['предвыборка L1 → L2, → L3: `addr_valid`', 'valid + данные', '0 (адрес, источник, `l2_pf_en` — данные)',
         'XSTile (6.5)'],
        ['`msiAck`, `teemsiAck`', 'рукопожатие (уровень)', '0 — значение сброса', 'XSTile'],
        ['`cpu_halt`, `cpu_critical_error`', 'состояние', '0 — значение сброса', 'XSTile'],
        ['`resetInFrontend` → `hartIsInReset`', 'состояние', '1 — значение сброса; плюс `hartInReset` контроллера',
         'XSTile'],
        ['`l2_flush_en`', 'запрос (CSR)', '0 — значение сброса', 'XSTile'],
        ['`beu_errors.{icache,dcache,uncache}.ecc_error.valid`', 'valid + адрес', '0', 'XSTile'],
        ['трасса: `groups(i).valid`; `mstatus`', 'valid + данные; уровень', 'valid = 0; `mstatus` удерживается', 'XSTile'],
        ['`l2_tlb_req`: `req.ready`, `resp.valid` (ядро — ответчик)', 'рукопожатие', '0, 0; ответ (`resp.bits`, '
         '`l2_pmp_resp`) — данные', 'XSTile'],
        ['`l2PfCtrl` → `pfCtrlFromCore`', 'конфигурация (CSR)', 'удерживается', 'XSTile'],
        ['`debugTopDown.robHeadPaddr.valid`; `robTrueCommit`', 'valid + адрес; счётчик', 'valid = 0; счётчик '
         'удерживается', 'XSTile'],
        ['`l1.done`, `l1.idle`, `l1.alive` (DCache → контроллер)', 'рукопожатие / состояние', '`done`, `idle` смотрятся '
         'только при `closed = 0`, `alive` и `resetInFrontend` — только в sRelease (снятие синхронно)', 'CoreResetCtrl'],
        ['записи в `tagArray`, `bankedDataArray`, `metaArray`, `errorArray`', 'разрешения записи (KEEP)',
         '`freeze` = `closed`: valid записи = 0', 'DCacheWrapper (5.6)'],
    ]
    s.append(table(rows, [2.2, 1.0, 2.5, 1.1]))
    s.append(P('<b>Что не нуждается в изоляции.</b> Регистр `isoHold` и маски стоят в домене тайла и сбрасываются только '
               'сбросом тайла. Интерфейс `l1_quiesce` в обратную сторону (`req`, `freeze`) и все остальные входы ядра идут из '
               'домена тайла. Внутренние связи ядра сбрасываются целиком и пересечения доменов не образуют.'))
    s += box('Почему маски и на A, и на B, если канал A закрывает block, а B — holdB / ackB', [
        'Канал A гейт закрывает с sDrain (`block`, на границе сообщения), а опустошение гарантирует, что к сбросу A '
        'стоит на границе. Значит, маска `isolate` на A функционально лишняя — формальная проверка подтверждает: мутант '
        'без неё (`GATE_MUTANT_NO_ISO_A`) эквивалентен (7.2). Её оставили, чтобы ни один выход гейта к L2 во время '
        'сброса не зависел от выхода ядра даже теоретически, без опоры на опустошение. Для B отдельной маски нет: пока '
        '`isolate` = 1, всегда поднят `holdB` (KEEP) или `ackB` (SWEEP) — ровно та же маска; это проверяют assert в гейте и '
        'свойство P17.',
    ])
    s.append(P('<b>Как это связано с правилом 100 тактов TileLink.</b> «The valid signals must be driven LOW for at least '
               '100 cycles while reset is asserted.» [TL 1.9.3 3.2.2, с. 15] ([TL 1.8.1 3.2.2, с. 14]). Внутри XSCore все '
               'TileLink-связи (DCache, ICache, PTW, их крестовины) сбрасываются вместе с ядром — для них правило '
               'выполняет длина сброса: `rstCycles` по умолчанию 100, и сброс держится не меньше. На границе изоляция даёт '
               'то же с обеих сторон: гейты и `TLResetIsolation` держат valid к ядру равным 0 всё время `isolate` (sReset — '
               'не меньше 100 тактов, и sRelease), а к L2 valid из ядра не проходит. «Ready, control, and data signals are '
               'free to take any value during reset» — поэтому ready ядра во время сброса может быть любым (у ProbeQueue в '
               'сбросе он 1), и изоляция не даёт ему дойти до L2.'))
    return s
