#!/usr/bin/env bash
# The stand-in tests: each script of tests/ but this one and lib.sh, run on
# this Mac alone, with fakes for whatever it would change or reach. Exits
# failing when any check failed.
set -u
cd "$(dirname "$0")" || exit 1
status=0
for test in *.sh; do
    case "$test" in
        run.sh | lib.sh) continue ;;
    esac
    echo "== ${test%.sh}"
    bash "$test" || status=1
done
if [ "$status" -eq 0 ]; then
    echo "All passed."
else
    echo "Some failed; see above."
fi
exit "$status"
