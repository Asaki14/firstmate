--!strict
-- firstmate-agents: the window half of Firstmate's Tern companion plugin
-- (docs/tern-backend.md "Agent-state plugin").
--
-- Tern exposes agent progress (idle/working/waiting_input/exited, from the
-- program's OSC 9;4 progress reports) and pane busy/alert flags only to
-- window-side Luau, never to the `tern` CLI. This half publishes them for
-- bin/backends/tern.sh:
--
--   <tern.plugin.data>/agents.json
--   {"version":1,"window_pid":<pid>,"blocks":{"<block id>":{...}}}
--
-- written to a temporary file and renamed into place on every change. Tern
-- runs window timers only while the window is awake (pane output, input), so
-- an idle window rewrites nothing and the file's age says nothing about its
-- truth; the reader instead trusts it only while window_pid, the window that
-- wrote it, is still a running tern process. Each block
-- entry carries `agent` (Tern's agent state, absent for a pane that is not an
-- agent), `shown` (the tab-bar state below), `busy`, `at_prompt`, `alert`,
-- `exited`, `tab`, `tab_name` and `session`.
--
-- It also colors Firstmate task tabs (tabs named `fm-*`) and adds a
-- status-line segment counting agents, so Tern's vertical tab bar reads like
-- Herdr's agent sidebar. The shown state is Tern's agent state, raised to
-- "needs you" while the pane holds an unseen alert (a harness's turn-end
-- notification). Firstmate launches omp/pi workers with PI_TUI_NATIVE=0,
-- which Tern does not list as agents once their first turn starts, so for
-- those task tabs the alert is the signal that remains.

local POLL_MS = 1000
local STATE_PATH = tern.plugin.data .. "/agents.json"
local TMP_PATH = STATE_PATH .. ".tmp"

local COLORS: { [string]: TabColor } = {
	working = "blue",
	waiting_input = "orange",
	idle = "green",
	exited = "red",
}

local last_signature = ""
local window_pid: number? = nil
local pid_pending = false
local moving = false
local tab_colors: { [number]: string } = {}
local counts = { working = 0, idle = 0, waiting = 0 }
local first_waiting: number? = nil
local started = false

local function flag(v: any): string
	if v == nil then
		return "-"
	end
	return tostring(v)
end

-- The state a pane shows in the tab bar and the status counts: Tern's agent
-- state, with an unseen alert raising anything but active work to
-- waiting_input ("needs you"). Panes that are neither agents nor in a task
-- tab show nothing.
local function shown_state(a: AgentBlock?, p: PaneInfo, task_tab: boolean): string?
	local state = if a then a.state else nil
	if p.alert and state ~= "working" and state ~= "exited" and (a ~= nil or task_tab) then
		return "waiting_input"
	end
	return state
end

local function is_task_tab(t: TabInfo?): boolean
	return t ~= nil and t.name ~= nil and string.sub(t.name, 1, 3) == "fm-"
end

-- One pass over the window: build the published document, recolor task tabs
-- and recount agents. Kept small: it runs on the UI thread under the 50 ms
-- window budget once a second.
local function scan(cx: WindowCx)
	local agents: { [number]: AgentBlock } = {}
	for _, a in cx.agents:list() do
		agents[a.pane] = a
	end

	local session_names: { [number]: string } = {}
	for _, s in cx.session:sessions() do
		session_names[s.id] = s.name
	end
	local tabs: { [number]: TabInfo } = {}
	for _, t in cx.session:tabs() do
		tabs[t.id] = t
	end

	local n_working, n_idle, n_waiting = 0, 0, 0
	local waiting_pane: number? = nil
	local shown: { [number]: string } = {}
	local blocks: { [string]: any } = {}
	local keys: { string } = {}
	for _, p in cx.session:panes() do
		local a = agents[p.pane]
		local t = if p.tab then tabs[p.tab] else nil
		local state = shown_state(a, p, is_task_tab(t))
		if state ~= nil then
			shown[p.pane] = state
			if state == "working" then
				n_working += 1
			elseif state == "idle" then
				n_idle += 1
			elseif state == "waiting_input" then
				n_waiting += 1
				if waiting_pane == nil then
					waiting_pane = p.pane
				end
			end
		end
		local key = tostring(p.pane)
		blocks[key] = {
			agent = if a then a.state else nil,
			shown = state,
			busy = p.busy,
			at_prompt = p.at_prompt,
			alert = p.alert,
			exited = p.exited,
			tab = p.tab,
			tab_name = if t then t.name else nil,
			session = if t then session_names[t.session] else nil,
		}
		table.insert(keys, key .. "=" .. flag(a and a.state) .. "," .. flag(p.busy) .. "," .. flag(p.at_prompt)
			.. "," .. flag(p.alert) .. "," .. flag(p.exited) .. "," .. flag(t and t.name))
	end
	table.sort(keys)

	-- Task tabs: color by the focused block's shown state; touch only tabs
	-- named fm-* and only when the wanted color changed.
	for id, t in tabs do
		if is_task_tab(t) then
			local state = shown[t.pane]
			local want = if state then COLORS[state] else nil
			local key = want or ""
			if tab_colors[id] ~= key then
				tab_colors[id] = key
				cx.layout:color_tab(id, want)
			end
		end
	end

	if n_working ~= counts.working or n_idle ~= counts.idle or n_waiting ~= counts.waiting then
		counts = { working = n_working, idle = n_idle, waiting = n_waiting }
		tern.chrome.refresh()
	end
	first_waiting = waiting_pane

	local signature = table.concat(keys, ";")
	if moving or window_pid == nil or signature == last_signature then
		return
	end
	local body = tern.json.encode({ version = 1, window_pid = window_pid, blocks = blocks })
	local ok, err = pcall(tern.fs.write, TMP_PATH, body)
	if not ok then
		tern.log.warn("firstmate-agents: write failed", err)
		return
	end
	moving = true
	tern.process.run({ "/bin/mv", "-f", TMP_PATH, STATE_PATH }, { timeout_ms = 5000 }, function(result, _cx)
		moving = false
		if result.status == 0 then
			last_signature = signature
		else
			tern.log.warn("firstmate-agents: rename failed", result.stderr)
		end
	end)
end

-- A child's parent is this window process: the pid the reader checks.
-- Looked up from the poll, not at load, which has its own tight budget.
local function find_window_pid()
	pid_pending = true
	tern.process.run({ "/bin/sh", "-c", "echo $PPID" }, { timeout_ms = 5000 }, function(result, _cx)
		pid_pending = false
		local pid = tonumber((string.gsub(result.stdout, "%s", "")))
		if result.status == 0 and pid ~= nil then
			window_pid = pid
		else
			tern.log.warn("firstmate-agents: window pid unknown", result.stderr)
		end
	end)
end

local function tick(cx: WindowCx?)
	tern.timer(POLL_MS, tick)
	if window_pid == nil and not pid_pending then
		local ok, err = pcall(find_window_pid)
		if not ok then
			pid_pending = false
			tern.log.warn("firstmate-agents: window pid lookup failed", err)
		end
	end
	if cx ~= nil then
		local ok, err = pcall(scan, cx)
		if not ok then
			tern.log.warn("firstmate-agents: scan failed", err)
		end
	end
end

local function start()
	if started then
		return
	end
	started = true
	tern.timer(POLL_MS, tick)
end

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local total = counts.working + counts.idle + counts.waiting
	if total == 0 then
		return nil
	end
	local parts = {}
	if counts.working > 0 then
		table.insert(parts, tostring(counts.working) .. " working")
	end
	if counts.idle > 0 then
		table.insert(parts, tostring(counts.idle) .. " idle")
	end
	if counts.waiting > 0 then
		table.insert(parts, tostring(counts.waiting) .. " need you")
	end
	local tone = if counts.waiting > 0 then "warn" elseif counts.working > 0 then "accent" else "muted"
	return {
		{
			text = "agents " .. table.concat(parts, " · "),
			icon = "sparkle",
			tone = tone,
			command = "plugin.firstmate-agents.focus-waiting",
		},
	}
end)

tern.command({
	id = "focus-waiting",
	title = "Focus the agent that needs you",
	run = function(cx: WindowCx)
		if first_waiting == nil then
			cx:toast("info", "No agent is waiting for input")
			return
		end
		cx.layout:focus(first_waiting)
	end,
})

tern.on("window_start", function(_cx: WindowCx)
	start()
end)

-- A reload replaces this VM without running window_start again in a window
-- that already ran it, so the poll also starts at load.
start()
