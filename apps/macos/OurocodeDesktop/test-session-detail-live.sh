#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
DATABASE_PATH="${OUROBOROS_DATABASE_PATH:-$HOME/.ouroboros/data/ouroboros.db}"
ENDPOINT="${OUROBOROS_MCP_ENDPOINT:-http://127.0.0.1:8976/mcp}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-session-detail-live.XXXXXX")
RESPONSE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-session-detail-responses.XXXXXX")
AUTH_TOKEN="${OUROBOROS_MCP_BEARER_TOKEN:-}"
if [[ -z "$AUTH_TOKEN" && "$ENDPOINT" == "http://127.0.0.1:8976/mcp" ]]; then
  MANAGED_LABELS=(
    com.ourolabs.ourocode.ouroboros-mcp.dev.v0-51-6.runtime-v4
    com.ourolabs.ourocode.ouroboros-mcp.dev.v0-51-6.auth-v3
  )
  for MANAGED_LABEL in "${MANAGED_LABELS[@]}"; do
    MANAGED_PLIST="$HOME/Library/LaunchAgents/$MANAGED_LABEL.plist"
    if [[ -f "$MANAGED_PLIST" ]]; then
      AUTH_TOKEN="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:OUROBOROS_MCP_AUTH_TOKEN' "$MANAGED_PLIST" 2>/dev/null || true)"
      [[ -n "$AUTH_TOKEN" ]] && break
    fi
  done
fi
if [[ -n "$AUTH_TOKEN" && ! "$AUTH_TOKEN" =~ '^[0-9a-f]{64}$' ]]; then
  echo "Invalid managed MCP bearer token format" >&2
  exit 65
fi

curl_mcp() {
  if [[ -n "$AUTH_TOKEN" ]]; then
    # Feed the header through stdin so the credential never appears in curl's
    # argv or diagnostic output.
    printf 'header = "Authorization: Bearer %s"\n' "$AUTH_TOKEN" | curl --config - "$@"
  else
    curl "$@"
  fi
}

IFS='|' read -r SESSION_ID EXECUTION_ID <<< "$(
  sqlite3 -readonly -separator '|' "$DATABASE_PATH" \
    "SELECT aggregate_id, json_extract(payload, '$.execution_id')
     FROM events
     WHERE event_type = 'orchestrator.session.started'
     ORDER BY timestamp DESC, id DESC
     LIMIT 1;"
)"
if [[ -z "$SESSION_ID" || -z "$EXECUTION_ID" ]]; then
  echo "No persisted Ouroboros session is available for the live probe" >&2
  exit 66
fi

EVENT_TYPES=(
  orchestrator.session.started
  execution.ac.attempt.dispatched
  execution.ac.completed
  execution.terminal
  orchestrator.session.completed
  orchestrator.session.failed
)
PIDS=()
for EVENT_TYPE in "${EVENT_TYPES[@]}"; do
  SAFE_NAME="${EVENT_TYPE//./_}"
  REQUEST=$(printf \
    '{"jsonrpc":"2.0","id":992,"method":"tools/call","params":{"name":"ouroboros_query_events","arguments":{"session_id":"%s","event_type":"%s","limit":24,"offset":0}}}' \
    "$SESSION_ID" "$EVENT_TYPE")
  (
    curl_mcp --max-time 30 -fsS \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H 'MCP-Protocol-Version: 2025-06-18' \
      --data "$REQUEST" "$ENDPOINT" > "$RESPONSE_DIR/$SAFE_NAME.sse"
    sed -n 's/^data: //p' "$RESPONSE_DIR/$SAFE_NAME.sse" > "$RESPONSE_DIR/$SAFE_NAME.json"
  ) &
  PIDS+=($!)
done
for PID in "${PIDS[@]}"; do
  wait "$PID"
done

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosRunProjection.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionDetailProjection.swift" \
  "$APP_ROOT/Tests/OuroborosSessionDetailLiveProbe.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY" "$RESPONSE_DIR" "$SESSION_ID" "$EXECUTION_ID"
TOTAL_BYTES=$(find "$RESPONSE_DIR" -name '*.json' -exec wc -c {} + | awk 'END {print $1}')
echo "Live detail JSON bytes: $TOTAL_BYTES"
