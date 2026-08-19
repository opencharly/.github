# opencharly/.github — org-wide community-health defaults

This repository is GitHub's org-level source of **default community-health
files**. Any repository in the `opencharly` org that does **not** ship its own
copy inherits the files here — so a change lands **once**, not in every repo.

## What lives here

- **`.github/PULL_REQUEST_TEMPLATE.md`** — the OpenCharly PR template. It elicits
  the exact evidence the fresh `pr-validator` agent needs to verify CLAUDE.md
  compliance: the change-class R10 gate + pasted output, the `disposable: true`
  target, whether the changed code path ran live (which caps the attribution
  tier), the concurrent-roster evidence for shared-state changes, and a full
  R0–R10 + pillars "state HOW / N/A" checklist.
- **`scripts/branch-protection.sh`** — the single organization-wide owner of the
  required PR-validator status. It discovers every active, non-fork repository
  through GitHub, replaces the required context in one batch, and verifies the
  resulting protection without maintaining per-repository copies or lists.
- **`.github/workflows/pr-validator.yml`** — the org-wide `charly/pr-validator` gate.
  Replaces the prior agent-posted `charly/pr-validator` commit status. Runs the pi
  coding agent as a fresh, independent PR validator on every pull request, always posts
  a PR comment with the validation result, and gates the check (named `charly/pr-validator`,
  satisfying branch protection) on the returned `Verdict: PASS|BLOCK`. Fully generic —
  the LLM provider is configured at runtime from the GitHub environment (see below).
- **`.github/workflows/auto-merge.yml`** — the disposer half of the two-step landing.
  Runs when the `charly/pr-validator` gate completes **success** (PASS): re-verifies the
  green check on the exact head, mints the merge-time CalVer, finalizes the placeholder
  `CHANGELOG/<CalVer>.md`, squash-merges the validated head (never `--admin`), and
  creates the `v<VER>` tag. Fully generic and auditable in run logs.

Future org-wide defaults (issue templates, `CONTRIBUTING.md`, `SECURITY.md`,
reusable CI workflows via `uses: opencharly/.github/.github/workflows/…@main`)
belong here too — one source, inherited everywhere.

## The `charly/pr-validator` workflow — required org-level configuration

`.github/workflows/pr-validator.yml` runs on every non-fork pull request in the
org. Its job is named `charly/pr-validator`, so its check run satisfies the
branch-protection required context of that name. It is fully generic: nothing is
hardcoded. Set these as **org-level** variables and secrets (Settings → Secrets
and variables → Actions → New repository secret / New variable, at the org
level, with **visibility: all** so every repo inherits them):

| Name | Kind | Default | Purpose |
|---|---|---|---|
| `AI_REVIEW_PROVIDER` | variable | `openrouter` | LLM provider name |
| `AI_REVIEW_BASE_URL` | variable | `https://openrouter.ai/api/v1` | Provider base URL override (empty = built-in) |
| `AI_REVIEW_MODEL` | variable | `~deepseek/deepseek-v4-flash-latest` | Exact model ID in the provider's catalog |
| `AI_REVIEW_API_KEY` | secret | — | Provider API key (never committed) |

The workflow passes these straight to the pi coding agent action
(`shaftoe/pi-coding-agent-action`) as its native `provider` / `model` / `base_url` /
`token` inputs — pi resolves the model against its built-in provider catalog, sets the
API key via `setRuntimeApiKey()`, and overrides the endpoint via `registerProvider()`.
No `models.json` is written, so nothing is hardcoded. `provider` must be a built-in pi
provider and `model` its exact catalog ID. The API key is read only from the
`AI_REVIEW_API_KEY` secret — it is never stored in this repository. The action is pinned
to an exact release; bump it deliberately.

## The two-phase pipeline (gate → merge/tag)

The two workflows form one validation → disposal pipeline for every germain PR:

1. **`pr-validator.yml`** runs on every non-fork pull request. It posts the
   `charly/pr-validator` check run (the branch-protection required context) and a single
   verdict comment, then gates on the returned `Verdict: PASS|BLOCK`.
2. **`auto-merge.yml`** is triggered by the gate's **success** completion. It re-verifies
   that the `charly/pr-validator` check on the PR head is green, mints a free merge-time
   CalVer `v<YYYY.DDD.HHMM>`, finalizes the placeholder `CHANGELOG/<CalVer>.md` on the PR
   branch, squash-merges the validated head (never `--admin`), and creates the `v<VER>`
   tag on the merged commit. If the gate is not yet green it exits quietly and the next
   successful validator run finishes the merge — the state machine is idempotent and
   loop-free.

Security hardening of `auto-merge.yml` (least-privilege PAT scoping, verdict integrity,
per-repo sdk CalVer form, per-branch queue lock) is a tracked follow-up; the first cut
prefers API-based merges that still require a green `charly/pr-validator` check on the
exact head being merged, and never merges `--admin` or force-pushes.

## Authority vs. convenience

The **authority** for what a PR must contain is the active harness root rulebook + the
`/charly-internals:git-workflow` and `pr-validator` skills (the 0–18 checklist).
This template is the GitHub-UI mirror of that — it does not restate the rules,
it prompts the author to supply the evidence for them.

Per-repo `.github/pull_request_template.md` copies are removed so every repo
falls through to this single source (see each repo's `CHANGELOG/`).
