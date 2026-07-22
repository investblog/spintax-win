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
fpc -Mdelphi -Fusrc -Futests -FUlib -O2 tests/local_tests.dpr -otests/local_tests
# Second build with overflow and range checks ON (-Co -Cr), into its own unit dir so it
# cannot poison the optimised one. This reproduces Delphi's Debug configuration, which is
# how EIntOverflow in the mulberry32 mixer reached a released tree: FPC's default build
# wraps silently, Delphi's Debug build raises. Cheap to run, and it turns a
# Delphi-only bug class into one FPC can catch.
mkdir -p lib/checked
fpc -Mdelphi -Co -Cr -Fusrc -Futests -FUlib/checked tests/local_tests.dpr -otests/local_tests_checked
fpc -Mdelphi -Fusrc -FUlib -O2 examples/demo.lpr -oexamples/demo
echo "built: tests/corpus_runner, tests/local_tests(+checked), examples/demo"
