#!/usr/bin/env python3
"""Merge the bin counts printed by every log in a module's logs/ folder into one regression coverage report."""
import re, sys, glob, os
logdir = sys.argv[1] if len(sys.argv) > 1 else "logs"
hits = {}
for f in sorted(glob.glob(os.path.join(logdir, "*_s*.log"))):
    inside = False
    for line in open(f, errors="ignore"):
        if "functional coverage =" in line:
            inside = True
            continue
        if inside:
            m = re.match(r"^\s{4}(\S+)\s+(\d+)\s*$", line)
            if not m:
                inside = False
                continue
            hits[m.group(1)] = hits.get(m.group(1), 0) + int(m.group(2))
total = len(hits); hit = sum(1 for v in hits.values() if v)
out = [f"merged functional coverage = {100.0*hit/max(total,1):.1f}% ({hit}/{total} bins)"]
out += [f"  {k:<30} {v}" for k, v in hits.items()]
open(os.path.join(logdir, "coverage_merged.txt"), "w").write("\n".join(out) + "\n")
print(out[0]); [print("  UNHIT", k) for k, v in hits.items() if v == 0]
