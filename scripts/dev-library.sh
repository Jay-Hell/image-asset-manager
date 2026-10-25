#!/usr/bin/env bash
# Copy the live library to <dest> for a debug build to open with IAM_LIBRARY, then print the
# command that launches one.
#
#   scripts/dev-library.sh <dest>
#
# The source is the live iCloud library unless IAM_SOURCE names another folder (another saved
# location, or a test). library.db is copied with SQLite's backup API, read-only, so a library
# the app has open (its WAL included) copies whole. Nothing is written to the source: the
# database is opened mode=ro (immutable=1 when it has no -wal, so not even a -shm is made), and
# assets/, prompts/, index.json and providers.json are read with cp. Backups/ is not copied.
#
# <dest> must not exist or must be empty, must not overlap the source, and must not be in the
# iCloud container. A sandboxed debug build can only open a folder inside its container
# (~/Library/Containers/Ionic.ImageAssetManager/Data/...); anywhere else is warned about.

set -euo pipefail

die() { echo "dev-library: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: scripts/dev-library.sh <dest>"
DEST_ARG="$1"
case "$DEST_ARG" in /*) ;; *) die "<dest> must be an absolute path: $DEST_ARG" ;; esac

ICLOUD="$HOME/Library/Mobile Documents/iCloud~Ionic~ImageAssetManager"
SRC_ARG="${IAM_SOURCE:-$ICLOUD/Documents}"
CONTAINER="$HOME/Library/Containers/Ionic.ImageAssetManager/Data"

command -v sqlite3 >/dev/null || die "sqlite3 is not on PATH"
[ -d "$SRC_ARG" ] || die "no library folder at $SRC_ARG"
[ -f "$SRC_ARG/library.db" ] || die "no library.db in $SRC_ARG"
case "$SRC_ARG/library.db" in *"'"*) die "the source path may not contain a single quote" ;; esac

# Symlinks resolved; a path that does not exist yet is resolved through its parent.
resolve() {
  if [ -d "$1" ]; then (cd "$1" && pwd -P)
  else
    local parent; parent="$(dirname "$1")"
    [ -d "$parent" ] || die "the folder above <dest> does not exist: $parent"
    echo "$(cd "$parent" && pwd -P)/$(basename "$1")"
  fi
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# True when one path is the other or inside it, by whole components, ignoring case (as APFS does).
overlaps() {
  local a b; a="$(lower "${1%/}")/"; b="$(lower "${2%/}")/"
  case "$a" in "$b"*) return 0 ;; esac
  case "$b" in "$a"*) return 0 ;; esac
  return 1
}

SRC="$(resolve "$SRC_ARG")"
DEST="$(resolve "$DEST_ARG")"
case "$DEST" in *"'"*) die "<dest> may not contain a single quote" ;; esac
overlaps "$DEST" "$SRC" && die "<dest> $DEST overlaps the source $SRC"
if [ -d "$ICLOUD" ]; then
  overlaps "$DEST" "$(resolve "$ICLOUD")" && die "<dest> $DEST is in the iCloud container; it would sync"
fi
if [ -e "$DEST" ]; then
  [ -d "$DEST" ] || die "<dest> exists and is not a folder: $DEST"
  [ -z "$(ls -A "$DEST")" ] || die "<dest> is not empty: $DEST (nothing is overwritten)"
fi

# Read-only, and with no -wal there is nothing to recover, so immutable: no -shm made, no lock.
if [ -e "$SRC/library.db-wal" ]; then
  URI="file:$SRC/library.db?mode=ro"
else
  URI="file:$SRC/library.db?mode=ro&immutable=1"
fi

mkdir -p "$DEST"
sqlite3 "$URI" ".backup '$DEST/library.db'"
CHECK="$(sqlite3 "$DEST/library.db" "PRAGMA integrity_check;")"
[ "$CHECK" = "ok" ] || die "the copy failed its integrity check: $CHECK"

for item in assets prompts index.json providers.json; do
  if [ -e "$SRC/$item" ]; then cp -Rp "$SRC/$item" "$DEST/$item"; fi
done

case "$DEST/" in
  "$CONTAINER"/*) ;;
  *) echo "dev-library: warning: $DEST is outside the app's container; a sandboxed debug build cannot open it." >&2 ;;
esac

APP="${IAM_DEBUG_APP:-<your Debug build>/ImageAssetManager.app}"
echo "Copied $SRC to $DEST"
echo "Launch a debug build on it with:"
printf '  open -n %q --args -IAM_LIBRARY %q\n' "$APP" "$DEST"
