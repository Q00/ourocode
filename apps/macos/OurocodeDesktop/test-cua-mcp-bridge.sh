#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h:h}"
PROXY="$ROOT/scripts/ourocode-cua-mcp-bridge"
TMP=$(mktemp -d /private/tmp/ourocode-cua-bridge.XXXXXX)
trap 'rm -rf -- "$TMP"' EXIT

cat >"$TMP/fake-cua" <<'PY'
#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    response = {
        "jsonrpc": "2.0",
        "id": message.get("id"),
        "result": {"forwardedMethod": message.get("method")},
    }
    print(json.dumps(response, separators=(",", ":")), flush=True)
PY
chmod 700 "$TMP/fake-cua"

OUTPUT=$(printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}' \
  | HOME="$TMP" "$PROXY" "$TMP/fake-cua")

FIRST=${OUTPUT%%$'\n'*}
SECOND=${OUTPUT#*$'\n'}
[[ "$FIRST" == *'"code":-32601'* && "$FIRST" == *'"id":1'* ]] || {
  print -u2 "FAIL: modern discovery did not receive method-not-found"
  exit 1
}
[[ "$SECOND" == *'"forwardedMethod":"initialize"'* && "$SECOND" == *'"id":2'* ]] || {
  print -u2 "FAIL: legacy initialize was not forwarded byte-for-byte"
  exit 1
}

print "PASS: CUA bridge enables Ouroboros modern-to-legacy fallback without intercepting tool traffic"
