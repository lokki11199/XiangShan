#!/usr/bin/env python3
"""Adds up the coverage lines of results_soak_<cfg>.log (v6: cr_txmon, cr_probe_sb, drain, iso, b2b, req-drop, full,
triggers C1..C15, directed Probes of nine cases). Prints JSON (keys of TESTPLAN 4.6)."""
import re, sys, json
log = sys.argv[1] if len(sys.argv) > 1 else 'results_soak.log'
tot = {}
def add(k, v): tot[k] = tot.get(k, 0) + int(v)
runs = 0
for line in open(log):
    line = line.strip()
    if line.startswith('###'): runs += 1; continue
    if line.startswith('final:'):
        for k in ['resets', 'reset-points', 'dcache-ops', 'ul-ops', 'icachectrl-ops', 'probes', 'spurious-probes',
                  'snoops-served-by-L2-alone', 'acquire-perm', 'lines-kept', 'probes-held',
                  'probes-answered-by-gate', 'errors']:
            m = re.search(r'\b' + k + r'=(\d+)', line); add('final.' + k, m.group(1))
    elif line.startswith('txmon-open-at-start:'):
        for c, v in re.findall(r'C(\d+)=(\d+)', line): add('open_at_start.C' + c, v)
    elif line.startswith('txmon-pre-completed:'):
        for k, v in re.findall(r'(\w+)=(\d+)', line): add('pre_done.' + k, v)
    elif line.startswith('txmon-started-in-sQuiesce:'):
        a, b = line.split('in-sDrain:')
        for k, v in re.findall(r'(\w+)=(\d+)', a): add('started_sQuiesce.' + k, v)
        for k, v in re.findall(r'(\w+)=(\d+)', b): add('started_sDrain.' + k, v)
    elif line.startswith('txmon:'):
        m = re.search(r'max-pre-latency=(\d+)', line); tot['max_pre_latency'] = max(tot.get('max_pre_latency', 0), int(m.group(1)))
        m = re.search(r'probes-answered-by-gate=(\d+)', line); add('txmon.gate_probes', m.group(1))
        m = re.search(r'errors=(\d+)', line); add('txmon.errors', m.group(1))
    elif line.startswith('probe-sb: probes offered'):
        m = re.search(r'longest-wait=(\d+)', line); tot['probe_longest_wait'] = max(tot.get('probe_longest_wait', 0), int(m.group(1)))
        line = re.sub(r'longest-wait=\d+', '', line)
        for k, v in re.findall(r'([\w()]+)=(\d+)', line): add('probe_offered.' + k, v)
    elif line.startswith('probe-sb: NtoN-for-lines-not-held'):
        m = re.search(r'not-held=(\d+) answered-by-the-gate=(\d+) longest-wait-outside-reset=(\d+)', line)
        add('probe.NtoN', m.group(1)); add('probe.gate_ack', m.group(2))
        tot['probe_longest_wait_outside_reset'] = max(tot.get('probe_longest_wait_outside_reset', 0), int(m.group(3)))
    elif line.startswith('probe-sb: ProbeAckData'):
        m = re.search(r'ProbeAckData=(\d+) clean-ProbeAck-from-T=(\d+).*dirty=(\d+) clean-T=(\d+) B=(\d+) \(toB (\d+)\)', line)
        for k, v in zip(['ProbeAckData', 'clean_from_T', 'hot_dirty', 'hot_cleanT', 'hot_B', 'hot_toB'], m.groups()): add('probe.' + k, v)
    elif line.startswith(('iso:', 'b2b:', 'req-drop:', 'full:')):
        pre = line.split(':')[0].replace('-', '_')
        for k, v in re.findall(r'([\w-]+)=(\d+)', line): add(pre + '.' + k.replace('-', '_'), v)
    elif line.startswith('triggers hit:'):
        for c, v in re.findall(r'C(\d+)=(\d+)', line): add('trig_hit.C' + c, v)
    elif line.startswith('triggers missed:'):
        for c, v in re.findall(r'C(\d+)=(\d+)', line): add('trig_miss.C' + c, v)
    elif line.startswith('drain:'):
        for k, v in re.findall(r'([\w-]+)=(\d+)', line):
            if k == 'longest-sDrain': tot['drain.' + k] = max(tot.get('drain.' + k, 0), int(v))
            else: add('drain.' + k, v)
    elif line.startswith('directed: dirty lines'):          # before the general 'directed:' line
        m = re.search(r'stale before the Probe=(\d+), skipped=(\d+), lost-lines-answered-by-the-gate=(\d+) \(of them dirty (\d+)\)', line)
        add('dir.dirty_l2_stale', m.group(1)); add('dir.skipped', m.group(2)); add('dir.lost_by_gate', m.group(3)); add('dir.lost_dirty_by_gate', m.group(4))
    elif line.startswith('directed: '):                      # the six trigger cases: <name> offered-in-<phase>=N later|transition-later=N
        m = re.match(r'directed: (\S+) offered-in-(\w+)=(\d+) (?:transition-)?later=(\d+)', line)
        n = m.group(1).replace('-', '_')
        add('dir.' + n + '.offered', m.group(3)); add('dir.' + n + '.later', m.group(4))
    elif line.startswith('debug-hold:'):
        m = re.search(r'holds=(\d+) snoops-during-hold=(\d+) \(dirty (\d+)\) longest-snoop-to-ProbeAck=(\d+) served-by-L2-alone=(\d+) waited-for-the-release=(\d+) longest-after-release=(\d+)', line)
        add('dbg.holds', m.group(1)); add('dbg.snoops', m.group(2)); add('dbg.dirty', m.group(3))
        tot['dbg.longest_ack'] = max(tot.get('dbg.longest_ack', 0), int(m.group(4)))
        add('dbg.l2only', m.group(5)); add('dbg.waited', m.group(6))
        m2 = re.search(r'data-from-hot-L1D=(\d+) crossed-an-eviction=(\d+)', line)
        add('dbg.hot', m2.group(1)); add('dbg.race', m2.group(2))
        tot['dbg.longest_after_release'] = max(tot.get('dbg.longest_after_release', 0), int(m.group(7)))
    elif line.startswith('directed '):
        m = re.match(r'directed (.+?)\s+dirty toN=(\d+) toB=(\d+) \| clean-T toN=(\d+) toB=(\d+) \| B toN=(\d+)', line)
        w = m.group(1).strip().replace(' ', '_')
        for k, v in zip(['dirty_toN', 'dirty_toB', 'cleanT_toN', 'cleanT_toB', 'B_toN'], m.groups()[1:]): add('dir.' + w + '.' + k, v)
tot['runs'] = runs
json.dump(tot, sys.stdout, indent=1, sort_keys=True)
print()
