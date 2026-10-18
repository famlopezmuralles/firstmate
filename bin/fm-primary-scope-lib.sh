#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.
# fm_primary_root_matches is split out so a caller can confirm primary-home
# identity before its gitignored state dir exists, such as to create it.

# Return 0 when $1 carries a genuine secondmate-home marker.
# A pooled worker slot claimed for a task is never a secondmate home, even
# when a retired home's gitignored identity marker is still on disk inside
# it. The claim lives at <pool>/<slot>/.fm-slot-owner, a sibling of the
# checkout written by bin/fm-spawn.sh for crewmate spawns and never for
# secondmate homes (which lease their slot instead), so its presence proves
# a worker owns this slot.
fm_root_claimed_as_worker_slot() {
  local root=$1 slot marker line task=
  slot=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd -P) || return 1
  slot=$(dirname "$slot")
  marker="$slot/.fm-slot-owner"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in task=*) task=${line#task=} ;; esac
  done < "$marker" 2>/dev/null || return 1
  [ -n "$task" ]
}

fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  # A worker session never owns a home: FM_TASK_ID is exported only for ship
  # and scout launches, never for a secondmate or primary session.
  [ -z "${FM_TASK_ID:-}" ] || return 1
  # A retired secondmate home's gitignored marker survives `treehouse return`
  # inside its pooled slot; the next worker that claims the slot must not
  # inherit its identity.
  fm_root_claimed_as_worker_slot "$1" && return 1
  return 0
}

# Return 0 when $1 is a genuine primary root, regardless of whether its state
# dir exists yet. A valid secondmate marker force-includes a linked secondmate
# home. Otherwise only a plain checkout is primary, never a linked task
# worktree.
fm_primary_root_matches() {
  local root=$1 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
}

# Return 0 when $1 is a genuine primary root whose effective state dir $2
# already exists.
fm_primary_scope_matches() {
  local root=$1 state=$2
  fm_primary_root_matches "$root" && [ -d "$state" ]
}
