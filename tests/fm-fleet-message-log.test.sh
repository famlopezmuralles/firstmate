#!/usr/bin/env bash
# Behavior tests for bin/fm-fleet-message-log.sh - the local live
# firstmate<->crew transcript page.
#
# Cases pin the page contract through behavior only: fixture inboxes and
# status logs in, rendered transcript out, with the state tree proven
# untouched, no external references, the loopback serve path exercised for
# real over HTTP, and live updates proven by appending a status line between
# two /events.json polls.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$ROOT/bin/fm-fleet-message-log.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-message-log)

make_home() {  # <name> -> echoes home dir
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

write_msg() {  # <path> <at> <body...>
  local path=$1 at=$2
  shift 2
  {
    printf 'schema=fm-task-inbox.v1\nat=%s\n--\n' "$at"
    printf '%s\n' "$*"
  } > "$path"
}

fetch() {  # <url> -> prints body
  python3 -c "import urllib.request,sys; sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())" "$1"
}

wait_for() {  # <url> -> waits until it answers
  local i=0
  while [ "$i" -lt 50 ]; do
    i=$((i + 1))
    fetch "$1" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}

test_build_renders_both_directions() {
  local home out html
  home=$(make_home build)
  mkdir -p "$home/state/alpha.inbox/handled"
  write_msg "$home/state/alpha.inbox/001.msg" "2026-10-20T10:00:00Z" \
    "[fm-from-firstmate] corr=aaa111bbb222 please explore the API"
  printf '001.msg\t2\t1792800000\n' > "$home/state/alpha.inbox/.ring-state"
  printf '001.msg\n' > "$home/state/alpha.inbox/.escalated"
  write_msg "$home/state/alpha.inbox/handled/002.msg" "2026-10-20T09:00:00Z" \
    "[fm-from-firstmate] corr=ccc333ddd444 earlier instruction"
  cat > "$home/state/alpha.status" <<'EOF'
done [at=1792820000] [key=done-explore]: explored, report at data/alpha/report.md corr=aaa111bbb222
working: applying follow-ups
EOF
  printf 'kind=secondmate\n' > "$home/state/alpha.meta"
  printf 'done [at=1792820100]: beta idle\n' > "$home/state/beta.status"
  out="$home/data/logs"
  "$LOG" --state-dir "$home/state" --out "$out" --refresh 0 >/dev/null \
    || fail "build must exit 0"
  html="$out/index.html"
  assert_present "$html" "build writes index.html"
  assert_grep "please explore the API" "$html" "pending steer body embedded"
  assert_grep "earlier instruction" "$html" "handled steer body embedded"
  assert_grep "explored, report at" "$html" "status line embedded"
  assert_grep "Firstmate to agent" "$html" "out direction labels"
  assert_grep "Agent to firstmate" "$html" "in direction labels"
  assert_grep "aaa111bbb222" "$html" "correlation id embedded"
  assert_grep "handled" "$html" "handled state embedded"
  assert_grep "rung 2x" "$html" "ring count derives from .ring-state"
  assert_grep "escalated" "$html" "escalation marker derives from .escalated"
  assert_grep 'id="q"' "$html" "free-text search box renders"
  assert_grep 'id="agent"' "$html" "agent filter renders"
  assert_grep "secondmate" "$html" "meta kind ships in the payload"
  assert_grep "events.json" "$html" "page polls the live endpoint"
  assert_no_grep "setInterval" "$html" "--refresh 0 disables live polling"
  pass "build renders both directions with derived state"
}

test_state_tree_untouched_and_local_only() {
  local home out before after html
  home=$(make_home readonly)
  mkdir -p "$home/state/gamma.inbox/handled"
  write_msg "$home/state/gamma.inbox/handled/009.msg" "2026-10-21T10:00:00Z" \
    "[fm-from-firstmate] corr=eee555fff666 go"
  printf 'working [at=1792820200]: on it corr=eee555fff666\n' > "$home/state/gamma.status"
  printf 'done [at=1792820300]: hidden record\n' > "$home/state/.hidden.status"
  before=$(cd "$home/state" && find . | sort)
  out="$home/data/logs"
  "$LOG" --state-dir "$home/state" --out "$out" >/dev/null \
    || fail "build must exit 0"
  after=$(cd "$home/state" && find . | sort)
  assert_equals "$before" "$after" "state tree is byte-identical after build"
  html="$out/index.html"
  assert_no_grep ".hidden" "$html" "dot-prefixed records stay out of the page"
  assert_no_grep "src=\"http" "$html" "no external scripts"
  assert_no_grep "href=\"http" "$html" "no external links"
  assert_grep "setInterval" "$html" "default build keeps live polling"
  assert_grep "POLL_SECS=5" "$html" "default poll interval is five seconds"
  pass "state tree untouched and page has no external references"
}

test_serve_polls_live_over_loopback() {
  local home out port server body1 body2 before after
  home=$(make_home serve)
  printf 'done [at=1792820400]: first served line\n' > "$home/state/solo.status"
  out="$home/data/logs"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  before=$(cd "$home/state" && find . | sort)
  "$LOG" --state-dir "$home/state" --out "$out" --serve --port "$port" >/dev/null 2>&1 &
  server=$!
  # shellcheck disable=SC2064
  trap "kill $server 2>/dev/null" EXIT
  wait_for "http://127.0.0.1:$port/events.json" || fail "server must answer on loopback"
  body1=$(fetch "http://127.0.0.1:$port/events.json")
  assert_contains "$body1" "first served line" "first poll carries the transcript"
  assert_contains "$(fetch "http://127.0.0.1:$port/")" "Fleet message log" "root serves the page"
  printf 'working [at=1792820500]: second live line\n' >> "$home/state/solo.status"
  body2=$(fetch "http://127.0.0.1:$port/events.json")
  assert_contains "$body2" "second live line" "second poll shows the appended line without a rebuild"
  kill "$server" 2>/dev/null
  trap - EXIT
  after=$(cd "$home/state" && find . | sort)
  assert_equals "$before" "$after" "serve adds no files to state"
  pass "serve polls live over loopback"
}

test_bad_inputs_refused() {
  local home code
  home=$(make_home bad)
  "$LOG" --state-dir "$home/state" --out "$home/data/logs" --bogus >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "unknown argument refuses"
  "$LOG" --state-dir "$home/state/nope" --out "$home/data/logs" >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "missing state dir refuses"
  "$LOG" --help >/dev/null || fail "--help must exit 0"
  pass "bad inputs refused"
}

test_build_renders_both_directions
test_state_tree_untouched_and_local_only
test_serve_polls_live_over_loopback
test_bad_inputs_refused
