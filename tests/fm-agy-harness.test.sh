#!/usr/bin/env bash
# Behavior tests for the agy (Antigravity CLI) detection arm in fm-harness.sh.
#
# agy is a verified crewmate/scout adapter (see bin/fm-spawn.sh's launch
# template, bin/fm-control-lib.sh's entry, and bin/fm-agy-turnend-hook.sh's
# busy-state wiring). This file pins only the detection facts:
#   1. ANTIGRAVITY_AGENT=1 is agy's own child/tool-process marker, and it
#      outranks BOTH an inherited CLAUDECODE and an inherited CURSOR_AGENT,
#      because agy clears neither (verified live on agy 1.2.12: a tool process
#      launched with both foreign markers present carried all three together).
#   2. The installed CLI is a native ELF binary whose live process reports
#      comm=agy directly (verified live), so ancestry detection needs no
#      MainThread-style interpreter hack the way gemini does.
#   3. The comm-name arm is anchored, never *agy*, so an unrelated command
#      mentioning agy is never misread as this harness.
# .agents/skills/harness-adapters/references/harness/agy.md records the full
# set of live findings, including the ones not yet wired into executable code.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

test_agy_marker_outranks_inherited_foreign_markers() {
  local out
  # The exact hazard: agy does not clear an inherited CLAUDECODE or
  # CURSOR_AGENT, so a real agy worker under a claude or cursor primary
  # carries all three markers at once.
  out=$(CLAUDECODE=1 CURSOR_AGENT=1 ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = agy ] || fail "CLAUDECODE + CURSOR_AGENT + ANTIGRAVITY_AGENT must detect agy, got '$out'"
  # Drive the signals apart so the case above cannot go quietly vacuous: the
  # marker alone must still produce its own verdict.
  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT alone must detect agy, got '$out'"
  pass "fm-harness.sh: agy's marker outranks an inherited CLAUDECODE and CURSOR_AGENT together"
}

test_agy_foreign_markers_alone_still_resolve_to_their_owner() {
  local out
  # Without ANTIGRAVITY_AGENT, the existing precedence order must be
  # unchanged: cursor's own marker still wins over an inherited CLAUDECODE,
  # and CLAUDECODE alone still detects claude.
  out=$(env -u ANTIGRAVITY_AGENT CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS")
  [ "$out" = cursor ] || fail "cursor's marker must still outrank CLAUDECODE when agy's marker is absent, got '$out'"
  out=$(env -u ANTIGRAVITY_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE alone must still detect claude when agy's marker is absent, got '$out'"
  pass "fm-harness.sh: adding agy's marker check left the existing precedence order unchanged"
}

test_agy_ancestry_matches_only_a_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'agy'; exit 0 ;;
  *"args="*) printf '%s\n' 'agy --dangerously-skip-permissions -i hello'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u ANTIGRAVITY_AGENT -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u GEMINI_CLI -u PI_CODING_AGENT -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE \
        -u ROVODEV_CLI PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = agy ] \
    || fail "a natively-named agy command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named agy command"
}

test_agy_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(env -u ANTIGRAVITY_AGENT -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u GEMINI_CLI -u PI_CODING_AGENT -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE \
        -u ROVODEV_CLI FAKE_PS_COMM=agy-helper FAKE_PS_ARGS='agy-helper --serve' \
        PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != agy ] \
    || fail "an unrelated agy-helper command must not detect agy, got '$out'"

  out=$(env -u ANTIGRAVITY_AGENT -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u GEMINI_CLI -u PI_CODING_AGENT -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE \
        -u ROVODEV_CLI FAKE_PS_COMM=node FAKE_PS_ARGS='node server.js --model agy' \
        PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != agy ] \
    || fail "a later node argument naming agy must not detect agy, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated agy mentions"
}

test_agy_marker_outranks_inherited_foreign_markers
test_agy_foreign_markers_alone_still_resolve_to_their_owner
test_agy_ancestry_matches_only_a_native_command_name
test_agy_ancestry_rejects_unrelated_mentions
