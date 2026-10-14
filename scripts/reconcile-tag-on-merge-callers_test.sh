#!/usr/bin/env bash
# _test.sh — offline tests for the two ORTHOGONAL dimensions. Never touches the network.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/reconcile-tag-on-merge-callers.sh
source "$HERE/reconcile-tag-on-merge-callers.sh" --source-only

pass=0 fail=0
check() { if [[ "$1" == "$2" ]]; then pass=$((pass+1)); echo "  ok   $3"
          else fail=$((fail+1)); echo "  FAIL $3: expected=$1 actual=$2"; fi }

CANON='name: t
# canonical prose
jobs:
  d:
    steps:
      - uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0, node24
        with: {script: "x"}'
MUT_ONLY='name: t
# canonical prose
jobs:
  d:
    steps:
      - uses: actions/github-script@v7
        with: {script: "x"}'
PROSE_ONLY='name: t
# OLD prose, frozen at an earlier template revision
jobs:
  d:
    steps:
      - uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0, node24
        with: {script: "x"}'
BOTH='name: t
# OLD prose, frozen at an earlier template revision
jobs:
  d:
    steps:
      - uses: actions/github-script@v7
        with: {script: "x"}'
NO_USES='name: t
# canonical prose
jobs:
  d:
    steps:
      - run: echo hi'

check pinned    "$(pin_state "$CANON")"      "canonical carries an immutable pin"
check mutable   "$(pin_state "$MUT_ONLY")"   "unpinned @v7 -> mutable (the T3 question)"
check pinned    "$(pin_state "$PROSE_ONLY")" "pinned pin, old prose -> still pinned"
check mutable   "$(pin_state "$BOTH")"       "both defects -> mutable on column 1"
check no-uses   "$(pin_state "$NO_USES")"    "no github-script step -> no-uses"
check absent    "$(pin_state "")"            "no caller -> absent"

check identical "$(prose_state "$CANON" "$CANON")"      "canonical prose -> identical"
check identical "$(prose_state "$CANON" "$MUT_ONLY")"   "only the pin differs -> prose identical"
check drifted   "$(prose_state "$CANON" "$PROSE_ONLY")" "old prose -> drifted (the revision question)"
check drifted   "$(prose_state "$CANON" "$BOTH")"       "both defects -> drifted on column 2"
check absent    "$(prose_state "$CANON" "")"            "no caller -> absent"

echo
echo "reconcile-tag-on-merge-callers_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
