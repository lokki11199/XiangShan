"""Timing diagrams (section 7.4) drawn from the small VCD files made by make_waves.sh (vcd.py reads them)."""
import os

from reportlab.graphics.shapes import Drawing, Line, Rect, String
from reportlab.lib import colors

import vcd
from pdflib import CONTENT_W, P, cap, box, ROOT

WDIR = os.path.join(ROOT, 'core-reset', 'verification', 'build', 'waves')
F, FB = 'DejaVu', 'DejaVu-Bold'
INK = colors.HexColor('#1f2328')
GREY = colors.HexColor('#6b7280')
LG = colors.HexColor('#dcdfe3')
STATE_FILL = ['#e4f4e8', '#e6eefb', '#fff1d9', '#fdeaea', '#efe8f8']
FST_FILL = ['#f0f1f3', '#fff1d9', '#e6eefb', '#dbe6f7', '#efe8f8']
FST_NAMES = ['sIdle', 'sDrain', 'sSweep', 'sWait', 'sDone']
C_OPS = {4: 'ProbeAck', 5: 'ProbeAckData', 6: 'Release', 7: 'ReleaseData'}
C_COL = {4: '#1f7a35', 5: '#1f7a35', 6: '#2a5db0', 7: '#2a5db0'}


def load(name):
    p = os.path.join(WDIR, name)
    if not os.path.exists(p):
        return None
    try:
        return vcd.Wave(p)
    except Exception:
        return None


class Rows:
    """Draws rows of signals over the cycles c0..c1 (sample indices) of a Wave."""

    def __init__(self, w, c0, c1, title, width=CONTENT_W, label_w=158, rh=12.5, tick=None, abs_labels=True):
        self.w, self.c0, self.c1 = w, c0, c1
        self.n = c1 - c0
        self.W = width
        self.lw = label_w
        self.rh = rh
        self.items = []
        self.title = title
        self.tick = tick
        self.marks = []
        self.notes = []

    def cx(self, i):          # left edge of cycle i
        return self.lw + (self.W - self.lw - 4) * (i - self.c0) / float(self.n)

    def cw(self):
        return (self.W - self.lw - 4) / float(self.n)

    def bit(self, label, f, color='#2a5db0'):
        self.items.append(('bit', label, f, color))

    def state(self, label, f, names, fills):
        self.items.append(('state', label, f, (names, fills)))

    def bus(self, label, f, fmt=str, color='#2a5db0'):
        self.items.append(('bus', label, f, (fmt, color)))

    def ev(self, label, f):
        """f(i) -> None or (text, colour): an event mark in cycle i (text only if it fits)"""
        self.items.append(('ev', label, f, None))

    def lvl2(self, label, f_off, f_taken, color='#b3261e'):
        """a level shown as: hatched when offered and not taken, solid when taken"""
        self.items.append(('hold', label, (f_off, f_taken), color))

    def mark(self, i, text, color='#6b7280'):
        self.marks.append((i, text, color))

    def build(self, top_notes=None):
        n_rows = len(self.items)
        head = 30
        foot = 28 + (10 * len(self.notes))
        H = head + n_rows * (self.rh + 3) + foot
        d = Drawing(self.W, H)
        # ruler
        y_top = H - head
        step = self.tick or (1 if self.n <= 40 else 5 if self.n <= 120 else 10 if self.n <= 200 else 20)
        absn = self.w['cyc_tb']
        for i in range(self.c0, self.c1 + 1):
            x = self.cx(i)
            if (i - self.c0) % step == 0:
                d.add(Line(x, y_top + 2, x, y_top + 6, strokeColor=GREY, strokeWidth=0.4))
                lab = absn[i] if i < len(absn) and absn[i] is not None else i
                d.add(String(x, y_top + 9, str(lab), fontName=F, fontSize=5.4, fillColor=GREY, textAnchor='middle'))
        d.add(String(2, H - 8, self.title, fontName=FB, fontSize=7, fillColor=INK))
        d.add(String(2, y_top + 9, 'такт тестбенча', fontName=F, fontSize=5.4, fillColor=GREY))
        y = y_top - 2
        for kind, label, f, extra in self.items:
            y -= self.rh + 3
            d.add(String(self.lw - 5, y + 3, label, fontName=F, fontSize=6.1, fillColor=INK, textAnchor='end'))
            d.add(Line(self.lw, y - 1.5, self.W - 4, y - 1.5, strokeColor=LG, strokeWidth=0.3))
            cw = self.cw()
            if kind == 'bit':
                col = colors.HexColor(extra)
                for i in range(self.c0, self.c1):
                    v = f(i)
                    x = self.cx(i)
                    if v:
                        d.add(Rect(x, y, cw, self.rh - 3, fillColor=col, strokeColor=col, strokeWidth=0.2))
                    else:
                        d.add(Rect(x, y, cw, 0.9, fillColor=LG, strokeColor=LG, strokeWidth=0.1))
            elif kind == 'state':
                names, fills = extra
                i = self.c0
                while i < self.c1:
                    v = f(i)
                    j = i
                    while j < self.c1 and f(j) == v:
                        j += 1
                    x = self.cx(i)
                    wd = self.cx(j) - x
                    fl = colors.HexColor(fills[v]) if v is not None and v < len(fills) else colors.white
                    d.add(Rect(x, y - 0.5, wd, self.rh - 1.5, fillColor=fl, strokeColor=GREY, strokeWidth=0.4))
                    t = names[v] if v is not None and v < len(names) else '?'
                    if wd > len(t) * 3.3 + 2:
                        d.add(String(x + wd / 2, y + 2.3, t, fontName=FB, fontSize=5.8, fillColor=INK,
                                     textAnchor='middle'))
                    i = j
            elif kind == 'bus':
                fmt, color = extra
                i = self.c0
                while i < self.c1:
                    v = f(i)
                    j = i
                    while j < self.c1 and f(j) == v:
                        j += 1
                    x = self.cx(i)
                    wd = self.cx(j) - x
                    d.add(Rect(x, y - 0.5, wd, self.rh - 1.5, fillColor=colors.HexColor('#f0f1f3'),
                               strokeColor=colors.HexColor(color), strokeWidth=0.4))
                    t = fmt(v) if v is not None else 'x'
                    if wd > len(t) * 3.2 + 1.5:
                        d.add(String(x + wd / 2, y + 2.3, t, fontName=F, fontSize=5.8, fillColor=INK,
                                     textAnchor='middle'))
                    i = j
            elif kind == 'ev':
                for i in range(self.c0, self.c1):
                    r = f(i)
                    if r:
                        t, col = r
                        x = self.cx(i)
                        d.add(Rect(x, y - 0.5, max(cw, 1.2), self.rh - 1.5, fillColor=colors.HexColor(col),
                                   strokeColor=colors.HexColor(col), strokeWidth=0.2))
                        pr = f(i - 1) if i > self.c0 else None
                        if t and not (pr and pr[0] == t):
                            d.add(String(x + cw + 1.2, y + 2.6, t, fontName=F, fontSize=5.2, fillColor=INK))
            elif kind == 'hold':
                f_off, f_taken = f
                col = colors.HexColor(extra)
                for i in range(self.c0, self.c1):
                    x = self.cx(i)
                    if f_taken(i):
                        d.add(Rect(x, y, cw, self.rh - 3, fillColor=colors.HexColor('#1f7a35'),
                                   strokeColor=colors.HexColor('#1f7a35'), strokeWidth=0.2))
                    elif f_off(i):
                        d.add(Rect(x, y, cw, self.rh - 3, fillColor=colors.HexColor('#f7c9c4'), strokeColor=col,
                                   strokeWidth=0.2))
                    else:
                        d.add(Rect(x, y, cw, 0.9, fillColor=LG, strokeColor=LG, strokeWidth=0.1))
        # marks: vertical dashed guides with a label at the bottom
        lastx, lev = -100, 0
        for i, text, col in sorted(self.marks):
            x = self.cx(i)
            lev = (lev + 1) % 3 if x - lastx < 55 else 0
            lastx = x
            ln = Line(x, 24, x, y_top, strokeColor=colors.HexColor(col), strokeWidth=0.5)
            ln.strokeDashArray = [2, 2]
            d.add(ln)
            d.add(String(x + 1.5, 5 + 7 * lev, text, fontName=F, fontSize=5.6, fillColor=colors.HexColor(col)))
        yy = 4
        for t in reversed(self.notes):
            d.add(String(2, yy, t, fontName=F, fontSize=5.6, fillColor=GREY))
            yy += 8
        return d


def _c_event(w):
    def f(i):
        if w['lc_v'][i] == 1 and w['lc_r'][i] == 1:
            op = w['lc_op'][i]
            return (None, C_COL.get(op, '#6b7280'))
        return None
    return f


def _first(seq, a, b, start=0):
    for i in range(max(1, start), len(seq)):
        if seq[i - 1] == a and seq[i] == b:
            return i
    return None


def _w(w, name, i):
    v = w[name][i]
    return 1 if v else 0


def _common_ctl_rows(r, w):
    st = w['ctl_st']
    r.state('состояние CoreResetCtrl', lambda i: st[i], vcd.STATE_NAMES, STATE_FILL)
    r.bit('gateBlock (A l1d)', lambda i: w['gate_block'][i], '#b3261e')
    r.bit('holdProbe (B держит)', lambda i: w['hold_probe'][i], '#c77a0a')
    r.bit('ackProbe (гейт отвечает)', lambda i: w['ack_probe'][i], '#6b3fa0')
    r.bit('isolate', lambda i: w['isolate'][i], '#6b3fa0')


# ------------------------------------------------------------------------------------------------ diagram 1
def wave1():
    w = load('w1_sweep_scen1.vcd')
    if w is None:
        return None
    ok, msg, c0, c1, ev = vcd.find_sweep1(w)
    if not ok:
        return None
    c0 = max(1, ev - 8)
    c1 = min(w.n - 1, c1 - 8)
    r = Rows(w, c0, c1, 'SWEEP, SCEN 1, seed 1: вся последовательность', tick=10)
    st = w['ctl_st']
    r.bit('req (запрос)', lambda i: w['req'][i], '#2a5db0')
    r.state('состояние CoreResetCtrl', lambda i: st[i], vcd.STATE_NAMES, STATE_FILL)
    r.bit('earlyBlock (A некогерентных)', lambda i: w['early_block'][i], '#b3261e')
    r.bit('quiet некогерентных (l1i, i_mmio)', lambda i: 1 if (w['quiet1'][i] and w['quiet2'][i]) else 0, '#1f7a35')
    r.state('DCacheFlushUnit', lambda i: w['u_dc.fst'][i], FST_NAMES, FST_FILL)
    r.bit('l1.done', lambda i: w['flush_done'][i], '#1f7a35')
    r.bit('l1.idle', lambda i: w['flush_idle'][i], '#1f7a35')
    r.bus('строк в L1D', lambda i: w['n_l1_lines'][i])
    r.bus('строк в директории L2', lambda i: w['n_dir_lines'][i])

    def cev(i):
        if w['lc_v'][i] == 1 and w['lc_r'][i] == 1:
            return (None, C_COL.get(w['lc_op'][i], '#6b7280'))
    r.ev('C → L2: Release(Data) синий, ProbeAck зелёный', cev)

    def dev(i):
        if w['ld_v'][i] == 1 and w['ld_r'][i] == 1:
            return (None, '#6b3fa0')
    r.ev('D ← L2 (ответы, Grant)', dev)
    r.lvl2('B: Probe предложен / принят', lambda i: w['lb_v'][i] == 1 and w['lb_r'][i] == 0,
           lambda i: w['lb_v'][i] == 1 and w['lb_r'][i] == 1)
    r.bit('gateBlock', lambda i: w['gate_block'][i], '#b3261e')
    r.bit('holdProbe', lambda i: w['hold_probe'][i], '#c77a0a')
    r.bit('ackProbe', lambda i: w['ack_probe'][i], '#6b3fa0')
    r.bit('isolate', lambda i: w['isolate'][i], '#6b3fa0')
    r.bit('coreReset (сброс ядра)', lambda i: w['core_rst'][i], '#b3261e')
    r.bit('сброс frontend', lambda i: w['fe_rst'][i], '#c77a0a')
    r.bit('l1.alive', lambda i: w['dc_alive'][i], '#1f7a35')
    for i in range(c0 + 1, c1):
        if st[i] != st[i - 1] and st[i] is not None and st[i] < 5:
            r.mark(i, vcd.STATE_NAMES[st[i]])
    return r.build(), msg


def _summary_w1(w):
    st = w['ctl_st']
    c0 = _first(st, 0, 1)
    d = _first(st, 1, 2)
    rs = _first(st, 2, 3)
    rl = _first(st, 3, 4)
    idl = _first(st, 4, 0)
    return dict(flush=d - c0, drain=rs - d, reset=rl - rs, release=idl - rl, total=idl - c0)


# ------------------------------------------------------------------------------------------------ diagram 2
def wave2():
    w = load('w2_keep_case5.vcd')
    if w is None:
        return None
    ok, msg, a, b, d = vcd.find_case5(w)
    if not ok:
        return None
    st = w['ctl_st']
    rs = _first(st, 2, 3, d)
    c0, c1 = d - 10, rs + 6
    r = Rows(w, c0, c1, 'KEEP, SCEN 6, seed 1, случай 5: Probe принят гейтом в последнем такте sFlush', tick=2)
    r.state('состояние CoreResetCtrl', lambda i: st[i], vcd.STATE_NAMES, STATE_FILL)
    r.state('DCacheFlushUnit', lambda i: w['u_dc.fst'][i], FST_NAMES, FST_FILL)
    r.bit('earlyBlock', lambda i: w['early_block'][i], '#b3261e')
    r.bit('gateBlock (A l1d)', lambda i: w['gate_block'][i], '#b3261e')
    r.bit('holdProbe', lambda i: w['hold_probe'][i], '#c77a0a')
    r.lvl2('B от L2: предложен / принят гейтом', lambda i: w['lb_v'][i] == 1 and w['lb_r'][i] == 0,
           lambda i: w['lb_v'][i] == 1 and w['lb_r'][i] == 1)
    r.bit('B гейт → буфер → DCache (gb_v)', lambda i: w['gb_v'][i], '#2a5db0')
    r.bit('C из DCache (dc → буфер → гейт, cc_v)', lambda i: w['cc_v'][i], '#2a5db0')

    def cev(i):
        if w['lc_v'][i] == 1 and w['lc_r'][i] == 1:
            return (C_OPS.get(w['lc_op'][i], ''), C_COL.get(w['lc_op'][i], '#6b7280'))
    r.ev('C к L2 (гейт принял и отдал)', cev)
    r.bit('quiet гейта l1d (quiet0)', lambda i: w['quiet0'][i], '#1f7a35')
    r.bit('l1.done', lambda i: w['flush_done'][i], '#1f7a35')
    r.bit('l1.idle', lambda i: w['flush_idle'][i], '#1f7a35')
    r.bit('coreReset', lambda i: w['core_rst'][i], '#b3261e')
    r.bit('isolate', lambda i: w['isolate'][i], '#6b3fa0')
    r.mark(d - 1, 'Probe принят', '#1f7a35')
    r.mark(d, 'sDrain', '#6b7280')
    r.mark(rs, 'sReset', '#b3261e')
    return r.build(), msg, dict(drain=rs - d)


# ------------------------------------------------------------------------------------------------ diagram 3
def wave3():
    w = load('w3_keep_case4.vcd')
    if w is None:
        return None
    ok, msg, a, b, d = vcd.find_case4(w)
    if not ok:
        return None
    st = w['ctl_st']
    ack = None
    e = _first(st, 4, 0, d)
    for i in range(e, w.n):
        if w['lc_v'][i] == 1 and w['lc_r'][i] == 1 and w['lc_op'][i] in (4, 5):
            ack = i
            break
    c0, c1 = d - 6, ack + 10
    r = Rows(w, c0, c1, 'KEEP, SCEN 6, seed 1, случай 4: Probe toN грязной строки в первом такте sDrain', tick=10)
    r.state('состояние CoreResetCtrl', lambda i: st[i], vcd.STATE_NAMES, STATE_FILL)
    r.bit('earlyBlock', lambda i: w['early_block'][i], '#b3261e')
    r.bit('gateBlock', lambda i: w['gate_block'][i], '#b3261e')
    r.bit('holdProbe', lambda i: w['hold_probe'][i], '#c77a0a')
    r.bit('isolate, freeze', lambda i: w['isolate'][i], '#6b3fa0')
    r.bit('coreReset', lambda i: w['core_rst'][i], '#b3261e')
    r.bit('сброс frontend', lambda i: w['fe_rst'][i], '#c77a0a')
    r.bit('l1.alive', lambda i: w['dc_alive'][i], '#1f7a35')
    r.lvl2('B: Probe предложен L2, не принят (уровень) / принят', lambda i: w['lb_v'][i] == 1 and w['lb_r'][i] == 0,
           lambda i: w['lb_v'][i] == 1 and w['lb_r'][i] == 1)
    # the output of the B buffer inside the core reset domain is garbage in reset: masked
    r.bit('B на входе DCache (db_v; в сбросе скрыто)', lambda i: (w['db_v'][i] if not w['core_rst'][i] else 0), '#2a5db0')

    def cev(i):
        if w['lc_v'][i] == 1 and w['lc_r'][i] == 1:
            return (C_OPS.get(w['lc_op'][i], ''), C_COL.get(w['lc_op'][i], '#6b7280'))
    r.ev('C к L2 (ответ на Probe)', cev)
    r.mark(d, 'sDrain', '#6b7280')
    rs = _first(st, 2, 3, d)
    r.mark(rs, 'sReset', '#b3261e')
    r.mark(_first(st, 3, 4, d), 'sRelease', '#6b3fa0')
    r.mark(e, 'sIdle', '#1f7a35')
    r.mark(ack, 'ProbeAck%s' % ('Data' if w['lc_op'][ack] == 5 else ''), '#1f7a35')
    return r.build(), msg, dict(held=ack - d, reset=_first(st, 3, 4, d) - rs)


# ------------------------------------------------------------------------------------------------ diagram 4
def wave4():
    w = load('w3_keep_case4.vcd')
    if w is None:
        return None
    ok, msg, a, b, d = vcd.find_case4(w)
    if not ok:
        return None
    st = w['ctl_st']
    rs = _first(st, 2, 3, d)
    c0, c1 = d - 4, rs + 10
    r = Rows(w, c0, c1, 'KEEP, момент установки сброса (тот же сброс, случай 4)', tick=1, label_w=150)
    r.state('состояние CoreResetCtrl', lambda i: st[i], vcd.STATE_NAMES, STATE_FILL)
    r.bit('holdProbe (функция регистра состояния)', lambda i: w['hold_probe'][i], '#c77a0a')
    r.bit('B от L2: valid (L2 предлагает Probe)', lambda i: w['lb_v'][i], '#b3261e')
    r.bit('B ready гейта к L2', lambda i: w['lb_r'][i], '#1f7a35')
    r.bit('quiet всех гейтов и l1.done && idle', lambda i: 1 if (w['quiet0'][i] and w['quiet1'][i] and w['quiet2'][i]
                                                                  and w['iso_quiet'][i] and w['flush_done'][i]
                                                                  and w['flush_idle'][i]) else 0, '#1f7a35')
    r.bit('coreReset (регистр)', lambda i: w['ctl_core_reset'][i], '#b3261e')
    r.bit('isolate (регистр)', lambda i: w['isolate'][i], '#6b3fa0')
    r.bit('сброс внутри ядра (после синхронизатора)', lambda i: w['core_rst'][i], '#c77a0a')
    r.bit('выход ядра: A valid из DCache (мусор в сбросе)', lambda i: w['ca_v'][i], '#c77a0a')
    r.bit('выход ядра: C valid из буфера (мусор)', lambda i: w['cc_v'][i], '#c77a0a')
    r.bit('на стороне тайла: A valid к L2 (la_v)', lambda i: w['la_v'][i], '#2a5db0')
    r.bit('на стороне тайла: C valid к L2 (lc_v)', lambda i: w['lc_v'][i], '#2a5db0')
    r.mark(d, 'sDrain', '#6b7280')
    r.mark(rs, 'sReset: coreReset и isolate на одном фронте', '#b3261e')
    return r.build(), msg, dict(rs=rs - d)


def available():
    return {k: os.path.exists(os.path.join(WDIR, k)) for k in ('w1_sweep_scen1.vcd', 'w2_keep_case5.vcd',
                                                               'w3_keep_case4.vcd')}
