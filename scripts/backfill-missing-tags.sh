#!/usr/bin/env bash
# backfill-missing-tags.sh — tag every repo head that carries no tag and no excuse.
#
# WHY THIS EXISTS (opencharly/.github#294). The caller reconcile writes its commit
# straight to `main`, outside the merge path that mints a CalVer tag. Before #296 that
# left ~420 heads untagged and UNEXPLAINED — not the `docs: add CHANGELOG …` commit that
# `design-pintag` excuses — so every pin that advanced to one of those heads failed that
# control, and its census may only be LOWERED by the change that fixes it. #296 tags new
# writes; this tags the ones already written.
#
# ADD-ONLY, ALWAYS. It creates a tag at `refs/heads/main` when NO tag points there; it
# never moves, deletes or re-points an existing tag. An existing tag at the head means the
# repo is left entirely alone, which is also what makes a second run a no-op.
#
# THE FORM IS PER REPO, mirroring the reusable's tag-on-merge: a root Go module consumed
# through the proxy (sdk, spec, plugin-gh) is tagged in Go's form v0.<y><doy>.<hhmm>; every
# other repo gets the plain CalVer. A plain v<major> tag on a proxy-consumed module needs a
# /vN module path and no consumer could name it — that is worse than no tag.
#
# WHAT IT WILL NOT TOUCH. A repo with no tag-on-merge caller mints no releases
# (`caller-absent`), so tagging it would invent a release the repo never had. The source
# repo (opencharly/.github) is skipped for the same reason the reconcile skips it: its
# `.github/workflows/tag-on-merge.yml` is the reusable, and its own releases come from its
# own merges.
#
# Usage:
#   bash scripts/backfill-missing-tags.sh            check (READ-ONLY, default)
#   bash scripts/backfill-missing-tags.sh --apply    create the missing tags
#   RECONCILE_REPOS="a b" limits either mode to a named allow-list (space- or comma-separated)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-org.sh
. "$HERE/lib-org.sh"

CALLER_PATH=".github/workflows/tag-on-merge.yml"
MODE=check
case "${1:-}" in
  ""|check) MODE=check ;;
  --apply)  MODE=--apply ;;
  *) echo "usage: $0 [check|--apply]" >&2; exit 2 ;;
esac


# api_absent <args...> — run `gh api`; return 0 on success, 3 ONLY when the API says the
# thing does not exist, 4 when the API REFUSED us (the quota is exhausted), and the
# FAILURE CODE (1) for anything else. Without this an auth error, a rate limit or a network
# blip reads as "no tag exists", which in `--apply` would create a SECOND tag at an
# already-tagged head — the exact thing "add-only" forbids.
#
# WHY 4 IS ITS OWN CLASS (opencharly/.github#300). An exhausted quota is ONE cause, and it
# renders as N repo names when it is folded into the generic failure: measured on the fleet
# pass, 60 lines read `CALLER UNREADABLE: <repo>` and every one was the same 403. Naming the
# class lets the caller stop paying for calls that cannot succeed and say the cause ONCE.
# classify_api_error <stderr-file> — THE one classifier, shared by every read and by the
# create, so the predicate that recognises an absent thing or a spent quota exists once:
# 3 = the thing does not exist (HTTP 404), 4 = the API refused us (the quota), 1 = a failure.
classify_api_error() {
  if grep -q 'HTTP 404' "$1"; then return 3; fi
  if grep -qi 'API rate limit exceeded' "$1"; then return 4; fi
  return 1
}

api_absent() {
  local err out rc cls
  err="$(mktemp)"
  out="$(gh api "$@" 2>"$err")"; rc=$?
  if [[ $rc -eq 0 ]]; then rm -f "$err"; printf '%s' "$out"; return 0; fi
  classify_api_error "$err"; cls=$?
  [[ $cls -eq 1 ]] && cat "$err" >&2
  rm -f "$err"
  return $cls
}

# ref_points_at <org> <repo> <tag> <sha> — a POINT read of the ref just created.
# A create must be verified by identity, not by scanning a LISTING: the tags listing
# lags a create (measured on the first pilot — the tag existed and the listing did not
# show it yet), so a listing-based read-back reports a successful tag as a failure.
# Answers, never exits: 0 = the ref holds <sha>, 10 = it does not (or is absent), 4 = the
# API refused the read, 2 = the ref could not be read for another reason. The CALLER decides
# what a refusal means, because only the caller owns the run's bookkeeping.
ref_points_at() {
  local org="$1" repo="$2" tag="$3" sha="$4" got rc
  got="$(api_absent "repos/$org/$repo/git/ref/tags/$tag" --jq '.object.sha')"; rc=$?
  case $rc in
    0) [[ "$got" = "$sha" ]] && return 0 || return 10 ;;
    3) return 10 ;;
    4) return 4 ;;
    *) return 2 ;;
  esac
}

# head_tag <org> <repo> <sha>
# Same contract as ref_points_at: 0 = a tag points at <sha>, 10 = none does (a 404 means the
# repo has no tags at all, which is also "none"), 4 = the API refused the read, 2 = the tags
# could not be read for another reason.
head_tag() {
  local org="$1" repo="$2" sha="$3" out rc
  out="$(api_absent --paginate "repos/$org/$repo/tags?per_page=100" --jq '.[].commit.sha')"; rc=$?
  case $rc in
    0) printf '%s\n' "$out" | grep -qxF "$sha" && return 0 || return 10 ;;
    3) return 10 ;;
    4) return 4 ;;
    *) return 2 ;;
  esac
}

if ! repos_raw="$(discover_repos)"; then echo "FATAL: discover_repos failed" >&2; exit 1; fi
repos_raw="$(printf '%s\n' "$repos_raw" | select_repos "${RECONCILE_REPOS:-}")"
mapfile -t REPOS <<<"$repos_raw"

tagged=0 needs=0 skipped=0 created=0 failed=0
L_NEEDS=()
L_UNEVALUATED=()
RATE_LIMITED=0
# unevaluated <repo> — this repo was NOT looked at, and the run says so ONCE rather than
# paying for a call the quota has already refused.
unevaluated() {
  L_UNEVALUATED+=("$1")
  if [[ $RATE_LIMITED -eq 0 ]]; then
    echo "  API RATE LIMITED (the quota is exhausted) — every repo from here on is NOT evaluated: $1" >&2
    RATE_LIMITED=1
  fi
}
for repo in "${REPOS[@]}"; do
  [[ -z "$repo" ]] && continue
  # Once the quota has refused one call it will refuse them all, so the remaining repos are
  # reported as not evaluated instead of each paying another doomed request.
  [[ $RATE_LIMITED -eq 1 ]] && { unevaluated "$repo"; continue; }
  if [[ "$repo" == "${SOURCE_REPO:-.github}" ]]; then
    echo "  skipped (the source repo's releases come from its own merges): $repo"; skipped=$((skipped+1)); continue
  fi
  # A repo with no caller mints no releases; tagging it would invent one.
  caller_out="$(api_absent "repos/$ORG/$repo/contents/$CALLER_PATH?ref=main")"; caller_rc=$?
  [[ $caller_rc -eq 4 ]] && { unevaluated "$repo"; continue; }
  if [[ $caller_rc -eq 3 ]]; then
    echo "  skipped (no tag-on-merge caller — this repo mints no releases): $repo"; skipped=$((skipped+1)); continue
  fi
  [[ $caller_rc -eq 0 ]] || { echo "  CALLER UNREADABLE: $repo" >&2; failed=$((failed+1)); continue; }
  # THROUGH THE ONE CLASSIFIER, never a second predicate: `api_absent` is the only place
  # that knows what an exhausted quota looks like, so a refusal here is the same answer it
  # gives everywhere else.
  head="$(api_absent "repos/$ORG/$repo/git/ref/heads/main" --jq '.object.sha')"; head_rc=$?
  if [[ $head_rc -eq 4 ]]; then unevaluated "$repo"; continue; fi
  if [[ $head_rc -ne 0 ]]; then echo "  UNREADABLE head: $repo" >&2; failed=$((failed+1)); continue; fi
  head_tag "$ORG" "$repo" "$head"; htt=$?
  if [[ $htt -eq 4 ]]; then unevaluated "$repo"; continue; fi
  if [[ $htt -eq 2 ]]; then echo "  TAGS UNREADABLE: $repo" >&2; failed=$((failed+1)); continue; fi
  if [[ $htt -eq 0 ]]; then tagged=$((tagged+1)); continue; fi
  # EXPLAINED HEADS ARE NOT A FINDING. `design-pintag` accepts a head that is the
  # `docs: add CHANGELOG …` commit sitting one above a tag — that is the ordinary shape
  # every merge produces — so tagging it would invent a second release for a commit the
  # control already excuses.
  subject="$(api_absent "repos/$ORG/$repo/commits/$head" --jq '.commit.message|split("\n")[0]')"; src=$?
  if [[ $src -eq 4 ]]; then unevaluated "$repo"; continue; fi
  if [[ $src -ne 0 ]]; then echo "  SUBJECT UNREADABLE: $repo" >&2; failed=$((failed+1)); continue; fi
  case "$subject" in
    "docs: add CHANGELOG"*)
      # The excuse is the CHANGELOG commit ABOVE A TAG, not any CHANGELOG commit: a tip
      # whose parent is untagged is still failing the control, so it needs a tag itself.
      parent="$(api_absent "repos/$ORG/$repo/commits/$head" --jq '.parents[0].sha')"; prc=$?
      if [[ $prc -eq 4 ]]; then unevaluated "$repo"; continue; fi
      if [[ $prc -ne 0 ]]; then echo "  PARENT UNREADABLE: $repo" >&2; failed=$((failed+1)); continue; fi
      head_tag "$ORG" "$repo" "$parent"; ptr=$?
      if [[ $ptr -eq 4 ]]; then unevaluated "$repo"; continue; fi
      if [[ $ptr -eq 2 ]]; then echo "  TAGS UNREADABLE: $repo" >&2; failed=$((failed+1)); continue; fi
      if [[ $ptr -eq 0 ]]; then
        echo "  explained (CHANGELOG tip above a tag): $repo"; skipped=$((skipped+1)); continue
      fi
      echo "  CHANGELOG tip with an UNTAGGED parent — it needs a tag: $repo" ;;
  esac
  tag="$(calver_at "$ORG" "$repo" "$head")" || { echo "  CANNOT DERIVE A CALVER: $repo" >&2; failed=$((failed+1)); continue; }
  if [[ "$MODE" == "check" ]]; then
    echo "  needs $tag: $repo  [$subject]"; needs=$((needs+1)); L_NEEDS+=("$repo")
    continue
  fi
  # ADD-ONLY: create at the head only. A ref that already exists is never overwritten —
  # and when the create loses to one (the pre-check's listing lagged), the point read says
  # whether it is the ref we wanted, which is the only question that matters here.
  create_err="$(mktemp)"
  create_rc=0
  gh api --method POST "repos/$ORG/$repo/git/refs" -f ref="refs/tags/$tag" -f sha="$head" >/dev/null 2>"$create_err" || create_rc=$?
  classify_api_error "$create_err"; crc=$?
  if [[ $crc -eq 4 ]]; then rm -f "$create_err"; unevaluated "$repo"; continue; fi
  if [[ $create_rc -eq 0 ]]; then
    rm -f "$create_err"
    ref_points_at "$ORG" "$repo" "$tag" "$head"; rp=$?
    if [[ $rp -eq 4 ]]; then unevaluated "$repo"; continue; fi
    if [[ $rp -eq 0 ]]; then
      echo "  tagged $tag: $repo"; created=$((created+1))
    else
      echo "  READ-BACK FAILED ($tag): $repo" >&2; failed=$((failed+1))
    fi
  elif grep -q 'HTTP 422' "$create_err"; then
    rm -f "$create_err"
    ref_points_at "$ORG" "$repo" "$tag" "$head"; rp=$?
    if [[ $rp -eq 4 ]]; then unevaluated "$repo"; continue; fi
    if [[ $rp -eq 2 ]]; then echo "  REF UNREADABLE ($tag): $repo" >&2; failed=$((failed+1)); continue; fi
    if [[ $rp -eq 0 ]]; then
      echo "  already present at the head ($tag): $repo"; tagged=$((tagged+1))
    else
      echo "  REF EXISTS AT A DIFFERENT COMMIT ($tag): $repo" >&2; failed=$((failed+1))
    fi
  else
    cat "$create_err" >&2; rm -f "$create_err"
    echo "  TAG CREATE FAILED ($tag): $repo" >&2; failed=$((failed+1))
  fi
done

echo
echo "backfill-missing-tags: mode=$MODE"
echo "  repos examined     : ${#REPOS[@]}"
echo "  allow-list         : ${RECONCILE_REPOS:-$(printf "<all discovered>")}"
echo "  already tagged     : $tagged"
echo "  skipped            : $skipped"
if [[ "$MODE" == "check" ]]; then
  echo "  NEED a tag         : $needs"
  for r in "${L_NEEDS[@]}"; do echo "    [needs] $r"; done
else
  echo "  tagged now         : $created"
  echo "  failures           : $failed"
fi
if [[ ${#L_UNEVALUATED[@]} -gt 0 ]]; then
  echo "  API RATE LIMITED   : ${#L_UNEVALUATED[@]} repo(s) NOT evaluated — the API refused the call, so nothing is known about them either way"
  echo "  retry with         : RECONCILE_REPOS=\"${L_UNEVALUATED[*]}\" $0 ${MODE}"
  if [[ -n "${BF_UNEVALUATED_FILE:-}" ]]; then
    printf '%s\n' "${L_UNEVALUATED[@]}" >"$BF_UNEVALUATED_FILE" \
      || { echo "  cannot write BF_UNEVALUATED_FILE: $BF_UNEVALUATED_FILE" >&2; exit 1; }
    echo "  unevaluated set    : $BF_UNEVALUATED_FILE"
  fi
fi
[[ "$failed" -eq 0 && ${#L_UNEVALUATED[@]} -eq 0 ]] || exit 1
