#!/usr/bin/env bash
# Downgrade check: can the released build still use a library this build has upgraded?
#
#   scripts/downgrade-check/run.sh <old-tag> <library-folder-at-the-old-schema>
#   e.g. scripts/downgrade-check/run.sh v1.1.0 /tmp/iam-copy      (make the copy with scripts/dev-library.sh)
#
# Phase A, this build's Core: opens a copy of the library (migrating it), then writes new-release data.
# Phase B, the old tag's Core: opens it (it must take no backup, so it sees no pending migration),
#   reads as the old app does and writes as the old app and MCP do.
# Phase C, this build's Core: reopens it; this build's data and the old build's writes must both read correctly.
#
# Phase B is written against the old tag's API, in CompatPhaseB-<old-tag>.swift; write a new one when the
# released version changes. Set IAM_DOWNGRADE_PLANT to SQL run between A and B to prove the check can
# fail (for example dropping a column the old build writes).
#
# Never reads the live library: it works on a copy made with SQLite's backup API, and refuses a source
# inside the iCloud container or the app container.
set -euo pipefail

OLD_TAG="${1:?old tag, e.g. v1.1.0}"
SOURCE="${2:?library folder holding library.db at the old schema}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PHASE_B="$HERE/CompatPhaseB-$OLD_TAG.swift"
[ -f "$PHASE_B" ] || { echo "no phase B for $OLD_TAG: write $PHASE_B" >&2; exit 2; }

RESOLVED="$(cd "$SOURCE" && pwd -P)"
case "$RESOLVED" in
  "$HOME/Library/Mobile Documents/"*|"$HOME/Library/Containers/Ionic.ImageAssetManager/Data/Library/Application Support/ImageAssetManager"*)
    echo "refusing a live library location: $RESOLVED (copy it with scripts/dev-library.sh)" >&2; exit 2 ;;
esac
[ -f "$RESOLVED/library.db" ] || { echo "no library.db in $RESOLVED" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/iam-downgrade.XXXXXX")"
OLD_WT="$WORK/old"; FX="$WORK/library"
cleanup() { git -C "$REPO" worktree remove --force "$OLD_WT" 2>/dev/null || true; rm -f "$CORE_TESTS/CompatPhasesTests.swift"; }
CORE_TESTS="$REPO/ImageAssetManager/ImageAssetManager/ImageAssetManagerCore/Tests/ImageAssetManagerCoreTests"
trap cleanup EXIT

mkdir -p "$FX"
sqlite3 "$RESOLVED/library.db" ".backup '$FX/library.db'"
[ -d "$RESOLVED/assets" ] && ln -s "$RESOLVED/assets" "$FX/assets"
git -C "$REPO" worktree add -q --detach "$OLD_WT" "$OLD_TAG"
cp "$HERE/CompatPhasesTests.swift" "$CORE_TESTS/"
cp "$PHASE_B" "$OLD_WT/ImageAssetManager/ImageAssetManager/ImageAssetManagerCore/Tests/ImageAssetManagerCoreTests/CompatPhaseBTests.swift"
export IAM_COMPAT_DIR="$FX"

phase() {   # $1 = repo root, $2 = suite
  local log="$WORK/$2.log" rc=0
  ( cd "$1/ImageAssetManager/ImageAssetManager/ImageAssetManagerCore" && swift test --scratch-path "$WORK/build-$(basename "$1")" --filter "$2" ) >"$log" 2>&1 || rc=$?
  # Exit 0 is not enough: the suite must have run its one test.
  if [ "$rc" -eq 0 ] && grep -q "Test run with 1 test in 1 suite passed" "$log"; then echo "$2: passed"; return 0; fi
  echo "$2: FAILED (log: $log)"; grep -E "Expectation failed|error:|recorded an issue" "$log" | head -5 | cut -c1-250
  return 1
}
migrations() { sqlite3 "$FX/library.db" "SELECT COUNT(*) FROM grdb_migrations"; }

phase "$REPO" CompatPhaseA
AFTER_A="$(migrations)"
[ -n "${IAM_DOWNGRADE_PLANT:-}" ] && sqlite3 "$FX/library.db" "$IAM_DOWNGRADE_PLANT" && echo "planted: $IAM_DOWNGRADE_PLANT"
B=0; phase "$OLD_WT" CompatPhaseB || B=1
[ "$(migrations)" = "$AFTER_A" ] || { echo "the old build changed grdb_migrations"; B=1; }
C=0; phase "$REPO" CompatPhaseC || C=1
if [ "$B" -eq 0 ] && [ "$C" -eq 0 ]; then echo "DOWNGRADE CHECK: OK ($OLD_TAG can use a library this build upgraded)"; rm -rf "$WORK"; else echo "DOWNGRADE CHECK: FAILED"; exit 1; fi
