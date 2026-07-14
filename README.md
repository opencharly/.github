# opencharly/.github — org-wide community-health defaults

This repository is GitHub's org-level source of **default community-health
files**. Any repository in the `opencharly` org that does **not** ship its own
copy inherits the files here — so a change lands **once**, not in every repo.

## What lives here

- **`.github/PULL_REQUEST_TEMPLATE.md`** — the OpenCharly PR template. It elicits
  the exact evidence the fresh `pr-validator` agent needs to verify CLAUDE.md
  compliance: the change-class R10 gate + pasted output, the `disposable: true`
  target, whether the changed code path ran live (which caps the attribution
  tier), the concurrent-roster evidence for shared-state changes, a model-aware
  authorship/validation table, and a full R0–R10 + pillars "state HOW / N/A"
  checklist. Review-only AI is PR disclosure; a 100% human-authored commit is
  accepted without an AI trailer.

Future org-wide defaults (issue templates, `CONTRIBUTING.md`, `SECURITY.md`,
reusable CI workflows via `uses: opencharly/.github/.github/workflows/…@main`)
belong here too — one source, inherited everywhere.

## Authority vs. convenience

The **authority** for what a PR must contain is CLAUDE.md + the
`/charly-internals:git-workflow` and `pr-validator` skills (the 0–18 checklist).
This template is the GitHub-UI mirror of that — it does not restate the rules,
it prompts the author to supply the evidence for them.

Per-repo `.github/pull_request_template.md` copies are removed so every repo
falls through to this single source (see each repo's `CHANGELOG/`).
