#!/usr/bin/env bash
# tests/fm-backend-tern.test.sh - fake-tern-CLI unit tests for the Tern
# session-provider adapter (bin/backends/tern.sh) and its seams: runtime
# detection, task-endpoint validation, explicit-target routing, supervisor-pane
# discovery, the agent-state file the companion plugin publishes, and the
# secondmate refusal. The fake `tern` keeps a small JSON inventory
# (sessions -> tabs -> blocks) so create/rename/close behave like the real CLI
# verified in docs/tern-backend.md; every call is logged. The real-binary smoke
# test is tests/fm-backend-tern-smoke.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the tern adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-tern-tests)
US=$'\037'

# make_tern_world <name>: a fresh fake-tern directory. Sets W (world dir),
# TERN_LOG, and puts the fake first on PATH. The inventory starts empty.
make_tern_world() {
  W="$TMP_ROOT/$1"
  mkdir -p "$W/fakebin" "$W/capture" "$W/process" "$W/plugins"
  printf '{"next":100,"sessions":[]}' >"$W/state.json"
  : >"$W/log"
  TERN_LOG="$W/log"
  cat >"$W/fakebin/tern" <<'SH'
#!/usr/bin/env bash
set -u
W=${FM_TERN_FAKE:?}
S="$W/state.json"
{ printf 'tern'; for a in "$@"; do printf '%s%s' $'\037' "$a"; done; printf '\n'; } >>"$W/log"
save() { printf '%s' "$1" >"$S"; }
has_block() { jq -e --arg b "$1" 'any(.sessions[].tabs[].blocks[]; (.id|tostring) == $b)' "$S" >/dev/null; }
no_block() { echo "tern $1: no block is called \`$2\`" >&2; exit 1; }
case "${1:-}" in
  --version) printf 'tern %s (1d14241)\n' "${FM_TERN_FAKE_VERSION:-0.4.5}"; exit 0 ;;
  ls)
    [ -z "${FM_TERN_FAKE_LS_FAIL:-}" ] || { echo "tern ls: no daemon" >&2; exit 1; }
    jq '{sessions: .sessions, detached: []}' "$S"; exit 0 ;;
  new)
    kind=$2; shift 2; name=; cwd=
    while [ $# -gt 0 ]; do
      case "$1" in --cwd) cwd=$2; shift 2 ;; --json) shift ;; *) name=$1; shift ;; esac
    done
    if [ "$kind" = session ]; then
      if jq -e --arg n "$name" 'any(.sessions[]; .name == $n)' "$S" >/dev/null; then
        echo "tern new: a session is already called \`$name\`" >&2; exit 1
      fi
      out=$(jq --arg n "$name" --arg c "$cwd" '
        .next as $i | .next += 3
        | .sessions += [{id: $i, name: $n, shown: false, tabs: [{id: ($i+1), name: null, blocks: [{id: ($i+2), cwd: $c, program: "/bin/zsh", live: true, exited: null}]}]}]
        | {state: ., created: {session: $i, tab: ($i+1), block: ($i+2)}}' "$S")
    else
      jq -e --arg n "$name" 'any(.sessions[]; .name == $n)' "$S" >/dev/null || { echo "tern new: no session is called \`$name\`" >&2; exit 1; }
      out=$(jq --arg n "$name" --arg c "$cwd" '
        .next as $i | .next += 2
        | (.sessions[] | select(.name == $n) | .tabs) += [{id: $i, name: null, blocks: [{id: ($i+1), cwd: $c, program: "/bin/zsh", live: true, exited: null}]}]
        | {state: ., created: {session: (.sessions[] | select(.name == $n) | .id), tab: $i, block: ($i+1)}}' "$S")
    fi
    save "$(printf '%s' "$out" | jq '.state')"
    printf '%s' "$out" | jq '.created'
    exit 0 ;;
  rename)
    has_block "$2" || no_block rename "$2"
    save "$(jq --arg b "$2" --arg n "$3" '(.sessions[].tabs[] | select(any(.blocks[]; (.id|tostring) == $b)) | .name) = $n' "$S")"
    exit 0 ;;
  send)
    has_block "$2" || no_block send "$2"
    exit 0 ;;
  capture)
    has_block "$2" || no_block capture "$2"
    f="$W/capture/$2"
    case " $* " in *" --ansi "*) f="$f.ansi" ;; *" --scrollback "*) f="$f.scrollback" ;; esac
    [ -f "$f" ] && cat "$f"
    exit 0 ;;
  process)
    has_block "$2" || no_block process "$2"
    if [ -f "$W/process/$2" ]; then cat "$W/process/$2"; else
      printf '{"pane":%s,"child":{"pid":999991,"name":"zsh","argv":["/bin/zsh","-l"],"cwd":"/w"},"group":999991,"foreground":{"pid":999991,"name":"zsh","argv":["/bin/zsh","-l"],"cwd":"/w"}}' "$2"
    fi
    exit 0 ;;
  close)
    has_block "$2" || no_block close "$2"
    [ -z "${FM_TERN_FAKE_CLOSE_FAIL:-}" ] || { echo "tern close: refused" >&2; exit 1; }
    save "$(jq --arg b "$2" '.sessions[].tabs |= map(select(all(.blocks[]; (.id|tostring) != $b)))' "$S")"
    exit 0 ;;
  plugin)
    [ "${2:-}" = dir ] && { printf '%s\n' "$W/plugins"; exit 0; }
    exit 0 ;;
esac
echo "fake tern: unhandled $*" >&2
exit 2
SH
  chmod +x "$W/fakebin/tern"
  export FM_TERN_FAKE="$W"
  PATH="$W/fakebin:$ORIG_PATH"
  export PATH
  unset FM_TERN_FAKE_LS_FAIL FM_TERN_FAKE_CLOSE_FAIL FM_TERN_FAKE_VERSION
  unset FM_BACKEND_TERN_STATE_FILE_CACHED
  export FM_TERN_SESSION=zz-fm-unit
  export FM_TERN_AGENT_STATE_FILE="$W/agents.json"
}

tern_calls() {  # <verb> -> number of logged calls of that verb
  grep -c "^tern$US$1" "$TERN_LOG" || true
}

set_block_live() {  # <block> <true|false>
  jq --arg b "$1" --argjson v "$2" '(.sessions[].tabs[].blocks[] | select((.id|tostring) == $b) | .live) = $v' "$W/state.json" >"$W/state.tmp" && mv "$W/state.tmp" "$W/state.json"
}

set_process() {  # <block> <fg-name> <fg-argv0> [group]
  printf '{"pane":%s,"child":{"pid":999991,"name":"zsh","argv":["/bin/zsh"],"cwd":"/w"},"group":%s,"foreground":{"pid":999992,"name":"%s","argv":["%s"],"cwd":"/w/wt"}}' \
    "$1" "${4:-999993}" "$2" "$3" >"$W/process/$1"
}

write_agents() {  # <window_pid> <block> <agent-state|-> [version]
  local agent=$3
  if [ "$agent" = - ]; then
    printf '{"version":%s,"window_pid":%s,"blocks":{"%s":{"busy":false}}}' "${4:-1}" "$1" "$2" >"$W/agents.json"
  else
    printf '{"version":%s,"window_pid":%s,"blocks":{"%s":{"agent":"%s","busy":true}}}' "${4:-1}" "$1" "$2" "$agent" >"$W/agents.json"
  fi
}

# start_tern_window: a long-lived process whose command name is `tern`,
# standing in for the Tern window that wrote agents.json. Sets WINDOW_PID.
start_tern_window() {
  mkdir -p "$W/window"
  ln -sf "$(command -v sleep)" "$W/window/tern"
  "$W/window/tern" 600 </dev/null >/dev/null 2>&1 &
  WINDOW_PID=$!
}

ORIG_PATH=$PATH
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tern || fail "could not source the tern adapter"

# --- create / target --------------------------------------------------------

test_create_task_first_creates_session_then_tabs() {
  local out1 out2 s b1 b2
  make_tern_world create
  out1=$(fm_backend_tern_create_task fm-a /work) || fail "first create_task failed"
  read -r s b1 <<<"$out1"
  [ "$s" = zz-fm-unit ] || fail "create_task should report the home session, got '$s'"
  [ "$(tern_calls "new${US}session")" = 1 ] || fail "the first task should create the session"
  out2=$(fm_backend_tern_create_task fm-b /work) || fail "second create_task failed"
  read -r _ b2 <<<"$out2"
  [ "$(tern_calls "new${US}tab")" = 1 ] || fail "a later task should add a tab to the existing session"
  [ "$(jq -r --arg b "$b1" '.sessions[].tabs[] | select(any(.blocks[]; (.id|tostring) == $b)) | .name' "$W/state.json")" = fm-a ] \
    || fail "the first task's tab should be named fm-a"
  [ "$(jq '[.sessions[] | select(.name == "zz-fm-unit") | .tabs[]] | length' "$W/state.json")" = 2 ] \
    || fail "the session should hold exactly the two task tabs (no filler tab)"
  [ "$b1" != "$b2" ] || fail "tasks must get distinct blocks"
  pass "create_task: first task creates the home session with its tab as the task tab; later tasks add tabs"
}

test_create_task_refuses_duplicate_label() {
  make_tern_world dup
  fm_backend_tern_create_task fm-a /work >/dev/null || fail "create_task failed"
  if fm_backend_tern_create_task fm-a /work >/dev/null 2>&1; then
    fail "create_task must refuse a second live fm-a tab in the session"
  fi
  pass "create_task: refuses a duplicate task label (Tern enforces no tab-name uniqueness)"
}

test_create_task_uses_existing_empty_session() {
  make_tern_world empty-session
  # A session whose last task tab closed stays as an empty session.
  jq '.sessions += [{id: 1, name: "zz-fm-unit", tabs: []}]' "$W/state.json" >"$W/s2"
  mv "$W/s2" "$W/state.json"
  fm_backend_tern_create_task fm-a /work >/dev/null || fail "create_task should add a tab to an existing (even empty) session"
  [ "$(tern_calls "new${US}session")" = 0 ] || fail "an existing session must never be re-created"
  pass "create_task: an existing empty session gets a new tab"
}

test_parse_target() {
  fm_backend_tern_parse_target 'tern:firstmate-1a2b/123' || fail "valid target rejected"
  [ "$FM_BACKEND_TERN_SESSION" = firstmate-1a2b ] && [ "$FM_BACKEND_TERN_BLOCK" = 123 ] || fail "target fields wrong"
  fm_backend_tern_parse_target 'tern:/11' || fail "the unscoped supervisor form must parse"
  [ -z "$FM_BACKEND_TERN_SESSION" ] && [ "$FM_BACKEND_TERN_BLOCK" = 11 ] || fail "unscoped fields wrong"
  local bad
  for bad in 'firstmate:fm-x' 'default:w1:p2' 'tern:s/abc' 'tern:s/' 'tern:a/b/1' '11'; do
    if fm_backend_tern_parse_target "$bad"; then
      fail "target '$bad' must not parse as a Tern target"
    fi
  done
  pass "parse_target: accepts tern:<session>/<block> and tern:/<block>, rejects tmux/herdr shapes and junk"
}

test_target_ready_checks_label_and_recovers() {
  local out s b
  make_tern_world ready
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  fm_backend_tern_target_ready "tern:$s/$b" fm-a || fail "matching label should be ready"
  if fm_backend_tern_target_ready "tern:$s/$b" fm-other; then
    fail "a block whose tab carries another label must not be ready"
  fi
  # The recorded block is gone but the task's tab exists under a new block.
  fm_backend_tern_target_ready "tern:$s/99999" fm-a || fail "label recovery should find the task tab"
  [ "$FM_BACKEND_TERN_BLOCK" = "$b" ] || fail "label recovery should adopt the live block, got '$FM_BACKEND_TERN_BLOCK'"
  if fm_backend_tern_target_ready "tern:$s/99999"; then
    fail "an absent block with no label must not be ready"
  fi
  set_block_live "$b" false
  if fm_backend_tern_target_ready "tern:$s/$b" fm-a; then
    fail "an exited block must not be ready"
  fi
  pass "target_ready: verifies the task label, recovers a moved block by label, rejects exited blocks"
}

# --- send / capture / composer ----------------------------------------------

test_send_literal_and_keys() {
  local out s b
  make_tern_world send
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  fm_backend_tern_send_literal "tern:$s/$b" '--help me' fm-a || fail "send_literal failed"
  grep -qx "tern${US}send${US}$b${US}text${US}--${US}--help me" "$TERN_LOG" || fail "send_literal must pass text after -- so option-shaped text stays literal"
  fm_backend_tern_send_key "tern:$s/$b" C-c fm-a || fail "send_key C-c failed"
  fm_backend_tern_send_key "tern:$s/$b" Escape fm-a || fail "send_key Escape failed"
  fm_backend_tern_send_key "tern:$s/$b" C-u fm-a || fail "send_key C-u failed"
  grep -qx "tern${US}send${US}$b${US}keys${US}ctrl+c" "$TERN_LOG" || fail "C-c must normalize to ctrl+c (Tern rejects C-c)"
  grep -qx "tern${US}send${US}$b${US}keys${US}Escape" "$TERN_LOG" || fail "Escape not sent"
  grep -qx "tern${US}send${US}$b${US}keys${US}ctrl+u" "$TERN_LOG" || fail "C-u must normalize to ctrl+u"
  if fm_backend_tern_send_literal "tern:$s/$b" 'x' fm-other 2>/dev/null; then
    fail "send must refuse a block whose tab is another task's"
  fi
  pass "send: literal text after --, Tern key names, refuses a mismatched task tab"
}

test_capture_scrollback_trim_and_viewport() {
  local out s b cap
  make_tern_world capture
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  printf 'h1\nh2\nv1\nv2\nv3\n' >"$W/capture/$b.scrollback"
  printf 'v1\nv2\nv3\n' >"$W/capture/$b"
  cap=$(fm_backend_tern_capture "tern:$s/$b" 2 fm-a) || fail "capture failed"
  [ "$cap" = $'v2\nv3' ] || fail "capture should trim the scrollback read to the last 2 lines, got '$cap'"
  cap=$(fm_backend_capture tern "tern:$s/$b" 10 fm-a) || fail "dispatch capture failed"
  [ "$cap" = $'h1\nh2\nv1\nv2\nv3' ] || fail "dispatch capture should include scrollback, got '$cap'"
  fm_backend_visible_capture_supported tern || fail "tern must advertise its viewport capture"
  cap=$(fm_backend_visible_capture tern "tern:$s/$b" fm-a) || fail "visible capture failed"
  [ "$cap" = $'v1\nv2\nv3' ] || fail "visible capture must read the viewport only, got '$cap'"
  if fm_backend_tern_capture "tern:$s/77777" 5 >/dev/null 2>&1; then
    fail "capture of an absent block must fail"
  fi
  pass "capture: scrollback trimmed locally; visible capture is the viewport; absent block fails"
}

test_composer_state_reads_omp_through_ansi() {
  local out s b esc=$'\033'
  make_tern_world composer
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  # omp 18.6.1's idle composer as Tern --ansi renders it: a bright keycap and a
  # dark ghost hint right-aligned on the bare ❯ row, then omp's status row.
  printf '%s\n' "transcript" "" \
    "❯ ${esc}[0;38;2;229;229;231m                    ${esc}[0;38;2;0;180;255m⇧⇥${esc}[0;38;2;229;229;231m ${esc}[0;3;38;2;107;114;128mto change thinking effort${esc}[m" \
    " π · ◒ Opus 5.5 · /tmp · ◫ 1.2%/1M ⟲ · (sub)" >"$W/capture/$b.ansi"
  [ "$(fm_backend_composer_state tern "tern:$s/$b" fm-a)" = empty ] || fail "omp's idle hint row must read empty"
  printf '%s\n' "transcript" "" "❯ ${esc}[0;38;2;229;229;231mpending draft${esc}[m" \
    " π · ◒ Opus 5.5 · /tmp · ◫ 1.2%/1M ⟲ · (sub)" >"$W/capture/$b.ansi"
  [ "$(fm_backend_composer_state tern "tern:$s/$b" fm-a)" = pending ] || fail "typed omp input must read pending"
  [ "$(fm_backend_composer_state tern "tern:$s/66666" fm-gone)" = unknown ] || fail "an absent task block must read unknown"
  pass "composer_state: classifies Tern's --ansi omp capture (idle hint empty, typed text pending, absent unknown)"
}

# --- kill / list ---------------------------------------------------------------

test_kill_closes_and_tolerates_gone() {
  local out s b
  make_tern_world kill
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  fm_backend_kill tern "tern:$s/$b" "" fm-a || fail "kill should succeed"
  [ "$(tern_calls close)" = 1 ] || fail "kill should close the block once"
  fm_backend_kill tern "tern:$s/$b" "" fm-a || fail "kill of an already-gone block must succeed"
  [ "$(tern_calls close)" = 1 ] || fail "kill must not close anything for an already-gone block"
  pass "kill: closes the task block; an already-gone block is a quiet success"
}

test_kill_closes_exited_task_block() {
  local out s b s2 b2
  make_tern_world kill-dead
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  set_block_live "$b" false
  fm_backend_kill tern "tern:$s/$b" "" fm-a || fail "kill of an exited task block should succeed"
  [ "$(tern_calls close)" = 1 ] || fail "kill must close the task's exited kept-open block"
  fm_backend_tern_block_for_label "$(fm_backend_tern_inventory)" "$s" fm-a >/dev/null && fail "the exited task tab must be gone after kill"
  out=$(fm_backend_tern_create_task fm-c /work)
  read -r s2 b2 <<<"$out"
  set_block_live "$b2" false
  fm_backend_kill tern "tern:$s2/99999" "" fm-c || fail "kill of an exited task block found by label should succeed"
  [ "$(tern_calls close)" = 2 ] || fail "kill must close the exited block it recovers by the task label"
  out=$(fm_backend_tern_create_task fm-b /work)
  read -r s2 b2 <<<"$out"
  set_block_live "$b2" false
  fm_backend_kill tern "tern:$s2/$b2" "" fm-a || fail "an exited block in another task's tab means ours is gone"
  [ "$(tern_calls close)" = 2 ] || fail "kill must never close an exited block in another task's tab"
  pass "kill: closes the task's exited kept-open block (by id or label), never another task's"
}

test_kill_never_closes_another_task_tab() {
  local out s b
  make_tern_world kill-other
  out=$(fm_backend_tern_create_task fm-b /work)
  read -r s b <<<"$out"
  fm_backend_kill tern "tern:$s/$b" "" fm-a || fail "a block now holding another tab means ours is gone"
  [ "$(tern_calls close)" = 0 ] || fail "kill must never close a block whose tab belongs to another task"
  pass "kill: a recorded block reused by another task's tab is left alone"
}

test_kill_reports_failures() {
  local out s b
  make_tern_world kill-fail
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  if FM_TERN_FAKE_CLOSE_FAIL=1 fm_backend_kill tern "tern:$s/$b" "" fm-a 2>/dev/null; then
    fail "a refused close with the block still listed must fail"
  fi
  if FM_TERN_FAKE_LS_FAIL=1 fm_backend_kill tern "tern:$s/$b" "" fm-a 2>/dev/null; then
    fail "an unreadable inventory must fail (the endpoint may still be live)"
  fi
  pass "kill: a refused close or unreadable inventory is a failure, never a silent success"
}

test_list_live_lists_home_task_tabs() {
  local out
  make_tern_world list
  fm_backend_tern_create_task fm-a /work >/dev/null
  fm_backend_tern_create_task fm-b /work >/dev/null
  jq '.sessions += [{id: 5, name: "other", tabs: [{id: 6, name: "fm-z", blocks: [{id: 7, live: true}]}]}]' "$W/state.json" >"$W/s2"
  mv "$W/s2" "$W/state.json"
  out=$(fm_backend_tern_list_live | cut -f2 | sort | tr '\n' ' ')
  [ "$out" = "fm-a fm-b " ] || fail "list_live should list only this home's task tabs, got '$out'"
  pass "list_live: only fm-* tabs of this home's session"
}

# --- agent state / busy state ------------------------------------------------

test_agent_state_classifies_process() {
  local out s b
  make_tern_world agent
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  set_process "$b" omp omp
  [ "$(fm_backend_agent_state tern "tern:$s/$b")" = alive ] || fail "an omp foreground must read alive"
  set_process "$b" zsh /bin/zsh
  [ "$(fm_backend_agent_state tern "tern:$s/$b")" = dead ] || fail "a bare shell foreground must read dead"
  set_process "$b" python3 /usr/bin/python3
  [ "$(fm_backend_agent_state tern "tern:$s/$b")" = ambiguous ] || fail "an unattributable foreground must read ambiguous"
  set_block_live "$b" false
  [ "$(fm_backend_agent_state tern "tern:$s/$b")" = dead ] || fail "an exited kept-open block must read dead"
  [ "$(fm_backend_agent_state tern "tern:$s/55555")" = missing ] || fail "an absent block must read missing"
  [ "$(FM_TERN_FAKE_LS_FAIL=1 fm_backend_agent_state tern "tern:$s/$b")" = unreadable ] || fail "a failed inventory must read unreadable"
  [ "$(fm_backend_agent_state tern 'firstmate:fm-a')" = unreadable ] || fail "a non-tern target must read unreadable"
  fm_control_backend_state_verified tern 2>/dev/null || {
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-control-lib.sh"
    fm_control_backend_state_verified tern || fail "tern must count as a recovery-grade backend"
  }
  case "$(fm_control_endpoint_absence_verdict tern "tern:$s/55555")" in
    unproven*) ;;
    *) fail "tern absence must stay unproven (window-scoped inventory)" ;;
  esac
  pass "agent_state: process-level alive/dead/ambiguous, missing only from a readable inventory, absence never proven"
}

test_busy_state_reads_plugin_file() {
  local out s b gone
  make_tern_world busy
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  start_tern_window
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = unknown ] || fail "no plugin file must read unknown"
  set_process "$b" omp omp
  write_agents "$WINDOW_PID" "$b" working
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = busy ] || fail "working with a live omp must read busy"
  write_agents "$WINDOW_PID" "$b" idle
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = idle ] || fail "idle must read idle"
  write_agents "$WINDOW_PID" "$b" waiting_input
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = idle ] || fail "waiting_input must read idle"
  write_agents "$$" "$b" working
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = unknown ] || fail "a file whose window pid is not a tern process must read unknown"
  write_agents "$WINDOW_PID" "$b" working 2
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = unknown ] || fail "an unknown file version must read unknown"
  printf '{"version":1,"blocks":{"%s":{"agent":"working"}}}' "$b" >"$W/agents.json"
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = unknown ] || fail "a file without a window pid must read unknown"
  write_agents "$WINDOW_PID" "$b" -
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = unknown ] || fail "a block Tern does not list as an agent must read unknown"
  printf 'not json' >"$W/agents.json"
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = unknown ] || fail "a corrupt file must read unknown"
  set_process "$b" zsh /bin/zsh
  write_agents "$WINDOW_PID" "$b" working
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = unknown ] || fail "a stale working flag over a bare shell must read unknown"
  set_process "$b" omp omp
  gone=$WINDOW_PID
  kill "$gone" 2>/dev/null
  wait "$gone" 2>/dev/null
  [ "$(fm_backend_busy_state tern "tern:$s/$b")" = unknown ] || fail "a file left by a closed window must read unknown"
  pass "busy_state: plugin working/idle/waiting_input map to busy/idle while the writing window lives; closed-window, unversioned, corrupt, or shell-only read unknown"
}

test_busy_lib_trusts_tern_native_busy() {
  local out s b st
  make_tern_world busylib
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  start_tern_window
  set_process "$b" omp omp
  write_agents "$WINDOW_PID" "$b" working
  st="$W/state"
  mkdir -p "$st"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-busy-lib.sh"
  out=$(fm_busy_classify tern "tern:$s/$b" omp fm-a "$st" "")
  [ "$out" = "busy tern-native" ] || fail "a recordless omp task with native working should classify 'busy tern-native', got '$out'"
  kill "$WINDOW_PID" 2>/dev/null
  wait "$WINDOW_PID" 2>/dev/null
  pass "fm-busy-lib: trusts Tern's native busy verdict the way it trusts Herdr's"
}

# --- plugin regressions (real Luau, requires `luau` on PATH) ------------------

# run_plugin_harness <name> <driver>: runs the REAL
# bin/backends/tern-plugin/window.luau (not a reimplementation) against a
# stubbed window-host API and prints the driver's output. The stub keeps a
# simulated millisecond clock: timers and process callbacks fire in due order,
# each one a separate hook the way Tern calls them, and every host call
# advances the clock by its modeled UI-thread cost. The costs are the ones
# measured on a busy Tern 0.6.2 window (30 tabs churning their titles): a
# process spawn 25-33 ms, a JSON encode of 32 panes 14 ms, a file write 8 ms,
# the pane listing about 2 ms. A child given stdin is the plugin's writer, and
# its stdin is what lands in agents.json; one given none is the pid lookup.
# The driver fills WORLD (agents, sessions, tabs, panes) and calls
# run_until(ms); `hooks` records each hook's simulated duration.
run_plugin_harness() {
  local dir harness
  dir="$TMP_ROOT/plugin-$1"
  mkdir -p "$dir"
  harness="$dir/harness.luau"
  cat >"$harness" <<'LUA'
local FAKE_PID = 54321
local PID_STATUS = 0
local COST = { spawn = 33, encode = 14, write = 8, panes = 2, tabs = 1, call = 0.1 }
local now = 0
local seq = 0
local queue = {}
local hooks = {}
local write_count = 0
local committed_body = nil
local colors = {}
local WORLD = { agents = {}, sessions = {}, tabs = {}, panes = {} }

local function schedule(delay, kind, fn)
  seq += 1
  table.insert(queue, { due = now + delay, seq = seq, kind = kind, fn = fn })
end

local function run_until(t)
  while true do
    table.sort(queue, function(a, b)
      if a.due ~= b.due then return a.due < b.due end
      return a.seq < b.seq
    end)
    local h = queue[1]
    if h == nil or h.due > t then break end
    table.remove(queue, 1)
    if h.due > now then now = h.due end
    local start = now
    h.fn()
    table.insert(hooks, { kind = h.kind, ms = now - start })
  end
  now = t
end

local function jsonstr(s)
  return '"' .. tostring(s):gsub('[\\"]', '\\%0'):gsub('\n', '\\n') .. '"'
end
local function jsonencode(v)
  local t = type(v)
  if t == "table" then
    if next(v) == nil then return "{}" end
    local parts = {}
    for k, val in pairs(v) do
      table.insert(parts, jsonstr(k) .. ":" .. jsonencode(val))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return jsonstr(v)
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  else
    return "null"
  end
end

local CX = {
  agents = { list = function(_self) now += COST.call; return WORLD.agents end },
  session = {
    sessions = function(_self) now += COST.call; return WORLD.sessions end,
    tabs = function(_self) now += COST.tabs; return WORLD.tabs end,
    panes = function(_self) now += COST.panes; return WORLD.panes end,
  },
  layout = {
    color_tab = function(_self, id, color) now += COST.call; colors[id] = color or "" end,
    focus = function(...) end,
  },
}

tern = {
  plugin = { data = "/fake/plugin-data" },
  json = { encode = function(v) now += COST.encode; return jsonencode(v) end },
  fs = { write = function(_path, _body) now += COST.write end },
  process = {
    run = function(_argv, opts, cb)
      now += COST.spawn
      local result = { status = 0, stdout = "", stderr = "", timed_out = false }
      if opts and opts.stdin then
        local body = opts.stdin
        schedule(5, "process", function()
          write_count += 1
          committed_body = body
          cb(result, CX)
        end)
      else
        result.status = PID_STATUS
        result.stdout = tostring(FAKE_PID) .. "\n"
        schedule(5, "process", function() cb(result, CX) end)
      end
    end,
  },
  timer = function(ms, fn) schedule(ms, "timer", function() fn(CX) end) end,
  on = function(_event, _fn) end,
  command = function(_spec) end,
  chrome = { status = function(_fn) end, refresh = function() now += COST.call end },
  log = {
    warn = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
      print("WARN: " .. table.concat(parts, " "))
    end,
  },
}
LUA
  sed '1{/^--!strict/d;}' "$ROOT/bin/backends/tern-plugin/window.luau" >>"$harness"
  printf '\n%s\n' "$2" >>"$harness"
  luau "$harness" 2>&1
}

# test_plugin_first_write_publishes_current_format: reproduces the captain's
# fresh-window race (docs/tern-backend.md): window_pid resolves, but with no
# agent panes and no fm-* task tabs the signature is the empty string "". A
# sentinel that starts equal to "" would treat that first scan as "no change"
# and never publish, leaving a stale or old-format file from an earlier window
# in place for however long the window stays idle. Skips cleanly without
# `luau` on PATH (same convention as the jq/tern skips above), consistent with
# every other optional-tool-gated case in this suite.
test_plugin_first_write_publishes_current_format() {
  command -v luau >/dev/null 2>&1 || { pass "luau not installed, skipping the window.luau first-write regression"; return; }
  local out write_count body
  out=$(run_plugin_harness first-write '
run_until(3000)
print("RESULT_WRITE_COUNT=" .. write_count)
print("RESULT_COMMITTED_BODY=" .. (committed_body or ""))
') || fail "the plugin harness crashed: $out"
  write_count=$(printf '%s\n' "$out" | sed -n 's/^RESULT_WRITE_COUNT=//p')
  body=$(printf '%s\n' "$out" | sed -n 's/^RESULT_COMMITTED_BODY=//p')
  [ "$write_count" = 1 ] || fail "a freshly loaded window must publish agents.json as soon as window_pid is known, even with an empty (no agents, no fm-* tabs) signature; got write_count=$write_count, harness output: $out"
  printf '%s' "$body" | jq -e '.version == 1 and (.window_pid | type) == "number" and (.blocks | type) == "object"' >/dev/null \
    || fail "the first-written body must be current format (version, window_pid, blocks), got: $body"
  pass "window.luau plugin: a freshly loaded window publishes current-format state as soon as window_pid is known, even with no agents/tabs"
}

# test_plugin_hooks_stay_inside_tern_budget: Tern disables a window timer until
# reload once one call runs past 50 ms ("plugin hook exceeded its budget;
# disabled until reload plugin=firstmate-agents hook=timer"), after which task
# tab colours and the agent count freeze. With 40 fm-* worker tabs whose state
# changes every second, no single hook may exceed the budget at the measured
# costs, and the plugin must still publish and colour the final state.
test_plugin_hooks_stay_inside_tern_budget() {
  command -v luau >/dev/null 2>&1 || { pass "luau not installed, skipping the window.luau budget regression"; return; }
  local out max kind writes body orange green
  out=$(run_plugin_harness budget '
local N = 40
local function world(state, busy, alert_even)
  WORLD.sessions = { { id = 1, name = "fm" } }
  WORLD.tabs, WORLD.panes, WORLD.agents = {}, {}, {}
  for i = 1, N do
    local tab, pane = 100 + i, 200 + i
    table.insert(WORLD.tabs, { id = tab, name = string.format("fm-%02d", i), session = 1, pane = pane })
    table.insert(WORLD.panes, { pane = pane, tab = tab, title = "omp", busy = busy, at_prompt = not busy,
      alert = alert_even and i % 2 == 0, exited = nil })
    table.insert(WORLD.agents, { pane = pane, state = state, cwd = "/work" })
  end
end
for second = 1, 10 do
  world(if second % 2 == 0 then "working" else "idle", second % 2 == 0, second % 3 == 0)
  run_until(second * 1000 + 500)
end
world("idle", false, true)
run_until(15000)
local max, kind = 0, ""
for _, h in hooks do
  if h.ms > max then max, kind = h.ms, h.kind end
end
local orange, green = 0, 0
for _, c in colors do
  if c == "orange" then orange += 1 elseif c == "green" then green += 1 end
end
print("RESULT_MAX_HOOK_MS=" .. max)
print("RESULT_MAX_HOOK_KIND=" .. kind)
print("RESULT_WRITE_COUNT=" .. write_count)
print("RESULT_COLORS=" .. orange .. " " .. green)
print("RESULT_COMMITTED_BODY=" .. (committed_body or ""))
') || fail "the plugin harness crashed: $out"
  max=$(printf '%s\n' "$out" | sed -n 's/^RESULT_MAX_HOOK_MS=//p')
  kind=$(printf '%s\n' "$out" | sed -n 's/^RESULT_MAX_HOOK_KIND=//p')
  writes=$(printf '%s\n' "$out" | sed -n 's/^RESULT_WRITE_COUNT=//p')
  read -r orange green <<<"$(printf '%s\n' "$out" | sed -n 's/^RESULT_COLORS=//p')"
  body=$(printf '%s\n' "$out" | sed -n 's/^RESULT_COMMITTED_BODY=//p')
  awk -v m="$max" 'BEGIN { exit !(m != "" && m + 0 < 50) }' \
    || fail "every plugin hook must stay under Tern's 50 ms budget on a busy window; the longest $kind hook took ${max} ms, harness output: $out"
  [ "${writes:-0}" -ge 2 ] || fail "the plugin must keep publishing while worker state changes, got $writes writes: $out"
  [ "$orange $green" = "20 20" ] || fail "the final state must colour 20 tabs needing input orange and 20 idle tabs green, got orange=$orange green=$green"
  printf '%s' "$body" | jq -e '(.blocks | length) == 40 and ([.blocks[] | select(.shown == "waiting_input")] | length) == 20 and ([.blocks[] | select(.busy)] | length) == 0' >/dev/null \
    || fail "agents.json must end on the final worker state, got: $body"
  pass "window.luau plugin: with 40 busy worker tabs every hook stays under Tern's 50 ms budget (longest ${max} ms) and the final state is published and coloured"
}

# test_plugin_scans_while_pid_lookup_fails: a timer call that spawns the
# window-pid lookup skips its scan, so a lookup that keeps failing must not be
# retried on every call, or tab colours and the agent count never update.
test_plugin_scans_while_pid_lookup_fails() {
  command -v luau >/dev/null 2>&1 || { pass "luau not installed, skipping the failing pid lookup regression"; return; }
  local out colored
  out=$(run_plugin_harness pid-fails '
PID_STATUS = 1
WORLD.sessions = { { id = 1, name = "fm" } }
WORLD.tabs = { { id = 101, name = "fm-01", session = 1, pane = 201 } }
WORLD.panes = { { pane = 201, tab = 101, title = "omp", busy = true, at_prompt = false, alert = false, exited = nil } }
WORLD.agents = { { pane = 201, state = "working", cwd = "/work" } }
run_until(10500)
print("RESULT_COLOR=" .. (colors[101] or "none"))
print("RESULT_WRITES=" .. write_count)
') || fail "the plugin harness crashed: $out"
  colored=$(printf '%s\n' "$out" | sed -n 's/^RESULT_COLOR=//p')
  [ -n "$colored" ] && [ "$colored" != none ] \
    || fail "a failing window-pid lookup must not starve the scan that colours task tabs: $out"
  [ "$(printf '%s\n' "$out" | sed -n 's/^RESULT_WRITES=//p')" = 0 ] \
    || fail "the plugin must not publish agents.json without a window pid: $out"
  pass "window.luau plugin: a failing window-pid lookup still lets every other timer call colour task tabs"
}

# --- seams outside the adapter -----------------------------------------------

# shellcheck disable=SC2016 # The child bash expands "$1" and the probe output.
test_detection_innermost_wins() {
  local out
  out=$(env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID TERN_PANE=11 TERM_PROGRAM=tern bash -c '. "$1"; fm_backend_detect >/dev/null; printf "%s %s" "$FM_BACKEND_DETECTED" "$FM_BACKEND_DETECT_SIGNAL"' _ "$ROOT/bin/fm-backend.sh")
  [ "$out" = "tern TERN_PANE" ] || fail "TERN_PANE with TERM_PROGRAM=tern should detect tern, got '$out'"
  out=$(env -u HERDR_ENV -u CMUX_WORKSPACE_ID TMUX=/tmp/s,1,0 TERN_PANE=11 TERM_PROGRAM=tern bash -c '. "$1"; fm_backend_detect' _ "$ROOT/bin/fm-backend.sh")
  [ "$out" = tmux ] || fail "tmux inside Tern must win, got '$out'"
  out=$(env -u TMUX -u CMUX_WORKSPACE_ID HERDR_ENV=1 TERN_PANE=11 TERM_PROGRAM=tern bash -c '. "$1"; fm_backend_detect' _ "$ROOT/bin/fm-backend.sh")
  [ "$out" = herdr ] || fail "herdr inside Tern must win, got '$out'"
  out=$(env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier TERN_PANE=11 TERM_PROGRAM=ghostty bash -c '. "$1"; fm_backend_detect' _ "$ROOT/bin/fm-backend.sh")
  [ "$out" != tern ] || fail "an inherited TERN_PANE under another terminal must not detect tern"
  out=$(env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u FM_BACKEND TERN_PANE=11 TERM_PROGRAM=tern FM_CONFIG_OVERRIDE="$TMP_ROOT/no-config" \
    bash -c '. "$1"; fm_backend_name' _ "$ROOT/bin/fm-backend.sh" 2>"$TMP_ROOT/notice")
  [ "$out" = tern ] || fail "fm_backend_name should resolve the detected tern, got '$out'"
  grep -q 'EXPERIMENTAL tern backend' "$TMP_ROOT/notice" || fail "auto-detected tern should print the experimental notice"
  pass "detection: Tern needs TERN_PANE and TERM_PROGRAM=tern; tmux and herdr nested inside it win"
}

test_validate_task_endpoint() {
  local meta="$TMP_ROOT/validate.meta"
  printf 'window=tern:firstmate-ab/42\nendpoint_task_id=t1\nworktree=/w\nproject=/p\nbackend=tern\ntern_session=firstmate-ab\ntern_block_id=42\n' >"$meta"
  fm_backend_validate_task_endpoint "$meta" t1 2>/dev/null || fail "a consistent tern record must validate"
  [ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "tern:tern:firstmate-ab/42" ] || fail "validated target wrong"
  printf 'window=tern:firstmate-ab/43\nendpoint_task_id=t1\nworktree=/w\nproject=/p\nbackend=tern\ntern_session=firstmate-ab\ntern_block_id=42\n' >"$meta"
  if fm_backend_validate_task_endpoint "$meta" t1 2>/dev/null; then
    fail "a window that disagrees with tern_block_id must be refused"
  fi
  printf 'window=tern:firstmate-ab/42\nworktree=/w\nproject=/p\nbackend=tern\ntern_session=firstmate-ab\ntern_block_id=42\n' >"$meta"
  if fm_backend_validate_task_endpoint "$meta" t1 2>/dev/null; then
    fail "a tern record without an endpoint task binding must be refused"
  fi
  pass "validate_task_endpoint: binds window to tern_session/tern_block_id and the task id"
}

test_explicit_target_routing() {
  local out s b home esc=$'\033'
  [ "$(fm_backend_of_selector 'tern:s/42' 'tern:s/42' "$TMP_ROOT/no-state")" = tern ] || fail "an unrecorded tern target must route to tern"
  [ "$(fm_backend_of_selector 'firstmate:fm-x' 'firstmate:fm-x' "$TMP_ROOT/no-state")" = tmux ] || fail "tmux targets must keep routing to tmux"
  make_tern_world send-explicit
  out=$(fm_backend_tern_create_task fm-a /work)
  read -r s b <<<"$out"
  home="$W/home"
  mkdir -p "$home/state"
  printf '%s\n' "transcript" "" "❯ ${esc}[0;3;38;2;107;114;128mto change thinking effort${esc}[m" >"$W/capture/$b.ansi"
  FM_HOME="$home" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "tern:$s/$b" "hello tern" >/dev/null 2>&1 ||
    fail "fm-send must deliver to a live unrecorded tern:<session>/<block> target"
  grep -qx "tern${US}send${US}$b${US}text${US}--${US}hello tern" "$TERN_LOG" || fail "fm-send must type the message into the tern block"
  grep -qx "tern${US}send${US}$b${US}keys${US}Enter" "$TERN_LOG" || fail "fm-send must submit the message in the tern block"
  set_block_live "$b" false
  : >"$TERN_LOG"
  if FM_HOME="$home" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "tern:$s/$b" "hello again" >"$W/send.err" 2>&1; then
    fail "fm-send must refuse an exited tern block"
  fi
  grep -q "is not a live tern endpoint" "$W/send.err" || fail "the refusal must name the tern backend, got: $(cat "$W/send.err")"
  [ "$(tern_calls send)" = 0 ] || fail "fm-send must not type into an exited tern block"
  pass "explicit targets: fm-send delivers to a live tern:<session>/<block>, refuses an exited one; tmux targets unchanged"
}

# shellcheck disable=SC2016 # The child bash expands "$1" and the probe output.
test_supervisor_discovery() {
  local out
  out=$(env -u TMUX_PANE -u HERDR_ENV -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND TERN_PANE=11 TERM_PROGRAM=tern \
    bash -c '. "$1"; printf "%s %s" "$(discover_supervisor_target)" "$(discover_supervisor_backend)"' _ "$ROOT/bin/fm-supervisor-target-lib.sh")
  [ "$out" = "tern:/11 tern" ] || fail "a Tern supervisor pane should resolve to 'tern:/11 tern', got '$out'"
  out=$(env -u HERDR_ENV -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND TMUX_PANE=%3 TERN_PANE=11 TERM_PROGRAM=tern \
    bash -c '. "$1"; printf "%s %s" "$(discover_supervisor_target)" "$(discover_supervisor_backend)"' _ "$ROOT/bin/fm-supervisor-target-lib.sh")
  [ "$out" = "%3 tmux" ] || fail "tmux inside Tern must win supervisor discovery, got '$out'"
  pass "supervisor discovery: TERN_PANE yields tern:/<block> after tmux and herdr"
}

test_secondmate_spawn_refuses_tern() {
  local dir="$TMP_ROOT/secondmate-refuse" out status
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects"
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" FM_PROJECTS_OVERRIDE="$dir/projects" \
    "$ROOT/bin/fm-spawn.sh" sm-tern-test --secondmate --backend tern 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh should refuse a --secondmate spawn with --backend tern"
  assert_contains "$out" "does not support --secondmate" "fm-spawn.sh did not report the tern secondmate refusal"
  pass "fm-spawn.sh: refuses backend=tern for --secondmate spawns"
}

test_omp_spawn_carries_tern_title_overlay() {
  local case_dir="$TMP_ROOT/omp-spawn" home fakebin id=tern-omp-q1 out status staged launch
  make_tern_world omp-spawn
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" omp)
  fm_test_spawn_home "$home" omp
  fm_git_worktree "$case_dir/project" "$case_dir/wt" wt-tern-omp
  fm_test_spawn_brief "$home" "$id"
  # The first task block in an empty world is 102; its shell sits in the worktree.
  printf '{"pane":102,"child":{"pid":1,"name":"zsh","argv":["zsh"],"cwd":"%s"},"group":1,"foreground":{"pid":1,"name":"zsh","argv":["zsh"],"cwd":"%s"}}' \
    "$case_dir/wt" "$case_dir/wt" >"$W/process/102"
  out=$(fm_test_run_spawn "$home" "$case_dir/wt" "$fakebin" "$id" "$case_dir/project" --harness omp --backend tern --scout)
  status=$?
  [ "$status" -eq 0 ] || fail "an omp scout spawn on the tern backend should succeed: $out"
  staged=$(sed -n "s/^tern${US}send${US}102${US}text${US}--${US}\. '\(.*\)'\$/\1/p" "$TERN_LOG")
  [ -f "$staged" ] || fail "the tern spawn did not type a staged launch file: $(tr "$US" ' ' <"$TERN_LOG")"
  launch=$(cat "$staged")
  rm -rf "/tmp/fm-$id" "/tmp/fm-$id+"*
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --config '$ROOT/.omp/fm-tern-worker-overlay.yml' --auto-approve" \
    "an omp worker on tern must add the title-spinner overlay after the posture overlay and before --auto-approve"
  pass "fm-spawn.sh: an omp worker on tern carries the title-spinner overlay"
}

test_version_check() {
  make_tern_world version
  fm_backend_tern_version_check || fail "0.4.5 must pass the version gate"
  if FM_TERN_FAKE_VERSION=0.3.9 fm_backend_tern_version_check 2>/dev/null; then
    fail "0.3.9 must fail the version gate"
  fi
  [ "$(fm_backend_required_tools tern)" = "tern jq treehouse" ] || fail "required tools for tern wrong"
  pass "version gate and required tools"
}

test_create_task_first_creates_session_then_tabs
test_create_task_refuses_duplicate_label
test_create_task_uses_existing_empty_session
test_parse_target
test_target_ready_checks_label_and_recovers
test_send_literal_and_keys
test_capture_scrollback_trim_and_viewport
test_composer_state_reads_omp_through_ansi
test_kill_closes_and_tolerates_gone
test_kill_closes_exited_task_block
test_kill_never_closes_another_task_tab
test_kill_reports_failures
test_list_live_lists_home_task_tabs
test_agent_state_classifies_process
test_busy_state_reads_plugin_file
test_busy_lib_trusts_tern_native_busy
test_plugin_first_write_publishes_current_format
test_plugin_hooks_stay_inside_tern_budget
test_plugin_scans_while_pid_lookup_fails
test_detection_innermost_wins
test_validate_task_endpoint
test_explicit_target_routing
test_supervisor_discovery
test_secondmate_spawn_refuses_tern
test_omp_spawn_carries_tern_title_overlay
test_version_check
