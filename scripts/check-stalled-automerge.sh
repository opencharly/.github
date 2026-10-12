#!/usr/bin/env bash
# check-stalled-automerge.sh — detect PRs that can never land, SILENTLY.
#
# Three shapes, each measured on a live stall. The subject of this script is not "a PR that is
# blocked" — a red PR gets read — but a PR that is blocked while reading as "queued".
#
#   1. ARMED + BEHIND (opencharly/.github#175). Native auto-merge armed + the org ruleset's
#      required_status_checks.strict = true + a head behind a moved base. GitHub's auto-merge does
#      not update the head branch when the base moves, a BEHIND head cannot merge, and nothing goes
#      red. Measured 2026-10-07T22:43 → 2026-10-08T09:09 (~10 h, zero landings) while at least seven
#      PRs sat green or armed (sdk#356, plugin-check#89, plugin-clean#12, plugin-deploy-pod#30, …).
#
#   2. ARMED + DIRTY (opencharly/.github#175 comment 6084457430). Strictly worse than BEHIND and
#      needing its own handling: `gh pr update-branch` CANNOT resolve a conflict, so an armed
#      conflicted PR waits forever with no signal at all (measured on charly#432: armed, DIRTY, ~30 h).
#
#   3. THE REQUIRED CHECK NEVER RESOLVED (opencharly/.github#186). A superseded validator run leaves
#      `validate / validate` CANCELLED on the head. Arming happens INSIDE the validator run — the run
#      that was cancelled — so the PR sits BLOCKED with autoMergeRequest == null and reads as
#      "queued": nothing re-dispatches it and no check ever concludes. MEASURED on this repo's own
#      #185: auto-merge armed = Y *and* the required check CANCELLED, waiting on a run that would
#      never conclude. The class is the whole non-resolving vocabulary, because a branch protection
#      rule requires EVERY same-name run on the head to pass: a completed CANCELLED / TIMED_OUT /
#      STALE / STARTUP_FAILURE / ACTION_REQUIRED run keeps the PR blocked even when a LATER run of
#      the same name succeeded (the POISON state) — so this reads EVERY run of the required context
#      on the head, never only the newest.
#
# SCOPE, stated so a later reader does not over-trust it (corrected 2026-10-12; this paragraph used to
# declare the cancelled shape out of scope):
#   * An UNARMED head that is BEHIND or DIRTY is NOT selected. The armed requirement is the shape
#     #175 measured; an unarmed behind head shows a disabled merge button and is not the silent stall
#     this script exists for.
#   * A head carrying NO run of the required context at all is NOT selected. Deciding whether that is
#     a stall or by design needs the ruleset SCOPE derivation (a fork or an excluded repo receives no
#     org gate at all: opencharly/.github#179, scripts/lib-org.sh `discover_excludes`), which this
#     script deliberately does not read. Under-reporting is the honest failure mode here: a detector
#     that cries wolf on ~16 forks is switched off, and then it detects nothing.
#
# Usage:   check-stalled-automerge.sh            scan the org, exit 1 when anything is stalled
#          check-stalled-automerge.sh --self-test
# Env:     CHARLY_ORG (default opencharly), REQUIRED_CHECK (default "validate / validate"), GH_TOKEN

set -euo pipefail

ORG="${CHARLY_ORG:-opencharly}"

# The ONE required context the org ruleset names (org-wide required workflow & main protection,
# required_status_checks.strict = true). It is named here rather than discovered because the ruleset
# API is a second, differently-shaped read; when the ruleset gains a second required context, this
# constant and its row in scripts/governance-claims.tsv move together.
REQUIRED_CHECK="${REQUIRED_CHECK:-validate / validate}"

# The conclusions that do NOT resolve: a completed run with any of these blocks the merge gate, and
# none of them ever turns green on its own. FAILURE is deliberately absent — a red required check is a
# verdict, which is LOUD (the collapsed rollup renders it as failing), and this script's subject is
# the quiet ones.
NON_RESOLVING='["CANCELLED","TIMED_OUT","STALE","STARTUP_FAILURE","ACTION_REQUIRED"]'

# The ONE query: the org's open PRs with exactly the fields that decide all three shapes. One call for
# the whole org — a per-PR `gh pr view` (or a per-head `check-runs` read) would be N calls to answer a
# question the search index already carries.
query() {
	cat <<GRAPHQL
{ search(query: "org:${ORG} is:pr is:open", type: ISSUE, first: 100) {
    nodes { ... on PullRequest { number repository { nameWithOwner } autoMergeRequest { enabledAt } mergeStateStatus
      statusCheckRollup { contexts(first: 100) { nodes { __typename ... on CheckRun { name status conclusion } } } } } } } }
GRAPHQL
}

# select_stalled is a PURE filter over the GraphQL reply, so its rule can be tested against fixtures
# rather than only against whatever the live org happens to look like.
# Prints "<owner>/<repo>#<n>\t<class>\t<detail>"; class is BEHIND | DIRTY | CHECK.
select_stalled() {
	jq -r --arg required "${REQUIRED_CHECK}" --argjson nonresolving "${NON_RESOLVING}" '
    def pr_name: "\(.repository.nameWithOwner)#\(.number)";
    .data.search.nodes[]
    | . as $pr
    | ($pr.autoMergeRequest != null) as $armed
    | ([ (($pr.statusCheckRollup // {}) | .contexts.nodes // [])[]
         | select(.name == $required)
         | select((.conclusion // "") as $c | $nonresolving | index($c)) ]
       | first) as $unresolved
    | if $armed and $pr.mergeStateStatus == "BEHIND" then "\($pr | pr_name)\tBEHIND\t\($pr.mergeStateStatus)"
      elif $armed and $pr.mergeStateStatus == "DIRTY" then "\($pr | pr_name)\tDIRTY\t\($pr.mergeStateStatus)"
      elif $unresolved != null then "\($pr | pr_name)\tCHECK\t\($required): \($unresolved.conclusion)"
      else empty end'
}

# report_stalled prints each stalled PR WITH the remedy for its class, one line per PR. Extracted from
# main so the stalled branch — the detector's actual output — is driven by the self-test rather than
# only by a live run that happened to take the exit-0 branch.
report_stalled() {
	local behind="" dirty="" check=""
	while IFS=$'\t' read -r pr class detail; do
		[[ -z "${pr}" ]] && continue
		case "${class}" in
		BEHIND) behind+="  ${pr}  (${detail})  →  merge the base in, re-key the body, then push"$'\n' ;;
		DIRTY) dirty+="  ${pr}  (${detail})  →  a HUMAN resolves the conflict and merges: gh pr update-branch CANNOT"$'\n' ;;
		CHECK) check+="  ${pr}  (${detail})  →  gh api -X POST repos/${pr%#*}/actions/runs/<id>/rerun"$'\n' ;;
		esac
	done <<<"$1"

	if [[ -n "${behind}" ]]; then
		echo "check-stalled-automerge: ARMED but BEHIND — these CANNOT merge and nothing else will say so:"
		printf '%s' "${behind}"
		echo "  A merge, never a force-push. The update and the body re-key are ONE act, in that order"
		echo "  (gh pr update-branch pushes a head the body then contradicts — opencharly/.github#175)."
	fi
	if [[ -n "${dirty}" ]]; then
		echo "check-stalled-automerge: ARMED but DIRTY — a moved base AND a conflict, so NO branch update can help:"
		printf '%s' "${dirty}"
	fi
	if [[ -n "${check}" ]]; then
		echo "check-stalled-automerge: THE REQUIRED CHECK NEVER RESOLVED — auto-merge cannot arm, or waits on nothing:"
		printf '%s' "${check}"
		echo "  RE-RUNNING IS A FRESH REVIEW and replaces the verdict — measured: a re-run turned a PASS"
		echo "  into a BLOCK carrying a finding the first run had not raised (opencharly/charly#871)."
		echo "  Never re-dispatch a head you have not read and fixed (opencharly/.github#186)."
	fi
}

run_self_test() {
	local failed=0

	# STALLED — one fixture per class. Each carries ONLY the field its class keys on, so a class cannot
	# pass by reading another class's field.
	local behind='{"data":{"search":{"nodes":[
		{"number":356,"repository":{"nameWithOwner":"opencharly/sdk"},"autoMergeRequest":{"enabledAt":"2026-10-07T22:43:58Z"},"mergeStateStatus":"BEHIND","statusCheckRollup":{"contexts":{"nodes":[]}}}]}}}'
	local dirty='{"data":{"search":{"nodes":[
		{"number":432,"repository":{"nameWithOwner":"opencharly/charly"},"autoMergeRequest":{"enabledAt":"2026-10-08T00:00:00Z"},"mergeStateStatus":"DIRTY","statusCheckRollup":{"contexts":{"nodes":[]}}}]}}}'
	# #186's filing instance: UNARMED, the required check CANCELLED, and nothing will re-dispatch it.
	local cancelled='{"data":{"search":{"nodes":[
		{"number":871,"repository":{"nameWithOwner":"opencharly/charly"},"autoMergeRequest":null,"mergeStateStatus":"BLOCKED","statusCheckRollup":{"contexts":{"nodes":[
			{"__typename":"CheckRun","name":"validate / validate","status":"COMPLETED","conclusion":"CANCELLED"}]}}}]}}}'
	# #185's instance: ARMED *and* cancelled — waiting on a run that will never conclude.
	local armed_cancelled='{"data":{"search":{"nodes":[
		{"number":185,"repository":{"nameWithOwner":"opencharly/.github"},"autoMergeRequest":{"enabledAt":"2026-10-09T21:05:00Z"},"mergeStateStatus":"BLOCKED","statusCheckRollup":{"contexts":{"nodes":[
			{"__typename":"CheckRun","name":"validate / validate","status":"COMPLETED","conclusion":"CANCELLED"}]}}}]}}}'
	# POISON: an OLDER cancelled run beside a NEWER success keeps the PR blocked forever, so reading
	# only the newest run would miss it. This fixture is the reason the filter scans every run.
	local poison='{"data":{"search":{"nodes":[
		{"number":460,"repository":{"nameWithOwner":"opencharly/opencharly"},"autoMergeRequest":{"enabledAt":"2026-10-09T00:00:00Z"},"mergeStateStatus":"BLOCKED","statusCheckRollup":{"contexts":{"nodes":[
			{"__typename":"CheckRun","name":"validate / validate","status":"COMPLETED","conclusion":"CANCELLED"},
			{"__typename":"CheckRun","name":"validate / validate","status":"COMPLETED","conclusion":"SUCCESS"}]}}}]}}}'

	# NOT stalled — every near-miss this rule must reject.
	local not_stalled='{"data":{"search":{"nodes":[
		{"number":1,"repository":{"nameWithOwner":"opencharly/a"},"autoMergeRequest":{"enabledAt":"x"},"mergeStateStatus":"CLEAN","statusCheckRollup":{"contexts":{"nodes":[]}}},
		{"number":2,"repository":{"nameWithOwner":"opencharly/b"},"autoMergeRequest":null,"mergeStateStatus":"BEHIND","statusCheckRollup":{"contexts":{"nodes":[]}}},
		{"number":3,"repository":{"nameWithOwner":"opencharly/c"},"autoMergeRequest":null,"mergeStateStatus":"BLOCKED","statusCheckRollup":{"contexts":{"nodes":[
			{"__typename":"CheckRun","name":"validate / validate","status":"COMPLETED","conclusion":"FAILURE"}]}}},
		{"number":4,"repository":{"nameWithOwner":"opencharly/d"},"autoMergeRequest":{"enabledAt":"x"},"mergeStateStatus":"BLOCKED","statusCheckRollup":{"contexts":{"nodes":[
			{"__typename":"CheckRun","name":"validate / validate","status":"COMPLETED","conclusion":"SUCCESS"}]}}},
		{"number":5,"repository":{"nameWithOwner":"opencharly/e"},"autoMergeRequest":{"enabledAt":"x"},"mergeStateStatus":"BLOCKED","statusCheckRollup":{"contexts":{"nodes":[
			{"__typename":"CheckRun","name":"validate / validate","status":"IN_PROGRESS","conclusion":null}]}}},
		{"number":6,"repository":{"nameWithOwner":"opencharly/f"},"autoMergeRequest":{"enabledAt":"x"},"mergeStateStatus":"UNSTABLE","statusCheckRollup":{"contexts":{"nodes":[]}}},
		{"number":7,"repository":{"nameWithOwner":"opencharly/g"},"autoMergeRequest":{"enabledAt":"x"},"mergeStateStatus":"BLOCKED","statusCheckRollup":{"contexts":{"nodes":[
			{"__typename":"CheckRun","name":"some other check","status":"COMPLETED","conclusion":"CANCELLED"}]}}}]}}}'

	expect() { # expect <label> <fixture> <expected output>
		local got; got="$(printf '%s' "$2" | select_stalled)"
		if [[ "$got" != "$3" ]]; then
			echo "self-test: $1: expected [${3}] got [${got}]" >&2
			failed=1
		fi
	}
	expect "armed+BEHIND"      "$behind"          $'opencharly/sdk#356\tBEHIND\tBEHIND'
	expect "armed+DIRTY"       "$dirty"           $'opencharly/charly#432\tDIRTY\tDIRTY'
	expect "unarmed+CANCELLED" "$cancelled"       $'opencharly/charly#871\tCHECK\tvalidate / validate: CANCELLED'
	expect "armed+CANCELLED"   "$armed_cancelled" $'opencharly/.github#185\tCHECK\tvalidate / validate: CANCELLED'
	expect "POISON pair"       "$poison"          $'opencharly/opencharly#460\tCHECK\tvalidate / validate: CANCELLED'
	expect "every near-miss"   "$not_stalled"     ''

	# The STALLED BRANCH is the detector's actual product: the exit code says something is wrong, and
	# these lines say WHICH class it is and what to do. A live scan that took the exit-0 branch proves
	# nothing about them, so each class is driven here.
	local line
	line="$(report_stalled "$(printf '%s' "$behind" | select_stalled)")"
	[[ "$line" == *"ARMED but BEHIND"* ]]              || { echo "self-test: BEHIND branch lost its alarm header; got: ${line}" >&2; failed=1; }
	[[ "$line" == *"re-key the body"* ]]               || { echo "self-test: BEHIND branch lost its remedy; got: ${line}" >&2; failed=1; }
	line="$(report_stalled "$(printf '%s' "$dirty" | select_stalled)")"
	[[ "$line" == *"ARMED but DIRTY"* ]]               || { echo "self-test: DIRTY branch lost its alarm header; got: ${line}" >&2; failed=1; }
	[[ "$line" == *"a HUMAN resolves the conflict"* ]] || { echo "self-test: DIRTY branch lost its remedy; got: ${line}" >&2; failed=1; }
	line="$(report_stalled "$(printf '%s' "$cancelled" | select_stalled)")"
	[[ "$line" == *"NEVER RESOLVED"* ]]                || { echo "self-test: CHECK branch lost its alarm header; got: ${line}" >&2; failed=1; }
	[[ "$line" == *"actions/runs/<id>/rerun"* ]]       || { echo "self-test: CHECK branch lost its remedy; got: ${line}" >&2; failed=1; }
	[[ "$line" == *"RE-RUNNING IS A FRESH REVIEW"* ]]  || { echo "self-test: CHECK branch lost the re-opens-the-verdict caveat; got: ${line}" >&2; failed=1; }

	if [[ $failed -eq 0 ]]; then echo "check-stalled-automerge: self-test ok"; fi
	return $failed
}

main() {
	if [[ "${1:-}" == "--self-test" ]]; then run_self_test; return; fi

	local reply
	if ! reply="$(gh api graphql -f query="$(query)")"; then
		echo "check-stalled-automerge: could not query the org — refusing to report 'nothing stalled' from a failed read" >&2
		return 2
	fi

	local stalled
	stalled="$(printf '%s' "$reply" | select_stalled)"

	if [[ -z "$stalled" ]]; then
		echo "check-stalled-automerge: no armed+BEHIND, armed+DIRTY or non-resolving required-check PRs in ${ORG} — nothing is silently parked"
		return 0
	fi

	report_stalled "$stalled"
	echo
	echo "The sanctioned remedies, per class, are above (opencharly/.github#175, #186). A merge, never a force-push."
	return 1
}

main "$@"
