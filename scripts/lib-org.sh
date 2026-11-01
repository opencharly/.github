#!/usr/bin/env bash
# lib-org.sh — the shared helpers of this repo's shell scripts: the org-wide cutover
# scripts (org-ruleset.sh and retire-per-repo-dispatchers.sh), the other cutover and
# reconciliation scripts, and the TESTS that judge a step shipped inside the reusable
# validator (head-settle_test.sh, retired-sweep-arm_test.sh, assert-org-rulebook_test.sh).
# SOURCE this file; do not run it.
#
# IMPORTANT — how discovery failures are surfaced. The discovery functions RETURN a
# non-zero status on failure and print NOTHING; callers must invoke them via command
# substitution and check the status:
#
#     if ! out="$(discover_repos)"; then echo FATAL >&2; exit 1; fi
#     mapfile -t repos <<<"$out"
#
# A guard placed INSIDE a `mapfile ... < <(fn)` process substitution is dead: the
# subshell's exit status is not propagated and `mapfile` returns 0 on empty input, so
# a 401/403/rate-limit/network failure would silently yield an EMPTY list. For the
# exclude set (legitimately empty when there are no forks/archived repos) emptiness is
# not a failure signal — only the exit status is. Hence the status is checked at the
# call site, under `set -o pipefail`.

readonly ORG="${OPENCHARLY_ORG:-opencharly}"
readonly SOURCE_REPO=".github"
readonly DISPATCHER_PATH=".github/workflows/pr-validator.yml"
readonly SOURCE_DISPATCHER_PATH=".github/workflows/pr-validator-dispatcher.yml"

# discover_repos — active, non-fork, `main`-default repos (the target set).
discover_repos() {
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select(.isArchived == false and .isFork == false and .defaultBranchRef.name == "main") | .name' \
    | sed '/^$/d' | sort
}

# discover_excludes — everything NOT in the target set (archived, fork, non-main).
discover_excludes() {
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select((.isArchived == true) or (.isFork == true) or (.defaultBranchRef.name != "main")) | .name' \
    | sed '/^$/d' | sort
}

# declared_non_main_defaults — the active, non-fork repos whose default branch is
# DELIBERATELY not `main`, as TAB-separated `<repo>\t<default>\t<reason>`.
#
# WHY THIS MUST BE ENUMERATED AT ALL. The target set is derived from
# `defaultBranchRef == "main"` and the exclude set is its complement, so a repo that
# keeps a non-`main` default drops out of the org gate silently: no required
# `validate / validate` check, no CalVer tag, no CHANGELOG — and the verify loop, which
# iterates the TARGET set, can never notice (opencharly/.github#180, measured live:
# `opencharly/plugin-task-old-16365` reports 0 rules on `main` where `charly` reports 5).
#
# A repo is outside the target set for exactly three reasons: it is a fork, it is
# archived, or its default branch is not `main`. The first two are by design and are
# computed, never declared here. The third is a DEFECT unless it is listed below with a
# reason — so an entry here is a decision the org has made on purpose, and `verify`
# asserts that the population of undeclared non-`main` defaults is EMPTY.
declared_non_main_defaults() {
  cat <<'LIST'
# <repo>	<default>	<reason>
omarchy-eval-artifacts	runs	the omarchy eval lane's runs-branch artifact sink: no PRs, no landing, no gate expected
pixelflux	av1	a vendored upstream kept on its own default branch; the org compiles it from source but never lands PRs against it
LIST
}

# dispatcher_path_for <repo> — the SOURCE repo uses the `-dispatcher.yml` stub.
dispatcher_path_for() {
  [[ "$1" == "$SOURCE_REPO" ]] && echo "$SOURCE_DISPATCHER_PATH" || echo "$DISPATCHER_PATH"
}

# list_config_paths <repo> — print `<status>` (ok | truncated | failed) then, when
# ok, every `charly.yml` blob path in the repo, ROOT OR NESTED, one per line. Uses
# the git TREES API recursively (`git/trees/main?recursive=1`) so a nested
# candy/box/tools/packaging/check/testdata manifest is discovered, not just the
# root file. Paths are the tree's blob paths (e.g. `candy/plugin-box/charly.yml`);
# the recursive listing includes testdata fixtures (e.g. charly/testdata/...), which
# is intended — the retired stamp must go from EVERY authored manifest.
#
# ALWAYS returns 0 (the caller branches on the status line):
#  - ok        — the tree was read; the paths follow (possibly none, meaning the
#                repo has no charly.yml — the caller counts it `absent`).
#  - truncated — the recursive API could not return the whole tree. This is a
#                SILENT-MISS risk: an unseen nested manifest would be left stamped.
#                The caller MUST treat it as FATAL, never as "no charly.yml".
#  - failed    — a transport/API error. The strip caller treats it as FATAL (like
#                `truncated`): a listing that failed means an UNKNOWN number of
#                manifests were not seen, so a green run could leave a nested stamp
#                behind. The caller aborts; it never reads this as "no charly.yml".
list_config_paths() {
  local repo="$1" json
  if ! json="$(gh api "repos/$ORG/$repo/git/trees/main?recursive=1" 2>/dev/null)"; then
    printf 'failed\n'; return 0
  fi
  # Gate BOTH the truncation probe and the path extraction on jq's EXIT STATUS: a
  # non-JSON/partial body returned while `gh` exited 0 would otherwise make the
  # probe yield "" (!= "true") and the extraction yield nothing — a silent `ok`
  # with zero paths, exactly the miss this helper must never produce.
  if ! truncated="$(jq -r '.truncated // false' <<<"$json" 2>/dev/null)"; then
    printf 'failed\n'; return 0
  fi
  if [[ "$truncated" == "true" ]]; then
    printf 'truncated\n'; return 0
  fi
  if ! paths="$(jq -r '[.tree[] | select(.type == "blob") | .path | select((split("/") | last) == "charly.yml")] | .[]' <<<"$json" 2>/dev/null)"; then
    printf 'failed\n'; return 0
  fi
  printf 'ok\n'
  [[ -n "$paths" ]] && printf '%s\n' "$paths"
  return 0
}

# api_status <path> — the HTTP status of a GET; empty on a transport/other failure.
api_status() {
  local resp
  resp="$(gh api --include "$1" 2>&1 || true)"
  # Read the status from the FIRST line but do NOT `exit` awk: under `pipefail` a
  # response body larger than the 64 KiB pipe buffer (every charly.yml over ~64 KB —
  # measured on distro-arch, 100 KB) makes awk close the pipe while printf is still
  # writing, so printf dies with SIGPIPE (141) and the whole pipeline — hence this
  # function under `set -e` — FAILS. Letting awk consume the whole input costs nothing
  # (it prints only line 1) and keeps the function SIGPIPE-safe for any body size.
  printf '%s\n' "$resp" | awk 'NR==1 { print $2 }'
}

# extract_step_run <workflow> <selector-regex> <outfile>
# The `run:` block of ONE workflow step, dedented, verbatim.
#
# WHY THIS IS ONE FUNCTION AND NOT A COPY PER TEST (R2). The reusable validator's
# steps live INSIDE .github/workflows/pr-validator.yml and run in the CALLER's
# repository, so a script in this repo cannot be what the caller runs: a test must
# EXTRACT the shipped step's text and run THAT, or the test judges a copy of the
# step instead of the step. Two tests needed that extraction and each grew its own
# awk — a byte-identical algorithm whose only difference was the step selector, so
# a change to the extraction had to be made in two places and could be made in one
# place only. The ALGORITHM lives here; the SELECTOR stays with each test, because
# which step a test judges is that test's own business.
#
# <selector-regex> matches the line that identifies the step (its `- name:` or its
# `id:`) — ANCHOR it, so a comment that merely mentions a step cannot match. The
# step's FIRST `run: |` block is the one extracted; a step with no `run:` block
# yields an empty outfile, and the caller decides what that means.
extract_step_run() {
  local wf="$1" selector="$2" out="$3"
  awk -v sel="$selector" '
    function indent(s,   i) { for (i = 1; i <= length(s); i++) if (substr(s, i, 1) != " ") return i - 1; return length(s) }
    $0 ~ sel { in_step = 1; next }
    in_step && !found_run && /^ *run: *\|/ { run_indent = indent($0); found_run = 1; next }
    found_run {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      ind = indent($0)
      if (ind <= run_indent) { exit }
      if (content_indent == 0) content_indent = ind
      if (ind < content_indent) { exit }
      print substr($0, content_indent + 1)
    }
  ' "$wf" >"$out"
}

# extract_step_yaml <workflow> <selector-regex> <outfile>
# The YAML BLOCK of ONE workflow step: the matching line and every line up to the
# next step. Where extract_step_run returns the step's CODE, this returns the step's
# DECLARATION — the env, the inputs, the timeout, the conditions around it.
# Same R2 reason as extract_step_run: the algorithm is one, the selector is the
# caller's.
extract_step_yaml() {
  local wf="$1" selector="$2" out="$3"
  awk -v sel="$selector" '
    $0 ~ sel { in_step = 1; print; next }
    in_step && /^ *- name: / { exit }
    in_step { print }
  ' "$wf" >"$out"
}
