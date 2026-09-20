// OMP's native task executor appends session_init before session_start.
// A parentSession header is not a child discriminator: top-level forks have it too.
export function isOmpSubagentContext(ctx: {
  sessionManager?: { getEntries?: () => readonly { type?: string }[] };
} | undefined): boolean {
  return ctx?.sessionManager?.getEntries?.().some((entry) => entry.type === "session_init") === true;
}
