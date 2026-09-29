# agy (Antigravity CLI)

Not yet a verified crewmate or scout adapter: this task landed only the harness-detection arm in `../../../../../bin/fm-harness.sh`, pinned by `../../../../../tests/fm-agy-harness.test.sh`.
No `../../../../../bin/fm-spawn.sh` launch template, no `../../../../../bin/fm-control-lib.sh` entry, and no busy-state wiring exist yet, so agy is undispatchable per `../../SKILL.md`'s non-negotiable safety and is absent from its harness routing table.

## Verified live (agy 1.2.12)

- Native ELF binary; a live process reports `comm=agy` directly, so ancestry detection needs no MainThread-style interpreter hack the way gemini's does.
- `ANTIGRAVITY_AGENT=1` is agy's own child/tool-process marker. agy clears NEITHER an inherited `CLAUDECODE` nor an inherited `CURSOR_AGENT` from its own tool children, so a real agy worker under a claude or cursor primary carries all three markers at once.
- Headless `-p` mode returns JSON output; `--dangerously-skip-permissions` grants unattended autonomy there.
- Interactive mode (`-i` / `--prompt-interactive`, the mode a supervised crewmate pane would use) shows a workspace-trust dialog with no suppression flag found; it is answered by one Enter to its default-safe choice. This dialog blocks completing a launch template and busy-state wiring today, and is the reason those remain unshipped.
- Auth resolves through the OS keyring under one Google subscription; available models include gemini, claude, and gpt-oss.
- `.agents/hooks.json` is agy's hook surface (workspace-level); `PreInvocation`/`Stop` are the candidate busy/turn-end hooks and are not yet wired — confirm no tracked-file clobber before wiring them.

## Detection

`../../../../../bin/fm-harness.sh` checks `ANTIGRAVITY_AGENT=1` before cursor and claude, since it is the most inheritance-prone marker of all the harnesses: with no launch template yet, there is no marker-clearing defense in depth at a launch boundary the way cursor and gemini already have, so this check ordering is the only mitigation until a spawn template lands.
Ancestry falls back to the anchored process name `agy`, never `*agy*`, for the same unrelated-command-collision reason as muse and omp.

## Follow-up

Landing a launch template, control entry, busy/turn-end wiring, tmux liveness, model/effort discovery, and a credential probe all first require resolving the interactive trust-dialog blocker above.
