# The Slack bridge

Carry firstmate conversation and alerts over a Slack workspace you own, with nothing exposed publicly: the bridge is a process on this machine holding a Socket Mode connection to Slack.

Like the [spoken interface](voice-relay.md), the bridge is NOT firstmate and never supervises anything. It moves messages in and out, and marks alerts from firstmate's durable records.

## The shape

```
Slack (captain-owned app, Socket Mode)
   |  allow-listed messages                     threaded replies
   v                                                ^
bin/fm-slack-bridge.sh  (this machine)
   |  fm-inbox.sh note --request-id <channel>:<ts>     receipts --after <cursor>
   v                                                      |
firstmate (durable notes, replies, records) ---------------+
   ^  alerts from records: bearings snapshot, disk, readiness
```

## What it does

- Inbound: a Slack message from an allow-listed user id becomes a durable note through `bin/fm-inbox.sh note`, with the Slack message id (`<channel>:<ts>`) as the `--request-id`.
  A Slack redelivery therefore replays the original note instead of creating a second one.
  Messages from any other user are dropped without a trace.
- Outbound: replies firstmate records with `bin/fm-inbox.sh reply` are posted by the bridge into the thread of the original Slack message.
  Replies to notes the bridge did not file are never delivered to Slack.
- Alerts: the bridge posts event classes it reads from durable records to two configurable channels, and marks each alert with reactions as the records change.
  It never reads conversation memory, chat transcripts, or terminal panes.

## Setup (one-time, by the captain)

1. Create a Slack app at `api.slack.com/apps` (from scratch, owned by you), and enable Socket Mode.
2. Create an app-level token with the `connections:write` scope; that is the app token (`xapp-...`).
3. Give the bot these OAuth scopes: `chat:write`, `reactions:read`, `reactions:write`, `channels:history`, `groups:history`, and `im:history`.
4. Under Event Subscriptions, subscribe bot events to `message.channels`, `message.groups`, and `message.im`.
5. Install the app to the workspace and copy the bot token (`xoxb-...`).
6. Invite the bot to the two alert channels you want to use, and note their channel ids.
7. Write the configuration into the home's gitignored `.env` (keys below).
8. Start the bridge: `bin/fm-slack-bridge.sh run`.
   Run it inside a service manager (for example a systemd user unit) if you want it to survive reboots; the bridge itself is a plain foreground process.

### Configuration

All keys live in `FM_HOME/.env`; an existing environment variable of the same name wins.
The bridge does nothing unless its keys are present - an unconfigured home refuses to start with the `.env` path to write.

| .env key | Bridge variable | Meaning |
| ---------------------- | -------------------------- | ----------------------------------------------- |
| `slack-bot-token` | `FM_SLACK_BOT_TOKEN` | Bot token (`xoxb-...`). Required. |
| `slack-app-token` | `FM_SLACK_APP_TOKEN` | App token (`xapp-...`) for Socket Mode. Required by `run`. |
| `slack-allow-users` | `FM_SLACK_ALLOW_USERS` | Comma-separated Slack user ids allowed inbound. Required. |
| `slack-action-channel` | `FM_SLACK_ACTION_CHANNEL` | Action channel id. Optional; action alerts are off without it. |
| `slack-status-channel` | `FM_SLACK_STATUS_CHANNEL` | Status channel id. Optional; status alerts are off without it. |
| `slack-poll-channels` | `FM_SLACK_POLL_CHANNELS` | Inbound channels for the poll transport. Optional; defaults to both alert channels. |

Optional tuning environment variables (no `.env` counterparts): `FM_SLACK_POLL_SECS` (poll cycle, 10), `FM_SLACK_ALERT_SECS` (alert cycle, 60), `FM_SLACK_UNATTENDED_SECS` (unattended threshold, 1800), `FM_SLACK_REPEAT_MAX` (capped repeat notices, 2), `FM_SLACK_SNOOZE_SECS` (snooze duration, 86400), `FM_SLACK_DISK_PCT` (disk threshold, 90), `FM_SLACK_DISK_PATH` (checked filesystem, `/`).

## Alert channels and coverage

The action channel is rare and always actionable.
The status channel can be muted; it carries things a running fleet says anyway.

| Class | Channel | Record read | Resolves when |
| --------- | ------ | -------------------------------------------- | ------------------------------- |
| Decision waiting on the captain | action | `bin/fm-bearings-snapshot.sh` `decisions_open` | The hold leaves the snapshot. |
| PR ready for review | action | `bin/fm-bearings-snapshot.sh` `recorded_prs` | The task leaves the recorded-PR set (merged or closed). |
| Worker stopped responding | status | `bin/fm-bearings-snapshot.sh` `unhealthy_endpoints` | The endpoint leaves the unhealthy set. |
| Disk nearly full | status | local `df` on `FM_SLACK_DISK_PATH` | Usage back under threshold. |
| Wedge alarm | status | the `command:` caller (see below) | `bin/fm-inbox.sh ready` answers healthy again. |

These classes are NOT covered, because no documented durable record exposes them:

- Red CI on a waiting PR - live check state needs the opt-in `--include-prs` GitHub read, which the bridge does not run.
- Failed or stalled validation - pipeline run state is not one of the bridge's record owners.
- AI quota out of band - no firstmate durable record carries it.
- A credential or login ask - it arrives as an ordinary note or decision, not as a distinct record.

An in-progress marker on a decision or PR alert means the record snapshot currently lists that task as under way.
A failed fleet-snapshot read never resolves anything; the bridge skips that cycle instead.

## Reactions

The bot marks every alert from record state, never from conversation memory:

- `bell` when posted (pending).
- `hammer_and_wrench` while the records show the work under way.
- `white_check_mark` when the records show it resolved.
- `alarm_clock` plus one thread notice when it stays unattended past `FM_SLACK_UNATTENDED_SECS`, repeated at most `FM_SLACK_REPEAT_MAX` times.

Your reactions back on an alert may do only two things:

- `eyes` acknowledges the alert as seen and silences further notices.
- `zzz` snoozes it for `FM_SLACK_SNOOZE_SECS` (a day by default).

Every other reaction is ignored, and no reaction can ever approve a merge, a destructive action, or a decision.
Approvals stay in firstmate's own channels.

## The wedge-alarm wiring

The bridge reuses the away-mode wedge alarm's `command:` channel instead of building a second alarm path.
Point `config/wedge-alarm` at the bridge and each wedge alarm becomes a status-channel alert that resolves when the primary answers the readiness read again:

```
command:/path/to/firstmate/bin/fm-slack-bridge.sh wedge
```

The alarm summary arrives as `$1` or on stdin and is posted verbatim as the alert text.

## Transports

- `socket` (default): Slack Socket Mode through the Node built-in WebSocket client and `fetch`.
  No package dependency is added; Node >= 21 (the fleet standard runtime is Node 22) is required.
  This transport sees DMs and every configured channel, and receives your reactions live.
- `poll` (`run --transport poll`): REST polling of `conversations.history` for the configured channels.
  A fallback for hosts where the websocket will not pass; it does not see DMs, and it reads your reactions back per live alert through `reactions.get`.

## Security notes

- Tokens are read from the home's gitignored `.env` through the one shared `.env` reader; they are never logged.
- Only allow-listed user ids produce notes; everyone else is dropped before anything is written.
- The log carries ids, channels, and outcomes - never message bodies.
- The bridge writes only its private state under `data/slack-bridge/bridge/` (gitignored), touches firstmate's state only through the documented `bin/fm-inbox.sh` surface, and reads records read-only.
- It is not a supervisor: it never drains or acknowledges firstmate's wake queue, never steers a worker, and never merges anything.

## What this build does not do

- No Slack path for merge approval or any decision exists, by design.
- Relay is unchanged.
- The bridge does not create the Slack app, hold credentials outside `.env`, or start itself as a service.
- Coverage gaps listed above are deliberate until the records exist to read them from.
