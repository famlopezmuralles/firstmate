#!/usr/bin/env bash
# fm-fleet-message-log.sh - render the firstmate<->crew message exchange as a local live transcript page.
#
# This script owns the fleet message-log page contract: which durable records
# it reads, how it derives each entry's direction, timestamp, correlation id,
# and steer delivery state, and how the page stays live.
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
# Modes: --serve runs a loopback-only HTTP server as the main mode. The page
# polls its /events.json every --refresh seconds and re-renders in place, so
# new messages appear without a manual reload and the agent filter and search
# text are preserved across polls. A plain build (no --serve) writes one
# self-contained index.html snapshot with the same renderer as a secondary
# option. Both modes phone nothing home: the page has no external references.
# Message bodies can hold private project and customer details: output
# defaults to gitignored data/ and must never be committed. Any server binds
# 127.0.0.1 only and refuses anything else.
#
# Usage:
#   fm-fleet-message-log.sh [--state-dir DIR] [--out DIR] [--refresh SECS] [--serve [--port PORT]]
#
#   --state-dir DIR  read inboxes and status logs from DIR (default $FM_HOME/state)
#   --out DIR        build writes index.html into DIR (default $FM_HOME/data/fleet-message-log)
#   --refresh SECS   page poll interval, 0 disables live polling (default 5)
#   --serve          serve the transcript over HTTP bound to 127.0.0.1 (default port 8471)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

STATE_DIR="$FM_HOME/state"
OUT_DIR="$FM_HOME/data/fleet-message-log"
REFRESH=5
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

run_py() {
  python3 - "$@" <<'PYEOF'
import html
import json
import os
import re
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = sys.argv[1]
STATE_DIR = sys.argv[2]
REFRESH = sys.argv[3]
if MODE == "serve":
    PORT = int(sys.argv[4])

CORR_RE = re.compile(r"corr=([0-9A-Za-z][0-9A-Za-z-]{5,})")
AT_RE = re.compile(r"\[at=(\d+)\]")
KEY_RE = re.compile(r"\[key=([^\]]+)\]")
VERB_RE = re.compile(r"^(working|done|failed|blocked|paused|needs-decision|resolved)\b")


def parse_msg(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    at = None
    is_faf = False
    body = text
    if text.startswith("schema="):
        head, sep, rest = text.partition("\n--\n")
        if sep:
            for line in head.splitlines():
                if line.startswith("at="):
                    at = line[3:].strip()
                elif line.strip() == "delivery=fire-and-forget":
                    is_faf = True
            body = rest
        else:
            body = ""
            for line in text.splitlines():
                if line.startswith("at="):
                    at = line[3:].strip()
                elif line.strip() == "delivery=fire-and-forget":
                    is_faf = True
    epoch = None
    if at:
        try:
            epoch = datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()
        except ValueError:
            epoch = None
    if epoch is None:
        epoch = os.path.getmtime(path)
    return body.strip(), epoch, is_faf


def read_sidecar(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def fmt_ts(epoch):
    try:
        return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OSError, OverflowError, ValueError):
        return "unknown"


def collect(state_dir):
    agents = set()
    for name in os.listdir(state_dir):
        if name.startswith("."):
            continue
        full = os.path.join(state_dir, name)
        if name.endswith(".inbox") and os.path.isdir(full):
            agents.add(name[:-len(".inbox")])
        elif name.endswith(".status") and os.path.isfile(full):
            agents.add(name[:-len(".status")])
    payload_agents = []
    for agent in sorted(agents):
        inbox = os.path.join(state_dir, agent + ".inbox")
        status_path = os.path.join(state_dir, agent + ".status")
        kind = ""
        try:
            with open(os.path.join(state_dir, agent + ".meta"),
                      encoding="utf-8", errors="replace") as fh:
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
            pending = sorted(
                f for f in os.listdir(inbox)
                if f.endswith(".msg") and os.path.isfile(os.path.join(inbox, f))
            )
            handled_dir = os.path.join(inbox, "handled")
            handled = []
            if os.path.isdir(handled_dir):
                handled = sorted(
                    f for f in os.listdir(handled_dir)
                    if f.endswith(".msg") and os.path.isfile(os.path.join(handled_dir, f))
                )
            for fname in pending:
                body, epoch, is_faf = parse_msg(os.path.join(inbox, fname))
                state = "pending"
                quals = []
                if fname in ring:
                    quals.append("rung %sx" % ring[fname])
                if escalated == fname:
                    quals.append("escalated")
                if retry == fname:
                    quals.append("retry-owed")
                if is_faf:
                    state = "fire-and-forget"
                if quals:
                    state += " (" + ", ".join(quals) + ")"
                m = CORR_RE.search(body)
                rows.append({"dir": "out", "epoch": epoch, "ts": fmt_ts(epoch),
                             "corr": m.group(1) if m else "", "state": state,
                             "body": body})
            for fname in handled:
                body, epoch, _is_faf = parse_msg(os.path.join(handled_dir, fname))
                m = CORR_RE.search(body)
                rows.append({"dir": "out", "epoch": epoch, "ts": fmt_ts(epoch),
                             "corr": m.group(1) if m else "", "state": "handled",
                             "body": body})
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
            v = VERB_RE.search(line)
            rows.append({"dir": "in", "epoch": epoch, "ts": fmt_ts(epoch),
                         "corr": c.group(1) if c else "",
                         "state": v.group(1) if v else "note", "body": line})
        rows.sort(key=lambda r: r["epoch"], reverse=True)
        payload_agents.append({"id": agent, "kind": kind, "rows": rows})
    payload_agents.sort(
        key=lambda a: (max([r["epoch"] for r in a["rows"]] or [0]), a["id"]),
        reverse=True)
    return {"generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "agents": payload_agents}


PAGE_TEMPLATE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fleet message log</title>
<style>
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
#live{font-weight:bold}
#live.stale{color:#b45309}
</style></head><body>
<h1>Fleet message log</h1>
<p class="note">Read-only transcript of firstmate steering records and crew status reports. Local only, never published. <span id="live">live</span> <span id="stamp"></span></p>
<div class="controls">
<label>Agent <select id="agent"><option value="">All agents</option></select></label>
<label>Direction <select id="dir"><option value="">Both</option><option value="out">Firstmate to agent</option><option value="in">Agent to firstmate</option></select></label>
<label>Search <input id="q" type="search" placeholder="free text or corr id"></label>
</div>
<p class="note" id="count"></p>
<div id="log"></div>
<script id="initial" type="application/json">__INITIAL__</script>
<script>
var POLL_SECS=__POLL__;
var agentEl=document.getElementById('agent'),dirEl=document.getElementById('dir'),qEl=document.getElementById('q');
var logEl=document.getElementById('log'),countEl=document.getElementById('count');
var stampEl=document.getElementById('stamp'),liveEl=document.getElementById('live');
function chip(text){if(!text)return null;var s=document.createElement('span');s.className='chip';s.textContent=text;return s;}
function render(data){
  var seen={};
  data.agents.forEach(function(a){seen[a.id]=true;});
  var cur=agentEl.value;
  agentEl.querySelectorAll('option[value]:not([value=""])').forEach(function(o){o.remove();});
  data.agents.forEach(function(a){
    var o=document.createElement('option');o.value=a.id;
    o.textContent=a.kind?a.id+' ('+a.kind+')':a.id;agentEl.appendChild(o);
  });
  if(seen[cur])agentEl.value=cur;
  logEl.innerHTML='';
  data.agents.forEach(function(a){
    var sec=document.createElement('section');sec.setAttribute('data-agent',a.id);
    var h=document.createElement('h2');h.textContent=a.id+' ';
    var k=document.createElement('span');k.className='kind';k.textContent=a.rows.length+' entries';
    h.appendChild(k);sec.appendChild(h);
    if(!a.rows.length){var p=document.createElement('p');p.className='note';p.textContent='No inbox records or status lines.';sec.appendChild(p);}
    a.rows.forEach(function(r){
      var art=document.createElement('article');
      art.className='entry '+r.dir;art.setAttribute('data-dir',r.dir);
      var meta=document.createElement('div');meta.className='meta';
      var d=document.createElement('span');
      d.className=r.dir==='out'?'dir-out':'dir-in';
      d.textContent=r.dir==='out'?'Firstmate to agent':'Agent to firstmate';
      meta.appendChild(d);
      var t=document.createElement('span');t.textContent=r.ts;meta.appendChild(t);
      var c1=chip(r.corr),c2=chip(r.state);
      if(c1)meta.appendChild(c1);if(c2)meta.appendChild(c2);
      art.appendChild(meta);
      var pre=document.createElement('pre');pre.textContent=r.body;art.appendChild(pre);
      sec.appendChild(art);
    });
    logEl.appendChild(sec);
  });
  stampEl.textContent='Updated '+data.generated_at+' UTC.';
  apply();
}
function apply(){
  var a=agentEl.value.toLowerCase(),d=dirEl.value,t=qEl.value.toLowerCase(),n=0;
  logEl.querySelectorAll('section[data-agent]').forEach(function(s){
    var vis=0;
    s.querySelectorAll('article.entry').forEach(function(e){
      var ok=(!a||s.getAttribute('data-agent').toLowerCase()===a)&&(!d||e.getAttribute('data-dir')===d)&&(!t||e.textContent.toLowerCase().indexOf(t)>=0);
      e.style.display=ok?'':'none';if(ok){vis++;n++;}
    });
    s.style.display=vis?'':'none';
  });
  countEl.textContent=n+' entries shown';
}
[agentEl,dirEl,qEl].forEach(function(el){el.addEventListener('input',apply);});
render(JSON.parse(document.getElementById('initial').textContent));
function poll(){
  fetch('events.json',{cache:'no-store'}).then(function(r){
    if(!r.ok)throw new Error(r.status);return r.json();
  }).then(function(data){liveEl.classList.remove('stale');render(data);}).catch(function(){
    liveEl.textContent='live (disconnected, showing last snapshot)';liveEl.classList.add('stale');
  });
}
if(POLL_SECS>0){__POLLJS__}
</script></body></html>
"""


def render_page(payload, refresh):
    initial = json.dumps(payload).replace("<", "\\u003c")
    polljs = "setInterval(poll,%s*1000);" % refresh if refresh != "0" else ""
    return PAGE_TEMPLATE.replace("__POLLJS__", polljs).replace("__POLL__", refresh).replace("__INITIAL__", initial)


class Handler(BaseHTTPRequestHandler):
    server_version = "FleetMessageLog/1"

    def log_message(self, *args):
        pass

    def _send(self, code, ctype, body):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index.html"):
            self._send(200, "text/html", render_page(collect(STATE_DIR), REFRESH))
        elif self.path == "/events.json":
            self._send(200, "application/json", json.dumps(collect(STATE_DIR)))
        else:
            self._send(404, "text/plain", "not found")


if MODE == "serve":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
else:
    payload = collect(STATE_DIR)
    with open(sys.argv[4], "w", encoding="utf-8") as fh:
        fh.write(render_page(payload, REFRESH) + "\n")
    with open(os.path.join(os.path.dirname(sys.argv[4]), "events.json"), "w", encoding="utf-8") as fh:
        fh.write(json.dumps(payload))
    print("page: %s" % sys.argv[4])
PYEOF
}

if [ "$SERVE" -eq 1 ]; then
  echo "serve: http://127.0.0.1:$PORT/ (loopback only, Ctrl-C to stop)"
  run_py serve "$STATE_DIR" "$REFRESH" "$PORT"
else
  run_py build "$STATE_DIR" "$REFRESH" "$OUT_DIR/index.html"
fi
