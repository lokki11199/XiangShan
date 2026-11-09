"""Readers of the results files of core-reset/verification for make_pdf.py. Every reader returns None (or an
object with .ok False) when its file is missing, so that the document says "нет данных" instead of failing."""
import json
import os
import re
import subprocess

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
VER = os.path.join(ROOT, 'core-reset', 'verification')


def _read(name):
    p = os.path.join(VER, name)
    if not os.path.exists(p):
        return None
    try:
        return open(p, errors='replace').read()
    except OSError:
        return None


# ---------------------------------------------------------------- formal
def formal(cfg):
    """results_formal_<k|s>.txt (formal/run_formal.sh): prove 100 / 16 with the time, bmc, covers, mutants."""
    txt = _read('results_formal_%s.txt' % cfg)
    if txt is None:
        return None
    r = {'prove': {}, 'bmc': None, 'cover': None, 'covers': [], 'mutants': [], 'equiv': [], 'final': None,
         'tools': None}
    for line in txt.splitlines():
        m = re.match(r'design prove rstCycles=(\d+) .*?: (\w+)\s+\(([\d.]+) sec\)', line)
        if m:
            r['prove'][int(m.group(1))] = (m.group(2), float(m.group(3)))
            continue
        m = re.match(r'design\s+bmc (\d+): (\w+) \(assumptions satisfiable: (\w+)\)', line)
        if m:
            r['bmc'] = (int(m.group(1)), m.group(2), m.group(3))
            continue
        m = re.match(r'design\s+cover : (\w+) \((\d+) reached: (.*)\)', line)
        if m:
            r['cover'] = (m.group(1), int(m.group(2)))
            r['covers'] = [(a, int(b)) for a, b in re.findall(r'(\w+) step (\d+)', m.group(3))]
            continue
        m = re.match(r'(\w+)\s+bmc : (\w+) at cycle (\d+)\s*(.*)', line)
        if m:
            r['mutants'].append((m.group(1), m.group(2), int(m.group(3)), m.group(4).split()))
            continue
        m = re.match(r'(\w+)\s+prove: (\w+) \(equivalent', line)
        if m:
            r['equiv'].append((m.group(1), m.group(2)))
            continue
        m = re.match(r'formal: (\d+) unexpected', line)
        if m:
            r['final'] = int(m.group(1))
            continue
        if line.startswith('tools:'):
            r['tools'] = line[6:].strip()
    return r


def equiv():
    txt = _read('results_equiv.txt')
    if txt is None:
        return None
    rows = []
    for line in txt.splitlines():
        m = re.match(r'(\w+)\s+bmc(\d+): (\w+) ([\d.]+)s\s+prove: (\w+) ([\d.]+)s', line)
        if m:
            rows.append((m.group(1), int(m.group(2)), m.group(3), float(m.group(4)), m.group(5), float(m.group(6))))
    m = re.search(r'failed miters: (\d+)', txt)
    return {'rows': rows, 'failed': int(m.group(1)) if m else None}


# ---------------------------------------------------------------- regression
def regress():
    """results_regress.txt: the same classification as scripts/regress_summary.py."""
    txt = _read('results_regress.txt')
    if txt is None:
        return None
    lines = [l for l in txt.splitlines() if l.startswith('CFG=')]
    skipped = [l for l in lines if ': SKIPPED' in l]
    lines = [l for l in lines if l not in skipped]
    equiv_ = [l for l in lines if ' +EQUIV ' in l]
    mut = [l for l in lines if 'MUTANT' in l and l not in equiv_]
    naive = [l for l in lines if ' SCEN=4 ' in l]
    good = [l for l in lines if l not in equiv_ and l not in mut and l not in naive]

    def caught(l):
        return 'ERROR' in l or '%Error' in l or 'TIMEOUT' in l or 'RESULT: FAIL' in l

    def reproduced(l):
        return 'ERROR' in l or '%Error' in l or 'TIMEOUT' in l or 'problem reproduced' in l

    def passed(l):
        return 'RESULT: PASS' in l and 'ERROR' not in l and '%Error' not in l and 'TIMEOUT' not in l

    cfg = lambda l: l.split()[0][4:]
    scen = lambda l: int(re.search(r'SCEN=(\d+)', l).group(1))
    res = {'cfg': {}, 'mut': {}, 'equiv': {}, 'skipped': len(skipped), 'total': len(lines)}
    for c in ['KEEP', 'CFG_SWEEP']:
        f = lambda L: [l for l in L if cfg(l) == c]
        res['cfg'][c] = {
            'design': len(f(good)), 'design_pass': sum(passed(l) for l in f(good)),
            'naive': len(f(naive)), 'naive_rep': sum(reproduced(l) for l in f(naive)),
            'mut': len(f(mut)), 'mut_caught': sum(caught(l) for l in f(mut)),
            'eq': len(f(equiv_)), 'eq_pass': sum(passed(l) for l in f(equiv_)),
        }
        # design runs per scenario
        sc = {}
        for l in f(good):
            k = (scen(l), '+SLOW' in l)
            a = sc.setdefault(k, [0, 0])
            a[0] += 1
            a[1] += passed(l)
        res['cfg'][c]['by_scen'] = sc
    for l in mut + equiv_:
        m = re.search(r'MUTANT=(\S+)', l)
        name = m.group(1)
        tgt = res['equiv'] if l in equiv_ else res['mut']
        d = tgt.setdefault(name, {})
        a = d.setdefault(cfg(l), {'runs': 0, 'ok': 0, 'scen': set()})
        a['runs'] += 1
        a['scen'].add(scen(l))
        a['ok'] += (passed(l) if l in equiv_ else caught(l))
    res['not_ok'] = (
        [l[:160] for l in good + equiv_ if not passed(l)] + [l[:160] for l in mut if not caught(l)] +
        [l[:160] for l in naive if not reproduced(l)])
    res['complete'] = bool(lines) and not res['not_ok'] and not skipped
    return res


# ---------------------------------------------------------------- soak and coverage
def soak(cfg):
    """results_soak_<KEEP|CFG_SWEEP>.log -> (runs, passed)"""
    txt = _read('results_soak_%s.log' % cfg)
    if txt is None:
        return None
    runs = len(re.findall(r'^###', txt, re.M))
    ok = len(re.findall(r'^RESULT: PASS', txt, re.M))
    return {'runs': runs, 'pass': ok}


def coverage(cfg):
    """coverage_<cfg>.json; if it is missing but the soak log exists, scripts/coverage.py is run on the log"""
    txt = _read('coverage_%s.json' % cfg)
    if txt is not None:
        try:
            return json.loads(txt)
        except ValueError:
            return None
    log = os.path.join(VER, 'results_soak_%s.log' % cfg)
    if os.path.exists(log):
        try:
            out = subprocess.run(['python3', os.path.join(VER, 'scripts', 'coverage.py'), log], capture_output=True,
                                 text=True, timeout=120).stdout
            return json.loads(out)
        except Exception:
            return None
    return None


def elab():
    """results_elab.txt: full elaboration of XSNoCTop (written by the architect)"""
    return _read('results_elab.txt')


def rare_seeds():
    txt = _read('scripts/rare_seeds.txt')
    if txt is None:
        return None
    rows = []
    for l in txt.splitlines():
        p = l.split()
        if len(p) >= 3:
            rows.append((p[0], p[1], p[2:]))
    return rows


def verilator_version():
    try:
        out = subprocess.run('. %s/scripts/env.sh >/dev/null 2>&1; verilator --version' % VER, shell=True,
                             capture_output=True, text=True, timeout=20, executable='/bin/bash').stdout.strip()
        return out
    except Exception:
        return None
