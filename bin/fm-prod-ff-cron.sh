#!/usr/bin/env bash
# fm-prod-ff-cron.sh - early-morning fast-forward-only refresh for every
# registered productive project clone under this (main) home's projects/, run
# from the OS cron rather than a live firstmate session.
#
# All fetch/fast-forward/dirty-copy/stuck-clone logic belongs to
# bin/fm-fleet-sync.sh (AGENTS.md section 2); this script is cron's entrypoint
# on top of it, plus failure alerting and the optional post-update
# restart-and-verify step below. It never stashes, commits, discards, or
# forces anything itself, and neither does fleet-sync.
#
# Guarded to the main (primary) home only: a secondmate home's projects/ is
# never touched here (fm-primary-scope-lib.sh's primary-home predicate).
# Install the schedule with fm-prod-ff-cron-install.sh; see
# docs/configuration.md "Early-morning productive fast-forward" for coverage,
# the restart/verify config schema, and what each alert means.
#
# Any fleet-sync outcome outside its known-benign set (already current,
# synced, recovered, pruned, or a benign skip: local-only, no origin remote,
# not a directory/git repo/clone root) is treated as needing captain
# attention - including every STUCK: dirty/off-default/diverged clone and
# every fetch or fast-forward failure - and reported through
# bin/fm-inbox.sh note so firstmate wakes on it at its next drain. A clean
# run with no configured restarts writes nothing to the inbox.
#
# When config/prod-ff-services.json configures a restart and verify command
# for a project, and fleet-sync actually fast-forwarded that project's local
# copy (never on a no-op "already current"/"recovered: ... (already current)"
# result, and never on a STUCK/dirty copy), this script runs the restart
# command and then the verify command, both with the project's clone as the
# working directory. A restart or verify failure is reported through the same
# inbox alert path. Those commands are read from local, gitignored,
# operator-authored configuration: this script does not itself add any force,
# discard, or recreate semantics, but it also cannot enforce that the
# configured commands avoid them - keep that configuration guarded the same
# way fleet-sync's own fetch/FF-only contract is.
#
# Usage: fm-prod-ff-cron.sh
# Environment: FM_HOME (defaults to this checkout), FM_ROOT_OVERRIDE (tests).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
SERVICES_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/prod-ff-services.json"
export FM_HOME FM_ROOT

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

if fm_root_is_secondmate_home "$FM_HOME"; then
  echo "fm-prod-ff-cron: refusing: $FM_HOME is a secondmate home (this cron is main-home only)" >&2
  exit 1
fi
if ! fm_primary_scope_matches "$FM_HOME" "$STATE"; then
  echo "fm-prod-ff-cron: refusing: $FM_HOME is not a genuine firstmate home" >&2
  exit 1
fi

# Known-benign fleet-sync outcomes: no alert, no restart consideration.
BENIGN_RE='^[^:]+: (already current|synced |recovered:|pruned |skipped: (local-only project|no origin remote|not a directory|not a git repo|not a clone root))'
# Outcomes that actually moved the local default branch forward: restart-eligible.
UPDATED_RE='^([^:]+): (synced |recovered: .*synced )'

OUT=$("$FM_ROOT/bin/fm-fleet-sync.sh" 2>&1)
RC=$?

ALERT_LINES=""
add_alert() {
  ALERT_LINES="${ALERT_LINES}${ALERT_LINES:+$'\n'}$1"
}

[ "$RC" -eq 0 ] || add_alert "fm-fleet-sync.sh exited $RC"

UPDATED_PROJECTS=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    *': '*) ;;
    *) continue ;;
  esac
  if ! printf '%s\n' "$line" | grep -Eq "$BENIGN_RE"; then
    add_alert "$line"
  fi
  if [[ "$line" =~ $UPDATED_RE ]]; then
    UPDATED_PROJECTS="${UPDATED_PROJECTS}${UPDATED_PROJECTS:+$'\n'}${BASH_REMATCH[1]}"
  fi
done <<EOF
$OUT
EOF

# ---- optional per-project restart + verify after a real fast-forward ------

restart_and_verify() {
  local name=$1 clone=$2 restart=$3 verify=$4

  if ! ( cd "$clone" && eval "$restart" ); then
    add_alert "$name: restart failed: $restart"
    return 0
  fi
  if ! ( cd "$clone" && eval "$verify" ); then
    add_alert "$name: restarted but failed to verify: $verify"
  fi
}

if [ -n "$UPDATED_PROJECTS" ] && [ -f "$SERVICES_CONFIG" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    add_alert "prod-ff-services: jq is required to read $SERVICES_CONFIG; no restarts were attempted"
  else
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      entry=$(jq -r --arg n "$name" \
        '.services // [] | map(select(.name == $n)) | .[0] // empty
         | "\(.restart // "")\t\(.verify // "")"' \
        "$SERVICES_CONFIG" 2>/dev/null) || {
        add_alert "$name: prod-ff-services: $SERVICES_CONFIG is not valid JSON; no restarts were attempted"
        continue
      }
      [ -n "$entry" ] || continue
      restart_cmd=${entry%%$'\t'*}
      verify_cmd=${entry#*$'\t'}
      if [ -z "$restart_cmd" ] || [ -z "$verify_cmd" ]; then
        [ -z "$restart_cmd" ] && [ -z "$verify_cmd" ] && continue
        add_alert "$name: prod-ff-services: entry is missing restart or verify; no restart was attempted"
        continue
      fi
      restart_and_verify "$name" "$PROJECTS/$name" "$restart_cmd" "$verify_cmd"
    done <<EOF
$UPDATED_PROJECTS
EOF
  fi
fi

[ -n "$ALERT_LINES" ] || exit 0

MSG=$(printf 'prod-ff: early-morning fast-forward refresh needs attention (home: %s)\n\n%s\n' \
  "$FM_HOME" "$ALERT_LINES")
printf '%s\n' "$MSG" | "$FM_ROOT/bin/fm-inbox.sh" note -
