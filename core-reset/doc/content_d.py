"""Section 7: verification (data driven, v6)."""
from reportlab.platypus import PageBreak, Spacer

from pdflib import H, P, bullets, numbered, table, box, cap, text_block, S

ND = 'нет данных'

PROPS = [
    ('P1', '`P1_reset_point_clean`', 'в sIso и sReset через границу ничего не открыто (включая ICache ctrl), ни одного сообщения на середине', 'сброс не обрывает транзакцию'),
    ('P2', '`P2_nothing_crosses`', 'в sIso, sReset, sRelease в ядро и из ядра не проходит ни одного beat-а (кроме ProbeAck гейта)', 'граница закрыта'),
    ('P3', '`P3_no_probe_to_reset`', 'Probe не предлагается ядру, пока оно в сбросе, в sIso и sRelease', 'Probe не пропадёт в сбрасываемой ProbeQueue'),
    ('P4', '`P4_a_message_not_cut`', 'гейт не обрывает многобитное сообщение на A', 'PutFull не повиснет в мосту L2'),
    ('P5', '`P5_quiet_is_sound`', 'все `quiet` ⇒ ничего не открыто', 'решение опирается на `quiet`'),
    ('P6', '`P6_reset_only_in_reset`', '`core_reset` == sReset и `in_reset` == `core_reset`', 'сброс не приходит вне процедуры'),
    ('P7', '`P7_no_probe_before_alive`', 'Probe в DCache только после её `alive`', 'ProbeQueue вышла из сброса'),
    ('P8', '`P8_b_closed_only_in_procedure`, `P8B_…`', 'B закрыт только в процедуре; ограничено по времени после снятия запроса (`RST + ISO + 16`)', 'B не закрыт навсегда'),
    ('P8N', '`P8N_held_only_in_drain_iso`, `_taken_at_once`, `_ack_offered`', 'FULL: `hold_probe == sDrain | sIso`; в sReset / sRelease Probe берётся сразу, готовый ответ предложен', 'ответ гейта не задерживает L2'),
    ('P9', '`P9_no_new_noncoherent`', 'с начала процедуры по A ранних гейтов нет новых запросов', 'раннее закрытие A'),
    ('P10', '`P10_noncoherent_quiet_in_drain`', 'в sDrain некогерентные агенты тихи', 'зависимость Get → Probe'),
    ('P11', '`P11_hart_in_reset_is_busy`', '`hartInReset == busy == !sIdle`', 'DM видит харт «в сбросе» с первого такта'),
    ('P12', '`P12_one_at_a_time`, `_ack_is_NtoN`, `_ack_follows_probe`, `_not_inside_c_msg`, `_only_without_keep`, `_take_only_in_reset`', 'ответы гейта: один за раз, NtoN, после Probe, не внутри C ядра, только FULL, только в sReset / sRelease', 'ответ гейта законен'),
    ('P13', '`P13_reset_until_req_drops`', 'ядро выходит из сброса только после снятия запроса', 'сброс — уровень'),
    ('P14', '`P14_reset_at_least_rst`', 'каждый сброс не короче `rstCycles`', '[@3.2.2]'),
    ('P15', '`P15_isolation_tile_side`, `_core_side`', 'пока `isolate`, сторона тайла гейтов не зависит от ядра, ядру ничего не предлагается', 'выходы ядра в сбросе произвольны'),
    ('P16', '`P16_isolation_covers_reset`, `_only_in_procedure`', '`(core_reset | cr_q2) ⇒ isolate`; `isolate == sIso | sReset | sRelease`', 'нет окна без изоляции'),
    ('P17', '`P17_b_closed_when_isolated`', 'B держится или отвечается, пока ядро изолировано', 'общая маска для B'),
    ('P18', '`P18_b_held_from_first_drain_cycle`', 'B держится с первого такта sDrain', 'быстрое закрытие B'),
    ('P19', '`P19_decision_after_done_idle`', '`isolate` поднимается только после `done`, `idle` и `quiet` в такте решения', 'флаги вместо 16 тактов; `STALE_QUIET`'),
    ('P20', '`P20_run_only_after_frontend`', 'запуск только когда frontend вне сброса', 'sRelease ждёт самый поздний узел'),
    ('P21', '`P21_iso_lead`', '`core_reset` ↑ ⇒ `isolate` стоял `isoCycles` тактов (R3)', '<b>новое</b>: опережение изоляции'),
    ('P22', '`P22_iso_drop_after_core_up`', '`isolate` ↓ только при `alive_q && !core_in_reset_q` из sRelease (R4)', '<b>новое</b>'),
    ('P23', '`P23_l1_req_through_iso`', '`l1_req == sQuiesce | sDrain | sIso`', '<b>новое</b>: store не входит в MainPipe в sIso'),
    ('P24', '`P24_freeze_from_iso`', '`l1_freeze == (KEEP && isolate)`', '<b>новое</b>'),
    ('P25', '`P25_no_busy_gap`, `P25_busy_falls_only_from_release`', 'нет провала `busy` между последовательностями', '<b>новое</b>'),
]

MUT = {
    'CTRL_MUTANT_NO_DRAIN': 'sDrain → sIso без ожидания флагов и тишины',
    'CTRL_MUTANT_STALE_QUIET': 'решение по `quiet` прошлого такта (Probe последнего такта sQuiesce проскакивает)',
    'CTRL_MUTANT_NO_L1_IDLE': 'контроллер игнорирует `l1.idle` (ожидаемо эквивалентен в моделировании)',
    'CTRL_MUTANT_NO_ALIVE': 'sRelease не ждёт `alive` DCache (в моделировании эквивалентен: alive и frontend выходят в одном порядке)',
    'CTRL_MUTANT_NO_FE_WAIT': 'sRelease не ждёт выхода frontend из сброса',
    'CTRL_MUTANT_NO_EARLY_QUIET': 'выход из sQuiesce без тишины ранних гейтов',
    'CTRL_MUTANT_NO_EARLY_BLOCK': 'A некогерентных закрывается только с sDrain',
    'CTRL_MUTANT_LATE_HOLDB': 'B закрывается на такт позже (со второго такта sDrain)',
    'CTRL_MUTANT_NO_HOLD_IN_RELEASE': 'Probe открывается вместе со снятием `coreReset`, до конца sRelease',
    'CTRL_MUTANT_RESET_EARLY': 'сброс заканчивается при `cnt >= rstCycles` и при поднятом запросе',
    'CTRL_MUTANT_ISO_LATE': '`isolate` поднимается на такт позже `coreReset`',
    'CTRL_MUTANT_ISO_EARLY_DROP': '`isolate` снимается вместе с `coreReset`, до конца sRelease',
    'CTRL_MUTANT_NO_ISO_LEAD': '`isolate` и `coreReset` на одном фронте (как v5)',
    'CTRL_MUTANT_ISO_SHORT': 'sIso всегда 1 такт, игнорируя `isoCycles` (только ISO2)',
    'CTRL_MUTANT_NO_REQ_IN_ISO': '`l1.req` = 0 в sIso: DCache разблокируется за такт до сброса',
    'CTRL_MUTANT_LATE_HART_IN_RESET': '`hartInReset` только в sReset / sRelease (как v5)',
    'CTRL_MUTANT_BUSY_GAP': 'sRelease → всегда sIdle: `busy` падает на такт между последовательностями',
    'CTRL_MUTANT_IN_RESET_WIDE': '`core_in_reset` поднят в sReset и sRelease',
    'CTRL_MUTANT_NOKEEP_HOLDB': 'FULL: Probe держится в sReset / sRelease вместо ответа гейта',
    'CTRL_MUTANT_ACK_IN_ISO': 'FULL: гейт отвечает на Probe уже в sIso (`hold_probe` только sDrain)',
    'CTRL_MUTANT_LATE_FREEZE': 'KEEP: `freeze` только в sReset и sRelease, не с sIso',
    'GATE_MUTANT_ALWAYS_QUIET': '`quiet` гейта всегда 1',
    'GATE_MUTANT_CUT_A': 'A закрывается посреди многобитного Put',
    'GATE_MUTANT_NO_ISO_A': 'нет маски `isolate` на канале A (ожидаемо эквивалентен в `fv_boundary`)',
    'GATE_MUTANT_NO_ISO_B': 'нет зажима B по `isolate` (виден только в `fv_adapters`)',
    'GATE_MUTANT_NO_ISO_C': 'нет изоляции канала C',
    'GATE_MUTANT_NO_ISO_D': 'нет изоляции D ready',
    'GATE_MUTANT_NO_ISO_E': 'нет изоляции канала E',
    'GATE_MUTANT_NO_HOLDB': 'KEEP: гейт не держит B в sDrain',
    'GATE_MUTANT_NO_ACKB': 'FULL: гейт не отвечает на Probe',
    'GATE_MUTANT_ACK_PARAM': 'FULL: гейт отвечает не NtoN',
    'ISO_MUTANT_NO_ISO': '`TLResetIsolation` ничего не изолирует',
    'ISO_MUTANT_ALWAYS_QUIET': '`quiet` `TLResetIsolation` всегда 1 (ожидаемо эквивалентен)',
    'QUIESCE_MUTANT_NO_BLOCK': 'store, atomic и промахи не блокируются на время опустошения',
    'QUIESCE_MUTANT_NO_WBQ_WAIT': 'опустошение не ждёт WritebackQueue',
    'QUIESCE_MUTANT_NO_MP_WAIT': 'опустошение не ждёт MainPipe',
    'QUIESCE_MUTANT_NO_MQ_WAIT': 'опустошение не ждёт MissQueue (в том числе неотправленный Acquire)',
    'META_MUTANT_CORE_RESET': 'KEEP: `metaArray` сбрасывается сбросом ядра',
    'TAG_MUTANT_CORE_RESET': 'KEEP: теги стираются сбросом ядра, meta сохранена',
    'FREEZE_MUTANT_NO_SRAM_MASK': 'KEEP: запись SRAM тегов и данных не зажата',
    'FREEZE_MUTANT_NO_READ_MASK': 'KEEP: чтение SRAM и `read.valid` meta / error не зажаты',
    'NOKEEP_MUTANT_META_KEPT': 'FULL: `metaArray` переживает сброс (L1D не пуста)',
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
    s.append(P('Проверка v6 строится так: у каждой функции — направленная проверка и мутант; немой мутант считается дырой и называется в отчёте. Все '
               'числа документа берутся из файлов результатов `core-reset/verification/`, а не вписываются руками; если файла нет, написано «нет данных». '
               'Состав: 7.1 Chisel; 7.2 формальные доказательства (`fv_boundary`, `fv_adapters`); 7.3 эквивалентность RTL ↔ моделей; 7.4 симуляция на моделях; '
               '7.5 RTL-тест настоящей DCache; 7.6 тест изоляции тайла на RTL XSTile; 7.7 что нашла сама проверка. Версии: Yosys 0.70 (abc pdr, smtbmc с yices 2.6.5), '
               'Verilator %s. Проверки идут только на закоммиченном и запушенном состоянии.' % (C.verilator or ND)))
    s.append(table([
        ['Функция', 'Свойство / сценарий', 'Мутант'],
        ['сброс-уровень, ≥ 100 тактов', 'P13, P14, S6, S7; SCEN 3, 7, 9', '`RESET_EARLY`'],
        ['раннее закрытие A некогерентных', 'P9, S3', '`NO_EARLY_BLOCK`'],
        ['выход из sQuiesce при тишине некогерентных', 'P10, S4', '`NO_EARLY_QUIET`'],
        ['B закрыт с первого такта sDrain', 'P18, S5; SCEN 6 случай 4', '`LATE_HOLDB`; `GATE_MUTANT_NO_HOLDB` (KEEP)'],
        ['решение по `quiet` текущего такта', 'P1, P19; SCEN 6 случай 5', '`STALE_QUIET`'],
        ['флаги пустоты, опустошение', 'P19; SCEN 5 C1–C16; RTL D1–D11', '`NO_DRAIN`; `QUIESCE_MUTANT_NO_MQ_WAIT`, `_NO_WBQ_WAIT`, `_NO_MP_WAIT`, `_NO_BLOCK`'],
        ['опережение изоляции', 'P21, S9, T5', '`NO_ISO_LEAD`; `ISO_SHORT` (ISO2)'],
        ['снятие изоляции после выхода ядра', 'P22, P20, S8, T5', '`ISO_EARLY_DROP`, `NO_FE_WAIT`'],
        ['`l1.req` в sIso', 'P23; S18; K4', '`NO_REQ_IN_ISO` (`isoCycles` = 1 — только формально; ISO2 — S18)'],
        ['FULL: NtoN только в sReset / sRelease', 'P12, P8N, S13, K7', '`ACK_IN_ISO`, `GATE_MUTANT_NO_ACKB`, `_ACK_PARAM`'],
        ['KEEP: freeze с sIso', 'P24, S15, K5', '`LATE_FREEZE`, `FREEZE_MUTANT_NO_READ_MASK`, `_NO_SRAM_MASK`'],
        ['`hartInReset` = `busy`; `busy` без провала', 'P11, P25, S11, S12; SCEN 8', '`LATE_HART_IN_RESET`, `BUSY_GAP`'],
        ['изоляция TileLink-рёбер', 'P15, P17; L1–L3 (`fv_adapters`)', '`GATE_MUTANT_NO_ISO_A`…`_E`, `ISO_MUTANT_NO_ISO`'],
        ['маски предвыборки, боковые сигналы, `l1_keep_reset`', 'T1–T4, T6 (RTL тайла)', 'TM1 `PF_MASK_LATE`, TM2 `NO_SIDEBAND_ISO`, TM3 `KEEP_RESET_WITH_CORE`'],
        ['идентичность при `EnableCoreReset = false`', 'I1, I2', '— (сравнение с эталоном 7b16188)'],
    ], [1.9, 1.9, 2.0]))
    s.append(cap('Таблица: трассировка «функция — проверка — мутант» (TESTPLAN 1.2, редакция 18.11.2026).'))
    return s


def section71(C):
    s = [H(2, '7.1. Chisel: компиляция, elaboration, идентичность при EnableCoreReset = false')]
    s.append(P('<b>Компиляция.</b> `mill xiangshan.compile` — без ошибок и предупреждений (16 файлов `src/`). Ревью Chisel-кода (отдельный субагент Sonnet, '
               'дифф `src/` против DESIGN.md): 0 критических и существенных замечаний, две правки (881de97: маскирование `ready` запроса L2 TLB в последовательности и '
               'проверка записей meta / error под freeze). Версия v4 не компилировалась (конфликт `TLQuiesceGate.name` с `LazyModule.name`); в v5 и v6 поле называется `gateName`.'))
    s.append(P('<b>Elaboration модулей</b> (стенд `verification/elab`, `xiangshan.CoreResetElab`): `CoreResetCtrl` для FULL, KEEP и ISO2-вариантов, гейты '
               '(TL-C, TL-UL), `TLResetIsolation`, `DCacheQuiesceUnit`, настоящая DCache в двух режимах. RTL этих модулей (`verification/rtl/`) — вход проверки '
               'эквивалентности (7.3); `check.sh` сравнивает свежую выборку с закоммиченной, игнорируя номера строк `*.scala:N`.'))
    s.append(P('<b>Полная elaboration XSNoCTop</b> (`make verilog CONFIG=XSNoCTopConfig`, firtool отдельно, одна конфигурация за раз):'))
    el = C.elab
    if el:
        rows = [['Результат (`results_elab.txt`)']]
        for l in el.splitlines():
            if l.startswith('#'):
                continue
            rows.append([l.strip().replace('<', '&lt;')])
        s.append(table(rows, [5.8]))
        s.append(P('Строки «structural …: OK» — структурные проверки (E1: порты XSTop и модули `CoreResetCtrl`, `TLResetIsolation`, пять `TLQuiesceGate`, `DCacheQuiesceUnit`; '
                   'E2: в KEEP `metaArray`, `errorArray`, `tagArray` получают `keepReset`, `bankedDataArray` — сброс DCache, в FULL порта нет; E3: при `EnableCoreReset = false` ни одного вхождения '
                   '`CoreReset|Quiesce|keepReset|core_reset_req|core_in_reset` во всём RTL).', 'small'))
    else:
        s.append(P('Результат: ' + ND + '.'))
    s.append(P('<b>Идентичность при `EnableCoreReset = false`.</b> Эталон — RTL upstream 7b16188, сгенерированный один раз во временном git worktree тем же firtool; в ветке хранится '
               '<b>нормализованный манифест хешей</b> (`elab/ident_ref_7b16188.txt`), не сам RTL. Нормализация (`scripts/rtl_normalize.py`): убираются комментарии (в `XSTop.sv` '
               '`make verilog` дописывает `git log` и `git diff`), номера строк в сообщениях assert (`*.scala:N`), пустые строки; `sha256` каждого файла и итог по отсортированному манифесту.'))
    ident = C.ident or []
    if ident:
        s.append(table([['Сравнение с 7b16188']] + [[l.replace('<', '&lt;')] for l in ident], [5.8]))
    else:
        s.append(P(ND))
    s += box('Что нашла сама проверка: SHA коммита в NewCSR', [
        'Первый прогон идентичности (на 5c67d43) дал РАЗЛИЧИЕ только в `NewCSR.sv`: NewCSR хранит SHA коммита сборки и флаг dirty как `dontTouch`-провода '
        '(`NewCSR.scala:317–320`), и они зашиты в RTL числовыми константами. Это не изменение дизайна, а метка сборки. Нормализатор теперь маскирует `gitCommitSHA` и '
        '`gitDirty` во всех файлах (85a11b3); после этого результат IDENTICAL. Заодно `make verilog` обёрнут в GNU `time`, которого в контейнере нет: `TIME_CMD=`.',
    ], 'warn')
    s.append(P('В `--quick` то же сравнение делается на стенде DCache (I1: `ident_dcache`) — быстрый сигнал; идентичности XSTile / XSTileWrap / XSNoCTop он не доказывает, это делает полный XSNoCTop (I2, `--full`).'))
    return s


def _fmt_prove(m, key):
    v = m['prove'].get(key)
    return ('%s (%s с)' % (v[0], ru(v[1]))) if v else ND


def section72(C):
    s = [H(2, '7.2. Формальное доказательство')]
    s.append(P('Модель границы `fv_boundary.sv`: гейты g0 (TL-C), g1 (UL), g2 + `TLResetIsolation` (icachectrl), контроллер (`cr_ctrl`), двухтриггерный синхронизатор сброса ядра, '
               'frontend на 2 такта позже, независимые счётчики транзакций, DCache — свободный чёрный ящик со своими допущениями. Свойства — `assert`; доказательство — Yosys + abc pdr '
               '(без ограничения глубины). Конфигурации: <b>f</b> (FULL), <b>k</b> (KEEP), <b>f2</b> и <b>k2</b> — то же с `isoCycles` = 2.'))
    s.append(P('<b>Допущения среды</b> (каждое не сильнее гарантии дизайна; полный перечень A1–A14 — TESTPLAN 2.2): опкоды и ответы только на открытый запрос; не больше 5 открытых '
               'транзакций каждого вида; <b>окно свободы ядра</b> (A5): в sIso и в sReset все выходы ядра произвольны каждый такт — сильнее реальности, значит доказательство сильнее; '
               'в сбросе вне окна `valid` = 0, `alive` = 0; frontend выходит на 2 такта позже; `alive` поднимается не позже 6 тактов после выхода; `done → (req | req_q)` (A10, исправление v5: '
               '`DCacheQuiesceUnit` держит sDone ещё такт после падения `req`, `FakeDCache` — нет); `req`, Probe от L2 и все `ready` свободны, стабильности `valid` нет '
               '([@4.1] разрешает снять непринятый beat). CBO (опкоды 12–14, ответ CBOAck) — новое в v6.'))
    s.append(table([['P', 'Метки assert', 'Что утверждает', 'Зачем']] + [[p[0], p[1], p[2], p[3]] for p in PROPS], [0.35, 1.8, 2.5, 1.2]))
    s.append(cap('Свойства P1–P25 (25 номеров, 37 меток assert). P23, P24, P11, P6 — «контрактные» (переформулировка спецификации выхода): без них мутанты `NO_REQ_IN_ISO`, `LATE_FREEZE`, '
                 '`LATE_HART_IN_RESET`, `IN_RESET_WIDE` в этой модели не видны (среда произвольна в sIso, DCache нет); их функциональные следствия проверяются в моделировании (S15, S18, S11) и RTL-тесте (K4, K5).'))
    f, k = C.formal.get('f'), C.formal.get('k')
    s.append(P('<b>Результаты.</b> Unbounded-доказательство `abc pdr` заменяет BMC всей модели (BMC на всю глубину не сходится): в строке «bmc: not run» файлов результатов сказано, '
               'что допущения показаны выполнимыми достигнутыми покрытиями.'))
    rows = [['Конфигурация', 'prove `rstCycles` = 100', 'prove `rstCycles` = 16', 'prove 16, `isoCycles` = 2', 'covers достигнуто', 'мутантов с контрпримером']]
    for nm, ff in (('f (FULL)', f), ('k (KEEP)', k)):
        if not ff:
            rows.append([nm] + [ND] * 5)
            continue
        m, m2 = ff['main'], ff['iso2']
        rows.append([nm, _fmt_prove(m, (100, 1)), _fmt_prove(m, (16, 1)), _fmt_prove(m2, (16, 2)),
                     ('%d' % m['cover'][1]) if m['cover'] else ND,
                     '%d из %d (+ %d в iso2)' % (sum(1 for x in m['mutants'] if x[1] == 'FAIL'), len(m['mutants']), len(m2['mutants']))])
    s.append(table(rows, [1.0, 1.1, 1.0, 1.0, 0.8, 1.2]))
    for nm, ff in (('f', f), ('k', k)):
        if ff and ff['main']['covers']:
            s.append(P('Покрытия %s (ступень = длина трассы, найденной pdr, не обязательно кратчайшей): %s; в iso2: %s.' % (
                nm, ', '.join('%s — %d' % x for x in ff['main']['covers']),
                ', '.join('%s — %d' % x for x in ff['iso2']['covers']) or ND), 'small'))
    s.append(table([
        ['C', 'Что достигается', 'Конф.'],
        ['C1, C2', 'транзакции в полёте на старте → сброс', 'f, k'],
        ['C3', 'Probe удержан в сбросе, потом доставлен', 'k'],
        ['C4', 'возврат в sIdle', 'f, k'],
        ['C5', 'Probe в первом такте sDrain: KEEP — доставлен после, FULL — ответ гейта', 'f, k'],
        ['C6', 'долгий сброс (`RST + 24`) и запуск', 'f, k'],
        ['C7', 'ответ гейта в сбросе, затем запуск', 'f'],
        ['C8, C9', 'icachectrl в полёте на старте; мусор ядра в сбросе, затем запуск', 'f, k'],
        ['C10', 'две последовательности подряд, `busy` = 1 между ними', 'f, k'],
        ['C11', 'Probe предложен в sIso: держится, затем ответ гейта (FULL) или доставка (KEEP)', 'f, k'],
        ['C12', 'запрос снят в sQuiesce, последовательность всё равно дошла до sIdle', 'f, k'],
        ['C13', '`ack_pend` пережил sIdle, потом B снова открыт', 'f'],
        ['C14', 'sIso длится 2 такта', 'f2, k2'],
    ], [0.6, 4.5, 0.7]))
    s.append(cap('Покрытия `fv_boundary` (в прогоне — как `assert !(Cn)` через pdr).'))
    s.append(P('<b>fv_adapters</b> — локальность изоляции: три адаптера с <b>свободными</b> управляющими входами (`block`, `hold_b`, `ack_b`, `isolate`), без допущения `isolate → hold_b | ack_b`. '
               'Это закрывает два мутанта, эквивалентных в v5 (`NO_ISO_B`, `NO_ISO_A`), и показывает, что зажим держится регистром сам. Свойства: L1 (TL-C при `isolate`: к L2 `a`, `e` valid = 0, `d.ready` = 0, '
               '`b.ready == (ack_b | pend) && take_b`; к ядру `b`, `d` valid = 0, ready A/C/E = 0), L2 (UL), L3 (`TLResetIsolation`), L4 (`quiet` честен), L5 (A режется только на границе сообщения), '
               'L6 (ответ гейта: один в полёте, NtoN, адрес = адрес Probe).'))
    a = C.adapters
    if a:
        s.append(P('prove `fv_adapters`: %s; мутантов с контрпримером: %d из %d.' % (_fmt_prove(a, (0, 1)), sum(1 for x in a['mutants'] if x[1] == 'FAIL'), len(a['mutants']))))
    # mutant table
    s.append(P('<b>Мутанты (формально).</b> Каждый должен упасть; указано свойство-ловец и такт контрпримера (`bmc` — искал abc bmc, `pdr` — после того, как bmc не нашёл за лимит).'))
    names = []
    for ff in (f, k):
        if ff:
            for sec in ('main', 'iso2'):
                for m in ff[sec]['mutants']:
                    if m[0] not in names:
                        names.append(m[0])
    rows = [['Мутант', 'Что ломает', 'FULL', 'KEEP']]

    def cell(ff, nm):
        if not ff:
            return ND
        for sec in ('main', 'iso2'):
            for m in ff[sec]['mutants']:
                if m[0] == nm:
                    return '%s, такт %d%s: %s' % (m[1], m[2], ' (pdr)' if m[4] == 'pdr' else '', ' '.join(m[3][:2]) or '—')
        return '—'
    for nm in names:
        rows.append(['`%s`' % nm.replace('CTRL_MUTANT_', '').replace('GATE_MUTANT_', 'GATE_').replace('ISO_MUTANT_', 'ISO_'), desc(nm), cell(f, nm), cell(k, nm)])
    s.append(table(rows, [1.3, 1.9, 1.35, 1.35]))
    s.append(cap('Мутанты `fv_boundary`: 27 в f, 25 в k, ещё `ISO_SHORT` и `NO_ISO_LEAD` в f2 и k2. «—» — мутант в этой конфигурации не строится.'))
    eqs = []
    for ff in (f, k):
        if ff:
            for e in ff['main']['equiv']:
                if e not in eqs:
                    eqs.append(e)
    s.append(P('<b>Ожидаемо эквивалентные</b> (замороженный список; `prove` обязан пройти): %s. `GATE_MUTANT_NO_ISO_B` в `fv_boundary` не запускается (по P17 он там эквивалентен; список не расширялся '
               'без решения пользователя), он убивается в `fv_adapters`.' % (', '.join('`%s` — %s' % e for e in eqs) or ND)))
    if a:
        rows = [['Мутант (`fv_adapters`)', 'Что ломает', 'Результат']]
        for m in a['mutants']:
            rows.append(['`%s`' % m[0], desc(m[0]), '%s, такт %d: %s' % (m[1], m[2], ' '.join(m[3][:2]) or '—')])
        s.append(table(rows, [1.7, 2.6, 1.5]))
    tot = []
    for nm, ff in (('f', f), ('k', k)):
        if ff:
            tot.append('%s: неожиданных результатов %s' % (nm, ff['final'] if ff['final'] is not None else ND))
    if C.adapt_full and C.adapt_full['final'] is not None:
        tot.append('adapters: неожиданных результатов %s' % C.adapt_full['final'])
    if tot:
        s.append(P('Итог прогонов: ' + '; '.join(tot) + '.'))
    return s


def section73(C):
    s = [H(2, '7.3. Эквивалентность RTL ↔ модели')]
    s.append(P('Формальная часть и симуляция доказывают свойства <b>моделей</b> (`cr_ctrl`, `cr_gate`, `cr_iso`, `cr_quiesce`). Чтобы вывод относился к Chisel, RTL, сгенерированный из Chisel '
               '(`extract_rtl.py` вырезает модули из elaboration), сравнивается с моделью миттером: общие входы, равенство всех выходов в каждом такте. Движки: bmc 30 тактов (smtbmc, yices) и unbounded `prove` (abc pdr). '
               'Допущения входов — те же, что в 7.2.'))
    e = C.eq
    if e and e['rows']:
        what = {
            'ctrl_full': 'контроллер FULL, `isoCycles` = 1: все 11 выходов', 'ctrl_keep': 'контроллер KEEP, `isoCycles` = 1',
            'ctrl_full_iso2': 'контроллер FULL, `isoCycles` = 2', 'ctrl_keep_iso2': 'контроллер KEEP, `isoCycles` = 2',
            'gate_c': 'гейт TL-C (l1d) + RTL-only assert-ы ответа гейта: ProbeAck, NtoN, `source` / `address` / `size` Probe, `corrupt` = 0',
            'gate_ul': 'гейт TL-UL (ранний)', 'iso': '`TLResetIsolation`', 'quiesce': '`DCacheQuiesceUnit`: `block`, `done`, `idle`, `alive`'}
        rows = [['Миттер', 'Что сравнивается', 'bmc 30', 'prove']]
        for r in e['rows']:
            rows.append(['`%s`' % r[0], what.get(r[0], ''), '%s, %s с' % (r[2], ru(r[3], 1)), '%s, %s с' % (r[4], ru(r[5], 1))])
        s.append(table(rows, [1.0, 3.2, 0.9, 0.9]))
        s.append(P('Миттеров, не прошедших: %s.' % (e['failed'] if e['failed'] is not None else ND)))
    else:
        s.append(P(ND))
    s.append(P('Ограничения: сравниваются управляющая логика, гейты и автомат DCache; массивы и тела очередей DCache в миттер не входят (их проверяет RTL-тест 7.5). Кодирование опкодов дополнено CBO '
               '(модель A 5 ↔ RTL 12–14) и CBOAck (D 2 ↔ RTL 8).', 'small'))
    return s


def section74(C):
    s = [H(2, '7.4. Симуляция на моделях')]
    s.append(P('Testbench на Verilator, модели на SystemVerilog: <b>контроллер</b> (`cr_ctrl`, эквивалентен RTL — 7.3), <b>гейты</b> и `cr_iso`, <b>DCache</b> (`cr_dcache`: MainPipe с флагами пустоты, MissQueue, '
               'WritebackQueue, ProbeQueue, массивы, модель обращений к SRAM под freeze, модель гонки асинхронного сброса в первых тактах), <b>L2</b> (`cr_l2`: директория, Probe, зависимость Get → Probe, '
               'в FULL — устаревшая директория), эталон данных. Конфигурации: FULL, CFG_KEEP, ISO2 (`isoCycles` = 2), CFG_KEEP+ISO2.'))
    s.append(table([
        ['SCEN', 'Что'],
        ['1', 'три сброса (короткий запрос) на фоне трафика и снупов'],
        ['2', '12 сбросов подряд со случайными паузами'],
        ['3', 'запрос случайной длины (2..2000) × 4'],
        ['4', 'наивный сброс без последовательности — ошибки ожидаются'],
        ['5', 'старт последовательности в момент транзакции класса C1–C16 (C13: load читает SRAM в такте решения; C14: CBO — пропускается в модели, проверяется формально и RTL-тестом D6; C15: Probe в такте решения; C16: неотправленный Acquire в MissQueue)'],
        ['6', 'направленные Probe строк L1D (грязная / чистая T / B, toN / toB), случаи 0–8: sReset, sRelease, после, старт sQuiesce, первый такт sDrain, последний такт sQuiesce, первый такт sIso, такт решения, такт `coreUp`'],
        ['7', 'долгий `debug_reset` (2000..20000) со снупами'],
        ['8', '<b>сбросы подряд</b>: запрос снят в sReset и поднят снова (а) в sRelease, (б) ровно в такте `coreUp`, (в) через такт после sIdle, (г) не снимается'],
        ['9', '<b>снятие / подъём запроса в каждом состоянии</b>: импульс в sIdle, снятие в sQuiesce, sDrain, sIso, sReset (до и после `rstCycles`), sRelease'],
    ], [0.5, 5.3]))
    s.append(P('Проверки S1–S23: S1 точка сброса чиста; S2 в sIso / sReset / sRelease через границу ничего; S3–S4 раннее закрытие A; S5 Probe не проходит гейт в sDrain и sIso; S6–S7 длина и конец сброса; '
               'S8 `isolate` падает только после `alive && !fe_rst`; <b>S9</b> опережение: подъём сброса только после `isoCycles` тактов `isolate`; S10 `isolate` только в процедуре; S11 `hart_in_reset == busy`; '
               '<b>S12</b> один сброс на запрос, sRelease → sQuiesce без провала `busy`; S13 FULL: гейт берёт Probe только в sReset / sRelease, один ProbeAck NtoN на Probe; S14 KEEP: гейт не отвечает, удержанный Probe доставляется после; '
               '<b>S15</b> KEEP: `arr_access` = 0, пока `isolate`; S16 KEEP: строки L1D после сброса равны директории и эталону; S17 FULL: L1D пуста; <b>S18</b> DCache не принимает store / AMO / CMO / промах со второго такта до сброса; '
               'S19 после `done` не начинается Release; S20, S23 данные (FULL — с учётом известных потерь, счётчики `full.*`); S21 отчёт ProbeAck против директории (FULL: NtoN законен для устаревшей строки); S22 Probe не ждёт дольше 200 тактов вне сброса.', 'small'))
    s.append(P('<b>Модель L2 для FULL.</b> Директория устаревает: после точки сброса строки, которые L2 числит за L1D, помечены `stale`; NtoN по такой строке и повторный Acquire — законны (7.2 п. 2); потеря грязных '
               'данных и чужие данные после AcquirePerm — не `$error`, а счётчики (`full.lost_dirty`, `full.foreign_lines`, `full.foreign_grant`), эталон данных сравнивается с копией L2 и пропускает строки без определённого значения '
               '(`golden_valid`). В KEEP то же — ошибка.'))
    r = C.reg
    if r:
        rows = [['Конфигурация', 'прогонов дизайна PASS', 'наивный сброс воспроизведён', 'мутантов поймано', '+EQUIV PASS']]
        for cname in ('FULL', 'CFG_KEEP', 'ISO2', 'CFG_KEEP+ISO2'):
            c = r['cfg'][cname]
            rows.append([cname, '%d / %d' % (c['design_pass'], c['design']), '%d / %d' % (c['naive_rep'], c['naive']),
                         '%d / %d' % (c['mut_caught'], c['mut']), '%d / %d' % (c['eq_pass'], c['eq'])])
        td = sum(c['design'] for c in r['cfg'].values())
        tp = sum(c['design_pass'] for c in r['cfg'].values())
        tn = sum(c['naive'] for c in r['cfg'].values())
        tnr = sum(c['naive_rep'] for c in r['cfg'].values())
        tm = sum(c['mut'] for c in r['cfg'].values())
        tmc = sum(c['mut_caught'] for c in r['cfg'].values())
        te = sum(c['eq'] for c in r['cfg'].values())
        tep = sum(c['eq_pass'] for c in r['cfg'].values())
        rows.append(['<b>всего</b>', '%d / %d' % (tp, td), '%d / %d' % (tnr, tn), '%d / %d' % (tmc, tm), '%d / %d' % (tep, te)])
        s.append(table(rows, [1.3, 1.2, 1.3, 1.2, 0.9]))
        s.append(cap('Регрессия (`results_regress.txt`). Прогон считается пойманным мутантом, если стенд сообщил ошибку. Пропущенных (SKIPPED): %d. Регрессия завершена без отклонений: %s.' % (
            r['skipped'], 'да' if r['complete'] else 'нет')))
        # by scen
        full = r['cfg']['FULL']['by_scen']
        keep = r['cfg']['CFG_KEEP']['by_scen']
        keys = sorted(set(full) | set(keep))
        rows = [['SCEN', 'FULL', 'CFG_KEEP']]
        for kk in keys:
            f_ = full.get(kk)
            k_ = keep.get(kk)
            rows.append(['%d%s' % (kk[0], ' +SLOW' if kk[1] else ''), ('%d / %d' % (f_[1], f_[0])) if f_ else '—', ('%d / %d' % (k_[1], k_[0])) if k_ else '—'])
        s.append(table(rows, [1.0, 1.0, 1.0]))
        s.append(cap('Прогоны дизайна по сценариям (PASS / всего). Наивный сброс — SCEN 4, 3 прогона на конфигурацию, ошибки обязаны воспроизвестись.'))
        # mutants
        rows = [['Мутант (регрессия)', 'Что ломает', 'FULL', 'KEEP', 'ISO2 / KEEP+ISO2', 'SCEN']]
        for nm in sorted(r['mut']):
            d = r['mut'][nm]
            def cc(c):
                a = d.get(c)
                return ('%d / %d' % (a['ok'], a['runs'])) if a else '—'
            iso = '; '.join(cc(c) for c in ('ISO2', 'CFG_KEEP+ISO2')) if ('ISO2' in d or 'CFG_KEEP+ISO2' in d) else '—'
            sc = sorted(set().union(*[a['scen'] for a in d.values()]))
            rows.append(['`%s`' % nm.replace('CTRL_MUTANT_', '').replace('GATE_MUTANT_', 'GATE_').replace('ISO_MUTANT_', 'ISO_').replace('QUIESCE_MUTANT_', 'Q_'),
                         desc(nm), cc('FULL'), cc('CFG_KEEP'), iso, ' '.join(str(x) for x in sc)])
        s.append(table(rows, [1.5, 2.3, 0.5, 0.5, 0.6, 0.4], size=None))
        s.append(cap('Мутанты регрессии: пойманных прогонов / всего. Суффикс `+NO_CTRL_ASSERT` в имени — assert-ы контроллера выключены (иначе их ловит assert, а не проверка стенда); «Q_» = `QUIESCE_MUTANT_`.'))
        ee = r['equiv']
        s.append(P('<b>Ожидаемо эквивалентные в моделировании</b> (замороженный список): %s. В формальной части оба ловятся (P19; P22, P20). Список заморожен решением пользователя и не расширялся. '
                   'Прогонов: %d, PASS: %d.' % (
                       ', '.join('`%s`' % x for x in sorted(ee)), sum(sum(a['runs'] for a in d.values()) for d in ee.values()), sum(sum(a['ok'] for a in d.values()) for d in ee.values()))))
        s.append(P('<b>+FORMALONLY.</b> `CTRL_MUTANT_NO_REQ_IN_ISO` при `isoCycles` = 1 в моделировании <b>не виден по построению</b>: блокировка DCache снимается через такт после `l1.req`, то есть уже в sReset '
                   '(так же в RTL `DCacheQuiesceUnit`). Он ловится формально (P23, 7.2). Прогонов с меткой `+FORMALONLY` (SCEN 2 и 5, обе конфигурации): %d, поймано в моделировании: %d — так и ожидалось; '
                   'в замороженный список эквивалентных он не добавлен. При `isoCycles` = 2 (ISO2, CFG_KEEP+ISO2, SCEN 2) мутант ловится стендом (S18, S1).' % (r['fonly'], r['fonly_caught'])))
    else:
        s.append(P('Регрессия: ' + ND))
    rare = C.rare
    if rare:
        s.append(P('<b>Редкие мутанты и их сиды.</b> Сиды v5 подобраны под модель v5 и Verilator 5.049 и недействительны; `seedsearch.sh` подобрал новые (формат «сценарий:сид»):'))
        rows = [['Конфигурация', 'Мутант', 'Сиды']] + [[a, '`%s`' % b, ' '.join(c)] for a, b, c in rare]
        s.append(table(rows, [0.9, 2.6, 2.3]))
    # soak
    sf, sk = C.soak.get('FULL'), C.soak.get('CFG_KEEP')
    s.append(P('<b>Длинный прогон</b> (`soak.sh`: SCEN 1–3 × 100 сидов + 90 +SLOW, SCEN 5 × 50, SCEN 6–9 × 25 — по 540 на конфигурацию): FULL — %s, KEEP — %s прогонов PASS.' % (
        ('%d / %d' % (sf['pass'], sf['runs'])) if sf else ND, ('%d / %d' % (sk['pass'], sk['runs'])) if sk else ND)))
    cf, ck = C.cov.get('FULL'), C.cov.get('CFG_KEEP')
    if cf and ck:
        keys = [('final.resets', 'сбросов'), ('final.probes', 'Probe'), ('final.probes-held', 'удержанных Probe'),
                ('drain.sDrain-phases', 'фаз sDrain'), ('drain.longest-sDrain', 'самый длинный sDrain, тактов'),
                ('drain.probes-held-in-sDrain', 'Probe, удержанных в sDrain'), ('drain.get-probes', 'Get → Probe (зависимость в L2)'),
                ('iso.phases', 'фаз изоляции'), ('iso.garbage_masked', 'мусорных обращений к массивам, снятых freeze'),
                ('iso.loads_clamped', 'load, зажатых в sIso / sReset'), ('iso.sram_access_in_iso', 'обращений к SRAM при `isolate` (KEEP обязан быть 0)'),
                ('b2b.direct', 'сбросов подряд напрямую (sRelease → sQuiesce)'), ('b2b.gap', 'сбросов подряд с зазором ≤ 4 тактов'),
                ('b2b.probes_across', 'Probe, удержанных через два сброса'), ('full.lost_dirty', 'FULL: потеряно грязных строк'),
                ('full.foreign_lines', 'FULL: строк с чужими данными после AcquirePerm'), ('full.nton_stale', 'FULL: NtoN по устаревшей директории'),
                ('full.reacquire_stale', 'FULL: повторных Acquire устаревшей строки'), ('full.gate_acks', 'FULL: ответов гейта')]

        def g(c, k_):
            if k_ in c:
                return str(c[k_])
            return '— (в этом режиме не бывает)' if k_.startswith('full.') else ND
        rows = [['Показатель покрытия (длинный прогон)', 'FULL', 'KEEP']]
        for kk, nm in keys:
            rows.append([nm, g(cf, kk), g(ck, kk)])
        s.append(table(rows, [3.4, 1.2, 1.2]))
        s.append(cap('Покрытие (`coverage_FULL.json`, `coverage_CFG_KEEP.json`): суммы по всем прогонам soak. Нули там, где режим по построению не даёт события (например, `full.*` в KEEP).'))
        trig = ['C%d' % i for i in range(1, 17)]
        rows = [['Класс SCEN 5'] + trig, ['FULL: попаданий'] + [str(cf.get('trig_hit.' + t, ND)) for t in trig],
                ['KEEP: попаданий'] + [str(ck.get('trig_hit.' + t, ND)) for t in trig]]
        s.append(table(rows, [0.9] + [0.3] * 16))
        s.append(cap('Классы транзакций SCEN 5, попавшие в старт последовательности (C14 — CBO в модели не моделируется, строка `SKIPPED C14` в логе).'))
    else:
        s.append(P('Покрытие: ' + ND))
    s += box('Почему приведены не только PASS: что показывает покрытие', [
        'Покрытие нужно, чтобы проверка не была пустой: направленные Probe SCEN 6 предложены в каждой из точек (старт sQuiesce, последний такт sQuiesce, первый такт sDrain, первый такт sIso, '
        'такт решения, sReset, sRelease, сразу после) для пяти видов строк (`dir.*`); в KEEP Probe проходит через два сброса (`b2b.probes_across`); `iso.sram_access_in_iso` в FULL больше нуля '
        '(зонды K5 и условие S15 не пусты), в KEEP равно нулю.',
    ])
    return s


def section75(C):
    s = [H(2, '7.5. RTL-тест настоящей DCache')]
    s.append(P('До v6 флаги пустоты и блокировки проверялись только на модели `cr_dcache`. Ревью дизайна (находка 2) потребовало прогнать <b>настоящий RTL</b>: Chisel-harness '
               '`CoreResetDCacheHarness` elaborate-ит `DCacheWrapper` + `TLBuffer` + `TLQuiesceGate("l1d")` с менеджером, параметры которого скопированы с CoupledL2; контроллер — RTL `CoreResetCtrl_*` '
               'из `rtl/` либо (для мутантов) модель `cr_ctrl` с `+define+CTRL_MODEL`. Стенд `tb_rtl/` — TL-C ответчик `rtl_l2` с директорией клиента, данными, отравлением после AcquirePerm, устареванием (FULL), '
               'CBO, управляемыми задержками и независимым счётчиком транзакций; драйверы store, AMO, LR/SC, AMOCAS, CBO, WFI, load. Режимы: FULL, KEEP, KEEP+ISO2.'))
    s.append(table([
        ['D', 'Случай', 'Что ожидается сверх K*'],
        ['D1', 'промах store (AcquireBlock) в полёте, Grant задержан на 0 / 5 / 40', '`done` после GrantAck; KEEP: строка T dirty после сброса'],
        ['D2', 'store на всю строку (AcquirePerm)', 'FULL: после сброса строка отравлена — `full.foreign_lines` (9.1); KEEP: ProbeAckData = данные store'],
        ['D3', 'промах AMO (`amoadd.d`)', 'ответ AMO выдан до `done`; KEEP: строка с результатом'],
        ['D4', 'LR (промах), запрос, SC', 'SC после сброса — неуспех (резервирования нет); Probe в окне LR/SC не дольше `LRSCCycles`'],
        ['D5', 'промах `amocas.d`', 'как D3'],
        ['D6', 'CBO clean / flush / inval к грязной строке', '`done` после CBOAck; ProbeAckData с данными'],
        ['D7', 'WFI с неотправленным Acquire', 'Acquire уходит в sQuiesce (блокировка снимает `wfiReq`), последовательность ≤ 2000 тактов'],
        ['D8', 'Probe в последнем такте sQuiesce', 'Probe принят, sDrain ждёт ProbeAck, sIso только после'],
        ['D9', 'Probe в первом такте sDrain', 'держится; FULL: ответ гейта в sReset; KEEP: после — L1D с данными'],
        ['D10', 'Probe в sIso, sReset, sRelease', 'FULL: гейт NtoN ровно один; KEEP: держится до конца sRelease'],
        ['D11', 'Release в полёте (вытеснение), ReleaseAck задержан', '`done` после ReleaseAck'],
        ['D12', 'запросы подряд (повторный подъём в sRelease; импульс в sIdle)', 'sRelease → sQuiesce, `busy` без провала'],
        ['D13', 'load через sIso (load каждый такт с последнего такта sDrain)', 'KEEP: `sram_access_in_iso` = 0; FULL: > 0 (непустота зондов K5)'],
        ['R', 'случайная смесь store / AMO / CBO / load / Probe и запросов', 'все K*'],
    ], [0.4, 2.6, 2.8]))
    s.append(table([
        ['K', 'Проверка'],
        ['K1', 'точка сброса: `gate.quiet` и независимый счётчик `rtl_l2` — ничего не открыто (Acquire, Grant без GrantAck, Release без ReleaseAck, Probe без ProbeAck, CBO без CBOAck), нет половины сообщения'],
        ['K2', 'подъём `l1.done`: все транзакции закончены по счётчику L2, ответы store / AMO / CBO выданы; в такте решения `l1.idle` = 1'],
        ['K3', 'после `done` не начинается Release (счётчик L2 + assert DCacheImp)'],
        ['K4', 'со второго такта `l1.req` до сброса: ни одного fire на `st_req`, `amo_req`, `cmoOpReq`, ни нового Acquire'],
        ['K5', 'KEEP: пока `isolate`, на зондах границ модулей (`tagArray`, `bankedDataArray`, `metaArray`, `errorArray`) и самих `*_ext` SRAM (`R*_en`, `W*_en`, `RW*_en`) нет обращений'],
        ['K6', 'в sIso / sReset / sRelease ничего не пересекает гейт (кроме ProbeAck гейта в FULL)'],
        ['K7', 'FULL: гейт берёт Probe только в sReset / sRelease, на каждый — один ProbeAck NtoN, без данных; KEEP: гейт не берёт Probe никогда'],
        ['K8', 'после последовательности: FULL — L1D пуста; KEEP — строки целы (отчёт ProbeAck совпадает с директорией, ProbeAckData = эталону, load-попадание = эталону)'],
        ['K9', 'ни один assert RTL (DCache, гейт, контроллер) не сработал'],
        ['K10', 'данные: эталон vs L2 / L1D; FULL — с учётом 9.1, KEEP — строго'],
        ['K11', 'протокол на стороне L2: опкоды, параметры, beat-ы, source / sink, Release не NtoN, ProbeAckData не NtoN'],
    ], [0.4, 5.4]))
    s.append(P('<b>Мутанты RTL-теста.</b> Chisel не мутируется; контроллер заменяется моделью `cr_ctrl` с тем же `define`: `NO_DRAIN` (D1, D11 — K1 / K9), `STALE_QUIET` (D8 — K1), `LATE_HOLDB` (D9 — K6), '
               '`NO_REQ_IN_ISO` (R, D13 — K4), `NO_ISO_LEAD` (D1 — assert контроллера), `ACK_IN_ISO` (FULL, D10 — K7), `LATE_FREEZE` (KEEP, D13 — K5); плюс контрольный прогон «модель без мутанта» — PASS.'))
    rd = C.rtl_dcache
    if rd and rd['rows']:
        sm = rd['summary']
        rows = [['Конф.', 'Прогонов дизайна (RTL и модель)', 'PASS', 'Мутантов', 'Поймано']]
        for cfg in ('FULL', 'KEEP', 'KEEP+ISO2'):
            rr = [x for x in rd['rows'] if x['cfg'] == cfg]
            des = [x for x in rr if not x['ctrl'].startswith('model+')]
            mu = [x for x in rr if x['ctrl'].startswith('model+')]
            rows.append([cfg, str(len(des)), str(sum(1 for x in des if x['res'] == 'PASS')), str(len(mu)), str(sum(1 for x in mu if x['res'] != 'PASS'))])
        s.append(table(rows, [1.0, 1.9, 0.8, 1.0, 1.0]))
        s.append(P('Итог файла: ' + (('прогонов %d, PASS %d, FAIL %d; мутантных прогонов %d, поймано %d' % sm) if sm else ND) + '.'))
        tl = sum(int(m) for x in rd['rows'] for m in __import__('re').findall(r'lost-dirty=(\d+)', x['rest']))
        s.append(P('По строкам FULL: суммарно потеряно грязных строк (`lost-dirty`) %d — это известное нарушение 9.1 в действии, не ошибка проверки.' % tl, 'small'))
    else:
        s.append(box('Результат RTL-теста DCache', [
            'Файл `results_rtl_dcache.txt` на момент сборки документа отсутствует: ' + ND + '. Полный набор (FULL, KEEP, KEEP+ISO2 × D1–D13 × сиды 1–3, R × сиды 1–10 и мутанты) выполняется шагом `rtl_dcache` команды `check.sh --full`; '
            'в `--quick` входит FULL, D1–D13, сид 1. Пересоберите документ после появления файла: числа подставятся автоматически.'], 'warn')[0])
    s.append(P('Ограничения теста: нет LSU / sbuffer / предвыборки (MemBlock), один порт load без replay-логики LSU; L2 — модель с одним клиентом, без CHI и HN; параметры только `XSNoCTopConfig` '
               '(WPU выключен, `SramedDataArray` не собирается — проверен по коду).', 'small'))
    return s


def section76(C):
    s = [H(2, '7.6. Тест изоляции тайла на RTL XSTile')]
    s.append(P('Таблицу 6.5 нельзя проверить моделью: сигналов много, и забытый — именно то, что искал бы обзор. RTL `XSTile` из полной elaboration XSNoCTop (FULL и KEEP) моделируется Verilator-ом с <b>заглушками</b> вместо '
               '`XSCore` и `L2Top`: заглушка ядра выдаёт мусор на всех выходах, пока `isolate`, а стенд требует, чтобы ни один вход `L2Top` и ни один выход `XSTile` при этом не менялись (кроме разрешённых). '
               'Контроллер в XSTile — настоящий RTL.'))
    s.append(table([
        ['T', 'Проверка'],
        ['T1', 'со второго такта `isolate` до его конца все входы `L2Top` и выходы `XSTile` стабильны (кроме `core_in_reset` и записанных в allowlist с ссылкой на DESIGN)'],
        ['T2', 'значения зажимов в первом такте `isolate` по таблице 6.5: `cpu_halt`, `cpu_critical_error`, `msiAck`, `l2_flush_en`, `beu_errors.*.valid`, trace `valid`, `iretire`, `itype`, `robHeadPaddr.valid`, `l2_tlb_req.req.ready`, `.resp.valid` — 0; `resetInFrontend` в L2Top — 1; `l2_pmp_resp` — все 1'],
        ['T3', 'пока `busy`: `addr_valid` моста предвыборки на входе L2Top = 0 и `l2_pf_master_en` = 0 при 1 от ядра'],
        ['T4', 'пока `busy`: `l2_tlb_req.req.valid` на входе ядра = 0'],
        ['T5', 'порт сброса заглушки ядра поднимается только после ≥ 1 такта `isolate`; `isolate` падает только после `alive && !resetInFrontend`; `core_in_reset` = только sReset; `core_reset_busy` и `hartIsInReset` = `busy`'],
        ['T6', 'KEEP: `l1_keep_reset` ядра не поднимается во время последовательности; FULL: порта нет'],
        ['T7', 'каждый из трёх входов запроса сам запускает последовательность через 3 такта синхронизатора; одновременные — одну'],
    ], [0.4, 5.4]))
    s.append(P('<b>Мутанты тайла</b> — текстовые патчи сгенерированного `XSTile.sv` (SKIPPED = дыра в отчёте): TM1 `PF_MASK_LATE` (убрать `!busy` из `addr_valid`) — ловят T3; TM2 `NO_SIDEBAND_ISO` (убрать зажим `cpu_halt`) — T1 / T2; '
               'TM3 `KEEP_RESET_WITH_CORE` (KEEP: `l1_keep_reset` от сброса ядра) — T6.'))
    t = C.tile
    if t:
        rows = [['Конфигурация', 'Мутант', 'Результат']] + [[('`%s`' % a), (b or '—'), c.replace('<', '&lt;')] for a, b, c in t['rows']]
        s.append(table(rows, [1.0, 1.0, 3.8]))
        s.append(P('Неожиданных результатов: %s. Счётчики прогона и значения срабатывания мутантов — в заголовке `results_tile_iso.txt`: ' % (t['unexpected'] if t['unexpected'] is not None else ND) +
                   ' '.join(l[1:].strip() for l in t['raw'].splitlines() if l.startswith('#') and ('counters' in l or 'mutants' in l or 't3' in l or 'T7' in l or 'TM' in l)).replace('<', '&lt;'), 'small'))
        s.append(box('Что в этом тесте SKIP и почему', [
            'Строка `T2 SKIP` — два требуемых шаблона отсутствуют в данной конфигурации: `robHeadPaddr_valid` (TopDown не собран) и `l2_tlb_req_req_ready` (`ready` не используется CoupledL2, удалён firtool). '
            'Это явные пропуски в отчёте, а не молчаливые: любой другой отсутствующий шаблон проваливает тест. Остальные сигналы таблицы 6.5 проверены.'], 'warn')[0])
    else:
        s.append(P(ND))
    return s


def section77(C):
    s = [H(2, '7.7. Что нашла сама проверка')]
    s.append(P('Ниже — ошибки и дефекты, которые нашли сами проверки (не человек, читающий код). Ошибки стенда исправлены и описаны; проверки не ослаблялись. Смоук-прогоны моделей нашли пять ошибок стенда и ни одной ошибки дизайна (сообщение коммита ecbaed6); '
               'остальное — дефекты планов, моделей и допущений.'))
    s.append(table([
        ['Что нашлось', 'Кто нашёл', 'Что сделано'],
        ['Ревью Chisel (Sonnet): `ready` запроса L2 TLB ядра не маскировался на время последовательности; записи meta / error под freeze не проверялись assert-ом', 'ревью кода', 'исправлено (881de97): `ready` маскируется `&& !busy`; assert покрывает meta и error'],
        ['SCEN 1–9, первые прогоны: <b>устаревшая директория</b> — запись L2, помеченная `stale` после сброса FULL, обязана быть исключена из точной проверки директории до перезаписи Grant-ом', 'смоук стенда (ecbaed6)', 'ошибка модели: проверка исправлена, запись остаётся stale до Grant'],
        ['<b>Собственный ProbeAck гейта</b>, пережившая последовательность (`ackPending`, медленный `c_ready`), считался транзакцией ядра в S1 точки сброса', 'смоук стенда', 'ошибка стенда: это сообщение гейта (DESIGN 3), S1 его не считает'],
        ['SCEN 6 случай 8 снимал запрос до ожидания снупа; SCEN 9 «подъём в sRelease» ожидал один сброс вместо двух', 'смоук стенда', 'сценарии исправлены; <b>новая проверка S12</b> (запрос высок в `coreUp` ⇒ не sIdle) — она ловит `BUSY_GAP`, молчавший до неё'],
        ['`PmemRanges`: DCache проверяет assert-ом (`DCacheWrapper.scala:1802`), что адрес каждого Acquire лежит в `PmemRanges` (бит 31 и ниже 2^43); адреса стенда лежали вне', 'RTL-тест (assert Chisel-кода)', 'ошибка стенда: адресное пространство `rtl_l2` / драйвера перенесено'],
        ['K11: <b>`source` в ProbeAck</b>. Проверка требовала source Probe; DCache отвечает через WritebackQueue, где source — идентификатор записи', 'RTL-тест', 'ошибка стенда: допустим source Probe либо id записи write-back (текст проверки в `rtl_l2.sv`)'],
        ['<b>D13: поток load</b> продолжался после выхода ядра из сброса и перезаполнял L1D — проверка «L1D пуста после сброса» в FULL видела чужую строку', 'RTL-тест (4a6113e)', 'ошибка стенда: поток останавливается в точке сброса'],
        ['<b>D7 дважды</b>. (1) Запрос поднимался, пока массив тегов ещё чистил себя после сброса (`TagSRAMBank.rst_cnt`, около 256 тактов): store не был принят, Acquire не существовало — случай ничего не доказывал (2a456c6). (2) После исправления триггер «по replay» не срабатывал, потому что store-промах под WFI ответа replay не получает (5c67d43)', 'RTL-тест', 'случай привязан к приёму store + 20 тактов; стенд проваливает случай, если Acquire ушёл раньше'],
        ['K8 в KEEP: Probe, удержанный через сброс, при доставке вправе забрать сохранённую строку (ProbeAckData TtoN с данными до сброса); сравнение с директорией на момент сброса давало ложное расхождение', 'RTL-тест (743c728)', 'K8 ждёт тишины L2 и сравнивает с текущей директорией; строка, потерянная без Probe, всё ещё в директории и всё ещё падает'],
        ['<b>`QUIESCE_MUTANT_NO_MQ_WAIT` был немым</b> на SCEN 5, сиды 1–3, и seedsearch (SCEN 2 и 5, сиды 1–30) не нашёл сида: Acquire уходит в L2 раньше блокировки, MissQueue пуста к решению', 'регрессия', '<b>новый направленный случай C16 в SCEN 5</b>: L2 держит A DCache «не готов», Acquire остаётся неотправленным, гейты тихи; корректный дизайн ждёт `mq_empty`, мутант не доживает (S1). Мутант — обычный, не редкий'],
        ['<b>Мутанты «окна»</b> `ACK_IN_ISO` (FULL) и `GATE_MUTANT_NO_HOLDB` (KEEP) на случайном SCEN 2 видны, только если L2 предложит Probe в единственный такт sIso или в sDrain: поймано 1 из 3 и 0 из 3 сидов. Дефект плана', 'регрессия (c5dc0cb)', 'оба идут на направленный SCEN 6 (3 из 3 сидов) как обычные мутанты и на SCEN 2 как редкие со своими сидами'],
        ['<b>`BUSY_GAP`</b> (`busy` падает на такт между последовательностями) был немым во всех сценариях, пока не было S12', 'регрессия + смоук', 'S12; SCEN 8; метрика `b2b.gap` (запуск следующей последовательности не позже 4 тактов после конца)'],
        ['<b>Урок «NO_ALIVE» из v5.</b> Допущение формальной модели «`alive` поднимается не позже 3 тактов» маскировало мутанты `NO_ALIVE`, `NO_FE_WAIT`', 'формальная часть v5 → v6', 'A11 переписано: не позже 6 тактов и не упорядочено с frontend; в v6 оба мутанта ловятся (P22, P20), а в моделировании `NO_ALIVE` честно объявлен эквивалентным'],
        ['<b>A10: допущение `l1_done → l1_req` v5 было сильнее RTL на такт</b>: `DCacheQuiesceUnit` держит sDone ещё такт после падения `req`', 'эквивалентность / формальная часть', 'допущение заменено на `done → (req | req_q)`'],
        ['`NO_REQ_IN_ISO` при `isoCycles` = 1 не виден в симуляции (блокировка снимается через такт после `l1.req`, то есть уже в sReset)', 'регрессия', 'ловится формально (P23); `+FORMALONLY`; при `isoCycles` = 2 ловится стендом'],
        ['План теста: S18 «DCache не принимает store до сброса ядра» сначала проверялся по состоянию контроллера, а не по `l1.req`; `traffic_en` по `hartInReset` выключил бы load с первого такта и сделал проверку зажима чтения пустой', 'смоук', 'S18 по `l1.req` со счётчиком непустоты (607f458); `traffic_en && !core_rst`'],
        ['NewCSR зашивает SHA коммита → идентичность с 7b16188 сначала различалась (7.1)', 'сравнение RTL', 'нормализатор маскирует SHA'],
        ['Тест тайла: T2 требует шаблонов, которых нет в конфигурации; T1 сравнивал источник подсказки предвыборки и `priv` / `trap` трассы без учёта их `valid`', 'тест тайла (1a9c5dd)', 'явные SKIP; сравнение только при `valid`; `ready` B гейта l1d может меняться в FULL при `ackProbe` (`takeB`)'],
    ], [3.2, 0.9, 1.7]))
    s.append(P('Ревью дизайна v6 (Fable high, находка 1, major): `AcquirePerm BtoT` при попадании в BRANCH тоже даёт `MakeUnique`, и FULL теряет не только записи ядра, но и закоммиченную запись другого харта — раздел 9.1. '
               'Остальные находки (опустошение настоящей DCache, идентичность RTL, `isoCycles ≥ 3` в KEEP, место блока freeze) вошли в дизайн и в тесты 7.1, 7.5.'))
    return s
