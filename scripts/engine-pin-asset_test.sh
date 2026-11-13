#!/usr/bin/env bash
# THE ENGINE-PIN ASSET PROBE's own coverage (opencharly/.github#285).
#
# WHAT IS UNDER TEST. The reusable validator's `Ensure charly` step fetches the PINNED
# release's assets and, when it cannot, hands a MEASURED class to the gate (INCONCLUSIVE,
# no review). Until this change it fetched with `curl -fsSL` — which DISCARDS the status
# and the body — and then reported, for every failure, "the release is published but its
# assets could not be downloaded (a partial upload)". That sentence is false for the
# failure that actually happens: GitHub's release-download path answers HTTP 504 with a
# 92-byte gateway page while the release API reports every asset `state: uploaded` at its
# full size. The remedy it named ("serve the pinned release") was already true, and the
# action that would have helped ("re-run, the pin is fine") was not named at all.
#
# WHY THE COVERAGE WORKS ON THE SHIPPED TEXT. The step lives INSIDE the reusable workflow
# and runs in the CALLER's repository, so a script here cannot be what the caller runs. The
# coverage EXTRACTS the shipped step's `run:` text (the shared extractor in lib-org.sh) and
# runs THAT — so the text under test IS the shipped text. `curl` is stubbed on PATH because
# the discrimination must be deterministic: the same class must be produced every run, and
# the real endpoint is INTERMITTENT (measured 2026-11-09: one asset 200 and another 504
# within the same minute).
#
# WHAT IT PROVES — each case is a DISCRIMINATION, and every one asserts BOTH the machine
# outputs the next step consumes AND the message a human finally reads:
#   1. 200 + ELF binary + gzip tarball  -> the engine is installed, no class emitted;
#   2. 504 + the 92-byte gateway page   -> `endpoint-failed`: the DOWNLOAD PATH failed,
#                                          release_state=published (the pin is NOT at fault);
#   3. 200 + an HTML body               -> `wrong-body`: a status check alone is fooled;
#   4. 404 on a published release       -> `absent`: the release does not serve the asset;
#   5. 404 with no release AND no tag   -> `no-tag`: the pin itself is wrong;
#   6. binary fine, tarball 504         -> the SECOND asset is measured, not assumed.
# Then the GATE step is run on those outputs and the posted comment body is asserted: the
# class line must carry the URL and the HTTP status, the verdict class must stay `infra`,
# and the remedy must match the class (re-run for 2, publish for 3/4, move the pin for 5).
#
# THE NEGATIVE CONTROLS AT THE END prove the coverage can FAIL: each one neuters ONE
# branch of the shipped step (or of the gate's class table) in a copy, and the coverage
# must turn RED with the expected message. A control that stayed green would mean that
# assertion is a tautology, and a tautology is not coverage (R7).
#
# usage: scripts/engine-pin-asset_test.sh [--workflow <path>] [--no-controls]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
WF="$root/.github/workflows/pr-validator.yml"
SKIP_CONTROLS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow) WF="$2"; shift 2 ;;
    --no-controls) SKIP_CONTROLS=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- the shipped text under test ---------------------------------------------------
# The EXTRACTION is the shared one (lib-org.sh), so this test and the other step-level
# tests cannot drift apart in HOW they read the shipped step — only in WHICH step they
# judge.
# shellcheck source=scripts/lib-org.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-org.sh"
extract_step_run "$WF" '^ *- name: "Ensure charly' "$STATE/ensure.sh"
extract_step_run "$WF" '^ *- name: Gate [(]inconclusive[)]$' "$STATE/gate.sh"
[[ -s "$STATE/ensure.sh" ]] || fail "the shipped Ensure charly step was not found in $WF"
[[ -s "$STATE/gate.sh" ]] || fail "the shipped Gate (inconclusive) step was not found in $WF"
grep -q 'probe_asset' "$STATE/ensure.sh" \
  || fail "the extracted Ensure charly step carries no asset probe — the extraction drifted"
grep -q 'asset unreachable' "$STATE/gate.sh" \
  || fail "the extracted gate step carries no 'asset unreachable' class — the extraction drifted"

# The step's YAML block must FORWARD the measurements the class line quotes, or the class
# would print empty strings: the wiring is part of the behaviour.
extract_step_yaml "$WF" '^ *- name: Gate [(]inconclusive[)]$' "$STATE/gate.yaml"
for k in RELEASE_STATE ASSET_STATE ASSET_URL ASSET_HTTP ASSET_BYTES ASSET_FORM; do
  grep -q "steps.ensure-charly.outputs.$(echo "$k" | tr 'A-Z' 'a-z')" "$STATE/gate.yaml" \
    || fail "the gate step does not forward ensure-charly's $(echo "$k" | tr 'A-Z' 'a-z') — the class would quote nothing"
done
grep -q 'PIN_CLASS' "$STATE/gate.yaml" \
  && fail "the gate step still forwards the retired pin_class output"

# ---- fixtures ---------------------------------------------------------------------
FX="$STATE/fx"; mkdir -p "$FX"
# A REAL ELF: the probe judges the MAGIC, so the fixture must carry it rather than a
# shell script pretending to be a binary.
cp /bin/true "$FX/elf" && chmod +x "$FX/elf"
head -c 4 "$FX/elf" | od -An -tx1 | tr -d ' \n' | grep -qx '7f454c46' \
  || fail "the ELF fixture does not start with the ELF magic — the harness is broken"
printf 'charly plugins fixture\n' > "$FX/plugin-marker"
tar czf "$FX/plugins.tar.gz" -C "$FX" plugin-marker
# GitHub's OWN gateway page, verbatim (`content-type: text/html`, 92 bytes) — the body a
# 504 actually carries, so the case exercises the real shape, including its size.
printf '<html><body><h1>504 Gateway Time-out</h1>\nThe server didn%st respond in time.\n</body></html>\n' "'" > "$FX/gateway504.html"
[[ "$(wc -c < "$FX/gateway504.html")" -eq 92 ]] \
  || fail "the gateway fixture is not the 92-byte body GitHub serves — it no longer matches the measured shape"
# A 200 that is NOT the asset: the case a status-only detector cannot catch.
printf '<html><body>an interception page served with 200</body></html>\n' > "$FX/html200.html"
: > "$FX/empty"
printf '{"tag_name":"%s","draft":false,"prerelease":false}\n' "v2099.001.0001" > "$FX/release-published.json"
printf '{"tag_name":"%s","draft":true,"prerelease":false}\n' "v2099.001.0001" > "$FX/release-draft.json"

# ---- the curl stub ----------------------------------------------------------------
# It answers the three URLs the step uses, from the CASE_* variables the case sets, and
# mimics the two option shapes the step passes: `-sSL -o <dest> -w <fmt> <url>` for an
# asset, and `-s -o <dest> -w <fmt> -H <header> <url>` for the release/tag API.
mkdir -p "$STATE/bin"
cat > "$STATE/bin/curl" <<'STUB'
#!/usr/bin/env bash
dest=""; fmt=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -H) shift 2 ;;
    -s|-S|-L|-f|-sS|-sSL|-sL|-fsSL) shift ;;
    --fail|--fail-with-body) shift ;;
    *) url="$1"; shift ;;
  esac
done
code=404; src="$CASE_STATE/fx/empty"
case "$url" in
  */releases/download/*)
    case "${url##*/}" in
      charly-linux-amd64)               code="$CASE_BIN_HTTP"; src="$CASE_STATE/fx/$CASE_BIN_BODY" ;;
      charly-plugins-linux-amd64.tar.gz) code="$CASE_PLG_HTTP"; src="$CASE_STATE/fx/$CASE_PLG_BODY" ;;
      *)                                code=404; src="$CASE_STATE/fx/empty" ;;
    esac ;;
  */releases/tags/*) code="$CASE_REL_CODE"; src="$CASE_STATE/fx/$CASE_REL_BODY" ;;
  */git/ref/tags/*)  code="$CASE_TAG_CODE"; src="$CASE_STATE/fx/empty" ;;
  *)                 code=404; src="$CASE_STATE/fx/empty" ;;
esac
if [[ -n "$dest" && "$dest" != "/dev/null" ]]; then cp "$src" "$dest" 2>/dev/null || :; fi
printf '%s' "${fmt//\%\{http_code\}/$code}"
STUB
chmod +x "$STATE/bin/curl"

TAG="v2099.001.0001"
# The shipped text with the Actions expression resolved (the step never sees `${{ }}`
# at runtime — GitHub substitutes it before bash does), written to a runnable copy.
sed "s|\${{ runner.temp }}|$STATE|g" "$STATE/ensure.sh" > "$STATE/ensure.run.sh"
grep -q '\${{' "$STATE/ensure.run.sh" \
  && fail "the Ensure charly step carries an Actions expression this harness does not resolve"

# ---- running one case -------------------------------------------------------------
# run_ensure <case> — CASE_* variables must already be exported by the caller.
run_ensure() {
  local name="$1"
  # Each case starts from an EMPTY runner.temp, exactly as a fresh job does: the
  # per-run dir is what the step creates, so a previous case's leftovers would
  # otherwise satisfy a later case's "was it even fetched?" assertions.
  rm -rf "${STATE:?}/charly-$TAG"
  : > "$STATE/$name.out"
  local rc=0
  CASE_STATE="$STATE" \
  PATH="$STATE/bin:/usr/bin:/bin" \
  CHARLY_VERSION="$TAG" PIN_FROM="vars.CHARLY_VERSION" GH_TOKEN="fixture-token" \
  GITHUB_OUTPUT="$STATE/$name.out" \
  GITHUB_PATH="$STATE/$name.path" \
  GITHUB_ENV="$STATE/$name.env" \
    bash -e -o pipefail "$STATE/ensure.run.sh" > "$STATE/$name.log" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# run_gate <label> — runs the SHIPPED gate step on the outputs of the last ensure run and
# leaves the posted comment body in $STATE/<label>.comment.md. The step exits 3 by design
# (the required check stays RED); the body is its product.
run_gate() {
  local label="$1" src="$2" rc=0
  rm -f /tmp/inconclusive-comment.md
  ENGINE_UNRESOLVED=true \
  PIN_TAG="$TAG" PIN_FROM="vars.CHARLY_VERSION" \
  RELEASE_STATE="$(kv "$src" release_state)" \
  ASSET_STATE="$(kv "$src" asset_state)" \
  ASSET_URL="$(kv "$src" asset_url)" \
  ASSET_HTTP="$(kv "$src" asset_http)" \
  ASSET_BYTES="$(kv "$src" asset_bytes)" \
  ASSET_FORM="$(kv "$src" asset_form)" \
  INCONCLUSIVE_INFRA=true INCONCLUSIVE_CLASS="" PROVIDER_UNANSWERED="" \
  PROVIDER_ERROR="" ENGINE_DEFECTIVE="" DISCARDED_VERDICT="" REVIEW_RC="" \
  ENGINE_TERMINAL="" ENGINE_REQUEST="" GH_TOKEN="fixture-token" PR_NUMBER=1 REPO=o/r \
    bash -e -o pipefail "$STATE/gate.sh" > "$STATE/$label.gate.log" 2>&1 || rc=$?
  [[ "$rc" -eq 3 ]] \
    || { cat "$STATE/$label.gate.log"; fail "the gate step did not exit 3 on an unobtainable engine (got $rc)"; }
  [[ -s /tmp/inconclusive-comment.md ]] \
    || fail "the gate step posted no comment body"
  cp /tmp/inconclusive-comment.md "$STATE/$label.comment.md"
}
kv() { sed -n "s/^$2=//p" "$1" | tail -1; }
expect() {  # expect <file> <literal> <what>
  grep -qF -- "$2" "$1" || { echo "--- $1 ---" >&2; cat "$1" >&2; fail "$3 (missing: $2)"; }
}
refute() {  # refute <file> <literal> <what>
  if grep -qF -- "$2" "$1"; then echo "--- $1 ---" >&2; cat "$1" >&2; fail "$3 (unexpected: $2)"; fi
}

# ---- case 1: both assets are what they claim -> the engine is installed ------------
rc="$(CASE_BIN_HTTP=200 CASE_BIN_BODY=elf CASE_PLG_HTTP=200 CASE_PLG_BODY=plugins.tar.gz \
      CASE_REL_CODE=404 CASE_TAG_CODE=404 CASE_REL_BODY=empty run_ensure case1)"
[[ "$rc" -eq 0 ]] || { cat "$STATE/case1.log"; fail "a good asset pair did not pass the probe (exit $rc)"; }
refute "$STATE/case1.out" 'engine_unresolved=true' "a good asset pair was reported as an unobtainable engine"
refute "$STATE/case1.log" '::error::' "a good asset pair emitted an error"
[[ -x "$STATE/charly-$TAG/bin/charly" ]] \
  || fail "the probe passed but the engine was not installed to \$D/bin/charly"
grep -qx "$STATE/charly-$TAG/bin" "$STATE/case1.path" \
  || fail "the probe passed but the engine's bin dir was not added to the job PATH"

# ---- case 2: the measured failure — 504 with GitHub's gateway page ----------------
rc="$(CASE_BIN_HTTP=504 CASE_BIN_BODY=gateway504.html CASE_PLG_HTTP=200 CASE_PLG_BODY=plugins.tar.gz \
      CASE_REL_CODE=200 CASE_REL_BODY=release-published.json CASE_TAG_CODE=200 run_ensure case2)"
[[ "$rc" -eq 0 ]] \
  || { cat "$STATE/case2.log"; fail "a 504 aborted the step (exit $rc) — it must hand the class to the parse step"; }
expect "$STATE/case2.out" 'engine_unresolved=true' "a 504 was not reported as an unobtainable engine"
expect "$STATE/case2.out" 'release_state=published' "a 504 on a published release did not report the release as published"
expect "$STATE/case2.out" 'asset_state=endpoint-failed' "a 504 was not classified as the download path failing"
expect "$STATE/case2.out" 'asset_http=504' "the asset's HTTP status was not captured"
expect "$STATE/case2.out" 'asset_bytes=92' "the gateway page's size was not captured"
expect "$STATE/case2.out" 'asset_form=an HTML page, not the asset' "the gateway page's form was not named"
expect "$STATE/case2.out" "asset_url=https://github.com/opencharly/charly/releases/download/$TAG/charly-linux-amd64" \
  "the class does not carry the failing asset's URL"
expect "$STATE/case2.log" '::error::' "the 504 did not raise an error annotation"
expect "$STATE/case2.log" 'HTTP 504' "the error annotation does not name the HTTP status"
expect "$STATE/case2.log" "$TAG/charly-linux-amd64" "the error annotation does not name the URL"
refute "$STATE/case2.log" 'partial upload' "the RETIRED misdiagnosis is still emitted"
[[ ! -e "$STATE/charly-$TAG/charly-plugins-linux-amd64.tar.gz" ]] \
  || fail "the second asset was fetched after the first had already failed"

# ---- case 3: 200 with an HTML body — the case a status check cannot catch ---------
rc="$(CASE_BIN_HTTP=200 CASE_BIN_BODY=html200.html CASE_PLG_HTTP=200 CASE_PLG_BODY=plugins.tar.gz \
      CASE_REL_CODE=200 CASE_REL_BODY=release-published.json CASE_TAG_CODE=200 run_ensure case3)"
[[ "$rc" -eq 0 ]] || { cat "$STATE/case3.log"; fail "a 200 HTML body aborted the step (exit $rc)"; }
expect "$STATE/case3.out" 'engine_unresolved=true' \
  "a 200 response carrying an HTML page was accepted as the engine — only a status check is not a check"
expect "$STATE/case3.out" 'asset_state=wrong-body' "a 200 with the wrong body was not classified as wrong-body"

# ---- case 4: the published release does not serve the asset (4xx) -----------------
rc="$(CASE_BIN_HTTP=404 CASE_BIN_BODY=empty CASE_PLG_HTTP=404 CASE_PLG_BODY=empty \
      CASE_REL_CODE=200 CASE_REL_BODY=release-published.json CASE_TAG_CODE=200 run_ensure case4)"
[[ "$rc" -eq 0 ]] || { cat "$STATE/case4.log"; fail "a 404 aborted the step (exit $rc)"; }
expect "$STATE/case4.out" 'asset_state=absent' "a 404 on a published release was not classified as an absent asset"
expect "$STATE/case4.out" 'release_state=published' "the release state was lost on a 404"

# ---- case 5: the tag itself does not exist — the PIN is wrong ---------------------
rc="$(CASE_BIN_HTTP=404 CASE_BIN_BODY=empty CASE_PLG_HTTP=404 CASE_PLG_BODY=empty \
      CASE_REL_CODE=404 CASE_TAG_CODE=404 CASE_REL_BODY=empty run_ensure case5)"
[[ "$rc" -eq 0 ]] || { cat "$STATE/case5.log"; fail "a dead tag aborted the step (exit $rc)"; }
expect "$STATE/case5.out" 'release_state=no-tag' "a pin naming no tag was not reported as no-tag"

# ---- case 6: binary fine, tarball 504 — the SECOND asset is measured --------------
rc="$(CASE_BIN_HTTP=200 CASE_BIN_BODY=elf CASE_PLG_HTTP=504 CASE_PLG_BODY=gateway504.html \
      CASE_REL_CODE=200 CASE_REL_BODY=release-published.json CASE_TAG_CODE=200 run_ensure case6)"
[[ "$rc" -eq 0 ]] || { cat "$STATE/case6.log"; fail "a tarball 504 aborted the step (exit $rc)"; }
expect "$STATE/case6.out" 'asset_state=endpoint-failed' "a tarball 504 was not classified as the download path failing"
expect "$STATE/case6.out" 'asset_url=' "the failing asset's URL is missing"
grep -q -- '/charly-plugins-linux-amd64.tar.gz$' "$STATE/case6.out" \
  || fail "the failing asset was not named as the plugins tarball"

# ---- the GATE's class table: the comment an author actually reads ------------------
run_gate case2 "$STATE/case2.out"
expect "$STATE/case2.comment.md" "class: asset unreachable — https://github.com/opencharly/charly/releases/download/$TAG/charly-linux-amd64 answered HTTP 504" \
  "the posted class does not name 'asset unreachable' with the URL and the HTTP status"
expect "$STATE/case2.comment.md" 'Verdict class: infra' \
  "an unobtainable engine no longer counts as infra — it would count toward auto-close"
expect "$STATE/case2.comment.md" 'RE-RUN' "the transient class does not name the re-run remedy"
expect "$STATE/case2.comment.md" 'Do NOT move the pin' \
  "the transient class does not warn against the pin move that cannot help"
refute "$STATE/case2.comment.md" 'partial upload' "the RETIRED misdiagnosis is still posted"

run_gate case4 "$STATE/case4.out"
expect "$STATE/case4.comment.md" "class: asset absent — the published release $TAG does not serve" \
  "an absent asset was not reported as the release's own defect"
expect "$STATE/case4.comment.md" 'gh release upload' "the absent-asset class does not name the publish remedy"

run_gate case5 "$STATE/case5.out"
expect "$STATE/case5.comment.md" 'the pin names no existing tag' \
  "a dead tag was not reported as a pin defect"
expect "$STATE/case5.comment.md" 'ls-remote --tags' "the dead-tag class does not name the tag-check remedy"

run_gate case3 "$STATE/case3.out"
expect "$STATE/case3.comment.md" "class: asset unreadable — https://github.com/opencharly/charly/releases/download/$TAG/charly-linux-amd64 answered HTTP 200" \
  "a 200 HTML body was not reported as an unreadable asset"

# ---- the negative controls: the coverage can FAIL ----------------------------------
if [[ "$SKIP_CONTROLS" -eq 0 ]]; then
  CONTROLS="$STATE/controls"; mkdir -p "$CONTROLS"

  # control 1: the MAGIC check is gone, so a 200 status alone accepts the engine — the
  # exact defect class case 3 exists for.
  python3 - "$WF" "$CONTROLS/no-magic.yml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needle = 'if [ "$BIN_HTTP" != "200" ] || [ "$BIN_MAGIC" != "7f454c46" ]; then'
assert needle in text, "the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(needle, 'if [ "$BIN_HTTP" != "200" ]; then', 1))
PY
  if bash "$0" --workflow "$CONTROLS/no-magic.yml" --no-controls >"$CONTROLS/no-magic.log" 2>&1; then
    fail "NEGATIVE CONTROL: accepting a 200 status without the magic must fail this coverage, but it passed"
  fi
  grep -q 'only a status check is not a check' "$CONTROLS/no-magic.log" \
    || { cat "$CONTROLS/no-magic.log"; fail "the no-magic control failed for the wrong reason"; }

  # control 2: the tarball is no longer measured — a plugins asset that cannot be
  # downloaded would then be discovered by `tar -xzf` instead of by the class.
  python3 - "$WF" "$CONTROLS/no-tarball-check.yml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needle = 'if [ "$PLG_HTTP" != "200" ] || [ "${PLG_MAGIC:0:6}" != "1f8b08" ]; then'
assert needle in text, "the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(needle, 'if false; then', 1))
PY
  if bash "$0" --workflow "$CONTROLS/no-tarball-check.yml" --no-controls >"$CONTROLS/no-tarball.log" 2>&1; then
    fail "NEGATIVE CONTROL: not measuring the second asset must fail this coverage, but it passed"
  fi
  # Without the tarball check the step aborts at `tar -xzf` instead of naming the
  # class — the abort IS the failure this control must produce.
  grep -q 'a tarball 504 aborted the step' "$CONTROLS/no-tarball.log" \
    || { cat "$CONTROLS/no-tarball.log"; fail "the no-tarball control failed for the wrong reason"; }

  # control 3: the gate's three-way table collapses back to one branch, so a dead tag
  # would be reported as a download-path failure — the misdiagnosis this change removes.
  python3 - "$WF" "$CONTROLS/collapsed-classes.yml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needle = 'if [ "$RELEASE_STATE" = "no-tag" ]; then'
assert needle in text, "the shipped shape moved"
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(needle, 'if false; then', 1))
PY
  if bash "$0" --workflow "$CONTROLS/collapsed-classes.yml" --no-controls >"$CONTROLS/collapsed.log" 2>&1; then
    fail "NEGATIVE CONTROL: collapsing the class table must fail this coverage, but it passed"
  fi
  grep -q 'a dead tag was not reported as a pin defect' "$CONTROLS/collapsed.log" \
    || { cat "$CONTROLS/collapsed.log"; fail "the collapsed-classes control failed for the wrong reason"; }
fi

echo "engine-pin-asset_test: OK (a good asset pair installs the engine; a 504 is 'asset unreachable' with its URL and status and stays infra with the RE-RUN remedy; a 200 HTML body is unreadable; a 4xx is an absent asset with the publish remedy; a dead tag is a pin defect; the tarball is measured too; three negative controls turn this RED)"
