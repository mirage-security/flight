#!/usr/bin/env bash
#
# Runs the `FlightLeakCheck` harness, which spawns subprocesses through
# `ShellService` and asserts the parent's FD table doesn't grow more than
# a small bound. Catches regressions where Pipe FileHandle read ends
# aren't released after the subprocess exits.
#
# Run locally: `Scripts/leak-check.sh`
# CI invokes this from `.github/workflows/pr.yml`.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift run -c release FlightLeakCheck
