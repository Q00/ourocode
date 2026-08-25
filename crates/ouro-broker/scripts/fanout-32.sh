#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
BENCH_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ouro-broker-fanout32.XXXXXX")
BENCH_SOCKET="$BENCH_TMP/broker.sock"
BROKER_PID=

cleanup() {
    if [ -n "$BROKER_PID" ]; then
        kill "$BROKER_PID" 2>/dev/null || true
        wait "$BROKER_PID" 2>/dev/null || true
    fi
    rm -f "$BENCH_SOCKET"
    rm -f "$BENCH_TMP"/done-*
    rmdir "$BENCH_TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ -z "${BROKER_BINARY+x}" ]; then
    cargo build --manifest-path "$REPOSITORY_ROOT/crates/ouro-broker/Cargo.toml" --release
    BROKER_BINARY="$REPOSITORY_ROOT/target/release/ouro-broker"
elif [ ! -x "$BROKER_BINARY" ]; then
    echo "BROKER_BINARY is not executable: $BROKER_BINARY" >&2
    exit 1
fi

"$BROKER_BINARY" "$BENCH_SOCKET" &
BROKER_PID=$!

attempt=0
while [ ! -S "$BENCH_SOCKET" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 100 ]; then
        echo "broker socket timeout" >&2
        exit 1
    fi
    sleep 0.02
done

echo "fanout_32_canonical_viewport_v1"
echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "os=$(uname -a)"
echo "broker_pid=$BROKER_PID"
echo "binary=$BROKER_BINARY"

python3 - "$BENCH_SOCKET" "$BENCH_TMP" <<'PY'
import json
import os
import socket
import sys
import time

path = sys.argv[1]
state_directory = sys.argv[2]
client = socket.socket(socket.AF_UNIX)
client.connect(path)
reader = client.makefile("rb")
hello = json.loads(reader.readline())
assert hello["version"] == 3
assert hello["build"]
assert set(hello["capabilities"]) == {
    "terminal.recovery.ansi_replay.viewport.v1",
    "terminal.resume.delta.v1",
    "terminal.create.idempotency.v1",
    "terminal.terminate.reaped_ack.v1",
}

def request(request_id, op, **fields):
    payload = {"version": 3, "id": request_id, "op": op, **fields}
    client.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
    while True:
        message = json.loads(reader.readline())
        if message.get("id") == request_id:
            if message.get("type") == "error":
                raise RuntimeError(message)
            return message

terminal_ids = []
for index in range(32):
    done_path = os.path.join(state_directory, "done-" + str(index))
    response = request(
        index + 1,
        "create",
        create_nonce="fanout-32-" + str(index),
        program="/bin/sh",
        args=[
            "-c",
            "/usr/bin/yes x | /usr/bin/head -c 655360; : > \"$1\"; sleep 300",
            "fanout-32",
            done_path,
        ],
        current_directory=None,
        environment={"TERM": "xterm-256color"},
        columns=80,
        rows=24,
    )
    terminal_ids.append(response["terminal"]["id"])

deadline = time.monotonic() + 30
summary = []
while time.monotonic() < deadline:
    summary = request(1000, "list")["terminals"]
    output_complete = all(
        os.path.exists(os.path.join(state_directory, "done-" + str(index)))
        for index in range(32)
    )
    if len(summary) == 32 and output_complete:
        break
    time.sleep(0.05)
else:
    raise RuntimeError("32 terminals did not produce bounded output before timeout")

print("broker_generation=" + str(hello["broker_generation"]))
print("terminal_count=" + str(len(summary)))
print("all_running=" + str(all(item["running"] for item in summary)).lower())
print("minimum_cursor=" + str(min(item["cursor"] for item in summary)))
print("maximum_cursor=" + str(max(item["cursor"] for item in summary)))
client.close()  # Simulated UI-less state; PTYs must remain broker-owned.
PY

IDLE_SETTLE_SECONDS=${IDLE_SETTLE_SECONDS:-10}
echo "idle_settle_seconds=$IDLE_SETTLE_SECONDS"
sleep "$IDLE_SETTLE_SECONDS"
if [ "$(uname -s)" = "Darwin" ]; then
    THREAD_LINES=$(ps -M "$BROKER_PID" | wc -l | tr -d ' ')
    echo "threads=$((THREAD_LINES - 1))"
    ps -o pid=,rss=,vsz=,%cpu= -p "$BROKER_PID" | awk '{print "ps_pid=" $1 " rss_kib=" $2 " vsz_kib=" $3 " cpu_percent=" $4}'
    echo "footprint_begin"
    footprint "$BROKER_PID" 2>&1
    echo "footprint_end"
else
    awk '/^Threads:/{print "threads=" $2} /^VmRSS:/{print "rss_kib=" $2} /^VmSize:/{print "vsz_kib=" $2}' "/proc/$BROKER_PID/status"
fi

python3 - "$BENCH_SOCKET" <<'PY'
import json
import socket
import sys

client = socket.socket(socket.AF_UNIX)
client.connect(sys.argv[1])
reader = client.makefile("rb")
hello = json.loads(reader.readline())
assert hello["version"] == 3
client.sendall(b'{"version":3,"id":1,"op":"list"}\n')
listed = json.loads(reader.readline())
print("ui_less_terminal_count=" + str(len(listed["terminals"])))
print("ui_less_all_running=" + str(all(item["running"] for item in listed["terminals"])).lower())
for request_id, terminal in enumerate(listed["terminals"], start=2):
    payload = {
        "version": 3,
        "id": request_id,
        "op": "terminate",
        "terminal_id": terminal["id"],
        "broker_generation": hello["broker_generation"],
    }
    client.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
    while json.loads(reader.readline()).get("id") != request_id:
        pass
PY
