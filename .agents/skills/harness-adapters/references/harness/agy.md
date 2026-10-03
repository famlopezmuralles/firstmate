# Antigravity CLI

Antigravity's `agy` TUI, verified end to end on 2026-09-10 with agy 1.2.0 on Linux through the Herdr backend.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no agy wake protocol.
`../../../../../docs/verification/agy.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `agy` from `PATH`, refused if absent; a Go-compiled single binary, so the live process name is exactly `agy` with `argv[0]=agy`. |
| Launch | `agy --prompt-interactive "<brief>" --model <id> --effort <level> --dangerously-skip-permissions`, with the resolved absolute binary; the brief auto-submits with no extra Enter. The spawn pre-registers the worktree in agy's trust store first, then waits for a busy turn (answering the folder-trust dialog if it renders anyway) before reporting success. |
| Busy state | Guarded global `PreInvocation`/`Stop` hook armed by the spawn (`../../../../../bin/fm-agy-turnend-hook.sh`); on Herdr the native `working` status also classifies busy, and the `agy-regex` rendered tail remains the fallback when no trusted record exists. |
| Rendered tail | Busy status row carries `esc to cancel` on the left; the idle row shows `? for shortcuts` instead. The `Generating...` word beside the braille spinner is free-floating output and is not a signal. |
| Turn end | The `Stop` hook touches the turn-end marker after the idle event; a manual `Escape` fires no closing hook. Completion also arrives through the worker status protocol and, on Herdr, the native return to `idle`. |
| Exit | `/quit`, one Enter; the process exits. |
| Interrupt | Single `Escape`, which prints the Interrupted row and leaves an idle composer with no repollution, so no clear key follows. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `--dangerously-skip-permissions` auto-approves tool calls for the run. |
| Marker | `ANTIGRAVITY_AGENT=1` on 1.2.13 tool children, tested before an inherited `CLAUDECODE` and `CURSOR_AGENT`. `AGENT=1` is not an agy identity, and a 1.2.0 TUI itself publishes no `AGY_*` variable. |
| Resume | `--continue` and `--conversation` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Model | `--model <id>` with the bare catalog id from `agy models` (for example `gemini-3.8-flash-high`); `bin/fm-spawn.sh` refuses a requested id a reachable listing omits. The listing is a remote fetch, so the probe runs stdin-detached under the shared hard bound and an unreachable or hung listing launches unvalidated with a notice. |
| Effort | `--effort low\|medium\|high`; `xhigh` and `max` stay in task metadata under the record-and-omit contract. |
| Composer | Borderless bare `>` row, which the shared classifier reads as `unknown` under the dead-shell rule, never `empty`; steering confirms delivery through native agent-state and the delivery footer instead, the cursor precedent. |

## Trust, and where the decision persists

Every task worktree is a path agy has never seen, so an unregistered launch stops on `Do you trust the contents of this project?` with the safe choice `Yes, I trust this folder` preselected, and an unanswered dialog sends the turn into agy's scratch directory instead of the worktree.
There is no launch flag that suppresses the dialog, but agy honours a `trustedWorkspaces` entry in the captain's own `~/.gemini/antigravity-cli/settings.json` written ahead of launch (verified live), so `../../../../../bin/fm-spawn.sh` pre-registers the worktree through `../../../../../bin/fm-agy-trust.sh` before launch, the claude shape: the helper refuses anything but a linked worktree of the spawning project, records both the logical pane path and its resolved form because agy compares the logical cwd, and preserves every other key in the store.
The post-launch readiness gate is the backstop: it answers a dialog that renders anyway with a single Enter, then requires a busy verdict (Herdr's native `working` status or the pinned `esc to cancel` row) before the spawn reports success, and on a path that was not pre-registered it never counts a busy verdict as ready until the dialog has been answered, because Herdr's native verdict can precede the dialog.
A pane whose brief cannot be confirmed to run in the worktree fails the spawn, records the failure in the task status, and closes the endpoint.
Never steer into a pane still showing the dialog; a spawn that reported success has already cleared it.

## Credential precondition

A verified agy worker ran under a signed-in Google account with no key export and no dialog.
The unauthenticated failure mode was not observed, so treat any auth prompt or refusal as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing into it.

## Detection

`../../../../../bin/fm-harness.sh` matches the anchored process name `agy`, never `*agy*`.
agy 1.2.13 tool children set `ANTIGRAVITY_AGENT=1` and clear neither an inherited `CLAUDECODE` nor `CURSOR_AGENT`, so that marker is tested before both.
`AGENT=1` observed on a live 1.2.0 TUI is an inherited launcher value, not an agy identity, and a structural agy ancestor still outranks a retained `CLAUDECODE`.
agy is deliberately absent from the session-lock name vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where muse, gemini, and rovo are also absent: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms a busy generation for a non-raw agy launch and writes `state/<id>.agy-turnend-token` plus the worktree pointer `.fm-agy-turnend`.
`../../../../../bin/fm-agy-turnend-hook.sh` installs one guarded key in `~/.gemini/config/hooks.json`; the hook is a no-op unless `workspacePaths[0]` holds that pointer naming a token in `~/.gemini/config/fm-turn-end.d`.
`PreInvocation` records busy and `Stop` records idle, and a manual `Escape` fires no closing hook.
`fm_busy_agy_tail_busy` remains the fallback when no trusted `agy-hook` record exists: it matches the pinned `esc to cancel` status row alone, and `fm_busy_classify` reports `unknown agy-regex` rather than idle when that row is absent, because a long turn can scroll the marker out of the captured tail.
Teardown removes the pointer, the token, and the registry entry; the machine-global hook installation stays.
A raw agy launch arms none of this and classifies `unknown missing`.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no agy protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
