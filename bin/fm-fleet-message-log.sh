#!/usr/bin/env bash
# fm-fleet-message-log.sh - render the firstmate<->crew message exchange as one local read-only transcript page.
#
# This script owns the fleet message-log page contract: which durable records
# it reads, how it derives each entry's direction, timestamp, correlation id,
# and steer delivery state, and where the generated page lives.
# bin/fm-task-inbox-lib.sh owns the inbox record format this script parses;
# bin/fm-classify-lib.sh owns status-line syntax; neither is restated here.
#
# Sources, read only: state/<id>.inbox/*.msg (firstmate sent, unacknowledged)
# and state/<id>.inbox/handled/*.msg (the worker's `mv` there IS the
# acknowledgement), plus state/<id>.status (what the crew reported back).
# The tool never writes to state/, never sends, rings, or acknowledges
# anything; it only reads.
#
# Derivation per entry: direction is firstmate-to-agent for inbox records and
# agent-to-firstmate for status lines. Timestamp is the record's `at=` header
# (steers) or `[at=epoch]` marker (status), else the file mtime, else unknown.
# Correlation is the first `corr=` token in the text. Steer state is handled
# for handled/ records, else pending, qualified by the watcher's durable
# ladder sidecars (.ring-state rung count, .escalated escalation marker,
# .retry-ring retry marker) when they name that record.
#
# Output is one self-contained index.html with no external references, so the
# page works offline and phones nothing home. Message bodies can hold private
# project and customer details: output defaults to gitignored data/ and must
# never be committed. Any server binds 127.0.0.1 only.
#
# Usage:
#   fm-fleet-message-log.sh [--state-dir DIR] [--out DIR] [--refresh SECS] [--serve [--port PORT]]
#
#   --state-dir DIR  read inboxes and status logs from DIR (default $FM_HOME/state)
#   --out DIR        write index.html into DIR (default $FM_HOME/data/fleet-message-log)
#   --refresh SECS   page auto-refresh interval, 0 disables (default 60)
#   --serve          serve the output dir over HTTP bound to 127.0.0.1 (default port 8471)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

STATE_DIR="$FM_HOME/state"
OUT_DIR="$FM_HOME/data/fleet-message-log"
REFRESH=60
SERVE=0
PORT=8471

usage() {
  sed -n '2,/^set -eu$/p' "$SCRIPT_DIR/fm-fleet-message-log.sh" | sed -n 's/^# \{0,1\}//p'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --state-dir) STATE_DIR="${2:?--state-dir needs a directory}"; shift 2 ;;
    --out) OUT_DIR="${2:?--out needs a directory}"; shift 2 ;;
    --refresh) REFRESH="${2:?--refresh needs seconds}"; shift 2 ;;
    --serve) SERVE=1; shift ;;
    --port) PORT="${2:?--port needs a port}"; shift 2 ;;
    *) echo "fm-fleet-message-log: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$REFRESH" in ''|*[!0-9]*) echo "fm-fleet-message-log: --refresh must be a non-negative integer" >&2; exit 2 ;; esac
case "$PORT" in ''|*[!0-9]*) echo "fm-fleet-message-log: --port must be a number" >&2; exit 2 ;; esac

[ -d "$STATE_DIR" ] || { echo "fm-fleet-message-log: state dir not found: $STATE_DIR" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "fm-fleet-message-log: python3 not found" >&2; exit 1; }
mkdir -p "$OUT_DIR"

python3 - "$STATE_DIR" "$OUT_DIR/index.html" "$REFRESH" <<'PYEOF'
import html
import os
import re
import sys

state_dir, out_path, refresh = sys.argv[1], sys.argv[2], sys.argv[3]

CORR_RE = re.compile(r"corr=([0-9A-Za-z][0-9A-Za-z-]{5,})")
AT_RE = re.compile(r"\[at=(\d+)\]")
KEY_RE = re.compile(r"\[key=([^\]]+)\]")
VERB_RE = re.compile(r"^(working|done|failed|blocked|paused|needs-decision|resolved)\b")


def parse_msg(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    at = None
    body = text
    if text.startswith("schema="):
        head, sep, rest = text.partition("\n--\n")
        if sep:
            for line in head.splitlines():
                if line.startswith("at="):
                    at = line[3:].strip()
            body = rest
        else:
            body = ""
            for line in text.splitlines():
                if line.startswith("at="):
                    at = line[3:].strip()
    epoch = None
    if at:
        try:
            from datetime import datetime, timezone
            epoch = datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()
        except ValueError:
            epoch = None
    if epoch is None:
        epoch = os.path.getmtime(path)
    return body.strip(), at, epoch


def read_sidecar(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return ""


agents = set()
for name in os.listdir(state_dir):
    if name.startswith("."):
        continue
    full = os.path.join(state_dir, name)
    if name.endswith(".inbox") and os.path.isdir(full):
        agents.add(name[:-len(".inbox")])
    elif name.endswith(".status") and os.path.isfile(full):
        agents.add(name[:-len(".status")])

entries = {}
for agent in sorted(agents):
    inbox = os.path.join(state_dir, agent + ".inbox")
    status_path = os.path.join(state_dir, agent + ".status")
    meta_path = os.path.join(state_dir, agent + ".meta")
    kind = ""
    try:
        with open(meta_path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("kind="):
                    kind = line[len("kind="):].strip()
                    break
    except OSError:
        pass
    rows = []
    if os.path.isdir(inbox):
        ring = {}
        for line in read_sidecar(os.path.join(inbox, ".ring-state")).splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                ring[parts[0]] = parts[1]
        escalated = read_sidecar(os.path.join(inbox, ".escalated"))
        retry = read_sidecar(os.path.join(inbox, ".retry-ring"))
        handled_dir = os.path.join(inbox, "handled")
        pending = sorted(
            f for f in os.listdir(inbox)
            if f.endswith(".msg") and os.path.isfile(os.path.join(inbox, f))
        )
        handled = []
        if os.path.isdir(handled_dir):
            handled = sorted(
                f for f in os.listdir(handled_dir)
                if f.endswith(".msg") and os.path.isfile(os.path.join(handled_dir, f))
            )
        for fname in pending:
            body, at, epoch = parse_msg(os.path.join(inbox, fname))
            state = "pending"
            quals = []
            if fname in ring:
                quals.append("rung %sx" % ring[fname])
            if escalated == fname:
                quals.append("escalated")
            if retry == fname:
                quals.append("retry-owed")
            if "delivery=fire-and-forget" in body or body.startswith("delivery="):
                state = "fire-and-forget"
            if quals:
                state += " (" + ", ".join(quals) + ")"
            m = CORR_RE.search(body)
            rows.append({
                "direction": "out", "epoch": epoch, "at": at,
                "corr": m.group(1) if m else "", "state": state,
                "body": body, "seq": fname,
            })
        for fname in handled:
            body, at, epoch = parse_msg(os.path.join(handled_dir, fname))
            m = CORR_RE.search(body)
            rows.append({
                "direction": "out", "epoch": epoch, "at": at,
                "corr": m.group(1) if m else "", "state": "handled",
                "body": body, "seq": fname,
            })
    try:
        with open(status_path, encoding="utf-8", errors="replace") as fh:
            lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    except OSError:
        lines = []
    mtime = os.path.getmtime(status_path) if os.path.isfile(status_path) else 0
    for line in lines:
        m = AT_RE.search(line)
        epoch = float(m.group(1)) if m else mtime
        c = CORR_RE.search(line)
        k = KEY_RE.search(line)
        v = VERB_RE.search(line)
        rows.append({
            "direction": "in", "epoch": epoch, "at": None,
            "corr": c.group(1) if c else "", "state": v.group(1) if v else "note",
            "body": line, "seq": k.group(1) if k else "",
        })
    rows.sort(key=lambda r: r["epoch"], reverse=True)
    entries[agent] = {"kind": kind, "rows": rows}

ordered = sorted(
    entries.items(),
    key=lambda kv: (max([r["epoch"] for r in kv[1]["rows"]] or [0]), kv[0]),
    reverse=True,
)

from datetime import datetime, timezone


def fmt_ts(epoch):
    try:
        return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OSError, OverflowError, ValueError):
        return "unknown"


def chip(text, cls):
    return '<span class="chip %s">%s</span>' % (cls, html.escape(text)) if text else ""


parts = []
parts.append("<!DOCTYPE html>")
parts.append('<html lang="en"><head><meta charset="utf-8">')
parts.append('<meta name="viewport" content="width=device-width, initial-scale=1">')
if refresh != "0":
    parts.append('<meta http-equiv="refresh" content="%d">' % int(refresh))
parts.append("<title>Fleet message log</title>")
parts.append("""<style>
body{font-family:system-ui,sans-serif;max-width:70rem;margin:0 auto;padding:1rem;color:#111}
.controls{position:sticky;top:0;background:#fff;padding:.5rem 0;border-bottom:1px solid #ddd;display:flex;gap:.75rem;flex-wrap:wrap;align-items:center}
.controls input,.controls select{font-size:1rem;padding:.25rem .5rem}
.entry{border:1px solid #ddd;border-radius:.5rem;padding:.5rem .75rem;margin:.5rem 0}
.entry.out{border-left:.3rem solid #2563eb}
.entry.in{border-left:.3rem solid #16a34a}
.entry pre{white-space:pre-wrap;word-break:break-word;max-height:24rem;overflow:auto;background:#f8fafc;padding:.5rem;border-radius:.25rem}
.meta{display:flex;gap:.5rem;flex-wrap:wrap;align-items:center;font-size:.85rem;color:#444}
.chip{display:inline-block;border:1px solid #bbb;border-radius:1rem;padding:0 .6rem;font-size:.8rem}
.dir-out{color:#1d4ed8}.dir-in{color:#15803d}
h2 .kind{color:#666;font-weight:normal;font-size:.9rem}
.note{color:#555;font-size:.9rem}
</style></head><body>""")
parts.append("<h1>Fleet message log</h1>")
parts.append('<p class="note">Read-only transcript of firstmate steering records and crew status reports. Local file only, never published. Generated {now} UTC. Auto-refresh: {r}.</p>'.format(
    now=html.escape(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")),
    r=("every %s s" % html.escape(refresh)) if refresh != "0" else "off",
))
parts.append("""<div class="controls">
<label>Agent <select id="agent"><option value="">All agents</option>""")
for agent, info in ordered:
    label = agent + (" (%s)" % info["kind"] if info["kind"] else "")
    parts.append('<option value="%s">%s</option>' % (html.escape(agent), html.escape(label)))
parts.append("""</select></label>
<label>Direction <select id="dir"><option value="">Both</option><option value="out">Firstmate to agent</option><option value="in">Agent to firstmate</option></select></label>
<label>Search <input id="q" type="search" placeholder="free text or corr id"></label>
</div>""")
parts.append('<p class="note" id="count"></p>')
for agent, info in ordered:
    label = html.escape(agent + (" · " + info["kind"] if info["kind"] else ""))
    parts.append('<section data-agent="%s"><h2>%s <span class="kind">%d entries</span></h2>' % (
        html.escape(agent), label, len(info["rows"])))
    if not info["rows"]:
        parts.append('<p class="note">No inbox records or status lines.</p>')
    for r in info["rows"]:
        dlabel = "Firstmate to agent" if r["direction"] == "out" else "Agent to firstmate"
        parts.append('<article class="entry %s" data-dir="%s" data-corr="%s" data-state="%s">' % (
            r["direction"], r["direction"],
            html.escape(r["corr"]), html.escape(r["state"])))
        parts.append('<div class="meta"><span class="dir-%s">%s</span><span>%s</span>%s%s</div>' % (
            r["direction"], dlabel, html.escape(fmt_ts(r["epoch"])),
            chip(r["corr"], "corr"), chip(r["state"], "state")))
        parts.append("<pre>%s</pre>" % html.escape(r["body"]))
        parts.append("</article>")
    parts.append("</section>")
parts.append("""<script>
var agent=document.getElementById('agent'),dir=document.getElementById('dir'),q=document.getElementById('q'),count=document.getElementById('count');
function apply(){
  var a=agent.value.toLowerCase(),d=dir.value,t=q.value.toLowerCase(),n=0;
  document.querySelectorAll('section[data-agent]').forEach(function(s){
    var vis=0;
    s.querySelectorAll('article.entry').forEach(function(e){
      var ok=(!a||s.getAttribute('data-agent').toLowerCase()===a)&&(!d||e.getAttribute('data-dir')===d)&&(!t||e.textContent.toLowerCase().indexOf(t)>=0);
      e.style.display=ok?'':'none';if(ok){vis++;n++;}
    });
    s.style.display=vis?'':'none';
  });
  count.textContent=n+' entries shown';
}
[agent,dir,q].forEach(function(el){el.addEventListener('input',apply);});
apply();
</script></body></html>""")

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(parts) + "\n")
print("page: %s" % out_path)
PYEOF

if [ "$SERVE" -eq 1 ]; then
  echo "serve: http://127.0.0.1:$PORT/ (loopback only, Ctrl-C to stop)"
  exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$OUT_DIR"
fi
