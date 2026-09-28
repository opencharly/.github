#!/usr/bin/env python3
"""_strip-filter.py — the MINIMAL-DIFF, parser-safe line filter for the
schema-versioning-removal cutover's retired authored `version:` stamp.

Reads a charly.yml on stdin, writes the stripped file on stdout, and prints a
ONE-line report on stderr (so the calling shell can tell whether anything was
removed without a second pass):

    STRIPPED <n>     # n >= 1 lines deleted (the caller PUTs the stdout)
    ABSENT           # nothing to strip — the caller must NOT write

WHY NOT `charly migrate`. The host leg of the removal (opencharly/charly#716) is
NOT landed, so no RELEASED charly accepts or needs the strip — and `charly
migrate` rewrites the WHOLE file to canonical form. Measured on the corpus: that
is ~100 cosmetic lines of churn per file, including trailing-whitespace changes
INSIDE `description:` block scalars. Across ~400 repos that is an unreviewable,
unnecessary diff. This filter touches ONLY the lines it deletes; the rest of the
file is byte-identical.

EXACT SEMANTICS (measured over the org TARGET set — the 423 active, non-fork,
`main`-default repos `discover_repos` enumerates — on 2026-09-28): 402 carry a
`charly.yml`; **394 would be STRIPPED**; 2 more carry ONLY a preserved code-block
example; 21 have no `charly.yml`. Equivalently, **396 repos carry at least one
`version:` line on `main`** (394 stripped + 2 preserved-only), while 6 carry a
`charly.yml` with no `version:` line at all. The node-form manifest grammar is
closed, so the indentation is stable — but the corpus is being stripped
CONCURRENTLY, so the count is a point-in-time snapshot.

THE PREDICATE IS STRUCTURAL, NOT A BARE INDENT (R1 fix, 2026-09-28). The stamp is
deleted ONLY when the `version:` line is either:

  * the DOCUMENT stamp — indent 0, the file's first `version:` key; or
  * a DIRECT child of a `candy:` / `box:` / `deploy:` entity body — the
    per-ENTITY stamp the retired schema carried under the kind discriminator.

Every OTHER `version:` is PRESERVED, whatever its indent. This is faithful to the
retired schema (the removed stamp lived on the DOCUMENT and the candy/box/deploy
ENTITY), to `charly migrate`'s canonical predicate (plugin-migrate#12's
`stripVersionField` removes the top-level stamp; `stripEntityVersionKey` removes a
DIRECT `version:` child of a `candy`/`box`/`deploy` body — never a deeper one), and
to the v1 filter's own documented intent. It matters because a bare indent match
would also delete a LIVE `version:` field that happens to sit at indent 4/8 — e.g.
`alpine:`/`debian:`/`fedora:`/`ubuntu:` -> `distro:` -> `version:` in
`charly/charly.yml`, the binary's `go:embed`-ed DEFAULT build vocabulary. Those are
`#Distro.version` (a live `schema/distro.cue` field; charly's own
`distro_cascade_test.go` asserts `debian version=13`, `ubuntu version=24.04`,
`fedora version=43`), and the host leg charly#716 (auto-closed; its successor carries it forward) deleted ONLY that file's
line-1 stamp, leaving the four distro versions intact.

  * indent 0, a `version:` key                     -> DELETE (document stamp)
  * a direct child of `candy:`/`box:`/`deploy:`    -> DELETE (entity stamp;
                            indent 8 in the 4-space manifests, indent 4 in the two
                            2-space manifests action-review / eval-charly)
  * any other `version:` (e.g. under `distro:`)    -> PRESERVE (a live field)

  * indent 16 or more   — a `version:` line inside a `description: |`
                          block scalar (a fenced YAML example in
                          prose)                             -> PRESERVE
                          (deleting it would corrupt the documentation.
                          Real: layer-charly-hermes's
                          `                version: 2026.156.1921   # mandatory CalVer`
                          inside a ```yaml block MUST survive.)

DEFENSIVE YAML-AWARE GUARD. On top of the structural rule the filter tracks
block-scalar context: it refuses to delete a matched line whenever the innermost
open `key: |` / `key: >` block scalar could contain it. A refusal is a hard, LOUD
failure (exit 3, nothing written) rather than a silent skip, so a manifest shape
the predicate did not anticipate can never be silently mis-stripped — the repo is
counted `failed` and the wave continues.

Exit codes: 0 = filtered (see the stderr report), 4 = input does not decode as
UTF-8.
"""

import re
import sys

# A stamp candidate: indent 0..8, `version:`, and optionally a trailing comment.
DELETE_RE = re.compile(r"^ {0,8}version:")
# A mapping key line: indent, then a key that is neither a comment (`#`) nor a
# sequence item (`-`), terminated by `:` + (space | end). Values are ignored.
KEY_RE = re.compile(r"^([ ]*)([^ \t#\-][^:]*?):(?:[ \t]|$)")
# A block-scalar opener: a key ending in `: |`/`: >` (with optional chomping /
# indentation indicator and a trailing comment), not itself a comment line.
OPENER_RE = re.compile(r"^[ ]*[^\s#][^:]*:[ ]*[|>][+-]?[0-9]*[ ]*(?:#.*)?$")
# The entity kinds whose DIRECT `version:` child is the retired per-entity stamp.
DELETABLE_PARENTS = frozenset(("candy", "box", "deploy"))


def main() -> int:
    data = sys.stdin.buffer.read()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        sys.stderr.write("NOT_UTF8\n")
        return 4

    lines = text.splitlines(keepends=True)
    out = []
    removed = 0
    block_indent = None  # content indent of the innermost open block scalar
    key_stack = []       # (indent, key) for the open mapping keys

    for line in lines:
        body = line.rstrip("\n").rstrip("\r")
        indent = len(body) - len(body.lstrip(" "))

        if block_indent is not None:
            # Blank lines and lines deeper than the scalar's key stay inside it.
            if body.strip() == "" or indent > block_indent:
                if DELETE_RE.match(body):
                    # A stamp candidate this deep should be impossible under the
                    # structural rule — refuse loudly rather than silently strip.
                    sys.stderr.write("REFUSED: matched stamp inside block scalar\n")
                    return 3
                out.append(line)
                continue
            block_indent = None  # the scalar ended; fall through and process this line

        key_m = KEY_RE.match(body)
        if key_m:
            k_indent = len(key_m.group(1))
            key = key_m.group(2).strip()
            # Close every key at this indent or deeper; the remaining top of the
            # stack is this key's immediate parent.
            while key_stack and key_stack[-1][0] >= k_indent:
                key_stack.pop()
            if DELETE_RE.match(body):
                is_document_stamp = k_indent == 0
                is_entity_stamp = bool(key_stack) and key_stack[-1][1] in DELETABLE_PARENTS
                if is_document_stamp or is_entity_stamp:
                    removed += 1
                    continue
            key_stack.append((k_indent, key))
            if OPENER_RE.match(body):
                block_indent = k_indent
            out.append(line)
            continue

        # Not a mapping key (a list item, a plain scalar, …) — a bare `version:`
        # here is a document-level stamp only at indent 0.
        if DELETE_RE.match(body) and indent == 0:
            removed += 1
            continue
        out.append(line)

    sys.stdout.write("".join(out))
    if removed:
        sys.stderr.write("STRIPPED %d\n" % removed)
    else:
        sys.stderr.write("ABSENT\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
