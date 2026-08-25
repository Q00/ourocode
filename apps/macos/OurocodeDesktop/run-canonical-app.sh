#!/bin/zsh
set -euo pipefail

# This is the supported development entry point. It never asks LaunchServices
# to resolve an application by display name: the absolute bundle path and the
# source-bound manifest are both checked first. A stale QA copy or an old
# `open -a Ourocode` registration cannot masquerade as the current build.

APP_ROOT="${0:A:h}"
BUILD_MANIFEST_TOOL="$APP_ROOT/canonical-build-manifest.sh"
CANONICAL_APP="${OUROCODE_CANONICAL_APP:-$APP_ROOT/.build/Ourocode.app}"
EXPECTED_PROFILE="${OUROCODE_CANONICAL_PROFILE:-development}"
REBUILD_IF_STALE="${OUROCODE_REBUILD_IF_STALE:-0}"

usage() {
  cat >&2 <<'EOF'
Usage: run-canonical-app.sh [--verify] [--rebuild] [--print-path] [--new-instance] [-- app-args...]

Environment:
  OUROCODE_CANONICAL_APP        absolute app bundle (default: .build/Ourocode.app)
  OUROCODE_CANONICAL_PROFILE    release or development (default: development)
  OUROCODE_REBUILD_IF_STALE     1 to run build-app.sh when the manifest is stale
EOF
  exit 64
}

[[ "$CANONICAL_APP" == /*.app ]] || {
  print -u2 "OUROCODE_CANONICAL_APP must be an absolute .app path"
  exit 64
}
[[ "$EXPECTED_PROFILE" == release || "$EXPECTED_PROFILE" == development ]] || {
  print -u2 "OUROCODE_CANONICAL_PROFILE must be release or development"
  exit 64
}
[[ "$REBUILD_IF_STALE" == 0 || "$REBUILD_IF_STALE" == 1 ]] || {
  print -u2 "OUROCODE_REBUILD_IF_STALE must be 0 or 1"
  exit 64
}

VERIFY_ONLY=0
PRINT_PATH=0
REBUILD=0
NEW_INSTANCE=0
APP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) VERIFY_ONLY=1; shift ;;
    --rebuild) REBUILD=1; shift ;;
    --print-path) PRINT_PATH=1; shift ;;
    --new-instance) NEW_INSTANCE=1; shift ;;
    --) shift; APP_ARGS=("$@"); break ;;
    -*) usage ;;
    *) APP_ARGS=("$@"); break ;;
  esac
done

verify_current() {
  "$BUILD_MANIFEST_TOOL" verify --app "$CANONICAL_APP" \
    --expected-profile "$EXPECTED_PROFILE" --require-current-source
}

set +e
verify_current
verify_status=$?
set -e
if (( verify_status != 0 )); then
  if (( REBUILD == 1 || REBUILD_IF_STALE == 1 )) \
      && [[ "$EXPECTED_PROFILE" == development ]]; then
    print "Canonical app is stale or missing; rebuilding from the current source tree" >&2
    "$APP_ROOT/build-app.sh"
    verify_current
  else
    print -u2 "Canonical app is not a verified current build (status $verify_status)."
    print -u2 "Run: OUROCODE_REBUILD_IF_STALE=1 $0"
    exit "$verify_status"
  fi
fi

if (( PRINT_PATH == 1 )); then
  print -r -- "$CANONICAL_APP"
fi
(( VERIFY_ONLY == 1 || PRINT_PATH == 1 )) && exit 0

# Use the exact path and activate its existing instance by default. A second
# process is an explicit QA/debug choice so ordinary launches cannot recreate
# the historical process zoo.
OPEN_FLAGS=()
(( NEW_INSTANCE == 1 )) && OPEN_FLAGS=(-n)
if (( ${#APP_ARGS[@]} > 0 )); then
  exec open "${OPEN_FLAGS[@]}" "$CANONICAL_APP" --args "${APP_ARGS[@]}"
else
  exec open "${OPEN_FLAGS[@]}" "$CANONICAL_APP"
fi
