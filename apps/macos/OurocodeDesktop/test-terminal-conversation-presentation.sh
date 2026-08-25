#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-conversation-fixture.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalConversationPresentation.swift" \
  "$APP_ROOT/Tests/TerminalConversationPresentationFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

SHADER="$APP_ROOT/Sources/OurocodeDesktop/Resources/OuroTerminalShaders.metal"
for declaration in \
  'semantic_prompt_row = 1u << 7' \
  'semantic_input = 1u << 8' \
  'semantic_prompt = 1u << 9' \
  'semantic_prompt_start_row = 1u << 10'
do
  grep -Fq "$declaration" "$SHADER" || {
    print -u2 "FAIL: Metal conversation flag contract drifted: $declaration"
    exit 1
  }
done

grep -Fq 'must not recolor terminal rows' "$SHADER" || {
  print -u2 "FAIL: unified terminal palette contract was removed"
  exit 1
}
if grep -Fq 'background = uniforms.semantic_turn_background' "$SHADER"; then
  print -u2 "FAIL: OSC 133 metadata recolors terminal rows"
  exit 1
fi
if grep -Fq 'foreground = mix(background, foreground' "$SHADER"; then
  print -u2 "FAIL: OSC 133 metadata dims prompt text"
  exit 1
fi
