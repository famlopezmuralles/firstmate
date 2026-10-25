#!/usr/bin/env bash
# fm-slack-bridge.sh - start or drive the opt-in Slack bridge process.
#
# docs/slack-bridge.md is the single owner of the operator contract: setup,
# scopes, .env keys, channel routing, the reaction contract, and which alert
# classes are covered. This wrapper owns only the launch mechanics: it reads
# the home's gitignored .env through bin/fm-env-lib.sh (the single .env read
# owner), exports the resolved keys as FM_SLACK_* environment variables
# (existing environment wins, matching the fm-mail.sh env-wins contract), and
# execs bin/fm-slack-bridge.mjs under the fleet-standard Node runtime. Secrets
# are never printed; a missing key refuses with the .env path to write.
#
# The bridge is NOT a supervisor: it only ever touches firstmate's state
# through the documented bin/fm-inbox.sh surface, reads durable records
# read-only, and keeps its own private state under data/slack-bridge/bridge/.
#
# Usage:
#   fm-slack-bridge.sh run [--transport socket|poll] [--once]
#   fm-slack-bridge.sh wedge [summary]   (config/wedge-alarm command: target;
#                                     summary from $1 or stdin)
#
# Configuration (FM_HOME/.env key; existing env var of the same name wins):
#   slack-bot-token        FM_SLACK_BOT_TOKEN        bot token (xoxb-...).   required
#   slack-app-token        FM_SLACK_APP_TOKEN        app token (xapp-...).   required by run (socket)
#   slack-allow-users      FM_SLACK_ALLOW_USERS      comma-separated Slack   required
#                                                    user ids allowed inbound
#   slack-action-channel   FM_SLACK_ACTION_CHANNEL   action channel id.      optional
#   slack-status-channel   FM_SLACK_STATUS_CHANNEL   status channel id.      optional
#   slack-poll-channels    FM_SLACK_POLL_CHANNELS    inbound channels for    optional
#                                                    the poll transport
#
# Environment:
#   FM_HOME                operational home (default: this repo checkout).
#
# Exit codes: 0 ok; 1 configuration or runtime refusal; 2 usage.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$REPO_ROOT}"
export FM_HOME
ENV_FILE="$FM_HOME/.env"

# shellcheck source=bin/fm-env-lib.sh
. "$SELF_DIR/fm-env-lib.sh"

export_resolved() {  # <env-var> <env-file-key>
  local var=$1 key=$2 line val
  line=$(fmx_env_get "$key" "$ENV_FILE")
  val=${line}
  if [ -z "${!var:-}" ] && [ -n "$val" ]; then
    printf -v "$var" '%s' "$val"
    # shellcheck disable=SC2163  # $var names the caller-supplied variable
    export "$var"
  fi
}

require_config() {  # <env-var> <names...>
  local var=$1
  shift
  if [ -z "${!var:-}" ]; then
    echo "fm-slack-bridge.sh: $* is required (set it in $ENV_FILE or the environment)" >&2
    exit 1
  fi
}

command -v node >/dev/null 2>&1 || {
  echo "fm-slack-bridge.sh: node is required (the fleet-standard runtime)" >&2
  exit 1
}

CMD="${1:-run}"
if [ "${1:-}" = "" ]; then
  set -- run
fi

case "$CMD" in
  run)
    export_resolved FM_SLACK_BOT_TOKEN slack-bot-token
    export_resolved FM_SLACK_APP_TOKEN slack-app-token
    export_resolved FM_SLACK_ALLOW_USERS slack-allow-users
    export_resolved FM_SLACK_ACTION_CHANNEL slack-action-channel
    export_resolved FM_SLACK_STATUS_CHANNEL slack-status-channel
    export_resolved FM_SLACK_POLL_CHANNELS slack-poll-channels
    require_config FM_SLACK_BOT_TOKEN "slack-bot-token"
    require_config FM_SLACK_ALLOW_USERS "slack-allow-users (comma-separated Slack user ids)"
    case "$FM_HOME" in /*) ;; *) echo "fm-slack-bridge.sh: FM_HOME must be absolute" >&2; exit 1 ;; esac
    exec node "$REPO_ROOT/bin/fm-slack-bridge.mjs" "$@"
    ;;
  wedge)
    shift
    export_resolved FM_SLACK_BOT_TOKEN slack-bot-token
    export_resolved FM_SLACK_STATUS_CHANNEL slack-status-channel
    require_config FM_SLACK_BOT_TOKEN "slack-bot-token"
    require_config FM_SLACK_STATUS_CHANNEL "slack-status-channel"
    exec node "$REPO_ROOT/bin/fm-slack-bridge.mjs" wedge "$@"
    ;;
  -h|--help|help)
    echo "usage: fm-slack-bridge.sh run [--transport socket|poll] [--once] | wedge [summary]"
    echo "  run    start the bridge (socket mode by default; --poll is the REST fallback)"
    echo "  wedge  config/wedge-alarm command: target; reads the alarm summary from \$1 or stdin"
    echo "Configuration comes from \$FM_HOME/.env (slack-bot-token, slack-app-token,"
    echo "slack-allow-users, slack-action-channel, slack-status-channel); docs/slack-bridge.md owns setup."
    exit 0
    ;;
  *)
    echo "usage: fm-slack-bridge.sh run [--transport socket|poll] [--once] | wedge [summary]" >&2
    exit 2
    ;;
esac
