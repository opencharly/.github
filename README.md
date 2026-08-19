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
  Supersedes the prior agent-posted `charly/pr-validator` commit status. The upstream
  cut-over that removes the agent-side posting is OPEN (`opencharly/charly` #349 candy
  source, `opencharly/plugins` #213 projections) and lands before this PR (landing
  order: plugins → charly → this), so there is never a dual writer to the
  branch-protection-required `charly/pr-validator` context. Runs the pi
  coding agent as a fresh, independent PR validator on every pull request, always posts
  a PR comment with the validation result, and gates the check (named `charly/pr-validator`,
  satisfying branch protection) on the returned `Verdict: PASS|BLOCK`. Fully generic —
  the LLM provider is configured at runtime from the GitHub environment (see below).
  The merge/tag disposer (`auto-merge.yml`) lands in the immediately-following PR and is
  installed + validated **by this very gate** (dogfooding), so the gate first proves
  itself on the gate-only install before it is given autonomous merge authority.

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

Glossary (for a cold reader):
- **pi** — the coding agent that the action wraps; it exposes providers/models/API-keys
  to cloud CLI tools (docs: `docs/models.md`).
- **provider / model / base_url / token** — the action's inputs: which LLM backend
  (`provider`), that backend's exact model ID (`model`), its API endpoint override
  (`base_url`), and its credential (`token`, from the `AI_REVIEW_API_KEY` secret).
- **`~` model-prefix** — pi's convention: `~<provider>/<id>` selects provider + model in
  one string; the `provider` input is then the fallback the model ID implies.
- **`setRuntimeApiKey()` / `registerProvider()`** — pi runtime functions the action
  calls to inject the API key and endpoint override for the chosen provider.
- **CalVer `v<YYYY.DDD.HHMM>`** — the merge-time release tag (year, day-of-year, HH:MM)
  the auto-merge disposer mints; not the schema `version:`.
- **`charly/pr-validator`** — the branch-protection-required check context; the gate's
  check run satisfies it (previously an agent-posted commit status of the same name).
- **`--admin`** — the flag that bypasses branch protection; the pipeline never uses it.
- **dogfooding** — using the gate itself to install and validate its own successor PR (the
  auto-merge disposer), so the mechanism proves itself on the gate-only install before it is
  given autonomous merge authority.


## Scope & evidence baseline (honest capability statement)

This gate is a **diff + thread + CI-status + re-run review**. The pi validator runs with
`get_pr_diff`, `get_issue_or_pr_thread`, `get_ci_status`, `get_workflow_run_logs` **plus a
real `bash` shell over the checked-out repo** (`read`/`find`/`grep` included). It genuinely
re-executes what the runner can execute at the PR head: repository greps per submodule,
YAML/JSON validation, file reads, generator regeneration checks (`cue:gen`,
`marketplace generate`, `docs generate`) and lint/vet/test runs where the toolchains exist
in the runner. It never trusts an author's claim it can verify itself.

What it **cannot** re-execute is external bed infrastructure: the `charly` binary is not
installed in the runner, there is no disposable target, and no live VM/container/lab
environment. For runtime-bed claims (`charly check run <bed>`, live probes), the gate
*does* re-validate the author's pasted output for existence, plausibility, internal
consistency, and class-gate fit, and it states the explicit tool-limited disposition
("could not re-run from this environment") — it never fabricates a run and never lets a
missing re-run pass on the author's word alone.

Consequence for evidence trust on **runtime-class** claims (beds, live probes): the gate
validates the pasted artifact and requires full internal consistency, but the authoritative
deep independent re-execution remains the job of the full shell-enabled fresh-evaluator
agent in the `charly` repo (its `pr-validator.md`), which this gate complements as the
org-wide first line. Authors must therefore paste complete, self-consistent, fraud-free
evidence for anything this runner cannot re-run; the gate's cross-check is a real
re-validation but not a substitute for a live bed re-run. This is the org's expected
baseline for runtime-class PRs reviewed by this gate — no more is overclaimed.

## The validation → disposal pipeline

The gate (this PR) is the validator; the auto-merge disposer lands as the separate next
PR and is itself installed and validated by this gate. Landing order:

1. **This PR installs `pr-validator.yml`** — runs on every non-fork pull request, posts
   the `charly/pr-validator` check run (the branch-protection required context) and a
   single verdict comment, then gates on the returned `Verdict: PASS|BLOCK`.
2. **The follow-up `auto-merge.yml` PR** is submitted and validated by the now-live gate.
   On gate **success** it re-verifies the green check on the exact head being merged,
   mints a free merge-time CalVer, finalizes the placeholder `CHANGELOG/<CalVer>.md` on
   the PR branch, squash-merges the validated head (never `--admin`), and creates the
   `v<VER>` tag on the merged commit — idempotent and loop-free.

Bootstrapping: because a gate cannot merge the PR that installs it (self-modifying
install), this gate-only PR is merged by the operator once it is green; every subsequent
PR — including the disposer — is handled entirely by the gate + disposer.

## Authority vs. convenience

The **authority** for what a PR must contain is the active harness root rulebook + the
`/charly-internals:git-workflow` and `pr-validator` skills (the 0–18 checklist).
This template is the GitHub-UI mirror of that — it does not restate the rules,
it prompts the author to supply the evidence for them.

Per-repo `.github/pull_request_template.md` copies are removed so every repo
falls through to this single source (see each repo's `CHANGELOG/`).
