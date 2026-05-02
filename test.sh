#!/usr/bin/env bash
#
# Runs the full test suite plus the subprocess FD-leak harness.
# CI calls this; run locally with `./test.sh`.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift test"
swift test

echo "==> FlightLeakCheck"
swift run -c release FlightLeakCheck
