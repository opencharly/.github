#!/usr/bin/env bash
set -euo pipefail

readonly ORG="${OPENCHARLY_ORG:-opencharly}"
readonly RULESET_NAME="main branch protection"
readonly APP_SLUG="charly-auto-merge"
readonly CONTEXT="validate / validate"

usage() {
  echo "usage: $0 {apply|verify}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
mode="$1"
[[ "$mode" == apply || "$mode" == verify ]] || usage

command -v gh >/dev/null

mapfile -t repos < <(
  gh repo list "$ORG" --limit 1000 \
    --json name,isArchived,isFork,defaultBranchRef \
    --jq '.[] | select(.isArchived == false and .isFork == false and .defaultBranchRef.name == "main") | .name' |
    sort
)
[[ ${#repos[@]} -gt 0 ]] || {
  echo "no active repositories discovered for $ORG" >&2
  exit 1
}

# The GitHub App that runs the org's tag-on-merge changelog writes. It is a
# scoped BYPASS actor of the main ruleset so its protected-main CHANGELOG
# commit can land (the legacy branch-protection API drops bypass fields; the
# ruleset API carries them). Resolved from the App endpoint; cache in
# OPENCHARLY_APP_ID if the API is unavailable.
app_id() {
  if [[ -n "${OPENCHARLY_APP_ID:-}" ]]; then
    echo "$OPENCHARLY_APP_ID"
    return
  fi
  gh api "apps/$APP_SLUG" --jq .id
}

APP_ID="$(app_id)"

ruleset_state() {
  # The list endpoint returns a summary (no rules/bypass); fetch the detail.
  local repo="$1"
  local id
  id="$(gh api "repos/$ORG/$repo/rulesets?includes_parents=true" \
    --jq ".[] | select(.name == \"$RULESET_NAME\" and .target == \"branch\" and .enforcement == \"active\") | .id" 2>/dev/null || true)"
  [[ -n "$id" ]] || return 1
  gh api "repos/$ORG/$repo/rulesets/$id" \
    --jq "{id, rules: [.rules[].type], checks: [.rules[] | select(.type == \"required_status_checks\") | .parameters.required_status_checks[].context], bypass: [.bypass_actors[] | select(.actor_type == \"Integration\") | .actor_id]}" 2>/dev/null
}

legacy_state() {
  local repo="$1"
  gh api "repos/$ORG/$repo/branches/main/protection" >/dev/null 2>&1 && echo "present" || echo "absent"
}

ruleset_payload() {
  cat <<JSON
{
  "name": "$RULESET_NAME",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "bypass_actors": [{"actor_id": $APP_ID, "actor_type": "Integration", "bypass_mode": "always"}],
  "rules": [
    {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": [{"context": "$CONTEXT"}]}},
    {"type": "non_fast_forward", "parameters": {}},
    {"type": "deletion", "parameters": {}},
    {"type": "creation", "parameters": {}}
  ]
}
JSON
}

if [[ "$mode" == apply ]]; then
  for repo in "${repos[@]}"; do
    existing="$(gh api "repos/$ORG/$repo/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
      echo "$repo: ruleset already present ($existing)"
    else
      id="$(gh api --method POST "repos/$ORG/$repo/rulesets" --input <(ruleset_payload) --jq .id)"
      echo "$repo: created ruleset $id"
    fi
    # the legacy protection blocks the app's changelog write (no bypass) — remove it
    legacy="$(legacy_state "$repo")"
    if [[ "$legacy" == "present" ]]; then
      gh api --method DELETE "repos/$ORG/$repo/branches/main/protection" >/dev/null
      echo "$repo: removed legacy branch protection"
    fi
  done
fi

fail=0
for repo in "${repos[@]}"; do
  legacy="$(legacy_state "$repo")"
  [[ "$legacy" == "absent" ]] || { echo "$repo: legacy branch protection still present" >&2; fail=1; }
  state="$(ruleset_state "$repo" || true)"
  [[ -n "$state" ]] || { echo "$repo: no active main ruleset" >&2; fail=1; continue; }
  ok=1
  echo "$state" | jq -e --arg ctx "$CONTEXT" '(.checks | index($ctx)) != null' >/dev/null || ok=0
  echo "$state" | jq -e --argjson app "$APP_ID" '(.bypass | index($app)) != null' >/dev/null || ok=0
  if [[ "$ok" == 1 ]]; then
    echo "$repo: verified main ruleset (required check + app bypass)"
  else
    echo "$repo: ruleset missing the required check and/or the app bypass" >&2
    fail=1
  fi
done
exit "$fail"
