#!/usr/bin/env bash
# fm-update-check-cron.sh - daily check-only alert naming every repository that
# is behind its origin: firstmate itself, no-mistakes, and any other
# git-backed tool source registered in config/watched-tools.json (the same
# registry fm-tool-update-check.sh already reads; firstmate's own entry there
# is what covers firstmate - nothing here is hardcoded to a particular
# checkout path), plus every registered productive project clone under this
# (main) home's projects/, run from the OS cron rather than a live firstmate
# session.
#
# This is the read-only sibling of fm-prod-ff-cron.sh: that cron fetches and
# fast-forwards a clean clone overnight; this one only reports, even on a
# clean clone, and never fast-forwards, stashes, commits, discards, or forces
# anything. It reuses bin/fm-fleet-sync.sh's own "--check-only" mode (added
# alongside this script) for every comparison, so project-clone coverage is
# exactly what fm-prod-ff-cron.sh already syncs - the two walk the identical
# candidate enumeration and local-only/no-origin/not-a-clone-root skip rules
# and can never disagree about which copies are covered.
#
# A watched-tools.json entry with no "git" field (no-mistakes today, since its
# install here is a built binary with no local git clone, plus herdr,
# treehouse, and the axi tools) has no local clone for this comparison and is
# left entirely to its own existing owner, bin/fm-tool-update-check.sh, which
# detects a published update by version/announcement instead. This script
# never duplicates that mechanism; it only adds git-clone coverage.
#
# Guarded to the main (primary) home only, exactly like fm-prod-ff-cron.sh: a
# secondmate home's projects/ is never touched here
# (fm-primary-scope-lib.sh's primary-home predicate).
# Install the schedule with fm-update-check-cron-install.sh; see
# docs/configuration.md "Daily update alert" for coverage and schedule.
#
# A clean run (every repository already current, or a benign skip: local-only,
# no origin remote, not a directory/git repo/clone root) writes nothing to the
# inbox. Any clone reported "N commits behind <base>" or "STUCK: ..." by
# --check-only is collected into exactly one consolidated bin/fm-inbox.sh note
# so firstmate wakes on it at its next drain.
#
# Usage: fm-update-check-cron.sh
# Environment: FM_HOME (defaults to this checkout), FM_ROOT_OVERRIDE (tests).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WATCHED_TOOLS="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/watched-tools.json"
export FM_HOME FM_ROOT

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

if fm_root_is_secondmate_home "$FM_HOME"; then
  echo "fm-update-check-cron: refusing: $FM_HOME is a secondmate home (this check is main-home only)" >&2
  exit 1
fi
if ! fm_primary_scope_matches "$FM_HOME" "$STATE"; then
  echo "fm-update-check-cron: refusing: $FM_HOME is not a genuine firstmate home" >&2
  exit 1
fi

FLEET_SYNC="$FM_ROOT/bin/fm-fleet-sync.sh"

# --check-only outcomes that need captain attention: a quantified behind count
# or a STUCK clone. Every other outcome (already current, or a benign skip)
# matches fm-prod-ff-cron.sh's own benign set and stays silent.
BEHIND_RE='^[^:]+: ([0-9]+ commits behind|STUCK:)'

ALERT_LINES=""
add_alert() {
  ALERT_LINES="${ALERT_LINES}${ALERT_LINES:+$'\n'}$1"
}

# Paths already checked (by realpath), so a git-backed tool source that
# happens to also live under projects/ is never reported twice.
SEEN_PATHS=""
already_seen() {
  local abs=$1
  case " $SEEN_PATHS " in
    *" $abs "*) return 0 ;;
    *) return 1 ;;
  esac
}
mark_seen() {
  SEEN_PATHS="${SEEN_PATHS}${SEEN_PATHS:+ }$1"
}

# collect_named <display-name> <repo-path> <remote> <branch>: run --check-only
# against one explicit repo, honoring its configured remote/branch override
# (docs/configuration.md's watched-tools.json schema: remote defaults to
# "origin", branch defaults to that remote's own default branch), and relabel
# its output lines with <display-name> rather than the raw path
# fm-fleet-sync.sh's single-project form would otherwise print.
collect_named() {
  local name=$1 path=$2 remote=$3 branch=$4 abs out line display
  [ -d "$path" ] || return 0
  abs=$(cd "$path" 2>/dev/null && pwd -P) || return 0
  already_seen "$abs" && return 0
  mark_seen "$abs"

  out=$("$FLEET_SYNC" --check-only "$path" "$remote" "$branch" 2>/dev/null)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$path: "*) display="$name: ${line#"$path: "}" ;;
      *) display=$line ;;
    esac
    case "$display" in *': '*) ;; *) continue ;; esac
    if printf '%s\n' "$display" | grep -Eq "$BEHIND_RE"; then
      add_alert "$display"
    fi
  done <<EOF
$out
EOF
}

# collect_fleet: every registered productive project clone under projects/,
# via the whole-fleet form - identical inventory to fm-prod-ff-cron.sh.
collect_fleet() {
  local out line
  out=$("$FLEET_SYNC" --check-only 2>/dev/null)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *': '*) ;;
      *) continue ;;
    esac
    if printf '%s\n' "$line" | grep -Eq "$BEHIND_RE"; then
      add_alert "$line"
    fi
  done <<EOF
$out
EOF
}

# Every git-backed tool source registered in config/watched-tools.json (local,
# gitignored; AGENTS.md section 2) - this is where firstmate's own entry lives
# in a real home, checked the same way as any other clone. Only entries that
# name a git source are relevant here - a command-only entry (no-mistakes
# today, herdr, treehouse, the axi tools) has no local clone for this
# comparison and is left to its own existing update check
# (bin/fm-tool-update-check.sh).
if [ -f "$WATCHED_TOOLS" ] && command -v jq >/dev/null 2>&1; then
  while IFS=$'\t' read -r name repo remote branch; do
    [ -n "$name" ] && [ -n "$repo" ] || continue
    collect_named "$name" "$repo" "$remote" "$branch"
  done < <(jq -r '.tools[]? | select(.git.repo != null) |
    "\(.name)\t\(.git.repo)\t\(.git.remote // "origin")\t\(.git.branch // "")"' \
    "$WATCHED_TOOLS" 2>/dev/null)
fi

# Every registered productive project clone under projects/.
collect_fleet

[ -n "$ALERT_LINES" ] || exit 0

MSG=$(printf 'update-check: the following repositories are behind their origin (home: %s)\n\n%s\n' \
  "$FM_HOME" "$ALERT_LINES")
printf '%s\n' "$MSG" | "$FM_ROOT/bin/fm-inbox.sh" note -
