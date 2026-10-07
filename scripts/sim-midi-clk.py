#!/usr/bin/env python3
"""Output timing error against emulated time, from midiclk.log.

usage: scripts/sim-midi-clk.py <midiclk.log>
Each line is "<emulated ms> <delivery ms>" ("gap" starts a new segment).
The offset (delivery - emulated) should be constant; its spread is the timing
error a listener hears. Slow drift (emulation speed vs real time) is removed
with a 2 s moving median per segment.
"""
import bisect
import statistics
import sys

segments = [[]]
for line in open(sys.argv[1]):
    if not line.endswith('\n'):
        break  # the app may still be writing the last line
    p = line.split()
    if p == ['gap']:
        segments.append([])
    elif len(p) == 2:
        segments[-1].append((float(p[0]), float(p[1])))

err = []
for rows in segments:
    if len(rows) < 20:
        continue
    emu = [e for e, _ in rows]
    off = [d - e for e, d in rows]
    for e, o in zip(emu, off):
        lo = bisect.bisect_left(emu, e - 1000)
        hi = bisect.bisect_right(emu, e + 1000)
        err.append(o - statistics.median(off[lo:hi]))

if not err:
    sys.exit("not enough data")
a = sorted(abs(x) for x in err)
print(f"messages={len(a)} mean abs={statistics.mean(a):.2f}ms "
      f"p90={a[int(len(a) * 0.9)]:.2f}ms p99={a[int(len(a) * 0.99)]:.2f}ms max={a[-1]:.2f}ms")
