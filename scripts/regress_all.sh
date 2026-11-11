#!/bin/bash
# Runs every module's regression and bug-injection checks; prints one summary.
cd "$(dirname "$0")/../tb"
for m in */; do
  m=${m%/}; [ "$m" = common ] && continue
  echo "=== $m"; make -s -C $m regress; make -s -C $m bugs 2>/dev/null
done | tee ../regress_summary.txt
