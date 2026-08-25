#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ "${1#/}" = "$1" ]; then
  echo "usage: $0 /absolute/path/to/official-zig-distribution.tar.xz" >&2
  exit 64
fi

ZIG_ARCHIVE=$1
test -f "$ZIG_ARCHIVE"
test "$(uname -s)" = Darwin

case "$(uname -m)" in
  arm64)
    EXPECTED_ARCHIVE_SHA=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
    EXPECTED_DIRECTORY=zig-aarch64-macos-0.16.0
    ;;
  x86_64)
    EXPECTED_ARCHIVE_SHA=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7
    EXPECTED_DIRECTORY=zig-x86_64-macos-0.16.0
    ;;
  *)
    echo "unsupported macOS architecture: $(uname -m)" >&2
    exit 66
    ;;
esac

ACTUAL_ARCHIVE_SHA=$(shasum -a 256 "$ZIG_ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL_ARCHIVE_SHA" != "$EXPECTED_ARCHIVE_SHA" ]; then
  echo "Zig distribution archive digest mismatch" >&2
  exit 65
fi
test "$(zig version)" = 0.16.0

ZIG_EXECUTABLE=$(command -v zig)
ZIG_DIRECTORY=$(CDPATH='' cd -- "$(dirname -- "$ZIG_EXECUTABLE")" && pwd -P)
if [ "$(basename "$ZIG_DIRECTORY")" != "$EXPECTED_DIRECTORY" ]; then
  echo "active Zig is not running from the audited distribution directory" >&2
  exit 65
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-zig-audit.XXXXXX")
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM
tar -xf "$ZIG_ARCHIVE" -C "$WORK_DIR"
if ! diff -qr "$WORK_DIR/$EXPECTED_DIRECTORY" "$ZIG_DIRECTORY" >/dev/null; then
  echo "active Zig distribution differs from the audited archive" >&2
  exit 65
fi
