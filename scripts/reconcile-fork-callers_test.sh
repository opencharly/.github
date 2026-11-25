#!/usr/bin/env bash
# reconcile-fork-callers_test.sh — the SCOPE=forks arm of the tag-caller reconcile.
#
# It proves the properties the fork rollout depends on, each of which can fail here:
#   1. an ABSENT fork caller is INSTALLED (the operator decision), on the fork's DEFAULT
#      branch — `stable` for fork-a, never a hard-coded `main`;
#   2. the install is a BIRTH commit, so it is NOT tagged (design-pintag's
#      `pre-release-process` owns that state);
#   3. a fork that PINS the reusable to a 40-hex SHA keeps that policy: the reconciler
#      substitutes the CURRENT opencharly/.github main SHA, never a stale literal;
#   4. an UPDATE is tagged (the #294 rule);
#   5. the targets scope still does not install an absent caller (one policy per scope).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$STATE/repo/.github/workflows" "$STATE/repo/scripts"
cp "$root/.github/workflows/tag-on-merge-dispatcher.yml" "$STATE/repo/.github/workflows/tag-on-merge-dispatcher.yml"
cp "$root/scripts/reconcile-tag-on-merge-callers.sh" "$STATE/repo/scripts/"
cp "$root/scripts/lib-org.sh" "$STATE/repo/scripts/"

CANON="$STATE/repo/.github/workflows/tag-on-merge-dispatcher.yml"
DG_SHA="1111111111111111111111111111111111111111"
BLOB_FORKB="2222222222222222222222222222222222222222"

cp "$CANON" "$STATE/caller_fork-b"
sed -i "s#tag-on-merge\.yml@main#tag-on-merge.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#" "$STATE/caller_fork-b"

gh() {
  [[ "$1" == api ]] || return 90
  shift
  local method=GET path="" jqexpr="" want_content="" want_branch="" want_sha="" want_ref=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --jq) jqexpr="$2"; shift 2 ;;
      --paginate|--include) shift ;;
      --) shift ;;
      -f)
        case "${2%%=*}" in
          content) want_content="${2#*=}" ;;
          branch)  want_branch="${2#*=}" ;;
          sha)     want_sha="${2#*=}" ;;
          ref)     want_ref="${2#*=}" ;;
        esac
        shift 2 ;;
      --*) shift ;;
      *) [[ -z "$path" ]] && path="$1"; shift ;;
    esac
  done

  case "$path" in
    orgs/fixture/repos?per_page=*)
      printf 'alpha\tfalse\tfalse\tmain\nfork-a\tfalse\ttrue\tstable\nfork-b\tfalse\ttrue\tmain\n'; return 0 ;;
    orgs/fixture)
      printf '3\n'; return 0 ;;
    repos/fixture/.github/commits/main)
      printf '%s\n' "$DG_SHA"; return 0 ;;
    repos/fixture/*/contents/.github/workflows/tag-on-merge.yml\?ref=*)
      local repo="${path#repos/fixture/}"; repo="${repo%%/*}"
      local st="$STATE/caller_$repo"
      if [[ ! -f "$st" ]]; then echo "gh: Not Found" >&2; return 1; fi
      if [[ "$jqexpr" == .sha ]]; then
        [[ "$repo" == fork-b ]] && printf '%s\n' "$BLOB_FORKB" || printf '3333333333333333333333333333333333333333\n'
        return 0
      fi
      base64 -w0 <"$st"; return 0 ;;
    repos/fixture/*/contents/.github/workflows/tag-on-merge.yml)
      local repo="${path#repos/fixture/}"; repo="${repo%%/*}"
      [[ "$method" == PUT ]] || return 90
      [[ -n "$want_branch" ]] || { echo "gh: the reconcile must name the branch" >&2; return 1; }
      if [[ "$repo" == fork-a ]]; then
        [[ -z "$want_sha" ]] || { echo "gh: an install must not send sha" >&2; return 1; }
        printf 'PUT %s branch=%s install\n' "$repo" "$want_branch" >>"$STATE/transcript"
      else
        [[ "$want_sha" == "$BLOB_FORKB" ]] || { echo "gh: update must send the blob sha" >&2; return 1; }
        printf 'PUT %s branch=%s sha=%s\n' "$repo" "$want_branch" "$want_sha" >>"$STATE/transcript"
      fi
      printf '%s' "$want_content" | base64 -d >"$STATE/caller_$repo"
      printf '{"commit":{"sha":"4444444444444444444444444444444444444444"}}\n'; return 0 ;;
    repos/fixture/*/git/ref/tags/*)
      echo "gh: Not Found" >&2; return 1 ;;
    repos/fixture/*/git/refs)
      printf '%s %s\n' "$path" "$want_ref" >>"$STATE/tags"; return 0 ;;
    repos/fixture/*/commits/*)
      printf '2026-11-10T08:00:00Z\n'; return 0 ;;
  esac
  echo "mock gh: unhandled: $*" >&2; return 97
}
export -f gh
export STATE DG_SHA BLOB_FORKB

run() { # run <scope> <mode> [allow-list]
  SCOPE="$1" RECONCILE_REPOS="${3:-}" OPENCHARLY_ORG=fixture \
    bash "$STATE/repo/scripts/reconcile-tag-on-merge-callers.sh" "$2"
}

: >"$STATE/transcript"; : >"$STATE/tags"

# 1-2-3-4: the fork apply
run forks --apply 'fork-a,fork-b' >"$STATE/out" 2>"$STATE/err" || { cat "$STATE/err" >&2; fail "fork apply failed"; }
grep -q 'PUT fork-a branch=stable install' "$STATE/transcript" \
  || { cat "$STATE/transcript" >&2; fail "fork-a must be installed on its DEFAULT branch stable, with no sha"; }
grep -q 'PUT fork-b branch=main sha='"$BLOB_FORKB" "$STATE/transcript" \
  || { cat "$STATE/transcript" >&2; fail "fork-b must be updated with its blob sha on main"; }
[[ "$(cat "$STATE/caller_fork-a")" == "$(cat "$CANON")" ]] \
  || fail "the installed fork-a caller must be the canonical template (no SHA policy existed)"
grep -q "tag-on-merge.yml@$DG_SHA" "$STATE/caller_fork-b" \
  || fail "fork-b's SHA pin must be BUMPED to the current opencharly/.github main sha"
grep -q 'installed on stable (birth commit' "$STATE/out" \
  || { cat "$STATE/out" >&2; fail "the install must be reported as a birth on stable"; }
grep -q '^repos/fixture/fork-b/git/refs refs/tags/' "$STATE/tags" 2>/dev/null || { cat "$STATE/tags" >&2; fail "the UPDATE (fork-b) must be tagged"; }
grep -q 'reconciled (pin=' "$STATE/out" || { cat "$STATE/out" >&2; fail "fork-b's update must be tagged"; }
[[ "$(wc -l <"$STATE/tags")" == 1 ]] || { cat "$STATE/tags" >&2; fail "exactly ONE tag must be created (the update), never one for the birth"; }

# 5: verify reports no absent caller after the installs, and exits 0
run forks verify 'fork-a,fork-b' >"$STATE/vout" 2>"$STATE/verr" || { cat "$STATE/verr" >&2; fail "fork verify failed"; }
grep -q 'caller-absent                 : 0' "$STATE/vout" || { cat "$STATE/vout" >&2; fail "no caller may be absent after the installs"; }

# 5b: the TARGETS scope still does not install an absent caller
rm -f "$STATE/caller_fork-a"
: >"$STATE/transcript"
run targets --apply 'alpha' >"$STATE/tout" 2>"$STATE/terr" || { cat "$STATE/terr" >&2; fail "targets apply failed"; }
grep -qE 'installed on (main|stable|master) \(birth commit' "$STATE/tout" && { cat "$STATE/tout" >&2; fail "the targets scope must NEVER install an absent caller"; }

# PURE: ref_state / render_canonical / filter_fork_rows
source "$STATE/repo/scripts/reconcile-tag-on-merge-callers.sh" --source-only
check() { [[ "$1" == "$2" ]] || { echo "FAIL: $3: expected=$1 actual=$2" >&2; exit 1; }; }
CANON_S="$(cat "$CANON")"
check main "$(ref_state "$CANON_S" "")" "an @main caller is main"
check sha-current "$(ref_state "$(render_canonical "$CANON_S" "$DG_SHA")" "$DG_SHA")" "the current SHA is sha-current"
check sha-stale "$(ref_state "$(render_canonical "$CANON_S" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" "$DG_SHA")" "an old SHA is sha-stale"
check other "$(ref_state "${CANON_S/@main/@v1}" "")" "a branch/tag ref is other"
check absent "$(ref_state "" "")" "no caller is absent"
check $'fork-a\tstable' "$(filter_fork_rows $'fork-a\tstable\nfork-b\tmain' 'fork-a')" "the allow-list keeps the named row WITH its default"

echo "PASS: fork caller reconcile — install on the default branch (birth, untagged), SHA-pin bump, update tagged, targets never install"
