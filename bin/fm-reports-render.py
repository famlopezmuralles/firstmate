#!/usr/bin/env python3
"""fm-reports-render.py - render a discovery manifest into the reports catalog.

Usage:
  fm-reports-render.py <publish-root> < manifest.json

Reads one "fm-reports-manifest.v1" JSON document on stdin (produced by
bin/fm-reports-publish.sh) and writes, under <publish-root>:
  <project>/<task-id>/<slug>.html  one sanitized page per report
  <project>/<task-id>/<file>.md    the persisted source markdown report
  <project>/index.html             static project index page
  catalog.json                     the client-side dataset
  index.html                       static root catalog index

Every report body is HTML-escaped before any markup is reconstructed, so
source content can never inject a tag, attribute, or script; only a small
fixed subset of Markdown (headings, paragraphs, emphasis, inline/fenced code,
lists, tables, horizontal rules, and http(s) links/autolinks) is rendered,
and anything else passes through as literal escaped text. This is a renderer,
not a summarizer: it never adds, reorders, or interprets report content.
"""
from __future__ import annotations

import collections
import html
import json
import os
import re
import shutil
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


def normalize_project_slug(raw_project: str | None) -> str:
    if not raw_project:
        return "general"
    p = raw_project.strip().split("/")[-1].lower()
    if p and SAFE_ID_RE.match(p):
        return p
    return "general"


def is_historical_name(stem: str) -> bool:
    s = stem.lower()
    return "prior" in s or "before" in s


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
body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;
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
.nav-bar{margin-bottom:1.5rem;font-size:0.95rem;}
.projects-nav{margin:1rem 0;padding:0.75rem 1rem;border:1px solid #8884;border-radius:8px;font-size:0.9rem;}
.projects-nav strong{margin-right:0.5rem;}
.projects-nav a{margin-right:0.6rem;display:inline-block;}
@media (max-width:600px){body{padding:1rem;}}
"""


def report_page_html(
    title: str,
    project_label: str,
    provenance_rows: list[tuple[str, str]],
    body_html: str,
    historical: bool,
) -> str:
    rows = "".join(
        f"<dt>{html.escape(k)}</dt><dd>{v}</dd>" for k, v in provenance_rows
    )
    badge = ' <span class="badge">historical / superseded</span>' if historical else ""
    safe_title = html.escape(title)
    safe_proj = html.escape(project_label)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{safe_title}</title>
<style>{PAGE_CSS}</style>
</head><body>
<p class="nav-bar"><a href="../index.html">&larr; Back to {safe_proj} reports</a> &middot; <a href="../../index.html">All reports</a></p>
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
const q = document.querySelector('#q');
if (q) {
  q.addEventListener('input', () => {
    const term = q.value.toLowerCase();
    const rows = document.querySelectorAll('#catalog tbody tr');
    for (const row of rows) {
      const text = row.textContent.toLowerCase();
      row.style.display = text.includes(term) ? '' : 'none';
    }
  });
}
"""


def project_index_html(project_slug: str, reports: list[dict]) -> str:
    safe_proj = html.escape(project_slug)
    tbody_rows: list[str] = []
    for r in reports:
        tr_class = ' class="historical"' if r.get("historical") else ""
        badge = ' <span class="badge">historical</span>' if r.get("historical") else ""
        title_esc = html.escape(r.get("title") or r.get("task_id", ""))
        stem_html = os.path.basename(r.get("html_path", "report.html"))
        task_id = html.escape(r.get("task_id", ""))
        rel_html = f"{task_id}/{stem_html}"
        filename = html.escape(r.get("filename") or "report.md")
        rel_md = f"{task_id}/{filename}"
        home_esc = html.escape(r.get("home", ""))
        updated_esc = html.escape(r.get("updated", "unknown"))
        pr_cell = ""
        pr_url = r.get("pr_url")
        if pr_url and URL_RE.match(pr_url):
            safe_pr = html.escape(pr_url, quote=True)
            pr_cell = f'<a href="{safe_pr}" target="_blank" rel="noopener noreferrer">PR</a>'

        tbody_rows.append(
            f"""<tr{tr_class}>
<td><a href="{rel_html}">{title_esc}{badge}</a></td>
<td><a href="{rel_md}">{filename}</a></td>
<td>{task_id}</td>
<td>{home_esc}</td>
<td>{updated_esc}</td>
<td>{pr_cell}</td>
</tr>"""
        )

    tbody_html = "\n".join(tbody_rows)
    count = len(reports)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{safe_proj} reports</title>
<style>{INDEX_CSS}</style>
</head><body>
<p class="nav-bar"><a href="../index.html">&larr; Back to all reports</a></p>
<h1>{safe_proj} reports</h1>
<p>{count} report(s). Local machine only.</p>
<input id="q" type="search" placeholder="Filter {safe_proj} reports&hellip;">
<table class="catalog" id="catalog">
<thead><tr><th>Report</th><th>Source</th><th>Task</th><th>Home</th><th>Updated</th><th>PR</th></tr></thead>
<tbody>
{tbody_html}
</tbody>
</table>
<script>{INDEX_JS}</script>
</body></html>
"""


def root_index_html(
    generated: str,
    reports: list[dict],
    projects: list[str],
    unavailable: list[dict],
    limitations: list[str],
) -> str:
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

    proj_counts = collections.Counter(r.get("project") or "general" for r in reports)
    sorted_projs = sorted(projects, key=lambda p: p.lower())
    proj_links = " &middot; ".join(
        f'<a href="{html.escape(p)}/index.html">{html.escape(p)} ({proj_counts[p]})</a>'
        for p in sorted_projs
    )
    projects_nav = f'<nav class="projects-nav"><strong>Projects:</strong> {proj_links}</nav>' if sorted_projs else ""

    tbody_rows: list[str] = []
    for r in reports:
        tr_class = ' class="historical"' if r.get("historical") else ""
        badge = ' <span class="badge">historical</span>' if r.get("historical") else ""
        title_esc = html.escape(r.get("title") or r.get("task_id", ""))
        html_path = html.escape(r.get("html_path", ""))
        proj = html.escape(r.get("project") or "general")
        proj_link = f'<a href="{proj}/index.html">{proj}</a>'
        task_id = html.escape(r.get("task_id", ""))
        home_esc = html.escape(r.get("home", ""))
        updated_esc = html.escape(r.get("updated", "unknown"))
        pr_cell = ""
        pr_url = r.get("pr_url")
        if pr_url and URL_RE.match(pr_url):
            safe_pr = html.escape(pr_url, quote=True)
            pr_cell = f'<a href="{safe_pr}" target="_blank" rel="noopener noreferrer">PR</a>'

        tbody_rows.append(
            f"""<tr{tr_class}>
<td><a href="{html_path}">{title_esc}{badge}</a></td>
<td>{proj_link}</td>
<td>{task_id}</td>
<td>{home_esc}</td>
<td>{updated_esc}</td>
<td>{pr_cell}</td>
</tr>"""
        )

    tbody_html = "\n".join(tbody_rows)
    count = len(reports)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Firstmate report catalog</title>
<style>{INDEX_CSS}</style>
</head><body>
<h1>Firstmate report catalog</h1>
<p>Generated {html.escape(generated)}. {count} report(s). Local machine only.</p>
{unavailable_html}
{projects_nav}
<input id="q" type="search" placeholder="Search by title, project, home, or task id&hellip;">
<table class="catalog" id="catalog">
<thead><tr><th>Report</th><th>Project</th><th>Task</th><th>Home</th><th>Updated</th><th>PR</th></tr></thead>
<tbody>
{tbody_html}
</tbody>
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
    skipped: list[str] = []
    persisted_reports: dict[tuple[str, str, str], dict] = {}

    os.makedirs(publish_root, exist_ok=True)

    # 1. Load existing reports from catalog.json if present
    catalog_path = os.path.join(publish_root, "catalog.json")
    if os.path.isfile(catalog_path):
        try:
            with open(catalog_path, "r", encoding="utf-8") as fh:
                old_catalog = json.load(fh)
            for r in old_catalog.get("reports", []):
                proj = normalize_project_slug(r.get("project"))
                task_id = r.get("task_id", "")
                html_path = r.get("html_path", "")
                if not task_id or not SAFE_ID_RE.match(task_id):
                    continue

                # Migrate from legacy reports/<home>/<task_id>/<stem>.html if present
                old_full = os.path.join(publish_root, html_path)
                if html_path.startswith("reports/") and os.path.isfile(old_full):
                    stem = os.path.splitext(os.path.basename(html_path))[0]
                    new_rel = f"{proj}/{task_id}/{stem}.html"
                    new_full = os.path.join(publish_root, new_rel)
                    os.makedirs(os.path.dirname(new_full), exist_ok=True)
                    if not os.path.isfile(new_full):
                        shutil.copy2(old_full, new_full)
                    html_path = new_rel
                    r["html_path"] = new_rel

                if os.path.isfile(os.path.join(publish_root, html_path)):
                    stem = os.path.splitext(os.path.basename(html_path))[0]
                    r["project"] = proj
                    if not r.get("filename"):
                        r["filename"] = f"{stem}.md"
                    persisted_reports[(proj, task_id, stem)] = r
        except Exception as exc:
            print(f"fm-reports-render: warning: could not load existing catalog.json: {exc}", file=sys.stderr)

    # 2. Scan disk for any existing published report pages not yet in persisted_reports
    try:
        for proj_entry in os.scandir(publish_root):
            if not proj_entry.is_dir() or proj_entry.name.startswith(".") or proj_entry.name in ("reports", "redesigns"):
                continue
            proj_slug = normalize_project_slug(proj_entry.name)
            for task_entry in os.scandir(proj_entry.path):
                if not task_entry.is_dir() or task_entry.name.startswith("."):
                    continue
                task_id = task_entry.name
                if not SAFE_ID_RE.match(task_id):
                    continue
                for file_entry in os.scandir(task_entry.path):
                    if file_entry.is_file() and file_entry.name.endswith(".html") and file_entry.name != "index.html":
                        stem = file_entry.name[:-5]
                        if not SAFE_ID_RE.match(stem):
                            continue
                        key = (proj_slug, task_id, stem)
                        if key not in persisted_reports:
                            stat = file_entry.stat()
                            mtime = datetime.fromtimestamp(stat.st_mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                            md_name = f"{stem}.md"
                            if not os.path.isfile(os.path.join(task_entry.path, md_name)):
                                md_name = "report.md" if os.path.isfile(os.path.join(task_entry.path, "report.md")) else f"{stem}.md"
                            title = stem.replace("-", " ").replace("_", " ")
                            persisted_reports[key] = {
                                "title": title,
                                "home": "local",
                                "project": proj_slug,
                                "task_id": task_id,
                                "filename": md_name,
                                "updated": mtime,
                                "pr_url": None,
                                "html_path": f"{proj_slug}/{task_id}/{file_entry.name}",
                                "historical": is_historical_name(stem),
                            }
    except Exception as exc:
        print(f"fm-reports-render: warning: scanning publish root: {exc}", file=sys.stderr)

    # 3. Process reports from current manifest
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

            raw_project = report.get("project")
            proj_slug = normalize_project_slug(raw_project)
            project_label = raw_project.strip() if raw_project and raw_project.strip() else proj_slug

            title = report.get("title") or stem.replace("-", " ").replace("_", " ")
            body_html = render_markdown(raw)
            historical = bool(report.get("historical"))
            provenance = [
                ("Home", html.escape(home_label)),
                ("Task", html.escape(task_id)),
                ("Project", f'<a href="../index.html">{html.escape(project_label)}</a>'),
                ("Source markdown", f'<a href="{html.escape(filename)}">{html.escape(filename)}</a>'),
                ("Source file", html.escape(report.get("display_path", filename))),
                ("Last updated", html.escape(report.get("mtime", "unknown"))),
            ]
            pr_url = report.get("pr_url")
            if pr_url and URL_RE.match(pr_url):
                safe_pr = html.escape(pr_url, quote=True)
                provenance.append(("Linked PR", f'<a href="{safe_pr}" target="_blank" rel="noopener noreferrer">{html.escape(pr_url)}</a>'))
            backlog_state = report.get("backlog_state")
            if backlog_state:
                provenance.append(("Backlog state", html.escape(backlog_state)))

            task_dir = os.path.join(publish_root, proj_slug, task_id)
            os.makedirs(task_dir, exist_ok=True)

            # Persist source markdown
            md_out_path = os.path.join(task_dir, filename)
            try:
                shutil.copy2(content_path, md_out_path)
            except Exception:
                write_file(md_out_path, raw)

            # Render HTML page
            rel_html_path = f"{proj_slug}/{task_id}/{stem}.html"
            out_html_path = os.path.join(publish_root, rel_html_path)
            page = report_page_html(title, project_label, provenance, body_html, historical)
            write_file(out_html_path, page)

            key = (proj_slug, task_id, stem)
            persisted_reports[key] = {
                "title": title,
                "home": home_label,
                "project": proj_slug,
                "task_id": task_id,
                "filename": filename,
                "updated": report.get("mtime", "unknown"),
                "pr_url": pr_url if pr_url and URL_RE.match(pr_url) else None,
                "html_path": rel_html_path,
                "historical": historical,
            }

    all_reports = list(persisted_reports.values())
    all_reports.sort(key=lambda r: (r.get("historical", False), r.get("updated") or ""), reverse=False)
    all_reports.sort(key=lambda r: r.get("updated") or "", reverse=True)

    by_project: dict[str, list[dict]] = collections.defaultdict(list)
    for r in all_reports:
        by_project[r["project"]].append(r)

    # Write project index pages
    for proj_slug, proj_reports in by_project.items():
        proj_index_path = os.path.join(publish_root, proj_slug, "index.html")
        write_file(proj_index_path, project_index_html(proj_slug, proj_reports))

    # Write root catalog.json
    write_file(
        os.path.join(publish_root, "catalog.json"),
        json.dumps({"generated": generated, "reports": all_reports}, indent=2),
    )

    # Write root index.html
    write_file(
        os.path.join(publish_root, "index.html"),
        root_index_html(generated, all_reports, list(by_project.keys()), manifest.get("unavailable", []), manifest.get("limitations", [])),
    )

    if skipped:
        print("fm-reports-render: skipped entries:", file=sys.stderr)
        for line in skipped:
            print(f"  {line}", file=sys.stderr)

    print(f"fm-reports-render: wrote {len(all_reports)} report page(s) to {publish_root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
