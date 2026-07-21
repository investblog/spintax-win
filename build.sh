#!/bin/sh
# Build the conformance runner and the demo. Requires Free Pascal (fpc) 3.2.2+.
# The runner is a .dpr shared with Delphi (see tests/SpxJson.pas). -Futests puts the
# JSON facade on the unit path: the FPC branch resolves units by search path, not by
# `in` clauses, whose backslashes would not resolve on the Linux CI runner.
set -e
# Always start from an empty unit cache. FPC reuses .ppu files it finds here, and a
# leftover unit built under different switches (the -Cn syntax gate used to share
# this directory) produced a DIFFERENT corpus result from the same sources.
rm -rf lib
mkdir -p lib
fpc -Mdelphi -Fusrc -Futests -FUlib -O2 tests/corpus_runner.dpr -otests/corpus_runner
fpc -Mdelphi -Fusrc -FUlib -O2 examples/demo.lpr -oexamples/demo
echo "built: tests/corpus_runner, examples/demo"
