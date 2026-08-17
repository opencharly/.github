<!--
OpenCharly PR template. `main` advances ONLY through this PR + a green
charly/pr-validator status posted by the fresh pr-validator agent, which
merges it. FILL EVERY SECTION with EVIDENCE, not promises — the pr-validator
FAILS a body that leaves any applicable section blank, answers a rule with a
bare checkbox instead of HOW it was satisfied, or pastes no R10 output. Mark a
line `N/A — <reason>` where the change class genuinely excludes it (docs-only
skips the runtime rules). See CLAUDE.md "Ground Truth Rules" + "Post-Execution
Policies" + /charly-internals:git-workflow + /charly-check:check "R10 gate by
change class". Do NOT compute the release CalVer: use a placeholder
CHANGELOG/<CalVer>.md; the pr-validator finalizes the merge-time version.
-->

## Summary of changes

<!-- What changed and WHY. One paragraph + a bulleted list of the concrete edits.
     Every file/behavior in the diff must be accounted for here (a description↔code
     mismatch is a security FAIL). -->

## Change class

<!-- Pick ONE (drives which R10 gate + which rules apply below):
     docs-only | candy/box-config | charly-or-sdk Go | hook/workflow | cross-repo
     For cross-repo: list the repos + the producer→consumer landing order. -->

**Closes / relates to:** <!-- issue or PR refs (`Closes #12`, `relates to opencharly/sdk#7`), or `none`. For a cross-repo leg, name the sibling legs and which must merge FIRST — a projection lands before the source that pins it. -->

**Breaking change + rollback:** <!-- Does this remove or rename a public surface (a CLI verb/flag, a schema field, an exported Go symbol, a candy/box name)? If yes: say WHAT breaks, name the `!` in the commit subject, and state how a consumer recovers. Then state how THIS PR is rolled back if it lands and proves wrong — a revert, or a forward-fix because a tag/publish already went out. `none` if nothing breaks. -->

## How R10-tested — exact gate, commands, and pasted output

<!-- The validator re-runs this; give it the EXACT recipe + proof, not a summary. -->

- **The gate for this change class:** <!-- name it per /charly-check:check "R10 gate by change class" — e.g. `charly check run <bed>` for a touched code path; `charly box validate` + build + the composing bed for a candy; the concurrent /verify-beds roster for a cross-cutting loader/resolver/IR change; the non-runtime standards for docs-only. -->
- **Eval beds run — the EXACT beds + per-bed results (a bare "the beds passed" FAILS):** <!-- List EVERY `charly check run <bed>` disposable bed executed for this change class, ONE PER LINE, each with its verdict: `<bed> | <substrate> | ok/FAIL | <steps> steps | <total_seconds>s`. State the ONE binary version (`charly version`) they all ran on and their shared run-calver (`.check/<bed>/<calver>/`); for a cross-cutting change confirm they were launched CONCURRENTLY in one batch. These MUST be the CORRECT beds for the touched code path — the pr-validator maps the diff to the R10-gate-by-change-class matrix, cross-checks every line against `.check/<bed>/<calver>/summary.yml`, RE-RUNS the correct beds itself if a result is missing/contradictory/suspicious, and FAILS a gate that ran the wrong or too-few beds. `N/A (docs-only)` with the reason if no bed applies. -->
- **Fresh rebuild:** <!-- confirm R9: the binary was REBUILT from this source (`task build:binary`) and `charly version` matches; and the gate ran on a FRESH `charly update`/rebuild, at ZERO warnings. `N/A (docs-only)` with the reason if no binary is involved. -->
- **Did the CHANGED code path execute live?** <!-- yes → the changed runner/branch ran, output below. If ONLY the success path ran (the new error/edge branch did not execute), say so — it caps the tier at `analysed on a live system`. A `--dry-run`, a bare `go test`, a rebuild WITHOUT running the changed piece, or "will test later" is NOT the gate. `N/A (docs-only)` with the reason if the diff changes no code path. -->
- **Concurrency (shared-state changes only):** <!-- if this touches the loader/discover walk, deploy ledger, podman store, resource arbiter, VM/pod lifecycle, or a build lock: paste the CONCURRENT roster run (all beds at once, /verify-beds). "It passes on an idle/serial run" is NOT proof and is a FAIL. Every failure the roster surfaced is answered with its ROOT mechanism + fix, never "flake/environmental/load". Else `N/A`. -->

**Evidence — put each item in the block whose label names it.** A block that does not apply to this
change class: replace its contents with `N/A — <reason>`, and keep the block. **Any block left empty
FAILS** — applicable or not, an empty block is never a valid answer.

*1. Fresh-rebuild gate output* (`charly version` + the gate run, at zero warnings):
```

```

*2. Each changed code path executing* (the lines proving the changed branch ran, not that it built):
```

```

*3. Docs-only evidence* (the R5 grep self-test result + the cross-reference/markdown review):
```

```

## Attribution tier

<!-- One of: fully tested and validated | analysed on a live system | documentation reviewed.
     Justified by the evidence above, never inflated:
     - `fully tested and validated` requires the cutover's NEW/CHANGED code paths to have
       EXECUTED against the fresh rebuild (a changed branch that never ran live is at most
       `analysed on a live system`).
     - `documentation reviewed` is legal ONLY when the whole diff is documentation
       (`*.md` / comment-only / all-doc submodule bump).
     - `syntax check only` / `theoretical suggestion` must NOT ship.
     An AI-authored commit carries the matching
     `Assisted-by: <Harness> <Provider Full Model Name> (<confidence>)` trailer,
     replacing each placeholder with the authoring runtime's exact identity. A 100% human-authored
     commit carries no `Assisted-by:` trailer. -->

## Harness rulebook compliance — state HOW each is satisfied (or `N/A — <reason>`)

<!-- One line of EVIDENCE per rule (what you did / where to look), not a bare tick.
     These mirror the pr-validator's checklist; an unanswered applicable rule FAILS. -->

- **R0 skills:** <!-- which Skill-Dispatcher skills the change's area loads, and how it honors them -->
- **R1 RCA + zero warnings:** <!-- every failure/warning surfaced (build/test/lint/check/deploy) root-caused + fixed; gate output has ZERO warnings; no "flake/transient/environmental" -->
- **R2 no out-of-scope:** <!-- every issue surfaced during this cutover fixed here (blocking) or spun as its own immediate-next cutover — none parked as "pre-existing/follow-up" -->
- **R3 no duplication:** <!-- any repeated pattern unified into one shared abstraction; no `<name>-host`/`<name>-pod` siblings -->
- **R4 no workaround:** <!-- no sleep/retry/magic-number/env-shim; a race fixed with a sync primitive; no ad-hoc podman/docker/virsh/systemctl against charly resources -->
- **R5 hard cutover + grep:** <!-- paste/confirm `git grep '<removed-id>'` (and every false claim swept) returns only CHANGELOG context; NO transitional/dual-mode/legacy path in the FINAL code  — or `N/A — purely additive, no identifier removed or renamed` (the false-claim sweep half still applies and should say so) -->
- **R6 git safety:** <!-- any destructive git action was preceded by a status/stash check — or N/A -->
- **R7 runtime gate:** <!-- a runtime-affecting change ran the end-to-end bed gate, not just `go test` — or N/A -->
- **R8 artifact invariants:** <!-- a generation change asserted the emitted Containerfile sections + `ai.opencharly.*` labels post-build — or N/A -->
- **R9 binary == source + deps:** <!-- deployed binary rebuilt + `charly version` matches; new runtime OS deps in the charly candy's `packaging:` section (`candy/charly/charly.yml`) — or N/A -->
- **R10 disposable + coverage:** <!-- proven on `disposable: true` only, fresh rebuild, zero warnings; ships the check/test coverage that would FAIL without this change  For a DOCS-ONLY change this branches, per CLAUDE.md R10: the non-runtime standards and NO bed — say so, and do not invent a runtime-shaped answer to fill a runtime-shaped demand. -->
- **RDD / ADE / SDD:** <!-- RDD: high-risk assumptions (esp. composition-at-latest-versions) bed-proven, not doc-read. ADE: every new/changed candy has `description:` + `plan:` with ≥1 deterministic `check:` (`charly box validate` passes). SDD: a schema/`.cue` edit regenerated its `*_gen.go` and `task cue:gen` is a no-op — or N/A -->
- **Hard cutover:** <!-- ONE atomic commit per repo; no "Phase 2/TODO/deferred" left in scope; an approved plan executed as written -->
- **Kernel/plugin boundary law:** <!-- a core/`sdk` change is only a generic Envelope/Mechanism/Bootstrap-root/kind-Data — no concrete-kind schema/switch/per-kind-map leaked into the kernel; a new capability is a plugin — or N/A -->
- **Disposable-only autonomy:** <!-- any autonomous destroy/rebuild was on a `disposable: true` target — or N/A -->
- **Clean architecture + Go gates:** <!-- cleanest approach, deprecated code fully removed; for Go: `gofmt -l .` empty, `golangci-lint run ./...` = 0 issues, `go vet` clean, `go test ./...` green — or N/A -->
- **CHANGELOG:** <!-- `CHANGELOG/<CalVer>.md` staged (placeholder CalVer — the pr-validator finalizes it)  — or `N/A — <reason>` if this repo keeps no `CHANGELOG/` (verify with `GET /contents/CHANGELOG`; do not assume) -->

---

*Assisted-by: &lt;Harness&gt; &lt;Provider Full Model Name&gt; (&lt;confidence&gt;)*
<!-- For a 100% human-authored PR, omit the Assisted-by line. -->

<!--
GLOSSARY — the load-bearing nouns above, defined once so this form is answerable
without opening five skills first. These DEFINE terms; they do not relax any rule.

  bed            A `disposable: true` deploy that `charly check run <bed>` drives end
                 to end: build → check image → deploy → check live → fresh update →
                 tear down. The R10 acceptance gate. Roster + matrix:
                 /charly-check:check "R10 gate by change class".
  disposable     The `disposable: true` flag on a DEPLOY (never on a vm/box entity).
                 The one and only authorization for autonomous destroy + rebuild;
                 never inferred from a name or hostname. /charly-internals:disposable.
  CalVer         `<YYYY>.<DDD>.<HHMM>` — the release version, minted BY THE VALIDATOR at
                 merge, not by the author. Use a placeholder `CHANGELOG/<CalVer>.md`.
                 The sdk is the one exception: Go modules forbid a leading-zero segment,
                 so it tags `v0.<YYYYDDD>.<HHMM zeros-stripped>`.
  R0–R10         The Ground Truth Rules in CLAUDE.md / AGENTS.md. R0 skills-first;
                 R1 RCA every anomaly (a warning is a failure); R2 no "out of scope";
                 R3 no duplication; R4 no workarounds; R4a fix the product before the
                 prose; R5 delete legacy completely; R6 git safety; R7 prove behaviour
                 not compilation; R8 verify emitted artifacts; R9 binary equals source;
                 R10 fresh disposable proof.
  RDD            Risk Driven Development — prove a high-risk assumption on a live bed
                 EARLY, before the edits that depend on it. Docs and code are hypotheses.
  ADE            Agent Driven Evaluation — every candy ships a non-empty `description:`
                 and a `plan:` with at least one deterministic `check:` step.
  SDD            Schema Driven Design — the CUE schema comes first; schema-shaped Go is
                 GENERATED (`task cue:gen`), never hand-written. Drift is an incident.
  projection     A GENERATED artifact — `plugins/**/SKILL.md` and
                 `docs/src/content/docs/{reference,recipes}/**` — produced from a candy
                 source. Never hand-edit one; fix the candy and regenerate. A projection
                 merges BEFORE the source that pins it. Also generated, but from the ROOT
                 documents rather than a candy: `docs/src/content/docs/{index,vision,
                 grievances,liberation}.md` — projected from `README.md` / `VISION.md` /
                 `GRIEVANCES.md`; fix the root document. NOT projections, and hand-authored:
                 `docs/src/content/docs/{start,concepts,guides}/**` — edit those directly.
-->
