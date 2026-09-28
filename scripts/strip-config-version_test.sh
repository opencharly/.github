#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
mkdir -p "$STATE/store"

# Fixtures:
#   strippable — node-form manifest with an indent-0 document stamp AND an indent-8
#                entity-body stamp (both must go; everything else byte-identical);
#   hermes     — the REAL layer-charly-hermes charly.yml (committed fixture), whose
#                indent-16 `version:` inside a ```yaml block in a description: |-
#                scalar MUST SURVIVE;
#   clean      — an already-stripped file (the only stamp is the indent-16 code-block one);
#   perm       — a repo whose PUT returns 403 (must fail + name the remediation);
#   beta       — no charly.yml at all (absent).
cat >"$STATE/strippable.yml" <<'YAML'
version: 2026.100.0000
alpha:
    candy:
        version: 2026.200.0000
        description: |-
            A test candy.
        plan:
            - run: true
              command: "true"
YAML
cp "$root/scripts/fixtures/layer-charly-hermes-charly.yml" "$STATE/hermes.yml"
cat >"$STATE/clean.yml" <<'YAML'
alpha:
    candy:
        description: |-
            An already-stripped manifest with a fenced example:
            ```yaml
            alpha:
              candy:
                version: 2026.156.1921   # mandatory CalVer
            ```
        plan:
            - run: true
              command: "true"
YAML
printf 'version: 2026.100.0000\nalpha:\n    candy:\n        version: 2026.200.0000\n' >"$STATE/perm.yml"

for r in strippable hermes clean perm; do cp "$STATE/$r.yml" "$STATE/store/$r"; done
: >"$STATE/transcript"

gh() {
  if [[ "$1 $2" == "repo list" ]]; then printf 'strippable\nhermes\nclean\nperm\nbeta\n'; return 0; fi
  [[ "$1" == api ]] || return 90
  shift
  local method=GET include=0 path="" input=0 payload=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --include) include=1; shift ;;
      --input) input=1; shift 2 ;;
      --jq) shift 2 ;;
      *) [[ -z "$path" ]] && path="$1"; shift ;;
    esac
  done
  [[ $input == 1 ]] && payload="$(cat)"

  local repo="" blob_sha=""
  if [[ "$path" =~ ^repos/test/(strippable|hermes|clean|perm|beta)/contents/charly\.yml$ ]]; then
    repo="${BASH_REMATCH[1]}"
  elif [[ "$path" =~ ^repos/test/(strippable|hermes|clean|perm|beta)/git/blobs/(.+)$ ]]; then
    repo="${BASH_REMATCH[1]}"; blob_sha="${BASH_REMATCH[2]}"
    [[ "$blob_sha" == "bigsha" ]] || return 92
    printf '{"sha":"bigsha","content":"%s"}\n' "$(base64 -w0 <"$STATE/store/$repo")"
    return 0
  else
    return 91
  fi
  local present=0
  [[ -f "$STATE/store/$repo" ]] && present=1

  if [[ "$method" == PUT ]]; then
    if [[ "${FORCE_PERM_FAIL:-}" == 1 && "$repo" == perm ]]; then
      printf 'gh: Resource not accessible by integration (HTTP 403)\n'; return 1
    fi
    if [[ "${FORCE_PUT_FAIL:-}" == 1 && "$repo" == strippable ]]; then
      printf 'gh: Server Error (HTTP 500)\n'; return 1
    fi
    printf '%s' "$payload" | jq -r '.content' | base64 -d >"$STATE/store/$repo"
    printf 'wrote %s\n' "$repo" >>"$STATE/transcript"
    printf 'deadbeef\n'; return 0
  fi

  if [[ "${FORCE_API_FAIL:-}" == 1 ]]; then
    [[ $include == 1 ]] && printf 'HTTP/2.0 500 X\r\n\r\n'
    return 1
  fi
  if [[ $present == 1 ]]; then
    if [[ $include == 1 ]]; then printf 'HTTP/2.0 200 OK\r\n\r\n'; return 0; fi
    # vanished-race: the probe saw 200, the metadata fetch now 404s (concurrent run).
    if [[ "${FORCE_VANISH_RACE:-}" == 1 && "$repo" == strippable ]]; then
      printf '{"message":"Not Found","status":"404"}\n'; return 1
    fi
    # > 1 MB: sha but no inline content (encoding none) — forces the blob fallback.
    if [[ "${FORCE_BIGFILE:-}" == 1 && "$repo" == strippable ]]; then
      printf '{"sha":"bigsha","encoding":"none","content":""}\n'; return 0
    fi
    printf '{"sha":"%s","content":"%s"}\n' "$(git hash-object "$STATE/store/$repo")" \
      "$(base64 -w0 <"$STATE/store/$repo")"
    return 0
  fi
  [[ $include == 1 ]] && printf 'HTTP/2.0 404 Not Found\r\n\r\n'
  return 1
}
export -f gh
export STATE

strip() { GH_TOKEN=x OPENCHARLY_ORG=test "$root/scripts/strip-config-version.sh" "$@"; }

# ---- filter unit tests (direct): the exact-bytes / indent rules -------------------
# indent-0 + indent-8 both deleted; everything else byte-identical.
printf 'version: A\nalpha:\n    candy:\n        version: B\n        x: 1\n' \
  | python3 "$root/scripts/_strip-filter.py" >"$STATE/u1" 2>/dev/null
printf 'alpha:\n    candy:\n        x: 1\n' >"$STATE/u1e"
cmp -s "$STATE/u1" "$STATE/u1e" || { echo "FAIL: filter must delete indent-0 + indent-8 only" >&2; exit 1; }
# a 2-space manifest (action-review / eval-charly): the entity stamp sits at indent 4.
printf 'version: A\nalpha:\n  candy:\n    version: B\n' \
  | python3 "$root/scripts/_strip-filter.py" >"$STATE/u2" 2>/dev/null
printf 'alpha:\n  candy:\n' >"$STATE/u2e"
cmp -s "$STATE/u2" "$STATE/u2e" || { echo "FAIL: filter must delete the indent-4 entity stamp of a 2-space manifest" >&2; exit 1; }
# an indent-16 stamp inside a block scalar is PRESERVED.
printf 'version: A\nalpha:\n    candy:\n        description: |-\n                version: 2026.156.1921\n' \
  | python3 "$root/scripts/_strip-filter.py" >"$STATE/u3" 2>/dev/null
grep -q '^                version: 2026.156.1921$' "$STATE/u3" \
  || { echo "FAIL: filter must PRESERVE an indent-16 block-scalar stamp" >&2; exit 1; }
# the defensive guard: a matched stamp genuinely inside a block scalar REFUSES (exit 3).
printf 'foo: |\n    version: 1\n' | python3 "$root/scripts/_strip-filter.py" >/dev/null 2>"$STATE/u4err" \
  && { echo "FAIL: the block-scalar guard must refuse (non-zero)" >&2; exit 1; }
grep -q '^REFUSED:' "$STATE/u4err" || { echo "FAIL: the guard must report REFUSED" >&2; exit 1; }

# ---- (a) indent-0 + indent-8 removed; beta absent; clean skipped -------------------
out="$(strip strippable beta clean)"
grep -qx 'wrote strippable' "$STATE/transcript" || { echo "FAIL: strippable was not written" >&2; exit 1; }
cat >"$STATE/strippable.expected" <<'YAML'
alpha:
    candy:
        description: |-
            A test candy.
        plan:
            - run: true
              command: "true"
YAML
cmp -s "$STATE/store/strippable" "$STATE/strippable.expected" \
  || { echo "FAIL: strippable output is not exactly the two deleted lines (else byte-identical)" >&2; diff "$STATE/strippable.expected" "$STATE/store/strippable" >&2; exit 1; }
grep -q 'wrote clean' "$STATE/transcript" && { echo "FAIL: an already-clean file must never be written" >&2; exit 1; }
cmp -s "$STATE/store/clean" "$STATE/clean.yml" || { echo "FAIL: the clean file changed" >&2; exit 1; }
grep -q "stripped=1 absent=1 skipped=1 failed=0" <<<"$out" \
  || { echo "FAIL: happy-path counters (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }

# ---- (b) the REAL layer-charly-hermes fixture: code-block line SURVIVES ------------
# Lock the fixture to the exact upstream bytes (git blob sha from GitHub).
[[ "$(git hash-object "$STATE/store/hermes")" == "988bdc946e548f79baeec61b6e88a4a8d9f9c534" ]] \
  || { echo "FAIL: the committed hermes fixture is not the real layer-charly-hermes charly.yml" >&2; exit 1; }
: >"$STATE/transcript"
strip hermes >/dev/null
grep -qx 'wrote hermes' "$STATE/transcript" || { echo "FAIL: hermes was not written" >&2; exit 1; }
# Capture the diff ONCE (a `diff | grep` pipeline would trip `pipefail` on diff's
# normal exit 1 when the files differ).
del="$(diff "$STATE/hermes.yml" "$STATE/store/hermes" || true)"
ndel="$(grep -c '^<' <<<"$del" || true)"
[[ "$ndel" == 2 ]] || { echo "FAIL: hermes strip must delete exactly 2 lines (got $ndel)" >&2; exit 1; }
grep -q '^< version: 2026.232.0520$' <<<"$del" \
  || { echo "FAIL: hermes indent-0 stamp must be deleted" >&2; exit 1; }
grep -q '^<         version: 2026.243.0909$' <<<"$del" \
  || { echo "FAIL: hermes indent-8 stamp must be deleted" >&2; exit 1; }
grep -qF '                version: 2026.156.1921   # mandatory CalVer' "$STATE/store/hermes" \
  || { echo "FAIL: the indent-16 code-block version line MUST SURVIVE (documentation corruption)" >&2; exit 1; }

# ---- (d) a repo that 403s on the PUT -> abort + remediation message ----------------
set +e
out="$(FORCE_PERM_FAIL=1 strip strippable hermes clean perm 2>&1)"; rc=$?
set -e
[[ $rc != 0 ]] || { echo "FAIL: a 403 PUT must abort the run" >&2; exit 1; }
grep -q 'contents: write' <<<"$out" || { echo "FAIL: the 403 abort must name the missing permission" >&2; exit 1; }
grep -q 'Resource not accessible by integration' <<<"$out" || { echo "FAIL: the 403 abort must quote the API error" >&2; exit 1; }

# ---- per-repo resilience: a PUT failure on one repo must NOT abort the wave --------
cp "$STATE/strippable.yml" "$STATE/store/strippable"
: >"$STATE/transcript"
set +e
out="$(FORCE_PUT_FAIL=1 strip strippable hermes clean perm 2>&1)"; rc=$?
set -e
[[ $rc != 0 ]] || { echo "FAIL: a PUT failure must exit non-zero" >&2; exit 1; }
grep -q 'FAILED repos' <<<"$out" || { echo "FAIL: the summary must list the failed repos" >&2; exit 1; }
grep -q 'wrote perm' "$STATE/transcript" || { echo "FAIL: the loop must CONTINUE past the failed repo" >&2; exit 1; }
grep -q "stripped=1 absent=0 skipped=2 failed=1" <<<"$out" \
  || { echo "FAIL: put-failure counters (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }

# ---- (c) already-clean + idempotent ------------------------------------------------
cp "$STATE/clean.yml" "$STATE/store/clean"; cp "$STATE/strippable.yml" "$STATE/store/strippable"
: >"$STATE/transcript"
out="$(strip strippable clean)"
grep -q 'wrote clean' "$STATE/transcript" && { echo "FAIL: an already-clean file must never be written" >&2; exit 1; }
cmp -s "$STATE/store/clean" "$STATE/clean.yml" || { echo "FAIL: the clean file changed" >&2; exit 1; }
grep -q "stripped=1 absent=0 skipped=1 failed=0" <<<"$out" \
  || { echo "FAIL: clean-file counters (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }
# idempotent: a second run over the now-stripped repos writes nothing.
: >"$STATE/transcript"
out="$(strip strippable clean)"
[[ -s "$STATE/transcript" ]] && { echo "FAIL: second run must be a no-op" >&2; exit 1; }
grep -q "stripped=0 absent=0 skipped=2 failed=0" <<<"$out" \
  || { echo "FAIL: idempotent counters (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }

# ---- DRY_RUN: reports what WOULD change and commits NOTHING ----------------------
cp "$STATE/strippable.yml" "$STATE/store/strippable"
: >"$STATE/transcript"
out="$(DRY_RUN=1 strip strippable)"
[[ -s "$STATE/transcript" ]] && { echo "FAIL: DRY_RUN must not write anything" >&2; exit 1; }
cmp -s "$STATE/store/strippable" "$STATE/strippable.yml" || { echo "FAIL: DRY_RUN modified the file" >&2; exit 1; }
grep -q 'WOULD strip' <<<"$out" || { echo "FAIL: DRY_RUN must report what it would change" >&2; exit 1; }
grep -q 'DRY_RUN: would_strip=1' <<<"$out" || { echo "FAIL: DRY_RUN counters (got: $(grep 'DRY_RUN' <<<"$out"))" >&2; exit 1; }

# ---- non-404 probe failure must ABORT, never read as absent ----------------------
if FORCE_API_FAIL=1 strip strippable >/dev/null 2>&1; then
  echo "FAIL: must abort on a non-404 probe failure" >&2; exit 1
fi

# ---- vanished-race (concurrent run) -> counted absent, run SUCCEEDS --------------
cp "$STATE/strippable.yml" "$STATE/store/strippable"
out="$(FORCE_VANISH_RACE=1 strip strippable beta 2>&1)" || {
  echo "FAIL: a vanished-race must not fail the run" >&2; exit 1; }
grep -q "stripped=0 absent=2 skipped=0 failed=0" <<<"$out" \
  || { echo "FAIL: vanished-race counters (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }
grep -q "strippable: charly.yml vanished between probe and fetch" <<<"$out" \
  || { echo "FAIL: a vanished race must be reported as already-handled" >&2; exit 1; }

# ---- > 1 MB fallback: Contents API omits content; the git blob API supplies it ---
cp "$STATE/strippable.yml" "$STATE/store/strippable"
: >"$STATE/transcript"
out="$(FORCE_BIGFILE=1 strip strippable 2>&1)" || { echo "FAIL: the large-file fallback must classify, not fail" >&2; exit 1; }
grep -q 'wrote strippable' "$STATE/transcript" || { echo "FAIL: a > 1 MB charly.yml must still be stripped via the blob fallback" >&2; exit 1; }

echo "strip-config-version_test: all assertions passed"
