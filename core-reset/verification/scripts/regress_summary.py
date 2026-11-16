#!/usr/bin/env python3
"""Summary of the regress.sh results: design runs must PASS, the naive reset and every mutant must report an
error, the +EQUIV mutants must PASS. Exit code 0 only if everything is as expected."""
import sys
lines = [l for l in open(sys.argv[1] if len(sys.argv) > 1 else 'results_regress.txt').read().splitlines() if l.startswith('CFG=')]
skipped = [l for l in lines if ': SKIPPED' in l]
lines = [l for l in lines if l not in skipped]
equiv = [l for l in lines if ' +EQUIV ' in l]
mut = [l for l in lines if 'MUTANT' in l and l not in equiv]
naive = [l for l in lines if ' SCEN=4 ' in l]
good = [l for l in lines if l not in equiv and l not in mut and l not in naive]
caught = lambda l: ('ERROR' in l or '%Error' in l or 'TIMEOUT' in l or 'RESULT: FAIL' in l)
# the naive reset: 'RESULT: FAIL (no error observed)' means the problem was NOT reproduced
reproduced = lambda l: ('ERROR' in l or '%Error' in l or 'TIMEOUT' in l or 'problem reproduced' in l)
passed = lambda l: 'RESULT: PASS' in l and 'ERROR' not in l and '%Error' not in l and 'TIMEOUT' not in l
cfg = lambda l: l.split()[0][4:]
print('design runs: %d, PASS %d' % (len(good), sum(passed(l) for l in good)))
for c in ['KEEP', 'CFG_SWEEP']:
    f = lambda L: [l for l in L if cfg(l) == c]
    print('  %-10s design %3d PASS %3d | naive %2d reproduced %2d | mutant runs %3d caught %3d | +EQUIV %2d PASS %2d' % (
        c, len(f(good)), sum(passed(l) for l in f(good)), len(f(naive)), sum(reproduced(l) for l in f(naive)),
        len(f(mut)), sum(caught(l) for l in f(mut)), len(f(equiv)), sum(passed(l) for l in f(equiv))))
print('naive reset: %d, problem reproduced %d' % (len(naive), sum(reproduced(l) for l in naive)))
print('mutant runs: %d, caught %d' % (len(mut), sum(caught(l) for l in mut)))
print('+EQUIV runs: %d, PASS %d' % (len(equiv), sum(passed(l) for l in equiv)))
for l in good:
    if not passed(l): print('  FAIL', l[:200])
for l in naive:
    if not reproduced(l): print('  NAIVE NOT REPRODUCED', l[:200])
for l in mut:
    if not caught(l): print('  NOT CAUGHT', l[:200])
for l in equiv:
    if not passed(l): print('  EQUIV NOT PASSING', l[:200])
for l in skipped: print('  SKIPPED', l[:200])
ok = all(passed(l) for l in good + equiv) and all(caught(l) for l in mut) and all(reproduced(l) for l in naive) and bool(lines)
sys.exit(0 if ok else 1)
