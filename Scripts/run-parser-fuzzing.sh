#!/bin/sh

set -eu

# Reproducible defaults; override either variable for a longer run or to replay
# a failing seed printed by CI/local XCTest output.
: "${SWIFT_METADATA_FUZZ_ITERATIONS:=50000}"
: "${SWIFT_METADATA_FUZZ_SEED:=0x53574946544D4554}"
export SWIFT_METADATA_FUZZ_ITERATIONS SWIFT_METADATA_FUZZ_SEED

echo "Parser property run: iterations=$SWIFT_METADATA_FUZZ_ITERATIONS seed=$SWIFT_METADATA_FUZZ_SEED"
swift test --filter ParserHardeningPropertyTests
