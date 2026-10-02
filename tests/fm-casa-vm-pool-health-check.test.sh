#!/usr/bin/env bash
# Behavior tests for fm-casa-vm-pool-health-check.sh: the deterministic
# condition for the casa-vm pool-health process-event watch. Every case uses
# FM_CASA_VM_HEALTH_HEARTBEAT_OVERRIDE to feed a local fixture file, so no case
# ever opens an SSH connection or touches a real host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-casa-vm-pool-health-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-casa-vm-pool-health-check)

write_heartbeat() {
  local path=$1 epoch=$2 phase=$3 vm_boot_epoch=$4
  jq -n --argjson epoch "$epoch" --arg phase "$phase" --argjson vm_boot_epoch "$vm_boot_epoch" \
    '{epoch:$epoch, phase:$phase, repo:"", vm_boot_epoch:$vm_boot_epoch, overlay:"", pid:1}' \
    > "$path"
}

run_check() {
  local fixture=$1; shift
  FM_CASA_VM_HEALTH_HEARTBEAT_OVERRIDE="$fixture" "$CHECK" "$@"
}

test_fresh_idle_heartbeat_is_healthy() {
  local fixture=$TMP_ROOT/fresh-idle.json out status
  write_heartbeat "$fixture" "$(date +%s)" idle null
  out=$(run_check "$fixture" linux25 /dev/null 180 4200 600) status=$?
  expect_code 1 "$status" "fresh idle heartbeat"
  assert_contains "$out" "healthy" "fresh idle heartbeat was not reported healthy"
  pass "fresh idle heartbeat is healthy"
}

test_running_with_normal_boot_age_is_healthy() {
  local fixture=$TMP_ROOT/running-ok.json out status now
  now=$(date +%s)
  write_heartbeat "$fixture" "$now" running "$((now - 600))"
  out=$(run_check "$fixture" linux25 /dev/null 180 4200 600) status=$?
  expect_code 1 "$status" "running heartbeat with normal boot age"
  assert_contains "$out" "healthy" "normal boot age was not reported healthy"
  pass "running heartbeat with normal boot age is healthy"
}

test_stale_epoch_is_unhealthy() {
  local fixture=$TMP_ROOT/stale.json out status now
  now=$(date +%s)
  write_heartbeat "$fixture" "$((now - 900))" idle null
  out=$(run_check "$fixture" linux25 /dev/null 180 4200 600) status=$?
  expect_code 0 "$status" "stale heartbeat"
  assert_contains "$out" "unhealthy: heartbeat stale" "stale heartbeat was not flagged as stale"
  pass "stale epoch is unhealthy"
}

test_halted_phase_is_unhealthy() {
  local fixture=$TMP_ROOT/halted.json out status
  write_heartbeat "$fixture" "$(date +%s)" halted null
  out=$(run_check "$fixture" linux25 /dev/null 180 4200 600) status=$?
  expect_code 0 "$status" "halted heartbeat"
  assert_contains "$out" "unhealthy: pool halted" "halted heartbeat was not flagged as halted"
  pass "halted phase is unhealthy"
}

test_vm_boot_age_past_watchdog_cap_is_unhealthy() {
  local fixture=$TMP_ROOT/stuck.json out status now
  now=$(date +%s)
  write_heartbeat "$fixture" "$now" running "$((now - 5000))"
  out=$(run_check "$fixture" linux25 /dev/null 180 4200 600) status=$?
  expect_code 0 "$status" "VM boot age past watchdog cap+grace"
  assert_contains "$out" "unhealthy: current VM boot age" \
    "stuck VM boot age was not flagged past the watchdog cap"
  pass "VM boot age past watchdog cap+grace is unhealthy"
}

test_malformed_heartbeat_is_a_condition_error() {
  local fixture=$TMP_ROOT/bad.json out status
  printf 'not json\n' > "$fixture"
  out=$(run_check "$fixture" linux25 /dev/null 180 4200 600) status=$?
  expect_code 2 "$status" "malformed heartbeat JSON"
  assert_contains "$out" "parse failed" "malformed JSON was not reported as a parse failure"
  pass "malformed heartbeat is a condition error"
}

test_missing_heartbeat_source_is_a_condition_error() {
  local fixture=$TMP_ROOT/does-not-exist.json out status
  out=$(run_check "$fixture" linux25 /dev/null 180 4200 600) status=$?
  expect_code 2 "$status" "missing heartbeat source"
  assert_contains "$out" "fetch failed" "missing source was not reported as a fetch failure"
  pass "missing heartbeat source is a condition error"
}

test_fresh_idle_heartbeat_is_healthy
test_running_with_normal_boot_age_is_healthy
test_stale_epoch_is_unhealthy
test_halted_phase_is_unhealthy
test_vm_boot_age_past_watchdog_cap_is_unhealthy
test_malformed_heartbeat_is_a_condition_error
test_missing_heartbeat_source_is_a_condition_error
