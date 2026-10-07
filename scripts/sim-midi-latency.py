#!/usr/bin/env python3
"""Measure MIDI-IN -> MIDI-OUT (Recomposer MIDI THRU) latency from midimon.log.

usage: scripts/sim-midi-latency.py <midimon.log>
Pairs each "IN 90 nn .." line with the next "90 nn .." output line.
"""
import statistics
import sys

ins, outs = [], []
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) >= 4 and p[1] == 'IN' and p[2] == '90':
        ins.append((float(p[0]), p[3]))
    elif len(p) >= 3 and p[1] == '90':
        outs.append((float(p[0]), p[2]))

lat = []
j = 0
for t, note in ins:
    while j < len(outs) and (outs[j][1] != note or outs[j][0] < t):
        j += 1
    if j < len(outs):
        lat.append(outs[j][0] - t)
        j += 1

print(f"in={len(ins)} out={len(outs)} matched={len(lat)}")
if lat:
    print(f"latency ms: min={min(lat):.1f} median={statistics.median(lat):.1f} "
          f"max={max(lat):.1f} stdev={statistics.pstdev(lat):.1f}")

# Jitter: compare output note intervals with the input intervals.
pairs = []
j = 0
for t, note in ins:
    while j < len(outs) and (outs[j][1] != note or outs[j][0] < t):
        j += 1
    if j < len(outs):
        pairs.append((t, outs[j][0]))
        j += 1
dev = [(o2 - o1) - (i2 - i1) for (i1, o1), (i2, o2) in zip(pairs, pairs[1:])]
if dev:
    print(f"interval error ms: mean abs={statistics.mean(abs(d) for d in dev):.1f} "
          f"max abs={max(abs(d) for d in dev):.1f}")
