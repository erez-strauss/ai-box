#!/usr/bin/env bash
# Run every test file. Plain bash, no framework: the point is that this runs
# anywhere the package does, including from an extracted tarball.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")" || exit 1
rc=0
for f in ./*.test.sh; do
    printf '\n\033[1m%s\033[0m\n' "$(basename "$f")"
    bash "$f" || rc=1
done
printf '\n'
if (( rc == 0 )); then printf '\033[32mall tests passed\033[0m\n'; else printf '\033[31mtests FAILED\033[0m\n'; fi
exit $rc
