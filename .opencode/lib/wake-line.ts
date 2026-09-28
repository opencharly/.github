/**
 * wake-line.ts — the ONE "last non-empty stdout line" helper shared by the
 * coordination plugins (`coord.ts`, `pr-watch.ts`).
 *
 * It lives in `.opencode/lib/` (NOT `.opencode/plugins/`) so opencode's plugin
 * discovery, which loads `plugins/*.{ts,js}` as plugins, never treats this module
 * as a plugin — it is a plain import target (R3: one implementation, not two).
 */

/** Return the last non-empty (trimmed) line of `stdout`, or undefined. */
export function wakeLine(stdout: string): string | undefined {
  return stdout
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean)
    .pop();
}
