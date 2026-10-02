# Report catalog

`bin/fm-reports-publish.sh` centralizes worker reports from this home and its
registered secondmates into one read-only, searchable local catalog, served
at `http://localhost/reports/` for the same local-only browsing experience
`http://localhost/diffs/` already gives `explain-diff-html` output.

## What is included

A report candidate is any `*.md` file directly inside a home's `data/<task>/`
directory, except a fixed deny-list (briefs, launch instructions, captain-hold
decision records, and firstmate-authored steering notes: `brief.md`,
`launch-brief.md`, `brief-*.md`, `decision.md`, `review-decision.md`,
`ship-instructions.md`, `task-note.md`, `intake.md`, `steer-*.md`), and except
a symlink. This means a supplemental file such as `cd-verification.md` is
published alongside the literal `report.md` for the same task.

A filename containing `prior` or `before` is still published, but marked
historical in the catalog rather than presented as the current report.

Each report's project, linked pull request, and backlog state come from that
home's own `bin/fm-fleet-snapshot.sh --json`, never from a second backlog
parser; a task with no matching backlog record shows those fields as unknown
rather than guessed.

This home's own `data/` is always scanned. Every home in `data/secondmates.md`
is scanned too: a local secondmate's home directory is read directly (same
filesystem, read-only), and the one remote-host route is read through the
existing bounded transport, `bin/fm-on.sh` plus `bin/fm-remote-file.sh`,
fetching only its literal `data/<task>/report.md` files (the same filesystem
scan `bin/fm-fleet-snapshot.sh`'s `scout_report_lines` performs locally). A
remote home's supplemental, non-`report.md` files are not discovered, because
there is no remote directory-listing primitive narrow enough to add safely
here; this is a disclosed limitation, shown in the catalog, not a silent gap.
An unreachable or failing source is listed by name with its reason rather
than making the run look like an empty, successful catalog.

## Privacy

Generated HTML lives outside every project and outside this repository,
in the captain-private `$HOME/reports-published` (override with
`FM_REPORTS_PUBLISH_ROOT`). The Apache alias this command installs uses
`Require local`, never `Require all granted`: a request from loopback, or
from the server's own address, is served; a request from a genuinely
different network peer is refused with 403. This was verified against a real
foreign peer (a Docker bridge container, a distinct network namespace from
the host) returning 403 for the exact same path that returns 200 from
loopback. `bin/fm-reports-publish.sh setup-apache` never changes the global
Apache `Listen` directive, the existing `/diffs` alias, or any other local
site; it only writes its own `reports.conf` and asks `systemctl` to reload
(not restart) Apache.

Report content is HTML-escaped before any Markdown is reconstructed into
tags, so a report can never inject a script or an unsafe link scheme; only
`http://` and `https://` links and autolinks are rendered as clickable.
`bin/fm-reports-render.py`'s module docstring owns the exact rendering
contract.

## Setup

One-time, each run manually and separately from the recurring refresh below:

```
bin/fm-reports-publish.sh setup-apache
bin/fm-reports-publish.sh install-cron
```

`setup-apache` writes a local-only `/reports` Apache conf and gracefully
reloads Apache. `install-cron` adds an idempotent per-user crontab line that
re-runs the plain `publish` action every 15 minutes, so a new or updated
report reaches the catalog without the captain remembering a path or asking
for it; re-running either command is safe and reapplies the same state.

## Manual refresh

```
bin/fm-reports-publish.sh
```

Re-scans every home and rewrites the catalog under the publish root. This is
the same action the cron entry runs; it never touches a project, another
home's data, or this repository's own tracked state.
