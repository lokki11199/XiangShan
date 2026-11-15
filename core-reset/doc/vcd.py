#!/usr/bin/env python3
"""Small streaming VCD reader for the waveforms of core-reset/doc/make_pdf.py (section 7.4), and the event
checks that make_waves.sh uses to pick the simulation windows (no hard-coded cycle numbers).

  python3 vcd.py extract <sweep1|case4|case5> IN.vcd OUT.vcd [AFTER_CYCLE]
        looks for the event in IN.vcd (not before the testbench cycle AFTER_CYCLE), writes a small VCD around it
        (only the signals of SIGNALS); exit code 0 if the event was found, prints it
  python3 vcd.py info FILE.vcd        states of CoreResetCtrl over the file

Only the signals asked for are kept (the testbench dumps about 40000 signals). Values are sampled once per
clock cycle: the value a signal has just before the rising edge of cr_tb.clk, i.e. the value during the cycle that
the edge ends (a register shows its new value in the cycle after its edge).
"""
import sys

# CoreResetCtrl states of the testbench (cr_tb.ctl_st)
S_IDLE, S_FLUSH, S_DRAIN, S_RESET, S_RELEASE = range(5)
STATE_NAMES = ['sIdle', 'sFlush', 'sDrain', 'sReset', 'sRelease']

# every signal used by the diagrams (names inside cr_tb; u_dc.fst is the state of the DCache flush unit)
SIGNALS = [
    'req', 'ctl_st', 'busy', 'early_block', 'gate_block', 'hold_probe', 'ack_probe', 'isolate', 'ctl_core_reset',
    'core_rst', 'fe_rst', 'dc_alive', 'hart_in_reset', 'l1_freeze', 'flush_done', 'flush_idle', 'quiet0', 'quiet1',
    'quiet2', 'iso_quiet', 'n_l1_lines', 'n_dir_lines', 'lb_v', 'lb_r', 'lb_par', 'lb_addr', 'lc_v', 'lc_r',
    'lc_op', 'lc_par', 'ld_v', 'ld_r', 'le_v', 'le_r', 'la_v', 'la_r', 'cc_v', 'cc_r', 'gb_v', 'gb_r', 'db_v',
    'db_r', 'c_gate', 'b_gate', 'ma_v', 'ma_r', 'wa_v', 'wa_r', 'ca_v', 'ca_r', 'cyc_tb', 'last_flush_take',
    'u_dc.fst', 'u_dc.inflight', 'tgt_l1', 'tgt_dir', 'tgt_addr', 'u_l2.prb_v',
]


class Wave:
    """Samples per clock cycle of the wanted signals: w['ctl_st'][i] is the value in cycle i (None = x/z)."""

    def __init__(self, path, signals=SIGNALS):
        want = {}
        for s in signals:
            want['cr_tb.' + s] = s
            want['cr_tb.' + s.replace('.', '__')] = s     # names written by write_trim
        ids = {}        # vcd id -> [short names]
        widths = {}
        scope = []
        self.found = set()
        f = open(path, 'r', errors='replace')
        for line in f:
            line = line.strip()
            if line.startswith('$scope'):
                scope.append(line.split()[2])
            elif line.startswith('$upscope'):
                scope.pop()
            elif line.startswith('$var'):
                p = line.split()
                full = '.'.join(scope) + '.' + p[4]
                if full in want:
                    ids.setdefault(p[3], []).append(want[full])
                    widths[p[3]] = int(p[2])
                    self.found.add(want[full])
                if full == 'cr_tb.clk':
                    ids.setdefault(p[3], []).append('__clk')
                    widths[p[3]] = 1
            elif line.startswith('$enddefinitions'):
                break
        ch = {}          # short name -> list of (time, value); the clock is '__clk'
        t = 0
        clk_edges = []
        clk_val = None
        for line in f:
            c = line[0]
            if c == '#':
                t = int(line[1:])
                continue
            if c == 'b' or c == 'B':
                v, i = line[1:].split()
                names = ids.get(i)
                if not names:
                    continue
                try:
                    val = int(v, 2)
                except ValueError:
                    val = None
                for n in names:
                    ch.setdefault(n, []).append((t, val))
            elif c in '01xzXZ':
                i = line[1:].strip()
                names = ids.get(i)
                if not names:
                    continue
                val = int(c) if c in '01' else None
                for n in names:
                    if n == '__clk':
                        if val == 1 and clk_val == 0:
                            clk_edges.append(t)
                        clk_val = val
                    ch.setdefault(n, []).append((t, val))
        f.close()
        self.edges = clk_edges
        self.n = len(clk_edges)
        self.ch = ch
        self.widths = {ids_n: widths[i] for i, ns in ids.items() for ids_n in ns if ids_n != '__clk'}
        self.s = {}
        for n in self.found:
            self.s[n] = self._sample(ch.get(n, []), clk_edges)

    @staticmethod
    def _sample(changes, edges):
        out = []
        j = 0
        cur = None
        for e in edges:
            while j < len(changes) and changes[j][0] < e:
                cur = changes[j][1]
                j += 1
            out.append(cur)
        return out

    def index_of_cycle(self, cyc):
        """first sample index whose cyc_tb is >= cyc"""
        for i, c in enumerate(self['cyc_tb']):
            if c is not None and c >= cyc:
                return i
        return self.n

    def write_trim(self, path, c0, c1):
        """VCD with the wanted signals and the clock for the cycles c0..c1 (sample indices) only"""
        c0 = max(0, c0)
        c1 = min(self.n - 1, c1)
        tmin = self.edges[c0] - 10000 if c0 > 0 else 0
        tmax = self.edges[c1]
        names = ['__clk'] + sorted(n for n in self.found)
        code = {}
        for k, n in enumerate(names):
            x, c = k, ''
            while True:
                c += chr(33 + x % 94)
                x //= 94
                if x == 0:
                    break
            code[n] = c
        out = ['$version trimmed by vcd.py $end', '$timescale 1ps $end', '$scope module cr_tb $end']
        for n in names:
            w = 1 if n == '__clk' else self.widths.get(n, 1)
            out.append('$var wire %d %s %s $end' % (w, code[n], 'clk' if n == '__clk' else n.replace('.', '__')))
        out += ['$upscope $end', '$enddefinitions $end']
        def fmt(n, v):
            w = 1 if n == '__clk' else self.widths.get(n, 1)
            if v is None:
                return ('x' + code[n]) if w == 1 else ('bx ' + code[n])
            return ('%d%s' % (v, code[n])) if w == 1 else ('b%s %s' % (bin(v)[2:], code[n]))
        out.append('#%d' % tmin)
        events = {}
        for n in names:
            cur = None
            for (t, v) in self.ch.get(n, []):
                if t < tmin:
                    cur = (t, v)
                elif t <= tmax:
                    events.setdefault(t, []).append(fmt(n, v))
                else:
                    break
            if cur is not None:
                out.append(fmt(n, cur[1]))
        for t in sorted(events):
            out.append('#%d' % t)
            out += events[t]
        open(path, 'w').write('\n'.join(out) + '\n')

    def __getitem__(self, name):
        return self.s.get(name, [None] * self.n)

    def has(self, name):
        return name in self.s

    def abs_cycle(self, i):
        c = self['cyc_tb'][i]
        return c


def transitions(seq, a, b, start=0):
    return [i for i in range(max(1, start), len(seq)) if seq[i - 1] == a and seq[i] == b]


def find_sweep1(w, start=0):
    """a whole sequence: sIdle -> sFlush ... sRelease -> sIdle inside the window; returns (ok, msg, c0, c1, event)"""
    st = w['ctl_st']
    t1 = transitions(st, S_IDLE, S_FLUSH, start)
    if not t1:
        return False, 'no sequence in the window', 0, 0, None
    t2 = [i for i in transitions(st, S_RELEASE, S_IDLE, start) if i > t1[0]]
    if not t2:
        return False, 'the sequence is not complete in the window', 0, 0, None
    return (True, 'sFlush at sample %d, sIdle again at %d (%d cycles)' % (t1[0], t2[0], t2[0] - t1[0]),
            t1[0] - 20, t2[0] + 20, t1[0])


def find_case5(w, start=0):
    """a Probe taken by the gate in the last cycle of sFlush (L2 offers it, B ready = 1, valid and ready both 1)"""
    st = w['ctl_st']
    for d in transitions(st, S_FLUSH, S_DRAIN, start):
        if w['lb_v'][d - 1] == 1 and w['lb_r'][d - 1] == 1:
            ends = [i for i in transitions(st, S_RELEASE, S_IDLE, d)]
            if not ends:
                continue
            return (True, 'Probe taken in the last cycle of sFlush (sample %d), sDrain from %d' % (d - 1, d),
                    d - 40, ends[0] + 25, d)
    return False, 'no Probe taken in the last cycle of sFlush', 0, 0, None


def find_case4(w, start=0):
    """a Probe offered by L2 in the first cycle of sDrain, not taken (held), delivered to the DCache after the reset"""
    st = w['ctl_st']
    for d in transitions(st, S_FLUSH, S_DRAIN, start):
        if w['lb_v'][d] == 1 and w['lb_r'][d] == 0 and w['hold_probe'][d] == 1:
            ends = transitions(st, S_RELEASE, S_IDLE, d)
            if not ends:
                continue
            e = ends[0]
            acks = [i for i in range(e, w.n) if w['lc_v'][i] == 1 and w['lc_r'][i] == 1 and w['lc_op'][i] in (4, 5)]
            if not acks:
                continue
            return (True, 'Probe offered in the first cycle of sDrain (sample %d), ProbeAck%s at %d' % (
                d, 'Data' if w['lc_op'][acks[0]] == 5 else '', acks[0]), d - 40, acks[0] + 25, d)
    return False, 'no Probe offered in the first cycle of sDrain and answered after the reset', 0, 0, None


CHECKS = {'sweep1': find_sweep1, 'case4': find_case4, 'case5': find_case5}


def main(argv):
    # extract KIND IN.vcd OUT.vcd [AFTER_CYCLE]: find the event (not before the cyc_tb value AFTER_CYCLE), write
    # the trimmed VCD around it; exit code 0 if found
    if len(argv) >= 5 and argv[1] == 'extract':
        w = Wave(argv[3])
        start = w.index_of_cycle(int(argv[5])) if len(argv) > 5 else 0
        ok, msg, c0, c1, ev = CHECKS[argv[2]](w, start)
        print(('OK  ' if ok else 'NO  ') + msg)
        if ok:
            w.write_trim(argv[4], c0, c1)
        return 0 if ok else 1
    if len(argv) >= 3 and argv[1] == 'info':
        w = Wave(argv[2])
        print('cycles %d, signals found %d' % (w.n, len(w.found)))
        st = w['ctl_st']
        last = None
        for i, s in enumerate(st):
            if s != last:
                print('sample %5d  cyc_tb %s  state %s' % (i, w['cyc_tb'][i],
                                                          STATE_NAMES[s] if s is not None and s < 5 else s))
                last = s
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
