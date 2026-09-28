#!/usr/bin/env python3
"""_strip-filter.py — the MINIMAL-DIFF, parser-safe line filter for the
schema-versioning-removal cutover's authored `version:` stamp.

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

  * indent 0            — the document stamp (the large majority)
                                                            -> DELETE
  * indent 8            — an entity-body stamp, under `name:` ->
                          `candy:`/`box:`/`deploy:`          -> DELETE
  * indent 4            — the same entity-body stamp in the two
                          2-space manifests (action-review,
                          eval-charly)                       -> DELETE
  * indent 16 or more   — a `version:` line inside a `description: |`
                          block scalar (a fenced YAML example in
                          prose)                             -> PRESERVE
                          (deleting it would corrupt the documentation.
                          Real: layer-charly-hermes's
                          `                version: 2026.156.1921   # mandatory CalVer`
                          inside a ```yaml block MUST survive.)

Any other indent (12/18/20/26…) is inside a block scalar: PRESERVED.

The rule the code enforces is a single regex: a line whose content matches
`^ {0,8}version:` — an indent of 0..8, then `version:`, optionally followed by a
trailing `  # comment`. Nothing else in the file changes.

DEFENSIVE YAML-AWARE GUARD. On top of the indent rule (which already excludes
block-scalar bodies) the filter tracks block-scalar context: it refuses to delete
a matched line whenever the innermost open `key: |` / `key: >` block scalar could
contain it. A refusal is a hard, LOUD failure (exit 3, nothing written) rather
than a silent skip, so a manifest shape the indent rule did not anticipate can
never be silently mis-stripped — the repo is counted `failed` and the wave
continues.

Exit codes: 0 = filtered (see the stderr report), 4 = input does not decode as
UTF-8.
"""

import re
import sys

# A strippable stamp: indent 0..8, `version:`, and optionally a trailing comment.
DELETE_RE = re.compile(r"^ {0,8}version:")
# A block-scalar opener: a key ending in `: |`/`: >` (with optional chomping /
# indentation indicator and a trailing comment), not itself a comment line.
OPENER_RE = re.compile(r"^[ ]*[^\s#][^:]*:[ ]*[|>][+-]?[0-9]*[ ]*(?:#.*)?$")


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

    for line in lines:
        body = line.rstrip("\n").rstrip("\r")
        indent = len(body) - len(body.lstrip(" "))

        if block_indent is not None:
            # Blank lines and lines deeper than the scalar's key stay inside it.
            if body.strip() == "" or indent > block_indent:
                if DELETE_RE.match(body):
                    # The indent rule says a stamp only ever lives at 0..8, so a
                    # matched line this deep should be impossible — refuse loudly.
                    sys.stderr.write("REFUSED: matched stamp inside block scalar\n")
                    return 3
                out.append(line)
                continue
            block_indent = None  # the scalar ended; fall through and process this line

        if DELETE_RE.match(body):
            removed += 1
            continue
        if OPENER_RE.match(body):
            block_indent = indent
        out.append(line)

    sys.stdout.write("".join(out))
    if removed:
        sys.stderr.write("STRIPPED %d\n" % removed)
    else:
        sys.stderr.write("ABSENT\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
