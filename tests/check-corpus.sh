#!/bin/sh
# check-corpus.sh — turn the corpus runner into an actual gate.
#
# corpus_runner is a REPORTER: it prints PASS/FAIL counts and exits 0 either way. Wiring
# CI straight to it would go green with 21 fixtures failing. This script runs it and diffs
# the failing case ids against tests/known-failures.txt, so a regression fails the build
# and a fixed case has to be recorded rather than silently absorbed.
#
# Usage: tests/check-corpus.sh [fixtures-dir]      (falls back to $SPINTAX_FIXTURES)

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
fixtures=${1:-${SPINTAX_FIXTURES:-}}
baseline="$root/tests/known-failures.txt"
runner="$root/tests/corpus_runner"

# fpc honours -o literally, so the binary has no .exe suffix even on Windows; a shell can
# execute it there regardless. Accept either name rather than assuming the platform.
[ -x "$runner" ] || runner="$runner.exe"

if [ -z "$fixtures" ] || [ ! -d "$fixtures" ]; then
  echo "check-corpus: no fixtures directory (pass one, or set SPINTAX_FIXTURES)" >&2
  echo "  expected the 'packages/conformance/fixtures' dir of a spintax-js checkout" >&2
  exit 2
fi

if [ ! -x "$runner" ]; then
  echo "check-corpus: $runner is not built - run ./build.sh first" >&2
  exit 2
fi

# A fixtures path that resolves to an empty directory would let the runner "succeed" over
# zero cases. Count the files before trusting anything it prints.
n=$(find "$fixtures" -maxdepth 1 -name '*.json' | wc -l)
if [ "$n" -lt 7 ]; then
  echo "check-corpus: only $n fixture files in $fixtures - that is not the golden corpus" >&2
  exit 2
fi

out=$("$runner" "$fixtures")
echo "$out" | tail -n 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A failing case prints "  FAIL [file.json] case  want=[...] got=[...]", and want/got may
# themselves contain newlines - so match only the lines that open a report.
echo "$out" \
  | sed -n 's/^[[:space:]]*FAIL \[\([^]]*\)\] \([^[:space:]]*\).*$/\1  \2/p' \
  | sort -u > "$tmp/actual"

sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$baseline" \
  | grep -v '^$' | sort -u > "$tmp/expected"

if diff -u "$tmp/expected" "$tmp/actual" > "$tmp/diff"; then
  echo "check-corpus: ok - $(wc -l < "$tmp/actual" | tr -d ' ') known failures, no regressions"
  exit 0
fi

echo "check-corpus: the failure set moved." >&2
echo "  '-' = a case in tests/known-failures.txt that now PASSES: delete the line (and say so)." >&2
echo "  '+' = a NEW failure: a regression - fix it, do not add it to the baseline." >&2
echo >&2
tail -n +3 "$tmp/diff" >&2
exit 1
