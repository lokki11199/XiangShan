#!/usr/bin/env python3
"""Generator of core-reset/xscore_reset_v5.pdf (the main deliverable of the core-only reset work, v5).

  python3 core-reset/doc/make_pdf.py            (from the repository root; reportlab 5, DejaVu fonts)

The document is data driven: the numbers come from core-reset/verification/results_*.txt, coverage_*.json, the soak
logs, the patch fragments from `git diff 7b16188 HEAD -- src/`, the timing diagrams from the VCD files that
core-reset/doc/make_waves.sh makes (vcd.py reads them). A missing file gives "нет данных" in the text, not an error.
Specification: core-reset/doc/SPEC_PDF.md.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import results as R                      # noqa: E402
from pdflib import Doc, diff_stat, ROOT  # noqa: E402
import content_a, content_b, content_c, content_d, content_e   # noqa: E402

OUT = os.path.join(ROOT, 'core-reset', 'xscore_reset_v5.pdf')


class Ctx:
    pass


def context():
    C = Ctx()
    C.ver = R.VER
    C.stat = diff_stat()
    C.formal = {'k': R.formal('k'), 's': R.formal('s')}
    C.eq = R.equiv()
    C.reg = R.regress()
    C.soak = {c: R.soak(c) for c in ('KEEP', 'CFG_SWEEP')}
    C.cov = {c: R.coverage(c) for c in ('KEEP', 'CFG_SWEEP')}
    C.elab = R.elab()
    C.rare = R.rare_seeds()
    C.verilator = None
    try:
        v = R.verilator_version()
        if v:
            C.verilator = v.split()[1] if v.startswith('Verilator') else v
    except Exception:
        pass

    def fnum(x):
        return ('%.2f' % x).replace('.', ',')
    C.fnum = fnum
    return C


def main():
    C = context()
    short = 'Сброс XSCore по debug reset (v5): уровень, ранний A, флаги пустоты, изоляция — описание изменений'
    doc = Doc(OUT, short, title='Сброс XSCore по debug reset (v5)')
    story = []
    story += content_a.front(C)
    story += content_a.section1(C)
    story += content_b.section2(C)
    story += content_b.section3(C)
    story += content_b.section4(C)
    story += content_c.section5(C)
    story += content_c.section6(C)
    story += content_d.section7(C)
    story += content_e.section8(C)
    story += content_e.section9(C)
    story += content_e.section10(C)
    doc.build(story)
    # summary: pages per top-level section
    secs = [(t, p) for (lv, t, p) in doc.sections if lv == 1]
    total = doc.page
    print('written', OUT, 'pages', total)
    for i, (t, p) in enumerate(secs):
        end = secs[i + 1][1] if i + 1 < len(secs) else total
        n = (end - p) + (1 if i + 1 < len(secs) and secs[i + 1][1] == end and False else 0)
        print('  %-70s start p.%d, %d page(s)' % (t[:70], p, max(1, end - p + 1)))
    json.dump({'pages': total, 'sections': doc.sections}, open(os.path.join(HERE, 'build_info.json'), 'w'),
              ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
