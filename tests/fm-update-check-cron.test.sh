#!/usr/bin/env bash
# Behavior tests for fm-update-check-cron.sh and fm-update-check-cron-install.sh.
#
# fm-update-check-cron.sh is the OS-cron entrypoint for the daily, check-only
# update alert (AGENTS.md section 2; docs/configuration.md "Daily update
# alert"). It is the read-only sibling of fm-prod-ff-cron.sh: both walk the
# identical bin/fm-fleet-sync.sh candidate enumeration (via its --check-only
# mode here), so coverage of projects/ never disagrees between the two. This
# script never fetches-and-fast-forwards; it only reports, through exactly one
# consolidated bin/fm-inbox.sh note, every repository (firstmate itself, any
# other git-backed tool source in config/watched-tools.json, and every
# registered productive project clone) that is behind its origin or STUCK.
# Both scripts refuse outright in a secondmate home (main-home only).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-update-check-cron-tests)

# --- fixtures ---------------------------------------------------------------

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

run_check() {
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-update-check-cron.sh"
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
    "$ROOT/bin/fm-update-check-cron-install.sh" "$@"
}

# --- tests -------------------------------------------------------------------

test_all_current_no_alert() {
  local home
  home=$(new_primary_home)
  build_pair "$home" alpha >/dev/null

  run_check "$home" >/dev/null

  [ "$(note_count "$home")" -eq 0 ] || fail "every clone current must not alert"
  pass "a run with every clone already current writes no inbox alert"
}

test_behind_clone_alerts_with_count_and_never_fast_forwards() {
  local home clone before
  home=$(new_primary_home)
  clone=$(build_pair "$home" beta)
  advance_origin "$home" beta C1
  before=$(git -C "$clone" rev-parse HEAD)

  run_check "$home" >/dev/null

  [ "$(note_count "$home")" -eq 1 ] || fail "a behind clone must raise exactly one inbox alert"
  assert_contains "$(note_bodies "$home")" "beta: 1 commits behind origin/main" \
    "alert names the clone and its behind-count"
  [ "$(git -C "$clone" rev-parse HEAD)" = "$before" ] \
    || fail "the check must never fast-forward the clone"
  pass "a behind clone raises one inbox alert and is left untouched"
}

test_dirty_copy_alerts_as_stuck() {
  local home clone before
  home=$(new_primary_home)
  clone=$(build_pair "$home" gamma)
  advance_origin "$home" gamma C1
  before=$(git -C "$clone" rev-parse HEAD)
  printf 'dirty edit\n' >> "$clone/file.txt"

  run_check "$home" >/dev/null

  [ "$(note_count "$home")" -eq 1 ] || fail "a dirty clone must raise exactly one inbox alert"
  assert_contains "$(note_bodies "$home")" "gamma: STUCK:" "alert names the stuck project"
  [ "$(git -C "$clone" rev-parse HEAD)" = "$before" ] || fail "dirty clone HEAD must be left untouched"
  grep -q "dirty edit" "$clone/file.txt" || fail "dirty working tree must be left untouched"
  pass "a dirty copy raises one inbox alert naming the stuck state"
}

test_local_only_and_no_origin_stay_silent() {
  local home
  home=$(new_primary_home)
  build_pair "$home" delta >/dev/null
  mkdir -p "$home/data"
  printf -- '- delta [local-only] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  local clone2="$home/projects/epsilon"
  git init -q "$clone2"
  git -C "$clone2" symbolic-ref HEAD refs/heads/main
  commit_file "$clone2" file.txt v0 C0

  run_check "$home" >/dev/null

  [ "$(note_count "$home")" -eq 0 ] || fail "benign skips (local-only, no-origin) must never alert"
  pass "local-only and no-origin clones are silently skipped, never alerted"
}

test_multiple_behind_clones_consolidate_into_one_note() {
  local home
  home=$(new_primary_home)
  build_pair "$home" zeta >/dev/null
  advance_origin "$home" zeta C1
  build_pair "$home" eta >/dev/null
  advance_origin "$home" eta C1
  advance_origin "$home" eta C2

  run_check "$home" >/dev/null

  [ "$(note_count "$home")" -eq 1 ] || fail "several behind clones must still raise exactly one consolidated note"
  assert_contains "$(note_bodies "$home")" "zeta: 1 commits behind origin/main" "note lists the first behind clone"
  assert_contains "$(note_bodies "$home")" "eta: 2 commits behind origin/main" "note lists the second behind clone with its own count"
  pass "multiple behind clones are consolidated into one inbox note"
}

test_git_backed_watched_tool_is_checked_and_relabeled() {
  local home tool_repo tool_remote work
  home=$(new_primary_home)

  tool_repo="$home/watched-tool"
  work="$home/work-watched-tool"
  tool_remote="$home/remotes/watched-tool.git"
  mkdir -p "$home/remotes"
  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$tool_remote"
  git -C "$work" remote add origin "file://$(cd "$tool_remote" && pwd)"
  git -C "$work" push -q -u origin main
  git clone --quiet "file://$(cd "$tool_remote" && pwd)" "$tool_repo"
  commit_file "$work" file.txt v1 C1
  git -C "$work" push -q origin main

  cat > "$home/config/watched-tools.json" <<JSON
{"tools":[{"name":"no-mistakes","git":{"repo":"$tool_repo"}}]}
JSON

  run_check "$home" >/dev/null

  [ "$(note_count "$home")" -eq 1 ] || fail "a behind git-backed watched tool must raise exactly one inbox alert"
  assert_contains "$(note_bodies "$home")" "no-mistakes: 1 commits behind origin/main" \
    "alert relabels the watched-tool path with its configured name"
  pass "a git-backed watched-tools.json entry is checked and relabeled with its configured name"
}

test_cron_refuses_in_secondmate_home() {
  local home out rc
  home=$(new_secondmate_home)

  set +e
  out=$(run_check "$home" 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "secondmate home must refuse rather than run"
  assert_contains "$out" "secondmate home" "refusal names the secondmate-home reason"
  pass "fm-update-check-cron.sh refuses outright in a secondmate home"
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
  assert_contains "$(cat "$store")" "42 6 * * *" "install writes the requested minute inside the 06:00 hour"

  run_install "$home" "$fakebin" install 7 >/dev/null
  [ "$(wc -l < "$store")" -eq 1 ] || fail "reinstalling must replace, not duplicate, this home's entry"
  assert_contains "$(cat "$store")" "7 6 * * *" "reinstall updates the minute"

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
  pass "fm-update-check-cron-install.sh refuses outright in a secondmate home"
}

test_all_current_no_alert
test_behind_clone_alerts_with_count_and_never_fast_forwards
test_dirty_copy_alerts_as_stuck
test_local_only_and_no_origin_stay_silent
test_multiple_behind_clones_consolidate_into_one_note
test_git_backed_watched_tool_is_checked_and_relabeled
test_cron_refuses_in_secondmate_home
test_install_status_uninstall_idempotent
test_install_refuses_in_secondmate_home
