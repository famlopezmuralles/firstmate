#!/usr/bin/env bash
# Tests for bin/fm-reports-publish.sh and bin/fm-reports-render.py: the
# central report catalog must organize published reports by project (1:1 with
# diffs-explained, with general fallback), persist source markdown alongside
# rendered HTML only, preserve existing published reports across worktree pruning,
# initialize the publish root as a Git repository and commit only when reports change,
# carry the captain's intent in each report's provenance, migrate legacy pages,
# provide static project and root index pages without client-side fetching,
# aggregate registered secondmate homes, disclose unreachable remotes, and
# never publish denylisted files, symlinks outside data/, or unsafe scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUBLISH="$ROOT/bin/fm-reports-publish.sh"

snapshot_stub() {  # <path> <records-json>
  local path=$1 records=$2
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
#!/usr/bin/env bash
cat <<JSON
{"schema":"fm-fleet-snapshot.v1","backlog":{"present":true,"records":$records},
 "tasks":[],"scout_reports":[],"main_inventory":{},"secondmate_current":{},
 "secondmate_landed":{},"secondmate_guidance":{}}
JSON
EOF
  chmod +x "$path"
}

make_fixture() {
  local root=$1 main=$1/main second=$1/second

  mkdir -p "$main/data/task-good" "$main/data/task-super" "$main/data/task-xss" \
    "$main/data/task-link" "$main/data/task-orphan" "$main/state" \
    "$second/data/task-remote-sib" "$second/state"

  snapshot_stub "$main/bin/fm-fleet-snapshot.sh" '[
    {"id":"task-good","structured":true,"title":"Good report task","repo":"demo-repo","pr_url":"https://github.com/example/demo/pull/1","state":"done"},
    {"id":"task-super","structured":true,"title":"Superseded task","repo":"demo-repo","pr_url":"","state":"done"},
    {"id":"task-xss","structured":true,"title":"XSS task","repo":"demo-repo","pr_url":"","state":"in_flight"},
    {"id":"task-orphan","structured":true,"title":"Orphan task","repo":"..","pr_url":"","state":"done"}
  ]'
  snapshot_stub "$second/bin/fm-fleet-snapshot.sh" '[
    {"id":"task-remote-sib","structured":true,"title":"Sibling home task","repo":"other-repo","pr_url":"","state":"done"}
  ]'

  printf '# Good report\n\nHello world.\n' > "$main/data/task-good/report.md"
  printf 'model=gpt-6-sol\neffort=high\n' > "$main/state/task-good.meta"
  printf 'model=claude-sonnet\neffort=medium\n' > "$second/state/task-remote-sib.meta"
  for junk in brief.md launch-brief.md decision.md review-decision.md \
      ship-instructions.md task-note.md intake.md brief-v2.md steer-x.md; do
    printf 'SHOULD_NOT_APPEAR_%s\n' "$junk" > "$main/data/task-good/$junk"
  done

  printf '# Current\n\ncurrent content marker\n' > "$main/data/task-super/report.md"
  printf "# Task\n\n## Captain's intent\n\nINTENT_MARKER_42\n\n## Firstmate spec\n\nbuild it\n" \
    > "$main/data/task-super/brief.md"
  printf '# Prior\n\nold content marker\n' > "$main/data/task-super/prior-report.md"

  printf '# XSS <script>alert(1)</script>\n\n[bad](javascript:alert(1))\n' \
    > "$main/data/task-xss/report.md"

  printf '# Orphan report\n\nNo associated project.\n' > "$main/data/task-orphan/report.md"

  printf 'SECRET_OUTSIDE_DATA\n' > "$root/secret.txt"
  ln -s "$root/secret.txt" "$main/data/task-link/report.md"

  printf '# Sibling report\n\nfrom the second home\n' > "$second/data/task-remote-sib/report.md"

  cat > "$main/data/secondmates.md" <<EOF
- second - Test secondmate for fm-reports-publish fixtures. (home: $second; scope: testing; projects: none; added 2026-01-01)
- ghost - Unreachable fixture remote for disclosure testing. (host: fm-reports-ghost-alias-zzz; root: /nonexistent/root; home: /nonexistent/home; scope: testing; projects: none; added 2026-01-01)
EOF
}

run_publish() {  # <root>
  FM_HOME="$1/main" FM_REPORTS_PUBLISH_ROOT="$1/publish" FM_REPORTS_REMOTE_TIMEOUT=6 \
    "$PUBLISH" publish
}

catalog_json() {  # <root>
  cat "$1/publish/catalog.json"
}

test_report_candidate_included_with_backlog_context() {
  local root
  root=$(fm_test_tmproot fm-reports-good)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"

  assert_contains "$(catalog_json "$root")" '"task_id": "task-good"' \
    "task-good should appear in the catalog"
  assert_contains "$(catalog_json "$root")" '"project": "demo-repo"' \
    "task-good's project should come from backlog context, not be invented"
  assert_contains "$(catalog_json "$root")" 'pull/1' \
    "task-good's linked PR should come from backlog context"
  assert_contains "$(catalog_json "$root")" '"model": "gpt-6-sol"' \
    "task model should come from state metadata"
  assert_contains "$(catalog_json "$root")" '"thinking_effort": "high"' \
    "task effort should come from state metadata"
  assert_contains "$(catalog_json "$root")" '"html_path": "demo-repo/task-good/report.html"' \
    "task-good should be published under demo-repo"
  [ -f "$root/publish/demo-repo/task-good/report.html" ] \
    || fail "task-good/report.html should be written under demo-repo"
  [ -f "$root/publish/demo-repo/index.html" ] \
    || fail "demo-repo/index.html project index should be generated"
  assert_contains "$(cat "$root/publish/demo-repo/task-good/report.html")" 'Model used</dt><dd>gpt-6-sol' \
    "report provenance should include its model"
  assert_contains "$(cat "$root/publish/demo-repo/index.html")" 'gpt-6-sol' \
    "project index should include model provenance"
  [ -f "$root/publish/index.html" ] \
    || fail "root index.html should be generated"
  local md_count
  md_count=$(find "$root/publish" -name '*.md' | wc -l)
  assert_equals "0" "$md_count" "raw markdown must never be persisted into the publish root"
  pass "a plain report.md is published as sanitized HTML under its project with a static index"
}

test_denylisted_files_never_published() {
  local root
  root=$(fm_test_tmproot fm-reports-deny)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"

  local found
  found=$(grep -rl "SHOULD_NOT_APPEAR" "$root/publish" 2>/dev/null || true)
  [ -z "$found" ] || fail "a denylisted file leaked into the catalog: $found"

  local html_count
  html_count=$(find "$root/publish/demo-repo/task-good" -type f -name '*.html' | wc -l)
  assert_equals "1" "$html_count" \
    "only report.md should be published for task-good, not its brief/decision/steer siblings"
  pass "briefs, decisions, and steering notes are never published"
}

test_superseded_variant_marked_historical() {
  local root json
  root=$(fm_test_tmproot fm-reports-historical)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"
  json=$(catalog_json "$root")

  [ -f "$root/publish/demo-repo/task-super/report.html" ] \
    || fail "the current report.html should still be published"
  [ -f "$root/publish/demo-repo/task-super/prior-report.html" ] \
    || fail "the superseded prior-report.html should still be published, not hidden"

  assert_contains "$json" '"task_id": "task-super"' "task-super should be in the catalog"
  assert_contains "$(python3 -c "
import json
d = json.load(open('$root/publish/catalog.json'))
rows = [r for r in d['reports'] if r['task_id'] == 'task-super']
rows.sort(key=lambda r: r['html_path'])
print(rows)
")" 'historical' "catalog rows for task-super should carry a historical flag"

  local prior_hist current_hist
  prior_hist=$(python3 -c "
import json
d = json.load(open('$root/publish/catalog.json'))
for r in d['reports']:
    if r['html_path'].endswith('prior-report.html'):
        print(r['historical'])
")
  current_hist=$(python3 -c "
import json
d = json.load(open('$root/publish/catalog.json'))
for r in d['reports']:
    if r['html_path'].endswith('/report.html') and r['task_id'] == 'task-super':
        print(r['historical'])
")
  assert_equals "True" "$prior_hist" "prior-report.md must be marked historical"
  assert_equals "False" "$current_hist" "the current report.md must not be marked historical"
  pass "a superseded variant is published but marked historical, never presented as current"
}

test_report_content_is_sanitized() {
  local root page
  root=$(fm_test_tmproot fm-reports-xss)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"
  page=$(cat "$root/publish/demo-repo/task-xss/report.html")

  assert_not_contains "$page" '<script>alert' \
    "a literal <script> tag in report content must never reach the rendered page"
  assert_contains "$page" '&lt;script&gt;' \
    "the script tag text should still be visible, escaped"
  assert_not_contains "$page" 'href="javascript:' \
    "a javascript: link target must never be rendered as a clickable href"
  pass "report content is HTML-escaped before any markup is reconstructed"
}

test_symlinked_report_is_excluded() {
  local root
  root=$(fm_test_tmproot fm-reports-symlink)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"

  [ ! -e "$root/publish/demo-repo/task-link" ] \
    || fail "a symlinked report.md must not be published"
  [ ! -e "$root/publish/general/task-link" ] \
    || fail "a symlinked report.md must not be published under general"
  assert_not_contains "$(catalog_json "$root")" 'task-link' \
    "task-link must not appear in the catalog"
  local leaked
  leaked=$(grep -rl "SECRET_OUTSIDE_DATA" "$root/publish" 2>/dev/null || true)
  [ -z "$leaked" ] || fail "a symlink let a file outside data/ leak into the catalog: $leaked"
  pass "a symlinked report.md is excluded rather than followed outside the data root"
}

test_registered_secondmate_is_aggregated() {
  local root
  root=$(fm_test_tmproot fm-reports-secondmate)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"

  assert_contains "$(catalog_json "$root")" '"task_id": "task-remote-sib"' \
    "the registered local secondmate home's report should be aggregated into the catalog"
  [ -f "$root/publish/other-repo/task-remote-sib/report.html" ] \
    || fail "the secondmate's report page should be written under its project directory"
  [ -f "$root/publish/other-repo/index.html" ] \
    || fail "other-repo project index should be generated"
  pass "a registered local secondmate home's reports are aggregated by project"
}

test_unreachable_remote_is_disclosed_not_silently_empty() {
  local root index
  root=$(fm_test_tmproot fm-reports-ghost)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"
  index=$(cat "$root/publish/index.html")

  assert_contains "$index" 'ghost' \
    "an unreachable registered remote home must be named in the catalog's disclosure"
  assert_contains "$index" 'unavailable' \
    "the catalog must disclose the unavailable source rather than reporting an empty successful run"
  pass "an unreachable registered remote home is disclosed rather than silently omitted"
}

test_unknown_project_falls_back_to_general() {
  local root
  root=$(fm_test_tmproot fm-reports-orphan)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"

  [ -f "$root/publish/general/task-orphan/report.html" ] \
    || fail "orphan task should be published under general"
  [ ! -e "$root/task-orphan" ] || fail "a dot project slug must not escape the publish root"
  [ -f "$root/publish/general/index.html" ] \
    || fail "general project index should be generated"
  assert_contains "$(catalog_json "$root")" '"project": "general"' \
    "orphan task should carry general project in catalog"
  pass "an unassociated report falls back to the clean general project grouping"
}

test_persistence_when_worktree_pruned() {
  local root
  root=$(fm_test_tmproot fm-reports-prune)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "first publish failed: $(cat "$root/stderr")"

  [ -f "$root/publish/demo-repo/task-good/report.html" ] \
    || fail "report.html should exist before prune"

  # Simulate worktree pruning: remove task-good from source data directory
  rm -rf "$root/main/data/task-good"

  # Run publish again
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "second publish failed: $(cat "$root/stderr")"

  [ -f "$root/publish/demo-repo/task-good/report.html" ] \
    || fail "report.html must be preserved after source data is pruned"
  assert_contains "$(catalog_json "$root")" '"task_id": "task-good"' \
    "task-good must remain in catalog.json after source prune"
  assert_contains "$(cat "$root/publish/demo-repo/index.html")" 'task-good' \
    "task-good must remain in project index after source prune"
  assert_contains "$(cat "$root/publish/index.html")" 'task-good' \
    "task-good must remain in root index after source prune"
  pass "existing published reports are preserved across worktree prunes"
}

test_git_repository_initialized_and_committed() {
  local root
  root=$(fm_test_tmproot fm-reports-git)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"

  [ -d "$root/publish/.git" ] || fail "publish root should be initialized as git repository"
  [ -f "$root/publish/.gitignore" ] || fail ".gitignore should exist in publish root"

  local status
  status=$(git -C "$root/publish" status --porcelain)
  [ -z "$status" ] || fail "git working tree should be clean after publish commit: $status"

  local log_msg
  log_msg=$(git -C "$root/publish" log -1 --pretty=%B)
  assert_contains "$log_msg" "publish: refresh report catalog" \
    "git repository should contain refresh commit"
  pass "publish root is initialized as git repository with .gitignore and version-controlled on refresh"
}

test_refresh_commits_only_when_reports_change() {
  local root before after
  root=$(fm_test_tmproot fm-reports-nocommit)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "first publish failed: $(cat "$root/stderr")"
  before=$(git -C "$root/publish" rev-list --count HEAD)

  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "routine publish failed: $(cat "$root/stderr")"
  after=$(git -C "$root/publish" rev-list --count HEAD)
  assert_equals "$before" "$after" "a routine refresh with no report changes must not create a commit"

  printf 'unrelated root data\n' > "$root/publish/notes.txt"
  printf 'unrelated nested data\n' > "$root/publish/demo-repo/task-good/notes.txt"
  git -C "$root/publish" add notes.txt
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "refresh with unrelated staged file failed: $(cat "$root/stderr")"
  after=$(git -C "$root/publish" rev-list --count HEAD)
  assert_equals "$before" "$after" "unrelated staged files must not trigger a report commit"

  printf '# Good report\n\nEdited body.\n' > "$root/main/data/task-good/report.md"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "changed publish failed: $(cat "$root/stderr")"
  after=$(git -C "$root/publish" rev-list --count HEAD)
  assert_equals "$((before + 1))" "$after" "a refresh that publishes a modified report must commit once"
  local committed_files status
  committed_files=$(git -C "$root/publish" diff-tree --no-commit-id --name-only -r HEAD)
  case "$committed_files" in *notes.txt*) fail "unrelated files must not be committed: $committed_files" ;; esac
  status=$(git -C "$root/publish" status --porcelain)
  assert_contains "$status" 'notes.txt' "unrelated staged and untracked files must remain outside the publisher commit"
  pass "the publish root commits only when new or modified reports are published"
}

test_provenance_carries_intent_and_hides_ephemeral_paths() {
  local root page
  root=$(fm_test_tmproot fm-reports-provenance)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"
  page=$(cat "$root/publish/demo-repo/task-super/report.html")

  assert_contains "$page" "INTENT_MARKER_42" \
    "the captain's intent from the task brief must appear in the provenance header"
  assert_contains "$page" "Thinking effort" "the provenance header must name the thinking effort"
  assert_not_contains "$page" "$root/main" \
    "the provenance header must not expose the ephemeral local source path"
  pass "provenance carries the captain's intent and omits ephemeral local paths"
}

test_legacy_pages_migrate_with_root_back_link() {
  local root page
  root=$(fm_test_tmproot fm-reports-legacy)
  make_fixture "$root"
  mkdir -p "$root/publish/reports/main/task-legacy"
  printf '<p><a href="../../../index.html">&larr; Back to report catalog</a></p>\n' \
    > "$root/publish/reports/main/task-legacy/report.html"
  printf '{"reports":[{"title":"Legacy","home":"main","task_id":"task-legacy","html_path":"reports/main/task-legacy/report.html","updated":"2026-01-01T00:00:00Z","historical":false}]}' \
    > "$root/publish/catalog.json"

  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"
  page=$(cat "$root/publish/general/task-legacy/report.html")

  assert_contains "$page" 'href="../../index.html"' \
    "a migrated legacy page must link back to the publish root from its new location"
  assert_not_contains "$page" '../../../index.html' \
    "the legacy back link must not resolve outside the publish root"
  assert_contains "$(catalog_json "$root")" '"html_path": "general/task-legacy/report.html"' \
    "the migrated legacy report must be recorded at its new path"
  pass "legacy reports migrate into the project layout with a working back link"
}

test_static_navigation_without_client_side_fetch() {
  local root index_content project_index
  root=$(fm_test_tmproot fm-reports-nav)
  make_fixture "$root"
  run_publish "$root" >/dev/null 2>"$root/stderr" || fail "publish failed: $(cat "$root/stderr")"

  index_content=$(cat "$root/publish/index.html")
  project_index=$(cat "$root/publish/demo-repo/index.html")

  assert_contains "$index_content" 'Good report task' \
    "root index.html must contain static report table row"
  assert_contains "$index_content" 'demo-repo/task-good/report.html' \
    "root index.html must link to report page"
  assert_contains "$index_content" 'demo-repo/index.html' \
    "root index.html must link to project index"
  assert_not_contains "$index_content" "fetch('catalog.json')" \
    "root index.html must not rely on fragile client-side fetching"
  python3 - "$root/publish/demo-repo/task-good/report.html" <<'PY'
from html.parser import HTMLParser
import posixpath
import sys

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.hrefs.append(dict(attrs).get("href"))

page_dir = "demo-repo/task-good"
parser = Links()
parser.feed(open(sys.argv[1], encoding="utf-8").read())
targets = [posixpath.normpath(posixpath.join(page_dir, href)) for href in parser.hrefs]
if targets[:2] != ["demo-repo/index.html", "index.html"]:
    raise SystemExit(f"report navigation targets are incorrect: {targets[:2]}")
if targets[2] != "demo-repo/index.html":
    raise SystemExit(f"project provenance target is incorrect: {targets[2]}")
PY

  assert_contains "$project_index" 'Good report task' \
    "project index must contain report row"
  assert_contains "$project_index" 'task-good/report.html' \
    "project index must link to report html"
  assert_contains "$project_index" '../index.html' \
    "project index must link back to root catalog"
  pass "static navigation works cleanly without client-side fetching"
}

test_report_candidate_included_with_backlog_context
test_denylisted_files_never_published
test_superseded_variant_marked_historical
test_report_content_is_sanitized
test_symlinked_report_is_excluded
test_registered_secondmate_is_aggregated
test_unreachable_remote_is_disclosed_not_silently_empty
test_unknown_project_falls_back_to_general
test_persistence_when_worktree_pruned
test_git_repository_initialized_and_committed
test_refresh_commits_only_when_reports_change
test_provenance_carries_intent_and_hides_ephemeral_paths
test_legacy_pages_migrate_with_root_back_link
test_static_navigation_without_client_side_fetch
