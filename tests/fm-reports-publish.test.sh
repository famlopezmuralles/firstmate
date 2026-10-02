#!/usr/bin/env bash
# Tests for bin/fm-reports-publish.sh and bin/fm-reports-render.py: the
# central report catalog must include genuine worker reports (including a
# supplemental file not literally named report.md), mark a superseded variant
# historical, aggregate a registered local secondmate home, disclose an
# unreachable registered remote home rather than reporting it as empty, and
# never publish a brief/decision/steering file, a symlinked file outside
# data/, or an executable script from report content.
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
    "$main/data/task-link" "$second/data/task-remote-sib"

  snapshot_stub "$main/bin/fm-fleet-snapshot.sh" '[
    {"id":"task-good","structured":true,"title":"Good report task","repo":"demo-repo","pr_url":"https://github.com/example/demo/pull/1","state":"done"},
    {"id":"task-super","structured":true,"title":"Superseded task","repo":"demo-repo","pr_url":"","state":"done"},
    {"id":"task-xss","structured":true,"title":"XSS task","repo":"demo-repo","pr_url":"","state":"in_flight"}
  ]'
  snapshot_stub "$second/bin/fm-fleet-snapshot.sh" '[
    {"id":"task-remote-sib","structured":true,"title":"Sibling home task","repo":"other-repo","pr_url":"","state":"done"}
  ]'

  printf '# Good report\n\nHello world.\n' > "$main/data/task-good/report.md"
  for junk in brief.md launch-brief.md decision.md review-decision.md \
      ship-instructions.md task-note.md intake.md brief-v2.md steer-x.md; do
    printf 'SHOULD_NOT_APPEAR_%s\n' "$junk" > "$main/data/task-good/$junk"
  done

  printf '# Current\n\ncurrent content marker\n' > "$main/data/task-super/report.md"
  printf '# Prior\n\nold content marker\n' > "$main/data/task-super/prior-report.md"

  printf '# XSS <script>alert(1)</script>\n\n[bad](javascript:alert(1))\n' \
    > "$main/data/task-xss/report.md"

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
  [ -f "$root/publish/reports/main/task-good/report.html" ] \
    || fail "task-good/report.html should be written"
  pass "a plain report.md is published with its backlog-derived project and PR"
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
  html_count=$(find "$root/publish/reports/main/task-good" -type f -name '*.html' | wc -l)
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

  [ -f "$root/publish/reports/main/task-super/report.html" ] \
    || fail "the current report.md should still be published"
  [ -f "$root/publish/reports/main/task-super/prior-report.html" ] \
    || fail "the superseded prior-report.md should still be published, not hidden"

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
  page=$(cat "$root/publish/reports/main/task-xss/report.html")

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

  [ ! -e "$root/publish/reports/main/task-link" ] \
    || fail "a symlinked report.md must not be published"
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
  [ -f "$root/publish/reports/second/task-remote-sib/report.html" ] \
    || fail "the secondmate's report page should be written under its own home directory"
  pass "a registered local secondmate home's reports are aggregated into the one catalog"
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

test_report_candidate_included_with_backlog_context
test_denylisted_files_never_published
test_superseded_variant_marked_historical
test_report_content_is_sanitized
test_symlinked_report_is_excluded
test_registered_secondmate_is_aggregated
test_unreachable_remote_is_disclosed_not_silently_empty
