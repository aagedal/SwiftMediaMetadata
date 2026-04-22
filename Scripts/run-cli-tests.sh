#!/usr/bin/env bash
# Run the CLI black-box test target only.
#
# The CLI tests spawn the built `swift-exif` binary as a subprocess and exercise
# the top-level commands (read/write/strip/copy/diff/stay-open/argfile). They
# are gated behind SWIFT_EXIF_RUN_CLI_TESTS=1 so the regular `swift test` run
# stays fast and focused on the library.
#
# Usage:
#   Scripts/run-cli-tests.sh                  # debug build, run all CLI tests
#   Scripts/run-cli-tests.sh -c release       # release build
#   Scripts/run-cli-tests.sh --filter Smoke   # only the Smoke tests
set -euo pipefail

cd "$(dirname "$0")/.."

export SWIFT_EXIF_RUN_CLI_TESTS=1

# --filter defaults to the CLI target; extra args after `--` are passed through
# to `swift test` (useful for narrowing to a specific class via `--filter`).
filter="SwiftExifCLITests"
extra_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter)
            filter="SwiftExifCLITests.$2"
            shift 2
            ;;
        --)
            shift
            extra_args+=("$@")
            break
            ;;
        *)
            extra_args+=("$1")
            shift
            ;;
    esac
done

# `${arr[@]+"${arr[@]}"}` avoids the `set -u` unbound-array error when
# `extra_args` is empty.
exec swift test --filter "$filter" ${extra_args[@]+"${extra_args[@]}"}
