# opencharly/.github — org-wide community-health defaults

This repository is GitHub's org-level source of **default community-health
files**. Any repository in the `opencharly` org that does **not** ship its own
copy inherits the files here — so a change lands **once**, not in every repo.

## What lives here

- **`.github/PULL_REQUEST_TEMPLATE.md`** — the OpenCharly PR template. It elicits
  the exact evidence the fresh `pr-validator` validator needs: the change-class
  R10 gate + pasted output, whether the changed code path ran live (which caps
  the attribution tier), and a full R0–R10 + pillars "state HOW / N/A" checklist.
- **`scripts/branch-protection.sh`** — the single organization-wide owner of the
  required `charly/pr-validator` check. It discovers every active, non-fork
  repository, replaces the required context in one batch, and verifies the
  resulting protection without maintaining per-repository copies or lists.
- **`.github/workflows/pr-validator.yml`** — the org-wide `charly/pr-validator` gate.
  A **reusable workflow** (`on: workflow_call`) that also self-gates this `.github`
  repo (`on: pull_request`). It runs a fresh, independent charly review (the plugin-review plugin, welded
  into the charly release) as the PR validator, always posts a single PR comment,
  and sets the required
  `charly/pr-validator` check from a deterministic `Verdict: PASS|BLOCK`
  (PASS → exit 0, BLOCK → exit 1, no verdict → **INCONCLUSIVE** + exit 3 — the
  required check stays RED, so a provider that never answered can neither pass
  unreviewed code nor be mistaken for a code finding — mixed verdict → exit 2).
- **`org-wide-pr-validator-dispatcher.yml`** — the one-file installer any org repo
  drops in as `.github/workflows/pr-validator.yml` to inherit the same gate via
  `uses: opencharly/.github/.github/workflows/pr-validator.yml@main` (see below).

Future org-wide defaults (issue templates, `CONTRIBUTING.md`, `SECURITY.md`) belong
here too — one source, inherited everywhere.

## How the gate is installed in an org repo

The gate is a **single source** in this repo; sibling repos never copy the
validator logic. A repo opts in by installing the one-file dispatcher:
`.github/workflows/pr-validator.yml` containing

```yaml
name: charly/pr-validator
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
permissions:
  contents: read
  pull-requests: write
  issues: write
jobs:
  pr-validator:
    name: charly/pr-validator
    if: github.event.pull_request.head.repo.fork == false
    uses: opencharly/.github/.github/workflows/pr-validator.yml@main
    secrets: inherit
```

(`org-wide-pr-validator-dispatcher.yml` is the exact template.) The repo's
branch protection then requires the `charly/pr-validator` check context. The
workflow's job is named `charly/pr-validator`, so the check run satisfies it —
the workflow is the canonical single writer of that context, and branch
protection enforces it. Companion repos (`plugins`, `charly`) install the
dispatcher in their cut-over PRs.

## Required org-level configuration

Nothing is hardcoded and no credential is committed. The workflow reads
provider/model/endpoint/key from the GitHub environment and passes them to the
charly review step as the `AI_REVIEW_*` env (`provider` / `model` / `base_url` / `api_key`). Set these as **org-level** variables/secret (Settings → Secrets and variables → Actions → New repository secret / New variable, org level, **visibility: all**):

| Name | Kind | Default | Purpose |
|---|---|---|---|
| `AI_REVIEW_PROVIDER` | variable | `ollama` | LLM provider name |
| `AI_REVIEW_BASE_URL` | variable | `https://ollama.com/v1` | Provider base URL override (empty = built-in) |
| `AI_REVIEW_MODEL` | variable | `deepseek-v4.1-flash` | Exact model ID in the provider's catalog |
| `AI_REVIEW_API_KEY` | secret | — | Provider API key (never committed) |

The model id is passed **verbatim** to the provider's chat-completions endpoint
(`deepseek-v4.1-flash` is an Ollama Cloud model id, served at `https://ollama.com/v1` —
the same catalog as the local ollama `deepseek-v4.1-flash:cloud` pointer); `base_url`
selects the endpoint; no `models.json` is written and no model catalog is embedded. The
gate is charly-native: plugin-review is welded into the charly release, driven by
`charly review --plan review-plan.yml` (plan + prompt live in
opencharly/action-review@main — the validator spec's single config source, updated without
touching the workflow). The gate-mechanism version surface is the pinned charly release
(`vars.CHARLY_VERSION`; the workflow default `v2026.254.1902` is bumped deliberately per
release).

## Scope & evidence baseline (honest capability statement)

This gate is a **static diff + thread review** run by a fresh independent validator
(`charly review`, the plugin-review plugin welded into the charly release). It runs
read-only GitHub tools — `get_pr_diff`, `get_pr_commits`, `get_pr_thread` (the CURRENT
live body is authoritative + prior comments), `get_pr_meta` — and **no shell**. For every claim
it verifies it either (a) derives it from the diff/commits/thread, or (b)
**cross-checks the author's pasted evidence for internal consistency** and states
an explicit tool-limited disposition ("could not re-run from this environment")
where independent re-execution would be required. It never fabricates a run and
never lets a missing re-run pass on the author's word alone.

Consequence for **runtime / Go / schema** classes: the gate validates pasted
bed/regen/lint output statically — it cannot independently re-run it. Deep
independent re-execution of runtime-class evidence remains the full shell-enabled
fresh-evaluator agent's job in the `charly` repo; this gate is the org-wide first
line. Authors must paste complete, self-consistent, fraud-free evidence. No more
is overclaimed.

## Self-install note

On the PR that first installs this gate, the gate's end-to-end green check is not
observable before the gate itself merges (a self-install). The validator guidance
accordingly never treats that as a blocking finding: it verifies the mechanism
statically, accepts an explicit operator sign-off, and passes unless a genuinely
fixable, non-self-blocking defect remains. This is the only instance where the
gate's own check is not independently green.

## Bot-token rename push (org secrets)

Every PR must carry a CHANGELOG placeholder renamed to the merge-time
CalVer. The validator performs that rename **with a bot token, not
GITHUB_TOKEN**: GitHub requires approval for runs triggered by
GITHUB_TOKEN pushes, and no event exists that can auto-approve them.
A bot-token push re-triggers `pull_request: synchronize` normally.

Setup (already done org-wide):

- GitHub App `charly-auto-merge` (id 4675576), installed on `opencharly`
  with All-repositories access.
- Org secrets `CHARLY_AUTO_MERGE_APP_ID` + `CHARLY_AUTO_MERGE_PRIVATE_KEY`.
  Fallback: `CHARLY_BOT_TOKEN` (fine-grained PAT, Contents: write).

The rename step hard-fails when neither is configured, so a missing
secret never silently degrades to the approval-required loop.
