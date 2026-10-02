#!/usr/bin/env bash
# Behavior tests for fm-prod-ff-cron.sh and fm-prod-ff-cron-install.sh.
#
# fm-prod-ff-cron.sh is the OS-cron entrypoint for the overnight
# fetch-plus-fast-forward-only refresh (AGENTS.md section 2;
# docs/configuration.md "Early-morning productive fast-forward"). It delegates
# every fetch/FF/dirty-copy decision to bin/fm-fleet-sync.sh and adds only:
#   - alerting through bin/fm-inbox.sh note on any non-benign outcome (a
#     STUCK: dirty/off-default/diverged clone, or a fetch/fast-forward
#     failure), never on a clean sync, and
#   - an optional per-project restart-then-verify step, driven by
#     config/prod-ff-services.json, that runs only when that project's clone
#     was actually fast-forwarded that run (never on a no-op or a STUCK
#     clone), with a restart or verify failure alerted the same way.
# Both scripts refuse outright in a secondmate home (main-home only).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-prod-ff-cron-tests)

# --- fixtures ---------------------------------------------------------------
#
# Each helper below is called as `home=$(new_primary_home)`: the command
# substitution forks a subshell, so any counter incremented inside the helper
# would never be visible to the next call. mktemp -d sidesteps that by making
# every fixture directory unique on its own, with no shared counter needed.

# new_primary_home: a fresh FM_HOME shaped like a genuine primary firstmate
# home (a plain git checkout with AGENTS.md, bin/, and state/), which is what
# fm-primary-scope-lib.sh's primary-home predicate requires.
new_primary_home() {
  local h
  h=$(mktemp -d "$TMP_ROOT/home-XXXXXX")
  mkdir -p "$h/projects" "$h/bin" "$h/state" "$h/config"
  : > "$h/AGENTS.md"
  git init -q "$h"
  git -C "$h" add AGENTS.md
  git -C "$h" commit -qm "seed"
  printf '%s\n' "$h"
}

new_secondmate_home() {
  local h
  h=$(mktemp -d "$TMP_ROOT/secondmate-XXXXXX")
  mkdir -p "$h/projects" "$h/bin" "$h/state"
  : > "$h/AGENTS.md"
  printf 'sm-%s\n' "$(basename "$h")" > "$h/.fm-secondmate-home"
  git init -q "$h"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_pair <home> <name>: a projects/<name> clone of a fresh bare origin
# with one commit on main, plus a side work-<name> repo for advancing origin.
build_pair() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main
  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

run_cron() {
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-prod-ff-cron.sh"
}

note_bodies() {
  local home=$1
  [ -d "$home/state/inbox" ] || return 0
  for f in "$home/state/inbox"/*.note; do
    [ -e "$f" ] || break
    sed -n '/^--$/,$p' "$f" | tail -n +2
  done
}

note_count() {
  local home=$1
  [ -d "$home/state/inbox" ] || { echo 0; return 0; }
  find "$home/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

# --- fake crontab for install-script tests -----------------------------------

new_fake_crontab() {
  local fakebin=$1 store=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/crontab" <<SH
#!/usr/bin/env bash
store="$store"
case "\$1" in
  -l) [ -f "\$store" ] && cat "\$store" || exit 1 ;;
  -r) rm -f "\$store" ;;
  -) cat > "\$store" ;;
  *) echo "unsupported: \$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/crontab"
}

run_install() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-prod-ff-cron-install.sh" "$@"
}

# --- tests -------------------------------------------------------------------

test_clean_sync_no_alert() {
  local home out
  home=$(new_primary_home)
  build_pair "$home" alpha >/dev/null
  advance_origin "$home" alpha C1

  out=$(run_cron "$home")

  [ "$(note_count "$home")" -eq 0 ] || fail "clean fast-forward must not alert"
  pass "a clean fetch-plus-fast-forward run writes no inbox alert"
}

test_dirty_copy_alerts_with_detail() {
  local home clone out
  home=$(new_primary_home)
  clone=$(build_pair "$home" beta)
  advance_origin "$home" beta C1
  printf 'dirty edit\n' >> "$clone/file.txt"

  out=$(run_cron "$home")

  [ "$(note_count "$home")" -eq 1 ] || fail "dirty copy must raise exactly one inbox alert"
  assert_contains "$(note_bodies "$home")" "beta: STUCK:" "alert names the stuck project"
  assert_contains "$(note_bodies "$home")" "uncommitted changes" "alert carries the dirty-copy detail"
  grep -q "dirty edit" "$clone/file.txt" || fail "dirty working tree must be left untouched"
  pass "a dirty copy raises one inbox alert naming the stuck state"
}

test_fetch_failure_alerts() {
  local home clone out
  home=$(new_primary_home)
  clone="$home/projects/gamma"
  git init -q "$clone"
  git -C "$clone" symbolic-ref HEAD refs/heads/main
  commit_file "$clone" file.txt v0 C0
  git -C "$clone" remote add origin "file://$home/remotes/does-not-exist.git"

  out=$(run_cron "$home")

  [ "$(note_count "$home")" -eq 1 ] || fail "a fetch failure must raise exactly one inbox alert"
  assert_contains "$(note_bodies "$home")" "gamma: skipped: fetch failed" "alert names the fetch failure"
  pass "a fetch failure raises one inbox alert"
}

test_local_only_and_no_origin_stay_silent() {
  local home out
  home=$(new_primary_home)
  build_pair "$home" delta >/dev/null
  advance_origin "$home" delta C1
  mkdir -p "$home/data"
  printf -- '- delta [local-only] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  local clone2="$home/projects/epsilon"
  git init -q "$clone2"
  git -C "$clone2" symbolic-ref HEAD refs/heads/main
  commit_file "$clone2" file.txt v0 C0

  out=$(run_cron "$home")

  [ "$(note_count "$home")" -eq 0 ] || fail "benign skips (local-only, no-origin) must never alert"
  pass "local-only and no-origin clones are silently skipped, never alerted"
}

test_restart_and_verify_only_after_real_fast_forward() {
  local home clone out
  home=$(new_primary_home)
  clone=$(build_pair "$home" zeta)
  advance_origin "$home" zeta C1
  cat > "$home/config/prod-ff-services.json" <<JSON
{"services":[{"name":"zeta","restart":"echo restarted > marker","verify":"grep -q restarted marker"}]}
JSON

  out=$(run_cron "$home")

  [ -f "$clone/marker" ] || fail "restart must run after a real fast-forward"
  [ "$(note_count "$home")" -eq 0 ] || fail "a successful restart+verify must not alert"
  pass "restart and verify run, silently, only after a real fast-forward"
}

test_no_restart_on_already_current() {
  local home clone
  home=$(new_primary_home)
  clone=$(build_pair "$home" eta)
  cat > "$home/config/prod-ff-services.json" <<JSON
{"services":[{"name":"eta","restart":"echo restarted > marker","verify":"true"}]}
JSON

  run_cron "$home" >/dev/null

  [ -f "$clone/marker" ] && fail "restart must never run when nothing updated (already current)"
  [ "$(note_count "$home")" -eq 0 ] || fail "an already-current clone must not alert"
  pass "restart never runs when the clone was already current"
}

test_no_restart_on_dirty_copy() {
  local home clone
  home=$(new_primary_home)
  clone=$(build_pair "$home" theta)
  advance_origin "$home" theta C1
  printf 'dirty\n' >> "$clone/file.txt"
  cat > "$home/config/prod-ff-services.json" <<JSON
{"services":[{"name":"theta","restart":"echo restarted > marker","verify":"true"}]}
JSON

  run_cron "$home" >/dev/null

  [ -f "$clone/marker" ] && fail "restart must never run on a dirty (STUCK) copy"
  pass "restart never runs on a dirty copy, even when configured"
}

test_restart_failure_alerts() {
  local home
  home=$(new_primary_home)
  build_pair "$home" iota >/dev/null
  advance_origin "$home" iota C1
  cat > "$home/config/prod-ff-services.json" <<JSON
{"services":[{"name":"iota","restart":"exit 1","verify":"true"}]}
JSON

  run_cron "$home" >/dev/null

  [ "$(note_count "$home")" -eq 1 ] || fail "a restart failure must raise exactly one inbox alert"
  assert_contains "$(note_bodies "$home")" "iota: restart failed" "alert names the restart failure"
  pass "a restart failure is reported through the inbox alert"
}

test_verify_failure_alerts() {
  local home
  home=$(new_primary_home)
  build_pair "$home" kappa >/dev/null
  advance_origin "$home" kappa C1
  cat > "$home/config/prod-ff-services.json" <<JSON
{"services":[{"name":"kappa","restart":"true","verify":"exit 1"}]}
JSON

  run_cron "$home" >/dev/null

  [ "$(note_count "$home")" -eq 1 ] || fail "a verify failure must raise exactly one inbox alert"
  assert_contains "$(note_bodies "$home")" "kappa: restarted but failed to verify" "alert names the verify failure"
  pass "a verify failure is reported through the inbox alert"
}

test_cron_refuses_in_secondmate_home() {
  local home out rc
  home=$(new_secondmate_home)

  set +e
  out=$(run_cron "$home" 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "secondmate home must refuse rather than run"
  assert_contains "$out" "secondmate home" "refusal names the secondmate-home reason"
  pass "fm-prod-ff-cron.sh refuses outright in a secondmate home"
}

test_install_status_uninstall_idempotent() {
  local home fakebin store out
  home=$(new_primary_home)
  fakebin=$(mktemp -d "$TMP_ROOT/fakebin-XXXXXX")
  store="$TMP_ROOT/crontab-store-$(basename "$fakebin")"
  new_fake_crontab "$fakebin" "$store"

  out=$(run_install "$home" "$fakebin" status)
  assert_contains "$out" "not installed" "status reports not-installed before any install"

  run_install "$home" "$fakebin" install 42 >/dev/null
  assert_contains "$(cat "$store")" "42 3 * * *" "install writes the requested minute inside the 03:00 hour"

  run_install "$home" "$fakebin" install 7 >/dev/null
  [ "$(wc -l < "$store")" -eq 1 ] || fail "reinstalling must replace, not duplicate, this home's entry"
  assert_contains "$(cat "$store")" "7 3 * * *" "reinstall updates the minute"

  run_install "$home" "$fakebin" uninstall >/dev/null
  [ -f "$store" ] && fail "uninstall must remove the entry (and the now-empty crontab)"
  pass "install/status/uninstall are idempotent and scoped to this home's own entry"
}

test_install_refuses_in_secondmate_home() {
  local home fakebin store rc out
  home=$(new_secondmate_home)
  fakebin=$(mktemp -d "$TMP_ROOT/fakebin-sm-XXXXXX")
  store="$TMP_ROOT/crontab-store-sm-$(basename "$fakebin")"
  new_fake_crontab "$fakebin" "$store"

  set +e
  out=$(run_install "$home" "$fakebin" install 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "install must refuse in a secondmate home"
  assert_contains "$out" "secondmate home" "refusal names the secondmate-home reason"
  [ -f "$store" ] && fail "a refused install must never write a crontab"
  pass "fm-prod-ff-cron-install.sh refuses outright in a secondmate home"
}

test_clean_sync_no_alert
test_dirty_copy_alerts_with_detail
test_fetch_failure_alerts
test_local_only_and_no_origin_stay_silent
test_restart_and_verify_only_after_real_fast_forward
test_no_restart_on_already_current
test_no_restart_on_dirty_copy
test_restart_failure_alerts
test_verify_failure_alerts
test_cron_refuses_in_secondmate_home
test_install_status_uninstall_idempotent
test_install_refuses_in_secondmate_home
