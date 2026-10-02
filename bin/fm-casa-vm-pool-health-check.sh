#!/usr/bin/env bash
# Deterministic condition for the casa-vm pool-health process-event watch
# (docs/casa-vm-pool-breakglass.md), armed via:
#   bin/fm-procevent-when.sh arm casa-vm-pool-health --condition \
#     bin/fm-casa-vm-pool-health-check.sh <ssh-host> <remote-heartbeat-path> \
#     <stale-after-secs> <watchdog-timeout-secs> <watchdog-grace-secs> \
#     --action <safe-no-op>
# Reads state/heartbeat.json over the documented read-only SSH route and exits
# 0 when the pool looks unhealthy (halted, or its heartbeat has gone stale
# beyond the given bound), 1 when it looks healthy, and 2 on any fetch or
# parse failure (ssh down, file missing, malformed JSON) so the runner treats
# that as a condition error rather than a false negative.
# Set FM_CASA_VM_HEALTH_HEARTBEAT_OVERRIDE to a local file path to read that
# file instead of sshing, for testing the detection logic against a simulated
# heartbeat without touching the real host.
set -u

if [ "$#" -ne 5 ]; then
  echo "usage: fm-casa-vm-pool-health-check.sh <ssh-host> <remote-heartbeat-path> <stale-after-secs> <watchdog-timeout-secs> <watchdog-grace-secs>" >&2
  exit 2
fi

SSH_HOST=$1
REMOTE_PATH=$2
STALE_AFTER=$3
WATCHDOG_TIMEOUT=$4
WATCHDOG_GRACE=$5

if [ -n "${FM_CASA_VM_HEALTH_HEARTBEAT_OVERRIDE:-}" ]; then
  RAW=$(cat "$FM_CASA_VM_HEALTH_HEARTBEAT_OVERRIDE" 2>/dev/null) || { echo "fetch failed: cannot read override file"; exit 2; }
else
  RAW=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" "cat $REMOTE_PATH" 2>&1) || { echo "fetch failed: $RAW"; exit 2; }
fi

PARSED=$(printf '%s' "$RAW" | jq -e -r '[.epoch, .phase, (.vm_boot_epoch // "null")] | @tsv' 2>/dev/null) || {
  echo "parse failed: heartbeat is not valid JSON or missing fields"
  exit 2
}

IFS=$'\t' read -r EPOCH PHASE VM_BOOT_EPOCH <<<"$PARSED"
NOW=$(date +%s)

if [ "$PHASE" = "halted" ]; then
  echo "unhealthy: pool halted (phase=halted)"
  exit 0
fi

AGE=$(( NOW - EPOCH ))
if [ "$AGE" -gt "$STALE_AFTER" ]; then
  echo "unhealthy: heartbeat stale, age=${AGE}s > ${STALE_AFTER}s"
  exit 0
fi

if [ "$VM_BOOT_EPOCH" != "null" ]; then
  BOOT_AGE=$(( NOW - VM_BOOT_EPOCH ))
  CAP=$(( WATCHDOG_TIMEOUT + WATCHDOG_GRACE ))
  if [ "$BOOT_AGE" -gt "$CAP" ]; then
    echo "unhealthy: current VM boot age=${BOOT_AGE}s exceeds watchdog cap+grace=${CAP}s"
    exit 0
  fi
fi

echo "healthy: phase=$PHASE age=${AGE}s"
exit 1
