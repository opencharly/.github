#!/usr/bin/env bash
# check-stalled-automerge.sh — detect PRs that can never land.
#
# opencharly/.github#175, measured on this host: native auto-merge armed + the org ruleset's
# required_status_checks.strict = true + a head that is BEHIND a moved base = a SILENT stall.
# GitHub's auto-merge does not update the head branch when the base moves, a BEHIND head cannot
# merge, and nothing goes red — so the PR reads as "queued" rather than "stuck". Measured window:
# 2026-10-07T22:43 → 2026-10-08T09:09, ~10 h, ZERO landings, while at least seven PRs sat green or
# armed (sdk#356, plugin-check#89, plugin-clean#12, plugin-deploy-pod#30, plugin-fleet#32, …).
#
# The state is ONE API field away and nothing read it before this script. That is the whole
# defect: not a missing capability, a missing reader.
#
# Scope, stated so a later reader does not over-trust it: this detects the shape the RCA measured —
# autoMergeRequest != null AND mergeStateStatus == BEHIND — and nothing else. A CANCELLED required
# check (a superseded validator run leaves `validate / validate` cancelled and the PR BLOCKED with
# auto-merge never armed) is a DIFFERENT shape with a different remedy; it is not covered here and
# is not claimed to be.
#
# Usage:   check-stalled-automerge.sh            scan the org, exit 1 when anything is stalled
#          check-stalled-automerge.sh --self-test
# Env:     CHARLY_ORG (default opencharly), GH_TOKEN

set -euo pipefail

ORG="${CHARLY_ORG:-opencharly}"

# The ONE query: the org's open PRs, with exactly the two fields that decide the stall. One call for
# the whole org — a per-PR `gh pr view` would be N calls to answer a question the search index
# already carries.
query() {
	cat <<GRAPHQL
{ search(query: "org:${ORG} is:pr is:open", type: ISSUE, first: 100) {
    nodes { ... on PullRequest { number repository { nameWithOwner } autoMergeRequest { enabledAt } mergeStateStatus } } } }
GRAPHQL
}

# select_stalled is a PURE filter over the GraphQL reply, so its rule can be tested against fixtures
# rather than only against whatever the live org happens to look like. Prints "<owner>/<repo>#<n>\t<status>".
select_stalled() {
	jq -r '
    .data.search.nodes[]
    | select(.autoMergeRequest != null and .mergeStateStatus == "BEHIND")
    | "\(.repository.nameWithOwner)#\(.number)\t\(.mergeStateStatus)"'
}

run_self_test() {
	local failed=0

	# A stalled PR: armed, and BEHIND.
	local stalled='{"data":{"search":{"nodes":[
		{"number":356,"repository":{"nameWithOwner":"opencharly/sdk"},"autoMergeRequest":{"enabledAt":"2026-10-07T22:43:58Z"},"mergeStateStatus":"BEHIND"}]}}}'
	# NOT stalled — each of the three ways a PR can look similar and be fine.
	local not_stalled='{"data":{"search":{"nodes":[
		{"number":1,"repository":{"nameWithOwner":"opencharly/a"},"autoMergeRequest":{"enabledAt":"x"},"mergeStateStatus":"CLEAN"},
		{"number":2,"repository":{"nameWithOwner":"opencharly/b"},"autoMergeRequest":null,"mergeStateStatus":"BEHIND"},
		{"number":3,"repository":{"nameWithOwner":"opencharly/c"},"autoMergeRequest":null,"mergeStateStatus":"BLOCKED"}]}}}'

	if [[ "$(printf '%s' "$stalled" | select_stalled)" != $'opencharly/sdk#356\tBEHIND' ]]; then
		echo "self-test: an armed+BEHIND PR was NOT selected" >&2
		failed=1
	fi
	if [[ -n "$(printf '%s' "$not_stalled" | select_stalled)" ]]; then
		echo "self-test: an unarmed or non-BEHIND PR WAS selected: $(printf '%s' "$not_stalled" | select_stalled)" >&2
		failed=1
	fi
	# The filter must be able to pass: guard against a filter that selects nothing ever, which would
	# make the whole detector a green no-op.
	if [[ -z "$(printf '%s' "$stalled" | select_stalled)" ]]; then
		echo "self-test: the filter selected nothing at all — it cannot fail, so it proves nothing" >&2
		failed=1
	fi

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
		echo "check-stalled-automerge: no armed+BEHIND PRs in ${ORG} — nothing is silently parked"
		return 0
	fi

	echo "check-stalled-automerge: ARMED but BEHIND — these CANNOT merge and nothing else will say so:"
	while IFS=$'\t' read -r pr status; do
		echo "  ${pr}  (${status})  →  gh pr update-branch ${pr##*#} --repo ${pr%#*}"
	done <<<"$stalled"
	echo
	echo "A merge, never a force-push: the branch update is the sanctioned remedy (opencharly/.github#175)."
	return 1
}

main "$@"
