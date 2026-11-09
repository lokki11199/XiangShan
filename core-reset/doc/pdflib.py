"""Building blocks of the document (reportlab platypus): fonts, styles, inline markup, tables, boxes, code and patch
fragments. See make_pdf.py for the content."""
import os
import re
import subprocess

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import cm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, Flowable, Frame, KeepTogether, PageBreak, PageTemplate, Paragraph,
                                Spacer, Table, TableStyle)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
FONTDIR = '/usr/share/fonts/truetype/dejavu/'
pdfmetrics.registerFont(TTFont('DejaVu', FONTDIR + 'DejaVuSans.ttf'))
pdfmetrics.registerFont(TTFont('DejaVu-Bold', FONTDIR + 'DejaVuSans-Bold.ttf'))
pdfmetrics.registerFont(TTFont('DejaVuMono', FONTDIR + 'DejaVuSansMono.ttf'))
pdfmetrics.registerFont(TTFont('DejaVuMono-Bold', FONTDIR + 'DejaVuSansMono-Bold.ttf'))
# there is no oblique DejaVu Sans on this machine: italic falls back to the regular face
pdfmetrics.registerFontFamily('DejaVu', normal='DejaVu', bold='DejaVu-Bold', italic='DejaVu', boldItalic='DejaVu-Bold')
pdfmetrics.registerFontFamily('DejaVuMono', normal='DejaVuMono', bold='DejaVuMono-Bold', italic='DejaVuMono',
                              boldItalic='DejaVuMono-Bold')

# ------------------------------------------------------------------ colours
INK = colors.HexColor('#1f2328')
GREY = colors.HexColor('#656d76')
HEAD_BG = colors.HexColor('#e9ebee')
LINE = colors.HexColor('#b8bcc2')
CODE_RED = '#8b1a1a'
TL181 = '#1a4fb5'
TL193 = '#1b7a2f'
BOX_BG = colors.HexColor('#eef4fb')
BOX_LINE = colors.HexColor('#8fb0d8')
WARN_BG = colors.HexColor('#fff4e0')
WARN_LINE = colors.HexColor('#e0a040')
BAD_BG = colors.HexColor('#fdeaea')
BAD_LINE = colors.HexColor('#d06060')
ADD_BG = colors.HexColor('#e6f6e9')
DEL_BG = colors.HexColor('#fde8e8')
CTX_BG = colors.HexColor('#f1f2f4')

PAGE_W, PAGE_H = A4
MARGIN = 2 * cm
CONTENT_W = PAGE_W - 2 * MARGIN

# ------------------------------------------------------------------ styles
S = {}
S['body'] = ParagraphStyle('body', fontName='DejaVu', fontSize=9, leading=12.6, textColor=INK, alignment=TA_LEFT,
                           spaceAfter=4)
S['small'] = ParagraphStyle('small', parent=S['body'], fontSize=7.8, leading=10.2, spaceAfter=2)
S['cell'] = ParagraphStyle('cell', parent=S['body'], fontSize=7.8, leading=10.0, spaceAfter=0)
S['cellb'] = ParagraphStyle('cellb', parent=S['cell'], fontName='DejaVu-Bold')
S['title'] = ParagraphStyle('title', fontName='DejaVu-Bold', fontSize=21, leading=26, textColor=INK, spaceAfter=8)
S['subtitle'] = ParagraphStyle('subtitle', fontName='DejaVu', fontSize=10.5, leading=14.5, textColor=GREY,
                               spaceAfter=10)
S['h1'] = ParagraphStyle('h1', fontName='DejaVu-Bold', fontSize=15, leading=19, textColor=INK, spaceBefore=12,
                         spaceAfter=6, keepWithNext=1)
S['h2'] = ParagraphStyle('h2', fontName='DejaVu-Bold', fontSize=11.5, leading=15, textColor=INK, spaceBefore=9,
                         spaceAfter=4, keepWithNext=1)
S['h3'] = ParagraphStyle('h3', fontName='DejaVu-Bold', fontSize=9.6, leading=13, textColor=INK, spaceBefore=6,
                         spaceAfter=3, keepWithNext=1)
S['bullet'] = ParagraphStyle('bullet', parent=S['body'], leftIndent=13, bulletIndent=3, spaceAfter=2.5)
S['bullet2'] = ParagraphStyle('bullet2', parent=S['body'], leftIndent=26, bulletIndent=16, spaceAfter=2)
S['caption'] = ParagraphStyle('caption', parent=S['small'], textColor=GREY, spaceBefore=2, spaceAfter=8)
S['boxtitle'] = ParagraphStyle('boxtitle', parent=S['body'], fontName='DejaVu-Bold', fontSize=9, spaceAfter=1)
S['boxbody'] = ParagraphStyle('boxbody', parent=S['body'], fontSize=8.6, leading=11.8, spaceAfter=2)


# ------------------------------------------------------------------ inline markup
def _amp(s):
    return re.sub(r'&(?!(?:[A-Za-z]+|#\d+);)', '&amp;', s)


def mk(text):
    """Inline markup: `code` -> dark-red monospace; [TL 1.8.1 ...] blue, [TL 1.9.3 ...] green; <b>, <i>, <br/> pass
    through. A bare < or & must be written as &lt; / &amp;."""
    parts = text.split('`')
    out = []
    for i, p in enumerate(parts):
        if i % 2 == 1:
            esc = p.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            out.append('<font face="DejaVuMono" color="%s" size="-0.6">%s</font>' % (CODE_RED, esc))
        else:
            p = _amp(p)

            def tl(m):
                col = TL181 if m.group(1) == '1.8.1' else TL193
                return '<font color="%s">%s</font>' % (col, m.group(0))
            p = re.sub(r'\[TL (1\.8\.1|1\.9\.3)[^\]]*\]', tl, p)
            out.append(p)
    return ''.join(out)


def P(text, style='body'):
    return Paragraph(mk(text), S[style] if isinstance(style, str) else style)


def bullets(items, style='bullet'):
    return [Paragraph(mk(t), S[style], bulletText='•') for t in items]


def numbered(items):
    return [Paragraph(mk(t), S['bullet'], bulletText='%d.' % (i + 1)) for i, t in enumerate(items)]


# ------------------------------------------------------------------ tables
def table(rows, widths, header=True, size=None, align_center_cols=(), zebra=False, extra=None, repeat=1):
    """rows: list of lists of str (markup) or flowables; widths: fractions or absolute points."""
    tot = float(sum(widths))
    cw = [CONTENT_W * w / tot if tot <= 20 else w for w in widths]
    data = []
    for ri, r in enumerate(rows):
        row = []
        for c in r:
            if isinstance(c, str):
                row.append(Paragraph(mk(c), S['cellb'] if (header and ri == 0) else S['cell']))
            else:
                row.append(c)
        data.append(row)
    t = Table(data, colWidths=cw, repeatRows=repeat if header else 0)
    st = [('VALIGN', (0, 0), (-1, -1), 'TOP'),
          ('GRID', (0, 0), (-1, -1), 0.4, LINE),
          ('LEFTPADDING', (0, 0), (-1, -1), 3.5), ('RIGHTPADDING', (0, 0), (-1, -1), 3.5),
          ('TOPPADDING', (0, 0), (-1, -1), 2.5), ('BOTTOMPADDING', (0, 0), (-1, -1), 2.8)]
    if header:
        st.append(('BACKGROUND', (0, 0), (-1, 0), HEAD_BG))
    if zebra:
        for i in range(1, len(rows)):
            if i % 2 == 0:
                st.append(('BACKGROUND', (0, i), (-1, i), colors.HexColor('#f8f9fa')))
    if extra:
        st += extra
    t.setStyle(TableStyle(st))
    return t


def box(title, paras, kind='why'):
    """A call-out: kind 'why' (light blue, "Почему так"), 'warn' (orange), 'bad' (red)."""
    bg, ln = {'why': (BOX_BG, BOX_LINE), 'warn': (WARN_BG, WARN_LINE), 'bad': (BAD_BG, BAD_LINE)}[kind]
    rows = [[Paragraph(mk(title), S['boxtitle'])]]
    for p in paras:
        if isinstance(p, str):
            rows.append([Paragraph(mk(p), S['boxbody'])])
        else:
            rows.append([p])
    t = Table(rows, colWidths=[CONTENT_W])
    t.setStyle(TableStyle([('BACKGROUND', (0, 0), (-1, -1), bg), ('BOX', (0, 0), (-1, -1), 0.8, ln),
                           ('LEFTPADDING', (0, 0), (-1, -1), 7), ('RIGHTPADDING', (0, 0), (-1, -1), 7),
                           ('TOPPADDING', (0, 0), (-1, -1), 1.5), ('BOTTOMPADDING', (0, 0), (-1, -1), 1.5),
                           ('TOPPADDING', (0, 0), (-1, 0), 4), ('BOTTOMPADDING', (0, -1), (-1, -1), 4)]))
    t.hAlign = 'LEFT'
    return [t, Spacer(1, 6)]


# ------------------------------------------------------------------ code and patch fragments
class CodeBlock(Flowable):
    """Monospaced lines with a background colour per line; splits between pages."""
    SIZE = 6.5
    LEAD = 8.1
    PAD = 3

    def __init__(self, lines, title=None):
        # lines: list of (gutter, marker, text, kind) kind in 'add','del','ctx','hunk','gap','plain'
        super().__init__()
        self.lines = lines
        self.title = title
        self.hAlign = 'LEFT'

    def wrap(self, aw, ah):
        self.aw = aw
        h = self.LEAD * len(self.lines) + 2 * self.PAD
        return aw, h

    def split(self, aw, ah):
        n = int((ah - 2 * self.PAD) / self.LEAD)
        if n < 4 or n >= len(self.lines):
            return []
        a = CodeBlock(self.lines[:n])
        b = CodeBlock(self.lines[n:])
        return [a, b]

    def draw(self):
        c = self.canv
        w = self.aw
        h = self.LEAD * len(self.lines) + 2 * self.PAD
        y = h - self.PAD
        c.setLineWidth(0.4)
        c.setStrokeColor(LINE)
        for gut, mark, text, kind in self.lines:
            y -= self.LEAD
            bg = {'add': ADD_BG, 'del': DEL_BG, 'ctx': CTX_BG, 'hunk': colors.HexColor('#e3ecf8'),
                  'gap': colors.white, 'plain': CTX_BG}[kind]
            c.setFillColor(bg)
            c.rect(0, y - 1.6, w, self.LEAD, stroke=0, fill=1)
            c.setFont('DejaVuMono', self.SIZE)
            c.setFillColor(GREY)
            if gut != '':
                c.drawRightString(21, y, str(gut))
            col = {'add': colors.HexColor('#14602a'), 'del': colors.HexColor('#8b1a1a'),
                   'ctx': colors.HexColor('#4a4f55'), 'hunk': colors.HexColor('#2a5db0'),
                   'gap': GREY, 'plain': colors.HexColor('#2d3136')}[kind]
            c.setFillColor(col)
            if mark:
                c.drawString(25, y, mark)
            c.drawString(33, y, text)
        c.setStrokeColor(LINE)
        c.rect(0, 0, w, h, stroke=1, fill=0)


MAXCH = 112


def _wrap_code(text):
    text = text.replace('\t', '    ')
    if len(text) <= MAXCH:
        return [text]
    out = [text[:MAXCH]]
    rest = text[MAXCH:]
    ind = len(text) - len(text.lstrip()) + 4
    while rest:
        out.append(' ' * ind + '↪ ' + rest[:MAXCH - ind - 2])
        rest = rest[MAXCH - ind - 2:]
    return out


_DIFF = None


def load_diff(base='7b16188'):
    """git diff <base> HEAD -- src/ split per file: {path: [(kind, text, newlineno)]}"""
    global _DIFF
    if _DIFF is not None:
        return _DIFF
    out = subprocess.run(['git', '-C', ROOT, 'diff', base, 'HEAD', '--', 'src/'], capture_output=True, text=True).stdout
    files = {}
    cur = None
    newno = 0
    for ln in out.splitlines():
        if ln.startswith('diff --git'):
            cur = ln.split(' b/')[-1]
            files[cur] = []
        elif cur is None or ln.startswith(('index ', '--- ', '+++ ', 'new file', 'deleted file', 'similarity')):
            continue
        elif ln.startswith('@@'):
            m = re.match(r'@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)', ln)
            newno = int(m.group(1))
            files[cur].append(('hunk', ln, 0))
        elif ln.startswith('+'):
            files[cur].append(('add', ln[1:], newno)); newno += 1
        elif ln.startswith('-'):
            files[cur].append(('del', ln[1:], 0))
        elif ln.startswith(' ') or ln == '':
            files[cur].append(('ctx', ln[1:], newno)); newno += 1
    _DIFF = files
    return files


def diff_stat():
    """list of (path, added, removed) from git diff --numstat"""
    out = subprocess.run(['git', '-C', ROOT, 'diff', '--numstat', '7b16188', 'HEAD', '--', 'src/'],
                         capture_output=True, text=True).stdout
    rows = []
    for ln in out.splitlines():
        a, d, f = ln.split('\t')
        rows.append((f, int(a), int(d)))
    return rows


def patch_frag(path, start, end=None, n=None, context_before=0, hide_ctx=False):
    """Fragment of the patch of one file: from the first line containing `start` to the line containing `end`
    (searched after the start) or n lines. Returns a flowable (a notice if the anchor is not found)."""
    d = load_diff().get(path)
    if d is None:
        return P('<i>[фрагмент недоступен: файл %s не найден в git diff]</i>' % path, 'small')
    idx = None
    for i, (k, t, _) in enumerate(d):
        if k != 'hunk' and start in t:
            idx = i
            break
    if idx is None:
        return P('<i>[фрагмент недоступен: «%s» не найдено в %s]</i>' % (start.replace('<', '&lt;'), path), 'small')
    a = max(0, idx - context_before)
    if end is not None:
        b = None
        for j in range(idx, len(d)):
            if d[j][0] != 'hunk' and end in d[j][1]:
                b = j
                break
        if b is None:
            b = min(len(d) - 1, idx + (n or 12))
    else:
        b = min(len(d) - 1, idx + (n or 12) - 1)
    rows = []
    for k, t, no in d[a:b + 1]:
        if k == 'hunk':
            m = re.match(r'@@ [^@]* @@(.*)', t)
            rows.append(('', '', '@@ ' + (m.group(1).strip() if m else ''), 'hunk'))
            continue
        for j, piece in enumerate(_wrap_code(t)):
            mark = {'add': '+', 'del': '-', 'ctx': ' '}[k] if j == 0 else ''
            rows.append((no if (j == 0 and k != 'del') else '', mark, piece, k))
    return CodeBlock(rows)


def src_frag(relpath, ranges):
    """Excerpt of a source file of the repository (CoupledL2, rocket-chip): line ranges [(a, b), ...] with line
    numbers; '...' between ranges."""
    p = os.path.join(ROOT, relpath)
    if not os.path.exists(p):
        return P('<i>[фрагмент недоступен: %s]</i>' % relpath, 'small')
    lines = open(p, errors='replace').read().splitlines()
    rows = []
    for ri, (a, b) in enumerate(ranges):
        if ri > 0:
            rows.append(('', '', '...', 'gap'))
        for no in range(a, b + 1):
            if no - 1 < len(lines):
                for j, piece in enumerate(_wrap_code(lines[no - 1])):
                    rows.append((no if j == 0 else '', '', piece, 'plain'))
    return CodeBlock(rows)


def text_block(text, kind='plain'):
    rows = []
    for ln in text.splitlines():
        for piece in _wrap_code(ln):
            rows.append(('', '', piece, kind))
    return CodeBlock(rows)


def cap(text):
    return Paragraph(mk(text), S['caption'])


# ------------------------------------------------------------------ document
class Doc(BaseDocTemplate):
    def __init__(self, path, short_name, **kw):
        super().__init__(path, pagesize=A4, leftMargin=MARGIN, rightMargin=MARGIN, topMargin=MARGIN,
                         bottomMargin=MARGIN + 0.3 * cm, title=kw.get('title', ''), author='')
        self.short = short_name
        self.sections = []        # (level, number, title, page)
        frame = Frame(MARGIN, MARGIN + 0.3 * cm, CONTENT_W, PAGE_H - 2 * MARGIN - 0.3 * cm, id='f', leftPadding=0,
                      rightPadding=0, topPadding=0, bottomPadding=0)
        self.addPageTemplates([PageTemplate(id='p', frames=[frame], onPage=self._footer)])
        self._n = 0

    def _footer(self, canv, doc):
        canv.saveState()
        canv.setStrokeColor(LINE)
        canv.setLineWidth(0.4)
        canv.line(MARGIN, 1.55 * cm, PAGE_W - MARGIN, 1.55 * cm)
        canv.setFont('DejaVu', 7.5)
        canv.setFillColor(GREY)
        canv.drawString(MARGIN, 1.15 * cm, self.short)
        canv.drawRightString(PAGE_W - MARGIN, 1.15 * cm, str(doc.page))
        canv.restoreState()

    def afterFlowable(self, fl):
        if isinstance(fl, Paragraph) and getattr(fl, '_toc', None):
            level, text = fl._toc
            key = 'h%d_%d' % (level, self._n)
            self._n += 1
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(text, key, level - 1, closed=(level > 1))
            self.sections.append((level, text, self.page))


def H(level, text):
    p = Paragraph(mk(text), S['h%d' % level])
    p._toc = (level, re.sub(r'<[^>]+>', '', text).replace('`', ''))
    return p


def src_anchor(relpath, specs):
    """Excerpt of a source file given by anchors: specs = [(substring, lines_before, lines_after[, nth]), ...]; the
    line numbers shown are those of the file in this tree."""
    p = os.path.join(ROOT, relpath)
    if not os.path.exists(p):
        return P('<i>[фрагмент недоступен: %s]</i>' % relpath, 'small')
    lines = open(p, errors='replace').read().splitlines()
    ranges = []
    for sp in specs:
        pat, bef, aft = sp[0], sp[1], sp[2]
        nth = sp[3] if len(sp) > 3 else 1
        k = 0
        hit = None
        for i, ln in enumerate(lines):
            if pat in ln:
                k += 1
                if k == nth:
                    hit = i + 1
                    break
        if hit is None:
            return P('<i>[фрагмент недоступен: «%s» не найдено в %s]</i>' % (pat.replace('<', '&lt;'), relpath), 'small')
        ranges.append((max(1, hit - bef), min(len(lines), hit + aft)))
    return src_frag(relpath, ranges)
