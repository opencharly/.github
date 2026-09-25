# opencharly/.github — org-wide community-health defaults

This repository is GitHub's org-level source of **default community-health
files**. Any repository in the `opencharly` org that does **not** ship its own
copy inherits the files here — so a change lands **once**, not in every repo.

## What lives here

- **`.github/PULL_REQUEST_TEMPLATE.md`** — the OpenCharly PR template. It elicits
  the exact evidence the fresh `pr-validator` validator needs: the change-class
  R10 gate + pasted output, whether the changed code path ran live (which caps
  the attribution tier), and a full R0–R10 + pillars "state HOW / N/A" checklist.
- **`scripts/org-ruleset.sh`** — the SINGLE organization-wide owner of BOTH the
  required `validate / validate` check AND main-branch protection. On GitHub Team
  it creates ONE org ruleset carrying the `workflows` rule (pointing at this repo's
  required workflow) *and* the ordinary branch rules (required status check, no
  force-push, no deletion, no creation), applied to every active non-fork
  `main`-default repo. It also enforces the two settings that cannot move to the org
  (`allow_auto_merge` and `delete_branch_on_merge`, per-repo settings with no org
  default). `apply` enables the org ruleset, deletes the now-redundant per-repo
  rulesets, and enforces both settings; `verify` asserts the whole end state. Its
  offline mock-`gh` test is `scripts/org-ruleset_test.sh`.
- **`scripts/retire-per-repo-dispatchers.sh`** +
  **`.github/workflows/retire-per-repo-dispatchers.yml`** — the one-shot cutover
  step that DELETES each repo's redundant `.github/workflows/pr-validator.yml`
  dispatcher stub. It runs as a workflow because a delete on a protected `main`
  needs a ruleset-bypass commit author — the `charly-auto-merge` App (the workflow
  mints that token). Run it BEFORE `scripts/org-ruleset.sh apply`, which refuses
  while any dispatcher survives, so the org required workflow is never a second
  producer of the required check. Idempotent (absent files skipped); its offline
  mock-`gh` test is `scripts/retire-per-repo-dispatchers_test.sh`.
- **`.github/workflows/pr-validator.yml`** — the org-wide `charly/pr-validator` gate.
  A **reusable workflow** (`on: workflow_call`) that also self-gates this `.github`
  repo (`on: pull_request`). It runs a fresh, independent charly review (the plugin-review plugin, welded
  into the charly release) as the PR validator, always posts a single PR comment,
  and sets the required
  `charly/pr-validator` check from a deterministic `Verdict: PASS|BLOCK`
  (PASS → exit 0 — **only for a review that exited 0**: a non-zero review exit
  may carry only a real BLOCK finding, so any other verdict it wrote is
  discarded (fail-closed) — BLOCK → exit 1, no trustworthy verdict →
  **INCONCLUSIVE** + exit 3 — the required check stays RED, so a provider that
  never answered can neither pass unreviewed code nor be mistaken for a code
  finding — mixed verdict → exit 2).
- **`.github/workflows/org-wide-pr-validator-required.yml`** — the org-level
  REQUIRED WORKFLOW the org ruleset names. GitHub runs it on every PR in every
  targeted repo (definition read once from this repo at the pinned ref); it calls
  the reusable `pr-validator.yml@main` above, so the gate logic stays one source,
  and it carries the per-PR `concurrency` dedupe + `actions: write` (the #163
  constraint — see the file header). This file replacing the per-repo dispatcher
  is why no repo carries validator config of its own.
- **`.github/workflows/validator-harness.yml`** +
  **`.github/tests/validator-gate-harness.py`** — the gate's own R10 coverage.
  The harness (python3 stdlib only, offline, fakes for charly and gh) drives the
  REAL `run:` bodies of the decision chain above and asserts each exit code, the
  classification, the INCONCLUSIVE comment and whether auto-merge was armed; the
  workflow runs it on every `pull_request` and on `workflow_dispatch`, so a
  non-zero harness exit reddens the check. The workflow also runs
  `scripts/org-ruleset_test.sh` (the owner script's offline mock-`gh` test) so
  the org-ruleset cutover logic is exercised on every `.github` PR. Coverage that
  never runs enforces nothing.

Future org-wide defaults (issue templates, `CONTRIBUTING.md`, `SECURITY.md`) belong
here too — one source, inherited everywhere.

## How the gate is installed in an org repo

**It is not.** The gate is a **single source** in this repo — the ONE org ruleset
(`scripts/org-ruleset.sh`) names the required workflow and requires the
`validate / validate` check for every repo, so no repo installs anything. The old
per-repo `.github/workflows/pr-validator.yml` dispatcher stub existed only because
org required-workflows need GitHub Team (the org was on the free plan when that
pattern began); the org ruleset now replaces it, and
`.github/workflows/retire-per-repo-dispatchers.yml` deletes the stub in every repo.
The one-time cutover order is:

```console
$ gh workflow run retire-per-repo-dispatchers.yml   # delete the per-repo stubs first
$ scripts/org-ruleset.sh apply                      # then enable the org ruleset
$ scripts/org-ruleset.sh verify                     # assert the whole end state
```

## New repos: bootstrap the initial `main`

The org ruleset carries the `creation` rule on `refs/heads/main`, so a **brand-new
repo cannot create its first `main` by any operator path** — `git push`, the
contents API, repo `auto_init`, and branch rename are all rejected (measured:
`GH013 Cannot create ref due to creations being restricted` on a push; the contents
API returns `409 Cannot create ref due to creations being restricted` on a repo with
no refs and `404 Branch main not found` on a repo with other refs but no `main`;
rename `422 repository rules do not permit renaming branch ... to 'main'`).
The ruleset's only bypass actor is the `charly-auto-merge` App — and without a
`main` the required workflow cannot run, so the required check can never be
produced (a deadlock).

Bootstrap a new repo's `main` with the App-token workflow:

```console
$ gh workflow run bootstrap-repo-main.yml -f repos="my-new-repo"   # in opencharly/.github
$ gh api --method PATCH repos/opencharly/my-new-repo -f default_branch=main
```

`scripts/bootstrap-repo-main.sh` (run by
`.github/workflows/bootstrap-repo-main.yml`) creates `refs/heads/main` from the
repo's current default-branch HEAD via the **git-data refs API** — the API with no
branch-must-exist precondition (the contents API requires the branch to already
exist). It **never** moves an existing `main` and skips a repo with nothing to seed
from, so it is safe and idempotent. The ref creation needs only the App's
`contents: write` bypass; setting the repo's **default branch** is a repo-settings
change the App cannot make (`403 Resource not accessible by integration`), so that
final step uses the operator's admin token.

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
  with All-repositories access. It is ALSO the ruleset bypass actor, so it
  additionally needs the **`workflows: write`** permission (Repository
  permissions → Workflows: Read and write) for the org cutover's dispatcher
  deletions (`.github/workflows/*`), on top of `contents: write`.
- Org secrets `CHARLY_AUTO_MERGE_APP_ID` + `CHARLY_AUTO_MERGE_PRIVATE_KEY`.
  Fallback: `CHARLY_BOT_TOKEN` (fine-grained PAT, Contents: write + Workflows: write).

The rename step hard-fails when neither is configured, so a missing
secret never silently degrades to the approval-required loop.

## The org-wide required workflow (ONE config, no per-repo copy)

Branch protection AND the required validator used to be applied per repo (a branch
ruleset + a copied `.github/workflows/pr-validator.yml` dispatcher). On GitHub Team
they are now ONE organization ruleset (`scripts/org-ruleset.sh`), which carries both
the `workflows` rule (naming `org-wide-pr-validator-required.yml` here) and the
branch rules (strict required `validate / validate`, no force-push/deletion/create).
One-time cutover order: `gh workflow run retire-per-repo-dispatchers.yml`, then
`scripts/org-ruleset.sh apply`, then `scripts/org-ruleset.sh verify`.
