#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
mkdir -p "$STATE/store"

# Fixtures — each repo is a directory tree of `charly.yml` files (root or nested):
#   strippable  — a ROOT manifest AND a nested `candy/x/charly.yml`, BOTH with an
#                 indent-0 document stamp AND an indent-8 entity-body stamp (all four
#                 lines must go; everything else byte-identical);
#   hermes      — the REAL layer-charly-hermes charly.yml (committed fixture) at BOTH
#                 the root AND a nested `candy/hermes-layer/charly.yml`, whose indent-16
#                 `version:` inside a ```yaml block in a description: |- scalar MUST
#                 SURVIVE at BOTH levels;
#   clean       — an already-stripped file (the only stamp is the indent-16 code-block one);
#   perm        — a repo whose PUT returns 403 (must fail + name the remediation);
#   nestedperm  — a repo whose NESTED write 403s (must fail + name the remediation);
#   bigfile     — a repo whose root charly.yml is served > 1 MB (blob-API fallback);
#   beta        — no charly.yml at all (absent);
#   vanished    — the tree lists a charly.yml the Contents API then 404s (counted absent).
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

# strippable: root + nested, both the same stamp shape.
mkdir -p "$STATE/store/strippable/candy/x"
cp "$STATE/strippable.yml" "$STATE/store/strippable/charly.yml"
cp "$STATE/strippable.yml" "$STATE/store/strippable/candy/x/charly.yml"
# hermes: the REAL fixture at BOTH the root and a nested layer path.
mkdir -p "$STATE/store/hermes/candy/hermes-layer"
cp "$STATE/hermes.yml" "$STATE/store/hermes/charly.yml"
cp "$STATE/hermes.yml" "$STATE/store/hermes/candy/hermes-layer/charly.yml"
# clean: only a root manifest, already stripped.
mkdir -p "$STATE/store/clean"
cp "$STATE/clean.yml" "$STATE/store/clean/charly.yml"
# perm: only a root manifest, PUT 403s.
mkdir -p "$STATE/store/perm"
cp "$STATE/perm.yml" "$STATE/store/perm/charly.yml"
# nestedperm: root is clean, the NESTED manifest 403s on write.
mkdir -p "$STATE/store/nestedperm/candy/plug"
cp "$STATE/clean.yml" "$STATE/store/nestedperm/charly.yml"
cp "$STATE/perm.yml" "$STATE/store/nestedperm/candy/plug/charly.yml"
# bigfile: only a root manifest, served > 1 MB (forces the blob fallback).
mkdir -p "$STATE/store/bigfile"
cp "$STATE/strippable.yml" "$STATE/store/bigfile/charly.yml"
# beta: NO charly.yml at all (an empty repo dir; tree lists nothing).
mkdir -p "$STATE/store/beta"
# vanished: tree LISTS a manifest that the Contents API then 404s (concurrent run).
mkdir -p "$STATE/store/vanished"
cp "$STATE/strippable.yml" "$STATE/store/vanished/charly.yml"
: >"$STATE/transcript"

gh() {
  if [[ "$1 $2" == "repo list" ]]; then
    printf 'strippable\nhermes\nclean\nperm\nnestedperm\nbigfile\nbeta\nvanished\n'; return 0
  fi
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

  local repo="" subpath="" blob_sha=""
  if [[ "$path" =~ ^repos/test/(strippable|hermes|clean|perm|nestedperm|bigfile|beta|vanished)/git/trees/main\?recursive=1$ ]]; then
    repo="${BASH_REMATCH[1]}"
    [[ "${FORCE_TREE_FAIL:-}" == 1 ]] && { printf 'gh: Server Error (HTTP 500)\n'; return 1; }
    if [[ "${FORCE_TREE_TRUNCATE:-}" == 1 ]]; then
      printf '{"sha":"treesha","truncated":true,"tree":[]}\n'; return 0
    fi
    # Emit the JSON list_config_paths consumes (it prints `ok` + jq output itself).
    if [[ -d "$STATE/store/$repo" ]]; then
      local body
      body="$(cd "$STATE/store/$repo" && find . -type f -name charly.yml -printf '%P\n' | sort \
        | jq -R . | jq -sc '{sha:"treesha",truncated:false,tree:(map({path:.,type:"blob"}))}')"
      printf '%s\n' "$body"
    else
      printf '{"sha":"treesha","truncated":false,"tree":[]}\n'
    fi
    return 0
  elif [[ "$path" =~ ^repos/test/(strippable|hermes|clean|perm|nestedperm|bigfile|beta|vanished)/contents/(.+)$ ]]; then
    repo="${BASH_REMATCH[1]}"; subpath="${BASH_REMATCH[2]}"
  elif [[ "$path" =~ ^repos/test/(strippable|hermes|clean|perm|nestedperm|bigfile|beta|vanished)/git/blobs/(.+)$ ]]; then
    repo="${BASH_REMATCH[1]}"; blob_sha="${BASH_REMATCH[2]}"
    [[ "$blob_sha" == "bigsha" ]] || return 92
    printf '{"sha":"bigsha","content":"%s"}\n' "$(base64 -w0 <"$STATE/store/$repo/charly.yml")"
    return 0
  else
    return 91
  fi
  local file="$STATE/store/$repo/$subpath"
  local present=0
  # `vanished` lists a manifest on disk but the Contents API always 404s it.
  if [[ "$repo" == "vanished" ]]; then present=0; else [[ -f "$file" ]] && present=1; fi

  if [[ "$method" == PUT ]]; then
    if [[ "${FORCE_PERM_FAIL:-}" == 1 && "$repo" == perm ]]; then
      printf 'gh: Resource not accessible by integration (HTTP 403)\n'; return 1
    fi
    if [[ "${FORCE_NESTED_PERM_FAIL:-}" == 1 && "$repo" == nestedperm && "$subpath" == candy/* ]]; then
      printf 'gh: Resource not accessible by integration (HTTP 403)\n'; return 1
    fi
    if [[ "${FORCE_PUT_FAIL:-}" == 1 && "$repo" == strippable && "$subpath" == charly.yml ]]; then
      printf 'gh: Server Error (HTTP 500)\n'; return 1
    fi
    printf '%s' "$payload" | jq -r '.content' | base64 -d >"$file"
    printf 'wrote %s:%s\n' "$repo" "$subpath" >>"$STATE/transcript"
    printf 'deadbeef\n'; return 0
  fi

  if [[ "${FORCE_API_FAIL:-}" == 1 ]]; then
    [[ $include == 1 ]] && printf 'HTTP/2.0 500 X\r\n\r\n'
    return 1
  fi
  if [[ $present == 1 ]]; then
    if [[ $include == 1 ]]; then printf 'HTTP/2.0 200 OK\r\n\r\n'; return 0; fi
    # vanished-race: the tree listed the path, the metadata fetch now 404s (concurrent run).
    if [[ "${FORCE_VANISH_RACE:-}" == 1 && "$repo" == strippable && "$subpath" == charly.yml ]]; then
      printf '{"message":"Not Found","status":"404"}\n'; return 1
    fi
    # > 1 MB: sha but no inline content (encoding none) — forces the blob fallback.
    if [[ "${FORCE_BIGFILE:-}" == 1 && "$repo" == bigfile && "$subpath" == charly.yml ]]; then
      printf '{"sha":"bigsha","encoding":"none","content":""}\n'; return 0
    fi
    printf '{"sha":"%s","content":"%s"}\n' "$(git hash-object "$file")" \
      "$(base64 -w0 <"$file")"
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
# a LIVE indent-8 `version:` that is NOT a candy/box/deploy entity stamp is
# PRESERVED — the R1 fix. `alpine: distro: version:` is a `#Distro.version` field
# (schema/distro.cue), NOT the retired stamp. A bare-indent predicate would delete
# it (measured: charly/charly.yml's embedded default vocabulary). The document
# stamp at indent 0 is still deleted, and the entity stamp still is.
printf 'version: A\nalpine:\n    distro:\n        version: "3.24"\n' \
  | python3 "$root/scripts/_strip-filter.py" >"$STATE/u5" 2>/dev/null
printf 'alpine:\n    distro:\n        version: "3.24"\n' >"$STATE/u5e"
cmp -s "$STATE/u5" "$STATE/u5e" \
  || { echo "FAIL: the filter must PRESERVE a live distro.version at indent 8 (R1)" >&2; exit 1; }
# the real charly/charly.yml shape: delete ONLY the indent-0 stamp, keep all four
# distro versions and the whole embedded vocabulary.
cat >"$STATE/u6" <<'YAML'
version: 2026.261.1747
alpine:
    distro:
        version: "3.24"
debian:
    distro:
        version: "13"
fedora:
    distro:
        version: "43"
ubuntu:
    distro:
        inherits: debian
        version: "24.04"
YAML
python3 "$root/scripts/_strip-filter.py" <"$STATE/u6" >"$STATE/u6o" 2>"$STATE/u6r"
[[ "$(cat "$STATE/u6r")" == "STRIPPED 1" ]] \
  || { echo "FAIL: the embedded-vocab shape must strip exactly the document stamp (got: $(cat "$STATE/u6r"))" >&2; exit 1; }
for v in '3.24' '13' '43' '24.04'; do
  grep -qF "        version: \"$v\"" "$STATE/u6o" \
    || { echo "FAIL: distro.version \"$v\" was deleted (live field corruption, R1)" >&2; exit 1; }
done
grep -q '^version:' "$STATE/u6o" && { echo "FAIL: the document stamp must be deleted" >&2; exit 1; }

# ---- (a) ROOT + NESTED both stripped; beta absent; clean skipped -------------------
out="$(strip strippable beta clean)"
grep -qx 'wrote strippable:charly.yml' "$STATE/transcript" || { echo "FAIL: strippable ROOT was not written" >&2; exit 1; }
grep -qx 'wrote strippable:candy/x/charly.yml' "$STATE/transcript" || { echo "FAIL: strippable NESTED was not written (the nested-file GAP)" >&2; exit 1; }
cat >"$STATE/strippable.expected" <<'YAML'
alpha:
    candy:
        description: |-
            A test candy.
        plan:
            - run: true
              command: "true"
YAML
cmp -s "$STATE/store/strippable/charly.yml" "$STATE/strippable.expected" \
  || { echo "FAIL: strippable ROOT output is not exactly the two deleted lines (else byte-identical)" >&2; diff "$STATE/strippable.expected" "$STATE/store/strippable/charly.yml" >&2; exit 1; }
cmp -s "$STATE/store/strippable/candy/x/charly.yml" "$STATE/strippable.expected" \
  || { echo "FAIL: strippable NESTED output is not exactly the two deleted lines (else byte-identical)" >&2; diff "$STATE/strippable.expected" "$STATE/store/strippable/candy/x/charly.yml" >&2; exit 1; }
grep -q 'wrote clean' "$STATE/transcript" && { echo "FAIL: an already-clean file must never be written" >&2; exit 1; }
cmp -s "$STATE/store/clean/charly.yml" "$STATE/clean.yml" || { echo "FAIL: the clean file changed" >&2; exit 1; }
grep -q 'strippable: stripped candy/x/charly.yml (STRIPPED 2)' <<<"$out" \
  || { echo "FAIL: the per-file line must name the nested path (got: $(grep 'strippable:' <<<"$out" | tr '\n' '|'))" >&2; exit 1; }
grep -q "stripped=2 absent=1 skipped=1 failed=0" <<<"$out" \
  || { echo "FAIL: happy-path counters (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }

# ---- (b) the REAL layer-charly-hermes fixture: code-block line SURVIVES at BOTH levels ----
# Lock the fixture to the exact upstream bytes (git blob sha from GitHub).
[[ "$(git hash-object "$STATE/store/hermes/charly.yml")" == "988bdc946e548f79baeec61b6e88a4a8d9f9c534" ]] \
  || { echo "FAIL: the committed hermes fixture is not the real layer-charly-hermes charly.yml" >&2; exit 1; }
: >"$STATE/transcript"
strip hermes >/dev/null
grep -qx 'wrote hermes:charly.yml' "$STATE/transcript" || { echo "FAIL: hermes ROOT was not written" >&2; exit 1; }
grep -qx 'wrote hermes:candy/hermes-layer/charly.yml' "$STATE/transcript" || { echo "FAIL: hermes NESTED was not written" >&2; exit 1; }
for lvl in charly.yml candy/hermes-layer/charly.yml; do
  # Capture the diff ONCE (a `diff | grep` pipeline would trip `pipefail` on diff's
  # normal exit 1 when the files differ).
  del="$(diff "$STATE/hermes.yml" "$STATE/store/hermes/$lvl" || true)"
  ndel="$(grep -c '^<' <<<"$del" || true)"
  [[ "$ndel" == 2 ]] || { echo "FAIL: hermes strip at $lvl must delete exactly 2 lines (got $ndel)" >&2; exit 1; }
  grep -q '^< version: 2026.232.0520$' <<<"$del" \
    || { echo "FAIL: hermes indent-0 stamp at $lvl must be deleted" >&2; exit 1; }
  grep -q '^<         version: 2026.243.0909$' <<<"$del" \
    || { echo "FAIL: hermes indent-8 stamp at $lvl must be deleted" >&2; exit 1; }
  grep -qF '                version: 2026.156.1921   # mandatory CalVer' "$STATE/store/hermes/$lvl" \
    || { echo "FAIL: the indent-16 code-block version line MUST SURVIVE at $lvl (documentation corruption)" >&2; exit 1; }
done

# ---- (c) tree with NO charly.yml at all -> absent ----------------------------------
: >"$STATE/transcript"
out="$(strip beta)"
grep -q "stripped=0 absent=1 skipped=0 failed=0" <<<"$out" \
  || { echo "FAIL: a repo with no charly.yml must be absent (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }
[[ -s "$STATE/transcript" ]] && { echo "FAIL: absent must write nothing" >&2; exit 1; }

# ---- (d) a 403 on a NESTED write -> abort + remediation ----------------------------
set +e
out="$(FORCE_NESTED_PERM_FAIL=1 strip nestedperm 2>&1)"; rc=$?
set -e
[[ $rc != 0 ]] || { echo "FAIL: a nested 403 PUT must abort the run" >&2; exit 1; }
grep -q 'contents: write' <<<"$out" || { echo "FAIL: the nested 403 abort must name the missing permission" >&2; exit 1; }
grep -q 'candy/plug/charly.yml' <<<"$out" || { echo "FAIL: the nested 403 abort must name the nested path" >&2; exit 1; }
grep -q 'Resource not accessible by integration' <<<"$out" || { echo "FAIL: the nested 403 abort must quote the API error" >&2; exit 1; }

# ---- root 403 -> abort + remediation (v1 case retained) ----------------------------
set +e
out="$(FORCE_PERM_FAIL=1 strip perm 2>&1)"; rc=$?
set -e
[[ $rc != 0 ]] || { echo "FAIL: a 403 PUT must abort the run" >&2; exit 1; }
grep -q 'contents: write' <<<"$out" || { echo "FAIL: the 403 abort must name the missing permission" >&2; exit 1; }
grep -q 'Resource not accessible by integration' <<<"$out" || { echo "FAIL: the 403 abort must quote the API error" >&2; exit 1; }

# ---- per-file resilience: a PUT failure on one repo must NOT abort the wave --------
cp "$STATE/strippable.yml" "$STATE/store/strippable/charly.yml"
cp "$STATE/strippable.yml" "$STATE/store/strippable/candy/x/charly.yml"
: >"$STATE/transcript"
set +e
out="$(FORCE_PUT_FAIL=1 strip strippable hermes clean perm 2>&1)"; rc=$?
set -e
[[ $rc != 0 ]] || { echo "FAIL: a PUT failure must exit non-zero" >&2; exit 1; }
grep -q 'FAILED files' <<<"$out" || { echo "FAIL: the summary must list the failed files" >&2; exit 1; }
grep -q 'wrote strippable:candy/x/charly.yml' "$STATE/transcript" || { echo "FAIL: the loop must CONTINUE past the failed file (nested)" >&2; exit 1; }
grep -q 'wrote perm:charly.yml' "$STATE/transcript" || { echo "FAIL: the loop must CONTINUE past the failed repo" >&2; exit 1; }
grep -q "stripped=2 absent=0 skipped=3 failed=1" <<<"$out" \
  || { echo "FAIL: put-failure counters (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }

# ---- already-clean + idempotent ----------------------------------------------------
cp "$STATE/strippable.yml" "$STATE/store/strippable/charly.yml"
cp "$STATE/strippable.yml" "$STATE/store/strippable/candy/x/charly.yml"
: >"$STATE/transcript"
out="$(strip strippable clean)"
grep -q 'wrote clean' "$STATE/transcript" && { echo "FAIL: an already-clean file must never be written" >&2; exit 1; }
cmp -s "$STATE/store/clean/charly.yml" "$STATE/clean.yml" || { echo "FAIL: the clean file changed" >&2; exit 1; }
grep -q "stripped=2 absent=0 skipped=1 failed=0" <<<"$out" \
  || { echo "FAIL: clean-file counters (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }
# idempotent: a second run over the now-stripped repos writes nothing.
: >"$STATE/transcript"
out="$(strip strippable clean)"
[[ -s "$STATE/transcript" ]] && { echo "FAIL: second run must be a no-op" >&2; exit 1; }
grep -q "stripped=0 absent=0 skipped=3 failed=0" <<<"$out" \
  || { echo "FAIL: idempotent counters (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }

# ---- DRY_RUN: reports every file (root + nested) and commits NOTHING -------------
cp "$STATE/strippable.yml" "$STATE/store/strippable/charly.yml"
cp "$STATE/strippable.yml" "$STATE/store/strippable/candy/x/charly.yml"
: >"$STATE/transcript"
out="$(DRY_RUN=1 strip strippable)"
[[ -s "$STATE/transcript" ]] && { echo "FAIL: DRY_RUN must not write anything" >&2; exit 1; }
cmp -s "$STATE/store/strippable/charly.yml" "$STATE/strippable.yml" || { echo "FAIL: DRY_RUN modified the ROOT file" >&2; exit 1; }
cmp -s "$STATE/store/strippable/candy/x/charly.yml" "$STATE/strippable.yml" || { echo "FAIL: DRY_RUN modified the NESTED file" >&2; exit 1; }
grep -q 'WOULD strip from charly.yml' <<<"$out" || { echo "FAIL: DRY_RUN must name the root file" >&2; exit 1; }
grep -q 'WOULD strip from candy/x/charly.yml' <<<"$out" || { echo "FAIL: DRY_RUN must name the nested file" >&2; exit 1; }
grep -q 'DRY_RUN: would_strip=2' <<<"$out" || { echo "FAIL: DRY_RUN counters (got: $(grep 'DRY_RUN' <<<"$out"))" >&2; exit 1; }

# ---- non-404 probe failure must ABORT, never read as absent ----------------------
if FORCE_API_FAIL=1 strip strippable >/dev/null 2>&1; then
  echo "FAIL: must abort on a non-404 probe failure" >&2; exit 1
fi
# a tree-listing failure is FATAL, never an empty->absent read.
if FORCE_TREE_FAIL=1 strip strippable >/dev/null 2>&1; then
  echo "FAIL: must abort on a tree-listing failure" >&2; exit 1
fi
# a TRUNCATED tree is FATAL (an unseen nested manifest would stay stamped).
if FORCE_TREE_TRUNCATE=1 strip strippable >/dev/null 2>&1; then
  echo "FAIL: must abort on a truncated tree listing" >&2; exit 1
fi

# ---- vanished-race (concurrent run) -> counted absent, run SUCCEEDS --------------
cp "$STATE/strippable.yml" "$STATE/store/strippable/charly.yml"
out="$(FORCE_VANISH_RACE=1 strip strippable beta 2>&1)" || {
  echo "FAIL: a vanished-race must not fail the run" >&2; exit 1; }
grep -q "stripped=1 absent=2 skipped=0 failed=0" <<<"$out" \
  || { echo "FAIL: vanished-race counters (got: $(grep 'stripped=' <<<"$out"))" >&2; exit 1; }
grep -q "strippable: charly.yml vanished between listing and fetch" <<<"$out" \
  || { echo "FAIL: a vanished race must be reported as already-handled" >&2; exit 1; }

# ---- > 1 MB fallback: Contents API omits content; the git blob API supplies it ---
cp "$STATE/strippable.yml" "$STATE/store/bigfile/charly.yml"
: >"$STATE/transcript"
out="$(FORCE_BIGFILE=1 strip bigfile 2>&1)" || { echo "FAIL: the large-file fallback must classify, not fail" >&2; exit 1; }
grep -q 'wrote bigfile:charly.yml' "$STATE/transcript" || { echo "FAIL: a > 1 MB charly.yml must still be stripped via the blob fallback" >&2; exit 1; }

echo "strip-config-version_test: all assertions passed"
