#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <static-archive> [expected-minimum]" >&2
  exit 64
fi

ARCHIVE_PATH="${1:A}"
EXPECTED_MINIMUM="${2:-13.0}"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Static archive does not exist: $ARCHIVE_PATH" >&2
  exit 66
fi

WORK_DIR=$(mktemp -d /private/tmp/ourocode-archive-minimum.XXXXXX)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cd "$WORK_DIR"
ar -x "$ARCHIVE_PATH"

OBJECTS=("$WORK_DIR"/*.o(N))
if (( ${#OBJECTS[@]} == 0 )); then
  echo "Static archive contains no object members: $ARCHIVE_PATH" >&2
  exit 65
fi

for OBJECT_PATH in "${OBJECTS[@]}"; do
  BUILD_INFO=$(vtool -show-build "$OBJECT_PATH" 2>/dev/null || true)
  MEMBER_MINIMUM=$(print -r -- "$BUILD_INFO" | awk '$1 == "minos" { print $2 }')
  if [[ "$MEMBER_MINIMUM" != "$EXPECTED_MINIMUM" ]]; then
    echo "Archive member does not target macOS $EXPECTED_MINIMUM: ${OBJECT_PATH:t}" >&2
    if [[ -z "$MEMBER_MINIMUM" ]]; then
      echo "No LC_BUILD_VERSION minimum was found" >&2
    else
      echo "Found minimum: $MEMBER_MINIMUM" >&2
    fi
    exit 65
  fi
done

echo "PASS: ${#OBJECTS[@]} archive members target macOS $EXPECTED_MINIMUM"
