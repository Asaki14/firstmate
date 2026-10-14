#!/usr/bin/env bash
# bin/backends/tern.sh - the Tern session-provider adapter (EXPERIMENTAL).
#
# Tern (https://docs.stencil.so/tern/) is Stencil's multiplexing terminal: one
# per-user session daemon holding named sessions -> tabs -> blocks (panes),
# shown by the Tern app's windows and driven by the `tern` CLI. Tern is a
# session provider ONLY, exactly like herdr/zellij/cmux: the worktree provider
# stays treehouse. Sourced only through bin/fm-backend.sh's fm_backend_source
# in normal operation; the unit tests source it directly. docs/tern-backend.md
# owns setup, limits, and the live verification record (Tern 0.4.5, macOS
# arm64).
#
# Container shape: ONE Tern session PER FIRSTMATE HOME, named by the shared
# per-installation home tag (bin/fm-backend-hometag-lib.sh, e.g.
# "firstmate-1a2b3c4d"; FM_TERN_SESSION overrides it), holding ONE TAB PER
# TASK named with the caller-facing fm-<id> label. Tern enforces unique
# session names, so the session itself scopes the tab names to this home and
# installation. The first task of a home creates the session with
# `tern new session` (its initial tab becomes that task's tab, so no filler
# tab is left behind); later tasks add `tern new tab <session>`. Neither
# command shows the new tab or steals focus (verified live): a task tab only
# appears in the window's tab bar when the captain opens that session.
#
# Target string shape: "tern:<session>/<block-id>". The literal `tern:` prefix
# and the `/` keep it distinct from tmux's `session:window` and herdr's
# `session:wX:pY` in fm-send.sh's explicit-target heuristic; the block id is
# Tern's own numeric pane id, which every CLI verb accepts. An empty session
# ("tern:/<block>") is the unscoped form used only for a supervisor pane
# discovered from $TERN_PANE (bin/fm-supervisor-target-lib.sh).
#
# Verified facts that shaped this adapter (docs/tern-backend.md has the log):
#   1. `tern send <block> text -- <text>` types literally without submitting;
#      `tern send <block> keys Enter|Escape|ctrl+c|ctrl+u` sends named keys.
#      Delivery needs a Tern window attached to the daemon.
#   2. `tern capture <block>` is the VIEWPORT only (a hidden tab is 80x24);
#      `--scrollback` adds history and `--ansi` keeps SGR styling. A fresh
#      block is readable immediately (no cmux-style fresh-surface error).
#   3. `tern process <block> --json` reports the foreground process with a
#      LIVE cwd (herdr-shape, not frozen like cmux/zellij), so current_path
#      needs no pwd-marker probe.
#   4. omp renders natively through Tern's surface protocol when it detects
#      Tern; its composer then never reaches `tern capture` (not even with
#      --surfaces, which returns only the transcript's main region). fm-spawn
#      therefore exports PI_TUI_NATIVE=0 into every Tern task pane before
#      launch, which makes omp (and pi) draw an ordinary terminal UI that the
#      shared composer classifier can read.
#   5. `tern close <block>` ends the program without confirmation; a session
#      whose last tab closed stays as an empty session. An unknown block fails
#      every verb with "no block is called `<id>`" and exit 1.
#   6. Agent state (idle/working/waiting_input/exited) exists only for
#      window-side Luau plugins. bin/backends/tern-plugin publishes it to a
#      JSON file this adapter reads for busy_state; recovery-grade
#      agent_state stays process-level (bin/fm-agent-process-lib.sh).
#
# Requires: tern (CLI; the macOS app bundle's binary is the fallback), jq.

FM_BACKEND_TERN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_TERN_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_TERN_ROOT/bin/fm-backend-hometag-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_TERN_ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_TERN_ROOT/bin/fm-agent-process-lib.sh"

# Verified minimum: the version the live pass ran against.
FM_BACKEND_TERN_MIN_MAJOR=0
FM_BACKEND_TERN_MIN_MINOR=4

FM_BACKEND_TERN_BUNDLE_BIN="${FM_BACKEND_TERN_BUNDLE_BIN:-/Applications/Tern.app/Contents/MacOS/tern}"

# fm_backend_tern_bin: the tern CLI - PATH first, then the app bundle.
fm_backend_tern_bin() {
  if command -v tern >/dev/null 2>&1; then
    printf 'tern'
    return 0
  fi
  if [ -x "$FM_BACKEND_TERN_BUNDLE_BIN" ]; then
    printf '%s' "$FM_BACKEND_TERN_BUNDLE_BIN"
    return 0
  fi
  return 1
}

fm_backend_tern_cli() {  # <tern-subcommand-and-args...>
  local bin
  bin=$(fm_backend_tern_bin) || return 1
  "$bin" "$@"
}

fm_backend_tern_tool_check() {
  fm_backend_tern_bin >/dev/null 2>&1 || { echo "error: backend=tern selected but the 'tern' CLI was not found on PATH or at $FM_BACKEND_TERN_BUNDLE_BIN (https://docs.stencil.so/tern/)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=tern selected but 'jq' is not installed (required to parse tern's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_tern_version_check: `tern --version` prints
# "tern 0.4.5 (1d14241)" and needs no daemon.
fm_backend_tern_version_check() {
  fm_backend_tern_tool_check || return 1
  local raw ver major rest minor
  raw=$(fm_backend_tern_cli --version 2>/dev/null) || { echo "error: 'tern --version' failed; is Tern installed correctly?" >&2; return 1; }
  ver=$(printf '%s' "$raw" | awk '{print $2}')
  case "$ver" in
    ''|*[!0-9.]*)
      echo "error: could not parse a tern version from '$raw'; refusing to use an unverified Tern build" >&2
      return 1
      ;;
  esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  if [ "$major" -lt "$FM_BACKEND_TERN_MIN_MAJOR" ] || { [ "$major" -eq "$FM_BACKEND_TERN_MIN_MAJOR" ] && [ "$minor" -lt "$FM_BACKEND_TERN_MIN_MINOR" ]; }; then
    echo "error: tern $ver is older than the verified minimum $FM_BACKEND_TERN_MIN_MAJOR.$FM_BACKEND_TERN_MIN_MINOR; update Tern before using backend=tern" >&2
    return 1
  fi
  return 0
}

# fm_backend_tern_session_name: this home's Tern session. FM_TERN_SESSION
# overrides the home tag (tests and the smoke script use zz-* names).
fm_backend_tern_session_name() {
  if [ -n "${FM_TERN_SESSION:-}" ]; then
    printf '%s' "$FM_TERN_SESSION"
    return 0
  fi
  fm_backend_hometag
}

# fm_backend_tern_inventory: `tern ls --json` - every session, tab, and block
# of the window this process addresses. A failed read proves nothing.
fm_backend_tern_inventory() {
  local out
  out=$(fm_backend_tern_cli ls --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e '.sessions | type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# fm_backend_tern_container_ensure: version gate plus a reachability read.
# Tern's daemon and window belong to the captain's desktop session; firstmate
# never launches or quits the app. Echoes this home's session name.
fm_backend_tern_container_ensure() {
  fm_backend_tern_version_check || return 1
  fm_backend_tern_inventory >/dev/null || {
    echo "error: backend=tern could not read Tern's sessions ('tern ls --json' failed). Open the Tern app so its daemon and a window are running, or set config/backend to tmux (or pass --backend tmux) if you did not mean to use Tern." >&2
    return 1
  }
  fm_backend_tern_session_name
}

# fm_backend_tern_block_record: one block's "<session>US<tab name>US<live>"
# (US = the 0x1f unit separator, which never collapses an empty tab name the
# way a whitespace IFS would) from an inventory, or failure when absent.
fm_backend_tern_block_record() {  # <inventory-json> <block-id>
  local rec
  rec=$(printf '%s' "$1" | jq -r --arg b "$2" '
    first(.sessions[]? as $s | $s.tabs[]? as $t | $t.blocks[]?
      | select((.id | tostring) == $b)
      | [$s.name, ($t.name // ""), (if .live == false then "dead" else "live" end)] | join("\u001f")) // empty
  ' 2>/dev/null)
  [ -n "$rec" ] || return 1
  printf '%s' "$rec"
}

# fm_backend_tern_block_for_label: the first block of the tab named <label>
# in <session>, or failure. Tern enforces no tab-name uniqueness; the
# duplicate check in create_task is ours.
fm_backend_tern_block_for_label() {  # <inventory-json> <session> <label>
  local id
  id=$(printf '%s' "$1" | jq -r --arg s "$2" --arg l "$3" '
    first(.sessions[]? | select(.name == $s) | .tabs[]? | select(.name == $l) | .blocks[0]?.id) // empty
  ' 2>/dev/null)
  case "$id" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$id"
}

fm_backend_tern_session_exists() {  # <inventory-json> <session>
  printf '%s' "$1" | jq -e --arg s "$2" 'any(.sessions[]?; .name == $s)' >/dev/null 2>&1
}

# fm_backend_tern_create_task: create the task's tab in this home's session
# and name it <label>, refusing an existing live <label>. Echoes
# "<session> <block-id>".
fm_backend_tern_create_task() {  # <label> <cwd>
  local label=$1 cwd=$2 session inv out block attempt
  session=$(fm_backend_tern_session_name)
  inv=$(fm_backend_tern_inventory) || { echo "error: could not read Tern's sessions before creating '$label'" >&2; return 1; }
  if fm_backend_tern_block_for_label "$inv" "$session" "$label" >/dev/null; then
    echo "error: Tern tab '$label' already exists in session '$session'" >&2
    return 1
  fi
  out=
  for attempt in 1 2; do
    if fm_backend_tern_session_exists "$inv" "$session"; then
      out=$(fm_backend_tern_cli new tab "$session" --cwd "$cwd" --json 2>&1) && break
    else
      out=$(fm_backend_tern_cli new session "$session" --cwd "$cwd" --json 2>&1) && break
    fi
    # Another spawn may have created the session between our read and our
    # create; re-read once and take the other branch.
    [ "$attempt" -eq 1 ] || break
    inv=$(fm_backend_tern_inventory) || break
    out=
  done
  block=$(printf '%s' "$out" | jq -r '.block // empty' 2>/dev/null)
  case "$block" in
    ''|*[!0-9]*)
      echo "error: tern could not create a tab for '$label' in session '$session': $out" >&2
      return 1
      ;;
  esac
  if ! out=$(fm_backend_tern_cli rename "$block" "$label" 2>&1); then
    echo "error: tern could not name tab $block '$label': $out" >&2
    fm_backend_tern_cli close "$block" >/dev/null 2>&1 || true
    return 1
  fi
  printf '%s %s' "$session" "$block"
}

# fm_backend_tern_parse_target: split "tern:<session>/<block>". Sets
# FM_BACKEND_TERN_SESSION and FM_BACKEND_TERN_BLOCK.
fm_backend_tern_parse_target() {  # <target>
  local target=$1 rest
  FM_BACKEND_TERN_SESSION=
  FM_BACKEND_TERN_BLOCK=
  case "$target" in
    tern:*/*) ;;
    *) return 1 ;;
  esac
  rest=${target#tern:}
  FM_BACKEND_TERN_SESSION=${rest%/*}
  FM_BACKEND_TERN_BLOCK=${rest##*/}
  case "$FM_BACKEND_TERN_BLOCK" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_BACKEND_TERN_SESSION" in */*) return 1 ;; esac
  return 0
}

# fm_backend_tern_target_ready: parse the target and verify its block is live
# in the inventory. With the owning task's fm-<id> label, the block must still
# sit in a tab of that name in the recorded session; when the recorded block
# is gone the label recovers the task's current block (Tern block ids do not
# survive a daemon restart that rebuilds the session).
fm_backend_tern_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} inv rec session tab live block
  fm_backend_tern_parse_target "$1" || return 1
  inv=$(fm_backend_tern_inventory) || return 1
  if rec=$(fm_backend_tern_block_record "$inv" "$FM_BACKEND_TERN_BLOCK"); then
    IFS=$'\037' read -r session tab live <<EOF
$rec
EOF
    [ "$live" = live ] || return 1
    [ -n "$expected_label" ] || return 0
    [ "$tab" = "$expected_label" ] || return 1
    [ -z "$FM_BACKEND_TERN_SESSION" ] || [ "$session" = "$FM_BACKEND_TERN_SESSION" ] || return 1
    return 0
  fi
  [ -n "$expected_label" ] && [ -n "$FM_BACKEND_TERN_SESSION" ] || return 1
  block=$(fm_backend_tern_block_for_label "$inv" "$FM_BACKEND_TERN_SESSION" "$expected_label") || return 1
  rec=$(fm_backend_tern_block_record "$inv" "$block") || return 1
  [ "${rec##*$'\037'}" = live ] || return 1
  FM_BACKEND_TERN_BLOCK=$block
  return 0
}

# fm_backend_tern_process_json: `tern process <block> --json`.
fm_backend_tern_process_json() {  # <block>
  fm_backend_tern_cli process "$1" --json 2>/dev/null
}

# fm_backend_tern_current_path: the foreground process's live cwd (verified
# fact 3), or empty on any error.
fm_backend_tern_current_path() {  # <target> [expected-label]
  local out
  fm_backend_tern_target_ready "$1" "${2:-}" || return 0
  out=$(fm_backend_tern_process_json "$FM_BACKEND_TERN_BLOCK") || return 0
  printf '%s' "$out" | jq -r '.foreground.cwd // .child.cwd // empty' 2>/dev/null
}

# fm_backend_tern_send_literal: TEXT as literal, UNSUBMITTED input. `--`
# keeps option-shaped text literal.
fm_backend_tern_send_literal() {  # <target> <text> [expected-label]
  fm_backend_tern_target_ready "$1" "${3:-}" || return 1
  fm_backend_tern_cli send "$FM_BACKEND_TERN_BLOCK" text -- "$2" >/dev/null 2>&1
}

# fm_backend_tern_normalize_key: firstmate's key vocabulary onto Tern's
# `send keys` combos (verified: Enter, Escape, ctrl+c, ctrl+u; Tern rejects
# tmux's C-c spelling).
fm_backend_tern_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'Enter' ;;
    Escape|escape|Esc|esc) printf 'Escape' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl+c' ;;
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'ctrl+u' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_tern_send_key() {  # <target> <key> [expected-label]
  fm_backend_tern_target_ready "$1" "${3:-}" || return 1
  local key
  key=$(fm_backend_tern_normalize_key "$2")
  fm_backend_tern_cli send "$FM_BACKEND_TERN_BLOCK" keys "$key" >/dev/null 2>&1
}

# fm_backend_tern_send_text_line: one line of TEXT then Enter. Returns 1 when
# Enter failed but Ctrl+C cleared the typed input, 2 when even that failed and
# the composer may still hold it (the cmux/zellij contract fm-spawn relies on).
fm_backend_tern_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_tern_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_tern_send_key "$1" Enter "${3:-}" && return 0
  fm_backend_tern_send_key "$1" C-c "${3:-}" >/dev/null 2>&1 && return 1
  return 2
}

# fm_backend_tern_capture: bounded plain-text capture including scrollback,
# trimmed locally to <lines>.
fm_backend_tern_capture() {  # <target> <lines> [expected-label]
  fm_backend_tern_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-200} out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  out=$(fm_backend_tern_cli capture "$FM_BACKEND_TERN_BLOCK" --scrollback 2>/dev/null) || return 1
  printf '%s\n' "$out" | tail -n "$lines"
}

# fm_backend_tern_visible_capture: the viewport only (verified fact 2).
fm_backend_tern_visible_capture() {  # <target> [expected-label]
  fm_backend_tern_target_ready "$1" "${2:-}" || return 1
  fm_backend_tern_cli capture "$FM_BACKEND_TERN_BLOCK" 2>/dev/null
}

# fm_backend_tern_composer_capture: the styled viewport tail. --ansi keeps the
# SGR runs the shared classifier uses to strip ghost/placeholder text.
fm_backend_tern_composer_capture() {  # <target> [expected-label]
  fm_backend_tern_target_ready "$1" "${2:-}" || return 1
  local out
  out=$(fm_backend_tern_cli capture "$FM_BACKEND_TERN_BLOCK" --ansi 2>/dev/null) || return 1
  printf '%s\n' "$out" | tail -n "$FM_COMPOSER_CAPTURE_LINES"
}

fm_backend_tern_composer_caps() {
  printf 'styled=1\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

fm_backend_tern_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_tern_composer_capture "$1" "${2:-}") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_tern_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_tern_send_text_submit: type once, then the shared
# verify-and-retry-Enter loop against the shared composer verdict.
fm_backend_tern_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  fm_backend_tern_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_tern_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_tern_send_key fm_backend_tern_composer_state \
    "$target" "$retries" "$sleep_s" "$expected_label"
}

# fm_backend_tern_kill: close the task's block, including an exited
# kept-open one still sitting in the task's tab (found by label when the
# recorded block id is gone). Already gone (or now holding another tab's
# block) is success; a close Tern refused while the block is still listed, or
# an unreadable inventory, is a failure the caller must not paper over
# (fm_backend_kill's retain-and-stop contract).
fm_backend_tern_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-} inv rec session tab live
  fm_backend_tern_parse_target "$1" || return 0
  inv=$(fm_backend_tern_inventory) || {
    echo "error: could not read Tern's sessions to close $1" >&2
    return 1
  }
  if ! fm_backend_tern_target_ready "$1" "$expected_label"; then
    if ! rec=$(fm_backend_tern_block_record "$inv" "$FM_BACKEND_TERN_BLOCK"); then
      [ -n "$expected_label" ] && [ -n "$FM_BACKEND_TERN_SESSION" ] || return 0
      FM_BACKEND_TERN_BLOCK=$(fm_backend_tern_block_for_label "$inv" "$FM_BACKEND_TERN_SESSION" "$expected_label") || return 0
      rec=$(fm_backend_tern_block_record "$inv" "$FM_BACKEND_TERN_BLOCK") || return 0
    fi
    IFS=$'\037' read -r session tab live <<EOF
$rec
EOF
    [ "$live" = dead ] || return 0
    if [ -n "$expected_label" ]; then
      [ "$tab" = "$expected_label" ] || return 0
      [ -z "$FM_BACKEND_TERN_SESSION" ] || [ "$session" = "$FM_BACKEND_TERN_SESSION" ] || return 0
    fi
  fi
  fm_backend_tern_cli close "$FM_BACKEND_TERN_BLOCK" >/dev/null 2>&1 && return 0
  inv=$(fm_backend_tern_inventory) || return 1
  if fm_backend_tern_block_record "$inv" "$FM_BACKEND_TERN_BLOCK" >/dev/null; then
    echo "error: tern refused to close block $FM_BACKEND_TERN_BLOCK and it is still listed" >&2
    return 1
  fi
  return 0
}

# fm_backend_tern_list_live: recovery/orphan discovery - every fm-* tab of
# this home's session, by NAME. One "tern:<session>/<block>\tfm-<id>" line
# each. Read-only; an unreachable Tern lists nothing.
fm_backend_tern_list_live() {
  local inv session
  session=$(fm_backend_tern_session_name)
  inv=$(fm_backend_tern_inventory) || return 0
  printf '%s' "$inv" | jq -r --arg s "$session" '
    .sessions[]? | select(.name == $s) | .tabs[]?
    | select((.name // "") | startswith("fm-")) | select(.blocks[0]?.id != null)
    | "tern:\($s)/\(.blocks[0].id)\t\(.name)"
  ' 2>/dev/null
}

# fm_backend_tern_agent_state: recovery-grade state (bin/fm-backend.sh's
# fm_backend_agent_state vocabulary). The block must appear in a successful
# inventory; its foreground process group, read from `tern process`, is
# classified by the shared process classifier: any verified harness is
# `alive`, nothing but shells is `dead`, anything else `ambiguous`. An exited
# kept-open block is `dead`. Tern's inventory covers only the window this
# process addresses, so `missing` is never upgraded to proven absence
# (bin/fm-control-lib.sh's fm_control_endpoint_absence_verdict).
fm_backend_tern_agent_state() {  # <target>
  local inv rec live proc fg_pid fg_name fg_argv0 group pid name args seen=0 shell=0 other=0 verdict
  fm_backend_tern_parse_target "$1" || { printf 'unreadable'; return 0; }
  inv=$(fm_backend_tern_inventory) || { printf 'unreadable'; return 0; }
  rec=$(fm_backend_tern_block_record "$inv" "$FM_BACKEND_TERN_BLOCK") || { printf 'missing'; return 0; }
  live=${rec##*$'\037'}
  [ "$live" = live ] || { printf 'dead'; return 0; }
  proc=$(fm_backend_tern_process_json "$FM_BACKEND_TERN_BLOCK") || { printf 'unreadable'; return 0; }
  IFS=$'\037' read -r fg_pid fg_name fg_argv0 group <<EOF
$(printf '%s' "$proc" | jq -r '[(.foreground.pid // ""), (.foreground.name // ""), (.foreground.argv[0]? // ""), (.group // "")] | map(tostring) | join("\u001f")' 2>/dev/null)
EOF
  [ -n "$fg_name" ] || { printf 'unreadable'; return 0; }
  args=$(LC_ALL=C ps -p "$fg_pid" -o args= 2>/dev/null) || args=
  verdict=$(fm_agent_process_classify "$fg_name" "$fg_argv0" "$args" "$fg_pid")
  [ "$verdict" != agent ] || { printf 'alive'; return 0; }
  # The rest of the foreground process group: a wrapper (`/bin/sh -c`, `env
  # -i`) can lead it while the harness runs as its child.
  case "$group" in ''|*[!0-9]*) group= ;; esac
  if [ -n "$group" ]; then
    while read -r pid name; do
      [ -n "$pid" ] || continue
      seen=1
      args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || args=
      case "$(fm_agent_process_classify "$name" "${args%%[[:space:]]*}" "$args" "$pid")" in
        agent) printf 'alive'; return 0 ;;
        shell) shell=1 ;;
        *) other=1 ;;
      esac
    done <<EOF
$(LC_ALL=C ps -A -o pid=,pgid=,comm= 2>/dev/null | awk -v g="$group" '$2 == g { pid = $1; $1 = ""; $2 = ""; sub(/^[[:space:]]+/, ""); print pid, $0 }')
EOF
  fi
  if [ "$seen" -eq 0 ]; then
    case "$verdict" in
      shell) printf 'dead' ;;
      *) printf 'ambiguous' ;;
    esac
    return 0
  fi
  if [ "$other" -eq 0 ] && [ "$shell" -eq 1 ]; then
    printf 'dead'
  else
    printf 'ambiguous'
  fi
}

# fm_backend_tern_state_file: where bin/backends/tern-plugin publishes agent
# state - <plugins dir>/../plugin-data/firstmate-agents/agents.json, resolved
# once per shell. FM_TERN_AGENT_STATE_FILE overrides it.
fm_backend_tern_state_file() {
  if [ -n "${FM_TERN_AGENT_STATE_FILE:-}" ]; then
    printf '%s' "$FM_TERN_AGENT_STATE_FILE"
    return 0
  fi
  if [ -z "${FM_BACKEND_TERN_STATE_FILE_CACHED:-}" ]; then
    local dir
    dir=$(fm_backend_tern_cli plugin dir 2>/dev/null) || return 1
    [ -n "$dir" ] || return 1
    FM_BACKEND_TERN_STATE_FILE_CACHED="$(dirname "$dir")/plugin-data/firstmate-agents/agents.json"
  fi
  printf '%s' "$FM_BACKEND_TERN_STATE_FILE_CACHED"
}

# fm_backend_tern_plugin_state: the plugin's agent state for <block>
# (working|idle|waiting_input|exited), or empty when the file is absent,
# unparseable, written by a window that is no longer a running tern process
# (closed window; an idle window rewrites nothing, so age proves nothing), or
# does not list the block as an agent. Empty always means "no native evidence".
fm_backend_tern_plugin_state() {  # <block>
  local file pid state comm
  file=$(fm_backend_tern_state_file) || return 0
  [ -f "$file" ] || return 0
  IFS=' ' read -r pid state <<EOF
$(jq -r --arg b "$1" '
    select(.version == 1 and (.window_pid | type) == "number")
    | "\(.window_pid) \(.blocks[$b].agent // "")"
  ' "$file" 2>/dev/null)
EOF
  [ -n "$pid" ] && [ -n "$state" ] || return 0
  comm=$(ps -p "$pid" -o comm= 2>/dev/null) || return 0
  [ "${comm##*/}" = tern ] || return 0
  printf '%s\n' "$state"
}

# fm_backend_tern_busy_state: busy|idle|unknown from Tern's own agent state
# (via the plugin). working is busy only while a verified harness process is
# in the foreground (a stale working flag over a shell is unknown, mirroring
# herdr); idle and waiting_input are idle (herdr maps blocked the same way);
# everything else - no plugin, stale file, exited, not an agent - is unknown,
# which callers answer with their harness-scoped capture fallback.
fm_backend_tern_busy_state() {  # <target>
  local state
  fm_backend_tern_target_ready "$1" || { printf 'unknown'; return 0; }
  state=$(fm_backend_tern_plugin_state "$FM_BACKEND_TERN_BLOCK")
  case "$state" in
    working)
      if [ "$(fm_backend_tern_agent_state "$1")" = alive ]; then
        printf 'busy'
      else
        printf 'unknown'
      fi
      ;;
    idle|waiting_input) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}
