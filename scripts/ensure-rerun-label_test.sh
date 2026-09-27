#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

# acme/one: absent -> CREATED; acme/two: exists (422 already_exists) -> skipped.
gh() {
  if [[ "$1 $2" == "repo list" ]]; then printf 'one\ntwo\n'; return; fi
  [[ "$1" == api ]] || return 90
  shift
  local path=""
  while [[ $# -gt 0 ]]; do case "$1" in repos/*) path="$1"; shift;; *) shift;; esac; done
  [[ "$path" =~ ^repos/acme/(one|two)/labels$ ]] || return 91
  local repo="${BASH_REMATCH[1]}"
  if [[ "$repo" == one ]]; then printf '{"name":"rerun"}\n'; return 0; fi
  printf '{"message":"Validation Failed","errors":[{"resource":"Label","code":"already_exists","field":"name"}]}\n' >&2
  return 1
}
export -f gh

out="$(GH_TOKEN=x OPENCHARLY_ORG=acme "$root/scripts/ensure-rerun-label.sh" 2>&1)"
grep -q "created=1 existed=1 failed=0" <<<"$out" || { echo "FAIL: counters wrong (got: $out)" >&2; exit 1; }

echo "ensure-rerun-label_test: all assertions passed"
