#!/usr/bin/env bash
# Behavior tests for the Slack bridge fleet-message-log pass
# (bin/fm-slack-bridge.mjs messagesPass, fed by
# bin/fm-fleet-message-log.sh --json): first-start silent baseline, one post
# per new steer and status line, no repost across restarts, oversized split,
# unconfigured key silence, and Slack-failure retry. Every Slack call goes to
# a local fake endpoint; no real Slack network call is made.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-slack-bridge.sh"
TMP_ROOT=$(fm_test_tmproot fm-slack-bridge-messages)

CAPTAIN=UCAPTAIN
ACTION_CH=C0ACTION
STATUS_CH=C0STATUS
MSG_CH=C0MESSAGES
BOT_USER=UBOTID

# Fake Slack endpoint: re-reads its config file on every request, appends one
# JSON line per API call to calls.log, and binds 127.0.0.1 only.
# Config knob beyond the shared shape: "fail_posts" true answers every
# chat.postMessage with "fail_error" (default ratelimited) without recording
# a delivery.
STUB_PIDS=()
cleanup_stubs() {
  local pid
  for pid in "${STUB_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_stubs; fm_test_cleanup' EXIT
trap 'cleanup_stubs; fm_test_cleanup; exit 130' INT
trap 'cleanup_stubs; fm_test_cleanup; exit 143' TERM

make_home() {  # <name> [nomsg] -> home path
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  {
    echo "slack-bot-token=xoxb-test-token"
    echo "slack-app-token=xapp-test-token"
    echo "slack-allow-users=$CAPTAIN"
    echo "slack-action-channel=$ACTION_CH"
    echo "slack-status-channel=$STATUS_CH"
    [ "${2:-}" = "nomsg" ] || echo "slack-messages-channel=$MSG_CH"
  } > "$home/.env"
  printf '%s\n' "$home"
}

fake_slack_start() {  # <dir> -> sets FAKE_PORT, registers the stub pid
  local dir=$1
  mkdir -p "$dir"
  echo '{}' > "$dir/config.json"
  : > "$dir/calls.log"
  cat > "$dir/stub.py" <<PY
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

CONFIG = "$dir/config.json"
LOG = "$dir/calls.log"
TS_COUNTER = [2000]

def load_config():
    with open(CONFIG) as f:
        return json.load(f)

def append_log(entry):
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")

class H(BaseHTTPRequestHandler):
    def reply(self, obj):
        raw = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode()
        params = {k: v[0] for k, v in parse_qs(body).items()}
        method = self.path.split("/")[-1]
        append_log({"method": method, "params": params})
        cfg = load_config()
        if method == "auth.test":
            self.reply({"ok": True, "user_id": "$BOT_USER"})
        elif method == "conversations.history":
            channel = params.get("channel", "")
            oldest = params.get("oldest", "0")
            msgs = cfg.get("channels", {}).get(channel, {}).get("messages", [])
            keep = [dict(m) for m in msgs if m.get("ts", "") > oldest]
            keep.sort(key=lambda m: m.get("ts", ""), reverse=True)
            self.reply({"ok": True, "messages": keep, "has_more": False,
                        "response_metadata": {"next_cursor": ""}})
        elif method == "chat.postMessage":
            if cfg.get("fail_posts"):
                self.reply({"ok": False, "error": cfg.get("fail_error", "ratelimited")})
            else:
                TS_COUNTER[0] += 1
                self.reply({"ok": True, "channel": params.get("channel", ""),
                            "ts": str(TS_COUNTER[0]) + ".000001"})
        elif method in ("reactions.add", "reactions.remove"):
            self.reply({"ok": True})
        elif method == "reactions.get":
            self.reply({"ok": True, "type": "message",
                        "message": {"ts": params.get("timestamp", ""), "reactions": []}})
        else:
            self.reply({"ok": False, "error": "unknown_method_" + method})

    def log_message(self, *args):
        pass

server = HTTPServer(("127.0.0.1", 0), H)
with open("$dir/port", "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
  python3 "$dir/stub.py" >/dev/null 2>&1 &
  STUB_PIDS+=($!)
  local i=0
  while [ ! -s "$dir/port" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$dir/port" ] || fail "fake Slack endpoint never reported its port"
  FAKE_PORT=$(cat "$dir/port")
}
FAKE_PORT=""

bridge_state() {  # <home> -> path of the bridge's private state file
  printf '%s\n' "$1/data/slack-bridge/bridge/state.json"
}

calls_matching() {  # <dir> <method> -> compact params JSON per matching call
  local dir=$1 method=$2
  jq -c --arg m "$method" 'select(.method == $m) | .params' < "$dir/calls.log" 2>/dev/null
}

message_posts() {  # <dir> -> params of posts to the messages channel only
  calls_matching "$1" "chat.postMessage" | grep -F "\"channel\":\"$MSG_CH\"" || true
}

# Run one bridge cycle against the fixture endpoint. The fleet snapshot comes
# from the documented test seam and disk alerts stay quiet (threshold 100).
bridge_once() {  # <home> <port> <snapshot-file> [extra env...]
  local home=$1 port=$2 snap=$3
  shift 3
  env FM_HOME="$home" \
    FM_SLACK_API_URL="http://127.0.0.1:$port/api" \
    FM_SLACK_SNAPSHOT_CMD="cat $snap" \
    FM_SLACK_DISK_PCT=100 \
    "$@" \
    bash "$BRIDGE" run --transport poll --once 2>>"$home/bridge.err"
}

write_steer() {  # <home> <task> <place:pending|handled> <fname> <at> <body>
  local home=$1 task=$2 place=$3 fname=$4 at=$5 body=$6 dir
  dir="$home/state/$task.inbox"
  mkdir -p "$dir/handled"
  if [ "$place" = "handled" ]; then
    dir="$dir/handled"
  fi
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\n%s\n' "$at" "$body" > "$dir/$fname"
}

printf '{}\n' > "$TMP_ROOT/empty-snap.json"

# --------------------------------------------------------------- tests ----

test_unconfigured_key_posts_nothing() {
  local home dir port posts status=0
  home=$(make_home unconfigured nomsg)
  dir="$TMP_ROOT/stub-unconfigured"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  write_steer "$home" task-x pending 001.msg "2026-10-26T10:00:00Z" "do the thing corr=unconf-1"
  printf 'done [at=1792988000]: did the thing corr=unconf-1\n' > "$home/state/task-x.status"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "bridge ran clean"
  posts=$(calls_matching "$dir" "chat.postMessage")
  [ -z "$posts" ] || fail "unconfigured key must post nothing, got: $posts"
  pass "without the key the message pass stays silent"
}

test_first_start_baselines_silently() {
  local home dir port posts base count status=0
  home=$(make_home baseline)
  dir="$TMP_ROOT/stub-baseline"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  write_steer "$home" task-old pending 001.msg "2026-10-26T10:00:00Z" "old steer corr=oldcorr-1"
  write_steer "$home" task-old handled 002.msg "2026-10-26T10:05:00Z" "older steer corr=oldcorr-2"
  printf 'done [at=1792988000]: old report corr=oldcorr-1\nworking [at=1792988100]: old grind\n' \
    > "$home/state/task-old.status"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "bridge ran clean"
  posts=$(message_posts "$dir")
  [ -z "$posts" ] || fail "first start must post nothing old, got: $posts"
  base=$(jq -r '.messagesBaseline' "$(bridge_state "$home")")
  [ "$base" = "true" ] || fail "first start must record the messages baseline"
  count=$(jq -r '.messagesPosted | length' "$(bridge_state "$home")")
  [ "$count" = "4" ] || fail "baseline must record all 4 existing entries, got $count"
  pass "first start baselines silently and posts nothing old"
}

test_new_steer_and_status_post_once() {
  local home dir port posts status=0
  home=$(make_home postonce)
  dir="$TMP_ROOT/stub-postonce"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  write_steer "$home" task-n pending 001.msg "2026-10-26T10:00:00Z" "baseline steer"
  printf 'done [at=1792988000]: baseline report\n' > "$home/state/task-n.status"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "baseline run clean"
  write_steer "$home" task-n handled 002.msg "2026-10-26T11:00:00Z" "tighten the framistat corr=newcorr-9"
  printf 'working [at=1792998000]: grinding on the framistat corr=newcorr-9\n' >> "$home/state/task-n.status"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "second run clean"
  posts=$(message_posts "$dir")
  [ "$(printf '%s\n' "$posts" | grep -c .)" = "2" ] || fail "expected 2 posts, got: $posts"
  assert_contains "$posts" "Firstmate to agent" "steer post must name its direction"
  assert_contains "$posts" "Agent to firstmate" "status post must name its direction"
  assert_contains "$posts" "task-n" "posts must name the agent id"
  assert_contains "$posts" "newcorr-9" "posts must carry the corr id"
  assert_contains "$posts" "steer handled" "steer post must show acknowledgement state"
  assert_contains "$posts" "tighten the framistat" "steer post must carry full text"
  assert_contains "$posts" "grinding on the framistat" "status post must carry full text"
  grep -q "grinding on the framistat" "$home/bridge.err" \
    && fail "bridge log must never carry message bodies"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "third run clean"
  posts=$(message_posts "$dir")
  [ "$(printf '%s\n' "$posts" | grep -c .)" = "2" ] || fail "restart must not repost, got: $posts"
  pass "new steer and status line post once each; restart reposts nothing; bodies stay out of the log"
}

test_oversized_text_splits_with_marker() {
  local home dir port posts body status=0
  home=$(make_home oversized)
  dir="$TMP_ROOT/stub-oversized"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "baseline run clean"
  body=$(yes "framistat line" | head -40 | tr '\n' ' ')
  write_steer "$home" task-big pending 001.msg "2026-10-26T12:00:00Z" "$body"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" FM_SLACK_MESSAGES_LIMIT=150 || status=$?
  expect_code 0 "$status" "oversized run clean"
  posts=$(message_posts "$dir")
  [ "$(printf '%s\n' "$posts" | grep -c .)" -ge 2 ] || fail "oversized text must split, got: $posts"
  assert_contains "$posts" "(part 1/" "split parts must say so in the post"
  assert_contains "$posts" "framistat line" "split parts must keep full text"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" FM_SLACK_MESSAGES_LIMIT=150 || status=$?
  expect_code 0 "$status" "rerun clean"
  [ "$(message_posts "$dir" | grep -c .)" = "$(printf '%s\n' "$posts" | grep -c .)" ] \
    || fail "split posts must not repost on restart"
  pass "oversized text splits into marked parts and posts once"
}

test_slack_failure_retries() {
  local home dir port posts posted status=0
  home=$(make_home retry)
  dir="$TMP_ROOT/stub-retry"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "baseline run clean"
  write_steer "$home" task-r pending 001.msg "2026-10-26T13:00:00Z" "retry the framistat corr=retrycorr-7"
  printf '{"channels": {}, "captain_reactions": [], "fail_posts": true}\n' > "$dir/config.json"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "failing run stays clean"
  posts=$(message_posts "$dir")
  [ "$(printf '%s\n' "$posts" | grep -c .)" = "1" ] || fail "failed post must still attempt once"
  posted=$(jq -r '.messagesPosted | keys[]' "$(bridge_state "$home")" 2>/dev/null || true)
  [ -z "$posted" ] || fail "a failed post must not mark the entry posted, got: $posted"
  printf '{"channels": {}, "captain_reactions": []}\n' > "$dir/config.json"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "recovery run clean"
  posts=$(message_posts "$dir")
  [ "$(printf '%s\n' "$posts" | grep -c 'retry the framistat')" = "2" ] \
    || fail "recovery must deliver once after the one failed attempt, got: $posts"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  [ "$(message_posts "$dir" | grep -c 'retry the framistat')" = "2" ] \
    || fail "delivered entry must not repost"
  pass "a Slack failure retries instead of marking posted; recovery delivers once"
}

test_no_real_slack_network() {
  local hits
  hits=$(grep -h 'slack\.com' "$TMP_ROOT"/stub-*/calls.log 2>/dev/null | grep -c .)
  [ "$hits" = "0" ] || fail "tests must not call real Slack"
  pass "no test run reached real Slack"
}

test_unconfigured_key_posts_nothing
test_first_start_baselines_silently
test_new_steer_and_status_post_once
test_oversized_text_splits_with_marker
test_slack_failure_retries
test_no_real_slack_network
