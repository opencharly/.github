#!/usr/bin/env bash
# proof-engine-pin.sh — run the SHIPPED engine-pin branch LIVE, and every class it can
# report, so the operator's evidence comes from the code that ships (opencharly/.github#285,
# opencharly/charly#723).
#
# WHY A HARNESS AND NOT A DISPATCH. Driving the unobtainable-engine path through the org
# would post an INCONCLUSIVE comment and a RED required check on whatever real PR it
# targeted. This runs the SAME shell the workflow runs — the step text extracted by the
# shared extractor, so the harness cannot drift from the shipped step — and prints what
# each class actually produces.
#
# THE DETECTOR UNDER TEST. The gate fetches the pinned release's two assets and, when it
# cannot, reports a MEASURED class. The old code fetched with `curl -fsSL` and called every
# failure "a partial upload"; the class was wrong for the failure that actually happens
# (GitHub's release-download path answering HTTP 504 with a 92-byte gateway page while the
# release API reports every asset `uploaded`), and the remedy it named was already true.
#
# WHAT THIS PROVES, AND WHICH LEGS CAN FAIL.
#   [1] LIVE, a release whose assets answer  -> the probe PASSES and installs the binary.
#   [2] LIVE, a second tag                   -> its real status is REPORTED, never assumed:
#       the endpoint is INTERMITTENT and per-OBJECT (measured 2026-11-09: the release the
#       issue was filed against answered 200 twice in a row while the NEWEST release
#       answered 504 twice), so a tag that failed when #285 was written can answer later.
#       A live 504 that happens during this run is reported as the class it produces.
#   [3] 504 replayed from GitHub's own 92-byte gateway page  -> `endpoint-failed`, the
#       class naming the URL and the HTTP status. DETERMINISTIC: this leg ASSERTS.
#   [4] 200 serving an HTML page            -> `wrong-body`. DETERMINISTIC: ASSERTS.
#   [5] 404                                 -> `absent`. DETERMINISTIC: ASSERTS.
# Each failing class then runs the SHIPPED gate step and prints the comment an author
# would read, including the remedy, because that comment is the only thing they see.
#
# The replay legs substitute ONE thing in the shipped text: the release URL BASE, so the
# asset hop is a local endpoint this harness controls. Everything else — the probe, the
# magic check, the release/tag API classification (which still calls GitHub for a real
# tag), the outputs, and the gate step — is the shipped text verbatim.
#
# usage: bash proof-engine-pin.sh [<tag-that-answers> [<second-tag>]]
#   defaults: v2026.313.0209 (the current release), v2026.308.2259 (the tag #285 named).
#   Needs `gh` (the API classification and its token) and python3 (the replay endpoints).
set -euo pipefail

GOOD_TAG="${1:-v2026.313.0209}"
OTHER_TAG="${2:-v2026.308.2259}"
WF="${WF:-.github/workflows/pr-validator.yml}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
GW_PID=""; H200_PID=""; GW404_PID=""; SERVE_PID=""
cleanup() {
  for pid in "$GW_PID" "$H200_PID" "$GW404_PID"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"; export GH_TOKEN

# The extraction is the SHARED one (R2): the harness judges the shipped text and must read
# it exactly the way the step-level tests read it.
# shellcheck source=scripts/lib-org.sh
source "$HERE/lib-org.sh"
extract_step_run "$WF" '^ *- name: "Ensure charly' "$TMP/ensure.sh"
extract_step_run "$WF" '^ *- name: Gate [(]inconclusive[)]$' "$TMP/gate.sh"
[[ -s "$TMP/ensure.sh" && -s "$TMP/gate.sh" ]] || { echo "FATAL: steps not found in $WF" >&2; exit 1; }
sed "s|\${{ runner.temp }}|$TMP|g" "$TMP/ensure.sh" > "$TMP/ensure.base.sh"
kv() { sed -n "s/^$2=//p" "$1" | tail -1; }
fail() { echo "PROOF FAILED: $*" >&2; exit 1; }

# run_ensure <label> <script> <tag> — the shipped step (or its replay variant), live, and
# its outputs printed. Leaves $TMP/<label>.out and $TMP/<label>.log.
run_ensure() {
  local label="$1" script="$2" tag="$3" rc=0
  rm -rf "${TMP:?}/charly-$tag"
  : > "$TMP/$label.out"
  CHARLY_VERSION="$tag" PIN_FROM="vars.CHARLY_VERSION" \
  GITHUB_OUTPUT="$TMP/$label.out" GITHUB_PATH="$TMP/$label.path" GITHUB_ENV="$TMP/$label.env" \
    bash -e -o pipefail "$script" > "$TMP/$label.log" 2>&1 || rc=$?
  echo "\$ CHARLY_VERSION=$tag bash <$label>   -> exit=$rc"
  grep -E '::error::|::warning::on-PATH' "$TMP/$label.log" | sed "s|$TMP|\$RUNNER_TEMP|g" || true
  return 0
  if [[ -s "$TMP/$label.out" ]]; then
    echo "--- GITHUB_OUTPUT ---"; cat "$TMP/$label.out"
  else
    echo "(the probe PASSED: the engine is installed at \$RUNNER_TEMP/charly-$tag/bin/charly)"
  fi
}

# run_gate <label> — the SHIPPED gate step on $TMP/<label>.out, and the comment body it
# writes. The step exits 3 by design: the required check stays RED, unreviewed code never
# merges. The body is the only thing an author sees, so it is printed in full.
run_gate() {
  local label="$1" src="$TMP/$1.out" rc=0
  rm -f /tmp/inconclusive-comment.md
  ENGINE_UNRESOLVED=true PIN_TAG="$(kv "$src" pin_tag)" PIN_FROM="$(kv "$src" pin_from)" \
  RELEASE_STATE="$(kv "$src" release_state)" ASSET_STATE="$(kv "$src" asset_state)" \
  ASSET_URL="$(kv "$src" asset_url)" ASSET_HTTP="$(kv "$src" asset_http)" \
  ASSET_BYTES="$(kv "$src" asset_bytes)" ASSET_FORM="$(kv "$src" asset_form)" \
  INCONCLUSIVE_INFRA=true INCONCLUSIVE_CLASS="" PROVIDER_UNANSWERED="" \
  PROVIDER_ERROR="" ENGINE_DEFECTIVE="" DISCARDED_VERDICT="" REVIEW_RC="" \
  ENGINE_TERMINAL="" ENGINE_REQUEST="" PR_NUMBER=0 REPO=opencharly/.github GH_TOKEN="$GH_TOKEN" \
    bash -e -o pipefail "$TMP/gate.sh" > "$TMP/$label.gate.log" 2>&1 || rc=$?
  echo "--- the gate step, and the comment it would post (step exit=$rc; 3 is fail-closed) ---"
  [[ -s /tmp/inconclusive-comment.md ]] || { echo "no comment body written"; return; }
  sed -n '1,10p' /tmp/inconclusive-comment.md
  grep -E '^[0-9]+\. ' /tmp/inconclusive-comment.md || true
}

# serve <status> <file> <portfile> — a REAL local HTTP endpoint returning <status> and
# <file>'s bytes, so the replay legs exercise curl and the probe, not a shell stub.
serve() {
  local status="$1" body="$2" portfile="$3"
  # A REAL local HTTP endpoint, so the replay legs exercise curl and the probe rather
  # than a shell stub. Its PID lands in SERVE_PID (a global, not command-substituted, so
  # the parent shell owns the process and can reap it).
  python3 - "$status" "$body" "$portfile" <<'PY' &
import http.server, socketserver, sys
status, body, portfile = int(sys.argv[1]), sys.argv[2], sys.argv[3]
data = open(body, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(status)
        self.send_header("Content-Type", "text/html" if data[:1] == b"<" else "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
with open(portfile, "w") as fh: fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY
  SERVE_PID=$!
  # READINESS, not a retry: python binds and listens BEFORE it writes the port file, so
  # the wait is only for that write to land — a bounded poll for a socket this harness
  # just created, and the one synchronous primitive bash offers for it.
  local i
  for i in $(seq 1 100); do [[ -s "$portfile" ]] && return 0; sleep 0.05; done
  echo "FATAL: the replay endpoint did not start" >&2; return 1
}

# GitHub's OWN gateway page, byte for byte (92 bytes, content-type text/html): the body a
# 504 actually carries, so the replay exercises the measured shape and not a lookalike.
printf '<html><body><h1>504 Gateway Time-out</h1>\nThe server didn%st respond in time.\n</body></html>\n' "'" > "$TMP/gateway504.html"
[[ "$(wc -c < "$TMP/gateway504.html")" -eq 92 ]] || fail "the gateway fixture is not 92 bytes"
printf '<html><body>an interception page served with 200</body></html>\n' > "$TMP/html200.html"
: > "$TMP/empty"

echo "################ [1] + [2] LIVE: the two tags, MEASURED ################"
echo
echo "=== [1] live, $GOOD_TAG — the tag the pin names today"
run_ensure good "$TMP/ensure.base.sh" "$GOOD_TAG"
if [[ -s "$TMP/good.out" ]]; then
  run_gate good
else
  echo "OK: a reachable release installs the pinned engine (no class emitted)."
fi

echo
echo "=== [2] live, $OTHER_TAG — the tag #285 was filed against"
run_ensure other "$TMP/ensure.base.sh" "$OTHER_TAG"
if [[ -s "$TMP/other.out" ]]; then
  # A live 504 IS the class: print it, and confirm the release itself is intact through
  # the API asset route — the diagnostic #285 used, and deliberately NOT a gate fallback.
  run_gate other
  aid="$(gh api "repos/opencharly/charly/releases/tags/$OTHER_TAG" \
         --jq '.assets[]|select(.name=="charly-linux-amd64")|.id' 2>/dev/null || true)"
  if [[ -n "$aid" ]]; then
    echo "--- the SAME asset over the API route (diagnostic only; the gate does not fall back) ---"
    curl -sS -o /dev/null -w "api-route http=%{http_code} size=%{size_download}\n" -L \
      -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/opencharly/charly/releases/assets/$aid" || true
  fi
else
  echo "NOTE: this tag's assets ANSWERED during this run. The class is INTERMITTENT and"
  echo "      per-OBJECT, so the tag a report blamed yesterday can serve today — which is"
  echo "      exactly why the gate must MEASURE each fetch instead of inferring a cause"
  echo "      from the release's API state."
fi

echo
echo "################ [3] the 504 class, replayed from GitHub's own gateway page ################"
GW_PORTFILE="$TMP/gw.port"
serve 504 "$TMP/gateway504.html" "$GW_PORTFILE"; GW_PID="$SERVE_PID"
GW_BASE="http://127.0.0.1:$(cat "$GW_PORTFILE")"
sed "s|https://github.com/opencharly/charly/releases/download|$GW_BASE|g" "$TMP/ensure.base.sh" > "$TMP/ensure.504.sh"
run_ensure e504 "$TMP/ensure.504.sh" "$GOOD_TAG"
[[ -s "$TMP/e504.out" ]] || fail "a 504 was accepted as the engine"
[[ "$(kv "$TMP/e504.out" asset_state)" = "endpoint-failed" ]] || fail "a 504 was not classified endpoint-failed"
[[ "$(kv "$TMP/e504.out" asset_http)" = "504" ]] || fail "the 504 status was not captured"
[[ "$(kv "$TMP/e504.out" asset_bytes)" = "92" ]] || fail "the gateway page's size was not captured"
run_gate e504
grep -q 'class: asset unreachable — http://127.0.0.1:' /tmp/inconclusive-comment.md \
  || fail "the posted class does not name 'asset unreachable' with the URL"
grep -q 'answered HTTP 504' /tmp/inconclusive-comment.md \
  || fail "the posted class does not name the HTTP status"
grep -q 'Verdict class: infra' /tmp/inconclusive-comment.md \
  || fail "the class is no longer excluded from the auto-close count"
grep -q 'Do NOT move the pin' /tmp/inconclusive-comment.md \
  || fail "the transient class does not name the RE-RUN remedy"
echo "OK: 504 -> 'asset unreachable' with the URL and the HTTP status, infra, RE-RUN."

echo
echo "################ [4] a 200 that is NOT the engine ################"
H200_PORTFILE="$TMP/h200.port"
serve 200 "$TMP/html200.html" "$H200_PORTFILE"; H200_PID="$SERVE_PID"
H200_BASE="http://127.0.0.1:$(cat "$H200_PORTFILE")"
sed "s|https://github.com/opencharly/charly/releases/download|$H200_BASE|g" "$TMP/ensure.base.sh" > "$TMP/ensure.200.sh"
run_ensure e200 "$TMP/ensure.200.sh" "$GOOD_TAG"
[[ -s "$TMP/e200.out" ]] || fail "a 200 HTML page was accepted as the engine (only a status check is not a check)"
[[ "$(kv "$TMP/e200.out" asset_state)" = "wrong-body" ]] || fail "a 200 HTML page was not classified wrong-body"
run_gate e200
grep -q 'class: asset unreadable' /tmp/inconclusive-comment.md || fail "a 200 HTML page was not reported as unreadable"
echo "OK: 200 + HTML -> 'asset unreadable' (the case a status-only detector accepts)."

echo
echo "################ [5] an asset the release does not serve (404) ################"
GW404_PORTFILE="$TMP/gw404.port"
serve 404 "$TMP/empty" "$GW404_PORTFILE"; GW404_PID="$SERVE_PID"
GW404_BASE="http://127.0.0.1:$(cat "$GW404_PORTFILE")"
sed "s|https://github.com/opencharly/charly/releases/download|$GW404_BASE|g" "$TMP/ensure.base.sh" > "$TMP/ensure.404.sh"
run_ensure e404 "$TMP/ensure.404.sh" "$GOOD_TAG"
[[ -s "$TMP/e404.out" ]] || fail "a 404 was accepted as the engine"
[[ "$(kv "$TMP/e404.out" asset_state)" = "absent" ]] || fail "a 404 on a published release was not classified absent"
[[ "$(kv "$TMP/e404.out" release_state)" = "published" ]] || fail "the release state was lost on a 404"
run_gate e404
grep -q 'class: asset absent' /tmp/inconclusive-comment.md || fail "a 404 was not reported as an absent asset"
grep -q 'gh release upload' /tmp/inconclusive-comment.md || fail "the absent class does not name the publish remedy"
echo "OK: 404 -> 'asset absent' with the publish remedy."
kill "$GW404_PID" 2>/dev/null || true

echo
echo "################ summary ################"
printf '%-8s %-16s %-16s %-5s %-5s %s\n' leg release_state asset_state http bytes asset_url
for f in good other e504 e200 e404; do
  [[ -s "$TMP/$f.out" ]] || { printf '%-8s %s\n' "$f" "(passed: the engine was installed)"; continue; }
  printf '%-8s %-16s %-16s %-5s %-5s %s\n' "$f" "$(kv "$TMP/$f.out" release_state)" \
    "$(kv "$TMP/$f.out" asset_state)" "$(kv "$TMP/$f.out" asset_http)" \
    "$(kv "$TMP/$f.out" asset_bytes)" "$(kv "$TMP/$f.out" asset_url)"
done
echo
echo "PROOF PASSED: the 504/200-HTML/404 classes each name themselves (URL + HTTP status), the"
echo "transient class stays infra and prescribes a RE-RUN (never a pin move), and the gate step"
echo "still exits 3 so an unreviewed diff can never merge."
