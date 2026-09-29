#!/usr/bin/env bash
# Install or remove Firstmate's guarded agy (Antigravity CLI) busy-state and
# turn-end hook.
#
# This command is the sole owner of the edit to
# $HOME/.gemini/config/hooks.json (agy's GLOBAL customization root - see
# below for why). install adds or replaces exactly one named hook key
# ("fm-turn-end") without disturbing any other key a captain or another tool
# has placed in that file; remove excises only that key. A file that is not a
# JSON object, or whose "fm-turn-end" key already holds something other than
# what this script would install, is refused without a write.
#
# WHY GLOBAL. agy discovers hooks.json only from two roots: the WORKSPACE
# customization root (`.agents/hooks.json`, walked from cwd to the repo root)
# or the machine-global root (`~/.gemini/config/hooks.json`). There is no
# per-invocation override (checked against `agy --help` and the binary's own
# string table for 1.2.12/1.2.13 - no settings-path flag or ANTIGRAVITY_*/
# GEMINI_* env var names one). Writing the workspace root would mean writing
# into every task's OWN worktree at `.agents/hooks.json`, which - unlike
# Claude's settings.local.json or Gemini's system-settings-path escape hatch -
# is a path a real project may already track for its OWN customizations, so
# firstmate would risk clobbering project configuration on every spawn. The
# global root is therefore the only safe place, exactly the same reasoning
# that puts Grok's and Kimi's turn-end hooks in their own global roots
# (`~/.grok/hooks/`, `~/.kimi-code/config.toml`).
#
# WHY GUARDED. A hook installed at the global root fires for every agy
# conversation this machine ever runs, firstmate-launched or not - including
# the captain's own interactive Antigravity sessions. The installed hook is
# therefore a no-op unless the CURRENT conversation's reported workspace path
# (from the hook payload's `workspacePaths[0]`) holds a `.fm-agy-turnend`
# pointer file naming a token this registry actually issued. That pointer is
# gitignored per-task state (../fm-spawn.sh writes it, ../fm-teardown.sh
# removes it), never a project file, mirroring the exact
# pointer-plus-private-registry shape `fm-kimi-turnend-hook.sh` already uses.
#
# WORKSPACE-PATH CAVEAT (verified live, agy 1.2.13, and the reason the guard
# matters, not just an optimization): a `workspacePaths[0]` reported by ONE
# anomalous invocation, out of roughly a dozen live PreInvocation/Stop
# payloads captured across single, multi-invocation, concurrent-different-
# workspace, and abrupt-kill-then-relaunch scenarios, named the CAPTAIN'S HOME
# DIRECTORY instead of the actual launch cwd; every other capture (including a
# genuine two-workspace concurrency test) was correct. The anomaly was not
# reproduced deliberately and is suspected to follow an abruptly killed prior
# agy process rather than ordinary concurrent use. Because the guard requires
# a REAL pointer file to exist at the reported path, and firstmate never
# places one at $HOME, this class of anomaly can only ever cause one missed
# busy/idle transition (self-correcting at the next event) - never a
# misattributed one, since a match at the wrong task's own worktree would
# require that task's own token, which this registry never had a reason to
# hand to the wrong workspace.
#
# Registry entry format (one file per task, in $HOME/.gemini/config/fm-turn-end.d/,
# named fm.<12-char mktemp suffix>, mode 0600), five lines:
#   busy_event=<absolute path to that task's own bin/fm-busy-event.sh>
#   state=<absolute state directory>
#   id=<task id>
#   gen=<busy-state incarnation token>
#   turnend=<absolute path to state/<id>.turn-ended>
# The busy_event path is recorded per task (not assumed to be a single fixed
# firstmate checkout) because a captain-run firstmate may have more than one
# code root, exactly the reasoning bin/fm-spawn.sh already applies to a
# forked code-root copy.
#
# Usage:
#   fm-agy-turnend-hook.sh install
#   fm-agy-turnend-hook.sh remove
set -u

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,55{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|remove\n' "${0##*/}" >&2
    exit 2
    ;;
esac

if [ -z "${HOME:-}" ]; then
  printf 'fm-agy-turnend-hook: refused: HOME is unset.\n' >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  printf 'fm-agy-turnend-hook: refused: node is required to install this hook.\n' >&2
  exit 1
fi

node - "$ACTION" "$HOME/.gemini/config" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const [ACTION, CONFIG_DIR] = process.argv.slice(2);
const HOOKS_JSON = path.join(CONFIG_DIR, "hooks.json");
const HOOK = path.join(CONFIG_DIR, "fm-turn-end.sh");
const REGISTRY = path.join(CONFIG_DIR, "fm-turn-end.d");
const KEY = "fm-turn-end";
const TOKEN_NAME = /^fm\.[A-Za-z0-9]{12}$/;

const HOOK_BYTES = `#!/usr/bin/env bash
# Firstmate agy busy-state/turn-end hook. Managed by fm-agy-turnend-hook.sh.
# Deliberately passive: every path is silent and always prints valid JSON.
set +e
mode=\${1:-}
case "$mode" in
  busy) safe='{}' ;;
  idle) safe='{"decision":"stop"}' ;;
  *) printf '{}'; exit 0 ;;
esac
payload=
IFS= read -r payload || [ -n "$payload" ] || { printf '%s' "$safe"; exit 0; }
command -v jq >/dev/null 2>&1 || { printf '%s' "$safe"; exit 0; }
workspace=$(jq -er '.workspacePaths[0] // empty' <<< "$payload" 2>/dev/null) || { printf '%s' "$safe"; exit 0; }
pointer="$workspace/.fm-agy-turnend"
[ -f "$pointer" ] || { printf '%s' "$safe"; exit 0; }
first=
IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || { printf '%s' "$safe"; exit 0; }
case "$first" in token=*) token=\${first#token=} ;; *) printf '%s' "$safe"; exit 0 ;; esac
case "$token" in fm.????????????) : ;; *) printf '%s' "$safe"; exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) printf '%s' "$safe"; exit 0 ;; esac
record="\${HOME:-}/.gemini/config/fm-turn-end.d/$token"
[ -n "\${HOME:-}" ] && [ -f "$record" ] || { printf '%s' "$safe"; exit 0; }
busy_event= state= id= gen= turnend=
{
  IFS= read -r l1
  IFS= read -r l2
  IFS= read -r l3
  IFS= read -r l4
  IFS= read -r l5
} < "$record" 2>/dev/null
case "$l1" in busy_event=/*) busy_event=\${l1#busy_event=} ;; esac
case "$l2" in state=/*) state=\${l2#state=} ;; esac
case "$l3" in id=*) id=\${l3#id=} ;; esac
case "$l4" in gen=*) gen=\${l4#gen=} ;; esac
case "$l5" in turnend=/*) turnend=\${l5#turnend=} ;; esac
case "$id" in ''|*[!A-Za-z0-9._-]*) id= ;; esac
case "$gen" in ''|*[!A-Za-z0-9._-]*) gen= ;; esac
if [ -n "$busy_event" ] && [ -n "$state" ] && [ -n "$id" ] && [ -n "$gen" ]; then
  event=pre-invocation
  [ "$mode" = idle ] && event=stop
  "$busy_event" apply "$state" "$id" "$mode" --gen "$gen" --source agy-hook --event "$event" >/dev/null 2>&1 || true
fi
[ "$mode" = idle ] && [ -n "$turnend" ] && touch -- "$turnend" 2>/dev/null
printf '%s' "$safe"
exit 0
`;

const HOOK_ENTRY = {
  PreInvocation: [{ type: "command", command: `bash ${JSON.stringify(HOOK)} busy` }],
  Stop: [{ type: "command", command: `bash ${JSON.stringify(HOOK)} idle` }],
};

function refuse(reason) {
  console.error(`fm-agy-turnend-hook: refused: ${reason}`);
  process.exit(1);
}

function readJsonObject(file, label) {
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (err) {
    if (err.code === "ENOENT") return {};
    throw err;
  }
  if (raw.trim() === "") return {};
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    refuse(`${label} is not valid JSON: ${err.message}`);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    refuse(`${label} is not a JSON object`);
  }
  return parsed;
}

function atomicWrite(file, data, mode) {
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.fm.${unique}`);
  fs.writeFileSync(tmp, data, { mode, flag: "wx" });
  try {
    fs.renameSync(tmp, file);
  } catch (err) {
    fs.rmSync(tmp, { force: true });
    throw err;
  }
}

try {
  if (ACTION === "install") {
    fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
    fs.mkdirSync(REGISTRY, { recursive: true, mode: 0o700 });
    fs.chmodSync(REGISTRY, 0o700);

    let existingHook = null;
    if (fs.existsSync(HOOK)) {
      const st = fs.lstatSync(HOOK);
      if (st.isSymbolicLink() || !st.isFile()) refuse(`'${HOOK}' is not a regular non-symlink file`);
      existingHook = fs.readFileSync(HOOK, "utf8");
    }
    if (existingHook !== HOOK_BYTES) {
      atomicWrite(HOOK, HOOK_BYTES, 0o700);
    } else {
      fs.chmodSync(HOOK, 0o700);
    }

    const root = readJsonObject(HOOKS_JSON, HOOKS_JSON);
    const existingEntry = root[KEY];
    const candidate = JSON.stringify(HOOK_ENTRY);
    if (existingEntry !== undefined && JSON.stringify(existingEntry) !== candidate) {
      refuse(`${HOOKS_JSON} key "${KEY}" already holds unexpected content`);
    }
    if (existingEntry === undefined) {
      root[KEY] = HOOK_ENTRY;
      atomicWrite(HOOKS_JSON, `${JSON.stringify(root, null, 2)}\n`, 0o600);
    }
  } else {
    if (fs.existsSync(HOOKS_JSON)) {
      const root = readJsonObject(HOOKS_JSON, HOOKS_JSON);
      if (root[KEY] !== undefined) {
        if (JSON.stringify(root[KEY]) !== JSON.stringify(HOOK_ENTRY)) {
          refuse(`${HOOKS_JSON} key "${KEY}" holds unexpected content; not removing`);
        }
        delete root[KEY];
        atomicWrite(HOOKS_JSON, `${JSON.stringify(root, null, 2)}\n`, 0o600);
      }
    }
    if (fs.existsSync(HOOK)) {
      const st = fs.lstatSync(HOOK);
      if (st.isSymbolicLink() || !st.isFile()) refuse(`'${HOOK}' is not a regular non-symlink file`);
      if (fs.readFileSync(HOOK, "utf8") !== HOOK_BYTES) {
        refuse(`'${HOOK}' has unexpected content; not removing`);
      }
      fs.unlinkSync(HOOK);
    }
    if (fs.existsSync(REGISTRY)) {
      const st = fs.lstatSync(REGISTRY);
      if (st.isSymbolicLink() || !st.isDirectory()) refuse(`'${REGISTRY}' is not a regular directory`);
      for (const name of fs.readdirSync(REGISTRY)) {
        if (!TOKEN_NAME.test(name)) refuse(`'${REGISTRY}' contains an unexpected entry '${name}'`);
        const childStat = fs.lstatSync(path.join(REGISTRY, name));
        if (childStat.isSymbolicLink() || !childStat.isFile()) {
          refuse(`'${REGISTRY}' contains a non-regular entry '${name}'`);
        }
      }
      for (const name of fs.readdirSync(REGISTRY)) fs.unlinkSync(path.join(REGISTRY, name));
      fs.rmdirSync(REGISTRY);
    }
  }
} catch (err) {
  refuse(`filesystem operation failed: ${err.message}`);
}
NODE
