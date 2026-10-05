#!/usr/bin/env bash
# fm-reports-publish.sh - centralize worker reports into one local HTML catalog.
#
# Usage:
#   fm-reports-publish.sh [publish]
#   fm-reports-publish.sh setup-apache
#   fm-reports-publish.sh install-cron
#
# `publish` (the default) is the recurring refresh: it scans this home's own
# data/ tree and every registered secondmate home for worker reports, enriches
# each with backlog context through bin/fm-fleet-snapshot.sh (never a second
# backlog parser), and hands a discovery manifest to fm-reports-render.py, which
# organizes published reports by project under the publish root (persisting only
# sanitized HTML), generates static project index.html and root index.html
# pages without client-side fetching, and commits the results to a Git
# repository inside FM_REPORTS_PUBLISH_ROOT (default $HOME/reports-published)
# only when a refresh changes a published report. It preserves existing
# published reports across worktree cleanup and never writes into a project or
# another home's data.
#
# `setup-apache` and `install-cron` are one-time, explicit, privileged/system
# steps kept out of the recurring refresh: the former writes a local-only
# /reports Apache conf (never `Require all granted`) and gracefully reloads
# Apache via `sudo systemctl reload apache2`; the latter adds an idempotent
# per-user crontab line that invokes this command's own `publish` action.
# Neither mutates any project or other Firstmate home.
#
# A local secondmate home is read directly from its own data/ tree (same
# filesystem, same user, read-only). The one remote-host route in
# data/secondmates.md is read through the existing bounded transport,
# bin/fm-on.sh plus bin/fm-remote-file.sh, and only for its literal
# data/<id>/report.md files (scout_report_lines' own filesystem scan on that
# host); a remote home's supplemental, non-report.md reports are a disclosed
# limitation, not silently skipped, because there is no remote directory
# listing primitive narrow enough to add safely here.
#
# A report candidate is any *.md file directly inside a home's data/<id>/
# directory except the fixed deny-list below (briefs, launch instructions,
# captain-hold decision records, and firstmate-authored steering notes), and
# except a non-regular-file (symlink) entry. Superseded variants (a filename
# containing "prior" or "before") are still published, marked historical.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
PUBLISH_ROOT="${FM_REPORTS_PUBLISH_ROOT:-$HOME/reports-published}"
SNAPSHOT_TIMEOUT="${FM_REPORTS_SNAPSHOT_TIMEOUT:-20}"
REMOTE_TIMEOUT="${FM_REPORTS_REMOTE_TIMEOUT:-25}"
MAX_REMOTE_BYTES="${FM_REPORTS_MAX_REMOTE_BYTES:-262144}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

die() { printf 'fm-reports-publish: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

ACTION=${1:-publish}
case "$ACTION" in
  publish|setup-apache|install-cron) ;;
  -h|--help) usage ;;
  *) usage ;;
esac

command -v jq >/dev/null 2>&1 || die "jq not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v git >/dev/null 2>&1 || die "git not found"

WORK_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-reports-publish.XXXXXX") || die "could not create scratch directory"
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

HOME_JSON_FILES=()
UNAVAILABLE_FILE="$WORK_DIR/unavailable.jsonl"
: > "$UNAVAILABLE_FILE"

note_unavailable() {  # <home-id> <reason>
  jq -n --arg home "$1" --arg reason "$2" '{home:$home,reason:$reason}' >> "$UNAVAILABLE_FILE"
}

# A home or task id must be a plain path-safe token: it becomes a directory
# name under the publish root, so anything else is refused rather than
# escaped or guessed at.
is_safe_component() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_denied_report_name() {  # <basename>
  case "$1" in
    brief.md|launch-brief.md|decision.md|review-decision.md|ship-instructions.md|task-note.md|intake.md) return 0 ;;
    brief-*.md|steer-*.md) return 0 ;;
    *) return 1 ;;
  esac
}

is_historical_name() {  # <filename-stem, lowercased by caller>
  case "$1" in
    *prior*|*before*) return 0 ;;
    *) return 1 ;;
  esac
}

mtime_iso() {  # <path>
  local epoch
  epoch=$(stat -c %Y "$1" 2>/dev/null) || epoch=$(stat -f %m "$1" 2>/dev/null) || return 1
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

epoch_iso() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf 'unknown (remote)'
}

# Backlog context for one task id, read from an already-captured
# fm-fleet-snapshot.sh --json file. Never a second parser: this only asks the
# one authoritative snapshot for the fields it already extracted.
backlog_context() {  # <snapshot-json-file> <task-id>
  jq -r --arg id "$2" '
    (.backlog.records[]? | select(.id == $id)) as $r
    | [($r.title // ""), ($r.repo // ""), ($r.pr_url // ""), ($r.state // "")] | join("\u001f")
  ' "$1" 2>/dev/null | head -1
}

# The "Captain's intent" section of a task's brief (its own ask, never a
# parser of the brief beyond that one section). Empty when there is no brief.
captain_intent() {  # <brief-path>
  [ -f "$1" ] || return 0
  awk '/^## Captain.s intent/ { inside = 1; next } /^## |^# / { inside = 0 } inside' "$1"
}

meta_value() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

report_entry_json() {  # <task_id> <filename> <content_path> <title> <project> <pr_url> <state> <mtime> <historical> <intent> <model> <effort>
  jq -n \
    --arg task_id "$1" --arg filename "$2" --arg content_path "$3" \
    --arg title "$4" --arg project "$5" --arg pr_url "$6" --arg state "$7" --arg mtime "$8" \
    --argjson historical "$9" --arg intent "${10}" --arg model "${11}" --arg effort "${12}" \
    '{task_id:$task_id,filename:$filename,content_path:$content_path,
      title:(if $title == "" then null else $title end),
      project:(if $project == "" then null else $project end),
      pr_url:(if $pr_url == "" then null else $pr_url end),
      backlog_state:(if $state == "" then null else $state end),
      intent:(if $intent == "" then null else $intent end),
      model:(if $model == "" or $model == "-" then null else $model end),
      thinking_effort:(if $effort == "" or $effort == "-" then null else $effort end),
      mtime:$mtime,historical:$historical}'
}

# Discover one local home: run its own fm-fleet-snapshot.sh for backlog
# context, then scan data/<task>/*.md directly (same filesystem, read-only)
# for report candidates past the deny-list.
discover_local_home() {  # <id> <label> <home_path>
  local id=$1 label=$2 home_path=$3
  local snapshot_json="$WORK_DIR/$id.snapshot.json" out_file="$WORK_DIR/$id.home.json"
  local reports_file="$WORK_DIR/$id.reports.jsonl"
  : > "$reports_file"

  if ! is_safe_component "$id"; then
    note_unavailable "$id" "home id is not a safe path component"
    return 0
  fi
  if [ ! -x "$home_path/bin/fm-fleet-snapshot.sh" ]; then
    note_unavailable "$label" "fm-fleet-snapshot.sh not found at $home_path/bin"
    return 0
  fi

  if ! fm_run_timed "$SNAPSHOT_TIMEOUT" env FM_ROOT_OVERRIDE="$home_path" FM_HOME="$home_path" \
      "$home_path/bin/fm-fleet-snapshot.sh" --json > "$snapshot_json" 2>"$WORK_DIR/$id.snapshot.err"; then
    note_unavailable "$label" "fm-fleet-snapshot.sh --json failed or timed out: $(head -c 200 "$WORK_DIR/$id.snapshot.err" 2>/dev/null)"
    : > "$snapshot_json"
    printf '{}\n' > "$snapshot_json"
  fi

  local data_dir="$home_path/data" task_dir task_id file base stem title project pr_url state mtime historical model effort
  [ -d "$data_dir" ] || { note_unavailable "$label" "data directory not found: $data_dir"; return 0; }

  while IFS= read -r file; do
    task_dir=$(dirname "$file")
    task_id=$(basename "$task_dir")
    base=$(basename "$file")
    is_safe_component "$task_id" || continue
    is_denied_report_name "$base" && continue
    stem=${base%.md}
    is_safe_component "$stem" || continue
    mtime=$(mtime_iso "$file") || mtime="unknown"
    historical=false
    is_historical_name "$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]')" && historical=true
    IFS=$'\x1f' read -r title project pr_url state < <(backlog_context "$snapshot_json" "$task_id" || printf '\x1f\x1f\x1f\n')
    model=$(meta_value "$home_path/state/$task_id.meta" model)
    effort=$(meta_value "$home_path/state/$task_id.meta" effort)
    report_entry_json "$task_id" "$base" "$file" "$title" "$project" "$pr_url" "$state" "$mtime" "$historical" \
      "$(captain_intent "$task_dir/brief.md")" "$model" "$effort" >> "$reports_file"
  done < <(
    find "$data_dir" -mindepth 2 -maxdepth 2 -type f -name '*.md' \
      -not -path "$data_dir/handoff/*" -not -path "$data_dir/remote-secondmates/*" 2>/dev/null | sort
  )

  jq -n --arg id "$id" --arg label "$label" --slurpfile reports "$reports_file" \
    '{id:$id,label:$label,remote:false,reports:$reports}' > "$out_file"
  HOME_JSON_FILES+=("$out_file")
}

# Discover the one remote-host route through bin/fm-on.sh: run the remote
# home's own fm-fleet-snapshot.sh --json over the bounded transport for
# backlog context and its real filesystem-scanned scout_reports[] (literal
# report.md only), then fetch each report's bytes the same bounded way.
discover_remote_home() {  # <id> <label>
  local id=$1 label=$2
  local snapshot_json="$WORK_DIR/$id.snapshot.json" out_file="$WORK_DIR/$id.home.json"
  local reports_file="$WORK_DIR/$id.reports.jsonl"
  : > "$reports_file"

  if ! is_safe_component "$id"; then
    note_unavailable "$id" "home id is not a safe path component"
    return 0
  fi

  local rc=0
  fm_run_timed "$REMOTE_TIMEOUT" "$FM_ROOT/bin/fm-on.sh" "$id" fm-fleet-snapshot.sh --json \
    < /dev/null > "$snapshot_json" 2>"$WORK_DIR/$id.snapshot.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 255 ]; then
      note_unavailable "$label" "remote transport unavailable (ssh exit 255)"
    elif [ "$rc" -eq 124 ]; then
      note_unavailable "$label" "remote fm-fleet-snapshot.sh timed out"
    else
      note_unavailable "$label" "remote fm-fleet-snapshot.sh failed (exit $rc): $(head -c 200 "$WORK_DIR/$id.snapshot.err" 2>/dev/null)"
    fi
    return 0
  fi

  local task_id base stem title project pr_url state model effort intent mtime epoch brief_dest rc2
  while IFS=$'\t' read -r task_id; do
    [ -n "$task_id" ] || continue
    is_safe_component "$task_id" || continue
    base=report.md
    stem=report
    local dest="$WORK_DIR/remote-$id-$task_id-report.md"
    rc2=0
    fm_run_timed "$REMOTE_TIMEOUT" "$FM_ROOT/bin/fm-on.sh" "$id" fm-remote-file.sh get \
      "data/$task_id/report.md" "$MAX_REMOTE_BYTES" < /dev/null > "$dest" 2>"$WORK_DIR/$id.$task_id.fetch.err" || rc2=$?
    if [ "$rc2" -ne 0 ]; then
      note_unavailable "$label: $task_id/report.md" "fetch failed (exit $rc2): $(head -c 160 "$WORK_DIR/$id.$task_id.fetch.err" 2>/dev/null)"
      continue
    fi
    IFS=$'\x1f' read -r title project pr_url state < <(backlog_context "$snapshot_json" "$task_id" || printf '\x1f\x1f\x1f\n')
    local meta_dest="$WORK_DIR/remote-$id-$task_id.meta"
    model="" effort=""
    if fm_run_timed "$REMOTE_TIMEOUT" "$FM_ROOT/bin/fm-on.sh" "$id" fm-remote-file.sh get \
      "state/$task_id.meta" 16384 < /dev/null > "$meta_dest" 2>/dev/null; then
      model=$(meta_value "$meta_dest" model)
      effort=$(meta_value "$meta_dest" effort)
    fi
    brief_dest="$WORK_DIR/remote-$id-$task_id-brief.md"
    intent="unknown (remote)"
    if fm_run_timed "$REMOTE_TIMEOUT" "$FM_ROOT/bin/fm-on.sh" "$id" fm-remote-file.sh get \
      "data/$task_id/brief.md" 65536 < /dev/null > "$brief_dest" 2>/dev/null; then
      intent=$(captain_intent "$brief_dest")
      [ -n "$intent" ] || intent="unknown (remote)"
    fi
    epoch=$(jq -r --arg id "$task_id" '.scout_reports[] | select(.id == $id) | .mtime_epoch // empty' "$snapshot_json" 2>/dev/null | head -1)
    mtime="unknown (remote)"
    case "$epoch" in *[!0-9]*|'') ;; *) mtime=$(epoch_iso "$epoch") ;; esac
    report_entry_json "$task_id" "$base" "$dest" "$title" "$project" "$pr_url" "$state" "$mtime" false "$intent" "$model" "$effort" \
      >> "$reports_file"
  done < <(jq -r '.scout_reports[]?.id // empty' "$snapshot_json" 2>/dev/null)

  jq -n --arg id "$id" --arg label "$label" --slurpfile reports "$reports_file" \
    '{id:$id,label:$label,remote:true,reports:$reports}' > "$out_file"
  HOME_JSON_FILES+=("$out_file")
}

do_publish() {
  local owned_path
  discover_local_home main "main" "$FM_HOME"

  if [ -f "$REG" ] && [ ! -L "$REG" ]; then
    while IFS= read -r line; do
      case "$line" in "- "*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" || continue
      if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
        discover_remote_home "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_ID"
      else
        discover_local_home "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME"
      fi
    done < "$REG"
  else
    note_unavailable "secondmates registry" "data/secondmates.md is absent or unsafe; only this home's own reports were scanned"
  fi

  local homes_array="$WORK_DIR/homes.json" unavailable_array="$WORK_DIR/unavailable.json"
  if [ "${#HOME_JSON_FILES[@]}" -gt 0 ]; then
    jq -s '.' "${HOME_JSON_FILES[@]}" > "$homes_array"
  else
    printf '[]' > "$homes_array"
  fi
  jq -s '.' "$UNAVAILABLE_FILE" > "$unavailable_array" 2>/dev/null || printf '[]' > "$unavailable_array"

  jq -n \
    --slurpfile homes "$homes_array" \
    --slurpfile unavailable "$unavailable_array" \
    --argjson limitations '["Remote homes (reached only through the registered SSH route) are discovered through their own literal data/<task>/report.md files only; supplemental non-report.md reports on a remote home are not mirrored here."]' \
    '{schema:"fm-reports-manifest.v1",homes:$homes[0],unavailable:$unavailable[0],limitations:$limitations}' \
    > "$WORK_DIR/manifest.json"

  mkdir -p "$PUBLISH_ROOT" || die "could not create publish root: $PUBLISH_ROOT"
  chmod 755 "$PUBLISH_ROOT" 2>/dev/null || true

  if [ ! -d "$PUBLISH_ROOT/.git" ]; then
    git -C "$PUBLISH_ROOT" init -q || die "could not initialize git repository in $PUBLISH_ROOT"
  fi

  local -a owned_paths=(index.html catalog.json)
  if [ -f "$PUBLISH_ROOT/catalog.json" ]; then
    while IFS= read -r owned_path; do
      [ -n "$owned_path" ] && owned_paths+=("$owned_path")
    done < <(jq -r '.reports[]?.html_path | select(type == "string") | select(test("^[A-Za-z0-9._/-]+\\.html$")) | select((split("/") | all(. != "" and . != "." and . != "..")))' "$PUBLISH_ROOT/catalog.json")
  fi
  if [ ! -f "$PUBLISH_ROOT/.gitignore" ]; then
    cat > "$PUBLISH_ROOT/.gitignore" <<'EOF'
# Temporary and editor files
*.tmp
*.tmp.*
*.log
.DS_Store
*~
EOF
    owned_paths+=(.gitignore)
  fi

  python3 "$SCRIPT_DIR/fm-reports-render.py" "$PUBLISH_ROOT" < "$WORK_DIR/manifest.json"

  while IFS= read -r owned_path; do
    [ -n "$owned_path" ] && owned_paths+=("$owned_path")
  done < <(jq -r '.reports[] | .html_path, (.project + "/index.html")' "$PUBLISH_ROOT/catalog.json" | sort -u)

  git -C "$PUBLISH_ROOT" add -A -- "${owned_paths[@]}"
  if ! git -C "$PUBLISH_ROOT" diff --cached --quiet -- "${owned_paths[@]}"; then
    local commit_date
    commit_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    git -C "$PUBLISH_ROOT" \
      -c user.name="Firstmate" \
      -c user.email="firstmate@local" \
      commit -q -m "publish: refresh report catalog $commit_date" \
      -- "${owned_paths[@]}" \
      || die "could not commit published reports in $PUBLISH_ROOT"
  fi
}

do_setup_apache() {
  local conf_name=reports.conf
  local conf_src="$WORK_DIR/$conf_name"
  cat > "$conf_src" <<EOF
# Serve a centralized, read-only catalog of Firstmate worker reports at
# http://<host>/reports. Local-machine access only - never Require all granted.
# Managed by bin/fm-reports-publish.sh setup-apache; re-run that command to
# reapply after an edit.

Alias /reports $PUBLISH_ROOT

<Directory $PUBLISH_ROOT>
    Options Indexes FollowSymLinks
    AllowOverride None
    Require local
</Directory>

IndexOptions +FancyIndexing +SuppressHTMLPreamble
EOF
  [ -d "$PUBLISH_ROOT" ] || mkdir -p "$PUBLISH_ROOT"
  sudo cp -- "$conf_src" "/etc/apache2/conf-available/$conf_name" \
    || die "could not install /etc/apache2/conf-available/$conf_name"
  sudo cp -- "$conf_src" "/etc/apache2/conf-enabled/$conf_name" \
    || die "could not install /etc/apache2/conf-enabled/$conf_name"
  sudo systemctl reload apache2 \
    || die "apache2 reload failed; the previous working configuration remains active, check 'sudo systemctl status apache2'"
  printf 'fm-reports-publish: /reports is configured for local-only access and apache2 was reloaded.\n'
}

do_install_cron() {
  local publish_cmd marker line
  publish_cmd="$FM_ROOT/bin/fm-reports-publish.sh publish"
  marker="# fm-reports-publish (managed; do not hand-edit this line)"
  line="*/15 * * * * $publish_cmd >> $HOME/.fm-reports-publish.log 2>&1 $marker"
  if crontab -l 2>/dev/null | grep -qxF "$line"; then
    printf 'fm-reports-publish: cron entry already present.\n'
    return 0
  fi
  { crontab -l 2>/dev/null | grep -vF "$marker"; printf '%s\n' "$line"; } | crontab -
  printf 'fm-reports-publish: installed a 15-minute cron refresh: %s\n' "$line"
}

case "$ACTION" in
  publish) do_publish ;;
  setup-apache) do_setup_apache ;;
  install-cron) do_install_cron ;;
esac
