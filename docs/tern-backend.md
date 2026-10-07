# Tern runtime backend

Tern is Stencil's multiplexing terminal, and Firstmate's experimental `tern` backend runs each task in a tab of it.
Tern provides task sessions, tabs, and blocks while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick Tern when it is already your terminal and you want each task as a tab in its vertical tab bar.
Tern needs its app running with a window open: the `tern` CLI drives the per-user session daemon, and `tern send` only delivers while a window is attached.

Prerequisites:

- Tern 0.4 or newer from [docs.stencil.so/tern](https://docs.stencil.so/tern/).
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

The adapter prefers `command -v tern` and otherwise uses `/Applications/Tern.app/Contents/MacOS/tern`.
Select it with `config/backend` containing `tern`, `FM_BACKEND=tern`, or a per-task `--backend tern`.

### Agent-state plugin

`bin/backends/tern-plugin/` is a small window-side Tern plugin, `firstmate-agents`.
Link it once from the Firstmate checkout and confirm it loaded:

```sh
tern plugin link bin/backends/tern-plugin
tern plugin list   # firstmate-agents ... window  ready
```

The plugin is optional: without it every backend operation still works, and busy state falls back to each harness's own lifecycle record and capture heuristics.
With it:

- it publishes Tern's agent state for every pane to `<plugins dir>/../plugin-data/firstmate-agents/agents.json` (on macOS `~/Library/Application Support/Tern/plugin-data/firstmate-agents/agents.json`), rewritten atomically on every change and stamped with the pid of the window that wrote it;
- it colors every `fm-*` task tab: blue while working, green when idle, orange when the agent waits for input or holds an unseen alert, red when it exited;
- it adds a status-line segment counting working, idle, and waiting agents, and clicking it focuses the first agent that needs you.

`FM_TERN_AGENT_STATE_FILE` overrides where the adapter reads that file.
Tern runs a window plugin's timers only while the window is awake (pane output, input), so an idle window rewrites nothing and the file's age proves nothing.
The adapter therefore treats the file as absent unless its `window_pid` is still a running `tern` process, so a closed window never reads as a live verdict; a plugin unloaded from a window that stays open leaves its last file in place until that window closes.

### Autostart

`bin/fm-tern-autostart.sh` is the Tern counterpart of a Herdr login launcher.
It waits for Tern, then leaves one `First Mate` session holding a `First Mate` tab running the omp primary at the Firstmate workspace and, when `quota-axi` is installed, a `Quota` tab running `quota-axi --tui --refresh 1m`.
It is idempotent: a primary already running at the workspace in any session is adopted, and an existing Quota tab is kept.
Its header owns the flags and environment overrides, and it logs to `~/Library/Logs/fm-tern-autostart.log` on macOS.

The script installs nothing.
To start Firstmate at login, install a LaunchAgent yourself, for example `~/Library/LaunchAgents/com.firstmate.tern-login.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.firstmate.tern-login</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-lc</string>
    <string>exec "$HOME/firstmate/bin/fm-tern-autostart.sh" --open</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

Replace `$HOME/firstmate` with the Firstmate checkout, load it with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.firstmate.tern-login.plist`, and remove any older login item that starts a different terminal's primary so only one primary runs.
`--open` launches Tern when its daemon is not reachable yet; the login shell (`-l`) supplies the `PATH` that finds `tern`, `jq`, `omp`, and `quota-axi`.

## Runtime detection

Tern injects `TERN_PANE` (the pane's block id) and `TERM_PROGRAM=tern` into every pane it starts.
Detection selects Tern only when both are present, after tmux and Herdr and before cmux, so a multiplexer nested inside Tern remains the active backend and a terminal started from a Tern pane does not inherit the claim.
Auto-detected Tern prints a one-line stderr notice because the backend is experimental.
The away-mode daemon's supervisor-pane discovery follows the same order and composes the unscoped `tern:/<TERN_PANE>` target.

## Task shape and metadata

Each Firstmate home owns one Tern session named by the shared home tag, `firstmate-<hash>` or `2ndmate-<id>-<hash>`, from `bin/fm-backend-hometag-lib.sh`.
`FM_TERN_SESSION` overrides that name.
Tern enforces unique session names, so the session scopes task tab names to one home and one installation.
The first task of a home creates the session and its first tab becomes that task's tab; later tasks add tabs.
Each task tab is named with the caller-facing `fm-<id>` label.
Neither creation shows the session nor moves focus; a task tab appears in the tab bar once you open that session.

```text
backend=tern
window=tern:<session>/<block-id>
tern_session=<session>
tern_block_id=<block-id>
```

The literal `tern:` prefix and the `/` keep the target from reading as a tmux `session:window` or a Herdr `session:wX:pY` in `fm-send.sh`'s explicit-target heuristic.
Operations verify that the recorded block still sits in a tab named `fm-<id>` in the recorded session; when the block is gone, the label recovers the task's current block, and a block now in another task's tab is never touched.

## Native rendering

omp and pi detect Tern and draw natively through Tern's surface protocol.
Their composer then never reaches `tern capture`, not even with `--surfaces`, which returns only the transcript region, so every composer guard and submit acknowledgement would read `unknown`.
`fm-spawn.sh` therefore exports `PI_TUI_NATIVE=0` into each Tern task pane before launch, and the launch environment floor forwards it, so workers draw an ordinary terminal UI the shared classifier reads.
Other harnesses ignore the variable.
The primary started by `bin/fm-tern-autostart.sh` keeps native rendering.

## Current operation and safety

Literal text goes through `tern send <block> text -- <text>`, and named keys through `tern send <block> keys`, with Enter, Escape, `ctrl+c`, and `ctrl+u` supported.
`tern capture` without `--scrollback` is the viewport only, which makes Tern a viewport-capture backend; ordinary captures add `--scrollback` and trim locally, and composer reads use `--ansi` so ghost text can be stripped.
`tern process <block> --json` reports the foreground process with a live working directory, so worktree discovery needs no `pwd` probe.

Recovery-grade agent state is process-level: the block must appear in a readable `tern ls --json`, and the foreground process group from `tern process` is classified by `bin/fm-agent-process-lib.sh`.
Busy state reads the plugin's file: `working` with a live harness process is busy, `idle` and `waiting_input` are idle, and everything else is unknown.
Tern only lists a pane as an agent while a typed command line names the harness, so workers launched through Firstmate's launch file usually read unknown and the harness lifecycle record stays the busy authority.

`tern close` ends the program without confirmation.
A task already gone, or whose block now belongs to another tab, is a quiet success; a refused close with the block still listed, or an unreadable inventory, is a failure that keeps the task's records.
A session whose last task tab closed stays as an empty session; Firstmate does not remove it because a concurrent spawn may be adding a tab.

Real tests act on the captain's running Tern: `tests/fm-backend-tern-smoke.test.sh` creates one unshown `zz-fm-smoke-<pid>` session and kills only that session.

## Active limits

- Tern is experimental and needs the app with a window open; the backend never launches or quits it.
- Tern commands act on one window's sessions (`--window`, `$TERN_WINDOW_KEY`, else the first window), so with several windows a task moved to another window reads `missing`, and absence is never treated as proven for relaunch.
- Secondmate spawns are unsupported until a per-home lifecycle on Tern is verified.
- There is no push-event stream; the watcher polls.
- Native agent state reaches Firstmate only through the plugin, and only for panes Tern lists as agents.
- The away-mode daemon accepts a Tern supervisor pane, but a natively rendering primary's composer reads `unknown`, so the daemon never injects into it; the omp primary uses its own supervision session instead.
- The wedge alarm has no Tern-specific channel; the default `auto` channel uses macOS Notification Center.
- Tern has no Linux build for aarch64 yet, so the backend is verified on macOS only.

## Regression entry points

```sh
tests/fm-backend-tern.test.sh
tests/fm-backend-tern-smoke.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#tern) records the active live evidence.
