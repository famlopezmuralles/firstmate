#!/usr/bin/env bash
# Pre-register agy's (Antigravity CLI) workspace trust for the isolated task
# worktree a ship/scout spawn is about to launch an agy crewmate into, so the
# worker reaches its brief instead of sitting at the workspace-trust dialog.
#
# Usage: fm-agy-trust.sh <worktree> <project>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Interactive agy (`-i`/`--prompt-interactive`, the mode a
# supervised crewmate pane uses) gates a folder it has never seen behind a
# "Do you trust the contents of this project?" dialog, and no CLI flag or
# environment variable suppresses it (checked against `agy --help` and the
# binary's own string table for 1.2.12/1.2.13 - no ANTIGRAVITY_* or GEMINI_*
# skip-trust control exists, unlike gemini's GEMINI_CLI_TRUST_WORKSPACE).
# Every fresh task worktree therefore hits it. Registering the trust before
# launch is the only control that reaches an interactive pane deterministically;
# this script's caller refuses the spawn rather than launch a worker that would
# sit at the dialog, exactly like fm-claude-trust.sh.
#
# UNLIKE CLAUDE, agy's dialog defaults to the SAFE choice ("Yes, I trust this
# folder" is preselected; verified live, agy 1.2.13), so an Enter keypress from
# firstmate's steering plane would not be destructive here the way it is for
# Claude's default-to-exit dialog. This script still exists because a spawn
# should not depend on a human or a watcher answering a dialog at all: it makes
# every fresh worktree launch dialog-free from the first frame.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, and it is STRUCTURAL rather than a
# path policy - identical rationale and mechanics to fm-claude-trust.sh's
# worktree/project verification (read that header for the full reasoning on
# treehouse vs Orca worktree shapes). <worktree> must be a LINKED git worktree
# - its own git dir, sharing <project>'s common dir - whose top level is
# exactly the resolved argument.
#
# Only the launching user's own store is written:
# $HOME/.gemini/antigravity-cli/settings.json's flat `trustedWorkspaces` string
# array (verified live: agy itself writes this exact shape when a captain
# accepts the dialog by hand, 2-space pretty JSON, trailing newline, mode 600).
# There is no per-invocation override for this path (checked: no
# ANTIGRAVITY_HOME-style variable and no --settings/--config flag), so unlike
# fm-claude-trust.sh there is no CLAUDE_CONFIG_DIR-equivalent to forward or
# validate - the store location is exactly $HOME/.gemini/antigravity-cli
# regardless of environment.
set -u
# See fm-claude-trust.sh for why this whole class is cleared once here: CDPATH
# would redirect a relative `cd` operand, and an inherited git override could
# make a primary checkout misreport itself as a linked worktree.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

[ "$#" -eq 2 ] || { echo "usage: fm-agy-trust.sh <worktree> <project>" >&2; exit 2; }
WT_ARG=$1
PROJ_ARG=$2

refuse() { echo "error: refusing to pre-register agy trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

[ -n "${HOME:-}" ] || refuse "HOME is not set, so agy's trust store cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"

[ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has an unresolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"

CONFIG_DIR="$HOME_REAL/.gemini/antigravity-cli"
if [ ! -d "$CONFIG_DIR" ]; then
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
fi
[ -d "$CONFIG_DIR" ] || refuse "agy config directory '$CONFIG_DIR' does not exist and could not be created"

STORE="$CONFIG_DIR/settings.json"
if [ -L "$STORE" ]; then
  STORE_REAL=$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$STORE" 2>/dev/null) || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write, then read back and confirm, exactly like
# fm-claude-trust.sh: agy itself can rewrite this file (a captain answering
# the dialog by hand, or another concurrent spawn), so the bytes read are
# fingerprinted and re-checked immediately before the rename, and a store that
# moved is retried once rather than clobbered.
if ! node - "$STORE" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, worktree] = process.argv.slice(2);
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) =>
  buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (root.trustedWorkspaces === undefined) root.trustedWorkspaces = [];
  const list = root.trustedWorkspaces;
  if (!Array.isArray(list)) {
    throw new Error(`${store} has a non-array "trustedWorkspaces" value`);
  }
  if (!list.includes(worktree)) list.push(worktree);
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.settings.json.fm-trust.${unique}`);
  // Two-space pretty-printed with a trailing newline: the format agy itself
  // writes when a captain accepts the dialog by hand (verified live, 1.2.13).
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = JSON.parse(fs.readFileSync(store, "utf8"));
  return Array.isArray(back.trustedWorkspaces) && back.trustedWorkspaces.includes(worktree) ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain trust for ${worktree} after 3 attempts`);
process.exit(1);
NODE
then
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

echo "trusted: $WT_REAL"
