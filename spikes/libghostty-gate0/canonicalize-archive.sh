#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 /absolute/input.a /absolute/output.a /absolute/member-manifest" >&2
  exit 64
fi

INPUT_ARCHIVE=$1
OUTPUT_ARCHIVE=$2
MEMBER_MANIFEST=$3

case "$INPUT_ARCHIVE:$OUTPUT_ARCHIVE:$MEMBER_MANIFEST" in
  /*:/*:/*) ;;
  *)
    echo "archive and manifest paths must be absolute" >&2
    exit 64
    ;;
esac
if [ "$INPUT_ARCHIVE" = "$OUTPUT_ARCHIVE" ]; then
  echo "input and output archives must be distinct" >&2
  exit 64
fi
test -f "$INPUT_ARCHIVE"
test -f "$MEMBER_MANIFEST"
test "$(uname -s)" = Darwin

AR_TOOL=$(xcrun --find ar)
STRIP_TOOL=$(xcrun --find strip)
LIBTOOL_TOOL=$(xcrun --find libtool)
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-ghostty-canonical.XXXXXX")
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

EXPECTED_NAMES="$WORK_DIR/expected-members.txt"
ACTUAL_NAMES="$WORK_DIR/actual-members.txt"
CANONICAL_ARCHIVE="$WORK_DIR/libghostty-vt.a"

awk '
  NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ || $2 !~ /^[A-Za-z0-9_.+-]+[.]o$/ { exit 1 }
  { print $2 }
' "$MEMBER_MANIFEST" > "$EXPECTED_NAMES" || {
  echo "invalid canonical member manifest" >&2
  exit 65
}
test -s "$EXPECTED_NAMES"
if [ "$(sort "$EXPECTED_NAMES" | uniq -d | wc -l | tr -d ' ')" -ne 0 ]; then
  echo "canonical member manifest contains duplicate names" >&2
  exit 65
fi

"$AR_TOOL" -t "$INPUT_ARCHIVE" \
  | sed '/^__[.]SYMDEF\( SORTED\)\{0,1\}$/d' > "$ACTUAL_NAMES"
if ! cmp -s "$EXPECTED_NAMES" "$ACTUAL_NAMES"; then
  echo "archive member set or order does not match the audited manifest" >&2
  diff -u "$EXPECTED_NAMES" "$ACTUAL_NAMES" >&2 || true
  exit 65
fi

(
  cd "$WORK_DIR"
  "$AR_TOOL" -x "$INPUT_ARCHIVE"
)

while read -r EXPECTED_SHA MEMBER_NAME; do
  MEMBER_PATH="$WORK_DIR/$MEMBER_NAME"
  test -f "$MEMBER_PATH"
  chmod 0644 "$MEMBER_PATH"
  "$STRIP_TOOL" -S "$MEMBER_PATH"
  ACTUAL_SHA=$(shasum -a 256 "$MEMBER_PATH" | awk '{print $1}')
  if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "canonical member digest mismatch: $MEMBER_NAME" >&2
    echo "expected $EXPECTED_SHA" >&2
    echo "actual   $ACTUAL_SHA" >&2
    exit 65
  fi
done < "$MEMBER_MANIFEST"

(
  cd "$WORK_DIR"
  "$LIBTOOL_TOOL" -static -D -filelist "$EXPECTED_NAMES" -o "$CANONICAL_ARCHIVE"
)
chmod 0644 "$CANONICAL_ARCHIVE"
"$AR_TOOL" -t "$CANONICAL_ARCHIVE" \
  | sed '/^__[.]SYMDEF\( SORTED\)\{0,1\}$/d' > "$ACTUAL_NAMES"
if ! cmp -s "$EXPECTED_NAMES" "$ACTUAL_NAMES"; then
  echo "canonical archive member set or order changed while rebuilding" >&2
  exit 65
fi

mkdir -p "$(dirname "$OUTPUT_ARCHIVE")"
mv "$CANONICAL_ARCHIVE" "$OUTPUT_ARCHIVE"
shasum -a 256 "$OUTPUT_ARCHIVE"
