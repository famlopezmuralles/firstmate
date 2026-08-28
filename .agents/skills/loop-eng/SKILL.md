---
name: loop-eng
description: >-
  Orchestrate one DECADA sprint execution loop with project-scoped context, human-confirmed authorization, bounded Firstmate dispatch, verification, and closure.
  Use when the captain invokes `/loop-eng` for a DECADA project or asks to connect Firstmate to a Cockpit proposal, Sprint, Epic, ADR, issue, or PR.
user-invocable: true
metadata:
  internal: true
---

# loop-eng

Use this skill as the native Firstmate integration seam for one DECADA sprint execution.
Keep it an orchestration contract and use the existing Firstmate scripts and authoritative help surfaces for mechanics.
Do not implement the Cockpit proposal schema, execution or telemetry ledger, API or rented-GPU backend, local OCuLink/Qwen runtime, or model-specific quota policy here.

## Resolve one project first

Resolve exactly one project before reading project context.
Use normal Firstmate intake and the project registry, and ask the captain when the project is missing or ambiguous.
After resolution, build a context manifest for that project only.
Include the selected Cockpit proposal and its authoritative Markdown source, current Sprint, Epic, ADR, issue, PR, project `AGENTS.md`, project README, and relevant current status.
Record source paths or IDs and revisions when available, and list exclusions such as other projects, unrelated records, and derived JSON treated as authority.
Pass the manifest and references to the isolated Treehouse worker so it can build detailed context in its own worktree.
Do not bulk-read `projects/` or load another project's records for convenience.

## Human-gated lifecycle

Run the following phases in order for one approved execution.

1. **Propose.** Read only the resolved project's manifest and references, then publish a recommendation with the bounded scope, exclusions, observable definition of done, effort class, budget, expiry, route, evidence plan, and open decisions.
   A proposal is pending advice and never dispatch authority.
2. **Review and confirm effort.** Treat effort as a recommendation that the captain must confirm.
   A valid authorization must bind one project and planning revision, bounded scope and exclusions, definition of done, effort, budget, expiry, attempt limit, and the approved route.
   Record a provider or model only when an authoritative harness or catalog surface establishes that it is supported; otherwise surface the uncertainty without inventing a model name.
   If the captain changes a material value, create or request a new proposal and authorization instead of editing the old approval in place.
3. **Run.** Recheck authorization, planning revision, expiry, budget, capacity, and scope immediately before dispatch.
   Dispatch one isolated Treehouse worker through `fm-spawn` and the applicable harness adapter, then use the normal Firstmate delivery path and `no-mistakes` gates.
   Use `gh-axi`, `chrome-devtools-axi`, or `lavish-axi` only when the approved task needs GitHub, browser, or structured review evidence.
   Never dispatch without every authorization field above and never create an autonomous loop.
4. **Pause.** Pause on captain request, an authorization or budget boundary, unavailable capacity, or a verification blocker, and record the reason and partial evidence.
   Resumption must revalidate the same authorization, budget, expiry, and scope; any material change requires a new human approval.
5. **Verify.** Compare the actual diff and worker evidence with the authorized project, planning revision, scope, definition of done, and required checks.
   Require applicable tests, lint or build results, diff review, PR, and CI evidence rather than treating an agent assertion as completion.
   Treat failed verification, unavailable required evidence, or a changed revision as blocked or failed, not as success.
6. **Close.** Record the terminal outcome, stop after this one approved run, and require new human authorization for a correction, retry beyond the limit, route change, scope change, or second iteration.

## Capacity and routing recommendation

Recommend capacity in this order: current subscriptions and available harnesses first, API or rented-GPU overflow second, and local OCuLink/Qwen inference last.
Treat these as capacity phases rather than permission to buy, provision, change provider, or execute autonomously.
Use `harness-adapters` for supported harness and effort behavior, `quota-array-dispatch` when a matched dispatch rule has multiple candidates, and the current `quota-axi` and catalog surfaces for quota and model evidence.
Surface the suggested effort, provider, model when established, route, budget, evidence basis, and remaining uncertainty for captain confirmation.
If the installed configuration cannot express a requested provider, model, effort, or review matrix, report the exact unsupported or unavailable dimension and leave it for a separate review decision.

## Required updates and authority boundaries

Use the project's approved integration path to surface or record the following without inventing a parallel runtime:

- proposal status and human decision;
- task, implementation, PR, tests, and checks evidence;
- execution outcome and open decisions; and
- private run telemetry references.

Keep planning Markdown authoritative and treat per-record JSON as derived and non-mutable by the worker or this skill.
Do not silently change proposal scope, planning records, authorization, budget, route, or another project's records.
Measure time, tokens, cost, retries, intervention, and quota only through existing observability hooks.
Record a metric as unavailable when the selected provider or hook does not expose it, and never substitute zero, a guess, or fake precision.

This skill defines the orchestration and integration seam only.
Later DECADA work owns the proposal schema, execution and telemetry ledger, overflow backends, local runtime, and model-specific policy.
