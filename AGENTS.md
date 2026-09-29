# AGENTS.md — opencharly/.github

The `opencharly` org's GitHub-level configuration repo. It is the SINGLE SOURCE
for the org-wide PR gate, the org branch ruleset, the CalVer tag-on-merge
mechanism, and the inherited community-health files — so a change lands **once**,
not in every repo.

Canonical files:

- `.github/workflows/org-wide-pr-validator-required.yml` — the org-level REQUIRED
  workflow the org ruleset names; it calls the reusable `pr-validator.yml`.
- `.github/workflows/pr-validator.yml` — the reusable `charly/pr-validator` gate
  (a fresh independent `charly review`; `Verdict: PASS|BLOCK`; the required
  `validate / validate` check).
- `.github/workflows/tag-on-merge.yml` (+ `tag-on-merge-dispatcher.yml`) — the
  org-wide CalVer tag + `CHANGELOG/<CalVer>.md` on merge.
- `.github/workflows/candy-validate.yml` — the ONE org-level candy/box manifest
  gate (reusable `on: workflow_call`), run at the org variable
  `vars.CHARLY_VERSION`; it skips cleanly when a repo has no `charly.yml`. It
  replaces the retired class of hand-rolled per-repo candy gates
  (`scripts/retire-per-repo-candy-gates.sh` deletes those).
- `.github/PULL_REQUEST_TEMPLATE.md` — the inherited PR template the validator
  reads (change-class gate, pasted evidence, R0–R10 accounting, attribution).
- `scripts/org-ruleset.sh` — the SINGLE owner of the org ruleset (required check
  + branch rules) and the per-repo auto-merge settings; `scripts/*_test.sh` are
  its offline mock-`gh` tests.
- `charly.yml` — the org-wide AI-review contract (`review-contract:` candy: the
  `AI_REVIEW_*` defaults and the validator rulebook).
- `README.md` — user overview only; never agent guidance.

## Load these skills first (R0)

- `/charly-internals:repo-setup` — the org ruleset, the required workflow, native
  auto-merge, tag-on-merge CalVer, and the new-repo checklist.
- `/charly-internals:git-workflow` — the landing mechanics the gate enforces
  (branch loop, the two-step PR + `pr-validator` merge/tag, CalVer-at-merge).

## Build / validate / test

- `.github/workflows/validator-harness.yml` runs `.github/tests/validator-gate-harness.py`
  (offline, python3 stdlib, fakes for `charly` + `gh`) against the REAL `run:`
  bodies of the decision chain, and `scripts/org-ruleset_test.sh` — on every PR
  to this repo.
- The merge gate is the **org-wide** `charly/pr-validator` (required check
  `validate / validate`); this repo is its own first consumer.
- `scripts/org-ruleset.sh verify` asserts the whole org end state.

## Modify this repo

- The gate logic is ONE source: edit `pr-validator.yml` /
  `org-wide-pr-validator-required.yml` here, never a per-repo copy (there are
  none — `.github/workflows/retire-per-repo-dispatchers.yml` deletes any that
  survive).
- The validator rulebook lives in `charly.yml`'s `AI_REVIEW_PROMPT` (overridable
  by org `AI_REVIEW_*` variables); a governance change is reconciled across the
  validator rulebook, the umbrella `AGENTS.md`, `charly/AGENTS.md`, and the
  skill source + its projection in the same change.
- The gate, the ruleset, and the template are self-modifying-security surfaces:
  a change here gets heightened review and must strengthen or preserve the gate.

## Landing

- PR-only. Every change lands through a pull request; the org-required
  `charly/pr-validator` validates the diff and body and arms native auto-merge on
  PASS. Direct pushes to `main` are blocked.
- History lives in `CHANGELOG/` (written by `tag-on-merge` at merge time); the PR
  body IS the changelog.
- The authoritative rulebook is the umbrella `AGENTS.md` in
  `opencharly/opencharly` and `charly/AGENTS.md` in the charly repo. Do not
  restate its rules here.
