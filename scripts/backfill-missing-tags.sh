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

# calver_for_head <org> <repo> <commit-sha> — the tag the reusable WOULD mint at this
# commit, derived from the commit's own committer date and in the repo's own form.
calver_for_head() {
  local org="$1" repo="$2" sha="$3" iso
  iso="$(gh api "repos/$org/$repo/commits/$sha" --jq '.commit.committer.date')" || return 1
  case "$repo" in
    sdk|spec|plugin-gh) date -u -d "$iso" +'v0.%Y%j.%-H%M' ;;
    *)                  date -u -d "$iso" +'v%Y.%j.%H%M' ;;
  esac
}

# head_tag <org> <repo> <sha> — prints the tag pointing at <sha>, or nothing.
head_tag() {
  local org="$1" repo="$2" sha="$3"
  gh api --paginate "repos/$org/$repo/tags?per_page=100" --jq '.[].commit.sha' 2>/dev/null \
    | grep -qxF "$sha"
}

if ! repos_raw="$(discover_repos)"; then echo "FATAL: discover_repos failed" >&2; exit 1; fi
repos_raw="$(printf '%s\n' "$repos_raw" | select_repos "${RECONCILE_REPOS:-}")"
mapfile -t REPOS <<<"$repos_raw"

tagged=0 needs=0 skipped=0 created=0 failed=0
L_NEEDS=()
for repo in "${REPOS[@]}"; do
  [[ -z "$repo" ]] && continue
  if [[ "$repo" == "${SOURCE_REPO:-.github}" ]]; then
    echo "  skipped (the source repo's releases come from its own merges): $repo"; skipped=$((skipped+1)); continue
  fi
  # A repo with no caller mints no releases; tagging it would invent one.
  if ! gh api "repos/$ORG/$repo/contents/$CALLER_PATH?ref=main" >/dev/null 2>&1; then
    echo "  skipped (no tag-on-merge caller — this repo mints no releases): $repo"; skipped=$((skipped+1)); continue
  fi
  head="$(gh api "repos/$ORG/$repo/git/ref/heads/main" --jq '.object.sha' 2>/dev/null)" || { echo "  UNREADABLE head: $repo" >&2; failed=$((failed+1)); continue; }
  if head_tag "$ORG" "$repo" "$head"; then
    tagged=$((tagged+1)); continue
  fi
  # EXPLAINED HEADS ARE NOT A FINDING. `design-pintag` accepts a head that is the
  # `docs: add CHANGELOG …` commit sitting one above a tag — that is the ordinary shape
  # every merge produces — so tagging it would invent a second release for a commit the
  # control already excuses.
  subject="$(gh api "repos/$ORG/$repo/commits/$head" --jq '.commit.message|split("\n")[0]' 2>/dev/null)"
  case "$subject" in
    "docs: add CHANGELOG"*) echo "  explained (CHANGELOG tip): $repo"; skipped=$((skipped+1)); continue ;;
  esac
  tag="$(calver_for_head "$ORG" "$repo" "$head")" || { echo "  CANNOT DERIVE A CALVER: $repo" >&2; failed=$((failed+1)); continue; }
  if [[ "$MODE" == "check" ]]; then
    echo "  needs $tag: $repo  [$subject]"; needs=$((needs+1)); L_NEEDS+=("$repo")
    continue
  fi
  # ADD-ONLY: create at the head only. A 422 means the ref exists — never overwrite it.
  if gh api --method POST "repos/$ORG/$repo/git/refs" -f ref="refs/tags/$tag" -f sha="$head" >/dev/null 2>&1; then
    if head_tag "$ORG" "$repo" "$head"; then
      echo "  tagged $tag: $repo"; created=$((created+1))
    else
      echo "  READ-BACK FAILED ($tag): $repo" >&2; failed=$((failed+1))
    fi
  else
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
[[ "$failed" -eq 0 ]] || exit 1
