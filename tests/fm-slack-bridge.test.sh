#!/usr/bin/env bash
# Behavior tests for the Slack bridge (bin/fm-slack-bridge.sh):
# allow-list rejection, idempotent inbound notes, threaded reply delivery,
# per-class channel routing, record-driven reaction transitions, and the rule
# that a captain reaction can never approve anything. Every Slack call goes to
# a local fake endpoint; no real Slack network call is made.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-slack-bridge.sh"
INBOX="$ROOT/bin/fm-inbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-slack-bridge)

CAPTAIN=UCAPTAIN
INTRUDER=UINTRUDER
ACTION_CH=C0ACTION
STATUS_CH=C0STATUS
BOT_USER=UBOTID

# Fake Slack endpoint: one python stub per scenario group. It re-reads its
# config file on every request, so a test reshapes history and captain
# reactions between bridge runs, and appends one JSON line per API call to
# calls.log for assertions. It binds 127.0.0.1 only.
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

make_home() {  # <name> -> home path
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  cat > "$home/.env" <<ENV
slack-bot-token=xoxb-test-token
slack-app-token=xapp-test-token
slack-allow-users=$CAPTAIN
slack-action-channel=$ACTION_CH
slack-status-channel=$STATUS_CH
ENV
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
            for f in cfg.get("post_fails", []):
                if f.get("thread_ts", "") == params.get("thread_ts", ""):
                    self.reply({"ok": False, "error": f.get("error", "channel_not_found")})
                    break
            else:
                TS_COUNTER[0] += 1
                self.reply({"ok": True, "channel": params.get("channel", ""),
                            "ts": str(TS_COUNTER[0]) + ".000001"})
        elif method in ("reactions.add", "reactions.remove"):
            self.reply({"ok": True})
        elif method == "reactions.get":
            channel = params.get("channel", "")
            ts = params.get("timestamp", "")
            found = []
            for r in cfg.get("captain_reactions", []):
                if r.get("channel") == channel and r.get("ts") == ts:
                    found.append({"name": r["name"], "users": r.get("users", []),
                                  "count": len(r.get("users", []))})
            self.reply({"ok": True, "type": "message",
                        "message": {"ts": ts, "reactions": found}})
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

inbox_notes() {  # <home> -> note ids, one per line
  FM_HOME="$1" bash "$INBOX" receipts --all-pending --all-handled \
    | jq -r '([.pending[].id] + [.handled[].id])[]' 2>/dev/null
}

receipt_field() {  # <home> <jq-path-expr on the combined receipts entries>
  FM_HOME="$1" bash "$INBOX" receipts --all-pending --all-handled \
    | jq -r "$2"
}

# Run one bridge cycle against the fixture endpoint. FM_SLACK_API_URL points
# at the stub; the fleet snapshot comes through the documented test seam.
bridge_once() {  # <home> <port> <snapshot-file-or-{}> [extra env]
  local home=$1 port=$2 snap=$3
  shift 3
  env FM_HOME="$home" \
    FM_SLACK_API_URL="http://127.0.0.1:$port/api" \
    FM_SLACK_SNAPSHOT_CMD="cat $snap" \
    "$@" \
    bash "$BRIDGE" run --transport poll --once 2>>"$home/bridge.err"
}

# --------------------------------------------------------------- tests ----

test_wrapper_refuses_without_config() {
  local home out status=0
  home=$(make_home no-config)
  rm -f "$home/.env"
  out=$(FM_HOME="$home" bash "$BRIDGE" run --transport poll --once 2>&1) || status=$?
  expect_code 1 "$status" "wrapper refused without config"
  assert_contains "$out" ".env" "refusal must name the .env path to write"
  pass "wrapper refuses to start without its .env keys"
}

test_allowlist_rejection_and_idempotent_inbound() {
  local home dir port notes rid body status=0 posts
  home=$(make_home inbound)
  dir="$TMP_ROOT/stub-inbound"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  cat > "$dir/config.json" <<JSON
{"channels": {"$ACTION_CH": {"messages": [
  {"ts": "100.000100", "user": "$CAPTAIN", "text": "hello from slack"},
  {"ts": "100.000200", "user": "$INTRUDER", "text": "intruder message"}
]}}, "captain_reactions": []}
JSON
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "bridge ran clean"
  notes=$(inbox_notes "$home")
  [ "$(printf '%s\n' "$notes" | grep -c .)" = "1" ] || fail "expected exactly one note, got: $notes"
  rid=$(receipt_field "$home" '([.pending[], .handled[]] | map(.request_id // empty) | .[0]) // ""')
  assert_contains "$rid" "$ACTION_CH:100.000100" "note request id must be channel:ts"
  body=$(receipt_field "$home" '([.pending[], .handled[]] | map(.body // empty) | .[0]) // ""')
  assert_contains "$body" "hello from slack" "note body must be the captain message"
  posts=$(calls_matching "$dir" "chat.postMessage")
  [ -z "$posts" ] || fail "inbound must not post anything to Slack yet"
  # Simulate a Slack redelivery after bridge-state loss: clear the channel
  # cursor and re-read the same history. The fm-inbox request id must replay.
  jq 'del(.channelCursor)' "$(bridge_state "$home")" > "$home/s.tmp" \
    && mv "$home/s.tmp" "$(bridge_state "$home")"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "second bridge run clean"
  notes=$(inbox_notes "$home")
  [ "$(printf '%s\n' "$notes" | grep -c .)" = "1" ] || fail "redelivery must replay, not duplicate"
  pass "allow-list drops other users; the same Slack message replays one note"
}

test_threaded_reply_delivery() {
  local home dir port note_id foreign_id threads status=0
  home=$(make_home reply)
  dir="$TMP_ROOT/stub-reply"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  cat > "$dir/config.json" <<JSON
{"channels": {"$ACTION_CH": {"messages": [
  {"ts": "300.000100", "user": "$CAPTAIN", "text": "please do the thing"}
]}}, "captain_reactions": []}
JSON
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  note_id=$(inbox_notes "$home" | head -1)
  [ -n "$note_id" ] || fail "fixture note missing"
  # Foreign notes (no Slack request id) must never be delivered to Slack.
  FM_HOME="$home" bash "$INBOX" note "unrelated human note" >/dev/null 2>&1 || true
  foreign_id=$(inbox_notes "$home" | tail -1)
  FM_HOME="$home" bash "$INBOX" reply "$note_id" "the answer body" >/dev/null 2>&1 \
    || fail "fixture reply failed"
  FM_HOME="$home" bash "$INBOX" reply "$foreign_id" "must not reach slack" >/dev/null 2>&1 || true
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  threads=$(calls_matching "$dir" "chat.postMessage")
  assert_contains "$threads" "{\"channel\":\"$ACTION_CH\",\"thread_ts\":\"300.000100\",\"text\":\"the answer body\"}" \
    "the reply must land in the original message thread"
  [ "$(printf '%s\n' "$threads" | grep -c 'must not reach slack')" = "0" ] \
    || fail "a reply to a non-Slack note must not be posted"
  pass "firstmate replies post into the original Slack thread; foreign notes stay local"
}

test_poisoned_reply_skips_ahead() {
  local home dir port first_id second_id posts dead status=0
  home=$(make_home poison-reply)
  dir="$TMP_ROOT/stub-poison-reply"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  cat > "$dir/config.json" <<JSON
{"channels": {"$ACTION_CH": {"messages": [
  {"ts": "400.000100", "user": "$CAPTAIN", "text": "first task"},
  {"ts": "400.000200", "user": "$CAPTAIN", "text": "second task"}
]}}, "captain_reactions": []}
JSON
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "bridge ran clean"
  first_id=$(FM_HOME="$home" bash "$INBOX" receipts --all-pending --all-handled \
    | jq -r --arg rid "$ACTION_CH:400.000100" '[.pending[], .handled[]] | map(select(.request_id == $rid)) | .[0].id // ""')
  second_id=$(FM_HOME="$home" bash "$INBOX" receipts --all-pending --all-handled \
    | jq -r --arg rid "$ACTION_CH:400.000200" '[.pending[], .handled[]] | map(select(.request_id == $rid)) | .[0].id // ""')
  [ -n "$first_id" ] && [ -n "$second_id" ] || fail "fixture notes missing"
  FM_HOME="$home" bash "$INBOX" reply "$first_id" "first answer" >/dev/null 2>&1 \
    || fail "fixture reply 1 failed"
  FM_HOME="$home" bash "$INBOX" reply "$second_id" "second answer" >/dev/null 2>&1 \
    || fail "fixture reply 2 failed"
  cat > "$dir/config.json" <<JSON
{"channels": {"$ACTION_CH": {"messages": [
  {"ts": "400.000100", "user": "$CAPTAIN", "text": "first task"},
  {"ts": "400.000200", "user": "$CAPTAIN", "text": "second task"}
]}}, "captain_reactions": [],
 "post_fails": [{"thread_ts": "400.000100", "error": "channel_not_found"}]}
JSON
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "bridge ran clean with a poisoned head reply"
  posts=$(calls_matching "$dir" "chat.postMessage")
  assert_contains "$posts" '"thread_ts":"400.000200","text":"second answer"' \
    "a later reply must still deliver past a permanently failed head reply"
  dead=$(jq -r --arg id "$first_id" '.deadReplies[$id] // ""' "$(bridge_state "$home")")
  assert_contains "$dead" "channel_not_found" "the poisoned reply must be recorded with its error"
  [ "$(grep -c 'failed permanently' "$home/bridge.err")" = "1" ] \
    || fail "the poisoned reply must be logged once"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  expect_code 0 "$status" "second bridge run clean"
  posts=$(calls_matching "$dir" "chat.postMessage")
  [ "$(printf '%s\n' "$posts" | grep -c 'second answer')" = "1" ] \
    || fail "a delivered reply must not repost and the poisoned one must not retry"
  pass "a permanently failed reply is recorded and skipped; later replies flow"
}

test_alert_channel_routing_and_pending_marker() {
  local home dir port posts bells status=0
  home=$(make_home routing)
  dir="$TMP_ROOT/stub-routing"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  cat > "$TMP_ROOT/snap-routing.json" <<JSON
{"in_flight": [],
 "decisions_open": [{"id": "task-dec", "key": "task-dec", "verb": "captain-hold",
                     "summary": "pick a database", "owner": "(main)"}],
 "recorded_prs": [{"id": "task-pr", "url": "https://github.com/acme/widget/pull/42"}],
 "unhealthy_endpoints": [{"id": "task-stuck", "target": "tmux:lane7", "exists": false, "agent": "dead"}]}
JSON
  bridge_once "$home" "$port" "$TMP_ROOT/snap-routing.json" || status=$?
  expect_code 0 "$status" "bridge ran clean"
  posts=$(calls_matching "$dir" "chat.postMessage")
  assert_contains "$posts" '{"channel":"'"$ACTION_CH"'","text":"Decision needed: pick a database (task task-dec)"}' \
    "a captain decision must alert the action channel"
  assert_contains "$posts" '{"channel":"'"$ACTION_CH"'","text":"PR ready for review: https://github.com/acme/widget/pull/42 (task task-pr)"}' \
    "a recorded PR must alert the action channel with its full URL"
  assert_contains "$posts" '{"channel":"'"$STATUS_CH"'","text":"Worker stopped responding: task-stuck (tmux:lane7)"}' \
    "an unhealthy endpoint must alert the status channel"
  bells=$(calls_matching "$dir" "reactions.add")
  [ "$(printf '%s\n' "$bells" | grep -c '"name":"bell"')" -ge 3 ] \
    || fail "every fresh alert must carry the pending marker"
  pass "alert classes route to their configured channels with the pending marker"
}

test_reaction_resolution_transition() {
  local home dir port adds removes state status=0
  home=$(make_home resolve)
  dir="$TMP_ROOT/stub-resolve"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  cat > "$TMP_ROOT/snap-open.json" <<'JSON'
{"in_flight": [], "decisions_open": [{"id": "task-a", "key": "task-a",
  "verb": "captain-hold", "summary": "choose", "owner": "(main)"}],
 "recorded_prs": [], "unhealthy_endpoints": []}
JSON
  cat > "$TMP_ROOT/snap-closed.json" <<'JSON'
{"in_flight": [], "decisions_open": [], "recorded_prs": [], "unhealthy_endpoints": []}
JSON
  bridge_once "$home" "$port" "$TMP_ROOT/snap-open.json" || status=$?
  bridge_once "$home" "$port" "$TMP_ROOT/snap-closed.json" || status=$?
  adds=$(calls_matching "$dir" "reactions.add")
  removes=$(calls_matching "$dir" "reactions.remove")
  assert_contains "$adds" '"name":"white_check_mark"' "resolution must add the done marker"
  assert_contains "$removes" '"name":"bell"' "resolution must remove the pending marker"
  state=$(jq -r '.alerts["decision:task-a"].done' "$(bridge_state "$home")")
  [ "$state" = "true" ] || fail "resolved decision must be done in the bridge record"
  pass "reaction transitions follow the durable records: bell to check when resolved"
}

test_unattended_escalation_and_captain_ack() {
  local home dir port adds notices state sfile ts ch status=0
  home=$(make_home unattended)
  dir="$TMP_ROOT/stub-unattended"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  cat > "$TMP_ROOT/snap-unatt.json" <<'JSON'
{"in_flight": [], "decisions_open": [{"id": "task-b", "key": "task-b",
  "verb": "captain-hold", "summary": "waiting", "owner": "(main)"}],
 "recorded_prs": [], "unhealthy_endpoints": []}
JSON
  bridge_once "$home" "$port" "$TMP_ROOT/snap-unatt.json" \
    FM_SLACK_UNATTENDED_SECS=0 FM_SLACK_REPEAT_MAX=1 || status=$?
  # Age the alert past the unattended threshold and re-evaluate.
  sfile="$(bridge_state "$home")"
  jq '.alerts["decision:task-b"].postedEpoch -= 10000' "$sfile" > "$home/s.tmp" \
    && mv "$home/s.tmp" "$sfile"
  bridge_once "$home" "$port" "$TMP_ROOT/snap-unatt.json" \
    FM_SLACK_UNATTENDED_SECS=0 FM_SLACK_REPEAT_MAX=1 || status=$?
  adds=$(calls_matching "$dir" "reactions.add")
  assert_contains "$adds" '"name":"alarm_clock"' "an aged alert must carry the unattended marker"
  notices=$(calls_matching "$dir" "chat.postMessage")
  assert_contains "$notices" '"text":"Still unattended' "an aged alert must post a repeat notice"
  # Cap: a further cycle adds no second notice.
  bridge_once "$home" "$port" "$TMP_ROOT/snap-unatt.json" \
    FM_SLACK_UNATTENDED_SECS=0 FM_SLACK_REPEAT_MAX=1 || status=$?
  notices=$(calls_matching "$dir" "chat.postMessage")
  [ "$(printf '%s\n' "$notices" | grep -c 'Still unattended')" = "1" ] \
    || fail "repeat notices must be capped at FM_SLACK_REPEAT_MAX"
  # A captain white_check_mark reaction approves nothing.
  ts=$(jq -r '.alerts["decision:task-b"].ts' "$sfile")
  ch=$(jq -r '.alerts["decision:task-b"].channel' "$sfile")
  jq --arg ts "$ts" --arg ch "$ch" \
    '.captain_reactions = [{"channel": $ch, "ts": $ts, "name": "white_check_mark", "users": ["'"$CAPTAIN"'"]}]' \
    "$dir/config.json" > "$dir/c.tmp" && mv "$dir/c.tmp" "$dir/config.json"
  bridge_once "$home" "$port" "$TMP_ROOT/snap-unatt.json" \
    FM_SLACK_UNATTENDED_SECS=0 FM_SLACK_REPEAT_MAX=1 || status=$?
  state=$(jq -r '.alerts["decision:task-b"] | "\(.done) \(.silenced)"' "$sfile")
  assert_contains "$state" "false false" \
    "a captain white_check_mark reaction must approve nothing"
  # Captain eyes silences the alert.
  jq --arg ts "$ts" --arg ch "$ch" \
    '.captain_reactions = [{"channel": $ch, "ts": $ts, "name": "eyes", "users": ["'"$CAPTAIN"'"]}]' \
    "$dir/config.json" > "$dir/c.tmp" && mv "$dir/c.tmp" "$dir/config.json"
  bridge_once "$home" "$port" "$TMP_ROOT/snap-unatt.json" \
    FM_SLACK_UNATTENDED_SECS=0 FM_SLACK_REPEAT_MAX=1 || status=$?
  state=$(jq -r '.alerts["decision:task-b"].silenced' "$sfile")
  [ "$state" = "true" ] || fail "captain eyes must silence the alert"
  pass "unattended alerts escalate with a capped notice; eyes silences; other reactions approve nothing"
}

test_disk_alert_roundtrip() {
  local home dir port posts state status=0
  home=$(make_home disk)
  dir="$TMP_ROOT/stub-disk"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" FM_SLACK_DISK_PCT=0 || status=$?
  posts=$(calls_matching "$dir" "chat.postMessage")
  assert_contains "$posts" '{"channel":"'"$STATUS_CH"'","text":"Disk nearly full' \
    "an over-threshold disk must alert the status channel"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" FM_SLACK_DISK_PCT=100 || status=$?
  state=$(jq -r '.alerts["disk"].done' "$(bridge_state "$home")")
  [ "$state" = "true" ] || fail "disk back under threshold must resolve its alert"
  pass "disk alerts fire over threshold and resolve back under it"
}

test_wedge_alert_roundtrip() {
  local home dir port posts state status=0
  home=$(make_home wedge)
  dir="$TMP_ROOT/stub-wedge"
  fake_slack_start "$dir"
  port=$FAKE_PORT
  FM_HOME="$home" FM_SLACK_API_URL="http://127.0.0.1:$port/api" \
    bash "$BRIDGE" wedge "injection stuck for 300s" 2>"$home/bridge.err" || status=$?
  expect_code 0 "$status" "wedge subcommand ran clean"
  posts=$(calls_matching "$dir" "chat.postMessage")
  assert_contains "$posts" '{"channel":"'"$STATUS_CH"'","text":"Wedge alarm: injection stuck for 300s"}' \
    "the wedge summary must alert the status channel verbatim"
  bridge_once "$home" "$port" "$TMP_ROOT/empty-snap.json" || status=$?
  state=$(jq -r '[.alerts[] | select(.cls == "wedge")][0].done' "$(bridge_state "$home")")
  [ "$state" = "true" ] || fail "a wedge alert must resolve when the readiness read recovers"
  pass "wedge alarms post to the status channel and resolve on recovered readiness"
}

test_no_real_slack_network() {
  local hits
  hits=$(grep -h 'slack\.com' "$TMP_ROOT"/stub-*/calls.log 2>/dev/null | grep -c .)
  [ "$hits" = "0" ] || fail "tests must not call real Slack"
  pass "no test run reached real Slack"
}

printf '{}\n' > "$TMP_ROOT/empty-snap.json"

test_wrapper_refuses_without_config
test_allowlist_rejection_and_idempotent_inbound
test_threaded_reply_delivery
test_poisoned_reply_skips_ahead
test_alert_channel_routing_and_pending_marker
test_reaction_resolution_transition
test_unattended_escalation_and_captain_ack
test_disk_alert_roundtrip
test_wedge_alert_roundtrip
test_no_real_slack_network
