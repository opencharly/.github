#!/usr/bin/env bash
# labels.sh — the ONE org-wide issue-label taxonomy tool (opencharly/opencharly#1238).
#
# The taxonomy lives in labels/taxonomy.json (12 closed labels: one category axis + one
# type axis) and labels/category-rules.json (generic path/action evidence; no
# repository names and no repo→category defaults). This script owns every
# mechanical operation: sync, audit, classify, apply, retire, render, verify-close,
# sample and explain. There is NO fallback label: an issue that cannot be decided is
# under-specified or split, never stamped with a guess.
#
# Usage:
#   bash scripts/labels.sh sync       [--org] [--repo <name>]... [--repos "<a b>"] [--dry-run]
#   bash scripts/labels.sh audit      [--org] [--repo ...] [--state open|closed|all] [--apply]
#                                     [--strict] [--json] [--close-pass]
#   bash scripts/labels.sh classify   [--org] [--repo ...] [--state open] [--out FILE]
#   bash scripts/labels.sh apply      --from FILE [--dry-run]
#   bash scripts/labels.sh retire     [--org] [--repo ...] [--after-backfill] [--snapshot-out FILE] [--dry-run]
#   bash scripts/labels.sh render     [--out FILE]
#   bash scripts/labels.sh verify-close <owner/repo#pr> <owner/repo#issue>
#   bash scripts/labels.sh sample     [--n 20] [--out FILE] [--from FILE] [--record] [--set NAME] [--revision REV]
#   bash scripts/labels.sh explain    <owner/repo#issue>
#
# A quota refusal is the one named class (api_error_class 4): the run stops paying for
# doomed calls, prints the unevaluated set once, and exits 1 with a runnable retry line.
# A permission refusal (class 5) aborts with the required App permission. A repo name is
# DATA: it travels in the environment/allow-list, never inside a command's text.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=scripts/lib-org.sh
. "$HERE/lib-org.sh"

readonly SPEC="$ROOT/labels/taxonomy.json"
readonly RULES="$ROOT/labels/category-rules.json"
readonly USED="$ROOT/labels/cold-reader-used.json"

die()  { printf 'labels: FAIL — %s\n' "$*" >&2; exit 1; }
warn() { printf 'labels: %s\n' "$*" >&2; }
say()  { printf '%s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

validate_spec() {
  need jq
  need gh
  jq -e . "$SPEC" >/dev/null 2>&1 || die "taxonomy.json is not valid JSON"
  jq -e . "$RULES" >/dev/null 2>&1 || die "category-rules.json is not valid JSON"
  local n bad dup
  n="$(jq -r '.labels | length' "$SPEC")"
  [[ "$n" == "12" ]] || die "taxonomy.json must define exactly 12 labels (found $n)"
  bad="$(jq -r '.labels[] | select((.description | length) > 100) | .name' "$SPEC")"
  [[ -z "$bad" ]] || die "label description over GitHub's 100-char limit: $bad"
  dup="$(jq -r '.labels[].name' "$SPEC" | sort | uniq -d)"
  [[ -z "$dup" ]] || die "duplicate label name: $dup"
  for a in category type; do
    [[ "$(jq -r --arg a "$a" '[.labels[] | select(.axis == $a)] | length' "$SPEC")" == "6" ]] \
      || die "axis '$a' must have exactly 6 values"
  done
}

# gh_call <outvar> <gh args...> — run gh, capture stdout; return 0 on success, else the
# api_error_class (3 = absent, 4 = quota, 5 = permission, 1 = other). The class names the
# cause once; every verb owns its bookkeeping.
gh_call() {
  local __outvar="$1"; shift
  local __err __out __rc __cls
  __err="$(mktemp)"
  __out="$(gh "$@" 2>"$__err")"; __rc=$?
  if [[ $__rc -eq 0 ]]; then rm -f "$__err"; printf -v "$__outvar" '%s' "$__out"; return 0; fi
  api_error_class "$__err"; __cls=$?
  [[ "$__cls" == "1" || "$__cls" == "5" ]] && cat "$__err" >&2
  rm -f "$__err"
  return "$__cls"
}

# handle_api_class <verb> <repo> <rc> — the ONE quota/permission/absent policy for
# every read and write. 4 = quota (the caller stops and prints the retry set);
# 5 = permission (abort with the required permission); 3 = absent; 1 = other.
# The cause is named ONCE; the caller owns the bookkeeping.
handle_api_class() {
  local verb="$1" repo="$2" rc="$3"
  case "$rc" in
    4) warn "API RATE LIMITED at $repo — every later repo is NOT evaluated"; return 4 ;;
    5) die "$verb: permission denied at $repo — the token needs issues: write" ;;
    3) warn "$verb: absent: $repo"; return 3 ;;
    *) warn "$verb: request failed: $repo"; return 1 ;;
  esac
}

# split_item <owner/repo#N> — sets ITEM_REPO and ITEM_NUM.
split_item() {
  local raw="${1:-}"
  [[ "$raw" == *#* ]] || die "malformed item '$raw' — want owner/repo#N"
  ITEM_REPO="${raw%%#*}"; ITEM_REPO="${ITEM_REPO##*/}"
  ITEM_NUM="${raw##*#}"
  [[ -n "$ITEM_REPO" && "$ITEM_NUM" =~ ^[0-9]+$ ]] || die "malformed item '$raw'"
}

# active_repos [allow-list] — every non-archived repo (forks included), filtered by the
# space/comma allow-list. Archived repos are read-only and cannot be written.
active_repos() {
  local allow="${1:-}" rows
  rows="$(discover_all)" || return 1
  printf '%s\n' "$rows" | awk -F'\t' '$2 == "false" { print $1 }' | sort | select_repos "$allow"
}

spec_labels_tsv() { jq -r '.labels[] | [.name, .axis, .color, .description] | @tsv' "$SPEC"; }
spec_names()     { jq -r '.labels[].name' "$SPEC"; }
spec_axis_names(){ jq -r --arg a "$1" '.labels[] | select(.axis == $a) | .name' "$SPEC"; }
retired_tsv()    { jq -r '.retired[] | [.name, (.replacement // ""), .reason] | @tsv' "$SPEC"; }
forbidden_values(){ jq -r '.forbidden_values[]' "$SPEC"; }

valid_axis_value() {
  local axis="$1" value="$2"
  printf '%s\n' "$(spec_axis_names "$axis")" | grep -qxF "$value"
}

# map_path_category <path> — the first matching generic path rule, or nothing. The
# repository name is NOT an input: every category is available in every repository.
map_path_category() {
  local path="$1" g c
  while IFS=$'\t' read -r g c; do
    [[ -z "$g" ]] && continue
    # shellcheck disable=SC2053
    if [[ "$path" == $g ]]; then printf '%s\n' "$c"; return 0; fi
  done < <(jq -r '.path_rules[] | [.glob, .category] | @tsv' "$RULES")
}

# action_hits <body> — the generic keyword categories the body matches, one per line.
action_hits() {
  local body="$1" cat kw
  while IFS=$'\t' read -r cat kw; do
    [[ -z "$cat" ]] && continue
    if grep -qiF -- "$kw" <<<"$body"; then printf '%s\n' "$cat"; fi
  done < <(jq -r '.action_keywords | to_entries[] | .key as $c | .value[] | [$c, .] | @tsv' "$RULES") | sort -u
}

# extract_paths <text> — the path-like tokens the issue says the remedy will touch.
extract_paths() {
  grep -oE '`[^`]+`|[A-Za-z0-9_.-]+/[A-Za-z0-9_./*-]+|[A-Za-z0-9_.-]+\.(go|cue|md|ya?ml|sh|ts|mjs|py|json)|Containerfile[^[:space:]]*' <<<"$1" \
    | tr -d '`' \
    | sed -E 's/[),.;:]+$//' \
    | grep -vE '#|^[a-z]+://|^\.\.\.$|^[0-9]+$' \
    | sort -u
}

# propose_category <body> — one category, or ? when the evidence is split/absent.
# Paths first; only when no path decides, the generic action keywords. The repository
# name is NEVER consulted, so a new or future repository needs no rule change.
propose_category() {
  local body="$1" p c uniq actions
  local -a cats=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    c="$(map_path_category "$p")"
    [[ -n "$c" ]] && cats+=("$c")
  done < <(extract_paths "$body")
  if [[ ${#cats[@]} -gt 0 ]]; then
    uniq="$(printf '%s\n' "${cats[@]}" | sort -u)"
    if [[ "$(printf '%s\n' "$uniq" | wc -l)" -eq 1 ]]; then printf '%s\n' "$uniq"; return 0; fi
    printf '?\n'; return 0
  fi
  actions="$(action_hits "$body")"
  if [[ -n "$actions" ]]; then
    if [[ "$(printf '%s\n' "$actions" | wc -l)" -eq 1 ]]; then printf '%s\n' "$actions"; return 0; fi
  fi
  printf '?\n'
}

# propose_type <repo> <body> — the mechanical type signals, or ? when nothing decides.
propose_type() {
  local body="$1" paths="$2" p all_prose=1 all_spec=1
  if [[ -z "$paths" ]]; then all_prose=0; all_spec=0; fi
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ "$p" != *.md && "$p" != .agents/skills/* && "$p" != */.agents/skills/* && "$p" != docs/* && "$p" != marketplace/* ]]; then all_prose=0; fi
    if [[ "$p" != spec/schema/* ]]; then all_spec=0; fi
  done <<<"$paths"
  if grep -qiE 'DESIGN\.(md|cue)|design/|Amend DESIGN|DESIGN decision|D-[A-Z]+-[0-9]+' <<<"$body" \
     && grep -qiE 'amend|add|decision|change' <<<"$body" \
     && ! grep -qiE 'violat|conform|implement' <<<"$body"; then printf 'design\n'; return 0; fi
  if [[ "$all_prose" -eq 1 && -n "$paths" ]]; then
    if grep -qiE 'contradict|violat|stale|wrong|incorrect|does not match|disagree' <<<"$body" \
       && grep -qiE 'AGENTS|DESIGN|schema' <<<"$body"; then printf 'fix\n'; return 0; fi
    printf 'docs\n'; return 0
  fi
  if [[ "$all_spec" -eq 1 && -n "$paths" ]]; then printf 'spec\n'; return 0; fi
  if grep -qiE 'golangci|lint|go mod|pin|deps?|dependency|cleanup|refactor|dead code|typo' <<<"$body" \
     && ! grep -qiE 'FAIL|error:|fails|regression|broken|exit [1-9]|violat' <<<"$body"; then printf 'chore\n'; return 0; fi
  if grep -qiE 'FAIL|error:|fails|failed|regression|broken|exit [1-9]|violat|silently|missing|not found|crash|panic' <<<"$body"; then
    printf 'fix\n'; return 0
  fi
  if grep -qiE 'add|support|implement|new |introduce|feature|enable' <<<"$body"; then printf 'feat\n'; return 0; fi
  printf '?\n'
}

# form_value <body> <heading> — the strict first value after `### <heading>`; empty if
# absent. The issue form is the source; free text is never read as an answer.
form_value() {
  awk -v h="### $2" '
    $0 == h { getline; while ($0 ~ /^[[:space:]]*$/) getline; print; exit }
  ' <<<"$1"
}

# ---------------------------------------------------------------------------
# sync — create/update the 12 labels in every selected non-archived repo.
# ---------------------------------------------------------------------------
cmd_sync() {
  local dry=0 allow="" repo rc out out2 name axis color desc found ecolor edesc
  local created=0 updated=0 unchanged=0 failed=0
  local -a L_FAILED=() L_UNEVAL=()
  local RATE_LIMITED=0
  while (($#)); do
    case "$1" in
      --org) ;;
      --repo)  shift; [[ $# -gt 0 ]] || die "--repo needs a value"; allow+=" $1" ;;
      --repos) shift; [[ $# -gt 0 ]] || die "--repos needs a value"; allow+=" $1" ;;
      --dry-run) dry=1 ;;
      *) die "sync: unknown flag '$1'" ;;
    esac
    shift
  done
  local rows
  rows="$(active_repos "$allow")" || die "sync: repo discovery failed"
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    if [[ $RATE_LIMITED -eq 1 ]]; then L_UNEVAL+=("$repo"); continue; fi
    gh_call out api --paginate "repos/$ORG/$repo/labels?per_page=100" --jq '.[] | [.name, .color, .description] | @tsv'
    rc=$?
    case $rc in
      0) ;;
      4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); warn "API RATE LIMITED at $repo — every later repo is NOT evaluated"; continue ;;
      5) die "sync: permission denied at $repo — the token needs issues: write" ;;
      *) failed=$((failed + 1)); L_FAILED+=("$repo"); warn "labels unreadable: $repo"; continue ;;
    esac
    while IFS=$'\t' read -r name axis color desc; do
      [[ -z "$name" ]] && continue
      found="$(printf '%s\n' "$out" | awk -F'\t' -v n="$name" '$1 == n { print; exit }')"
      if [[ -z "$found" ]]; then
        if [[ $dry -eq 1 ]]; then
          say "PLAN CREATE $repo $name"
        else
          gh_call out2 label create "$name" -R "$ORG/$repo" --color "$color" --description "$desc"; rc=$?
          case $rc in
            0) created=$((created + 1)) ;;
            5) die "sync: permission denied creating $name in $repo — the token needs issues: write" ;;
            4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); warn "API RATE LIMITED creating $name in $repo"; break ;;
            *) failed=$((failed + 1)); L_FAILED+=("$repo"); warn "label create failed: $repo $name"; break ;;
          esac
        fi
      else
        ecolor="$(cut -f2 <<<"$found")"
        edesc="$(cut -f3- <<<"$found")"
        if [[ "$ecolor" != "$color" || "$edesc" != "$desc" ]]; then
          if [[ $dry -eq 1 ]]; then
            say "PLAN UPDATE $repo $name"
          else
            gh_call out2 label edit "$name" -R "$ORG/$repo" --color "$color" --description "$desc"; rc=$?
            case $rc in
              0) updated=$((updated + 1)) ;;
              5) die "sync: permission denied editing $name in $repo — the token needs issues: write" ;;
              4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); warn "API RATE LIMITED editing $name in $repo"; break ;;
              *) failed=$((failed + 1)); L_FAILED+=("$repo"); warn "label edit failed: $repo $name"; break ;;
            esac
          fi
        else
          unchanged=$((unchanged + 1))
        fi
      fi
    done < <(spec_labels_tsv)
  done <<<"$rows"
  say "sync: mode=$([[ $dry -eq 1 ]] && echo plan || echo apply) created=$created updated=$updated unchanged=$unchanged failed=$failed"
  [[ ${#L_FAILED[@]} -gt 0 ]] && say "  FAILED: ${L_FAILED[*]}"
  if [[ ${#L_UNEVAL[@]} -gt 0 ]]; then
    say "  NOT EVALUATED (${#L_UNEVAL[@]}): ${L_UNEVAL[*]}"
    say "  retry with : LABELS_REPOS=\"${L_UNEVAL[*]}\" bash scripts/labels.sh sync"
    exit 1
  fi
  [[ $failed -eq 0 ]] || exit 1
  return 0
}

# ---------------------------------------------------------------------------
# audit — report missing/multi/forbidden/unknown labels; optionally map form answers.
# ---------------------------------------------------------------------------
cmd_audit() {
  local state=open apply=0 strict=0 json=0 close_pass=0 ignore_retired=0 allow="" repo rc out out2 line cls
  local number title body l
  local issues=0 findings=0 missing=0 multi=0 forbidden=0 unknown_n=0 applied=0 failed=0
  while (($#)); do
    case "$1" in
      --org) ;;
      --repo)  shift; allow+=" ${1:-}" ;;
      --repos) shift; allow+=" ${1:-}" ;;
      --state) shift; state="${1:-open}" ;;
      --apply) apply=1 ;;
      --strict) strict=1 ;;
      --json) json=1 ;;
      --close-pass) close_pass=1 ;;
      --ignore-retired) ignore_retired=1 ;;
      *) die "audit: unknown flag '$1'" ;;
    esac
    shift
  done
  [[ "$state" =~ ^(open|closed|all)$ ]] || die "audit: --state must be open|closed|all"
  local rows
  rows="$(active_repos "$allow")" || die "audit: repo discovery failed"
  local RATE_LIMITED=0
  local -a L_UNEVAL=()
  local spec_all; spec_all="$(spec_names)"
  local forb; forb="$(forbidden_values)"
  local forb_prefixes; forb_prefixes="$(jq -r '.forbidden_prefixes[]' "$SPEC")"
  local retired_names; retired_names="$(jq -r '.retired[].name' "$SPEC")"
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    if [[ $RATE_LIMITED -eq 1 ]]; then L_UNEVAL+=("$repo"); continue; fi
    gh_call out api --paginate "repos/$ORG/$repo/issues?state=$state&per_page=100" \
      --jq '.[] | select(.pull_request == null) | {number, title, body, labels: [.labels[].name]} | @json'
    rc=$?
    case $rc in
      0) ;;
      4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); warn "API RATE LIMITED at $repo — every later repo is NOT evaluated"; continue ;;
      5) die "audit: permission denied at $repo — the token needs issues: read" ;;
      *) failed=$((failed + 1)); warn "issues unreadable: $repo"; continue ;;
    esac
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      issues=$((issues + 1))
      number="$(jq -r '.number' <<<"$line")"
      title="$(jq -r '.title' <<<"$line")"
      body="$(jq -r '.body // ""' <<<"$line")"
      local -a cats=() types=() unknown=() bad=()
      while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        local pref hit=0
        while IFS= read -r pref; do
          [[ -z "$pref" ]] && continue
          if [[ "$l" == "$pref"* ]]; then hit=1; break; fi
        done <<<"$forb_prefixes"
        if [[ $hit -eq 1 ]]; then bad+=("$l"); continue; fi
        if printf '%s\n' "$forb" | grep -qxF "$l"; then bad+=("$l"); continue; fi
        case "$l" in
          category:*) cats+=("$l") ;;
          type:*) types+=("$l") ;;
          *)
            if printf '%s\n' "$retired_names" | grep -qxF "$l"; then
              [[ $ignore_retired -eq 1 ]] || unknown+=("$l")
            elif ! printf '%s\n' "$spec_all" | grep -qxF "$l"; then
              unknown+=("$l")
            fi ;;
        esac
      done < <(jq -r '.labels[]?' <<<"$line")
      if [[ $apply -eq 1 ]]; then
        if [[ ${#cats[@]} -eq 0 ]]; then
          local v; v="$(form_value "$body" Category)"
          if [[ -n "$v" ]] && valid_axis_value category "$v"; then
            gh_call out2 issue edit "$number" -R "$ORG/$repo" --add-label "$v"; rc=$?
            case $rc in
              0) cats+=("$v"); applied=$((applied + 1)) ;;
              5) die "audit: permission denied at $repo#$number — the token needs issues: write" ;;
              4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); warn "API RATE LIMITED applying $v at $repo#$number"; break ;;
              *) failed=$((failed + 1)); warn "apply failed: $repo#$number $v" ;;
            esac
          fi
        fi
        if [[ ${#types[@]} -eq 0 ]]; then
          local v; v="$(form_value "$body" Type)"
          if [[ -n "$v" ]] && valid_axis_value type "$v"; then
            gh_call out2 issue edit "$number" -R "$ORG/$repo" --add-label "$v"; rc=$?
            case $rc in
              0) types+=("$v"); applied=$((applied + 1)) ;;
              5) die "audit: permission denied at $repo#$number — the token needs issues: write" ;;
              4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); warn "API RATE LIMITED applying $v at $repo#$number"; break ;;
              *) failed=$((failed + 1)); warn "apply failed: $repo#$number $v" ;;
            esac
          fi
        fi
      fi
      local miss=0 mult=0
      [[ ${#cats[@]} -eq 0 ]] && miss=$((miss + 1))
      [[ ${#cats[@]} -gt 1 ]] && mult=$((mult + 1))
      [[ ${#types[@]} -eq 0 ]] && miss=$((miss + 1))
      [[ ${#types[@]} -gt 1 ]] && mult=$((mult + 1))
      if [[ $miss -gt 0 || $mult -gt 0 || ${#bad[@]} -gt 0 || ${#unknown[@]} -gt 0 ]]; then
        findings=$((findings + 1))
        [[ $miss -gt 0 ]] && missing=$((missing + 1))
        [[ $mult -gt 0 ]] && multi=$((multi + 1))
        [[ ${#bad[@]} -gt 0 ]] && forbidden=$((forbidden + 1))
        [[ ${#unknown[@]} -gt 0 ]] && unknown_n=$((unknown_n + 1))
        if [[ $json -eq 1 ]]; then
          jq -cn --arg repo "$ORG/$repo" --argjson issue "$number" --arg title "$title" \
            --argjson missing_axes "$miss" --argjson multi_axes "$mult" \
            --argjson categories "$(printf '%s\n' "${cats[@]}" | jq -R . | jq -s 'map(select(. != ""))')" \
            --argjson types "$(printf '%s\n' "${types[@]}" | jq -R . | jq -s 'map(select(. != ""))')" \
            --argjson forbidden "$(printf '%s\n' "${bad[@]}" | jq -R . | jq -s 'map(select(. != ""))')" \
            --argjson unknown "$(printf '%s\n' "${unknown[@]}" | jq -R . | jq -s 'map(select(. != ""))')" \
            '{repo:$repo, issue:$issue, title:$title, missing_axes:$missing_axes, multi_axes:$multi_axes, categories:$categories, types:$types, forbidden:$forbidden, unknown:$unknown}'
        else
          say "FINDING $ORG/$repo#$number missing=$miss multi=$mult forbidden=${bad[*]:-} unknown=${unknown[*]:-} — $title"
        fi
      fi
    done <<<"$out"
  done <<<"$rows"
  if [[ $close_pass -eq 1 ]]; then
    local merged cutoff vrc
    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      if [[ $RATE_LIMITED -eq 1 ]]; then L_UNEVAL+=("$repo"); continue; fi
      gh_call merged api --paginate "repos/$ORG/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
        --jq '.[] | select(.merged_at != null) | [.number, .merged_at, .title, .body] | @tsv'; rc=$?
      if [[ $rc -ne 0 ]]; then
        handle_api_class audit "$repo" "$rc"; cls=$?
        [[ $cls -eq 4 ]] && { RATE_LIMITED=1; L_UNEVAL+=("$repo"); break; }
        continue
      fi
      cutoff="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
      while IFS=$'\t' read -r pnum pmerged ptitle pbody; do
        [[ -z "$pnum" || "$pmerged" < "$cutoff" ]] && continue
        while IFS= read -r closes; do
          [[ -z "$closes" ]] && continue
          local inum="${closes##*#}"
          verify_close_one "$ORG/$repo#$pnum" "$ORG/$repo#$inum"; vrc=$?
          case $vrc in
            0) ;;
            4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); break 2 ;;
            *)
              findings=$((findings + 1))
              [[ $json -eq 1 ]] && jq -cn --arg pr "$ORG/$repo#$pnum" --arg issue "$ORG/$repo#$inum" '{repo:($pr|split("#")[0]), pr:($pr|split("#")[1]|tonumber), issue:($issue|split("#")[1]|tonumber), kind:"close-mismatch"}' ;;
          esac
        done < <(grep -oiE '(closes|fixes|resolves)[[:space:]]+#[0-9]+' <<<"$pbody" | grep -oE '#[0-9]+' | tr -d '#')
      done <<<"$merged"
    done <<<"$rows"
  fi
  say "audit: repos=$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l) issues=$issues findings=$findings missing=$missing multi=$multi forbidden=$forbidden unknown=$unknown_n applied=$applied failed=$failed"
  [[ ${#L_UNEVAL[@]} -gt 0 ]] && { say "  NOT EVALUATED (${#L_UNEVAL[@]}): ${L_UNEVAL[*]}"; say "  retry with : LABELS_REPOS=\"${L_UNEVAL[*]}\" bash scripts/labels.sh audit --state $state"; exit 1; }
  [[ $failed -eq 0 ]] || exit 1
  [[ $strict -eq 1 && $findings -gt 0 ]] && exit 1
  return 0
}

# ---------------------------------------------------------------------------
# classify — propose category/type per open issue, with evidence. Never applies.
# ---------------------------------------------------------------------------
cmd_classify() {
  local state=open allow="" out_file="-" repo rc out line number title body cls
  while (($#)); do
    case "$1" in
      --org) ;;
      --repo)  shift; allow+=" ${1:-}" ;;
      --repos) shift; allow+=" ${1:-}" ;;
      --state) shift; state="${1:-open}" ;;
      --out) shift; out_file="${1:--}" ;;
      *) die "classify: unknown flag '$1'" ;;
    esac
    shift
  done
  local rows; rows="$(active_repos "$allow")" || die "classify: repo discovery failed"
  local tmp; tmp="$(mktemp)"
  printf 'repo\tissue\tcategory\ttype\tconfidence\tevidence\ttitle\n' > "$tmp"
  local RATE_LIMITED=0
  local -a L_UNEVAL=()
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    if [[ $RATE_LIMITED -eq 1 ]]; then L_UNEVAL+=("$repo"); continue; fi
    gh_call out api --paginate "repos/$ORG/$repo/issues?state=$state&per_page=100" \
      --jq '.[] | select(.pull_request == null) | {number, title, body} | @json'
    rc=$?
    if [[ $rc -ne 0 ]]; then
      handle_api_class classify "$repo" "$rc"; cls=$?
      case $cls in
        4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); continue ;;
        *) continue ;;
      esac
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      number="$(jq -r '.number' <<<"$line")"
      title="$(jq -r '.title' <<<"$line")"
      body="$(jq -r '.body // ""' <<<"$line")"
      local paths cat typ conf ev p cat_lab typ_lab
      paths="$(extract_paths "$body")"
      cat="$(propose_category "$body")"
      typ="$(propose_type "$body" "$paths")"
      cat_lab="$cat"; [[ "$cat" != "?" ]] && cat_lab="category:$cat"
      typ_lab="$typ"; [[ "$typ" != "?" ]] && typ_lab="type:$typ"
      ev="paths=$(printf '%s' "$paths" | tr '\n' ',' | sed 's/,$//'); actions=$(action_hits "$body" | tr '\n' ',' | sed 's/,$//')"
      if [[ "$cat" != "?" && "$typ" != "?" ]]; then conf=high; elif [[ "$cat" != "?" || "$typ" != "?" ]]; then conf=medium; else conf=low; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$number" "$cat_lab" "$typ_lab" "$conf" "$ev" "$title" >> "$tmp"
    done <<<"$out"
  done <<<"$rows"
  if [[ ${#L_UNEVAL[@]} -gt 0 ]]; then
    rm -f "$tmp"
    say "classify: NOT EVALUATED (${#L_UNEVAL[@]}): ${L_UNEVAL[*]}"
    say "  retry with : LABELS_REPOS=\"${L_UNEVAL[*]}\" bash scripts/labels.sh classify --state $state"
    exit 1
  fi
  if [[ "$out_file" == "-" ]]; then cat "$tmp"; else cp "$tmp" "$out_file"; say "classify: wrote $out_file"; fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# apply — add the reviewed labels from a classify TSV. Idempotent; skips ?.
# ---------------------------------------------------------------------------
cmd_apply() {
  local from="" dry=0
  while (($#)); do
    case "$1" in
      --from) shift; from="${1:-}" ;;
      --dry-run) dry=1 ;;
      *) die "apply: unknown flag '$1'" ;;
    esac
    shift
  done
  [[ -n "$from" && -f "$from" ]] || die "apply: --from FILE is required"
  local applied=0 skipped=0 failed=0 repo issue cat typ rc
  while IFS=$'\t' read -r repo issue cat typ _; do
    [[ "$repo" == "repo" || -z "$repo" ]] && continue
    if [[ "$cat" == "?" || "$typ" == "?" || -z "$cat" || -z "$typ" ]]; then
      skipped=$((skipped + 1)); continue
    fi
    if ! valid_axis_value category "$cat" || ! valid_axis_value type "$typ"; then
      warn "apply: not a taxonomy value: $repo#$issue $cat $typ"; failed=$((failed + 1)); continue
    fi
    if [[ $dry -eq 1 ]]; then
      say "PLAN $repo#$issue $cat $typ"
    else
      gh_call out issue edit "$issue" -R "$ORG/$repo" --add-label "$cat" --add-label "$typ"; rc=$?
      case $rc in
        0) applied=$((applied + 1)) ;;
        5) die "apply: permission denied at $repo#$issue — the token needs issues: write" ;;
        4) warn "API RATE LIMITED at $repo#$issue — the quota is exhausted; stop and retry this set"; exit 1 ;;
        *) failed=$((failed + 1)); warn "apply failed: $repo#$issue" ;;
      esac
    fi
  done < "$from"
  say "apply: applied=$applied skipped=$skipped failed=$failed"
  [[ $failed -eq 0 ]] || exit 1
}

# ---------------------------------------------------------------------------
# retire — snapshot, then delete the retired labels (after the backfill).
# ---------------------------------------------------------------------------
cmd_retire() {
  local allow="" after=0 snapshot="${TMPDIR:-/tmp}/opencharly-labels-retired-snapshot.tsv" dry=0 repo rc out name repl reason cls
  local deleted=0 absent=0 failed=0 carries=0
  while (($#)); do
    case "$1" in
      --org) ;;
      --repo)  shift; allow+=" ${1:-}" ;;
      --repos) shift; allow+=" ${1:-}" ;;
      --after-backfill) after=1 ;;
      --snapshot-out) shift; snapshot="${1:-$snapshot}" ;;
      --dry-run) dry=1 ;;
      *) die "retire: unknown flag '$1'" ;;
    esac
    shift
  done
  if [[ $after -eq 1 ]]; then
    if ! ( cmd_audit --org --state open --strict --ignore-retired ) >/dev/null 2>&1; then
      die "retire: audit still reports findings — finish the backfill (no fallback label exists)"
    fi
  fi
  local rows; rows="$(active_repos "$allow")" || die "retire: repo discovery failed"
  printf 'repo\tname\tcolor\tdescription\n' > "$snapshot"
  local RATE_LIMITED=0
  local -a L_UNEVAL=()
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    if [[ $RATE_LIMITED -eq 1 ]]; then L_UNEVAL+=("$repo"); continue; fi
    gh_call out api --paginate "repos/$ORG/$repo/labels?per_page=100" --jq '.[] | [.name, .color, .description] | @tsv'
    rc=$?
    case $rc in
      0) ;;
      4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); warn "API RATE LIMITED at $repo — later repos NOT evaluated"; continue ;;
      5) die "retire: permission denied at $repo — the token needs issues: write" ;;
      *) failed=$((failed + 1)); warn "labels unreadable: $repo"; continue ;;
    esac
    while IFS=$'\t' read -r name color desc; do
      printf '%s\t%s\t%s\t%s\n' "$repo" "$name" "$color" "$desc" >> "$snapshot"
    done <<<"$out"
    while IFS=$'\t' read -r name repl reason; do
      [[ -z "$name" ]] && continue
      if ! printf '%s\n' "$out" | cut -f1 | grep -qxF "$name"; then absent=$((absent + 1)); continue; fi
      local count=""
      gh_call cnt issue list -R "$ORG/$repo" --label "$name" --state open --limit 1000 --json number --jq 'length' 2>/dev/null; rc=$?
      if [[ $rc -ne 0 ]]; then
        handle_api_class retire "$repo" "$rc"; cls=$?
        case $cls in
          4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); break 2 ;;
          *) count=0 ;;
        esac
      else
        count="$cnt"
      fi
      if [[ -n "$count" ]]; then carries=$((carries + count)); fi
      if [[ $dry -eq 1 ]]; then
        say "PLAN DELETE $repo $name (open issues carrying it: ${count:-?})"
      else
        gh_call out2 label delete "$name" -R "$ORG/$repo" --yes; rc=$?
        case $rc in
          0) deleted=$((deleted + 1)) ;;
          3) absent=$((absent + 1)) ;;
          5) die "retire: permission denied deleting $name in $repo — the token needs issues: write" ;;
          4) RATE_LIMITED=1; L_UNEVAL+=("$repo"); warn "API RATE LIMITED deleting $name in $repo"; break ;;
          *) failed=$((failed + 1)); warn "delete failed: $repo $name" ;;
        esac
      fi
    done < <(retired_tsv)
  done <<<"$rows"
  say "retire: mode=$([[ $dry -eq 1 ]] && echo plan || echo apply) deleted=$deleted absent=$absent open_carriers=$carries failed=$failed snapshot=$snapshot"
  [[ ${#L_UNEVAL[@]} -gt 0 ]] && { say "  NOT EVALUATED (${#L_UNEVAL[@]}): ${L_UNEVAL[*]}"; say "  retry with : LABELS_REPOS=\"${L_UNEVAL[*]}\" bash scripts/labels.sh retire --dry-run"; exit 1; }
  [[ $failed -eq 0 ]] || exit 1
}

# ---------------------------------------------------------------------------
# render — emit the org issue form from the spec. No static fallback labels.
# ---------------------------------------------------------------------------
cmd_render() {
  local out="$ROOT/.github/ISSUE_TEMPLATE/issue.yml"
  while (($#)); do
    case "$1" in
      --out) shift; out="${1:-}" ;;
      *) die "render: unknown flag '$1'" ;;
    esac
    shift
  done
  mkdir -p "$(dirname "$out")"
  {
    printf 'name: Issue\n'
    printf 'description: File an org-wide issue with exactly one category and one type.\n'
    printf 'title: "[issue] "\n'
    printf 'labels: []\n'
    printf 'body:\n'
    printf '  - type: markdown\n'
    printf '    attributes:\n'
    printf '      value: |\n'
    printf '        Every issue carries exactly one category and one type. There is no fallback: if the evidence does not decide, improve the issue or split it.\n'
    printf '  - type: dropdown\n'
    printf '    id: category\n'
    printf '    attributes:\n'
    printf '      label: Category\n'
    printf '      description: The work category; exactly one.\n'
    printf '      options:\n'
    jq -r '.issue_form.category_values[] | "        - " + .' "$SPEC"
    printf '    validations:\n'
    printf '      required: true\n'
    printf '  - type: dropdown\n'
    printf '    id: type\n'
    printf '    attributes:\n'
    printf '      label: Type\n'
    printf '      description: The remedy class; exactly one.\n'
    printf '      options:\n'
    jq -r '.issue_form.type_values[] | "        - " + .' "$SPEC"
    printf '    validations:\n'
    printf '      required: true\n'
    printf '  - type: textarea\n'
    printf '    id: remedy\n'
    printf '    attributes:\n'
    printf '      label: Remedy / files the remedy will touch\n'
    printf '      description: The primary action and the paths; the classifier uses these.\n'
    printf '    validations:\n'
    printf '      required: true\n'
    printf '  - type: input\n'
    printf '    id: cited\n'
    printf '    attributes:\n'
    printf '      label: Cited DESIGN D-id or AGENTS.md rule (or none)\n'
    printf '      description: For a violation, name the D-id or rule; otherwise write none.\n'
    printf '    validations:\n'
    printf '      required: true\n'
  } > "$out"
  say "render: wrote $out"
}

# ---------------------------------------------------------------------------
# verify-close — compare a merged PR to the issue it closes.
# ---------------------------------------------------------------------------
verify_close_one() {
  local pr_item="$1" issue_item="$2" pr_repo pr_num is_repo is_num
  split_item "$pr_item"; pr_repo="$ITEM_REPO"; pr_num="$ITEM_NUM"
  split_item "$issue_item"; is_repo="$ITEM_REPO"; is_num="$ITEM_NUM"
  local pr issue rc cls
  gh_call pr pr view "$pr_num" -R "$ORG/$pr_repo" --json title,body,files \
    --jq '{title, body, files: [.files[].path]}'; rc=$?
  if [[ $rc -ne 0 ]]; then
    handle_api_class audit "$pr_repo" "$rc"; cls=$?
    [[ $cls -eq 4 ]] && return 4
    return 1
  fi
  gh_call issue issue view "$is_num" -R "$ORG/$is_repo" --json title,body,labels \
    --jq '{title, body, labels: [.labels[].name]}'; rc=$?
  if [[ $rc -ne 0 ]]; then
    handle_api_class audit "$is_repo" "$rc"; cls=$?
    [[ $cls -eq 4 ]] && return 4
    return 1
  fi
  local icat itype ititle ptitle
  icat="$(jq -r '[.labels[] | select(startswith("category:"))] | if length == 1 then .[0] else "" end' <<<"$issue")"
  itype="$(jq -r '[.labels[] | select(startswith("type:"))] | if length == 1 then .[0] else "" end' <<<"$issue")"
  ititle="$(jq -r '.title' <<<"$issue")"
  ptitle="$(jq -r '.title' <<<"$pr")"
  local -a cats=() p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    local c; c="$(map_path_category "$p")"
    [[ -n "$c" ]] && cats+=("$c")
  done < <(jq -r '.files[]' <<<"$pr")
  local bad=0
  if [[ -z "$icat" || -z "$itype" ]]; then
    say "MISMATCH $issue_item — the issue must carry exactly one category and one type (has '$icat' / '$itype')"
    bad=1
  fi
  if [[ -n "$icat" && ${#cats[@]} -gt 0 ]]; then
    if ! printf '%s\n' "${cats[@]}" | grep -qxF "$icat"; then
      say "MISMATCH $pr_item closes $issue_item — PR paths map to ${cats[*]}, issue says $icat"
      bad=1
    fi
  fi
  local expect=""
  case "$itype" in
    type:fix)   expect='fix' ;;
    type:feat)  expect='feat' ;;
    type:docs)  expect='docs' ;;
    type:chore) expect='chore|ci|refactor|test' ;;
    type:design) expect='design|docs|feat|fix' ;;
    type:spec)   expect='spec|fix|feat|refactor' ;;
  esac
  local ptype; ptype="$(sed -nE 's/^([a-z]+)(\([^)]*\))?!?:.*/\1/p' <<<"$ptitle" | head -1)"
  if [[ -n "$expect" && -n "$ptype" ]] && ! grep -qE "^($expect)$" <<<"$ptype"; then
    say "MISMATCH $pr_item — PR subject type '$ptype' does not match issue type '$itype'"
    bad=1
  fi
  [[ $bad -eq 0 ]]
}

cmd_verify_close() {
  [[ $# -eq 2 ]] || die "verify-close takes <owner/repo#pr> <owner/repo#issue>"
  verify_close_one "$1" "$2"
}

# ---------------------------------------------------------------------------
# sample — draw N unused issues for a held-out cold-reader round; record the ids.
# ---------------------------------------------------------------------------
cmd_sample() {
  local n=20 out="" record=0 set_name="" revision="unreleased" from_fixture=""
  while (($#)); do
    case "$1" in
      --n) shift; n="${1:-20}" ;;
      --out) shift; out="${1:-}" ;;
      --record) record=1 ;;
      --set) shift; set_name="${1:-}" ;;
      --revision) shift; revision="${1:-unreleased}" ;;
      --from) shift; from_fixture="${1:-}" ;;
      *) die "sample: unknown flag '$1'" ;;
    esac
    shift
  done
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || die "sample: --n must be a positive integer"
  [[ -f "$USED" ]] || die "sample: missing $USED"
  local used_tmp; used_tmp="$(mktemp)"
  jq -r '.used[]' "$USED" > "$used_tmp"
  # --from records the fixture that was ACTUALLY read by the cold reader. A later
  # --record redraw can differ when the live census changed between the two draws
  # (measured: a new issue displaced one in distro-cachyos), which would record a set
  # nobody tested. The tested fixture is the authority.
  if [[ -n "$from_fixture" ]]; then
    [[ -f "$from_fixture" ]] || die "sample --from: no such fixture: $from_fixture"
    local -a tested=()
    local line item
    while IFS= read -r line; do
      [[ "$line" == '=== '* ]] && tested+=("${line#=== }")
    done < "$from_fixture"
    [[ ${#tested[@]} -gt 0 ]] || die "sample --from: no '=== repo#N' headers in $from_fixture"
    for item in "${tested[@]}"; do
      split_item "$item"
      if grep -qxF "$item" "$used_tmp"; then die "sample --from: $item is already used"; fi
    done
    if [[ $record -eq 0 ]]; then printf '%s\n' "${tested[@]}"; rm -f "$used_tmp"; return 0; fi
    [[ -n "$set_name" ]] || set_name="$(date -u +%Y%m%dT%H%M%SZ)"
    local ids_json; ids_json="$(printf '%s\n' "${tested[@]}" | jq -R . | jq -s .)"
    local tmp; tmp="$(mktemp)"
    jq --argjson ids "$ids_json" --arg set "$set_name" --arg rev "$revision" \
      '.used = ((.used + $ids) | unique | sort) | .rounds += [{set: $set, revision: $rev, issues: $ids}]' \
      "$USED" > "$tmp" && mv "$tmp" "$USED"
    say "sample: recorded the tested fixture set=$set_name revision=$revision ids=${#tested[@]}"
    rm -f "$used_tmp"
    return 0
  fi
  local rows; rows="$(active_repos "")" || die "sample: repo discovery failed"
  local repo rc out ids cls
  declare -A groups=()
  local -a order=()
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    gh_call ids api --paginate "repos/$ORG/$repo/issues?state=open&per_page=100" \
      --jq '.[] | select(.pull_request == null) | .number'; rc=$?
    if [[ $rc -ne 0 ]]; then
      handle_api_class sample "$repo" "$rc"; cls=$?
      if [[ $cls -eq 4 ]]; then rm -f "$used_tmp"; die "sample: API RATE LIMITED at $repo — retry after the quota resets"; fi
      continue
    fi
    while IFS= read -r inum; do
      [[ -z "$inum" ]] && continue
      local id="$ORG/$repo#$inum"
      grep -qxF "$id" "$used_tmp" && continue
      [[ -z "${groups[$repo]+x}" ]] && order+=("$repo")
      groups[$repo]+=" $id"
    done <<<"$ids"
  done <<<"$rows"
  local -a selected=()
  local i pass
  for pass in 1 2 3 4 5; do
    for repo in "${order[@]}"; do
      [[ ${#selected[@]} -ge $n ]] && break 2
      local -a list; read -ra list <<<"${groups[$repo]}"
      local idx=$((pass - 1))
      [[ $idx -lt ${#list[@]} ]] && selected+=("${list[$idx]}")
    done
  done
  [[ ${#selected[@]} -gt 0 ]] || die "sample: no unused open issues left"
  selected=("${selected[@]:0:$n}")
  [[ ${#selected[@]} -ge $n ]] || die "sample: cannot draw $n unused issues (got ${#selected[@]})"
  local fixture; fixture="$(mktemp)"
  local item
  for item in "${selected[@]}"; do
    split_item "$item"
    printf '=== %s/%s#%s\n' "$ORG" "$ITEM_REPO" "$ITEM_NUM" >> "$fixture"
    gh_call one issue view "$ITEM_NUM" -R "$ORG/$ITEM_REPO" --json number,title,body,url \
      --jq '"TITLE: \(.title)\nURL: \(.url)\nBODY: \(.body[0:1400])"'; rc=$?
    if [[ $rc -ne 0 ]]; then
      handle_api_class sample "$ITEM_REPO" "$rc"; cls=$?
      rm -f "$fixture" "$used_tmp"
      [[ $cls -eq 4 ]] && die "sample: API RATE LIMITED at $ITEM_REPO — retry after the quota resets"
      die "sample: cannot read $item"
    fi
    printf '%s\n\n' "$one" >> "$fixture"
  done
  if [[ -n "$out" ]]; then cp "$fixture" "$out"; say "sample: wrote $out (${#selected[@]} issues)"; else cat "$fixture"; fi
  rm -f "$fixture" "$used_tmp"
  if [[ $record -eq 1 ]]; then
    [[ -n "$set_name" ]] || set_name="$(date -u +%Y%m%dT%H%M%SZ)"
    local ids_json; ids_json="$(printf '%s\n' "${selected[@]}" | jq -R . | jq -s .)"
    local tmp; tmp="$(mktemp)"
    jq --argjson ids "$ids_json" --arg set "$set_name" --arg rev "$revision" \
      '.used = ((.used + $ids) | unique | sort) | .rounds += [{set: $set, revision: $rev, issues: $ids}]' \
      "$USED" > "$tmp" && mv "$tmp" "$USED"
    say "sample: recorded set=$set_name revision=$revision ids=${#selected[@]}"
  fi
}

# ---------------------------------------------------------------------------
# explain — print the evidence and the proposal for ONE issue.
# ---------------------------------------------------------------------------
cmd_explain() {
  [[ $# -eq 1 ]] || die "explain takes <owner/repo#issue>"
  split_item "$1"
  local item="$1" body title
  gh_call out issue view "$ITEM_NUM" -R "$ORG/$ITEM_REPO" --json number,title,body,labels \
    --jq '{title, body, labels: [.labels[].name]}' || die "explain: cannot read $item"
  title="$(jq -r '.title' <<<"$out")"
  body="$(jq -r '.body // ""' <<<"$out")"
  local paths cat typ
  paths="$(extract_paths "$body")"
  cat="$(propose_category "$body")"
  typ="$(propose_type "$body" "$paths")"
  say "issue:    $ORG/$ITEM_REPO#$ITEM_NUM — $title"
  say "labels:   $(jq -r '.labels | join(", ")' <<<"$out")"
  say "paths:    $(printf '%s' "$paths" | tr '\n' ' ')"
  say "actions:  $(action_hits "$body" | tr '\n' ' ')"
  say "category: $cat"
  say "type:     $typ"
  local p c
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    c="$(map_path_category "$p")"
    [[ -n "$c" ]] && say "  $p -> $c"
  done <<<"$paths"
}

usage() {
  sed -n '3,22p' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//'
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    sync) validate_spec; cmd_sync "$@" ;;
    audit) validate_spec; cmd_audit "$@" ;;
    classify) validate_spec; cmd_classify "$@" ;;
    apply) validate_spec; cmd_apply "$@" ;;
    retire) validate_spec; cmd_retire "$@" ;;
    render) validate_spec; cmd_render "$@" ;;
    verify-close) validate_spec; cmd_verify_close "$@" ;;
    sample) validate_spec; cmd_sample "$@" ;;
    explain) validate_spec; cmd_explain "$@" ;;
    -h|--help|help|"") usage; exit 0 ;;
    *) usage; die "unknown verb '$cmd'" ;;
  esac
}

main "$@"
