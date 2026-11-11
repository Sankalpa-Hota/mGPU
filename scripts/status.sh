#!/bin/bash
# One line per block from the files in tb/*/logs: regression passes, merged coverage, planted bugs caught.
cd "$(dirname "$0")/../tb"
printf "%-24s %-12s %-26s %s\n" block regression coverage "planted bugs"
for m in */; do
  m=${m%/}; [ "$m" = common ] && continue
  p=$(grep -c "^PASS" $m/logs/regress.txt 2>/dev/null); f=$(grep -c "^FAIL" $m/logs/regress.txt 2>/dev/null)
  c=$(head -1 $m/logs/coverage_merged.txt 2>/dev/null | sed 's/merged functional coverage = //')
  caught=0; total=0; missed=""
  for b in $m/logs/bug_BUG_*.log; do
    [ -f "$b" ] || continue
    total=$((total+1))
    r=$(../scripts/check_log.sh $b expect_fail)
    case "$r" in "BUG CAUGHT"*) caught=$((caught+1));; *) missed="$missed $(basename $b .log)";; esac
  done
  printf "%-24s %-12s %-26s %s\n" "$m" "${p:-0} pass ${f:-0} fail" "${c:-n/a}" "$caught/$total caught$missed"
done
