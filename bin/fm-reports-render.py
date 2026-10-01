#!/usr/bin/env python3
"""fm-reports-render.py - render a discovery manifest into the reports catalog.

Usage:
  fm-reports-render.py <publish-root> < manifest.json

Reads one "fm-reports-manifest.v1" JSON document on stdin (produced by
bin/fm-reports-publish.sh) and writes, under <publish-root>:
  reports/<home-id>/<task-id>/<slug>.html  one sanitized page per report
  catalog.json                             the client-side search dataset
  index.html                               the catalog shell (title/project/
                                            date navigation and search)

Every report body is HTML-escaped before any markup is reconstructed, so
source content can never inject a tag, attribute, or script; only a small
fixed subset of Markdown (headings, paragraphs, emphasis, inline/fenced code,
lists, tables, horizontal rules, and http(s) links/autolinks) is rendered,
and anything else passes through as literal escaped text. This is a renderer,
not a summarizer: it never adds, reorders, or interprets report content.
"""
from __future__ import annotations

import html
import json
import os
import re
import sys
from datetime import datetime, timezone

SAFE_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
URL_RE = re.compile(r"^https?://", re.IGNORECASE)
TOKEN_RE = re.compile(r"\x00T(\d+)\x00")

TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
HR_RE = re.compile(r"^(?:-{3,}|\*{3,}|_{3,})\s*$")
FENCE_RE = re.compile(r"^```")
UL_RE = re.compile(r"^\s*[-*]\s+(.*)$")
OL_RE = re.compile(r"^\s*\d+[.)]\s+(.*)$")
BARE_URL_RE = re.compile(r"https?://[^\s<>\"'\]\)]+", re.IGNORECASE)
MD_LINK_RE = re.compile(r"\[([^\]\n]*)\]\(([^)\s]+)\)")
CODE_SPAN_RE = re.compile(r"`([^`\n]+)`")
BOLD_RE = re.compile(r"\*\*([^*\n]+)\*\*")
ITALIC_RE = re.compile(r"(?<!\*)\*([^*\n]+)\*(?!\*)|_([^_\n]+)_")


def safe_component(value: str) -> str:
    if not value or not SAFE_ID_RE.match(value):
        raise ValueError(f"unsafe path component: {value!r}")
    return value


class TokenBox:
    """Protects already-finished inline HTML from further inline passes."""

    def __init__(self) -> None:
        self._store: list[str] = []

    def put(self, finished_html: str) -> str:
        idx = len(self._store)
        self._store.append(finished_html)
        return f"\x00T{idx}\x00"

    def restore(self, text: str) -> str:
        def sub(match: "re.Match[str]") -> str:
            return self._store[int(match.group(1))]

        return TOKEN_RE.sub(sub, text)


def render_inline(raw: str, box: TokenBox) -> str:
    """Escape raw text, then reconstruct a small safe inline subset."""
    escaped = html.escape(raw, quote=True)

    def code_sub(match: "re.Match[str]") -> str:
        return box.put(f"<code>{match.group(1)}</code>")

    escaped = CODE_SPAN_RE.sub(code_sub, escaped)

    def md_link_sub(match: "re.Match[str]") -> str:
        label, url = match.group(1), match.group(2)
        url = html.unescape(url)
        if not URL_RE.match(url):
            return box.put(label)
        safe_url = html.escape(url, quote=True)
        return box.put(
            f'<a href="{safe_url}" rel="noopener noreferrer" target="_blank">{label}</a>'
        )

    escaped = MD_LINK_RE.sub(md_link_sub, escaped)

    def bare_url_sub(match: "re.Match[str]") -> str:
        url = match.group(0)
        trail = ""
        while url and url[-1] in ".,;:)!?’”":
            trail = url[-1] + trail
            url = url[:-1]
        if not url:
            return match.group(0)
        safe_url = html.escape(url, quote=True)
        return box.put(
            f'<a href="{safe_url}" rel="noopener noreferrer" target="_blank">{safe_url}</a>'
        ) + trail

    escaped = BARE_URL_RE.sub(bare_url_sub, escaped)
    escaped = BOLD_RE.sub(lambda m: f"<strong>{m.group(1)}</strong>", escaped)
    escaped = ITALIC_RE.sub(
        lambda m: f"<em>{m.group(1) if m.group(1) is not None else m.group(2)}</em>",
        escaped,
    )
    return box.restore(escaped)


def split_table_row(line: str) -> list[str]:
    stripped = line.strip()
    if stripped.startswith("|"):
        stripped = stripped[1:]
    if stripped.endswith("|"):
        stripped = stripped[:-1]
    return [cell.strip() for cell in re.split(r"(?<!\\)\|", stripped)]


def render_markdown(raw_text: str) -> str:
    text = raw_text.replace("\x00", "")
    lines = text.splitlines()
    out: list[str] = []
    paragraph: list[str] = []
    box = TokenBox()

    def flush_paragraph() -> None:
        if paragraph:
            joined = " ".join(paragraph)
            out.append(f"<p>{render_inline(joined, box)}</p>")
            paragraph.clear()

    i = 0
    n = len(lines)
    list_stack: list[str] = []

    def close_lists() -> None:
        while list_stack:
            out.append(f"</{list_stack.pop()}>")

    while i < n:
        line = lines[i]

        if FENCE_RE.match(line.strip()):
            flush_paragraph()
            close_lists()
            code_lines: list[str] = []
            i += 1
            while i < n and not FENCE_RE.match(lines[i].strip()):
                code_lines.append(lines[i])
                i += 1
            i += 1
            body = html.escape("\n".join(code_lines), quote=True)
            out.append(f"<pre><code>{body}</code></pre>")
            continue

        if not line.strip():
            flush_paragraph()
            close_lists()
            i += 1
            continue

        heading_match = HEADING_RE.match(line)
        if heading_match:
            flush_paragraph()
            close_lists()
            level = len(heading_match.group(1))
            out.append(f"<h{level}>{render_inline(heading_match.group(2), box)}</h{level}>")
            i += 1
            continue

        if HR_RE.match(line.strip()):
            flush_paragraph()
            close_lists()
            out.append("<hr>")
            i += 1
            continue

        if (
            "|" in line
            and i + 1 < n
            and TABLE_SEP_RE.match(lines[i + 1])
            and "|" in lines[i + 1]
        ):
            flush_paragraph()
            close_lists()
            header_cells = split_table_row(line)
            i += 2
            body_rows: list[list[str]] = []
            while i < n and "|" in lines[i] and lines[i].strip():
                body_rows.append(split_table_row(lines[i]))
                i += 1
            out.append("<table><thead><tr>")
            for cell in header_cells:
                out.append(f"<th>{render_inline(cell, box)}</th>")
            out.append("</tr></thead><tbody>")
            for row in body_rows:
                out.append("<tr>")
                for cell in row:
                    out.append(f"<td>{render_inline(cell, box)}</td>")
                out.append("</tr>")
            out.append("</tbody></table>")
            continue

        ul_match = UL_RE.match(line)
        ol_match = None if ul_match else OL_RE.match(line)
        if ul_match or ol_match:
            flush_paragraph()
            tag = "ul" if ul_match else "ol"
            if not list_stack or list_stack[-1] != tag:
                close_lists()
                out.append(f"<{tag}>")
                list_stack.append(tag)
            item_text = (ul_match or ol_match).group(1)
            out.append(f"<li>{render_inline(item_text, box)}</li>")
            i += 1
            continue

        close_lists()
        paragraph.append(line.strip())
        i += 1

    flush_paragraph()
    close_lists()
    return "\n".join(out)


PAGE_CSS = """
:root{color-scheme:light dark;}
body{font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;
  max-width:860px;margin:0 auto;padding:1.5rem;line-height:1.55;}
header.provenance{border:1px solid #8884;border-radius:8px;padding:0.75rem 1rem;
  margin-bottom:1.5rem;font-size:0.9rem;}
header.provenance dl{display:grid;grid-template-columns:auto 1fr;gap:0.15rem 0.75rem;margin:0;}
header.provenance dt{font-weight:600;opacity:0.75;}
header.provenance dd{margin:0;word-break:break-word;}
table{border-collapse:collapse;width:100%;margin:1rem 0;}
th,td{border:1px solid #8884;padding:0.4rem 0.6rem;text-align:left;vertical-align:top;}
pre{background:#8881;padding:0.75rem;border-radius:6px;overflow-x:auto;white-space:pre-wrap;}
code{background:#8881;padding:0.1rem 0.3rem;border-radius:4px;}
pre code{background:none;padding:0;}
.badge{display:inline-block;font-size:0.75rem;border-radius:4px;padding:0.1rem 0.5rem;
  background:#c8891a33;border:1px solid #c8891a88;margin-left:0.5rem;}
a{word-break:break-word;}
@media (max-width:600px){body{padding:1rem;}}
"""


def report_page_html(title: str, provenance_rows: list[tuple[str, str]], body_html: str, historical: bool) -> str:
    rows = "".join(
        f"<dt>{html.escape(k)}</dt><dd>{v}</dd>" for k, v in provenance_rows
    )
    badge = '<span class="badge">historical / superseded</span>' if historical else ""
    safe_title = html.escape(title)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{safe_title}</title>
<style>{PAGE_CSS}</style>
</head><body>
<p><a href="../../../index.html">&larr; Back to report catalog</a></p>
<h1>{safe_title}{badge}</h1>
<header class="provenance"><dl>{rows}</dl></header>
{body_html}
</body></html>
"""


INDEX_CSS = PAGE_CSS + """
table.catalog{font-size:0.92rem;}
input#q{width:100%;padding:0.5rem;font-size:1rem;margin-bottom:1rem;
  box-sizing:border-box;}
.unavailable{border:1px solid #c0392b66;border-radius:8px;padding:0.75rem 1rem;
  margin:1rem 0;font-size:0.9rem;}
.limitations{opacity:0.8;font-size:0.85rem;}
tr.historical{opacity:0.65;}
"""

INDEX_JS = """
let ROWS = [];
function cell(text){ const d=document.createElement('td'); d.textContent=text||''; return d; }
function render(rows){
  const tbody = document.querySelector('#catalog tbody');
  tbody.innerHTML = '';
  for (const r of rows) {
    const tr = document.createElement('tr');
    if (r.historical) tr.className = 'historical';
    const titleTd = document.createElement('td');
    const a = document.createElement('a');
    a.href = r.html_path;
    a.textContent = r.title + (r.historical ? ' (historical)' : '');
    titleTd.appendChild(a);
    tr.appendChild(titleTd);
    tr.appendChild(cell(r.home));
    tr.appendChild(cell(r.project || 'unknown'));
    tr.appendChild(cell(r.task_id));
    tr.appendChild(cell(r.updated));
    const prTd = document.createElement('td');
    if (r.pr_url) {
      const pa = document.createElement('a');
      pa.href = r.pr_url; pa.textContent = 'PR'; pa.target = '_blank';
      pa.rel = 'noopener noreferrer';
      prTd.appendChild(pa);
    }
    tr.appendChild(prTd);
    tbody.appendChild(tr);
  }
}
function applyFilter(){
  const q = document.querySelector('#q').value.toLowerCase();
  if (!q) { render(ROWS); return; }
  render(ROWS.filter(r =>
    (r.title && r.title.toLowerCase().includes(q)) ||
    (r.project && r.project.toLowerCase().includes(q)) ||
    (r.home && r.home.toLowerCase().includes(q)) ||
    (r.task_id && r.task_id.toLowerCase().includes(q))
  ));
}
fetch('catalog.json').then(r => r.json()).then(data => {
  ROWS = data.reports || [];
  render(ROWS);
  document.querySelector('#q').addEventListener('input', applyFilter);
});
"""


def index_html(generated: str, unavailable: list[dict], limitations: list[str]) -> str:
    unavailable_html = ""
    if unavailable:
        items = "".join(
            f"<li>{html.escape(u.get('home', 'unknown'))}: {html.escape(u.get('reason', 'unavailable'))}</li>"
            for u in unavailable
        )
        unavailable_html = f"""<div class="unavailable"><strong>Some sources were unavailable this run:</strong>
<ul>{items}</ul></div>"""
    limitations_html = ""
    if limitations:
        items = "".join(f"<li>{html.escape(x)}</li>" for x in limitations)
        limitations_html = f'<p class="limitations">Known limitations:</p><ul class="limitations">{items}</ul>'
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Firstmate report catalog</title>
<style>{INDEX_CSS}</style>
</head><body>
<h1>Firstmate report catalog</h1>
<p>Generated {html.escape(generated)}. Local machine only.</p>
{unavailable_html}
<input id="q" type="search" placeholder="Search by title, project, home, or task id&hellip;">
<table class="catalog" id="catalog">
<thead><tr><th>Report</th><th>Home</th><th>Project</th><th>Task</th><th>Updated</th><th>PR</th></tr></thead>
<tbody></tbody>
</table>
{limitations_html}
<script>{INDEX_JS}</script>
</body></html>
"""


def write_file(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.replace(tmp, path)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: fm-reports-render.py <publish-root> < manifest.json", file=sys.stderr)
        return 2
    publish_root = sys.argv[1]
    manifest = json.load(sys.stdin)
    if manifest.get("schema") != "fm-reports-manifest.v1":
        print("fm-reports-render: unsupported manifest schema", file=sys.stderr)
        return 1

    generated = manifest.get("generated") or datetime.now(timezone.utc).isoformat()
    catalog_rows: list[dict] = []
    skipped: list[str] = []

    for home in manifest.get("homes", []):
        home_id = home.get("id", "")
        home_label = home.get("label", home_id)
        try:
            safe_component(home_id)
        except ValueError:
            skipped.append(f"home with unsafe id skipped: {home_id!r}")
            continue
        for report in home.get("reports", []):
            task_id = report.get("task_id", "")
            filename = report.get("filename", "")
            content_path = report.get("content_path")
            try:
                safe_component(task_id)
                stem, ext = os.path.splitext(filename)
                safe_component(stem)
                if ext != ".md":
                    raise ValueError("report filename must end in .md")
            except ValueError as exc:
                skipped.append(f"{home_id}/{task_id}/{filename}: {exc}")
                continue
            if not content_path or not os.path.isfile(content_path):
                skipped.append(f"{home_id}/{task_id}/{filename}: content unavailable")
                continue
            with open(content_path, "r", encoding="utf-8", errors="replace") as fh:
                raw = fh.read()

            title = report.get("title") or stem.replace("-", " ").replace("_", " ")
            body_html = render_markdown(raw)
            historical = bool(report.get("historical"))
            provenance = [
                ("Home", html.escape(home_label)),
                ("Task", html.escape(task_id)),
                ("Source file", html.escape(report.get("display_path", filename))),
                ("Last updated", html.escape(report.get("mtime", "unknown"))),
            ]
            project = report.get("project")
            if project:
                provenance.append(("Project", html.escape(project)))
            pr_url = report.get("pr_url")
            if pr_url and URL_RE.match(pr_url):
                safe_pr = html.escape(pr_url, quote=True)
                provenance.append(("Linked PR", f'<a href="{safe_pr}">{html.escape(pr_url)}</a>'))
            backlog_state = report.get("backlog_state")
            if backlog_state:
                provenance.append(("Backlog state", html.escape(backlog_state)))

            rel_html_path = f"reports/{home_id}/{task_id}/{stem}.html"
            out_path = os.path.join(publish_root, rel_html_path)
            page = report_page_html(title, provenance, body_html, historical)
            write_file(out_path, page)

            catalog_rows.append(
                {
                    "title": title,
                    "home": home_label,
                    "project": project,
                    "task_id": task_id,
                    "updated": report.get("mtime", "unknown"),
                    "pr_url": pr_url if pr_url and URL_RE.match(pr_url) else None,
                    "html_path": rel_html_path,
                    "historical": historical,
                }
            )

    catalog_rows.sort(key=lambda r: (r["historical"], r["updated"] or ""), reverse=False)
    catalog_rows.sort(key=lambda r: r["updated"] or "", reverse=True)

    write_file(
        os.path.join(publish_root, "catalog.json"),
        json.dumps({"generated": generated, "reports": catalog_rows}, indent=2),
    )
    write_file(
        os.path.join(publish_root, "index.html"),
        index_html(generated, manifest.get("unavailable", []), manifest.get("limitations", [])),
    )

    if skipped:
        print("fm-reports-render: skipped entries:", file=sys.stderr)
        for line in skipped:
            print(f"  {line}", file=sys.stderr)

    print(f"fm-reports-render: wrote {len(catalog_rows)} report page(s) to {publish_root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
