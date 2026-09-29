# agy (Antigravity CLI)

Google's `agy` TUI, the successor to gemini-cli, verified end to end on 2026-09-29 with agy 1.2.13 on Linux.
Launch shape: `agy --dangerously-skip-permissions -i "$(cat <brief>)"`, after `../../../../../bin/fm-agy-trust.sh` pre-registers the worktree.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because it has no primary supervision protocol.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Semantic `agy-hook`: a machine-global `PreInvocation` hook opens a turn, `Stop` closes it. Guarded per task by a worktree pointer plus a private registry - see Worker busy state below. |
| Turn end | The global `Stop` hook's command touches `state/<id>.turn-ended` after applying the idle event. No hook fires on a manual `Escape` interrupt (verified live), the same limitation Claude has. |
| Exit | `/quit`, one Enter, verified to end the process cleanly (confirmed via an exit marker written after the command in the same shell invocation - a naive check can race the dying tmux server). |
| Interrupt | Single `Escape`, prints `Interrupted · What should Antigravity CLI do instead?` and returns to the idle `? for shortcuts` footer with an empty composer - no clear key needed. |
| Skill | `/`-commands exist (for example `/fork`, `/resume`); exact submit mechanics UNVERIFIED. |
| Autonomy | `--dangerously-skip-permissions`, verified live in BOTH print mode and interactive mode (`-i`): a Bash-then-Read tool pair ran with no permission prompt. Blast radius exceeds the worktree - see the caution below. |
| Marker | `ANTIGRAVITY_AGENT=1` on child/tool processes, own child marker only (agy never sets it on itself). agy clears NEITHER an inherited `CLAUDECODE` nor `CURSOR_AGENT` from its own tool children. |
| Resume | `--continue` / `-c` (most recent conversation) and `--conversation <id>` exist per `--help`; not exercised through a crewmate pane. |
| Model | `--model <slug>`, discovered via `agy models` (14 entries live: `gemini-3.8-flash-{high,medium,low}`, `gemini-3.7-flash-*`, `gemini-3.6-flash-*`, `gemini-3.1-pro-{high,low}`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium`). Unknown model fails loud (exit 1, no silent fallback). |
| Effort | `--effort low\|medium\|high` on the installed default model (gemini-3.8-flash); `--help` also lists `max`, but it was verified live to error against that model (`gemini-3.8-flash has no "max" effort`), so `xhigh`/`max` are omitted in `fm-spawn.sh` rather than passed unverified - the model may vary per slug, not re-verified per model. |

## Trust dialog, and why the fix differs from Claude's and Gemini's

Interactive agy (`-i`/`--prompt-interactive`, the mode a crewmate pane uses) gates a folder it has never seen behind `Do you trust the contents of this project?`, with choices `Yes, I trust this folder` (preselected) and `No, exit`.
No CLI flag or environment variable suppresses it - checked against `agy --help` and the installed binary's own string table for 1.2.12/1.2.13, and unlike gemini's `GEMINI_CLI_TRUST_WORKSPACE=true` or Claude's absence of any per-invocation override, agy has neither.

Unlike Claude, agy's default choice is the SAFE one, matching gemini's dialog rather than Claude's.
`../../../../../bin/fm-agy-trust.sh` still refuses the spawn on a failed registration rather than launch into an unattended dialog: the mechanism it uses is a flat `trustedWorkspaces` string array in `$HOME/.gemini/antigravity-cli/settings.json` (verified live: accepting the dialog by hand appends the exact absolute path there, 2-space pretty JSON, trailing newline, mode 600), and pre-seeding the worktree's exact path before launch was verified to suppress the dialog entirely on the next launch.
The script's own header carries the full structural scope-test reasoning, identical to `fm-claude-trust.sh`'s.

## Blast-radius caution (unchanged from the scout finding)

Under `--dangerously-skip-permissions`, a benign prompt was observed running well beyond its own worktree: reading sibling scratch files, `cat`-ing `/proc/<pid>/environ` and `/proc/<pid>/cmdline` for other processes, and grepping across the whole firstmate checkout it could locate via its own cmdline.
Nothing destructive was observed, but the reach is real.
Never treat this flag as scoped to the task worktree; prefer scoped `permissions.allow` rules (`command(...)`, `read_file`, etc. in agy's `settings.json`) over the blanket flag where a task's risk profile calls for it - out of scope for this adapter's initial verification, but the finding this note preserves.

## Detection

`ANTIGRAVITY_AGENT=1` is checked BEFORE cursor and claude in `../../../../../bin/fm-harness.sh`'s marker layer, deliberately: it is the most inheritance-prone marker of all the harnesses, since agy clears none of the foreign markers it may inherit.
`../../../../../bin/fm-spawn.sh`'s agy launch template now also clears the foreign markers at the launch boundary (defense in depth, matching cursor/gemini/omp), but the ordering above remains the only mitigation for an agy session a human started by hand.
Ancestry falls back to the anchored process name `agy` (native ELF, `comm=agy` directly - no `MainThread`-style interpreter hack needed, unlike gemini), never `*agy*`, for the same unrelated-command-collision reason as muse and omp; `fm_agent_process_classify_name` (`../../../../../bin/fm-agent-process-lib.sh`) anchors it the same way for tmux liveness classification, which a real spawn depends on for every control-plane verb.
`../../../../../tests/fm-agy-harness.test.sh` pins the marker precedence and ancestry boundary.

## Worker busy state and turn end

agy's hook surface (`.agents/hooks.json` schema; `PreToolUse`/`PostToolUse`/`PreInvocation`/`PostInvocation`/`Stop` events) is discovered from exactly two roots: the WORKSPACE customization root (`.agents/hooks.json`, walked from cwd to the repo root) or the machine-GLOBAL root (`~/.gemini/config/hooks.json`).
There is no third, firstmate-ownable location the way gemini's `GEMINI_CLI_SYSTEM_SETTINGS_PATH` provides.
Writing the workspace root would mean writing into every task's own worktree at `.agents/hooks.json`, a path a real project may already track for its own customizations - unlike Claude's `settings.local.json` or gemini's system-settings escape hatch, so firstmate would risk clobbering project configuration on every spawn.

The global root is therefore the only safe place - the identical tradeoff gemini's own reference once weighed and rejected in favor of its system-settings escape hatch, but agy has no such escape hatch to reject it in favor of.
`../../../../../bin/fm-agy-turnend-hook.sh` installs ONE named key (`"fm-turn-end"`) into that global file, idempotently, and refuses to touch it if the key already holds something else.
The installed hook script is a guarded no-op: harmless for every agy conversation on the machine, firstmate-launched or not, unless the CURRENT conversation's reported workspace (`workspacePaths[0]` in the hook's JSON stdin payload) holds a `.fm-agy-turnend` pointer file naming a token this registry actually issued.
`../../../../../bin/fm-spawn.sh` writes that pointer plus a five-line private registry entry (the task's own `fm-busy-event.sh` path, state dir, id, gen, and turnend path) per task, mirroring Grok's and Kimi's turnend-only registry shape but carrying a full busy/idle pair because agy's semantic source is real, not just a notification touch.
`PreInvocation` records busy; `Stop` records idle, touches the turn-end NOTIFICATION, and returns `{"decision":"stop"}` (verified live to allow normal completion).
Every hook command tolerates a refused event so a stale-generation writer can never break agy's own lifecycle.

Verified live across roughly a dozen PreInvocation/Stop payloads (single- and multi-invocation turns, a genuine two-workspace concurrency case, and an abrupt-kill-then-relaunch sequence): `workspacePaths[0]` reported the actual launch cwd in every case but one, where it anomalously named the captain's HOME directory instead.
The anomaly was not reproduced deliberately and is suspected to follow an abruptly killed prior agy process rather than ordinary concurrent use.
Because the guard requires a REAL pointer file at the reported path and firstmate never places one at `$HOME`, this class of anomaly can only ever cause one missed transition (self-correcting at the next event), never a misattributed one.

A raw agy-shaped launch (the unverified-adapter escape hatch) receives no trust pre-registration and no busy-state wiring, and therefore has no trusted busy state (classifies `unknown missing`), exactly like a raw gemini launch.

## Skills

UNVERIFIED for agy: the scout probe recorded workspace `.agents/skills/<name>/SKILL.md` (same layout as every other adapter) and agy's own global `~/.gemini/antigravity-cli/skills/`, but user-level discovery from `~/.agents/skills` - the path that makes `~/.agents/skills/no-mistakes` reachable for every other adapter - was not exercised.
Do not assume it works until checked.

## Primary integration

Unsupported and unverified, the same posture as gemini, muse, and rovo.
No wake protocol exists for agy, and this task verified only crewmate-side launch, trust, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI or from agy's own `PreInvocation`/`Stop` pair.

## Follow-up

Deliberately not exercised through a crewmate pane, and worth checking before relying on: `--input-format stream-json` round-trip, `--json-schema`, `--sandbox`, `--mode`, API-key auth mode (`modelProvider`+`GEMINI_API_KEY`), the unauthenticated-browser-login flow, `/`-command exact submit mechanics, `--conversation`/`--continue` resume through a real relaunch, and per-model effort variance beyond the installed default.
`fm-control-lib.sh`'s tables (interrupt key `Escape`, exit command `/quit`) were each verified live against a real agy process by hand (raw tmux `send-keys`), but `bin/fm-control.sh`'s own orchestration - its full interrupt/exit verb, ack-source polling, and postcondition proof - was exercised only through the fake-backend portable suite (`../../../../../tests/fm-control.test.sh`), not a real agy process driven through the actual script.
