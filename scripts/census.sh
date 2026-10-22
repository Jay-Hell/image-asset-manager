#!/usr/bin/env bash
# Census: every check that counts or pins something repo-wide, in one script.
# Run it before calling a pass done and before any full run.
#
#   MIN_TESTS=154 scripts/census.sh
#
# It runs, in order:
#   1. Core package tests            (swift test)
#   2. App tests, macOS              (xcodebuild test)
#   3. App build, iPad simulator     (xcodebuild build)
#   4. node --check on mcp-server/src/*.js
#
# It fails on any failure. It also fails if a test run reports zero tests, or if the
# total reported is lower than MIN_TESTS (so a suite that silently stops running is a
# red, not a green). Exit 0 from a test command is not taken as evidence on its own:
# the count is read from the output.

set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MIN_TESTS="${MIN_TESTS:-0}"
# A generic simulator destination: no named device to go missing when Xcode updates its list.
IPAD="${IPAD_DESTINATION:-generic/platform=iOS Simulator}"
PROJECT="$ROOT/ImageAssetManager/ImageAssetManager.xcodeproj"
CORE="$ROOT/ImageAssetManager/ImageAssetManager/ImageAssetManagerCore"
LOGS="$(mktemp -d)"

FAILED=0
fail() { echo "CENSUS FAIL: $*" >&2; FAILED=1; }
step() { echo; echo "== $* =="; }

# 1. Core package tests. Swift Testing prints "Test run with N tests in M suites passed".
step "Core tests"
swift test --package-path "$CORE" >"$LOGS/core.log" 2>&1
CORE_STATUS=$?
CORE_COUNT="$(grep -Eo 'Test run with [0-9]+ tests?' "$LOGS/core.log" | tail -1 | grep -Eo '[0-9]+')"
CORE_COUNT="${CORE_COUNT:-0}"
echo "core tests reported: $CORE_COUNT (exit $CORE_STATUS)"
[ "$CORE_STATUS" -eq 0 ] || fail "Core tests failed (log: $LOGS/core.log)"
grep -Eq 'Test run with [0-9]+ tests? .* passed' "$LOGS/core.log" || fail "Core test run did not report 'passed' (log: $LOGS/core.log)"
[ "$CORE_COUNT" -gt 0 ] || fail "Core tests reported zero tests"

# 2. App tests on macOS. xcodebuild prints one "Test case '...' passed on ..." line per test.
step "App tests (macOS)"
xcodebuild test -project "$PROJECT" -scheme ImageAssetManager -destination 'platform=macOS' >"$LOGS/app.log" 2>&1
APP_STATUS=$?
APP_COUNT="$(grep -Ec "^Test case '.*' passed on" "$LOGS/app.log")"
APP_FAILED="$(grep -Ec "^Test case '.*' failed on" "$LOGS/app.log")"
echo "app tests passed: $APP_COUNT, failed: $APP_FAILED (exit $APP_STATUS)"
[ "$APP_STATUS" -eq 0 ] || fail "App tests failed (log: $LOGS/app.log)"
[ "$APP_FAILED" -eq 0 ] || fail "App tests reported $APP_FAILED failures"
[ "$APP_COUNT" -gt 0 ] || fail "App tests reported zero tests"

# 3. iPad simulator build.
step "iPad simulator build"
xcodebuild build -project "$PROJECT" -scheme ImageAssetManager -destination "$IPAD" >"$LOGS/ipad.log" 2>&1
IPAD_STATUS=$?
echo "iPad build exit $IPAD_STATUS"
[ "$IPAD_STATUS" -eq 0 ] || fail "iPad build failed (log: $LOGS/ipad.log)"
grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOGS/ipad.log" || fail "iPad build did not report BUILD SUCCEEDED (log: $LOGS/ipad.log)"

# 4. MCP server syntax.
step "node --check"
NODE_FILES=0
for f in "$ROOT"/mcp-server/src/*.js; do
  [ -e "$f" ] || continue
  NODE_FILES=$((NODE_FILES + 1))
  node --check "$f" || fail "node --check failed: $f"
done
[ "$NODE_FILES" -gt 0 ] || fail "no mcp-server/src/*.js files found to check"
echo "checked $NODE_FILES files"

# Totals.
TOTAL=$((CORE_COUNT + APP_COUNT))
step "Census"
echo "tests: core=$CORE_COUNT app=$APP_COUNT total=$TOTAL (MIN_TESTS=$MIN_TESTS)"
if [ "$TOTAL" -le 0 ]; then
  fail "zero tests reported"
elif [ "$TOTAL" -lt "$MIN_TESTS" ]; then
  fail "total $TOTAL is lower than MIN_TESTS $MIN_TESTS"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "CENSUS: FAILED (logs in $LOGS)" >&2
  exit 1
fi
echo "CENSUS: OK ($TOTAL tests)"
