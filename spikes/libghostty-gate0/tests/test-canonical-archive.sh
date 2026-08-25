#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
CANONICALIZER="$SCRIPT_DIR/../canonicalize-archive.sh"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-canonical-test.XXXXXX")
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

mkdir "$WORK_DIR/a" "$WORK_DIR/b" "$WORK_DIR/reference"
printf '%s\n' 'int alpha(void) { return 1; }' > "$WORK_DIR/a/alpha.c"
printf '%s\n' 'int beta(void) { return 2; }' > "$WORK_DIR/a/beta.c"
cp "$WORK_DIR/a/alpha.c" "$WORK_DIR/a/beta.c" "$WORK_DIR/b/"

(
  cd "$WORK_DIR/a"
  cc -g -c alpha.c beta.c
  xcrun libtool -static alpha.o beta.o -o input.a
)
(
  cd "$WORK_DIR/b"
  cc -g -c alpha.c beta.c
  xcrun libtool -static alpha.o beta.o -o input.a
)

cp "$WORK_DIR/a/alpha.o" "$WORK_DIR/a/beta.o" "$WORK_DIR/reference/"
chmod 0644 "$WORK_DIR/reference/"*.o
xcrun strip -S "$WORK_DIR/reference/"*.o
for MEMBER in alpha.o beta.o; do
  MEMBER_SHA=$(shasum -a 256 "$WORK_DIR/reference/$MEMBER" | awk '{print $1}')
  printf '%s  %s\n' "$MEMBER_SHA" "$MEMBER"
done > "$WORK_DIR/members.sha256"

"$CANONICALIZER" "$WORK_DIR/a/input.a" "$WORK_DIR/a/output.a" \
  "$WORK_DIR/members.sha256" >/dev/null
"$CANONICALIZER" "$WORK_DIR/b/input.a" "$WORK_DIR/b/output.a" \
  "$WORK_DIR/members.sha256" >/dev/null
cmp -s "$WORK_DIR/a/output.a" "$WORK_DIR/b/output.a"

printf '%s\n' 'int gamma(void) { return 3; }' > "$WORK_DIR/a/gamma.c"
(
  cd "$WORK_DIR/a"
  cc -g -c gamma.c
  xcrun libtool -static alpha.o beta.o gamma.o -o unexpected.a
)
if "$CANONICALIZER" "$WORK_DIR/a/unexpected.a" "$WORK_DIR/a/rejected.a" \
    "$WORK_DIR/members.sha256" >/dev/null 2>&1; then
  echo "canonicalizer accepted an unexpected archive member" >&2
  exit 1
fi

printf '%s\n' 'int alpha(void) { return 99; }' > "$WORK_DIR/b/alpha.c"
(
  cd "$WORK_DIR/b"
  cc -g -c alpha.c
  xcrun libtool -static alpha.o beta.o -o tampered.a
)
if "$CANONICALIZER" "$WORK_DIR/b/tampered.a" "$WORK_DIR/b/rejected.a" \
    "$WORK_DIR/members.sha256" >/dev/null 2>&1; then
  echo "canonicalizer accepted a changed member payload" >&2
  exit 1
fi

echo "canonical archive tests passed"
