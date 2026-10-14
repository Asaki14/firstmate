#!/usr/bin/env bash
# tests/fm-backend-tern-smoke.test.sh - real Tern smoke test for the Tern
# session-provider adapter (bin/backends/tern.sh), verified against Tern 0.4.5
# (docs/tern-backend.md). Every other suite fakes the CLI; this one talks to
# the REAL daemon and window, so like the cmux smoke test it acts on the
# captain's live Tern: it creates ONE throwaway session named
# zz-fm-smoke-<pid> (never shown, never focused), touches only blocks it
# created, and kills that session - and nothing else - on exit.
#
# Skips cleanly when tern or jq is missing, or when `tern ls` cannot reach a
# daemon with a window (CI and machines without Tern are unaffected).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SESSION="zz-fm-smoke-$$"
cleanup_all() {
  case "$SESSION" in
    zz-fm-smoke-*) fm_backend_tern_cli kill session "$SESSION" >/dev/null 2>&1 || true ;;
  esac
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the tern adapter)"; exit 0; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tern || { echo "skip: could not source the tern adapter"; exit 0; }
fm_backend_tern_tool_check >/dev/null 2>&1 || { echo "skip: tern CLI not found on PATH or in /Applications/Tern.app"; exit 0; }
fm_backend_tern_version_check >/dev/null 2>&1 || { echo "skip: installed Tern is older than the verified minimum"; exit 0; }
fm_backend_tern_inventory >/dev/null 2>&1 || { echo "skip: 'tern ls --json' cannot reach a Tern daemon with a window - open Tern to run this smoke test"; exit 0; }

export FM_TERN_SESSION="$SESSION"
SMOKE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-tern-smoke.XXXXXX")
SMOKE_DIR=$(cd "$SMOKE_DIR" && pwd -P)
trap 'cleanup_all; rm -rf "$SMOKE_DIR"' EXIT

# --- create_task + duplicate refusal -----------------------------------------

LABEL=fm-test-smoke1
TASK_IDS=$(fm_backend_tern_create_task "$LABEL" "$SMOKE_DIR") || fail "create_task failed"
read -r SES BLOCK <<EOF
$TASK_IDS
EOF
[ "$SES" = "$SESSION" ] && [ -n "$BLOCK" ] || fail "create_task returned '$TASK_IDS'"
TARGET="tern:$SES/$BLOCK"
shown=$(fm_backend_tern_inventory | jq -r --arg s "$SESSION" '.sessions[] | select(.name == $s) | .shown')
[ "$shown" = false ] || fail "creating a task session must not show it in the window"
if fm_backend_tern_create_task "$LABEL" "$SMOKE_DIR" >/dev/null 2>&1; then
  fail "create_task should refuse a duplicate task tab"
fi
pass "real tern: create_task makes an unshown session/tab named for the task and refuses a duplicate"

fm_backend_tern_target_ready "$TARGET" "$LABEL" || fail "target_ready with the task label should succeed"
if fm_backend_tern_target_ready "$TARGET" "fm-test-not-smoke" >/dev/null 2>&1; then
  fail "target_ready with another task's label should fail"
fi
pass "real tern: target_ready accepts the task's own tab and rejects a mismatched label"

# --- send / capture -----------------------------------------------------------

fm_backend_tern_send_literal "$TARGET" 'echo literal-then-key-captain' "$LABEL" || fail "send_literal failed"
fm_backend_tern_send_key "$TARGET" Enter "$LABEL" || fail "send_key Enter failed"
out=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.3
  out=$(fm_backend_capture tern "$TARGET" 40 "$LABEL") || fail "capture failed"
  case "$out" in *$'\n'literal-then-key-captain*) break ;; esac
done
case "$out" in *$'\n'literal-then-key-captain*) ;; *) fail "capture did not show the command output: $out" ;; esac
pass "real tern: literal text plus a separate Enter runs in the task shell and capture reads it"

# shellcheck disable=SC2016 # The task shell, not this test, expands the loop.
fm_backend_tern_send_text_line "$TARGET" 'for i in $(seq 1 60); do echo smoke-line-$i; done' "$LABEL" || fail "send_text_line failed"
visible=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.3
  visible=$(fm_backend_visible_capture tern "$TARGET" "$LABEL") || fail "visible capture failed"
  case "$visible" in *smoke-line-60*) break ;; esac
done
case "$visible" in *smoke-line-60*) ;; *) fail "visible capture should show the newest line" ;; esac
case "$visible" in *smoke-line-1$'\n'*) fail "visible capture must not include scrolled-away lines" ;; esac
history=$(fm_backend_tern_capture "$TARGET" 200 "$LABEL") || fail "scrollback capture failed"
case "$history" in *smoke-line-1$'\n'*) ;; *) fail "scrollback capture should include the first line" ;; esac
pass "real tern: visible capture is the viewport only; capture includes scrollback"

path=$(fm_backend_tern_current_path "$TARGET" "$LABEL")
[ "$path" = "$SMOKE_DIR" ] || fail "current_path should be the shell's cwd '$SMOKE_DIR', got '$path'"
fm_backend_tern_send_text_line "$TARGET" "cd /" "$LABEL" || fail "cd failed"
sleep 0.5
path=$(fm_backend_tern_current_path "$TARGET" "$LABEL")
[ "$path" = / ] || fail "current_path should follow a cd live, got '$path'"
pass "real tern: current_path follows the foreground process's live cwd"

# --- state ----------------------------------------------------------------------

state=$(fm_backend_agent_state tern "$TARGET")
[ "$state" = dead ] || fail "a bare shell block should read dead, got '$state'"
state=$(fm_backend_busy_state tern "$TARGET")
[ "$state" = unknown ] || fail "a non-agent block should read busy unknown, got '$state'"
pass "real tern: a bare shell reads agent_state dead and busy_state unknown"

# --- kill -----------------------------------------------------------------------

fm_backend_kill tern "$TARGET" "" "$LABEL" || fail "kill failed"
state=$(fm_backend_agent_state tern "$TARGET")
[ "$state" = missing ] || fail "a closed block should read missing, got '$state'"
fm_backend_kill tern "$TARGET" "" "$LABEL" || fail "kill of an already-closed block should succeed"
pass "real tern: kill closes the block, reads missing afterwards, and is idempotent"
