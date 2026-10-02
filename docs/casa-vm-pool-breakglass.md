# casa-vm pool: casa-overflow break-glass runbook

This is a manual runbook only.
No step here runs automatically, and adding the label described below happens only on a future halted-pool alert, by a separate human decision at that time.

## Background

`linux25` runs `pool.sh`, a single-VM ephemeral GitHub Actions runner pool labeled `casa-vm` for 7 repositories, capped at one concurrent VM.
A registration-timeout watchdog and a 3-strike halt (see the main-home investigation report `data/casa-vm-observability/report.md` for the full design) stop the pool after 3 consecutive VM boots fail to register in a row, rather than retrying forever.
A halted pool blocks PR-triggered CI for those repositories, because `ci.yml` routes `pull_request` events to the `casa-vm` label and everything else to the always-on `casa` runner.
`casa` is already online for all 7 repositories under the label `casa`, so the fastest recovery is making `casa` also accept `casa-vm`-labeled jobs while the pool is down.

## When to use this

Only after a "pool halted" alert actually fires for the casa-vm pool, and only once whoever is responding has judged that routing currently queued PR jobs onto `casa` is acceptable.
Never apply it preemptively or leave it in place permanently: `casa` is a persistent, more-privileged runner that also executes push/main/deploy workflows (`deploy.yml`, `promote-production.yml`, `staging-deploy.yml`), so letting PR-triggered code share it defeats the isolation reason the ephemeral `casa-vm` pool exists.

## Steps

1. Confirm the pool is actually halted, not mid-watchdog-retry: `ssh linux25 cat /home/user/casa-vm/state/heartbeat.json` should show `"phase": "halted"`.
2. Add the `casa-vm` label to the existing `casa` runner so it matches both label sets:
   ```sh
   gh api -X POST repos/famlopezmuralles/<repo>/actions/runners/<runner_id>/labels -f labels[]=casa-vm
   ```
   Use the organization-level runners endpoint instead if `casa` is registered at the organization rather than per-repository; `gh api repos/famlopezmuralles/<repo>/actions/runners` lists the runner id and its current labels.
3. Confirm a queued PR job picks up the now-dual-labeled `casa` runner and completes.
4. Once the pool is confirmed healthy again (`pool.sh` relaunched past its strike cap, `heartbeat.json` back to `phase: "idle"` or `"running"` with no strikes), remove the label:
   ```sh
   gh api -X DELETE repos/famlopezmuralles/<repo>/actions/runners/<runner_id>/labels/casa-vm
   ```
5. Confirm removal: the runner's label list no longer includes `casa-vm`, and new PR jobs again wait for the ephemeral pool rather than landing on `casa`.

## Rollback

Step 4 above is the rollback: removing the `casa-vm` label from `casa` restores the original routing.
Nothing else needs to be undone; this runbook never touches `pool.sh`, `casa-vm` VM state, or any workflow file.
