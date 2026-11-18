"""Block diagrams and sequence diagrams of the document (reportlab.graphics). All text is Russian, DejaVu Sans."""
from reportlab.graphics.shapes import Drawing, Line, Polygon, Rect, String, Group
from reportlab.lib import colors

from pdflib import CONTENT_W

F = 'DejaVu'
FB = 'DejaVu-Bold'
FM = 'DejaVuMono'
INK = colors.HexColor('#1f2328')
GREY = colors.HexColor('#6b7280')
LGREY = colors.HexColor('#d5d8dc')
BLUE = colors.HexColor('#2a5db0')
GREEN = colors.HexColor('#1f7a35')
RED = colors.HexColor('#b3261e')
ORANGE = colors.HexColor('#c77a0a')
PURPLE = colors.HexColor('#6b3fa0')
F_BLUE = colors.HexColor('#e6eefb')
F_GREEN = colors.HexColor('#e4f4e8')
F_RED = colors.HexColor('#fdeaea')
F_ORANGE = colors.HexColor('#fff1d9')
F_GREY = colors.HexColor('#f0f1f3')
F_PURPLE = colors.HexColor('#efe8f8')


class Cv:
    def __init__(self, w, h):
        self.d = Drawing(w, h)
        self.w, self.h = w, h

    def text(self, x, y, s, fs=7, anchor='start', color=INK, bold=False, font=None):
        self.d.add(String(x, y, s, fontName=font or (FB if bold else F), fontSize=fs, fillColor=color,
                          textAnchor=anchor))

    def lines(self, x, y, ss, fs=7, lead=None, anchor='start', color=INK, bold=False):
        lead = lead or fs * 1.25
        for i, s in enumerate(ss):
            self.text(x, y - i * lead, s, fs, anchor, color, bold)

    def box(self, x, y, w, h, txt='', fill=F_GREY, stroke=GREY, fs=7, bold=False, dash=None, color=INK, sw=0.8,
            top=False):
        r = Rect(x, y, w, h, rx=3, ry=3, fillColor=fill, strokeColor=stroke, strokeWidth=sw)
        if dash:
            r.strokeDashArray = dash
        self.d.add(r)
        if txt:
            ss = txt if isinstance(txt, list) else [txt]
            lead = fs * 1.25
            if top:
                y0 = y + h - fs - 2
            else:
                y0 = y + h / 2 + (len(ss) - 1) * lead / 2 - fs * 0.33
            for i, s in enumerate(ss):
                self.text(x + w / 2, y0 - i * lead, s, fs, 'middle', color, bold and i == 0)

    def line(self, x1, y1, x2, y2, color=GREY, w=0.8, dash=None):
        ln = Line(x1, y1, x2, y2, strokeColor=color, strokeWidth=w)
        if dash:
            ln.strokeDashArray = dash
        self.d.add(ln)

    def arrow(self, x1, y1, x2, y2, color=GREY, w=0.9, dash=None, both=False, head=3.6):
        import math
        self.line(x1, y1, x2, y2, color, w, dash)
        for (xa, ya, xb, yb) in ([(x1, y1, x2, y2)] + ([(x2, y2, x1, y1)] if both else [])):
            ang = math.atan2(yb - ya, xb - xa)
            for s in (+1, -1):
                pass
            p1 = (xb - head * math.cos(ang - 0.4), yb - head * math.sin(ang - 0.4))
            p2 = (xb - head * math.cos(ang + 0.4), yb - head * math.sin(ang + 0.4))
            self.d.add(Polygon([xb, yb, p1[0], p1[1], p2[0], p2[1]], fillColor=color, strokeColor=color,
                               strokeWidth=0.3))


# ------------------------------------------------------------------------------------------------ tile structure
def tile_structure():
    W, H = CONTENT_W, 345
    c = Cv(W, H)
    # core reset domain
    c.box(0, 70, 150, 270, fill=colors.white, stroke=RED, dash=[4, 3], sw=1)
    c.text(75, 328, 'XSCore: домен сброса ядра', 7.2, 'middle', RED, True)
    items = [
        (292, 'Frontend: ICache', 'Get на l1i', F_GREY),
        (254, 'Frontend: выборка из MMIO', 'Get на i_mmio', F_GREY),
        (216, 'MemBlock: PTW / L2TLB', 'Get на ptw', F_GREY),
        (178, 'Uncache (MMIO данных)', 'запросы на d_mmio', F_GREY),
        (140, 'Регистры ICache ctrl', 'менеджер в ядре', F_GREY),
    ]
    for y, t1, t2, fl in items:
        c.box(8, y, 134, 31, [t1, t2], fill=fl, fs=6.6)
    c.box(8, 76, 134, 58, ['DCache (L1D): MainPipe, MissQueue,', 'WritebackQueue, ProbeQueue,',
                           'DCacheQuiesceUnit', '(KEEP: meta, error, теги — сброс тайла)'], fill=F_BLUE, stroke=BLUE,
          fs=6.4, bold=True)
    # gates
    gx, gw = 188, 92
    gates = [(292, 'гейт l1i', 'ранний', F_ORANGE), (254, 'гейт i_mmio', 'ранний', F_ORANGE),
             (216, 'гейт ptw', 'ранний', F_ORANGE), (178, 'гейт d_mmio', 'ранний', F_ORANGE),
             (140, 'TLResetIsolation', 'ребро icachectrl', F_PURPLE)]
    for y, t1, t2, fl in gates:
        c.box(gx, y, gw, 31, [t1, t2], fill=fl, stroke=ORANGE if fl == F_ORANGE else PURPLE, fs=6.8, bold=True)
    c.box(gx, 76, gw, 58, ['гейт l1d', 'TL-C: A, B, C, D, E', 'A закрыт с sDrain,', 'B: держит / отвечает (FULL)'],
          fill=F_ORANGE, stroke=ORANGE, fs=6.8, bold=True)
    c.text(gx + gw / 2, 328, 'домен тайла: гейты', 7.2, 'middle', ORANGE, True)
    # L2Top
    c.box(330, 70, 152, 270, fill=colors.white, stroke=GREEN, sw=1)
    c.text(406, 328, 'L2Top: работает всё время', 7.2, 'middle', GREEN, True)
    c.box(338, 224, 136, 92, ['CoupledL2', 'инклюзивный; директория:', 'состояние и бит клиента',
                              'MSHR, SinkC, SourceB (Probe)'], fill=F_GREEN, stroke=GREEN, fs=6.6, bold=True)
    c.box(338, 140, 136, 70, ['MMIO-крестовина и мост', 'MMIOBridge → CHI', 'адреса icachectrl → ядро'],
          fill=F_GREEN, stroke=GREEN, fs=6.6)
    c.box(338, 78, 136, 50, ['CHI-порт к HN', 'кредиты, LINKACTIVE, SYSCO', 'сброса не видят'], fill=F_GREEN,
          stroke=GREEN, fs=6.4)
    # edges core -> gate
    for y in (307, 269, 231, 193):
        c.arrow(142, y, gx, y, BLUE, both=True)
    c.arrow(142, 155, gx, 155, BLUE, both=True)
    c.arrow(142, 105, gx, 105, BLUE, both=True)
    c.text(165, 109, 'ABCDE', 5.6, 'middle', BLUE)
    # gate -> L2
    c.arrow(gx + gw, 307, 330, 296, BLUE, both=True)
    c.arrow(gx + gw, 269, 330, 180, BLUE, both=True)
    c.arrow(gx + gw, 231, 330, 262, BLUE, both=True)
    c.arrow(gx + gw, 193, 330, 170, BLUE, both=True)
    c.arrow(gx + gw, 105, 330, 280, BLUE, both=True)
    c.arrow(330, 155, gx + gw, 155, BLUE)
    # controller
    c.box(104, 2, 270, 62, ['CoreResetCtrl (домен тайла)', 'sIdle → sQuiesce → sDrain → sIso → sReset → sRelease',
                            'выходы: earlyBlock, gateBlock, holdProbe, ackProbe,', 'isolate, coreReset, l1.req, l1.freeze, busy',
                            'входы: req (3 синхронизатора), earlyQuiet, gatesQuiet,', 'l1.done / idle / alive, resetInFrontend'],
          fill=F_RED, stroke=RED, fs=6.0, bold=True)
    c.arrow(234, 64, 234, 76, RED, both=True)
    c.text(240, 67, 'block, holdB, ackB, isolate ↑  quiet ↓', 5.6, 'start', RED)
    c.arrow(104, 33, 62, 33, RED)
    c.arrow(62, 33, 62, 70, RED)
    c.text(4, 58, 'coreReset → ResetGen', 5.6, 'start', RED)
    c.text(4, 14, 'l1.req, freeze ↓', 5.6, 'start', RED)
    c.text(4, 6, 'done, idle, alive ↑', 5.6, 'start', RED)
    c.box(386, 4, 96, 56, ['XSTile: изоляция', 'остальных выходов', 'ядра (isoReset /', 'isoHold)'], fill=F_PURPLE,
          stroke=PURPLE, fs=6.2, bold=True)
    c.arrow(374, 32, 386, 32, PURPLE)
    return c.d


# ------------------------------------------------------------------------------------------------ CoreResetCtrl FSM
def _circle(c, cx, cy, n):
    from reportlab.graphics.shapes import Circle
    c.d.add(Circle(cx, cy, 5.2, fillColor=colors.white, strokeColor=INK, strokeWidth=0.7))
    c.text(cx, cy - 2, str(n), 6.4, 'middle', INK, True)


def fsm_ctrl():
    W, H = CONTENT_W, 250
    c = Cv(W, H)
    bw, gap = 66, 15
    xs = [2 + i * (bw + gap) for i in range(6)]
    names = ['sIdle', 'sQuiesce', 'sDrain', 'sIso', 'sReset', 'sRelease']
    sub = [['ядро работает', 'busy = 0'],
           ['busy = 1; A', 'некогерентных', 'закрыт; DCache:', 'опустошение;', 'B открыт'],
           ['A l1d закрыт;', 'B держится', '(holdProbe);', 'решение по quiet', 'этого такта'],
           ['isolate, freeze', '(KEEP) := 1;', 'сброса ещё нет;', 'l1.req = 1;', 'isoCycles тактов'],
           ['coreReset = 1;', 'FULL: гейт', 'отвечает NtoN;', 'KEEP: Probe', 'держится'],
           ['coreReset = 0;', 'isolate держится;', 'ждёт alive и', 'frontend']]
    fills = [F_GREEN, F_BLUE, F_ORANGE, F_PURPLE, F_RED, F_PURPLE]
    c.text(W / 2, H - 9, 'CoreResetCtrl: 6 состояний, только уровень', 7.6, 'middle', INK, True)
    ytop = H - 124
    for x, n, sb, f in zip(xs, names, sub, fills):
        c.box(x, ytop, bw, 90, [n] + sb, fill=f, stroke=GREY, fs=5.9, bold=True, top=True)
    for i in range(5):
        c.arrow(xs[i] + bw, ytop + 45, xs[i + 1], ytop + 45, INK, 1.0)
        _circle(c, xs[i] + bw + gap / 2, ytop + 56, i + 1)
    yb = ytop - 14
    c.line(xs[5] + bw / 2, ytop, xs[5] + bw / 2, yb, INK, 1.0)
    c.line(xs[5] + bw / 2, yb, xs[0] + bw / 2, yb, INK, 1.0)
    c.arrow(xs[0] + bw / 2, yb, xs[0] + bw / 2, ytop, INK, 1.0)
    _circle(c, (xs[0] + xs[5] + bw) / 2 + 40, yb, 6)
    # sRelease -> sQuiesce
    yc = ytop + 100
    c.line(xs[5] + bw / 2 + 10, ytop + 90, xs[5] + bw / 2 + 10, yc, GREY, 0.9, [3, 2])
    c.line(xs[5] + bw / 2 + 10, yc, xs[1] + bw / 2, yc, GREY, 0.9, [3, 2])
    c.arrow(xs[1] + bw / 2, yc, xs[1] + bw / 2, ytop + 90, GREY, 0.9, [3, 2])
    c.text((xs[1] + xs[5]) / 2 + 30, yc + 2, '7 (запрос снова поднят: busy не падает)', 6.0, 'middle', GREY)
    leg = ['1  req: busy := 1',
           '2  l1Done && earlyQuiet: DCache опустошена, ранние гейты тихи',
           '3  gatesQuiet && l1Done && l1Idle в одном такте: isolate := 1',
           '4  cnt == isoCycles - 1: coreReset := 1 (isolate уже стоял isoCycles полных тактов)',
           '5  cnt >= rstCycles (100) && !req: coreReset := 0, releasing := 1',
           '6  coreUp = releasing && alive && !resetInFrontend, req = 0: isolate, releasing, busy := 0;  7  то же при req = 1']
    y = yb - 14
    for t in leg:
        c.text(4, y, t, 6.2)
        y -= 8.4
    return c.d


def fsm_quiesce():
    W, H = 481, 118
    c = Cv(W, H)
    xs = [10, 175, 340]
    names = ['sIdle', 'sDrain', 'sDone']
    sub = [['block = 0', 'ждёт quiesce.req'], ['block = 1', 'ждёт idle:', 'mq && wbq && mp && pq'], ['block = 1, done = 1', 'пока req = 1']]
    for x, n, s in zip(xs, names, sub):
        c.box(x, 28, 130, 56, [n] + s, fill=[F_GREEN, F_ORANGE, F_PURPLE][xs.index(x)], fs=6.8, bold=True, top=True)
    for i in range(2):
        c.arrow(xs[i] + 130, 56, xs[i + 1], 56, INK, 1.0)
    c.text(xs[0] + 152, 62, 'req', 6.4, 'middle')
    c.text(xs[1] + 152, 62, 'idle', 6.4, 'middle')
    c.line(xs[1] + 65, 28, xs[1] + 65, 14, INK, 0.8)
    c.line(xs[1] + 65, 14, xs[0] + 65, 14, INK, 0.8, [2, 2])
    c.arrow(xs[0] + 65, 14, xs[0] + 65, 28, INK, 0.8)
    c.text(xs[0] + 112, 5, '!req', 6, 'middle', GREY)
    c.line(xs[2] + 65, 28, xs[2] + 65, 14, INK, 0.8)
    c.line(xs[2] + 65, 14, xs[0] + 65, 14, INK, 0.8, [2, 2])
    c.text(W / 2, 104, 'DCacheQuiesceUnit: 3 состояния; одинаков для FULL и KEEP; idle = mq_empty && wbq_empty && mp_empty && pq_empty',
           7.0, 'middle', INK, True)
    return c.d


# ------------------------------------------------------------------------------------------------ phases timeline
def phases_timeline():
    W, H = CONTENT_W, 262
    c = Cv(W, H)
    x0 = 112
    cols = [('sIdle', 36), ('sQuiesce', 70), ('sDrain', 34), ('sIso', 22), ('sReset', 110), ('sRelease', 40)]
    tot = sum(w for _, w in cols)
    sc = (W - x0 - 4) / tot
    xs = []
    x = x0
    for n, w in cols:
        xs.append((x, w * sc, n))
        x += w * sc
    ylab = H - 15
    for (x, w, n), fl in zip(xs, [F_GREEN, F_BLUE, F_ORANGE, F_PURPLE, F_RED, F_PURPLE]):
        c.box(x, ylab, w, 14, n, fill=fl, fs=6.4, bold=True)
    rows = [
        ('A l1i, ptw, i_mmio, d_mmio', [(0, 1, 'открыт', F_GREEN), (1, 6, 'закрыт (earlyBlock = busy)', F_RED)]),
        ('A l1d', [(0, 2, 'открыт', F_GREEN), (2, 6, 'закрыт (gateBlock)', F_RED)]),
        ('B (Probe), FULL', [(0, 2, 'открыт', F_GREEN), (2, 4, 'держится в L2', F_ORANGE),
                             (4, 6, 'гейт: ProbeAck NtoN', F_PURPLE)]),
        ('B (Probe), KEEP', [(0, 2, 'открыт', F_GREEN), (2, 6, 'держится в L2 (holdProbe)', F_ORANGE)]),
        ('DCache', [(0, 1, 'работает', F_GREEN), (1, 2, 'блок; опустошение', F_BLUE),
                    (2, 4, 'блок (l1.req)', F_BLUE), (4, 5, 'в сбросе', F_RED), (5, 6, 'выход', F_ORANGE)]),
        ('ядро', [(0, 1, 'работает', F_GREEN), (1, 4, 'работает, нового наружу нет', F_BLUE), (4, 5, 'в сбросе', F_RED),
                  (5, 6, 'выход', F_ORANGE)]),
        ('isolate; freeze (KEEP)', [(0, 3, '0', F_GREY), (3, 6, '1', F_PURPLE)]),
        ('busy = hartInReset', [(0, 1, '0', F_GREY), (1, 6, '1', F_PURPLE)]),
        ('условие выхода', [(1, 2, 'done && earlyQuiet', F_GREY), (2, 3, 'quiet && done && idle', F_GREY),
                            (3, 4, 'isoCycles тактов', F_GREY), (4, 5, '>= 100 && !req', F_GREY),
                            (5, 6, 'alive, frontend', F_GREY)]),
    ]
    y = ylab - 22
    for label, segs in rows:
        c.text(x0 - 4, y + 5, label, 6.2, 'end')
        for a, b, t, fl in segs:
            xa, wa = xs[a][0], sum(xs[k][1] for k in range(a, b))
            c.box(xa + 0.5, y, wa - 1, 18, t, fill=fl, stroke=LGREY, fs=5.7)
        y -= 24
    c.text(W / 2, 4, 'ширина столбцов условная; sReset длится не меньше rstCycles = 100 тактов и до снятия запроса', 6, 'middle', GREY)
    return c.d


# ------------------------------------------------------------------------------------------------ sequence diagrams
def sequence(title, parts, steps, H=None, colw=None):
    n = len(parts)
    height = 28
    for s in steps:
        height += {'phase': 16, 'msg': 14, 'note': 22, 'note2': 32}[s[0]]
    W = CONTENT_W
    c = Cv(W, height + 20)
    left = 55
    xs = [left + (W - 2 * left) * i / (n - 1) for i in range(n)]
    c.text(W / 2, height + 8, title, 7.4, 'middle', INK, True)
    top = height - 4
    for x, p in zip(xs, parts):
        c.box(x - 46, top - 16, 92, 18, p, fill=F_BLUE, stroke=BLUE, fs=6.2, bold=True)
        c.line(x, top - 16, x, 6, GREY, 0.6, [2, 2])
    y = top - 26
    for s in steps:
        if s[0] == 'phase':
            c.box(4, y - 10, W - 8, 12, s[1], fill=colors.HexColor('#e6e8eb'), stroke=LGREY, fs=6.4, bold=True)
            y -= 16
        elif s[0] == 'msg':
            _, i, j, t, col, dash = s
            col = col or INK
            if i == j:
                wd = 8 + 3.15 * len(t)
                x0 = min(max(xs[i] - wd / 2, 4), W - wd - 4)
                c.box(x0, y - 8, wd, 11, t, fill=colors.white, stroke=col, fs=5.7)
            else:
                c.arrow(xs[i], y - 2, xs[j], y - 2, col, 0.9, dash)
                mx = (xs[i] + xs[j]) / 2
                c.text(mx, y + 1.2, t, 5.9, 'middle', col)
            y -= 14
        elif s[0] == 'note':
            _, i, t, fl = s
            ss = t if isinstance(t, list) else [t]
            wd = 170
            x = min(max(xs[i] - wd / 2, 4), W - wd - 4)
            c.box(x, y - 14, wd, 18, ss, fill=fl, stroke=LGREY, fs=5.8)
            y -= 22
        elif s[0] == 'note2':
            _, i, t, fl = s
            wd = 190
            x = min(max(xs[i] - wd / 2, 4), W - wd - 4)
            c.box(x, y - 24, wd, 28, t, fill=fl, stroke=LGREY, fs=5.8)
            y -= 32
    return c.d


PARTS = ['Debug Module / кластер', 'CoreResetCtrl', 'DCache (L1D)', 'гейты', 'L2 / HN']


def seq_full():
    S = [
        ('phase', '1. запрос и sQuiesce: опустошение DCache (обхода нет)'),
        ('msg', 0, 1, 'запрос = 1; busy = 1', BLUE, None),
        ('msg', 1, 3, 'earlyBlock: A l1i, ptw, i_mmio, d_mmio закрыт', RED, None),
        ('msg', 1, 2, 'l1.req: блок store, AMO, CMO, новых промахов', RED, None),
        ('msg', 4, 2, 'Probe (B открыт); Grant, ReleaseAck для начатого', GREEN, None),
        ('msg', 2, 4, 'ProbeAck(Data), GrantAck, Release(Data) начатое', GREEN, None),
        ('msg', 2, 1, 'l1.done; гейты: earlyQuiet', PURPLE, [2, 2]),
        ('phase', '2. sDrain: A l1d и B закрыты с первого такта; решение по quiet этого такта'),
        ('msg', 1, 3, 'gateBlock = 1, holdProbe = 1', RED, None),
        ('msg', 4, 3, 'Probe предложен: b.ready = 0, b.valid к ядру = 0', GREEN, [3, 2]),
        ('note', 3, 'gatesQuiet && l1Done && l1Idle в одном такте', F_ORANGE),
        ('phase', '3. sIso: изоляция включена, сброса ещё нет (isoCycles = 1 такт)'),
        ('msg', 1, 3, 'isolate := 1: гейты и боковые сигналы зажаты', RED, None),
        ('phase', '4. sReset (не меньше 100 тактов и до снятия запроса)'),
        ('msg', 1, 1, 'coreReset := 1; ackProbe = 1', RED, None),
        ('msg', 3, 4, 'ProbeAck NtoN от гейта на удержанный Probe', GREEN, None),
        ('note', 2, 'L1D пуста: грязные строки потеряны (7.2)', F_BLUE),
        ('phase', '5. sRelease и выход'),
        ('msg', 1, 1, 'coreReset := 0; ждёт alive и frontend', RED, None),
        ('msg', 1, 3, 'isolate := 0: гейты открыты; busy = 0', RED, None),
        ('msg', 2, 4, 'первые обращения ядра — промахи; L2 отдаёт свои данные', GREEN, None),
    ]
    return sequence('Последовательность FULL (CoreResetKeepL1 = false, по умолчанию)', PARTS, S)


def seq_keep():
    S = [
        ('phase', '1. запрос и sQuiesce: опустошение DCache (обхода нет)'),
        ('msg', 0, 1, 'запрос = 1; busy = 1', BLUE, None),
        ('msg', 1, 3, 'earlyBlock: A некогерентных закрыт', RED, None),
        ('msg', 1, 2, 'l1.req: блок store, AMO, CMO, новых промахов', RED, None),
        ('msg', 4, 2, 'Probe (B открыт) → ProbeAck(Data)', GREEN, None),
        ('msg', 2, 1, 'l1.done; гейты: earlyQuiet', PURPLE, [2, 2]),
        ('phase', '2. sDrain'),
        ('msg', 1, 3, 'gateBlock = 1, holdProbe = 1', RED, None),
        ('msg', 4, 3, 'Probe предложен: b.ready = 0, b.valid к ядру = 0', GREEN, [3, 2]),
        ('note', 3, 'gatesQuiet && l1Done && l1Idle в одном такте', F_ORANGE),
        ('phase', '3. sIso: isolate и freeze := 1'),
        ('msg', 1, 2, 'freeze: запись, чтение SRAM = 0', RED, None),
        ('phase', '4. sReset (не меньше 100 тактов и до снятия запроса)'),
        ('msg', 1, 1, 'coreReset := 1; meta, error, теги — на сбросе тайла: целы', RED, None),
        ('msg', 4, 3, 'Probe к строке L1D ждёт (SourceB; снуп HN ждёт)', GREEN, [3, 2]),
        ('note', 2, 'строки L1D сохранены (meta, error, tag, data)', F_BLUE),
        ('phase', '5. sRelease и выход'),
        ('msg', 1, 1, 'coreReset := 0; ждёт alive и frontend', RED, None),
        ('msg', 1, 3, 'isolate := 0: гейты открыты', RED, None),
        ('msg', 3, 2, 'Probe доходит до DCache', GREEN, None),
        ('msg', 2, 4, 'ProbeAckData из «горячей» L1D', GREEN, None),
    ]
    return sequence('Последовательность KEEP (CoreResetKeepL1 = true)', PARTS, S)


# ------------------------------------------------------------------------------------------------ timing of the isolation lead
def iso_lead_timing():
    """cycle diagram of DESIGN 2.3 (isoCycles = 1): T-1, T, T+1, T+2 ... X, X+1 ... U, U+1"""
    W, H = CONTENT_W, 205
    c = Cv(W, H)
    x0, x1 = 130, W - 6
    cols = ['T-1', 'T', 'T+1', 'T+2', '...', 'X', 'X+1', '...', 'U', 'U+1']
    n = len(cols)
    cw = (x1 - x0) / n
    def X(i):
        return x0 + cw * i
    for i, t in enumerate(cols):
        c.text(X(i) + cw / 2, H - 12, t, 6.6, 'middle', INK, True)
        c.line(X(i), 6, X(i), H - 18, LGREY, 0.4)
    c.line(X(n), 6, X(n), H - 18, LGREY, 0.4)
    state = [(0, 2, 'sDrain', F_ORANGE), (2, 3, 'sIso', F_PURPLE), (3, 6, 'sReset', F_RED), (6, 9, 'sRelease', F_PURPLE), (9, 10, 'sIdle', F_GREEN)]
    rows = ['state', 'gatesQuiet && done', 'isolate, freeze (рег.)', 'coreReset (рег.)', 'сброс внутри XSCore',
            'выходы ядра', 'alive && !resetInFrontend']
    ys = {}
    y = H - 40
    for r in rows:
        ys[r] = y
        c.text(x0 - 5, y + 3, r, 6.3, 'end')
        y -= 24
    for a, b, t, fl in state:
        c.box(X(a) + 0.5, ys['state'] - 3, (b - a) * cw - 1, 14, t, fill=fl, stroke=LGREY, fs=6)
    def lvl(r, a, b, color, lab=''):
        c.box(X(a) + 0.5, ys[r] - 1, (b - a) * cw - 1, 9, lab, fill=color, stroke=GREY, sw=0.4, fs=5.6)
    lvl('gatesQuiet && done', 1, 2, F_GREEN, '1')
    lvl('isolate, freeze (рег.)', 2, 9, F_PURPLE, '1: весь такт T+1 зажимы стоят')
    lvl('coreReset (рег.)', 3, 6, F_RED, '1')
    lvl('сброс внутри XSCore', 3, 8, F_ORANGE, 'асинхронно ↑ ... синхронно ↓ по цепочке ResetGen')
    lvl('выходы ядра', 3, 7, colors.HexColor('#fde3c8'), 'произвольны; зажаты')
    lvl('alive && !resetInFrontend', 8, 9, F_GREEN, '1')
    c.text(X(1) + cw / 2, ys['gatesQuiet && done'] - 12, 'такт решения', 5.6, 'middle', GREY)
    c.text(X(2) + cw / 2, ys['isolate, freeze (рег.)'] - 12, 'запас isoCycles', 5.6, 'middle', GREY)
    c.text(X(8) + cw / 2, ys['alive && !resetInFrontend'] - 12, 'isolate := 0 на фронте U → U+1', 5.6, 'middle', GREY)
    c.text(W / 2, 1, 'isoCycles = 1; запись, зарегистрированная на такт позже s3, фиксируется на фронте T → T+1, до сброса остаётся такт T+1', 5.8, 'middle', GREY)
    return c.d


def iso_timing():
    W, H = CONTENT_W, 190
    c = Cv(W, H)
    x0, x1 = 128, W - 8
    def X(t):
        return x0 + (x1 - x0) * t / 100.0
    rows = ['req (запрос)', 'состояние CoreResetCtrl', 'isolate (регистр)', 'coreReset (регистр)',
            'сброс внутри XSCore (ResetGen)', 'выходы ядра (valid, msiAck ...)', 'после изоляции: к L2 / IMSIC',
            'freeze → SRAM L1D (KEEP)']
    y = H - 24
    ys = {}
    for r in rows:
        ys[r] = y
        c.text(x0 - 6, y + 3, r, 6.3, 'end')
        c.line(x0, y - 4, x1, y - 4, LGREY, 0.4)
        y -= 20
    def lvl(r, segs, color=BLUE, h=9):
        yy = ys[r]
        for a, b, v in segs:
            c.box(X(a), yy - 1, X(b) - X(a), h if v else 1.2, fill=color if v else LGREY,
                  stroke=color if v else LGREY, sw=0.4)
    lvl('req (запрос)', [(0, 4, 0), (4, 80, 1), (80, 100, 0)], BLUE)
    yy = ys['состояние CoreResetCtrl']
    for a, b, t, fl in [(0, 14, 'sDrain', F_ORANGE), (14, 18, 'sIso', F_PURPLE), (18, 80, 'sReset: >= 100 тактов и до снятия запроса', F_RED),
                        (80, 96, 'sRelease', F_PURPLE), (96, 100, 'sIdle', F_GREEN)]:
        c.box(X(a), yy - 3, X(b) - X(a) - 0.5, 13, t, fill=fl, stroke=LGREY, fs=5.7)
    lvl('isolate (регистр)', [(0, 14, 0), (14, 96, 1), (96, 100, 0)], PURPLE)
    lvl('coreReset (регистр)', [(0, 18, 0), (18, 80, 1), (80, 100, 0)], RED)
    lvl('сброс внутри XSCore (ResetGen)', [(0, 19, 0), (19, 82, 1), (82, 100, 0)], ORANGE)
    yy = ys['выходы ядра (valid, msiAck ...)']
    c.box(X(19), yy - 1, X(25) - X(19), 9, 'мусор', fill=colors.HexColor('#fde3c8'), stroke=ORANGE, fs=5.6)
    c.box(X(82), yy - 1, X(88) - X(82), 9, 'выход', fill=colors.HexColor('#e8e8e8'), stroke=GREY, fs=5.2)
    c.text(X(57), ys['после изоляции: к L2 / IMSIC'] + 1, 'значение сброса, не зависит от ядра (valid 0, msiAck 0, ...)', 5.8, 'middle', PURPLE)
    lvl('freeze → SRAM L1D (KEEP)', [(0, 14, 0), (14, 96, 1)], PURPLE)
    for t, lab in [(14, 'sDrain → sIso'), (18, 'coreReset ↑'), (80, 'запрос снят, cnt >= 100'), (96, 'alive && !resetInFrontend')]:
        c.line(X(t), 14, X(t), H - 22, GREY, 0.5, [2, 2])
        c.text(X(t), 6, lab, 5.6, 'middle', GREY)
    c.line(X(18), H - 12, X(18), H - 16, INK, 0.8)
    c.line(X(18), H - 14, X(60), H - 14, INK, 0.8)
    c.text(X(39), H - 10, '>= rstCycles = 100 тактов', 6.2, 'middle', INK, True)
    c.arrow(X(60), H - 14, X(80), H - 14, INK, 0.8)
    c.text(X(70), H - 10, 'до снятия запроса', 6.2, 'middle', INK)
    return c.d
