# Firstmate PR merge runbook

This runbook supplies this repository's project-specific landing steps and supplements the shared `/land-pr` procedure.

1. Use `bin/fm-pr-merge.sh` with the task ID and the full pull request URL to perform the guarded merge.
2. Continue only after the merge script proves that the pull request landed.
3. Run `bin/fm-fleet-sync.sh` to refresh this home's firstmate project clone with a safe fast-forward.
4. Invoke `/updatefirstmate` so the running firstmate and registered secondmate homes receive the landed tracked code.
5. Report any skipped or blocked sync or update target in plain language.
