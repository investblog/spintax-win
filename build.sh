#!/bin/sh
# Build the conformance runner and the demo. Requires Free Pascal (fpc) 3.2.2+.
set -e
mkdir -p lib
fpc -Mdelphi -Fusrc -FUlib -O2 tests/corpus_runner.lpr -otests/corpus_runner
fpc -Mdelphi -Fusrc -FUlib -O2 examples/demo.lpr -oexamples/demo
echo "built: tests/corpus_runner, examples/demo"
