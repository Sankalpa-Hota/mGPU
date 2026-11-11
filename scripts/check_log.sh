#!/bin/bash
# Pass = the UVM report shows zero UVM_ERROR and zero UVM_FATAL (so the test reached the report phase).
log=$1; mode=$2
err=$(sed -n 's/^UVM_ERROR : *\([0-9]*\).*/\1/p' "$log")
fat=$(sed -n 's/^UVM_FATAL : *\([0-9]*\).*/\1/p' "$log")
cov=$(sed -n 's/.*functional coverage = \([0-9.]*%\).*/\1/p' "$log" | tail -1)
if [ "$err" = 0 ] && [ "$fat" = 0 ]; then res=PASS; else res=FAIL; fi
if [ "$mode" = expect_fail ]; then
  [ $res = FAIL ] && echo "BUG CAUGHT  $log (errors=${err:-?})" || echo "BUG MISSED  $log"
else
  echo "$res  $log (errors=${err:-?} fatals=${fat:-?} coverage=${cov:-n/a})"
fi
