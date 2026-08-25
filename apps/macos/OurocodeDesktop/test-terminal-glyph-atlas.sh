#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-glyph-atlas-fixture.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  -D OUROCODE_GHOSTTY_METAL_SURFACE \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroGlyphAtlas.swift" \
  "$APP_ROOT/Tests/TerminalGlyphAtlasFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

RENDERER="$APP_ROOT/Sources/OurocodeDesktop/OuroTerminalRenderer.swift"
rg -Fq 'private var inFlight = false' "$RENDERER"
rg -Fq 'guard !self.preparing, !self.inFlight, self.pending == nil else { return false }' "$RENDERER"
rg -Fq ': try OuroGlyphAtlas(device: self.device)' "$RENDERER"
rg -Fq 'atlas = pending.atlas' "$RENDERER"

echo "PASS: typography atlas rotation keeps one prepared frame and one GPU frame in flight"
