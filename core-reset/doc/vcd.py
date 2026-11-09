#!/usr/bin/env python3
"""Small streaming VCD reader for the waveforms of core-reset/doc/make_pdf.py (section 7.4), and the event
checks that make_waves.sh uses to pick the simulation windows (no hard-coded cycle numbers).

  python3 vcd.py check <sweep1|case4|case5> FILE.vcd    exit code 0 if the window holds the event, prints it
  python3 vcd.py info FILE.vcd                            list of the cycles of the window with the states

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
            elif line.startswith('$enddefinitions'):
                break
        ch = {}          # short name -> list of (time, value)
        t = 0
        clk_edges = []
        clk_val = 0
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
                    else:
                        ch.setdefault(n, []).append((t, val))
        f.close()
        self.edges = clk_edges
        self.n = len(clk_edges)
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

    def __getitem__(self, name):
        return self.s.get(name, [None] * self.n)

    def has(self, name):
        return name in self.s

    def abs_cycle(self, i):
        c = self['cyc_tb'][i]
        return c


def transitions(seq, a, b):
    return [i for i in range(1, len(seq)) if seq[i - 1] == a and seq[i] == b]


def check_sweep1(w):
    """a whole sequence: sIdle -> sFlush ... sRelease -> sIdle inside the window"""
    st = w['ctl_st']
    t1 = transitions(st, S_IDLE, S_FLUSH)
    t2 = transitions(st, S_RELEASE, S_IDLE)
    if not t1 or not t2 or t2[0] < t1[0]:
        return False, 'no complete sequence in the window'
    return True, 'sFlush at window cycle %d, sIdle again at %d (%d cycles)' % (t1[0], t2[0], t2[0] - t1[0])


def check_case5(w):
    """a Probe taken by the gate in the last cycle of sFlush (L2 offers it, B ready = 1, valid and ready both 1)"""
    st = w['ctl_st']
    for d in transitions(st, S_FLUSH, S_DRAIN):
        if w['lb_v'][d - 1] == 1 and w['lb_r'][d - 1] == 1:
            return True, 'Probe taken in the last cycle of sFlush (window cycle %d), sDrain from %d' % (d - 1, d)
    return False, 'no Probe taken in the last cycle of sFlush'


def check_case4(w):
    """a Probe offered by L2 in the first cycle of sDrain, not taken (held), delivered to the DCache after the reset"""
    st = w['ctl_st']
    for d in transitions(st, S_FLUSH, S_DRAIN):
        if w['lb_v'][d] == 1 and w['lb_r'][d] == 0 and w['hold_probe'][d] == 1:
            ends = transitions(st, S_RELEASE, S_IDLE)
            if not ends:
                continue
            e = ends[0]
            acks = [i for i in range(e, w.n) if w['lc_v'][i] == 1 and w['lc_r'][i] == 1 and w['lc_op'][i] in (4, 5)]
            if not acks:
                continue
            return True, 'Probe offered in the first cycle of sDrain (window cycle %d), ProbeAck%s at %d' % (
                d, 'Data' if w['lc_op'][acks[0]] == 5 else '', acks[0])
    return False, 'no Probe offered in the first cycle of sDrain and answered after the reset'


CHECKS = {'sweep1': check_sweep1, 'case4': check_case4, 'case5': check_case5}


def main(argv):
    if len(argv) >= 3 and argv[1] == 'check':
        ok, msg = CHECKS[argv[2]](Wave(argv[3]))
        print(('OK  ' if ok else 'NO  ') + msg)
        return 0 if ok else 1
    if len(argv) >= 3 and argv[1] == 'info':
        w = Wave(argv[2])
        print('cycles %d, signals found %d' % (w.n, len(w.found)))
        st = w['ctl_st']
        last = None
        for i, s in enumerate(st):
            if s != last:
                print('cycle %5d  state %s' % (i, STATE_NAMES[s] if s is not None and s < 5 else s))
                last = s
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
