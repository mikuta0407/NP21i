#!/usr/bin/env python3
"""Analyze scripts/sim-rec-test.sh: input note timing vs played-back timing.

usage: scripts/sim-rec-analyze.py <midimon.log> <first playback line>
Input notes are the "IN 90 nn" lines, playback notes are output "90 nn vv"
(vv != 0) lines after the given line number. Notes are paired by number, and
the onset intervals are compared (the absolute offset does not matter).
"""
import statistics
import sys

lines = open(sys.argv[1]).read().splitlines()
mark = int(sys.argv[2])

def onsets(rows, is_input):
    out = {}
    for row in rows:
        p = row.split()
        if is_input:
            if len(p) >= 5 and p[1] == 'IN' and p[2] == '90' and p[4] != '00':
                out.setdefault(p[3], float(p[0]))
        else:
            # a packet may hold several messages (running status not used here)
            t = float(p[0])
            b = p[1:]
            k = 0
            while k + 2 < len(b) + 1 and k < len(b):
                if b[k] == '90' and k + 2 < len(b) and b[k + 2] != '00':
                    out.setdefault(b[k + 1], t)
                k += 3 if b[k][0] in '89abe' else 2 if b[k][0] in 'cd' else 1
    return out

ins = onsets(lines, True)
outs = onsets(lines[mark:], False)
common = sorted(set(ins) & set(outs), key=lambda n: ins[n])
print(f"input notes={len(ins)} played back={len(outs)} paired={len(common)}")
if len(common) < 3:
    sys.exit(1)
err = []
for a, b in zip(common, common[1:]):
    err.append((outs[b] - outs[a]) - (ins[b] - ins[a]))
ab = sorted(abs(e) for e in err)
print(f"interval error ms: mean abs={statistics.mean(ab):.2f} p90={ab[int(len(ab) * 0.9)]:.2f} "
      f"max={ab[-1]:.2f} (mean signed={statistics.mean(err):+.2f})")
