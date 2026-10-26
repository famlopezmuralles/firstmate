#!/usr/bin/env node
/**
 * fm-slack-bridge.mjs - the Slack bridge process (docs/slack-bridge.md owns setup).
 *
 * A small opt-in process that carries firstmate conversation and alerts over a
 * captain-owned Slack app without exposing anything publicly. The wrapper
 * bin/fm-slack-bridge.sh is the public entrypoint: it resolves configuration
 * from FM_HOME/.env through bin/fm-env-lib.sh (the single .env read owner),
 * exports it as environment variables, and execs this file. This file reads
 * configuration ONLY from its environment and never logs tokens or message
 * bodies.
 *
 * What it does (docs/slack-bridge.md owns the operator contract):
 *   inbound  allow-listed Slack messages become durable notes through
 *            `bin/fm-inbox.sh note --request-id <channel>:<ts>`, so a Slack
 *            redelivery replays instead of duplicating. Exit 3 (saved but the
 *            wake append did not confirm) is repaired with the documented
 *            `announce` subcommand.
 *   outbound replies firstmate records with `bin/fm-inbox.sh reply` are read
 *            through the documented `receipts --after <cursor>` cursor and
 *            posted into the thread of the original Slack message. Replies to
 *            notes the bridge did not file are left alone.
 *   alerts   two configurable channels. The action channel carries captain
 *            decisions and review-ready PRs; the status channel carries
 *            worker-health, disk, and wedge events. Every alert class reads a
 *            durable record owner (default: `bin/fm-bearings-snapshot.sh
 *            --json` for fleet state, `df` for disk, `bin/fm-inbox.sh ready`
 *            for wedge resolution) - never conversation memory. Event classes
 *            that no listed durable record exposes (red CI, quota out of
 *            band, stalled validation, credential asks) are NOT covered and
 *            docs/slack-bridge.md says so explicitly.
 *   messages the fleet message log (firstmate steers plus agent status
 *            lines, read through `bin/fm-fleet-message-log.sh --json`, which
 *            stays the single owner of entry identity and derivation) posts
 *            each entry once, full text, to one optional channel. The first
 *            start with the key set records every current entry as a silent
 *            baseline and posts nothing old. Inbound captain notes and
 *            outbound replies live outside those records, so message posts
 *            cannot loop back into the channel.
 *   reactions the bot marks each alert from record state: bell (pending),
 *            hammer_and_wrench (in progress), white_check_mark (resolved),
 *            alarm_clock (still unattended, with a capped repeat notice).
 *            Captain reactions may only acknowledge (eyes = silence) or snooze
 *            (zzz = default date). ANY other reaction is ignored; a reaction
 *            can never approve a merge, a destructive action, or a decision.
 *
 * Transports:
 *   socket (default) Slack Socket Mode via apps.connections.open and the
 *            Node built-in WebSocket (Node >= 21; the fleet standard runtime
 *            is Node 22). No package dependency is added.
 *   poll     REST polling of conversations.history for the configured
 *            channels plus reactions.get for live alerts. Used as a fallback
 *            and as the test seam; it does not see DMs (documented limit).
 *
 * Test seams (production leaves these unset):
 *   FM_SLACK_API_URL      override https://slack.com/api for the REST client.
 *   FM_SLACK_SNAPSHOT_CMD command whose stdout is the fleet snapshot JSON
 *                         (default runs bin/fm-bearings-snapshot.sh).
 *   FM_SLACK_MESSAGES_LIMIT per-post character cap for message-log posts
 *                         (default 39000); oversized posts split into
 *                         marked parts.
 *
 * State lives in $FM_HOME/data/slack-bridge/bridge/state.json. That is the
 * bridge's private directory under the gitignored data/ tree; the bridge
 * never writes state/ except through the fm-inbox.sh surface.
 *
 * Usage (normally through bin/fm-slack-bridge.sh):
 *   fm-slack-bridge.mjs run [--transport socket|poll] [--once]
 *   fm-slack-bridge.mjs wedge
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const HOME = process.env.FM_HOME || REPO_ROOT;
const INBOX = path.join(REPO_ROOT, "bin", "fm-inbox.sh");
const STATE_DIR = path.join(HOME, "data", "slack-bridge", "bridge");
const STATE_FILE = path.join(STATE_DIR, "state.json");
const STATE_VERSION = 1;

// Reaction vocabulary. bell/hammer/check are the bot's own record-driven
// markers; alarm_clock is the unattended marker; eyes/zzz are the ONLY
// captain reactions acted on, and they only silence or snooze.
const MARK_PENDING = "bell";
const MARK_PROGRESS = "hammer_and_wrench";
const MARK_DONE = "white_check_mark";
const MARK_UNATTENDED = "alarm_clock";
// Bot markers on inbound captain messages: inbox_tray when the message is
// filed as a note, white_check_mark when firstmate's reply lands in its
// thread. Neither clashes with the captain's eyes (silence) or zzz (snooze).
const MARK_RECEIVED = "inbox_tray";
const MARK_REPLIED = "white_check_mark";
const CAPTAIN_ACK = "eyes";
const CAPTAIN_SNOOZE = "zzz";
const PERMANENT_POST_ERRORS = new Set([
  "channel_not_found",
  "is_archived",
  "not_in_channel",
  "missing_scope",
]);

const DEFAULTS = {
  pollSecs: 10,
  alertSecs: 60,
  unattendedSecs: 1800,
  repeatMax: 2,
  snoozeSecs: 86400,
  diskPct: 90,
  diskPath: "/",
};

function envInt(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

function cfg() {
  const allow = (process.env.FM_SLACK_ALLOW_USERS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return {
    botToken: process.env.FM_SLACK_BOT_TOKEN || "",
    appToken: process.env.FM_SLACK_APP_TOKEN || "",
    allow,
    actionChannel: process.env.FM_SLACK_ACTION_CHANNEL || "",
    statusChannel: process.env.FM_SLACK_STATUS_CHANNEL || "",
    pollChannels: (process.env.FM_SLACK_POLL_CHANNELS ||
      [process.env.FM_SLACK_ACTION_CHANNEL, process.env.FM_SLACK_STATUS_CHANNEL]
        .filter(Boolean)
        .join(","))
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
    messagesChannel: process.env.FM_SLACK_MESSAGES_CHANNEL || "",
    apiUrl: process.env.FM_SLACK_API_URL || "https://slack.com/api",
    snapshotCmd: process.env.FM_SLACK_SNAPSHOT_CMD || "",
    pollSecs: envInt("FM_SLACK_POLL_SECS", DEFAULTS.pollSecs),
    alertSecs: envInt("FM_SLACK_ALERT_SECS", DEFAULTS.alertSecs),
    unattendedSecs: envInt("FM_SLACK_UNATTENDED_SECS", DEFAULTS.unattendedSecs),
    repeatMax: envInt("FM_SLACK_REPEAT_MAX", DEFAULTS.repeatMax),
    snoozeSecs: envInt("FM_SLACK_SNOOZE_SECS", DEFAULTS.snoozeSecs),
    diskPct: envInt("FM_SLACK_DISK_PCT", DEFAULTS.diskPct),
    diskPath: process.env.FM_SLACK_DISK_PATH || DEFAULTS.diskPath,
  };
}

// Logs carry ids, endpoints, and outcomes only - never tokens and never
// message or alert text bodies.
function log(msg) {
  process.stderr.write(`[fm-slack-bridge] ${msg}\n`);
}

// ---------------------------------------------------------------- state ----

function emptyState() {
  return {
    version: STATE_VERSION,
    replyCursor: "",
    // channel id -> newest inbound message ts already read (poll transport)
    channelCursor: {},
    // firstmate note id -> {channel, ts} of the Slack message that filed it
    noteCoords: {},
    // alert key -> alert record (see postAlert)
    alerts: {},
    deadReplies: {},
    botUserId: "",
    // False until the first successful fleet read seeds every current
    // record as a silent baseline (fresh homes only; see alertPass).
    alertBaseline: false,
    // False until the first successful message-log read seeds every current
    // entry as a silent baseline; see messagesPass.
    messagesBaseline: false,
    // message-log entry id -> epoch seconds, so reposts never happen and old
    // ids can age out once their records are gone.
    messagesPosted: {},
  };
}

function loadState() {
  try {
    const raw = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
    if (raw && raw.version === STATE_VERSION) return { ...emptyState(), ...raw };
    log(`state version mismatch at ${STATE_FILE}; starting fresh`);
  } catch (e) {
    if (e.code !== "ENOENT") log(`state read failed (${e.message}); starting fresh`);
  }
  return emptyState();
}

function saveState(state) {
  fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const tmp = `${STATE_FILE}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 1) + "\n", { mode: 0o600 });
  fs.renameSync(tmp, STATE_FILE);
}

// ----------------------------------------------------------- slack api ----

async function slackApi(cfgv, method, params, token) {
  const body = new URLSearchParams();
  for (const [k, v] of Object.entries(params || {})) {
    if (v !== undefined && v !== null) body.set(k, String(v));
  }
  const res = await fetch(`${cfgv.apiUrl}/${method}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token || cfgv.botToken}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body,
  });
  if (!res.ok) throw new Error(`${method}: HTTP ${res.status}`);
  const json = await res.json();
  if (!json.ok) {
    const err = new Error(`${method}: ${json.error || "slack error"}`);
    err.slack = json;
    throw err;
  }
  return json;
}

// ------------------------------------------------------- fm-inbox calls ----

// Runs one documented fm-inbox.sh subcommand against the home. This is the
// only path through which the bridge touches firstmate's state/.
function inbox(args) {
  const res = spawnSync("bash", [INBOX, ...args], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: HOME },
    timeout: 60_000,
  });
  return { status: res.status, stdout: res.stdout || "", stderr: res.stderr || "" };
}

function parseJsonOut(res) {
  try {
    return JSON.parse(res.stdout);
  } catch {
    return null;
  }
}

// ------------------------------------------------------------- inbound ----

function requestIdFor(channel, ts) {
  // The Slack message id is its ts; the channel prefix keeps it unique across
  // channels. Both are [A-Za-z0-9.:_-], which fm-inbox request ids allow.
  return `${channel}:${ts}`;
}

async function inboundMessage(cfgv, state, event) {
  if (!event || event.type !== "message") return true;
  if (event.subtype) return true; // edits, joins, deletes - not captain chat
  if (event.bot_id || !event.user || !event.ts || !event.channel) return true;
  if (!event.text || !event.text.trim()) return true;
  if (!cfgv.allow.includes(event.user)) return true; // allow-list: drop silently

  const rid = requestIdFor(event.channel, event.ts);
  const res = inbox(["note", "--request-id", rid, "--json", "--", event.text]);
  const json = parseJsonOut(res);
  if (!json || !json.id) {
    log(`note failed for ${rid} (exit ${res.status})`);
    return false;
  }
  state.noteCoords[json.id] = { channel: event.channel, ts: event.ts };
  if (res.status === 3) {
    // Saved but the wake append did not confirm; the documented repair.
    const ann = inbox(["announce", "--json", json.id]);
    log(`note ${json.id} ${json.outcome}; announce exit ${ann.status}`);
  } else {
    log(`note ${json.id} ${json.outcome} from ${rid}`);
  }
  // Best effort: mark the Slack message received so the sender knows it
  // arrived even while the answer is minutes away. A marker failure never
  // blocks the filed note.
  try {
    await slackApi(cfgv, "reactions.add", {
      channel: event.channel,
      timestamp: event.ts,
      name: MARK_RECEIVED,
    });
  } catch (e) {
    log(`received marker failed for ${rid}: ${e.message}`);
  }
  return true;
}

// ------------------------------------------------------------ outbound ----

async function replyPass(cfgv, state) {
  const args = ["receipts", "--all-replies", "--all-pending", "--all-handled"];
  if (state.replyCursor) args.push("--after", state.replyCursor);
  const res = inbox(args);
  const json = parseJsonOut(res);
  if (!json) {
    log(`receipts read failed (exit ${res.status})`);
    return;
  }
  const coordsFor = (noteId) => {
    if (state.noteCoords[noteId]) return state.noteCoords[noteId];
    // Fallback: decode the request id the bridge filed this note under.
    for (const group of [...(json.pending || []), ...(json.handled || [])]) {
      if (group.id === noteId && typeof group.request_id === "string") {
        const i = group.request_id.indexOf(":");
        if (i > 0) {
          return {
            channel: group.request_id.slice(0, i),
            ts: group.request_id.slice(i + 1),
          };
        }
      }
    }
    return null;
  };
  // Advance the cursor per reply; stop at the first failed post so it is
  // retried next pass. Replies to notes the bridge did not file (no coords,
  // no Slack request id) are skipped permanently, never re-read.
  let advanced = state.replyCursor;
  for (const reply of json.replies || []) {
    const coords = coordsFor(reply.id);
    if (coords) {
      try {
        await slackApi(cfgv, "chat.postMessage", {
          channel: coords.channel,
          thread_ts: coords.ts,
          text: reply.body,
        });
        log(`reply for ${reply.id} posted to ${coords.channel} thread ${coords.ts}`);
        // Best effort: mark the original message replied. A marker failure
        // never unposts the delivered reply.
        try {
          await slackApi(cfgv, "reactions.add", {
            channel: coords.channel,
            timestamp: coords.ts,
            name: MARK_REPLIED,
          });
        } catch (e) {
          log(`replied marker failed for ${reply.id}: ${e.message}`);
        }
      } catch (e) {
        const code = e && e.slack && e.slack.error;
        if (code && PERMANENT_POST_ERRORS.has(code)) {
          state.deadReplies = state.deadReplies || {};
          if (!state.deadReplies[reply.id]) {
            state.deadReplies[reply.id] = code;
            log(`reply for ${reply.id} failed permanently (${code}); skipping`);
          }
          advanced = reply.cursor;
          continue;
        }
        log(`reply post failed for ${reply.id}: ${e.message}`);
        break;
      }
    }
    advanced = reply.cursor;
  }
  state.replyCursor = advanced;
}

// -------------------------------------------------------------- alerts ----

function alertText(cls, row, cfgv, extra) {
  switch (cls) {
    case "decision":
      return `Decision needed: ${row.summary || row.key} (task ${row.key})`;
    case "pr":
      return `PR ready for review: ${row.url} (task ${row.id})`;
    case "stuck":
      return `Worker stopped responding: ${row.id} (${row.target || "-"})`;
    case "disk":
      return `Disk nearly full: ${extra}% used on ${cfgv.diskPath} (threshold ${cfgv.diskPct}%)`;
    case "wedge":
      return `Wedge alarm: ${extra}`;
    default:
      return `${cls}: ${row && row.id ? row.id : ""}`;
  }
}

async function postAlert(cfgv, state, key, cls, channel, text) {
  const existing = state.alerts[key];
  if (existing) return existing;
  const json = await slackApi(cfgv, "chat.postMessage", { channel, text });
  const alert = {
    key,
    cls,
    channel,
    ts: json.ts,
    postedEpoch: Math.floor(Date.now() / 1000),
    marker: "",
    repeats: 0,
    silenced: false,
    snoozeUntil: 0,
    done: false,
  };
  state.alerts[key] = alert;
  await setMarker(cfgv, alert, MARK_PENDING);
  log(`alert ${key} posted to ${channel} as ${json.ts}`);
  return alert;
}

async function removeReaction(cfgv, alert, name) {
  try {
    await slackApi(cfgv, "reactions.remove", {
      channel: alert.channel,
      timestamp: alert.ts,
      name,
    });
    return true;
  } catch (e) {
    if (e && e.slack && e.slack.error === "no_reaction") return true;
    log(`reaction remove failed on ${alert.key}: ${e.message}`);
    return false;
  }
}

async function setMarker(cfgv, alert, marker) {
  if (alert.marker === marker) return;
  if (alert.marker && alert.marker !== MARK_UNATTENDED) {
    if (!(await removeReaction(cfgv, alert, alert.marker))) return;
  }
  if (marker) {
    try {
      await slackApi(cfgv, "reactions.add", {
        channel: alert.channel,
        timestamp: alert.ts,
        name: marker,
      });
    } catch (e) {
      log(`reaction add failed on ${alert.key}: ${e.message}`);
      return;
    }
  }
  alert.marker = marker;
}

async function finishAlert(cfgv, alert) {
  await setMarker(cfgv, alert, MARK_DONE);
  if (alert.marker !== MARK_DONE) return;
  if (alert.hasAlarm) {
    if (!(await removeReaction(cfgv, alert, MARK_UNATTENDED))) return;
    alert.hasAlarm = false;
  }
  alert.done = true;
}

async function readSnapshot() {
  const cmd = process.env.FM_SLACK_SNAPSHOT_CMD;
  let res;
  if (cmd) {
    res = spawnSync("bash", ["-c", cmd], { encoding: "utf8", timeout: 120_000 });
  } else {
    res = spawnSync(
      "bash",
      [
        path.join(REPO_ROOT, "bin", "fm-bearings-snapshot.sh"),
        "--json",
        "--all-decisions",
        "--all-recorded-prs",
        "--all-unhealthy",
      ],
      { encoding: "utf8", timeout: 120_000, env: { ...process.env, FM_HOME: HOME } },
    );
  }
  if (res.status !== 0) {
    log(`fleet snapshot read failed (exit ${res.status}); skipping alert pass`);
    return null;
  }
  try {
    return JSON.parse(res.stdout);
  } catch (e) {
    log(`fleet snapshot parse failed: ${e.message}`);
    return null;
  }
}

function diskUsedPct(cfgv) {
  const res = spawnSync("df", ["-P", cfgv.diskPath], { encoding: "utf8", timeout: 15_000 });
  if (res.status !== 0) return null;
  const line = res.stdout.trim().split("\n").pop();
  const cols = line.split(/\s+/);
  const pct = cols[4] ? parseInt(cols[4].replace("%", ""), 10) : NaN;
  return Number.isFinite(pct) ? pct : null;
}

// Reconciles one alert cycle from durable records. desired is a Map of
// alert key -> {cls, channel, row, extra, progress, resolved}. When
// absenceResolves is set (the fleet read succeeded), a live alert that no
// longer appears in desired is resolved: the record that raised it no longer
// lists it.
async function reconcileAlerts(cfgv, state, desired, absenceResolves) {
  for (const [key, want] of desired) {
    try {
    let alert = state.alerts[key];
    if (!alert) {
      // A class that only ever reports resolved (e.g. disk under threshold)
      // must never post a first alert just to finish it.
      if (want.resolved || !want.channel) continue;
      alert = await postAlert(cfgv, state, key, want.cls, want.channel, alertText(want.cls, want.row, cfgv, want.extra));
    }
    if (!alert.ts) {
      // Silent baseline entry from the first start: it has no Slack message,
      // so there is nothing to mark or resolve through the API. Still
      // present means still baselined; resolved means drop it silently, and
      // a later reappearance posts as a new alert through the !alert branch.
      if (want.resolved) delete state.alerts[key];
      continue;
    }
    if (want.resolved) {
      await finishAlert(cfgv, alert);
      continue;
    }
    if (alert.done) {
      alert.done = false;
      alert.silenced = false;
      alert.snoozeUntil = 0;
      alert.repeats = 0;
      alert.postedEpoch = Math.floor(Date.now() / 1000);
      await setMarker(cfgv, alert, MARK_PENDING);
    }
    const age = Math.floor(Date.now() / 1000) - alert.postedEpoch;
    const snoozed = alert.snoozeUntil > Date.now();
    if (want.progress) {
      await setMarker(cfgv, alert, MARK_PROGRESS);
    } else {
      await setMarker(cfgv, alert, MARK_PENDING);
    }
    if (!alert.silenced && !snoozed && age > cfgv.unattendedSecs && alert.repeats < cfgv.repeatMax) {
      try {
        if (!alert.hasAlarm) {
          await slackApi(cfgv, "reactions.add", {
            channel: alert.channel,
            timestamp: alert.ts,
            name: MARK_UNATTENDED,
          });
          alert.hasAlarm = true;
        }
        await slackApi(cfgv, "chat.postMessage", {
          channel: alert.channel,
          thread_ts: alert.ts,
          text: `Still unattended: ${alert.key} (notice ${alert.repeats + 1}/${cfgv.repeatMax})`,
        });
        alert.repeats += 1;
        log(`alert ${key} repeat ${alert.repeats}/${cfgv.repeatMax}`);
      } catch (e) {
        log(`repeat notice failed on ${key}: ${e.message}`);
      }
    }
    } catch (e) {
      log(`alert ${key} reconcile failed: ${e.message}`);
    }
  }
  // Absence resolution: the record owner no longer lists these alerts.
  if (absenceResolves) {
    for (const alert of Object.values(state.alerts)) {
      if (!desired.has(alert.key) && !alert.done) {
        if (!alert.ts) {
          delete state.alerts[alert.key];
          continue;
        }
        await finishAlert(cfgv, alert);
        log(`alert ${alert.key} resolved by absence from its record`);
      }
    }
  }
  // Retention: drop resolved alerts older than 30 days to bound the file.
  const cutoff = Date.now() / 1000 - 30 * 86400;
  for (const [key, alert] of Object.entries(state.alerts)) {
    if (alert.done && alert.postedEpoch < cutoff) delete state.alerts[key];
  }
}

function plural(n, one, many) {
  return `${n} ${n === 1 ? one : many}`;
}

// One short summary per channel for the first-start baseline: counts per
// class, never record bodies. Returns null when the channel baselined nothing.
function baselineSummary(role, tally) {
  const parts = [];
  if (role === "action") {
    if (tally.decision) parts.push(plural(tally.decision, "decision", "decisions"));
    if (tally.pr) parts.push(plural(tally.pr, "PR", "PRs"));
  } else {
    if (tally.stuck) parts.push(plural(tally.stuck, "stuck worker", "stuck workers"));
    if (tally.disk) parts.push("disk over threshold");
    if (tally.wedge) parts.push(plural(tally.wedge, "wedge alarm", "wedge alarms"));
  }
  if (parts.length === 0) return null;
  return `Bridge baseline: ${parts.join(", ")} already recorded; only new ones will alert individually.`;
}

// The very first successful fleet read seeds every current record as a silent
// baseline instead of alerting each one, then posts one short summary per
// channel with counts per class. Only records that appear after the baseline
// post individual alerts. Homes with an existing state file migrated from
// before this baseline existed keep their posted alerts and skip seeding.
async function seedBaseline(cfgv, state, desired) {
  const now = Math.floor(Date.now() / 1000);
  const tally = { action: { decision: 0, pr: 0 }, status: { stuck: 0, disk: 0, wedge: 0 } };
  for (const [key, want] of desired) {
    if (want.resolved || !want.channel) continue;
    if (state.alerts[key]) continue;
    state.alerts[key] = {
      key,
      cls: want.cls,
      channel: want.channel,
      ts: "",
      postedEpoch: now,
      marker: "",
      repeats: 0,
      silenced: true,
      snoozeUntil: 0,
      done: false,
      baseline: true,
    };
    log(`alert ${key} baselined silently on first start`);
    const bucket = want.channel === cfgv.actionChannel ? tally.action : tally.status;
    if (bucket && Object.hasOwn(bucket, want.cls)) bucket[want.cls] += 1;
  }
  for (const [role, channel, bucket] of [["action", cfgv.actionChannel, tally.action], ["status", cfgv.statusChannel, tally.status]]) {
    if (!channel) continue;
    const text = baselineSummary(role, bucket);
    if (!text) continue;
    try {
      await slackApi(cfgv, "chat.postMessage", { channel, text });
      log(`baseline summary posted to ${channel}`);
    } catch (e) {
      log(`baseline summary failed for ${channel}: ${e.message}`);
    }
  }
  state.alertBaseline = true;
}

async function alertPass(cfgv, state) {
  const desired = new Map();
  const snap = await readSnapshot();
  if (snap) {
    for (const row of snap.decisions_open || []) {
      desired.set(`decision:${row.id}`, {
        cls: "decision",
        channel: cfgv.actionChannel,
        row,
        progress: (snap.in_flight || []).some((w) => w.id === row.id),
        resolved: false,
      });
    }
    for (const row of snap.recorded_prs || []) {
      desired.set(`pr:${row.id}`, {
        cls: "pr",
        channel: cfgv.actionChannel,
        row,
        progress: (snap.in_flight || []).some((w) => w.id === row.id),
        resolved: false,
      });
    }
    for (const row of snap.unhealthy_endpoints || []) {
      desired.set(`stuck:${row.id}`, {
        cls: "stuck",
        channel: cfgv.statusChannel,
        row,
        progress: false,
        resolved: false,
      });
    }
  }
  // Disk: local system read; over threshold alerts, back under resolves.
  const pct = diskUsedPct(cfgv);
  if (pct !== null) {
    desired.set("disk", {
      cls: "disk",
      channel: cfgv.statusChannel,
      row: null,
      extra: pct,
      progress: false,
      resolved: pct < cfgv.diskPct,
    });
  } else if (state.alerts.disk && !state.alerts.disk.done) {
    desired.set("disk", {
      cls: "disk",
      channel: state.alerts.disk.channel,
      row: null,
      progress: false,
      resolved: false,
    });
  }
  // Wedge alerts resolve when the primary answers the documented readiness
  // read again; each wedge invocation is its own alert.
  const ready = inbox(["ready"]);
  if (ready.status !== 0) {
    for (const [key, alert] of Object.entries(state.alerts)) {
      if (alert.cls === "wedge" && !alert.done) {
        desired.set(key, { cls: "wedge", channel: alert.channel, row: null, progress: false, resolved: false });
      }
    }
  } else {
    for (const [key, alert] of Object.entries(state.alerts)) {
      if (alert.cls === "wedge" && !alert.done) {
        desired.set(key, { cls: "wedge", channel: alert.channel, row: null, progress: false, resolved: true });
      }
    }
  }
  // Absence resolution only when the fleet read succeeded: a failed read
  // must never resolve anything (it proves nothing about the records).
  // A failed read also defers the first-start baseline to the next cycle.
  if (snap !== null && !state.alertBaseline) await seedBaseline(cfgv, state, desired);
  await reconcileAlerts(cfgv, state, desired, snap !== null);
}

// ------------------------------------------------- fleet message log ----

// Reads the fleet message log through bin/fm-fleet-message-log.sh --json,
// which stays the single owner of entry identity, direction, timestamp, and
// correlation derivation. This pass only reads state/; it never writes to
// it and never rings, acks, or steers anything.
function readMessageLog() {
  const res = spawnSync(
    "bash",
    [path.join(REPO_ROOT, "bin", "fm-fleet-message-log.sh"), "--json",
     "--state-dir", path.join(HOME, "state")],
    { encoding: "utf8", timeout: 120_000, env: { ...process.env, FM_HOME: HOME } },
  );
  if (res.status !== 0) {
    log(`message log read failed (exit ${res.status}); skipping message pass`);
    return null;
  }
  try {
    return JSON.parse(res.stdout);
  } catch (e) {
    log(`message log parse failed: ${e.message}`);
    return null;
  }
}

// One post per entry: direction, agent id, timestamp, corr id when present,
// and steer acknowledgement state for firstmate-to-agent entries.
function formatMessagePost(agent, row) {
  const dir = row.dir === "out" ? "Firstmate to agent" : "Agent to firstmate";
  const head = [`fleet log | ${dir}`, `agent ${agent}`, row.ts || "unknown time"];
  if (row.corr) head.push(`corr ${row.corr}`);
  if (row.state) head.push(row.dir === "out" ? `steer ${row.state}` : row.state);
  return `${head.join(" | ")}\n${row.body || ""}`;
}

// Splits only past the per-post cap; every part carries its (part i/n)
// marker so the split says so in the channel.
function splitMessagePost(text, limit) {
  if (text.length <= limit) return [text];
  const width = Math.max(64, limit - 32); // room for the part marker below
  const raw = [];
  let rest = text;
  while (rest.length > width) {
    let cut = rest.lastIndexOf("\n", width);
    if (cut < width / 2) cut = width;
    raw.push(rest.slice(0, cut));
    rest = rest.slice(cut).replace(/^\n/, "");
    if (!rest) break;
  }
  if (rest) raw.push(rest);
  return raw.map((p, i) => `${p}\n(part ${i + 1}/${raw.length})`);
}

// Publishes each message-log entry once, oldest first. The first successful
// read with the key set records every current entry as a silent baseline
// and posts nothing old. A failed post breaks the queue without marking
// anything, so a burst waits for the next cycle instead of dropping silently.
// Logs carry entry ids, the channel, and outcomes only - never bodies.
async function messagesPass(cfgv, state) {
  const channel = cfgv.messagesChannel;
  if (!channel) return; // off without its key
  let payload;
  try {
    payload = readMessageLog();
  } catch (e) {
    log(`message log read failed: ${e.message}`);
    return;
  }
  if (!payload) return; // a failed read skips this cycle; nothing is marked
  const entries = [];
  for (const agent of payload.agents || []) {
    for (const row of agent.rows || []) {
      if (!row || !row.id) continue;
      entries.push({ agent: agent.id, row });
    }
  }
  entries.sort((a, b) => (a.row.epoch || 0) - (b.row.epoch || 0));
  state.messagesPosted = state.messagesPosted || {};
  if (!state.messagesBaseline) {
    for (const e of entries) state.messagesPosted[e.row.id] = e.row.epoch || 0;
    state.messagesBaseline = true;
    log(`messages baseline: ${entries.length} existing entries recorded silently for ${channel}`);
    return;
  }
  const limit = envInt("FM_SLACK_MESSAGES_LIMIT", 39000) || 39000;
  const seen = new Set(entries.map((e) => e.row.id));
  for (const e of entries) {
    if (state.messagesPosted[e.row.id] !== undefined) continue;
    const parts = splitMessagePost(formatMessagePost(e.agent, e.row), limit);
    try {
      for (const text of parts) await slackApi(cfgv, "chat.postMessage", { channel, text });
    } catch (err) {
      log(`message post failed for ${e.row.id}: ${err.message}`);
      break;
    }
    state.messagesPosted[e.row.id] = e.row.epoch || 0;
    log(`message ${e.row.id} posted to ${channel} in ${parts.length} part(s)`);
  }
  // Retention: drop posted ids whose records have been gone over 30 days.
  const cutoff = Date.now() / 1000 - 30 * 86400;
  for (const [id, epoch] of Object.entries(state.messagesPosted)) {
    if (!seen.has(id) && epoch < cutoff) delete state.messagesPosted[id];
  }
}

// ---------------------------------------------------- captain reactions ----

// A captain reaction may ONLY acknowledge (silence) or snooze an alert.
// Every other reaction, on any message, is ignored without state change, so a
// reaction can never approve a merge, a destructive action, or a decision.
async function captainReaction(cfgv, state, reaction, item, user) {
  if (!reaction || !item || item.type !== "message" || !item.channel || !item.ts) return;
  if (!cfgv.allow.includes(user)) return;
  const alert = Object.values(state.alerts).find(
    (a) => a.channel === item.channel && a.ts === item.ts,
  );
  if (!alert) return;
  if (reaction === CAPTAIN_ACK) {
    if (alert.silenced) return;
    if (alert.hasAlarm) {
      if (!(await removeReaction(cfgv, alert, MARK_UNATTENDED))) return;
      alert.hasAlarm = false;
    }
    alert.silenced = true;
    log(`alert ${alert.key} silenced by captain reaction`);
  } else if (reaction === CAPTAIN_SNOOZE) {
    if (alert.snoozeUntil > Date.now()) return;
    if (alert.hasAlarm) {
      if (!(await removeReaction(cfgv, alert, MARK_UNATTENDED))) return;
      alert.hasAlarm = false;
    }
    alert.snoozeUntil = Date.now() + cfgv.snoozeSecs * 1000;
    log(`alert ${alert.key} snoozed by captain reaction`);
  }
  // Any other reaction: deliberately ignored.
}

// Poll transport reads captain reactions back from the live (not done,
// not silenced) alerts through the documented reactions.get read.
async function reactionPass(cfgv, state) {
  if (!state.botUserId) {
    try {
      const who = await slackApi(cfgv, "auth.test", {});
      state.botUserId = who.user_id || "";
    } catch (e) {
      log(`auth.test failed: ${e.message}`);
      return;
    }
  }
  for (const alert of Object.values(state.alerts)) {
    if (alert.done || alert.silenced) continue;
    if (!alert.ts) continue; // silent baseline entry: no Slack message to read back
    try {
      const json = await slackApi(cfgv, "reactions.get", {
        channel: alert.channel,
        timestamp: alert.ts,
      });
      const reactions = (json.message && json.message.reactions) || [];
      for (const r of reactions) {
        const users = (r.users || []).filter((u) => u !== state.botUserId);
        const actor = users.find((u) => cfgv.allow.includes(u));
        if (!actor) continue;
        await captainReaction(cfgv, state, r.name, { type: "message", channel: alert.channel, ts: alert.ts }, actor);
      }
    } catch (e) {
      log(`reactions.get failed on ${alert.key}: ${e.message}`);
    }
  }
}

// ------------------------------------------------------------ transports ----

async function pollInbound(cfgv, state) {
  for (const channel of cfgv.pollChannels) {
    const cursor = state.channelCursor[channel] || "0";
    const pages = [];
    let pageCursor;
    let failed = false;
    for (;;) {
      let json;
      try {
        json = await slackApi(cfgv, "conversations.history", { channel, oldest: cursor, limit: 50, cursor: pageCursor });
      } catch (e) {
        log(`history read failed for ${channel}: ${e.message}`);
        failed = true;
        break;
      }
      for (const m of json.messages || []) pages.push(m);
      const next = json.has_more && json.response_metadata && json.response_metadata.next_cursor;
      if (!next) break;
      pageCursor = next;
    }
    if (failed) continue;
    const msgs = pages
      .filter((m) => m.ts && m.ts > cursor)
      .sort((a, b) => (a.ts < b.ts ? -1 : 1));
    for (const m of msgs) {
      // conversations.history entries carry no event type and no channel of
      // their own; normalize to the message-event shape the inbound handler
      // shares with Socket Mode.
      const ok = await inboundMessage(cfgv, state, { ...m, type: "message", channel });
      if (!ok) break;
      state.channelCursor[channel] = m.ts;
    }
  }
}

async function handleSocketEvent(cfgv, state, event) {
  if (!event) return true;
  if (event.type === "message") {
    return inboundMessage(cfgv, state, event);
  } else if (event.type === "reaction_added") {
    await captainReaction(cfgv, state, event.reaction, event.item, event.user);
  }
  // Everything else (edits, deletes, mentions of the bot) is ignored.
  return true;
}

async function socketLoop(cfgv, state, once) {
  let backoff = 1000;
  for (;;) {
    let url;
    try {
      const conn = await slackApi(cfgv, "apps.connections.open", {}, cfgv.appToken);
      url = conn.url;
    } catch (e) {
      log(`socket url open failed: ${e.message}`);
      if (once) process.exit(1);
      await new Promise((r) => setTimeout(r, backoff));
      backoff = Math.min(backoff * 2, 30_000);
      continue;
    }
    backoff = 1000;
    await new Promise((resolve) => {
      const ws = new WebSocket(url);
      let closed = false;
      const finish = () => {
        if (!closed) {
          closed = true;
          resolve();
        }
      };
      ws.onmessage = (m) => {
        let env;
        try {
          env = JSON.parse(String(m.data));
        } catch {
          return;
        }
        if (env.type === "events_api" && env.payload && env.payload.event && env.payload.event.type === "message") {
          Promise.resolve()
            .then(() => handleSocketEvent(cfgv, state, env.payload.event))
            .then((ok) => {
              if (ok !== false && env.envelope_id) ws.send(JSON.stringify({ envelope_id: env.envelope_id }));
            })
            .catch((e) => {
              log(`socket inbound failed: ${e.message}`);
            });
          return;
        }
        if (env.envelope_id) {
          ws.send(JSON.stringify({ envelope_id: env.envelope_id }));
        }
        if (env.type === "events_api") {
          handleSocketEvent(cfgv, state, env.payload && env.payload.event);
        } else if (env.type === "interactive" || env.type === "slash_commands") {
          // Acked above and deliberately ignored: interactive surfaces are not
          // an approval path for anything.
        }
      };
      ws.onerror = finish;
      const tick = async () => {
        try {
          await replyPass(cfgv, state);
          await alertPass(cfgv, state);
          await messagesPass(cfgv, state);
          await reactionPass(cfgv, state); // socket covers live alerts; harmless re-read
          saveState(state);
        } catch (e) {
          log(`cycle failed: ${e.message}`);
        }
      };
      const timer = setInterval(tick, cfgv.alertSecs * 1000);
      ws.onclose = () => {
        clearInterval(timer);
        finish();
      };
      if (once) {
        // One cycle, then leave: --once is the deterministic test/ops mode.
        tick().then(() => {
          clearInterval(timer);
          try {
            ws.close();
          } catch {
            /* already closed */
          }
          resolve();
        });
      } else {
        void tick();
      }
    });
    if (once) break;
  }
}

async function pollLoop(cfgv, state, once) {
  for (;;) {
    const started = Date.now();
    try {
      await pollInbound(cfgv, state);
      await replyPass(cfgv, state);
      await alertPass(cfgv, state);
      await messagesPass(cfgv, state);
      await reactionPass(cfgv, state);
      saveState(state);
    } catch (e) {
      log(`cycle failed: ${e.message}`);
    }
    if (once) break;
    const elapsed = Date.now() - started;
    await new Promise((r) => setTimeout(r, Math.max(0, cfgv.pollSecs * 1000 - elapsed)));
  }
}

// --------------------------------------------------------------- wedge ----

// The config/wedge-alarm `command:` target: reads the alarm summary from $1
// or stdin and posts it as a status-channel alert that resolves when the
// documented readiness read succeeds again.
async function wedge(cfgv, state) {
  const argText = process.argv[3] || "";
  const text = argText.trim() || fs.readFileSync(0, "utf8").trim();
  if (!text) {
    log("wedge: empty alarm summary");
    process.exit(1);
  }
  if (!cfgv.statusChannel) {
    log("wedge: no status channel configured; alarm not delivered");
    process.exit(1);
  }
  const key = `wedge:${Date.now()}:${process.pid}`;
  await postAlert(cfgv, state, key, "wedge", cfgv.statusChannel, alertText("wedge", null, cfgv, text));
  saveState(state);
}

// ----------------------------------------------------------------- main ----

function requireNodeRuntime() {
  if (typeof WebSocket !== "function") {
    log("this bridge needs Node >= 21 (built-in WebSocket); refusing to start");
    process.exit(1);
  }
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const mode = cmd || "run";
  if (mode === "run") {
    requireNodeRuntime();
    let transport = process.env.FM_SLACK_TRANSPORT || "";
    const tflag = rest.indexOf("--transport");
    if (tflag >= 0 && rest[tflag + 1]) transport = rest[tflag + 1];
    if (!transport && rest.includes("--poll")) transport = "poll";
    if (!transport) transport = "socket";
    const once = rest.includes("--once");
    const cfgv = cfg();
    if (!cfgv.botToken || cfgv.allow.length === 0) {
      log(`run needs FM_SLACK_BOT_TOKEN and FM_SLACK_ALLOW_USERS (set them in ${path.join(HOME, ".env")})`);
      process.exit(1);
    }
    if (transport === "socket" && !cfgv.appToken) {
      log(`socket transport needs FM_SLACK_APP_TOKEN (set it in ${path.join(HOME, ".env")}); use --poll for the REST fallback`);
      process.exit(1);
    }
    const state = loadState();
    // Homes with a state file from before the baseline existed keep their
    // posted alerts and never seed: only a truly fresh home baselines.
    try {
      if (fs.existsSync(STATE_FILE) && !state.alertBaseline) state.alertBaseline = true;
    } catch {
      /* a stat failure must not block the bridge */
    }
    if (transport === "poll") {
      await pollLoop(cfgv, state, once);
    } else {
      await socketLoop(cfgv, state, once);
    }
    if (once) saveState(state);
  } else if (mode === "wedge") {
    requireNodeRuntime();
    const cfgv = cfg();
    if (!cfgv.botToken) {
      log(`wedge needs FM_SLACK_BOT_TOKEN (set it in ${path.join(HOME, ".env")})`);
      process.exit(1);
    }
    await wedge(cfgv, loadState());
  } else {
    log("usage: fm-slack-bridge.mjs run [--transport socket|poll] [--once] | wedge");
    process.exit(2);
  }
}

main().catch((e) => {
  log(`fatal: ${e.message}`);
  process.exit(1);
});
