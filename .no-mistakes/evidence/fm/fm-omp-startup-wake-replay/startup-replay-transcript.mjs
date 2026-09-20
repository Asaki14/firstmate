// Startup transcript: how many "FIRSTMATE_OP: v1 watcher" messages main receives at
// session_start when the replacement handoff holds 24 stale records whose results
// were already acknowledged (.handled) plus 3 genuinely unconsumed ones.
import { pathToFileURL } from "node:url";
import { mkdirSync, writeFileSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
const handoff = `${state}/extensions/omp-primary-watch/session-replacement-actionable.json`;
mkdirSync(`${state}/extensions/omp-primary-watch`, { recursive: true });
mkdirSync(`${state}/procevent-inbox`, { recursive: true });
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const pending = [];
for (let i = 1; i <= 24; i++) {
  pending.push({ version: 1, token: `1-1-${i}`, message: `check: process-event result captured: procevent:pr-${i}:1`, predecessorArmPid: "" });
  writeFileSync(`${state}/procevent-inbox/pr-${i}.1.handled`, "");
}
pending.push({ version: 1, token: "1-1-25", message: "check: process-event result captured: procevent:fresh:1", predecessorArmPid: "" });
pending.push({ version: 1, token: "1-1-26", message: "check: process-event result captured: procevent:batch:1 procevent:batch:2", predecessorArmPid: "" });
pending.push({ version: 1, token: "1-1-27", message: "check: process-event source stranded: procevent:worker:1", predecessorArmPid: "" });
writeFileSync(handoff, JSON.stringify({ version: 2, pending }));
const mod = await import(pathToFileURL(process.env.EXT).href);
const handlers = new Map(), sent = [];
mod.default({ on(e, h) { handlers.set(e, h); }, registerTool() {}, registerCommand() {}, sendUserMessage(m) { sent.push(m); } });
await handlers.get("session_start")({}, {});
await new Promise((r) => setTimeout(r, 1500));
console.log(`extension: ${process.env.LABEL}`);
console.log(`handoff records at startup: ${pending.length} (24 already acknowledged via .handled, 3 unconsumed)`);
console.log(`v1 watcher messages injected into main at session_start: ${sent.length}`);
for (const m of sent) console.log(`  - ${m.split("\n")[0].replace(/^⁣/, "")}`);
await handlers.get("session_shutdown")({}, {});
process.exit(0);
