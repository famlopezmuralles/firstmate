#!/usr/bin/env bash
# Behavior tests for bin/fm-agy-trust.sh and the agy spawn that calls it.
#
# Both halves of the contract are load-bearing and both are proven here: a
# legitimate fresh task worktree is trusted so an agy worker reaches its
# brief with no human, and every out-of-scope path is REFUSED rather than
# warned about or quietly skipped. The scope-test cases below are ported
# directly from tests/fm-claude-trust.test.sh, which owns the original
# structural reasoning (CDPATH, inherited git env, HOME-as-worktree); only
# the store format and the missing CLAUDE_CONFIG_DIR-equivalent axis differ,
# because agy has no per-invocation override for its trust store location
# (see bin/fm-agy-trust.sh's header).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-trust)

TRUST="$ROOT/bin/fm-agy-trust.sh"

# make_case <name>: a project with one linked worktree plus an isolated HOME.
# Echoes "<case>|<proj>|<wt>|<home>".
make_case() {
  local name=$1 case_dir proj wt home
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$home"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT HOME_DIR <<EOF
$1
EOF
}

# run_trust <home> <worktree> <project>: invoke against an isolated HOME.
run_trust() {
  local home=$1 wt=$2 proj=$3
  HOME="$home" "$TRUST" "$wt" "$proj" 2>&1
}

STORE_REL=.gemini/antigravity-cli/settings.json

trusted_paths() {  # <home>
  local store="$1/$STORE_REL"
  node -e 'const fs=require("node:fs");const p=process.argv[1];if(!fs.existsSync(p)){process.exit(0);}const j=JSON.parse(fs.readFileSync(p,"utf8"));for(const w of j.trustedWorkspaces||[])console.log(w);' "$store"
}

assert_trusted() {  # <home> <path> <msg>
  trusted_paths "$1" | grep -Fqx "$2" || fail "$3"
}

assert_not_trusted() {  # <home> <path> <msg>
  trusted_paths "$1" | grep -Fqx "$2" && fail "$3"
  return 0
}

store_value() {  # <home> <key...> -> the JSON value at that key path
  local home=$1 store="$1/$STORE_REL"
  shift
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));let v=j;for(const k of process.argv.slice(2)){v=(v===undefined||v===null)?undefined:v[k];}console.log(JSON.stringify(v));' "$store" "$@"
}

assert_store_value() {  # <home> <expected-json> <msg> <key...>
  local home=$1 expected=$2 msg=$3 actual
  shift 3
  actual=$(store_value "$home" "$@")
  [ "$actual" = "$expected" ] || fail "$msg (expected $expected, got $actual)"
}

# A PATH carrying the tools the scope test needs but no node, so the
# missing-interpreter path is exercised without disturbing the real PATH.
node_free_path() {  # <case-dir> -> a bin dir holding the script's own tools but no node
  local dir=$1/nonode-bin tool
  mkdir -p "$dir"
  for tool in bash env git mkdir; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

test_fresh_worktree_is_trusted() {
  local rec out
  rec=$(make_case fresh)
  read_case "$rec"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  assert_contains "$out" "trusted:" "registration did not report what it trusted"
  assert_trusted "$HOME_DIR" "$WT" "the worktree was not recorded as trusted"
  # The staged write is renamed into place, so no temporary store may survive it.
  [ -z "$(find "$HOME_DIR/.gemini/antigravity-cli" -maxdepth 1 -name '.settings.json.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left behind in the config directory"
  pass "fm-agy-trust.sh: a fresh task worktree is trusted"
}

test_registration_is_idempotent() {
  local rec out count
  rec=$(make_case idempotent)
  read_case "$rec"
  run_trust "$HOME_DIR" "$WT" "$PROJ" >/dev/null
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a repeat registration must succeed: $out"
  count=$(trusted_paths "$HOME_DIR" | grep -Fxc "$WT")
  [ "$count" = 1 ] || fail "a repeat registration duplicated the entry ($count)"
  pass "fm-agy-trust.sh: repeat registration is idempotent"
}

test_primary_checkout_is_refused() {
  local rec out
  rec=$(make_case primary)
  read_case "$rec"
  out=$(run_trust "$HOME_DIR" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$HOME_DIR" "$PROJ" "the primary checkout was trusted"
  pass "fm-agy-trust.sh: refuses the primary checkout"
}

test_cdpath_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case cdpath)
  read_case "$rec"
  mkdir -p "$CASE_DIR/decoy/.git"
  export CDPATH="$CASE_DIR/decoy"
  out=$(run_trust "$HOME_DIR" "$PROJ" "$PROJ")
  expect_code 1 $? "an exported CDPATH must not let the primary checkout through: $out"
  unset CDPATH
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$HOME_DIR" "$PROJ" "an exported CDPATH let the primary checkout be trusted"
  pass "fm-agy-trust.sh: an exported CDPATH cannot defeat the scope refusal"
}

test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal() {
  local rec out
  rec=$(make_case gitenv)
  read_case "$rec"
  GIT_DIR=$(git -C "$WT" rev-parse --absolute-git-dir)
  GIT_WORK_TREE=$PROJ
  export GIT_DIR GIT_WORK_TREE
  out=$(run_trust "$HOME_DIR" "$PROJ" "$PROJ")
  set -- $?
  unset GIT_DIR GIT_WORK_TREE
  expect_code 1 "$1" "inherited git environment overrides must not let the primary checkout through: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_not_trusted "$HOME_DIR" "$PROJ" "inherited git environment overrides let the primary checkout be trusted"
  pass "fm-agy-trust.sh: inherited git environment overrides cannot defeat the scope refusal"
}

test_home_directory_is_refused_even_when_it_is_a_worktree() {
  local rec out home
  rec=$(make_case home-worktree)
  read_case "$rec"
  # Make HOME itself a linked worktree of the project, so every git check
  # PASSES and only the home guard can refuse it.
  home="$CASE_DIR/home2"
  git -C "$PROJ" worktree add --quiet -b wt-home "$home"
  out=$(HOME="$home" "$TRUST" "$home" "$PROJ" 2>&1)
  expect_code 1 $? "a home directory must be refused even as a valid worktree: $out"
  assert_contains "$out" "home directory" "the refusal did not name the home directory"
  assert_not_trusted "$home" "$home" "the home directory was trusted"
  # Prove the git checks really would have accepted it, so the guard above is
  # what refused rather than an unrelated failure. Unlike CLAUDE_CONFIG_DIR,
  # agy's store location is derived from HOME with no override, so HOME must
  # itself be a real, existing directory here - exactly as it always is in a
  # live process.
  mkdir -p "$CASE_DIR/elsewhere-home"
  out=$(run_trust "$CASE_DIR/elsewhere-home" "$home" "$PROJ")
  expect_code 0 $? "the same path must be acceptable once it is not HOME: $out"
  pass "fm-agy-trust.sh: refuses a home directory the git checks would accept"
}

test_non_git_directory_is_refused() {
  local rec out plain
  rec=$(make_case plain)
  read_case "$rec"
  plain="$CASE_DIR/plain"
  mkdir -p "$plain"
  out=$(run_trust "$HOME_DIR" "$plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the refusal did not name the missing repository"
  assert_not_trusted "$HOME_DIR" "$plain" "a plain directory was trusted"
  pass "fm-agy-trust.sh: refuses a directory that is not a git worktree"
}

test_missing_directory_is_refused() {
  local rec out
  rec=$(make_case missing)
  read_case "$rec"
  out=$(run_trust "$HOME_DIR" "$CASE_DIR/nope" "$PROJ")
  expect_code 1 $? "a nonexistent path must be refused: $out"
  assert_contains "$out" "not an accessible directory" "the refusal did not name the inaccessible path"
  pass "fm-agy-trust.sh: refuses a path that does not exist"
}

test_foreign_project_worktree_is_refused() {
  local rec out other other_wt
  rec=$(make_case foreign)
  read_case "$rec"
  other="$CASE_DIR/other-project"
  other_wt="$CASE_DIR/other-wt"
  fm_git_worktree "$other" "$other_wt" wt-other
  out=$(run_trust "$HOME_DIR" "$other_wt" "$PROJ")
  expect_code 1 $? "another project's worktree must be refused: $out"
  assert_contains "$out" "is not a worktree of project" "the refusal did not name the project mismatch"
  assert_not_trusted "$HOME_DIR" "$other_wt" "a foreign project's worktree was trusted"
  pass "fm-agy-trust.sh: refuses a worktree belonging to another project"
}

test_worktree_subdirectory_is_refused() {
  local rec out sub
  rec=$(make_case subdir)
  read_case "$rec"
  sub="$WT/sub"
  mkdir -p "$sub"
  out=$(run_trust "$HOME_DIR" "$sub" "$PROJ")
  expect_code 1 $? "a subdirectory of the worktree must be refused: $out"
  assert_contains "$out" "is not a worktree root" "the refusal did not name the non-root path"
  assert_not_trusted "$HOME_DIR" "$sub" "a worktree subdirectory was trusted"
  pass "fm-agy-trust.sh: refuses a subdirectory of the worktree"
}

test_unrelated_store_content_is_preserved() {
  local rec store
  rec=$(make_case preserve)
  read_case "$rec"
  store="$HOME_DIR/$STORE_REL"
  mkdir -p "$(dirname "$store")"
  cat > "$store" <<'JSON'
{"permissions":{"allow":["command(agy)"]},"trustedWorkspaces":["/other/path"]}
JSON
  run_trust "$HOME_DIR" "$WT" "$PROJ" >/dev/null || fail "registration failed against an existing store"
  assert_trusted "$HOME_DIR" "$WT" "the worktree was not recorded in an existing store"
  assert_store_value "$HOME_DIR" '["command(agy)"]' "an unrelated top-level key was lost" permissions allow
  assert_trusted "$HOME_DIR" "/other/path" "another workspace's trust decision was lost"
  pass "fm-agy-trust.sh: preserves unrelated store content"
}

test_symlinked_store_to_a_foreign_owned_target_is_refused() {
  local rec out store
  rec=$(make_case symlink-foreign)
  read_case "$rec"
  if [ "$(id -u)" = 0 ]; then
    pass "fm-agy-trust.sh: refuses a store symlinked to another user's file (skipped as root)"
    return 0
  fi
  store="$HOME_DIR/$STORE_REL"
  mkdir -p "$(dirname "$store")"
  ln -s /etc/passwd "$store"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "a store resolving to another user's file must be refused: $out"
  assert_contains "$out" "not owned by this user" "the refusal did not name the ownership failure"
  assert_contains "$out" "/etc/passwd" "the refusal named the link rather than the resolved target it judged"
  pass "fm-agy-trust.sh: refuses a store symlinked to another user's file"
}

test_symlinked_store_to_an_owned_target_is_accepted() {
  local rec out store target
  rec=$(make_case symlink-owned)
  read_case "$rec"
  store="$HOME_DIR/$STORE_REL"
  target="$CASE_DIR/dotfiles/settings.json"
  mkdir -p "$(dirname "$store")" "$CASE_DIR/dotfiles"
  printf '%s\n' '{"trustedWorkspaces":[]}' > "$target"
  ln -s "$target" "$store"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 0 $? "a store symlinked to this user's own file must be accepted: $out"
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.exit((j.trustedWorkspaces||[]).includes(process.argv[2])?0:1)' \
    "$target" "$WT" || fail "the trust did not land in the symlink's target"
  [ -L "$store" ] || fail "the store symlink was replaced by a regular file instead of followed"
  [ -z "$(find "$CASE_DIR/dotfiles" -maxdepth 1 -name '.settings.json.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left beside the resolved target"
  pass "fm-agy-trust.sh: follows a store symlink to this user's own file and leaves the link intact"
}

test_missing_node_is_refused() {
  local rec out bindir
  rec=$(make_case no-node)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "a missing node must refuse rather than let the spawn proceed: $out"
  assert_contains "$out" "node" "the refusal did not name the missing interpreter"
  assert_not_trusted "$HOME_DIR" "$WT" "a worktree was trusted without an interpreter to write the store"
  case "$out" in
    *"trusted:"*) fail "a registration was claimed although none could be written: $out" ;;
  esac
  pass "fm-agy-trust.sh: a missing node is refused rather than degraded"
}

test_scope_refusal_stays_fail_closed_without_node() {
  local rec out bindir
  rec=$(make_case no-node-refusal)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$HOME_DIR" "$PROJ" "$PROJ")
  expect_code 1 $? "the primary checkout must still be refused without node: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  pass "fm-agy-trust.sh: a scope refusal stays fail-closed without node"
}

test_corrupt_store_fails_closed() {
  local rec out store
  rec=$(make_case corrupt)
  read_case "$rec"
  store="$HOME_DIR/$STORE_REL"
  mkdir -p "$(dirname "$store")"
  printf '%s\n' 'not json' > "$store"
  out=$(run_trust "$HOME_DIR" "$WT" "$PROJ")
  expect_code 1 $? "an unparseable store must be refused: $out"
  assert_grep 'not json' "$store" "the unparseable store was overwritten instead of left alone"
  pass "fm-agy-trust.sh: refuses an unparseable store and leaves it untouched"
}

# The spawn half: a real fm-spawn of an agy worker must pre-register the
# worktree AND deliver the launch command carrying the brief, with no dialog
# to answer and no human in the loop.
test_agy_spawn_pretrusts_its_worktree_and_reaches_the_brief() {
  local case_dir home proj wt fakebin launch_log out
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launch_log="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  fm_test_spawn_home "$home" agy
  fm_git_worktree "$proj" "$wt" wt-spawn
  fm_test_spawn_brief "$home" trustspawn
  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" trustspawn "$proj" agy \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "the agy spawn must succeed: $out"
  assert_trusted "$home/user-home" "$wt" \
    "the agy spawn did not pre-register trust for its worktree"
  assert_present "$launch_log" "the agy spawn sent no launch command"
  assert_grep "agy' --prompt-interactive " "$launch_log" \
    "the launch command was not the agy worker launch"
  assert_grep ' --dangerously-skip-permissions' "$launch_log" \
    "the agy worker launch did not skip permission prompts"
  assert_grep "$home/data/trustspawn/launch-brief.md" "$launch_log" \
    "the launch command did not carry the brief the worker must read"
  pass "fm-spawn.sh: an agy spawn pre-trusts its worktree and launches with the brief"
}

# A refused registration must not launch an unattended agy worker: the spawn
# still fails at the launch-confirmation gate, records that failure for
# teardown, and leaves no busy state behind.
test_refused_spawn_leaves_no_task_state() {
  local case_dir home proj wt fakebin out id store
  case_dir="$TMP_ROOT/refused-spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="refusedspawn$$"
  if [ "$(id -u)" = 0 ]; then
    pass "fm-spawn.sh: a trust-refused agy spawn leaves no task state (skipped as root)"
    return 0
  fi
  store="$home/user-home/$STORE_REL"
  mkdir -p "$(dirname "$store")"
  ln -s /etc/passwd "$store"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  fm_test_spawn_home "$home" agy
  fm_git_worktree "$proj" "$wt" wt-refused
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" agy \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "a spawn whose trust registration is refused must fail: $out"
  assert_contains "$out" "workspace trust" "the spawn did not report the trust refusal"
  [ ! -e "$home/state/$id.busy-state" ] \
    || fail "a refused spawn stranded a busy record nothing can clear"
  [ ! -e "$home/state/$id.busy-gen" ] \
    || fail "a refused spawn stranded a busy generation nothing can clear"
  assert_grep 'failed [at=' "$home/state/$id.status" \
    "a refused spawn did not record its failure for teardown to find"
  pass "fm-spawn.sh: a trust-refused agy spawn fails and leaves no busy state behind"
}

test_fresh_worktree_is_trusted
test_registration_is_idempotent
test_primary_checkout_is_refused
test_cdpath_cannot_defeat_the_primary_checkout_refusal
test_git_env_overrides_cannot_defeat_the_primary_checkout_refusal
test_home_directory_is_refused_even_when_it_is_a_worktree
test_non_git_directory_is_refused
test_missing_directory_is_refused
test_foreign_project_worktree_is_refused
test_worktree_subdirectory_is_refused
test_unrelated_store_content_is_preserved
test_symlinked_store_to_a_foreign_owned_target_is_refused
test_symlinked_store_to_an_owned_target_is_accepted
test_missing_node_is_refused
test_scope_refusal_stays_fail_closed_without_node
test_corrupt_store_fails_closed
test_agy_spawn_pretrusts_its_worktree_and_reaches_the_brief
test_refused_spawn_leaves_no_task_state
