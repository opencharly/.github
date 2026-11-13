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
# Overridable so a test can exercise the source-repo guard without inventing a repo.
readonly SOURCE_REPO="${SOURCE_REPO:-.github}"
readonly DISPATCHER_PATH=".github/workflows/pr-validator.yml"
readonly SOURCE_DISPATCHER_PATH=".github/workflows/pr-validator-dispatcher.yml"

# discovery page size — the ONE named literal (R3: no unnamed magic number).
#
# WHY REST PAGING AND NOT ONE `gh repo list --limit 1000` (opencharly/.github#290).
# The org holds ~486 repos, so the single GraphQL listing was five requests, and its
# later pages returned 502/504 intermittently while `--limit 100`/`--limit 200` and
# REST paging answered on every attempt. Measured INTERLEAVED, so the variable was
# the request, not the minute. Discovery is step zero of every org-wide script, so a
# flake there aborts the whole report — which is what happened: four consecutive
# attempts at the tag-on-merge caller rollout died at `FATAL: discover_repos failed`.
readonly DISCOVERY_PAGE_SIZE="${DISCOVERY_PAGE_SIZE:-100}"

# discover_all — every repo the listing can see, one row per repo, TAB-separated:
#   <name>\t<archived>\t<fork>\t<default_branch>
#
# TWO CONTROLS, and they are different controls:
#   1. `--paginate` returns non-zero if ANY page fails, so a page that 502s can
#      never be mistaken for the end of the org.
#   2. The COUNT is a LOWER BOUND on what the org reports. A merely TRUNCATED
#      successful response would still read as a smaller org to every caller — the
#      same class as the `mapfile < <(fn)` trap described at the top of this file,
#      where emptiness is not a failure signal on its own. One cheap request buys
#      the invariant.
# A repo created between the listing and the count makes this fail LOUD rather than
# return a set nobody verified. Nothing retries it (R3): every call site ABORTS on a
# non-zero status, and a re-run yields a consistent pair.
discover_all() {
  local rows got want
  if ! rows="$(gh api --paginate "orgs/${ORG}/repos?per_page=${DISCOVERY_PAGE_SIZE}" \
      --jq '.[] | [.name, (.archived|tostring), (.fork|tostring), (.default_branch // "")] | @tsv')"; then
    echo "discover_all: the org listing FAILED — refusing to return a partial repo set" >&2
    return 1
  fi
  if ! want="$(gh api "orgs/${ORG}" --jq '(.public_repos // 0) + (.total_private_repos // 0)')"; then
    echo "discover_all: the org repo COUNT could not be read — refusing to return an unverifiable repo set" >&2
    return 1
  fi
  got="$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l)"
  # A LOWER BOUND, not an equality. Truncation removes repos, so `got < want` is the
  # failure this catches. `got > want` is NOT a failure and must not be treated as one:
  # measured on a runner (opencharly/.github run 42770802075) the listing returned 486
  # while `public_repos + total_private_repos` reported 485 — the count is not an exact
  # census of what the listing serves, and an equality test turned that off-by-one into
  # `FATAL: discover_repos failed`, blocking every org-wide script.
  if [ "$got" -lt "$want" ]; then
    echo "discover_all: discovered ${got} repo(s) but the org reports ${want} — a page was TRUNCATED; refusing to understate the org" >&2
    return 1
  fi
  printf '%s\n' "$rows"
}

# discover_repos — active, non-fork, `main`-default repos (the target set).
discover_repos() {
  discover_all | awk -F'\t' '$2 == "false" && $3 == "false" && $4 == "main" { print $1 }' | sort
}

# discover_excludes — everything NOT in the target set (archived, fork, non-main).
discover_excludes() {
  discover_all | awk -F'\t' '$2 == "true" || $3 == "true" || $4 != "main" { print $1 }' | sort
}

# discover_membership — the active, non-fork repos as `<name>\t<default_branch>`,
# the read org-ruleset.sh's membership arm needs. It issues its OWN paged,
# count-checked fetch: a command substitution cannot memoise, so this read CAN
# diverge from the target set (a repo created between the two lands in neither)
# and CAN fail behind a successful targets read. Neither is silent — each read
# refuses a truncated set and every call site aborts on failure — and putting all
# three filters on ONE read per script is opencharly/.github#292.
discover_membership() {
  discover_all | awk -F'\t' '$2 == "false" && $3 == "false" { print $1 "\t" $4 }'
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

# calver_at <org> <repo> <commit-sha> — the CalVer tag this org mints at a release,
# derived from the commit's OWN committer date, in the same v<YYYY>.<DDD>.<HHMM> shape
# tag-on-merge uses. It exists because a write that bypasses the merge path bypasses the
# tag: the commit the reconcile PUTs lands on main untagged, so the tree is left with a
# head that is neither at a tag nor explicable as the CHANGELOG commit above one, and
# every pin that advances to it fails design-pintag (opencharly/.github#294).
calver_at() {
  local org="$1" repo="$2" sha="$3" iso
  iso="$(gh api "repos/$org/$repo/commits/$sha" --jq '.commit.committer.date')" || return 1
  # THE FORM IS PER-REPO, exactly as the reusable's tag-on-merge derives it: a root Go
  # module consumed through the proxy (sdk, spec, plugin-gh) is tagged in Go's form
  # v0.<y><doy>.<hhmm>, because a plain v<major>.<doy>.<hhmm> tag would need a /vN
  # module-path suffix and no consumer could name it. Every other repo gets the plain
  # CalVer. A single fixed form here would mint an unusable tag on those three.
  case "$repo" in
    sdk|spec|plugin-gh) date -u -d "$iso" +'v0.%Y%j.%-H%M' ;;
    *)                  date -u -d "$iso" +'v%Y.%j.%H%M' ;;
  esac
}

# select_repos — PURE. Reads repo names on stdin and prints those the allow-list names.
# An EMPTY (or all-space/comma) allow-list passes everything through. Shared so the
# reconcile and the backfill filter the same way instead of each carrying a copy.
select_repos() {
  local want="$1" line w
  if [[ -z "${want//[ ,	]/}" ]]; then cat; return 0; fi
  local -A keep=()
  for w in ${want//,/ }; do keep["$w"]=1; done
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ -n "${keep[$line]:-}" ]] && printf '%s\n' "$line"
  done
  return 0
}
