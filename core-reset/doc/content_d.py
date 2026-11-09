"""Section 7: verification (data driven)."""
import os
import re

from reportlab.platypus import PageBreak, Spacer, KeepTogether

from pdflib import H, P, bullets, numbered, table, box, cap, text_block, S
import waves

ND = 'нет данных'

PROPS = [
    ('P1', 'в sReset через границу ничего не открыто (включая запросы к ICache ctrl), ни одно сообщение не на середине',
     'главное свойство: сброс не обрывает транзакцию и не оставляет L2 в ожидании'),
    ('P2', 'в sReset и sRelease в ядро и из ядра не проходит ни одного beat-а — ни через гейты, ни через `TLResetIsolation`',
     'граница закрыта на всё время сброса и выхода'),
    ('P3', 'Probe не предлагается ядру, пока оно в сбросе, и раньше, чем гейты открылись', 'Probe не пропадёт в сбрасываемой ProbeQueue'),
    ('P4', 'гейт не обрывает многобитное сообщение на A', 'PutFull не повиснет в мосту L2'),
    ('P5', '`quiet` гейтов верен: ничего не открыто и нет сообщения на середине', 'решение контроллера опирается на `quiet`'),
    ('P6', '`coreReset` только в sReset', 'сброс ядра не приходит вне процедуры'),
    ('P7', 'Probe попадает в DCache только после её `alive`', 'ProbeQueue вышла из сброса'),
    ('P8', 'B закрыт (держится или отвечает гейт) только в процедуре (sDrain, sReset, sRelease); P8B — ограничено по времени '
           'после снятия запроса', 'B не остаётся закрытым навсегда; взаимной блокировки на стороне гейта нет'),
    ('P8N', 'SWEEP: Probe держится только в sDrain; пока гейт отвечает, предложенный Probe принимается сразу (если прошлый ответ '
            'ушёл), а готовый ответ всегда предложен L2', 'ответ гейта не задерживает L2'),
    ('P9', 'с начала процедуры по A ранних гейтов не проходит новых запросов', 'ранняя блокировка A некогерентных работает'),
    ('P10', 'в sDrain некогерентные агенты тихи (ничего не открыто, нет сообщения на середине ни на одном канале)',
     'зависимость Get → Probe: B закрывается только после их тишины'),
    ('P11', '`hartIsInReset` = 1 от первого сброса ядра до запуска ядра', 'Debug Module видит харт «в сбросе»'),
    ('P12', 'собственные ответы гейта: один Probe за раз, ровно один ProbeAck NtoN на каждый, никогда внутри сообщения C ядра; '
            'только в SWEEP', 'ответ гейта законен и однозначен'),
    ('P13', 'ядро выходит из сброса только после снятия запроса', 'сброс — уровень'),
    ('P14', 'каждый сброс ядра не короче `rstCycles` (100 тактов с valid = 0)', 'правило TileLink 3.2.2'),
    ('P15', 'изоляция: пока `isolate`, ни один сигнал стороны тайла гейтов и `TLResetIsolation` не зависит от ядра (A, C, E valid и '
            'D ready замаскированы, B держится или отвечает), и ядру ничего не предлагается', 'выходы ядра в сбросе произвольны'),
    ('P16', 'изоляция покрывает сброс ядра (установку и синхронизатор) и только sReset / sRelease', 'нет окна без изоляции'),
    ('P17', 'B держится или отвечается, пока ядро изолировано', 'общая маска для B'),
    ('P18', 'B держится с первого такта sDrain (в этом такте Probe не предлагается ядру)', 'быстрое закрытие B'),
    ('P19', 'сброс ядра начинается только после `l1.done` и `l1.idle` в предыдущем такте', 'флаги пустоты вместо 16 тактов'),
    ('P20', 'ядро запускается (sIdle после sRelease) только когда frontend вне сброса', 'sRelease ждёт самый поздний узел цепочки'),
]

MUT = {
    'CTRL_MUTANT_NO_DRAIN': 'сброс без ожидания флагов и тишины: sDrain → sReset сразу',
    'CTRL_MUTANT_STALE_QUIET': 'решение sDrain по `quiet` предыдущего такта (Probe последнего такта sFlush проскакивает)',
    'CTRL_MUTANT_NO_L1_IDLE': 'контроллер игнорирует `l1.idle`',
    'CTRL_MUTANT_NO_ALIVE': 'sRelease не ждёт `alive` DCache',
    'CTRL_MUTANT_NO_FE_WAIT': 'sRelease не ждёт выхода frontend из сброса',
    'CTRL_MUTANT_NO_EARLY_QUIET': 'выход из sFlush без тишины ранних гейтов: B закрывается, пока Get может ждать Probe',
    'CTRL_MUTANT_NO_EARLY_BLOCK': 'A некогерентных закрывается только с sDrain (как в v4)',
    'CTRL_MUTANT_LATE_HOLDB': 'B закрывается на такт позже (со второго такта sDrain)',
    'CTRL_MUTANT_NO_HOLD_IN_RELEASE': 'Probe открывается вместе со снятием `coreReset`, до конца sRelease',
    'CTRL_MUTANT_RESET_EARLY': 'сброс заканчивается при `cnt >= rstCycles` даже при поднятом запросе',
    'CTRL_MUTANT_ISO_LATE': '`isolate` поднимается на такт позже `coreReset`',
    'CTRL_MUTANT_ISO_EARLY_DROP': '`isolate` снимается вместе с `coreReset`, до конца sRelease',
    'CTRL_MUTANT_NOKEEP_HOLDB': 'SWEEP: Probe держится вместо ответа гейта',
    'GATE_MUTANT_ALWAYS_QUIET': '`quiet` гейта всегда 1',
    'GATE_MUTANT_CUT_A': 'A закрывается посреди многобитного Put',
    'GATE_MUTANT_NO_ISO_A': 'нет маски `isolate` на канале A',
    'GATE_MUTANT_NO_ISO_C': 'нет изоляции канала C',
    'GATE_MUTANT_NO_ISO_D': 'нет изоляции D ready',
    'GATE_MUTANT_NO_ISO_E': 'нет изоляции канала E',
    'GATE_MUTANT_NO_HOLDB': 'KEEP: гейт не держит B (Probe проходит к ядру в сбросе)',
    'GATE_MUTANT_NO_ACKB': 'SWEEP: гейт не отвечает на Probe, Probe проходит к ядру',
    'GATE_MUTANT_ACK_PARAM': 'SWEEP: гейт отвечает TtoN вместо NtoN',
    'ISO_MUTANT_NO_ISO': '`TLResetIsolation` ничего не изолирует',
    'ISO_MUTANT_ALWAYS_QUIET': '`quiet` `TLResetIsolation` всегда 1',
    'FLUSH_MUTANT_NO_BLOCK': 'записи, атомики и промахи не блокируются на время опустошения',
    'FLUSH_MUTANT_NO_WBQ_WAIT': 'опустошение не ждёт WritebackQueue (Release, ProbeAck)',
    'FLUSH_MUTANT_NO_MP_WAIT': 'опустошение не ждёт MainPipe',
    'FLUSH_MUTANT_NO_SWEEP': 'обхода нет: L1D сбрасывается со строками (удалённый полный сброс)',
    'FLUSH_MUTANT_SWEEP_NO_WAIT': '`done` сразу после последнего flush, Release ещё в очереди',
    'FLUSH_MUTANT_SWEEP_NO_DATA': 'грязная строка отдаётся без данных',
    'FLUSH_MUTANT_SWEEP_ONE_WAY': 'обход останавливается после пути 0',
    'META_MUTANT_CORE_RESET': 'KEEP: `metaArray` сбрасывается сбросом ядра',
    'TAG_MUTANT_CORE_RESET': 'KEEP: теги стираются сбросом ядра (дефект v4), meta сохранена',
    'FREEZE_MUTANT_NO_SRAM_MASK': 'KEEP: запись в SRAM тегов и данных не замаскирована `freeze`',
    'NOKEEP_MUTANT_META_KEPT': 'SWEEP: `metaArray` переживает сброс',
}


def desc(name):
    base = name.split('+')[0]
    extra = ''
    if '+NO_CTRL_ASSERT' in name:
        extra = ' (assert-ы контроллера выключены)'
    if '+NO_FREEZE_CHECK' in name:
        extra += ' (проверка массивов под freeze выключена)'
    return MUT.get(base, '') + extra


def fn(x, nd=1):
    return ('%.' + str(nd) + 'f') % x


def ru(x, nd=2):
    return fn(x, nd).replace('.', ',')


def section7(C):
    s = [PageBreak(), H(1, '7. Проверка')]
    s.append(P('Проверка идёт четырьмя независимыми путями: компиляция и elaboration Chisel (7.1), формальное доказательство '
               'гейтов, изоляции и контроллера в произвольном окружении (7.2), симуляция моделей с проверяющим тестбенчем (7.3) и '
               'временные диаграммы из VCD (7.4). Все числа — из файлов результатов (`core-reset/verification/results_*`, '
               '`coverage_*.json`); если файла нет, документ пишет «нет данных». Это проверка <b>моделей, которые повторяют Scala-код '
               'один в один, и RTL трёх модулей через эквивалентность</b>, а не симуляция RTL всего ядра.'))
    s += section71(C)
    s += section72(C)
    s += section73(C)
    s += section74(C)
    return s


def section71(C):
    s = [H(2, '7.1. Chisel: компиляция, elaboration, эквивалентность RTL ↔ моделям')]
    s.append(P('<b>Компиляция.</b> `mill xiangshan.compile` проходит на коммитах v5 (Scala 2.13.15, Chisel 6.7, firtool 1.62.1). '
               'Версия v4 не компилировалась (конфликт `TLQuiesceGate.name` и `LazyModule.name`).'))
    s.append(P('<b>Elaboration модулей.</b> Стенд `verification/elab/CoreResetElabHarness.scala` (object `xiangshan.CoreResetElab`) '
               'собирает отдельные модули в Verilog: `CoreResetCtrl` (KEEP и SWEEP), гейты `TLQuiesceGate` (TL-C и TL-UL), '
               '`TLResetIsolation`; а также `DCache` (`dcache_keep`, `dcache_sweep`: DCacheWrapper с менеджером и клиентом ICache ctrl). '
               'Из вывода первых трёх целей `scripts/extract_rtl.py` вырезает RTL, на котором работают миттеры:'))
    rows = [['Файл RTL (`verification/rtl/`)', 'Модуль', 'Есть']]
    for f, m in [('CoreResetCtrl_keep.sv', 'CoreResetCtrl, KEEP'), ('CoreResetCtrl_sweep.sv', 'CoreResetCtrl, SWEEP'),
                 ('TLQuiesceGate.sv', 'TLQuiesceGate, TL-C (l1d)'), ('TLQuiesceGate_1.sv', 'TLQuiesceGate, TL-UL (ранний)'),
                 ('TLResetIsolation.sv', 'TLResetIsolation')]:
        p = os.path.join(C.ver, 'rtl', f)
        rows.append(['`%s`' % f, m, ('да (%d строк)' % sum(1 for _ in open(p, errors='replace'))) if os.path.exists(p) else ND])
    s.append(table(rows, [2.4, 2.4, 1.0]))
    s.append(P('Результат elaboration целей `dcache_keep` / `dcache_sweep` в пакет результатов не записан: %s.' % ND, 'small'))
    s.append(Spacer(1, 3))
    e = C.eq
    s.append(P('<b>Эквивалентность RTL ↔ модели.</b> Пять миттеров (`formal/eq_chisel.sv`, `formal/run_equiv.sh`) сравнивают '
               'RTL, сгенерированный Chisel / firtool, с моделями (`model/cr_ctl_models.sv`), на которых построены формальная '
               'проверка и симуляция. Все входы свободны, каждый выход сравнивается в каждом такте, кроме первого (там сброс). '
               'Ограничения входов: коды операций выбираются из малого свободного селектора, так что встречаются только допустимые '
               'для канала (A: PutFull, Get, AcquireBlock, AcquirePerm; C: ProbeAck(Data), Release(Data); D: AccessAck(Data), Grant(Data), '
               'ReleaseAck; B: Probe); размер сообщения — 16 байт (2 beat-а по 8 Б), адрес с нулевыми старшими битами, маска единицы, '
               'corrupt / denied = 0, данные не сравниваются. Проверка: BMC глубины 30 и доказательство (abc pdr).'))
    if e and e['rows']:
        rows = [['Миттер', 'BMC 30', 'Время', 'Доказательство (prove)', 'Время']]
        names = {'ctrl_keep': 'CoreResetCtrl, KEEP', 'ctrl_sweep': 'CoreResetCtrl, SWEEP', 'gate_c': 'TLQuiesceGate, TL-C',
                 'gate_ul': 'TLQuiesceGate, TL-UL', 'iso': 'TLResetIsolation'}
        for r in e['rows']:
            rows.append([names.get(r[0], r[0]), r[2], '%s с' % ru(r[3], 1), r[4], '%s с' % ru(r[5], 1)])
        s.append(table(rows, [2.2, 0.8, 0.8, 1.6, 0.8]))
        okc = sum(1 for r in e['rows'] if r[2] == 'PASS' and r[4] == 'PASS')
        s.append(P('Итог: %d из %d миттеров эквивалентны%s.' % (okc, len(e['rows']), '' if e['failed'] is None else
                                                                 '; неудачных миттеров: %d' % e['failed']), 'small'))
    else:
        s.append(P('Результаты эквивалентности: %s.' % ND))
    elab = C.elab
    s += box('Полная elaboration XSNoCTop', [
        ('Результат (`results_elab.txt`): ' + ' '.join(x.strip() for x in elab.strip().splitlines()[:8])) if elab else
        'Полная elaboration XSNoCTop <b>не выполнена</b>: файла `results_elab.txt` нет. Полная elaboration — единственное, '
        'что проверило бы соединения XSTile на реальных модулях (гейты на пяти рёбрах, изоляция, контроллер, сбросы). Для '
        'неё нужен YAML только с ключами сброса (`verification/elab/xsnoctop_keep.yml`, `xsnoctop_sweep.yml`): конфигурация '
        'XSNoCTop из `Default.yml` (с `tp: true`) ломает elaboration независимо от сброса.',
    ], 'warn')
    return s


def section72(C):
    s = [H(2, '7.2. Формальное доказательство')]
    s.append(P('SymbiYosys / abc проверяет свойства '
               'для всех достижимых состояний трёх гейтов (TL-C для DCache и два TL-UL ранних), `TLResetIsolation` и '
               '`CoreResetCtrl` (`formal/fv_boundary.sv`; модели один в один с `CoreReset.scala`, их RTL доказан эквивалентным в 7.1). '
               'Окружение произвольно в рамках правил TileLink: запрос сброса приходит и снимается в любой такт и держится '
               'сколько угодно.'))
    s.append(P('<b>Допущения среды</b> (вне допущений — всё свободно):'))
    s += bullets([
        'TileLink: beat-ы данных принадлежат одному сообщению; ответ — только на открытый запрос (Grant → Acquire, ReleaseAck → '
        'Release, AccessAck → Put / Get, GrantAck → Grant, ProbeAck → Probe); L2 может предложить Probe в любой такт; до 5 открытых '
        'транзакций каждого вида. Устойчивость valid <b>не</b> предполагается: [TL 1.8.1 4.1, с. 19] разрешает снять valid '
        'непринятого beat-а.',
        'Выходы ядра в сбросе: пока `CoreResetCtrl` в sReset — <b>все</b> выходы ядра произвольны в каждом такте, в том числе '
        '`l1.done`, `l1.idle`, `l1.alive` и признак сброса frontend; пока сброс снимается через синхронизатор (sRelease) — '
        'значения сброса (valid 0, `alive` 0, `done` 0). Вне сброса ядро подчиняется TileLink.',
        'Сброс frontend: `fe_rst = core_rst || fe_q2`, frontend выходит на 2 такта позже остального ядра.',
        'Drain DCache: после перехода контроллера из sIdle / sFlush DCache не начинает новых Release (проверяет monitor в симуляции и '
        'assert в DCacheWrapper); `l1.done` только при `l1.req`; `l1.idle` свободен (и в сбросе); `l1.alive` = 0 в сбросе и '
        'поднимается не позже чем через 6 тактов после него, в любом порядке относительно сброса frontend (нужно только для границы '
        'P8B; она остаётся rstCycles + 16).',
    ])
    s.append(P('Независимые счётчики-эталоны (`fv_boundary.sv`) считают транзакции отдельно от счётчиков гейта: A, D, E — на стороне L2; '
               'Probe и C — на стороне ядра; Probe, на который гейт ответил сам, отслеживается отдельно.'))
    rows = [['Свойство', 'Что утверждает', 'Зачем']]
    rows += [[a, b, c] for a, b, c in PROPS]
    s.append(table(rows, [0.5, 3.6, 1.7]))
    s.append(P('Проверено 20 свойств (P8 включает P8B, P8N — только SWEEP, P12 — только SWEEP).', 'small'))
    # results
    s.append(P('<b>Результаты.</b> `results_formal_k.txt` (KEEP), `results_formal_s.txt` (SWEEP) — вывод `formal/run_formal.sh`: '
               'доказательство: abc pdr без ограничения глубины при `rstCycles` = 100 и 16; cover: каждое Cn проверяется как '
               'утверждение «!Cn» движком abc pdr (достижимо = найден контрпример; «шаг» — длина найденной трассы, не обязательно '
               'кратчайшей); мутанты: abc bmc3 глубины 60 с лимитом 300 с, не пойманный там мутант перезапускается abc pdr (без '
               'ограничения глубины); если abc не называет нарушенное свойство, его метка берётся из короткого перезапуска smtbmc '
               '(yices) до найденной глубины; эквивалентные мутанты — abc pdr prove. BMC всей модели не запускался (см. врезку).'))
    rows = [['', 'KEEP', 'SWEEP']]
    fk, fs = C.formal.get('k'), C.formal.get('s')

    def pv(f, r):
        if not f or r not in f['prove']:
            return ND
        v = f['prove'][r]
        return '%s, %s с' % (v[0], ru(v[1]))

    def bm(f):
        if not f or not f['bmc']:
            return ND
        if f['bmc'] == 'not run':
            return 'не запускался'
        return '%s (допущения выполнимы: %s)' % (f['bmc'][1], 'да' if f['bmc'][2] == 'yes' else 'НЕТ')

    def cv(f):
        if not f or not f['cover']:
            return ND
        return '%s: достигнуто %d' % (f['cover'][0], f['cover'][1])

    def mt(f):
        if not f or not f['mutants']:
            return ND
        return '%d из %d дали контрпример' % (sum(1 for m in f['mutants'] if m[1] == 'FAIL'), len(f['mutants']))

    def eqm(f):
        if not f or not f['equiv']:
            return ND
        return '%d из %d доказаны' % (sum(1 for m in f['equiv'] if m[1] == 'PASS'), len(f['equiv']))
    rows += [['prove, rstCycles = 100', pv(fk, 100), pv(fs, 100)], ['prove, rstCycles = 16', pv(fk, 16), pv(fs, 16)],
             ['BMC', bm(fk), bm(fs)], ['cover (abc pdr)', cv(fk), cv(fs)], ['мутанты', mt(fk), mt(fs)],
             ['эквивалентные мутанты (должны доказываться)', eqm(fk), eqm(fs)]]
    s.append(table(rows, [2.0, 1.9, 1.9]))
    # covers
    s.append(P('<b>Достижимость (cover).</b> Каждое сценарное условие достижимо при допущениях среды:'))
    CV = {'C1': ('inflight_at_start_then_reset', 'в момент запроса открыты Probe, Release, Acquire, сообщение на середине C — и сброс состоялся'),
          'C2': ('more_inflight_at_start', 'в момент запроса открыты также GrantAck, Get и сообщение на середине A'),
          'C3': ('probe_held_then_delivered', 'Probe, предложенный в сбросе, ждёт и после сброса доставлен'),
          'C4': ('back_to_idle', 'после сброса контроллер вернулся в sIdle'),
          'C5': ('probe_in_first_drain_cycle_held_then_delivered', 'KEEP: Probe, предложенный в первом такте sDrain, держится весь сброс и доставлен'),
          'C6': ('reset_held_long_then_run', 'запрос держат дольше `rstCycles` + 24 такта, затем ядро запускается'),
          'C7': ('probe_answered_by_gate_in_reset_then_run', 'SWEEP: гейт ответил на Probe в сбросе, затем ядро запущено'),
          'C8': ('icachectrl_inflight_at_start_then_reset', 'запрос к регистрам ICache ctrl открыт в момент запроса сброса'),
          'C9': ('core_garbage_in_reset_then_run', 'выходы ядра в сбросе — мусор, затем ядро запущено')}
    rows = [['Cover', 'Что достигается', 'KEEP: шаг', 'SWEEP: шаг']]
    dk = dict(fk['covers']) if fk and fk['covers'] else {}
    ds = dict(fs['covers']) if fs and fs['covers'] else {}

    def cc(dd, f, n):
        if not f or not f['covers']:
            return ND
        if n in dd:
            return str(dd[n])
        if (n == 'C5' and f is fs) or (n == 'C7' and f is fk):
            return '—'
        return 'нет'
    for n, (nm, ds_) in CV.items():
        rows.append([n + ' `' + nm + '`', ds_, cc(dk, fk, n), cc(ds, fs, n)])
    s.append(table(rows, [1.5, 3.2, 0.55, 0.55]))
    s += box('Почему так: без BMC всей модели', [
        'BMC всей модели (smtbmc / yices, затем abc bmc3) не дошёл до глубины 25–30 за часы: широкие счётчики и эталонные трекеры. '
        'Доказательства abc pdr не ограничены глубиной и покрывают любую; а 8 достигнутых cover показывают, что допущения среды '
        'выполнимы (пустое, вакуумное доказательство исключено).'])
    # mutants
    s.append(P('<b>Мутанты.</b> Намеренно испорченные варианты модели; каждый, применимый к конфигурации, должен дать контрпример '
               '(abc bmc3 глубины 60, лимит 300 с; не пойманные — abc pdr, помечены «pdr»). В таблице — какие свойства нарушены и на каком такте; «—» — мутант к этой '
               'конфигурации не применяется.'))
    allm = []
    for f in (fk, fs):
        if f:
            for m in f['mutants']:
                if m[0] not in allm:
                    allm.append(m[0])
    if allm:
        rows = [['Мутант', 'Что ломает', 'KEEP: свойство, такт', 'SWEEP: свойство, такт']]
        dk = {m[0]: m for m in fk['mutants']} if fk else {}
        ds = {m[0]: m for m in fs['mutants']} if fs else {}

        def cell(d, n, f):
            if not f or not f['mutants']:
                return ND
            if n not in d:
                return '—'
            m = d[n]
            return '%s%s, такт %d%s' % ('' if m[1] == 'FAIL' else 'НЕ ЛОМАЕТ: ', ', '.join(x.split('_')[0] for x in m[3]) or '?', m[2],
                                         ' (pdr)' if m[4] == 'pdr' else '')
        for n in allm:
            rows.append(['`%s`' % n, desc(n), cell(dk, n, fk), cell(ds, n, fs)])
        s.append(table(rows, [1.7, 2.3, 1.1, 1.1]))
    else:
        s.append(P('Таблица мутантов: %s.' % ND))
    eqs = []
    for f in (fk, fs):
        if f:
            for m in f['equiv']:
                if m[0] not in [e[0] for e in eqs]:
                    eqs.append(m)
    if eqs:
        s.append(P('<b>Эквивалентные мутанты</b> — изменения, после которых все свойства по-прежнему доказываются (без ограничения '
                   'глубины), и это ожидаемо: ' + '; '.join(
            '`%s` — %s (%s)' % (n, desc(n), 'доказан' if r == 'PASS' else 'НЕ ДОКАЗАН') for n, r in eqs) + '. '
                   '`GATE_MUTANT_NO_ISO_A` эквивалентен, потому что A закрыт блокировкой `block` с sDrain, а опустошение оставляет A на '
                   'границе сообщения; `ISO_MUTANT_ALWAYS_QUIET` — потому что запрос к регистрам ICache ctrl уже учтён гейтом '
                   'клиента (достижимы только собственные обращения ядра). Оба элемента оставлены в RTL как явная изоляция, '
                   'не зависящая от этих рассуждений (1.6, 6.2).'))
    return s


def section73(C):
    s = [H(2, '7.3. Симуляция')]
    s.append(P('Тестбенч (`tb/cr_tb.sv`, мониторы `tb/cr_monitors.sv`) собирает Verilator 5 (бинарь, `--timing`) из моделей, которые '
               'повторяют Scala-код: контроллер и гейты (`model/cr_ctl_models.sv`, те же, что в формальной части), DCache и окружение '
               '(`model/cr_dcache.sv`, `model/cr_env_models.sv`).'))
    s += bullets([
        '<b>Модель DCache</b> (`cr_dcache`): MainPipe с тремя стадиями (запросы Probe, store, flush), проверка конфликта набора; '
        'MissQueue с одной записью (в том числе AcquirePerm на запись всей строки); WritebackQueue — две записи Release и слот ProbeAck; '
        'ProbeQueue — запись и регистр выбора; `DCacheFlushUnit` (sweep по всем парам, sWait); флаги пустоты — те же четыре, что в RTL; '
        'флаги `busy_true` — настоящее состояние для проверки самого стенда. Размер модели уменьшен: 4 набора × 2 пути, 16 адресов '
        '(в RTL — 256 × 4); задержка записи в s3 — 0..2 такта (0..6 с `+SLOW`).',
        '<b>Буферы B и C</b> (`cr_buf1`): одноместные буферы в домене сброса ядра между DCache и гейтом — модель `l1d_to_l2_buffer`; '
        'в сбросе на выходе мусор.',
        '<b>L2</b> (`cr_l2`): инклюзивная, с директорией, снупами HN и ответчиком TL-UL; AcquirePerm не даёт данных и оставляет L2 без '
        'действительной копии (poison); <b>зависимость Get → Probe</b>: Get некогерентного клиента к строке, которую L1D держит в T, '
        'ждёт Probe toB (как CoupledL2). L2 иногда нарочно шлёт Probe строке, которой в директории нет (кроме `+NOSPUR`).',
        'Каждая модель ядра после установки сброса 1–4 такта выдаёт случайные выходы (и случайные разрешения записи массивов): изоляция '
        'должна их скрыть.',
    ])
    s.append(P('<b>Сценарии.</b>'))
    s.append(table([
        ['Сценарий', 'Что проверяет'],
        ['1, 2', 'сбросы при непрерывном трафике ядра (загрузки, записи, AcquirePerm) и снупах HN: три запроса (1), двенадцать подряд с '
         'случайными паузами (2)'],
        ['3', 'запрос случайной длины (2..2000 тактов): ядро в сбросе, пока держат запрос'],
        ['4', 'наивный сброс без последовательности: воспроизводит проблему (ошибки ожидаются)'],
        ['5', 'процедура начинается ровно тогда, когда в полёте транзакция одного из классов C1..C12 (открытые Probe, Release, Acquire, '
         'GrantAck, сообщение на середине, MSHR с неотправленным Acquire, Probe, предложенный в этом такте)'],
        ['6', 'направленные Probe строк L1D (грязная / чистая T / B; toN / toB), шесть случаев: 0 — в sReset, 1 — в sRelease, 2 — сразу '
         'после последовательности, 3 — в начале sFlush, 4 — в первом такте sDrain, 5 — в последнем такте sFlush (гейт принял, sDrain '
         'ждёт его ProbeAck)'],
        ['7', 'долгий запрос (2000..20000 тактов, как `ndmreset` / `hartreset` у отладчика) со снупами во время удержания (KEEP: Probe '
         'горячей строки ждёт в L2 до снятия запроса; SWEEP: ответ гейта сразу)'],
        ['+SLOW', 'длинные случайные задержки в L2, паузы ready и между beat-ами (по умолчанию в сценариях 5, 6, 7)'],
    ], [0.7, 5.1]))
    s.append(P('<b>Проверки</b> в каждой точке сброса и при выходе: в L2 для ядра ничего не висит; управляющая логика DCache и буферы B / C '
               'пусты (`busy_true` = 0); директория L2 совпадает с meta DCache построчно (SWEEP: L1D пуста, L2 ничего не числит); текущее '
               'значение каждой строки (DCache, если грязная, иначе L2) равно эталону; после начала процедуры ни одного нового '
               'некогерентного запроса; в sDrain ничего некогерентного открытого; ни одного Probe через гейт в sDrain; конец '
               'последовательности только когда frontend вне сброса; выход из сброса только после снятия запроса; один сброс на запрос; '
               'во время сброса ничего не проходит ни по одному каналу, при KEEP meta не меняется; Probe не ждёт более 200 тактов (KEEP — вне '
               'сброса). Каждая загрузка-попадание сверяется с эталоном, каждый некэшируемый ответ — с клиентом. В конце — '
               'глобальная согласованность и отсутствие зависания.'))
    # regress table
    r = C.reg
    s.append(P('<b>Регрессия</b> (`scripts/regress.sh` → `results_regress.txt`): сценарии 1–3 × 15 seed-ов, с `+SLOW` × 5, сценарий 5 × 10, '
               'сценарий 6 × 5, сценарий 7 × 5, сценарий 4 × 3 (наивный сброс) — для каждой конфигурации; затем мутанты. Все прогоны '
               'дизайна должны пройти, наивный сброс и каждый мутант — дать ошибку, эквивалентные (`+EQUIV`) — пройти.'))
    if r:
        rows = [['', 'KEEP', 'SWEEP']]
        K, S_ = r['cfg']['KEEP'], r['cfg']['CFG_SWEEP']
        rows += [['прогонов дизайна: PASS / всего', '%d / %d' % (K['design_pass'], K['design']), '%d / %d' % (S_['design_pass'], S_['design'])],
                 ['наивный сброс: проблема воспроизведена', '%d / %d' % (K['naive_rep'], K['naive']), '%d / %d' % (S_['naive_rep'], S_['naive'])],
                 ['прогонов мутантов: пойманы / всего', '%d / %d' % (K['mut_caught'], K['mut']), '%d / %d' % (S_['mut_caught'], S_['mut'])],
                 ['ожидаемо эквивалентные (+EQUIV): PASS / всего', '%d / %d' % (K['eq_pass'], K['eq']), '%d / %d' % (S_['eq_pass'], S_['eq'])]]
        s.append(table(rows, [2.8, 1.5, 1.5]))
        if not r['complete']:
            s.append(P('<b>Регрессия не завершена или содержит отклонения на момент сборки документа.</b> Незавершённых строк: %d; '
                       'прогонов в файле: %d. %s' % (r['skipped'], r['total'], ('Отклонения: ' + '; '.join(r['not_ok'][:4])) if r['not_ok'] else ''),
                       'small'))
        # by scenario
        rows = [['Группа прогонов дизайна', 'KEEP: PASS / всего', 'SWEEP: PASS / всего']]
        keys = sorted(set(K['by_scen']) | set(S_['by_scen']))
        for k in keys:
            a = K['by_scen'].get(k)
            b = S_['by_scen'].get(k)
            rows.append(['сценарий %d%s' % (k[0], ' (+SLOW)' if k[1] else ''), '%d / %d' % (a[1], a[0]) if a else '—',
                         '%d / %d' % (b[1], b[0]) if b else '—'])
        s.append(table(rows, [2.8, 1.5, 1.5]))
    else:
        s.append(P('Результаты регрессии: %s.' % ND))
    # mutants in sim
    s.append(P('<b>Мутанты в симуляции.</b> Каждый мутант — отдельная сборка (`build/obj_<конфигурация>+<мутант>`); «пойман» — прогон '
               'завершился ошибкой проверки. Редкие в симуляции мутанты (попадание зависит от seed-а) запускаются на seed-ах, подобранных '
               '`scripts/seedsearch.sh` (`scripts/rare_seeds.txt`; сборка Verilator %s вместо 5.049, поэтому seed-ы подобраны заново).' %
               (C.verilator or '5.050')))
    if r and r['mut']:
        rows = [['Мутант', 'Что ломает', 'KEEP', 'SWEEP', 'Сценарии']]
        for n in sorted(r['mut']):
            d = r['mut'][n]

            def c(cfg):
                a = d.get(cfg)
                return '%d / %d' % (a['ok'], a['runs']) if a else '—'
            sc = sorted(set().union(*[a['scen'] for a in d.values()]))
            rows.append(['`%s`' % n, desc(n), c('KEEP'), c('CFG_SWEEP'), ', '.join(map(str, sc))])
        s.append(table(rows, [2.0, 2.2, 0.5, 0.5, 0.6], extra=None))
        s.append(P('«a / b»: пойманных прогонов / запущенных. Любой мутант, пойманный не во всех прогонах, — «немой» на части seed-ов; '
                   'немой на всех — дыра в проверке (в таблице таких не должно быть).', 'small'))
    elif not r:
        s.append(P('Таблица мутантов: %s.' % ND))
    if r and r['equiv']:
        s.append(P('<b>Ожидаемо эквивалентные мутанты в симуляции</b> (прогон проходит, мутант не наблюдаем):'))
        rows = [['Мутант', 'Что ломает', 'PASS / всего', 'Почему не наблюдаем']]
        WHY = {'CTRL_MUTANT_NO_L1_IDLE': 'флаг `l1.idle` избыточен с `l1.done` и `quiet` гейтов (в sDone занят может быть только путь Probe, а каждый Probe считает гейт); формально ловится (P19), потому что окружение допускает произвольный `idle`',
               'CTRL_MUTANT_NO_ALIVE': 'frontend — последний в цепочке ResetGen, после DCache: ожидание выхода frontend покрывает `alive`; формально ловится (P7), потому что окружение допускает любой порядок',
               'FLUSH_MUTANT_NO_MP_WAIT': 'в SWEEP после обхода MainPipe пуст (ожидание `inflight === 0` в sWait), поэтому флаг `mp_empty` ничего не добавляет; в KEEP мутант ловится',
               'NOKEEP_MUTANT_META_KEPT': 'после обхода у каждой строки состояние N, поэтому сохранённая meta содержит только N'}
        for n in sorted(r['equiv']):
            d = r['equiv'][n]
            ok = sum(a['ok'] for a in d.values())
            tot = sum(a['runs'] for a in d.values())
            rows.append(['`%s`' % n, desc(n), '%d / %d' % (ok, tot), WHY.get(n.split('+')[0], '')])
        s.append(table(rows, [1.7, 1.5, 0.6, 2.3]))
    # soak
    s.append(P('<b>Длинный прогон</b> (`scripts/soak.sh` → `results_soak_<конфигурация>.log`): сценарии 1–3 на seed-ах 31..130 (300 прогонов), '
               'с `+SLOW` на seed-ах 11..40 (90), сценарий 5 на seed-ах 21..70 (50), сценарии 6 и 7 на seed-ах 11..35 (по 25) — '
               '490 прогонов на конфигурацию.'))
    sk, ss = C.soak.get('KEEP'), C.soak.get('CFG_SWEEP')
    rows = [['', 'KEEP', 'SWEEP'],
            ['прогонов: PASS / всего', ('%d / %d' % (sk['pass'], sk['runs'])) if sk else ND, ('%d / %d' % (ss['pass'], ss['runs'])) if ss else ND]]
    s.append(table(rows, [2.8, 1.5, 1.5]))
    # coverage
    cv, cs = C.cov.get('KEEP'), C.cov.get('CFG_SWEEP')

    def g(c, k):
        return str(c[k]) if c and k in c else ND
    s.append(P('<b>Покрытие</b> (`coverage_*.json`, сумма по прогонам длинного прогона):'))
    rows = [['Показатель', 'KEEP', 'SWEEP']]
    for lab, k in [('сбросов (resets)', 'final.resets'), ('операций DCache', 'final.dcache-ops'), ('Probe всего', 'final.probes'),
                   ('Probe лишних (строки нет в директории)', 'final.spurious-probes'), ('снупов, которые L2 обслужила сама', 'final.snoops-served-by-L2-alone'),
                   ('AcquirePerm', 'final.acquire-perm'), ('Release во время процедуры', 'final.releases-during-quiesce'),
                   ('из них с данными', 'final.releases-with-data'), ('Probe удержано (KEEP)', 'final.probes-held'),
                   ('Probe, отвеченных гейтом (SWEEP)', 'final.probes-answered-by-gate'),
                   ('фаз sDrain', 'drain.sDrain-phases'), ('самая длинная sDrain, тактов', 'drain.longest-sDrain'),
                   ('Probe удержано в sDrain', 'drain.probes-held-in-sDrain'), ('Get, ждавших Probe (get-probes)', 'drain.get-probes'),
                   ('Probe в 1-м такте sDrain: предложен в sDrain', 'dir.drain_first_cycle.offered'),
                   ('Probe в 1-м такте sDrain: позже', 'dir.drain_first_cycle.later'),
                   ('Probe в последнем такте sFlush: попал', 'dir.flush_last_cycle.offered'),
                   ('Probe в последнем такте sFlush: позже', 'dir.flush_last_cycle.later'),
                   ('Probe в начале sFlush: в sFlush', 'dir.flush_start.offered')]:
        rows.append([lab, g(cv, k), g(cs, k)])
    s.append(table(rows, [3.2, 1.3, 1.3]))
    # classes C1..C12
    rows = [['Класс сценария 5', 'Описание', 'Попаданий KEEP', 'Попаданий SWEEP']]
    CL = ['Acquire принят, Grant ещё нет', 'GrantData: первый beat передан, второй нет', 'Grant передан, GrantAck ещё нет',
          'Release(Data) передан, ReleaseAck ещё нет', 'ReleaseData: передан только первый beat',
          'Probe доставлен, ProbeAck ещё нет', 'ProbeAckData: только первый beat', 'Get / PutFull передан, AccessAck ещё нет',
          'PutFull: только первый beat', 'AccessAckData: только первый beat', 'MSHR выделена, Acquire не отправлен',
          'L2 предлагает Probe в этом такте']
    for i in range(1, 13):
        rows.append(['C%d' % i, CL[i - 1] if i - 1 < len(CL) else '', g(cv, 'trig_hit.C%d' % i), g(cs, 'trig_hit.C%d' % i)])
    s.append(P('Попадания направленных запусков сценария 5 в классы транзакций (`triggers hit`; классы C1..C10 — открытые состояния '
               '`cr_txmon`, C11 и C12 — условия в тестбенче):', 'small'))
    s.append(table(rows, [0.8, 2.6, 1.2, 1.2]))
    # rare seeds
    rs = C.rare
    if rs:
        rows = [['Конфигурация', 'Мутант', 'seed-ы (сценарий:seed)']]
        for a, b, c in rs:
            rows.append([a, '`%s`' % b, ' '.join(c)])
        s.append(P('<b>Seed-ы редких мутантов</b> (`scripts/rare_seeds.txt`):'))
        s.append(table(rows, [1.0, 3.0, 1.8]))
    # what the check found
    s += box('Что нашла сама проверка', [
        '<b>(а) Ревью Chisel:</b> дефект v4 — теги L1D стирались при сбросе ядра (KEEP): `TagSRAMBank.rst_cnt` в домене сброса ядра '
        'обнулял SRAM тегов при каждом сбросе, а meta сохранялась. Исправлено (`tagArray` на сбросе тайла), добавлен мутант '
        '`TAG_MUTANT_CORE_RESET`.',
        '<b>(б)</b> Определение мутанта `STALE_QUIET` было эквивалентным (мутант не менял поведения) — исправлено: теперь он решает по '
        '`quiet` прошлого такта и в первом такте sDrain, и Probe последнего такта sFlush проскакивает.',
        '<b>(в)</b> В модели DCache апгрейд BtoT не блокировался flush-ем, в отличие от RTL — исправлено.',
        '<b>(г)</b> Класс C12 сценария 5 был недостижим в v5 (Probe, предложенный в такте запроса, принимается ещё в sIdle) — класс '
        'переопределён: «L2 предлагает Probe в этом такте».',
        '<b>(д)</b> Триггер случая 5 сценария 6 в SWEEP не попадал в последний такт sFlush — добавлено условие пустоты (`u_dc.idle`).',
        '<b>(е)</b> Конфигурация XSNoCTop из `Default.yml` (`tp: true`) ломает elaboration независимо от сброса — взяты YAML только с '
        'ключами сброса.',
        '<b>(ж) Формальная часть:</b> пока `l1.alive` в окружении поднимался не позже чем через 3 такта после сброса, frontend (позже на '
        '2 такта) всегда выходил из сброса после `alive` и такта sRelease → sIdle, поэтому мутант `CTRL_MUTANT_NO_ALIVE` был '
        'доказуем: немой мутант означал, что окружение сильнее, чем гарантирует дизайн (`alive` DCache не упорядочен относительно '
        'сброса frontend). Граница ослаблена до 6 тактов, мутант пойман свойством P7 на такте 26 (pdr). В симуляции он остаётся '
        '`+EQUIV`: в реальном RTL frontend последний в цепочке ResetGen, ожидание его выхода покрывает `alive`.',
        'Кроме того, стенд дал ошибку, найденную длинным прогоном: ожидание тишины в сценарии 6 не учитывало MainPipe, и эталон строки B '
        'запоминался, пока store в s3 ждал BtoT-апгрейда; исправление — ждать `dc_busy_true` и буферы B и C.',
    ], 'warn')
    return s


def section74(C):
    s = [H(2, '7.4. Временные диаграммы из VCD')]
    s.append(P('Диаграммы нарисованы по VCD-файлам реальных прогонов тестбенча (`core-reset/doc/make_waves.sh`: сборка Verilator с трассировкой '
               '`TRACE_BUILD=1 scripts/run.sh ...`, разбор VCD — `core-reset/doc/vcd.py`, отрисовка — `reportlab`). Окна по тактам '
               'найдены автоматически по событиям (состояние контроллера, handshake Probe), не заданы числами. Горизонтальная ось — '
               'такты тестбенча; зелёный — условие выполнено, серая линия — 0; красная штриховка в строке B — Probe предложен и '
               'не принят. Модель DCache уменьшена (4 набора × 2 пути), поэтому sFlush и обход в ней короче, чем в RTL.'))
    av = waves.available()
    missing = [k for k, v in av.items() if not v]
    if missing:
        s += box('Нет данных для временных диаграмм', ['Не найдены файлы: ' + ', '.join('`%s`' % m for m in missing) + '. Запустите '
                 '`core-reset/doc/make_waves.sh` и пересоберите документ.'], 'bad')
    cap_txt = {}
    # 1
    r = waves.wave1()
    s.append(H(3, 'Диаграмма 1. SWEEP, сценарий 1, seed 1: вся последовательность'))
    if r:
        d, msg = r
        info = waves._summary_w1(waves.load('w1_sweep_scen1.vcd'))
        s.append(d)
        s.append(cap('Рис. 8. Запрос поднят в такте тестбенча; sFlush — %d тактов (обход L1D модели: Release / ReleaseData '
                     'по строкам, синие метки на C; ReleaseAck — на D), sDrain — %d такт(а), sReset — %d тактов (>= 100, запрос снят сразу '
                     'после), sRelease — %d тактов; весь цикл — %d тактов. Число строк в L1D падает до 0, в директории L2 — до 0: после '
                     'обхода L2 ничего не числит за L1D. `earlyBlock` поднят с первого такта sFlush, `quiet` некогерентных — к его '
                     'концу; `holdProbe` — только в sDrain; `ackProbe`, `isolate` и сброс ядра — с sReset; сброс frontend '
                     'снимается позже `alive`.' % (info['flush'], info['drain'], info['reset'], info['release'], info['total'])))
    else:
        s.append(P('Нет данных: файл `w1_sweep_scen1.vcd` отсутствует или в нём нет полной последовательности.'))
    # 2
    r = waves.wave2()
    s.append(H(3, 'Диаграмма 2. KEEP, сценарий 6, seed 1, случай 5: Probe принят в последнем такте sFlush'))
    if r:
        d, msg, info = r
        s.append(d)
        s.append(cap('Рис. 9. Гейт l1d принял Probe (зелёный в строке B) в последнем такте sFlush; в sDrain `holdProbe` закрывает '
                     'B, а sDrain ждёт: DCache отвечает ProbeAck(Data), он идёт через буфер C (`cc_v`) в гейт и дальше к L2 (`C к L2`); '
                     '`quiet` гейта l1d (`probes` ≠ 0) остаётся 0, пока ответ не пройдёт, и только затем — `gatesQuiet && l1Done && l1Idle` '
                     'и переход в sReset. sDrain длится %d тактов (в v4 — 16 тактов подряд плюс проверка).' % (info['drain'],)))
    else:
        s.append(P('Нет данных: файл `w2_keep_case5.vcd` отсутствует или в нём нет случая 5.'))
    # 3
    r = waves.wave3()
    s.append(H(3, 'Диаграмма 3. KEEP, сценарий 6, seed 1, случай 4: Probe toN грязной строки в первом такте sDrain'))
    if r:
        d, msg, info = r
        s.append(d)
        s.append(cap('Рис. 10. L2 предлагает Probe в первом такте sDrain: `holdProbe` уже 1 (функция регистра состояния), `b.ready` = 0. '
                     'Probe не принят все %d тактов до ответа (красная штриховка: предложен, не принят — рисуется уровнем), включая sReset '
                     '(%d тактов), sRelease и выход ядра; после запуска DCache получает Probe и отвечает ProbeAckData из «горячей» L1D. '
                     'Выход буфера B внутри домена сброса ядра в сбросе — мусор: строка `db_v` скрыта на время `coreReset`.' % (
                         info['held'], info['reset'])))
    else:
        s.append(P('Нет данных: файл `w3_keep_case4.vcd` отсутствует или в нём нет случая 4.'))
    # 4
    r = waves.wave4()
    s.append(H(3, 'Диаграмма 4. Момент установки сброса (тот же сброс, случай 4)'))
    if r:
        d, msg, info = r
        s.append(d)
        s.append(cap('Рис. 11. Крупно: `holdProbe` с первого такта sDrain, L2 предлагает Probe (`B valid`), `B ready` гейта = 0. В такте решения '
                     '`quiet` всех гейтов, `l1.done` и `l1.idle` одновременно высоки; на следующем фронте поднимаются регистры `coreReset` '
                     'и `isolate` вместе (E0). Внутри ядра сброс приходит позже (после синхронизатора), а выходы ядра (`A valid` из DCache, '
                     '`C valid` из буфера) в первые такты сброса случайны (мусор, оранжевый); на стороне тайла `A valid` и `C valid` к L2 '
                     'остаются 0: изоляция их замаскировала.'))
    else:
        s.append(P('Нет данных: файл `w3_keep_case4.vcd` отсутствует или в нём нет случая 4.'))
    return s
