#!/usr/bin/env bash
# fm-update-check-cron-install.sh - manage this (main) home's daily update-alert
# cron entry (see fm-update-check-cron.sh and docs/configuration.md "Daily
# update alert").
#
# Usage:
#   fm-update-check-cron-install.sh install [<minute 0-59>]
#   fm-update-check-cron-install.sh status
#   fm-update-check-cron-install.sh uninstall
#
# Guarded to a genuine primary firstmate home (fm-primary-scope-lib.sh): a
# secondmate home refuses install/uninstall rather than touching a user-level
# crontab that is shared by every home running as this OS user.
# The installed line always falls inside the 06:00-06:59 window (hour fixed
# at 6, after the 03:00-03:59 overnight fast-forward window so a freshly
# fast-forwarded clone is never wrongly reported as behind), <minute> picks
# the exact minute, default 15, and is the only knob.
# Idempotent: re-running install replaces this home's own previous entry
# (matched by its unique "# fm-update-check-cron:<home>" marker comment)
# rather than duplicating it. uninstall removes only that marked line, leaving
# every other crontab entry - including another home's, and the overnight
# fast-forward entry - untouched.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

die() { echo "fm-update-check-cron-install: $*" >&2; exit 1; }

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  ''|-h|--help|help) usage; exit 0 ;;
esac

command -v crontab >/dev/null 2>&1 || die "crontab not found; install cron first"

if fm_root_is_secondmate_home "$FM_HOME"; then
  die "$FM_HOME is a secondmate home; this cron is main-home only"
fi
if ! fm_primary_scope_matches "$FM_HOME" "$STATE"; then
  die "$FM_HOME is not a genuine firstmate home"
fi

HOME_ABS=$(cd "$FM_HOME" && pwd -P)
MARKER="# fm-update-check-cron:$HOME_ABS"
CRON_SCRIPT="$FM_ROOT/bin/fm-update-check-cron.sh"

current_crontab() { crontab -l 2>/dev/null || true; }

without_marker() {
  current_crontab | grep -Fv "$MARKER" || true
}

cmd_status() {
  local line
  line=$(current_crontab | grep -F "$MARKER" || true)
  if [ -n "$line" ]; then
    printf 'installed: %s\n' "$line"
  else
    printf 'not installed for %s\n' "$HOME_ABS"
  fi
}

cmd_install() {
  local minute=${1:-15} line new
  case "$minute" in
    ''|*[!0-9]*) die "minute must be 0-59" ;;
  esac
  [ "$minute" -le 59 ] || die "minute must be 0-59"

  line="$minute 6 * * * FM_HOME='$HOME_ABS' '$CRON_SCRIPT' >/dev/null 2>&1 $MARKER"
  new=$( { without_marker; printf '%s\n' "$line"; } )
  printf '%s\n' "$new" | crontab -
  printf 'installed: %s\n' "$line"
}

cmd_uninstall() {
  local new
  new=$(without_marker)
  if [ -z "$new" ]; then
    crontab -r >/dev/null 2>&1 || true
  else
    printf '%s\n' "$new" | crontab -
  fi
  printf 'uninstalled (if it was present) for %s\n' "$HOME_ABS"
}

case "$1" in
  install) shift; cmd_install "$@" ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
