#!/usr/bin/env python3
"""validator-gate-harness.py - in-repo, offline coverage for the decision chain of
.github/workflows/pr-validator.yml (the org-wide merge guardrail).

WHY THIS FILE EXISTS
  The gate classification (PASS / BLOCK / INCONCLUSIVE / AMBIGUOUS) and its exit
  codes are BEHAVIOUR, not prose. This harness runs the REAL run: bodies of the
  workflow against fakes for charly and gh, so the taxonomy is asserted in-repo
  instead of merely asserted in the PR body - and
  .github/workflows/validator-harness.yml RUNS this file on every pull_request
  (plus workflow_dispatch), so the coverage is WIRED IN, not just present.

WHAT IT DOES
  * Parses the workflow with a line-based YAML-subset reader (a small indentation
    extractor is enough for this file): python3 STDLIB ONLY - no PyYAML, no
    network, no third-party dependency.
  * Extracts the real run: bodies of the decision chain
        review -> Parse verdict -> Gate (BLOCK) | Gate (inconclusive)
                                | Gate (ambiguous) -> Enable auto-merge
  * Writes fake charly / gh executables into a temp dir prepended to PATH and
    drives every scenario through them.
  * Resolves GitHub expressions (${{ ... }}) in env: values AND in run: bodies from
    a context rebuilt at run time out of the PREVIOUS steps GITHUB_OUTPUT files -
    the same data flow GitHub uses - and evaluates each step if: condition against
    that context.
  * Runs each step with the shell GitHub uses for bash steps,
    bash --noprofile --norc -eo pipefail <script>, in workflow order, stopping at
    the first failing step. A scenario job exit code is therefore exactly the exit
    code GitHub would report for the required check.

SCENARIOS ASSERTED END TO END (exit code + classification output + PR comment)
  VERDICT classes
    pass                verdict PASS -> no gate fires -> auto-merge -> exit 0
    block               verdict BLOCK -> Gate (BLOCK)                 -> exit 1
    mixed               PASS + BLOCK in one review output
                        -> Gate (ambiguous)                           -> exit 2
    pass-with-error     the review exits NON-ZERO while writing a PASS line
                        into review.txt -> that untrusted output is
                        DISCARDED, the run is INCONCLUSIVE (exit 3), the
                        INCONCLUSIVE comment is posted and auto-merge is NOT
                        armed (the fail-closed guard on the captured rc).
    block-with-error    the review exits NON-ZERO carrying BLOCK -> a finding
                        is a finding: BLOCK is reported (exit 1), NOT
                        discarded into INCONCLUSIVE, and auto-merge is NOT
                        armed.
  INCONCLUSIVE classes (each -> exit 3 and the notice posted on the PR)
    provider-unanswered a stall marker in the log, no completed turn 1
    engine-defective    a COMPLETED turn 1 then a later failure
    provider-error      an explicit HTTP 4xx/5xx rejection
    unanswered-plus-error  both, with no completed turn 1
    mixed-signals       a completed turn 1 + a rejection (the composed class)
    non-error-status    a 2xx line must NOT be read as a refusal
    verdict-less        review.txt with no Verdict line
    attempt-cap         the engine's own terminal line
                        `exceeded AI_REVIEW_ATTEMPT_TIMEOUT` -> whole-request cap
    empty-completion    the engine's own terminal line
                        `produced no answer` -> empty completion
    engine-terminal-other  an engine class this workflow keeps no narrative
                        for (the REAL `PR too large to review in one context`
                        line) -> the gate DEFERS to the engine's own line and
                        quotes it, instead of falling through to a signature
  AUTO-CLOSE (the policy bound on an unreviewable PR)
    auto-close-at-threshold / -multi-page / -over-threshold-count /
    -below-threshold / -eval-counts / -infra-excluded / -infra-only-never-closes
    (ONE count-based bound is AI_REVIEW_AUTO_CLOSE_AFTER over `BLOCK` +
    engine/EVAL INCONCLUSIVE; a CLEAR INFRA INCONCLUSIVE carries
    `Verdict class: infra` and is EXCLUDED from the count — opencharly/.github#170)
  EVIDENCE
    pass-with-unwritable-evidence

  The three terminal-line classes (attempt-cap, empty-completion,
  engine-terminal-other) are the MISATTRIBUTION GUARD for opencharly/.github#133:
  before this change EVERY class the engine named was folded into "provider
  unanswered" - the classifier's fallback matched the bare substring
  `inconclusive:`, which is true for all of them - so each scenario asserts that the
  notice names ITS OWN class AND excludes the other classes' words. A canned
  narrative cannot satisfy them: they also require the run's own engine lines in the
  posted body. The provider-unanswered fake carries the engine's REAL terminal
  wording (`the LLM provider never answered or stopped streaming`), not the
  retired "all 3 attempts timed out" line, which described a per-turn retry loop the
  engine no longer has and certified behaviour it does not have.

  EVERY scenario also asserts the gh call log (expect_auto_merge): only the plain
  pass scenario may contain "gh pr merge --auto". The exit code alone would not
  prove the merge was not armed - a fail-closed classification must be proven,
  not inferred.

  It ALSO drives the REAL `run:` bodies of the org-wide candy-manifest reusable
  `.github/workflows/candy-validate.yml` offline (see run_harness()'s candy-validate
  section): the clean-skip branch (no `charly.yml` -> `present=false` -> the
  pin-required step's `if` resolves false -> GREEN) and the fail-loud branch
  (`charly.yml` present + `vars.CHARLY_VERSION` unset -> non-zero `::error::`). The
  happy path (clone + build the pinned charly) needs network and is not run offline.

  Plus structural guards: the review step contains NO in-job retry (no sleep, no
  for-attempt loop) - the R4 regression guard for the dropped retry band-aid; the
  header names no pinned release VERSION and no org-var VALUE (either would drift)
  and instead points at `gh variable get` and the run's own `request -` line; the
  header states the generation bounds are the cause-class (a cap DETECTS a long
  generation, it never BOUNDS one) and carries no re-run-and-see remedy; the three
  knobs the engine no longer reads (AI_REVIEW_MAX_ATTEMPTS, _MAX_TURNS,
  _TOOL_RESULT_MAX_BYTES) are neither forwarded nor kept in the review contract;
  and the emitted INCONCLUSIVE notice quotes the RUN'S OWN terminal + request
  lines instead of a canned narrative (opencharly/.github#133).

HOW TO RUN
    python3 .github/tests/validator-gate-harness.py
  exit 0 = every scenario and guard passed; exit 1 = a failure, printed with context.

ENVIRONMENT NOTES
  The workflow bodies address the runner absolute paths (/tmp/review.txt,
  /tmp/review.untrusted.txt, /tmp/review.log, /tmp/inconclusive-comment.md)
  literally. This harness removes those files before and after every scenario;
  everything else it writes lives in a temp dir. Because those paths are shared,
  the harness holds an EXCLUSIVE LOCK (LOCK_WAIT_SECONDS) for the whole run: a
  second instance WAITS instead of racing on /tmp/review.log, and fails fast with
  the reason if the holder never releases. Running two instances concurrently is
  therefore safe (serialized), not merely discouraged.
"""

import atexit
import fcntl
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

LOCK_WAIT_SECONDS = 600

NL = chr(10)
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
WORKFLOW_PATH = os.path.join(REPO_ROOT, ".github", "workflows", "pr-validator.yml")
# The workflow that RUNS this harness - asserted below, so the coverage can never
# silently regress into "present but invoked by nothing" (R10).
HARNESS_WORKFLOW_PATH = os.path.join(REPO_ROOT, ".github", "workflows",
                                     "validator-harness.yml")
# The org-wide candy-manifest reusable. Its skip / fail-loud branches are BEHAVIOUR, so
# they are driven offline here too (the same real-`run:`-body technique) instead of a
# static text check — see run_harness()'s candy-validate section.
CANDY_WORKFLOW_PATH = os.path.join(REPO_ROOT, ".github", "workflows",
                                   "candy-validate.yml")
# The org-wide REQUIRED caller of the reusable gate. A called workflow can only hold a
# permission its CALLER also grants, so the `issues` scope must be asserted on BOTH —
# asserting only the reusable would pass while the caller silently nullified it (`.github#173`).
CALLER_WORKFLOW_PATH = os.path.join(REPO_ROOT, ".github", "workflows",
                                    "org-wide-pr-validator-required.yml")

STEP_PREFIX = "      - "   # a step marker in this workflow
KEY_INDENT = 8             # name: / id: / if: / run: / env:
CHILD_INDENT = 10          # block-scalar and env entries
EXPR_RE = re.compile(r"[$][{][{](.*?)[}][}]", re.S)
PATH_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)((?:[.][A-Za-z0-9_-]+)+)")

RUNNER_PATHS = ["/tmp/review.txt", "/tmp/review.untrusted.txt", "/tmp/review.log",
                "/tmp/inconclusive-comment.md"]

# Temp dirs this harness creates. One functional test — the ensure-charly pin guard —
# downloads a ~383 MB pinned charly release into its temp dir; when these are never
# removed they accumulate across runs and exhaust the runner's disk quota (a measured
# EDQUOT after ~30 runs, which then fails EVERY scenario with "Disk quota exceeded"
# and looks like a code regression). Register every harness temp dir for removal at
# process exit so the coverage is self-cleaning and cannot poison later runs (R1).
_TMP_DIRS = []


def make_tmpdir(prefix):
    path = tempfile.mkdtemp(prefix=prefix)
    _TMP_DIRS.append(path)
    return path


def cleanup_tmpdirs():
    while _TMP_DIRS:
        shutil.rmtree(_TMP_DIRS.pop(), ignore_errors=True)


atexit.register(cleanup_tmpdirs)


class HarnessError(Exception):
    pass


class _Empty(str):
    """GitHub's empty context value: an empty string that STILL supports dotted lookup.

    `steps.parse.outputs.verdict` must evaluate to "" when the step has not run (or the
    output is absent) — the same as it does in Actions. A plain "" would raise on the
    next `.outputs`, so the empty value chains instead of terminating.
    """

    def __getattr__(self, name):
        return _EMPTY

    def __getitem__(self, name):
        return _EMPTY


_EMPTY = _Empty("")


class Ctx(object):
    """Dict-backed object for GitHub dotted lookups; a missing key is empty (GitHub)."""

    def __init__(self, data):
        object.__setattr__(self, "_data", data)

    def __getattr__(self, name):
        return self.lookup(name)

    def __getitem__(self, name):
        return self.lookup(name)

    def lookup(self, name):
        data = object.__getattribute__(self, "_data")
        if isinstance(data, dict) and name in data:
            value = data[name]
            return Ctx(value) if isinstance(value, dict) else value
        return _EMPTY

    def __str__(self):
        data = object.__getattribute__(self, "_data")
        return data if isinstance(data, str) else ""


def gh_to_py(expr):
    """Translate the small GitHub-expression subset this workflow uses into Python.

    Dotted context paths become bracket lookups so identifiers containing dashes
    (inputs.pr-number) survive, and && / || become and / or.
    """
    def repl(match):
        head = match.group(1)
        parts = [part for part in match.group(2).split(".") if part]
        return head + "".join("[" + repr(part) + "]" for part in parts)
    return PATH_RE.sub(repl, expr).replace("&&", " and ").replace("||", " or ")


def eval_gh(expr, ns):
    if "!" in expr.replace("!=", ""):
        raise HarnessError("unsupported '!' in GitHub expression: " + repr(expr))
    try:
        return eval(gh_to_py(expr), {"__builtins__": {}}, ns)
    except Exception as exc:
        raise HarnessError("cannot evaluate GitHub expression " + repr(expr) + ": " + str(exc))


def subst(text, ns):
    def repl(match):
        value = eval_gh(match.group(1).strip(), ns)
        if value is True:
            return "true"
        if value is False:
            return "false"
        return str(value)
    return EXPR_RE.sub(repl, text)


def unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def workflow_permissions(path):
    """Return a workflow's top-level `permissions:` mapping (scope -> value).

    A line-based read of the 2-space-indented block after a column-0 `permissions:`,
    matching this harness's no-PyYAML technique. Comments and blank lines are skipped;
    the first column-0 line after the block ends it.
    """
    if not os.path.exists(path):
        raise HarnessError("workflow not found: " + path)
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    result = {}
    in_block = False
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[0] != " ":  # a top-level (column-0) line
            in_block = line.strip() == "permissions:"
            continue
        if in_block:
            key, _, value = line.strip().partition(":")
            result[key.strip()] = value.strip()
    return result


def job_if(path, job_name):
    """Return a job's top-level `if:` expression (unquoted), or None when absent.

    A line-based read of the 2-space-indented `<job_name>:` block under `jobs:`, then
    the first 4-space-indented `if:` inside it — the harness's no-PyYAML technique.
    """
    if not os.path.exists(path):
        raise HarnessError("workflow not found: " + path)
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    in_job = False
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip()
        if indent == 2 and stripped == job_name + ":":
            in_job = True
            continue
        if in_job and indent == 2 and stripped.endswith(":"):
            break  # the next job begins
        if in_job and indent >= 4 and stripped.startswith("if:"):
            return unquote(stripped.partition(":")[2].strip())
    return None


def indent(text, pad):
    return NL.join(pad + line for line in text.splitlines())


def step_blocks(lines):
    """Split the file into per-step line groups (marker line + indented children)."""
    blocks = []
    current = None
    for line in lines:
        if line.startswith(STEP_PREFIX):
            if current is not None:
                blocks.append(current)
            current = [line]
            continue
        if current is None:
            continue
        if not line.strip() or line.startswith(" " * (KEY_INDENT)):
            current.append(line)
            continue
        blocks.append(current)
        current = None
    if current is not None:
        blocks.append(current)
    return blocks


def read_block(block_lines, start):
    """Return (block_text, next_index) for a block scalar at CHILD_INDENT."""
    body = []
    i = start
    while i < len(block_lines):
        line = block_lines[i]
        if not line.strip():
            body.append("")
            i += 1
            continue
        width = len(line) - len(line.lstrip(" "))
        if width < CHILD_INDENT:
            break
        body.append(line[CHILD_INDENT:])
        i += 1
    while body and body[-1] == "":
        body.pop()
    return NL.join(body) + NL, i


def parse_step(block_lines):
    step = {"name": None, "id": None, "if": None, "continue-on-error": None, "env": {}, "run": None}
    lines = [" " * KEY_INDENT + block_lines[0][len(STEP_PREFIX):]] + block_lines[1:]
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped:
            i += 1
            continue
        width = len(line) - len(line.lstrip(" "))
        if width != KEY_INDENT:
            i += 1
            continue
        key, _, value = stripped.partition(":")
        key = key.strip()
        value = value.strip()
        if key in ("name", "id", "if", "continue-on-error"):
            step[key] = unquote(value)
            i += 1
        elif key == "run":
            step["run"], i = read_block(lines, i + 1)
        elif key == "env":
            i += 1
            while i < len(lines):
                entry = lines[i]
                if not entry.strip():
                    i += 1
                    continue
                width = len(entry) - len(entry.lstrip(" "))
                if width < CHILD_INDENT:
                    break
                stripped = entry.strip()
                if stripped.startswith("#"):
                    i += 1  # YAML comment inside the env block
                    continue
                k, _, v = stripped.partition(":")
                # YAML strips the quotes of a quoted scalar, so a constant written as
                # `NAME: '1'` reaches the step as `1` — unquote here for the same reason
                # name/id/if are unquoted, or a quoted numeric constant would be handed to
                # the shell WITH its quotes and a numeric guard would reject it.
                step["env"][k.strip()] = unquote(v.strip())
                i += 1
        elif value in ("|", "|-", ">", ">-", "|+", ">+"):
            _, i = read_block(lines, i + 1)
        else:
            i += 1
    step["label"] = step["id"] or step["name"]
    return step


def parse_workflow(path):
    if not os.path.exists(path):
        raise HarnessError("workflow not found: " + path)
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    lines = text.splitlines()
    steps = [parse_step(b) for b in step_blocks(lines)]
    return text, steps


def find_step(steps, key, value):
    matches = [s for s in steps if s[key] == value]
    if len(matches) != 1:
        raise HarnessError("expected exactly one step with " + key + "=" + repr(value) +
                           ", found " + str(len(matches)))
    return matches[0]


FAKE_CHARLY = NL.join([
    "#!/usr/bin/env bash",
    "echo \"charly $*\" >> \"$FAKE_LOG\"",
    "out=\"\"",
    "prev=\"\"",
    "for a in \"$@\"; do",
    "  if [ \"$prev\" = \"--out\" ]; then out=\"$a\"; fi",
    "  prev=\"$a\"",
    "done",
    "case \"$FAKE_SCENARIO\" in",
    "  pass)",
    "    echo \"Verdict: PASS\" > \"$out\"",
    "    echo \"review complete (fake charly)\"",
    "    exit 0",
    "    ;;",
    "  block)",
    "    echo \"Verdict: BLOCK\" > \"$out\"",
    "    echo \"review complete (fake charly)\"",
    "    exit 0",
    "    ;;",
    "  provider-unanswered)",
    "    # A stall marker with NO completed turn 1. The terminal line is the engine's REAL",
    "    # wording (review.go's classify(), the timeout class) - the previous fake said",
    "    # 'all 3 attempts timed out', which described a per-turn RETRY LOOP the engine no",
    "    # longer has (R5) and a wording it never emits, so it certified behaviour the",
    "    # engine does not have. The classifier keys on that real wording, and the class",
    "    # must still reach the posted notice as 'provider unanswered'.",
    "    echo 'plugin-review[debug]: request — reasoning_effort=\"high\" max_tokens=262144 attempt_timeout=15m0s idle=3m0s' >&2",
    "    echo 'inconclusive: the LLM provider never answered or stopped streaming (idle bound 3m0s); this is NOT a review verdict - re-run the gate' >&2",
    "    exit 1",
    "    ;;",
    "  attempt-cap)",
    "    # The WHOLE-REQUEST CAP class, as the engine REALLY reports it (review.go's",
    "    # classify()): a distinct `inconclusive:` terminal line, together with the",
    "    # `request -` debug line that names the bounds in force. Before the #133 fix",
    "    # the workflow had no reader for either: it matched the substring",
    "    # `inconclusive:` and reported the run as PROVIDER UNANSWERED, so an operator",
    "    # read a provider story for a generation that was simply too long. Both lines",
    "    # must reach the posted notice unchanged.",
    "    echo 'plugin-review[debug]: request — reasoning_effort=\"medium\" max_tokens=262144 attempt_timeout=18m0s idle=3m0s sampling=temp=1.0,top_p=0.95 context_bytes=(system=32768 user=261820) files=76 comments=12' >&2",
    "    echo 'inconclusive: the turn exceeded AI_REVIEW_ATTEMPT_TIMEOUT=18m0s (whole-request cap; not retried) at reasoning_effort=\"medium\" max_tokens=262144; this is NOT a review verdict - bound the generation with AI_REVIEW_REASONING_EFFORT, or raise AI_REVIEW_ATTEMPT_TIMEOUT for a legitimately long turn' >&2",
    "    exit 1",
    "    ;;",
    "  empty-completion)",
    "    # The EMPTY-COMPLETION class: the shared max_tokens budget was spent on",
    "    # reasoning, so no answer was produced. A DIFFERENT terminal line, a DIFFERENT",
    "    # durable remedy, and - like attempt-cap - folded into PROVIDER UNANSWERED",
    "    # before the #133 fix. The two classes must never be conflated: the notice for",
    "    # one must exclude the other's words.",
    "    echo 'inconclusive: the model produced no answer and this is not retryable (empty completion: the shared max_tokens budget was spent on reasoning) ; raise AI_REVIEW_MAX_TOKENS (currently 65536) so the reasoning budget leaves room for the answer, or lower AI_REVIEW_REASONING_EFFORT (currently \"high\")' >&2",
    "    exit 1",
    "    ;;",
    "  engine-terminal-other)",
    "    # AN ENGINE CLASS THIS WORKFLOW KEEPS NO NARRATIVE FOR (opencharly/.github#133). The",
    "    # engine's FAIL-CLOSED context guard (review.go's budgetError) refused the request",
    "    # BEFORE sending it, and named that in its terminal line. Pre-fix the bare substring",
    "    # `inconclusive:` matched, so this run was reported as PROVIDER UNANSWERED and the",
    "    # operator was told to escalate to a provider that was never called - while the",
    "    # actionable instruction (`split the PR into smaller PRs`) sat unread in the log.",
    "    # The gate must now DEFER to the engine's own line and quote it verbatim.",
    "    echo 'plugin-review[debug]: request — reasoning_effort=\"high\" max_tokens=262144 attempt_timeout=15m0s idle=3m0s context_bytes=(system=32768 user=521820) files=214 comments=31' >&2",
    "    echo 'inconclusive: PR too large to review in one context — the input is ~166000 tokens and the output reserve is 262144, exceeding the 1048576-token window (margin 16384). This is NOT a review verdict; split the PR into smaller PRs, or raise AI_REVIEW_CONTEXT_TOKENS if the model window is larger' >&2",
    "    exit 1",
    "    ;;",
    "  engine-defective)",
    "    # The class the `engine_defective` branch exists for: the engine COMPLETED turn 1 (the",
    "    # endpoint answered) and a LATER turn failed (here: the whole-generation deadline). The",
    "    # log carries BOTH markers the workflow keys on - a completed `turn 1: N tool call(s)` AND",
    "    # a provider marker - which is exactly the context-dependent signature that a",
    "    # provider-egress story cannot explain. Pre-fix the workflow has no engine_defective",
    "    # branch, so this run is labelled a generic provider-unanswered run and the INCONCLUSIVE",
    "    # notice omits the class.",
    "    echo \"turn 1: 4 tool call(s)\" >&2",
    "    echo \"attempt 3 failed: Post \\\"https://provider.invalid/chat/completions\\\": context deadline exceeded (Client.Timeout exceeded while awaiting headers)\" >&2",
    "    exit 1",
    "    ;;",
    "  provider-error)",
    "    # The provider PARSED the request and REFUSED it (HTTP 4xx/5xx) — the class that must",
    "    # NOT be reported under the engine streaming narrative, because the engine never ran a",
    "    # turn. Live evidence: opencode Go answers 400 MissingSessionID for every request",
    "    # lacking an x-opencode-session header (2026-09-12, the org-wide verdict outage).",
    "    echo \"LLM 400: provider rejected the request (MissingSessionID: x-opencode-session required)\" >&2",
    "    exit 1",
    "    ;;",
    "  unanswered-plus-error)",
    "    # PROVIDER_UNANSWERED (a stall marker) + PROVIDER_ERROR (an HTTP refusal) with NO",
    "    # completed turn 1. The plain provider branch used to deny that the no-headers class",
    "    # applied here, contradicting its own inputs; the composite branch describes both.",
    "    echo \"attempt 1 failed: LLM 400: the endpoint refused the request\" >&2",
    "    echo \"attempt 2 failed: Post \\\"https://provider.invalid/chat/completions\\\": context deadline exceeded (Client.Timeout exceeded while awaiting headers)\" >&2",
    "    exit 1",
    "    ;;",
    "  mixed-signals)",
    "    # BOTH markers: a completed turn 1 (engine_defective, once a provider marker is present)",
    "    # AND an explicit HTTP rejection. The COMPOSED class must win — narrating the plain",
    "    # protocol fault here would deny that the engine ever ran a turn, contradicting the log.",
    "    echo \"turn 1: 4 tool call(s)\" >&2",
    "    echo \"attempt 2 failed: Post \\\"https://provider.invalid/chat/completions\\\": context deadline exceeded (Client.Timeout exceeded while awaiting headers)\" >&2",
    "    echo \"attempt 3 failed: LLM 400: the enlarged context was refused by the endpoint\" >&2",
    "    exit 1",
    "    ;;",
    "  non-error-status)",
    "    # A verdict-less log that ALSO carries a NON-ERROR status line. The extractor must not",
    "    # read it as a provider rejection: a 2xx is not a refusal, and reporting it as one would",
    "    # preempt the engine-defective class — the same misattribution this change fixes, inverted.",
    "    echo \"LLM 200: an empty-but-successful response body\" >&2",
    "    exit 1",
    "    ;;",
    "  verdict-less)",
    "    echo \"verdict: required but no Verdict line produced\" >&2",
    "    echo \"## Review - markdown with no Verdict line\" > \"$out\"",
    "    exit 2",
    "    ;;",
    "  mixed)",
    "    echo \"Verdict: PASS\" > \"$out\"",
    "    echo \"Verdict: BLOCK\" >> \"$out\"",
    "    echo \"review complete (fake charly)\"",
    "    exit 0",
    "    ;;",
    "  pass-with-error)",
    "    # The fail-closed case: the review EXITS NON-ZERO (the plan did not",
    "    # complete cleanly) yet leaves a PASS line in the output file. That line",
    "    # is untrusted and must never arm auto-merge.",
    "    echo \"Verdict: PASS\" > \"$out\"",
    "    echo \"review complete (fake charly), but the plan exit is NON-ZERO\" >&2",
    "    exit 1",
    "    ;;",
    "  block-with-error)",
    "    # A real finding written before a non-zero exit: BLOCK is the ONLY class",
    "    # a non-zero review exit may carry, so it must NOT be discarded.",
    "    echo \"Verdict: BLOCK\" > \"$out\"",
    "    echo \"review complete (fake charly), but the plan exit is NON-ZERO\" >&2",
    "    exit 1",
    "    ;;",
    "esac",
    "echo \"harness fake charly: unknown scenario $FAKE_SCENARIO\" >&2",
    "exit 9",
    ""
])

FAKE_GH = NL.join([
    "#!/usr/bin/env bash",
    "echo \"gh $*\" >> \"$FAKE_LOG\"",
    "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"comment\" ]; then",
    "  body=\"\"; bodyfile=\"\"",
    "  prev=\"\"",
    "  for a in \"$@\"; do",
    "    if [ \"$prev\" = \"--body-file\" ]; then bodyfile=\"$a\"; fi",
    "    if [ \"$prev\" = \"--body\" ]; then body=\"$a\"; fi",
    "    prev=\"$a\"",
    "  done",
    "  echo \"=== gh pr comment (fake gh) ===\" >> \"$FAKE_COMMENT_LOG\"",
    "  if [ -n \"$bodyfile\" ]; then",
    "    if [ -f \"$bodyfile\" ]; then cat \"$bodyfile\" >> \"$FAKE_COMMENT_LOG\"; else echo \"(missing body file: $bodyfile)\" >> \"$FAKE_COMMENT_LOG\"; fi",
    "  else",
    "    printf '%s\\n' \"$body\" >> \"$FAKE_COMMENT_LOG\"",
    "  fi",
    "  echo \"=== end comment ===\" >> \"$FAKE_COMMENT_LOG\"",
    "fi",
    # `gh api --paginate ...` — the auto-close step counts the PR's verdict comments PER
    # CLASS (BLOCK and INCONCLUSIVE have different bounds: AI_REVIEW_AUTO_CLOSE_AFTER vs
    # the constant 1). Emit REAL JSON pages (the workflow
    # pipes to `jq -s`, which collects the pages into one array), so the multi-page
    # path is genuinely exercised. This is the ONLY gh api call the workflow makes,
    # so answering it here is exact, not a blanket stub.
    #
    # END-TO-END (the anti-tautology contract): the api answer REPLAYS the machine
    # notices the gate really posted to $FAKE_COMMENT_LOG (recorded by the `gh pr
    # comment` branch above), as `github-actions[bot]` comments. So the counter is
    # exercised against the EMITTED artifact — a rename of the gate's header (or of
    # the counter's own literal) drops the notice from the replay, the count falls to
    # 0, and the seeded scenario's `expect_closed` fails LOUD. The synthetic
    # FAKE_BLOCK_COUNT / FAKE_INCONCLUSIVE_COUNT injections remain for the pure
    # threshold scenarios; FAKE_OTHER_COUNT + FAKE_PAGE_SIZE keep the multi-page
    # thread reproducible.
    "if [ \"$1\" = \"api\" ]; then",
    "  python3 - \"${FAKE_BLOCK_COUNT:-0}\" \"${FAKE_INCONCLUSIVE_COUNT:-0}\" \"${FAKE_OTHER_COUNT:-0}\" \"${FAKE_PAGE_SIZE:-30}\" \"${FAKE_COMMENT_LOG:-}\" \"${FAKE_INFRA_COUNT:-0}\" <<'PYEOF'",
    "import json, sys",
    "blocks, inconcl, other, size = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])",
    "comment_log = sys.argv[5]",
    "infra = int(sys.argv[6]) if len(sys.argv) > 6 else 0",
    "# Replay the REAL bot notices captured from `gh pr comment` so the counter is",
    "# exercised against the gate's EMITTED artifact, not a re-typed literal. Only",
    "# the machine notices the counter is meant to match are replayed as the bot.",
    "replayed = []",
    "if comment_log:",
    "    try:",
    "        with open(comment_log, \"r\", encoding=\"utf-8\") as fh:",
    "            captured = fh.read()",
    "    except OSError:",
    "        captured = \"\"",
    "    for block in captured.split(\"=== gh pr comment (fake gh) ===\")[1:]:",
    "        body = block.split(\"=== end comment ===\")[0].strip(\"\\n\")",
    "        if body.startswith(\"## validator INCONCLUSIVE\") or body.startswith(\"## Auto-closed:\"):",
    "            replayed.append({\"user\": {\"login\": \"github-actions[bot]\"}, \"body\": body})",
    "items = list(replayed)",
    "items += [{\"user\": {\"login\": \"github-actions[bot]\"}, \"body\": \"## Review — BLOCK\\n\\nblocked\"}] * blocks",
    "# A synthetic EVAL INCONCLUSIVE has NO `Verdict class: infra` line, so it COUNTS.",
    "items += [{\"user\": {\"login\": \"github-actions[bot]\"}, \"body\": \"## validator INCONCLUSIVE — no review verdict\\n\\nno answer\\n- Verdict class: eval (counts toward AI_REVIEW_AUTO_CLOSE_AFTER)\"}] * inconcl",
    "# A synthetic INFRA INCONCLUSIVE carries the exact line the counter excludes.",
    "items += [{\"user\": {\"login\": \"github-actions[bot]\"}, \"body\": \"## validator INCONCLUSIVE — no review verdict\\n\\nno answer\\n- Verdict class: infra (does NOT count toward AI_REVIEW_AUTO_CLOSE_AFTER)\"}] * infra",
    "items += [{\"user\": {\"login\": \"someone\"}, \"body\": \"a normal comment\"}] * other",
    "for i in range(0, max(len(items), 1), size):",
    "    print(json.dumps(items[i:i+size]))",
    "    if not items:",
    "        break",
    "PYEOF",
    "  exit 0",
    "fi",
    "exit 0",
    ""
])
# A fake `curl` for the head-checks gate sub-test. The REAL step body runs against it, so
# the gate's own jq/loop/fail-closed logic is what is being exercised — only the GitHub API
# boundary is canned. Each case is one branch of the gate, and every one of them was ALSO
# proven against the live API before this was written (see the PR body for the transcript);
# the fake exists so the coverage runs deterministically on every push, not to stand in for
# that live proof.
#   pass         every check completed green
#   bad          a check completed FAILED                      -> the #795 / #791 case
#   pending      a check never settles inside the wait budget -> fail closed
#   gap          the #796 REGRESSION: during a re-run GitHub's `filter=latest` DROPS the
#                check name while `filter=all` still lists it. The gate must read `all`.
#   self         a check run whose details_url names THIS run id (the gate itself)
FAKE_CURL_CHECKRUNS = NL.join([
    "#!/usr/bin/env bash",
    "ok='{\"name\":\"validate / validate\",\"status\":\"completed\",\"conclusion\":\"success\",\"details_url\":\"https://x/runs/1\",\"id\":2,\"app\":{\"slug\":\"github-actions\"}}'",
    "gofail='{\"name\":\"go\",\"status\":\"completed\",\"conclusion\":\"failure\",\"details_url\":\"https://x/runs/3\",\"id\":3,\"app\":{\"slug\":\"github-actions\"}}'",
    "gook='{\"name\":\"go\",\"status\":\"completed\",\"conclusion\":\"success\",\"details_url\":\"https://x/runs/3\",\"id\":3,\"app\":{\"slug\":\"github-actions\"}}'",
    "gopend='{\"name\":\"go\",\"status\":\"in_progress\",\"conclusion\":null,\"details_url\":\"https://x/runs/3\",\"id\":3,\"app\":{\"slug\":\"github-actions\"}}'",
    "selfrun='{\"name\":\"validate / validate\",\"status\":\"completed\",\"conclusion\":\"failure\",\"details_url\":\"https://x/runs/424242\",\"id\":99,\"app\":{\"slug\":\"github-actions\"}}'",
    "case \"${FAKE_CR_CASE:-}\" in",
    "  pass)    printf '{\"check_runs\":[%s,%s]}' \"$ok\" \"$gook\" ;;",
    "  bad)     printf '{\"check_runs\":[%s,%s]}' \"$ok\" \"$gofail\" ;;",
    "  pending) printf '{\"check_runs\":[%s,%s]}' \"$ok\" \"$gopend\" ;;",
    "  self)    printf '{\"check_runs\":[%s,%s]}' \"$ok\" \"$selfrun\" ;;",
    "  gap)",
    "    # the whole point: `latest` loses the check, `all` still has it",
    "    if [[ \"$*\" == *\"filter=latest\"* ]]; then printf '{\"check_runs\":[%s]}' \"$ok\"",
    "    else printf '{\"check_runs\":[%s,%s]}' \"$ok\" \"$gofail\"; fi ;;",
    "  *)       printf '{\"check_runs\":[]}' ;;",
    "esac",
    ""
])
def write_executable(path, content):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(path, 0o755)


def read_outputs(path):
    outs = {}
    if not os.path.exists(path):
        return outs
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh.read().splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                outs[key.strip()] = value.strip()
    return outs


def build_ns(step_outputs, workspace, tmpdir):
    data = {
        "inputs": {"pr-number": "12345"},
        "github": {
            "token": "fake-token",
            "repository": "opencharly/harness-fixture",
            "workspace": workspace,
        },
        "vars": {},
        "secrets": {},
        "runner": {"temp": tmpdir},
        "env": {},
        "steps": dict((sid, {"outputs": outs}) for sid, outs in step_outputs.items()),
    }
    return dict((key, Ctx(value)) for key, value in data.items())


TARGETS = [
    ("id", "review"),
    ("id", "parse"),
    # Auto-close runs BEFORE the Gate (BLOCK) in the workflow, so the close +
    # notice land before the gate fails the check. The harness executes in this
    # order, so it must mirror the workflow's.
    ("name", "Auto-close (max attempts; eval verdicts only)"),
    ("name", "Gate (BLOCK)"),
    ("name", "Gate (inconclusive)"),
    ("name", "Gate (ambiguous)"),
    # The two new gates sit between the verdict gates and auto-merge, in the workflow's
    # own order. `go-modules` is fully offline (find + bash over the workspace) and is
    # exercised as the REAL body here — in this fixture workspace there is no `pr-head/`
    # checkout, so it takes its SKIP path, which is exactly the contract to pin: a repo
    # with no declared golangci-lint config must skip cleanly and never false-red.
    # `golint` is guarded on `present == 'true'`, so it is skipped in every scenario and
    # is listed only so the coverage ledger names the whole chain.
    # `head-checks` is deliberately NOT in TARGETS: it polls the live GitHub API, and a
    # step listed here is executed against the workspace with only `charly`/`gh` faked.
    # It is covered the way ensure-charly is — a dedicated functional sub-test that runs
    # the REAL body against a controlled PATH (see "HEAD CHECK-RUNS GATE" below).
    ("id", "go-modules"),
    ("id", "golint"),
    ("name", "Enable auto-merge"),
    # The evidence step runs on `if: always()`, so it is exercised on every scenario —
    # including the failing ones (which is the whole point: the evidence exists when the
    # run WENT WRONG). Its content is asserted per scenario via expect_summary_contains.
    ("id", "evidence"),
]

SCENARIOS = [
    {
        "name": "pass",
        "fake": "pass",
        "expect_exit": 0,
        "expect_steps": ["review", "parse", "go-modules", "Enable auto-merge", "evidence"],
        "expect_summary_contains": [
            "## Validator evidence",
            "| review exit code |",
            "| class inputs |",
        ],
        "expect_verdict": "PASS",
        "expect_comment": False,
        "expect_auto_merge": True,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "0",
                                  "success": "true"},
    },
    {
        "name": "block",
        "fake": "block",
        "expect_exit": 1,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (BLOCK)", "evidence"],
        "expect_verdict": "BLOCK",
        "expect_comment": False,
        "expect_auto_merge": False,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "0"},
    },
    {
        # AUTO-CLOSE (BLOCK): a PR whose BLOCK count has reached the threshold must be
        # closed with the "open a clean PR from scratch" notice. The harness supplies the
        # count via FAKE_BLOCK_COUNT and the threshold via vars; both branches
        # (below/at threshold) are asserted.
        "name": "auto-close-at-threshold",
        "fake": "block",
        "block_count": 5,
        "expect_exit": 1,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (BLOCK)", "evidence"],
        "expect_verdict": "BLOCK",
        "expect_comment": True,
        "expect_comment_contains": ["Auto-closed", "open a clean PR from scratch",
                                    "**Closed after** 5 counting verdict(s) reached AI_REVIEW_AUTO_CLOSE_AFTER=5"],
        "expect_auto_merge": False,
        "expect_closed": True,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "0"},
    },
    {
        # AUTO-CLOSE (multi-page): a thread longer than ONE page must still count
        # correctly. With the old `gh api --paginate --jq 'length'` the filter ran
        # PER PAGE (a >30-comment thread yielded several numbers), the guard
        # rejected the newline, and auto-close silently disabled itself — on
        # exactly the long threads it exists to bound. 5 blocks + 60 others at a
        # page size of 30 = 3 pages; the count must still be 5 and the PR closed.
        "name": "auto-close-multi-page",
        "fake": "block",
        "block_count": 5,
        "other_count": 60,
        "page_size": 30,
        "expect_exit": 1,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (BLOCK)", "evidence"],
        "expect_verdict": "BLOCK",
        "expect_comment": True,
        "expect_comment_contains": ["Auto-closed", "open a clean PR from scratch",
                                    "**Closed after** 5 counting verdict(s) reached AI_REVIEW_AUTO_CLOSE_AFTER=5"],
        "expect_auto_merge": False,
        "expect_closed": True,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "0"},
    },
    {
        # AUTO-CLOSE (over threshold): the notice MUST render the ACTUAL verdict-count,
        # not the threshold. `blocks=8` against the default threshold 5 fired the
        # headline "Auto-closed: 5 unanswered …" while the body said
        # "received **8**" — a false statement from the gate. The scenario asserts
        # the real count appears (and the threshold-only count does not).
        "name": "auto-close-over-threshold-count",
        "fake": "block",
        "block_count": 8,
        "expect_exit": 1,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (BLOCK)", "evidence"],
        "expect_verdict": "BLOCK",
        "expect_comment": True,
        "expect_comment_contains": ["Auto-closed: 8 counting verdict(s) on this thread",
                                    "**8** `BLOCK`",
                                    "**Closed after** 8 counting verdict(s) reached AI_REVIEW_AUTO_CLOSE_AFTER=5"],
        "expect_comment_excludes": ["Auto-closed: 5 counting"],
        "expect_auto_merge": False,
        "expect_closed": True,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "0"},
    },
    {
        # AUTO-CLOSE (below threshold): 4 BLOCKs against the default threshold 5 must
        # NOT close. This is the base of the restored count-based bound.
        "name": "auto-close-below-threshold",
        "fake": "block",
        "block_count": 4,
        "expect_exit": 1,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (BLOCK)", "evidence"],
        "expect_verdict": "BLOCK",
        "expect_comment": False,
        "expect_auto_merge": False,
        "expect_closed": False,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "0"},
    },
    {
        # AUTO-CLOSE (restored count bound, MIXED classes): 4 BLOCKs + 1 EVAL
        # INCONCLUSIVE on the thread = 5 counting verdicts, so the PR closes. This is
        # the exact case #169 got WRONG in the other direction: an eval-class
        # INCONCLUSIVE is a review attempt and DOES count, together with BLOCKs.
        "name": "auto-close-eval-counts",
        "fake": "block",
        "block_count": 4,
        "inconclusive_count": 1,
        "expect_exit": 1,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (BLOCK)", "evidence"],
        "expect_verdict": "BLOCK",
        "expect_comment": True,
        "expect_comment_contains": ["Auto-closed: 5 counting verdict(s) on this thread",
                                    "**4** `BLOCK`",
                                    "**1** counted `INCONCLUSIVE`"],
        "expect_auto_merge": False,
        "expect_closed": True,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "0"},
    },
    {
        # AUTO-CLOSE (INFRA EXCLUDED — the #170 fix): 4 BLOCKs + 1 prior INFRA
        # INCONCLUSIVE, with THIS run ALSO an infra failure (provider-unanswered).
        # Under #169 this closed on the single infra verdict; under the restored bound
        # the counting class is 4 BLOCKs (< 5) and the infra verdicts are EXCLUDED, so
        # the PR MUST NOT close. This is the regression the operator reported.
        "name": "auto-close-infra-excluded",
        "fake": "provider-unanswered",
        "block_count": 4,
        "infra_count": 1,
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_closed": False,
        "expect_comment_contains": ["Verdict class: infra (does NOT count toward AI_REVIEW_AUTO_CLOSE_AFTER)"],
        "expect_review_outputs": {"provider_unanswered": "true", "review_rc": "1",
                                  "discarded_verdict": "false"},
    },
    {
        # AUTO-CLOSE (INFRA-ONLY thread NEVER closes): zero BLOCKs and four infra
        # INCONCLUSIVEs — a PR that only ever hit provider/GitHub hiccups must NEVER
        # be closed by the bound. Proves infra failures do not accumulate toward the max.
        "name": "auto-close-infra-only-never-closes",
        "fake": "provider-unanswered",
        "block_count": 0,
        "infra_count": 4,
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_closed": False,
        "expect_review_outputs": {"provider_unanswered": "true", "review_rc": "1",
                                  "discarded_verdict": "false"},
    },
    {
        "name": "provider-unanswered",
        "fake": "provider-unanswered",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        # END-TO-END anti-tautology: the EXACT literal the auto-close counter matches
        # (the workflow's `contains("## validator INCONCLUSIVE")`) must be present in
        # the comment the gate REALLY posts. A rename of the notice header fails HERE.
        # The post-loop replay check below ties the same emitted body back through the
        # REAL counter, so a rename of the counter's literal fails THERE.
        "expect_comment_contains": [
            "## validator INCONCLUSIVE",
            "provider unanswered",
            "in-job retries: none",
            "AI_REVIEW_STREAM_IDLE_TIMEOUT",
            # A provider stall is a CLEAR INFRA failure: it is excluded from the
            # auto-close count and labelled as such in the emitted notice.
            "Verdict class: infra (does NOT count toward AI_REVIEW_AUTO_CLOSE_AFTER)",
        ],
        "expect_closed": False,
        "expect_review_outputs": {"provider_unanswered": "true", "review_rc": "1",
                                  "discarded_verdict": "false"},
    },
    {
        # THE WHOLE-REQUEST CAP (opencharly/.github#133). The engine's terminal line
        # names this class explicitly, so the notice must name it too — and must NOT
        # repeat the retired provider story. Before the fix the run matched the bare
        # substring `inconclusive:` and was reported as "provider unanswered" with the
        # deleted 5-minute-cap narrative attached; this scenario's fake log carries the
        # real terminal line, which pre-fix reaches NEITHER the class selection NOR the
        # posted body, so both the class assertion and the "Measured in this run" block
        # fail on the pre-fix workflow.
        "name": "attempt-cap",
        "fake": "attempt-cap",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_comment_contains": [
            "## validator INCONCLUSIVE",
            "whole-request cap",
            "in-job retries: none",
            # The run's OWN lines, not a template: the bounds the engine reported and the
            # terminal line that named the class must both survive into the posted body.
            "**Measured in this run**",
            'reasoning_effort="medium"',
            "AI_REVIEW_ATTEMPT_TIMEOUT=18m0s",
        ],
        # The anti-misattribution half: neither the other class's words nor the retired
        # provider story may appear for a cap-cut run.
        "expect_comment_excludes": ["provider unanswered", "empty completion"],
        "expect_auto_merge": False,
        "expect_closed": False,
        "expect_review_outputs": {"inconclusive_class": "attempt-cap",
                                  "provider_unanswered": "false", "review_rc": "1",
                                  "discarded_verdict": "false", "inconclusive_infra": "true"},
    },
    {
        # THE EMPTY-COMPLETION class (#133): a DIFFERENT terminal line, a DIFFERENT
        # durable remedy. Conflating it with the cap class (or with provider-unanswered)
        # sends the operator after the wrong knob.
        "name": "empty-completion",
        "fake": "empty-completion",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_comment_contains": [
            "## validator INCONCLUSIVE",
            "empty completion",
            "in-job retries: none",
            "**Measured in this run**",
            "produced no answer",
            "AI_REVIEW_MAX_TOKENS",
            "Verdict class: infra (does NOT count toward AI_REVIEW_AUTO_CLOSE_AFTER)",
        ],
        "expect_comment_excludes": ["provider unanswered", "whole-request cap"],
        "expect_auto_merge": False,
        "expect_closed": False,
        "expect_review_outputs": {"inconclusive_class": "empty-completion",
                                  "provider_unanswered": "false", "review_rc": "1",
                                  "discarded_verdict": "false", "inconclusive_infra": "true"},
    },
    {
        # AN ENGINE CLASS THE WORKFLOW HAS NO NARRATIVE FOR (#133). The engine's fail-closed
        # context guard refused the request BEFORE sending it, and said so in its terminal
        # line. The gate must DEFER to that line and quote it — never fall through to a
        # signature story. Pre-fix this log matched the bare `inconclusive:` substring, so
        # the run was posted as "provider unanswered": the operator was pointed at a
        # provider that was never called, while the engine's own actionable instruction
        # ("split the PR into smaller PRs") sat unread in the log. The fake carries the
        # engine's REAL budgetError line; the excludes are the anti-misattribution half.
        "name": "engine-terminal-other",
        "fake": "engine-terminal-other",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_comment_contains": [
            "## validator INCONCLUSIVE",
            "DEFERS to the line",
            "in-job retries: none",
            # The engine's OWN words must reach the body: the class line echoes the marker,
            # and the measured block quotes the terminal line verbatim.
            "**Measured in this run**",
            "PR too large to review in one context",
            "split the PR into smaller PRs",
        ],
        "expect_comment_excludes": ["provider unanswered", "whole-request cap", "empty completion"],
        "expect_auto_merge": False,
        "expect_closed": False,
        "expect_review_outputs": {"inconclusive_class": "engine-terminal-other",
                                  "provider_unanswered": "false", "review_rc": "1",
                                  "discarded_verdict": "false", "inconclusive_infra": "false"},
    },
    {
        # The engine-defective class must be SELECTED from the run's own signature, not merely
        # mentioned in the workflow's text: this scenario's fake log carries a completed turn 1
        # plus a provider marker, so the true branch of the classification fires and the
        # INCONCLUSIVE notice must name the class. Pre-fix (no engine_defective branch) the
        # notice cannot contain it, so these assertions FAIL on the pre-fix workflow.
        # engine-defective is an EVAL failure (the engine RAN and failed a later turn), so it
        # counts toward the bound — but a single one is below the default 5 and must NOT close.
        "name": "engine-defective",
        "fake": "engine-defective",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_comment_contains": [
            "validator INCONCLUSIVE",
            "engine-defective (the review engine",
            "T13 engine-change exception",
            "Verdict class: eval (counts toward AI_REVIEW_AUTO_CLOSE_AFTER)",
        ],
        "expect_closed": False,
        "expect_review_outputs": {"provider_unanswered": "true", "engine_defective": "true",
                                  "review_rc": "1", "discarded_verdict": "false",
                                  "inconclusive_infra": "false"},
    },
    {
        # A provider HTTP rejection is its OWN class with its OWN narrative. Before this
        # scenario existed the notice printed ONE fixed root cause for every class, so a
        # `LLM 400 ... MissingSessionID` log was reported under the engine streaming story —
        # a misattribution that was live org-wide on 2026-09-12. The excludes below are the
        # point of the scenario: the RIGHT class AND the ABSENCE of the wrong narrative.
        "name": "provider-error",
        "fake": "provider-error",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_comment_contains": [
            "validator INCONCLUSIVE",
            "provider rejected the request (HTTP 400)",
            "an explicit REJECTION",
            "read the provider message in the diagnostics",
            "do NOT retry blindly",
            "Verdict class: infra (does NOT count toward AI_REVIEW_AUTO_CLOSE_AFTER)",
        ],
        "expect_comment_excludes": [
            "whole-generation deadline is the wrong bound",
            "verdict-less review output",
        ],
        "expect_closed": False,
        "expect_review_outputs": {"provider_error": "400", "provider_unanswered": "false",
                                  "engine_defective": "false", "review_rc": "1",
                                  "discarded_verdict": "false", "inconclusive_infra": "true"},
        # The ALWAYS-present surface: a reader opening the failed run finds the class and the
        # effective configuration on the Summary page — no PR-comment round trip, no log hunt.
        "expect_summary_contains": [
            "## Validator evidence",
            "| review exit code |",
            "| provider HTTP error |",
            "400",
            "| class inputs |",
            "| provider / model / base_url |",
        ],
    },
    {
        # PROVIDER_ERROR + PROVIDER_UNANSWERED with NO completed turn 1: the case where the
        # plain provider branch used to print a denial its own class inputs contradicted.
        "name": "unanswered-plus-error",
        "fake": "unanswered-plus-error",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_comment_contains": [
            "validator INCONCLUSIVE",
            "provider rejected the request (HTTP 400) and another attempt stalled without headers",
            "This log carries BOTH signatures",
        ],
        "expect_comment_excludes": [
            "neither of those classes describes",
            "the engine never got to run a turn",
        ],
        "expect_closed": False,
        "expect_review_outputs": {"provider_error": "400", "provider_unanswered": "true",
                                  "engine_defective": "false", "review_rc": "1",
                                  "discarded_verdict": "false", "inconclusive_infra": "true"},
    },
    {
        # continue-on-error on the reporting steps: the evidence step FAILS (its RUNNER_TEMP is
        # unwritable) and the job must STILL keep the verdict it produced — exit 0 and the
        # armed auto-merge, not a red check on a PASS run.
        "name": "pass-with-unwritable-evidence",
        "fake": "pass",
        "unwritable_evidence": True,
        "expect_exit": 0,
        "expect_steps": ["review", "parse", "go-modules", "Enable auto-merge", "evidence"],
        "expect_verdict": "PASS",
        "expect_comment": False,
        "expect_auto_merge": True,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "0",
                                  "discarded_verdict": "false"},
    },
    {
        # BOTH signals in one log — the case the extractor's precedence must get right. Before
        # the composed branch, the provider branch won and asserted "the engine never got to run
        # a turn" while the log showed turn 1 COMPLETED: the same misattribution class this PR
        # removes, inverted.
        "name": "mixed-signals",
        "fake": "mixed-signals",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_comment_contains": [
            "validator INCONCLUSIVE",
            "provider rejected a LATER request (HTTP 400) after turn 1 completed",
            "the enlarged-context class",
        ],
        "expect_comment_excludes": [
            "the engine never got to run a turn",
            "neither of those classes describes",
        ],
        "expect_closed": False,
        "expect_review_outputs": {"provider_error": "400", "provider_unanswered": "true",
                                  "engine_defective": "true", "review_rc": "1",
                                  "discarded_verdict": "false", "inconclusive_infra": "false"},
    },
    {
        # The BOUNDARY the extractor must respect. Before the pattern was narrowed to [45]xx,
        # this log produced a confident "provider rejected the request" class AND preempted the
        # engine-defective branch — a misattribution manufactured by the fix itself. R10: a
        # test that fails on a non-error status.
        "name": "non-error-status",
        "fake": "non-error-status",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_comment_contains": [
            "validator INCONCLUSIVE",
            "verdict-less review output",
        ],
        "expect_comment_excludes": [
            "provider rejected the request",
            "an explicit REJECTION",
        ],
        "expect_closed": False,
        "expect_review_outputs": {"provider_error": "", "provider_unanswered": "false",
                                  "engine_defective": "false", "review_rc": "1",
                                  "discarded_verdict": "false", "inconclusive_infra": "false"},
    },
    {
        "name": "verdict-less",
        "fake": "verdict-less",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        # The DEFAULT narrative is evidence-bounded: a log with none of the recognised
        # signatures must NOT be told the streaming story as fact (the review's block 3).
        "expect_comment_contains": [
            "validator INCONCLUSIVE",
            "verdict-less review output",
            "carries NONE of the recognised signatures",
        ],
        "expect_comment_excludes": [
            "whole-generation deadline is the wrong bound",
        ],
        "expect_closed": False,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "2",
                                  "discarded_verdict": "false", "inconclusive_infra": "false"},
    },
    {
        "name": "mixed",
        "fake": "mixed",
        "expect_exit": 2,
        "expect_steps": ["review", "parse", "Gate (ambiguous)", "evidence"],
        "expect_verdict": "AMBIGUOUS",
        "expect_comment": False,
        "expect_auto_merge": False,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "0"},
    },
    {
        # T3/T4 fail-closed: the review exit is NON-ZERO while the output file
        # carries a PASS line. main's bash -e aborted on that rc; capturing the
        # rc must not be a weaker gate, so the untrusted PASS is discarded, the
        # run is INCONCLUSIVE (exit 3) and auto-merge is NEVER armed.
        "name": "pass-with-error",
        "fake": "pass-with-error",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (inconclusive)", "evidence"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_comment_contains": [
            "validator INCONCLUSIVE",
            "FAIL-CLOSED",
            "may only carry a real BLOCK finding",
            "untrustworthy by construction",
            "Verdict class: infra (does NOT count toward AI_REVIEW_AUTO_CLOSE_AFTER)",
        ],
        "expect_closed": False,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "1",
                                  "success": "false", "inconclusive": "true",
                                  "discarded_verdict": "true", "inconclusive_infra": "true"},
    },
    {
        # A finding is a finding: BLOCK is the ONLY class a non-zero review exit
        # may carry, so it is NOT discarded - the gate reports BLOCK (exit 1),
        # never INCONCLUSIVE and never PASS.
        "name": "block-with-error",
        "fake": "block-with-error",
        "expect_exit": 1,
        "expect_steps": ["review", "parse", "Auto-close (max attempts; eval verdicts only)", "Gate (BLOCK)", "evidence"],
        "expect_verdict": "BLOCK",
        "expect_comment": False,
        "expect_auto_merge": False,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "1",
                                  "success": "true", "discarded_verdict": "false"},
    },
]


def run_scenario(spec, ordered, tmpdir, fakedir, workspace):
    label = spec["name"]
    log_path = os.path.join(tmpdir, label + ".calls.log")
    comment_path = os.path.join(tmpdir, label + ".comment.log")
    open(log_path, "w").close()
    open(comment_path, "w").close()
    for path in RUNNER_PATHS:
        if os.path.exists(path):
            os.remove(path)

    outputs = {}
    ns = build_ns(outputs, workspace, tmpdir)
    executed = []
    skipped = []
    transcript = []
    job_exit = 0
    job_failed = False
    step_outputs = {}
    summary_path = ""

    for _, step in ordered:
        name = step["label"]
        condition = step["if"]
        # GitHub semantics, modelled correctly. A failed step does NOT end the job: a later
        # step runs when its `if:` is a STATUS function (always()), and both a step with no
        # `if:` and a step with a plain expression carry an IMPLICIT success() — so they are
        # SKIPPED once a step has failed. The previous model broke out of the loop on the
        # first failure ("the job stops here, exactly as GitHub would" — it does not), which
        # is precisely why an `if: always()` evidence step could never be exercised here.
        if condition is None:
            run = not job_failed
        elif "always()" in condition:
            run = True
        elif job_failed:
            run = False
        else:
            run = eval_gh(condition, ns)
        if not run:
            skipped.append(name)
            reason = ("if: " + condition) if condition else "a failed earlier step (implicit success())"
            transcript.append("  [" + name + "] skipped (" + reason + ")")
            continue
        env = dict(os.environ)
        env["PATH"] = fakedir + os.pathsep + env.get("PATH", "")
        env["GITHUB_WORKSPACE"] = workspace
        env["GITHUB_ACTIONS"] = "true"
        env["FAKE_LOG"] = log_path
        env["FAKE_COMMENT_LOG"] = comment_path
        env["FAKE_SCENARIO"] = spec["fake"]
        # The auto-close step counts the PR's BLOCK/INCONCLUSIVE comments via `gh api`; the
        # scenario supplies the count so the threshold branch is exercised.
        env["FAKE_BLOCK_COUNT"] = str(spec.get("block_count", 0))
        env["FAKE_INCONCLUSIVE_COUNT"] = str(spec.get("inconclusive_count", 0))
        env["FAKE_INFRA_COUNT"] = str(spec.get("infra_count", 0))
        env["FAKE_OTHER_COUNT"] = str(spec.get("other_count", 0))
        env["FAKE_PAGE_SIZE"] = str(spec.get("page_size", 30))
        stem = label + "." + re.sub("[^A-Za-z0-9]+", "_", name)
        out_file = os.path.join(tmpdir, stem + ".github_output")
        open(out_file, "w").close()
        env["GITHUB_OUTPUT"] = out_file
        # The evidence step writes the run Summary and a manifest under RUNNER_TEMP. Both
        # are real files in CI, so the harness supplies REAL paths and asserts their
        # CONTENT — a debugging-output claim is only proven by reading what it wrote.
        summary_path = os.path.join(tmpdir, stem + ".step_summary")
        open(summary_path, "w").close()
        if spec.get("unwritable_evidence"):
            # A REPORTING failure must not change the verdict (continue-on-error). Point the
            # evidence step at paths it cannot write and assert the job keeps its exit code.
            env["RUNNER_TEMP"] = "/proc/validator-evidence-unwritable"
            env["GITHUB_STEP_SUMMARY"] = "/proc/validator-evidence-unwritable/summary"
        else:
            env["RUNNER_TEMP"] = tmpdir
            env["GITHUB_STEP_SUMMARY"] = summary_path
        for key, value in step["env"].items():
            env[key] = subst(value, ns)
        script_path = os.path.join(tmpdir, stem + ".sh")
        with open(script_path, "w", encoding="utf-8") as fh:
            fh.write(subst(step["run"], ns))
        proc = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", script_path],
            cwd=workspace,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
        )
        executed.append(name)
        transcript.append("  [" + name + "] exit " + str(proc.returncode))
        body = proc.stdout.rstrip()
        if body:
            transcript.append(indent(body, "      "))
        if step["id"]:
            step_outputs[step["id"]] = read_outputs(out_file)
            outputs[step["id"]] = step_outputs[step["id"]]
            ns = build_ns(outputs, workspace, tmpdir)
        if proc.returncode != 0:
            # continue-on-error: GitHub does NOT fail the job for this step. Modelled here
            # because a declaration nobody can exercise is not a contract — the evidence steps
            # rely on it so a reporting failure can never turn a PASS run RED.
            if step.get("continue-on-error") == "true":
                transcript.append("  -> step failed (exit " + str(proc.returncode) +
                                  "), continue-on-error: the job keeps its verdict")
            else:
                if job_exit == 0:
                    job_exit = proc.returncode
                job_failed = True
                transcript.append("  -> step failed (exit " + str(proc.returncode) +
                                  "); later steps run only when they declare always()")

    with open(comment_path, "r", encoding="utf-8") as fh:
        comment = fh.read()
    with open(log_path, "r", encoding="utf-8") as fh:
        calls = fh.read()
    # The fake gh pr comment appends every posted body to comment_path; the auto-close
    # replay below needs it to survive this function, so it is captured here (the CONTENT
    # is returned) and the file is removed — no leftover per-scenario artifact.
    comment_log = comment
    try:
        os.remove(comment_path)
    except OSError:
        pass
    for path in RUNNER_PATHS:
        if os.path.exists(path):
            os.remove(path)
    summary = ""
    if summary_path and os.path.exists(summary_path):
        with open(summary_path, "r", encoding="utf-8") as fh:
            summary = fh.read()
    return {
        "transcript": transcript,
        "job_exit": job_exit,
        "executed": executed,
        "skipped": skipped,
        "outputs": step_outputs,
        "comment": comment,
        "comment_log": comment_log,
        "calls": calls,
        "summary": summary,
    }


def run_harness():
    text, steps = parse_workflow(WORKFLOW_PATH)
    ordered = [(key, find_step(steps, key, value)) for key, value in TARGETS]
    review_run = find_step(steps, "id", "review")["run"]

    log = []
    checks = []

    def note(ok, message):
        checks.append((ok, message))
        log.append(("PASS  " if ok else "FAIL  ") + message)

    note("sleep" not in review_run,
         "structural: the review step contains no in-job retry (no sleep)")
    note("for attempt" not in review_run,
         "structural: the review step contains no in-job retry (no for-attempt loop)")
    note("MAINTAINER SIGN-OFF" in text,
         "structural: header records the T4 maintainer sign-off requirement")
    note("vars.REVIEW_RUNNER_LABEL" in text,
         "structural: header names the operator lever vars.REVIEW_RUNNER_LABEL")
    note("GENERATION-LENGTH problem, not a scheduling one" in text
         and "A cap only DETECTS a generation that is too long" in text,
         "structural: the header names the generation-bound MECHANISM (a long review is "
         "a generation-length problem; a cap DETECTS it, the effort/token budget BOUNDS "
         "it) rather than a retired timeout narrative")
    note("hardcoded 5-minute" not in text and "5m0s whole-request deadline" not in text,
         "structural: the retired hardcoded-5-minute narrative is GONE (the cap is an "
         "org-settable knob with no built-in value in this file)")
    note("throttles/blocks datacenter/shared runner egress" not in text,
         "structural: no throttled-egress RCA anywhere in the workflow")
    note("non-streaming request under a whole-generation deadline" not in text.lower(),
         "structural: the retired non-streaming RCA is GONE (case-insensitive)")
    note("narrative below it" not in text,
         "structural: the header carries no dangling reference to a superseded "
         "narrative it claims to retain (R5: deleted in the same commit)")
    note("RCA 2026-09-19" not in text and "awaiting headers" not in text
         and "turn request attempt N/3 failed" not in text,
         "structural: the superseded 2026-09-12 / 2026-09-19 RCAs are ABSENT from the "
         "file entirely (R5: deleted, never retained below as history)")
    note("opencharly/plugin-review#36" in text,
         "structural: header routes the LIVE generation-bound defect to its owner (the "
         "engine: the empty-effort knob, opencharly/plugin-review#36)")
    note("the generation knobs are INERT" not in text and "INERT until the engine release" not in text,
         "structural: header no longer claims the generation knobs are INERT")
    note("v2026.267.0045" not in text and "plugin-review@v2026.266" not in text
         and "this comment names no version" in text,
         "structural: the header names NO pinned release (a literal drifts the moment "
         "CHARLY_VERSION moves) and points at the live pin instead")
    note("NO built-in fallback TAG" in text and 'TAG="$CHARLY_VERSION"' in text,
         "structural: the header states there is NO fallback TAG (the pin is used "
         "verbatim) — the claim the pin-enforcement fix made true")
    note("the engine is not at fault" not in text.lower(),
         "structural: no emitted narrative exonerates the engine of the unbounded "
         "generation (header and emitted RCA agree)")
    note("must STAY SET to a" in text and "opencharly/plugin-review#36" in text,
         "structural: header states the OPERATIONAL invariant for the effort knob (the "
         "org var must stay SET to a non-empty value until plugin-review#36 is welded) — "
         "the reason an unset var silently degrades the gate to an unbounded provider "
         "default instead of failing loud")
    note("remedies: re-run" not in text,
         "structural: no re-run-and-see remedy anywhere in the workflow text")
    note("AI_REVIEW_STREAM_IDLE_TIMEOUT" in text,
         "structural: header documents the stream-idle lever this workflow passes "
         "through (the meaningful bound for a streaming engine)")
    note("timeout-minutes: 20" in text,
         "structural: the validate job carries a fail-hard wall clock "
         "(timeout-minutes: 20 caps a provider-unanswered burn)")
    # The `issues` scope (`.github#173`): the review reads the PR body via the issues API
    # and posts its verdict/INCONCLUSIVE notice as a PR comment. Without the scope a PUBLIC
    # repo's body still reads (unauthenticated), so the gap is invisible — but the org's
    # first PRIVATE repo (`opencharly/charly-images`) 403s and the gate is verdict-less on
    # EVERY run, so no private-repo PR can merge. Asserted on BOTH surfaces: the reusable
    # AND the org-wide caller, because a called workflow can only hold a permission its
    # caller also grants (asserting only the reusable would pass while the caller nullified
    # it). These FAIL if either scope is dropped — the exact regression `.github#25` made.
    note(workflow_permissions(WORKFLOW_PATH).get("issues") is not None,
         "functional: pr-validator.yml grants the `issues` scope (the review reads the PR "
         "body via the issues API + posts its verdict as a PR comment; without it a PRIVATE "
         "repo's body read 403s — .github#173)")
    note(workflow_permissions(CALLER_WORKFLOW_PATH).get("issues") is not None,
         "functional: the org-wide caller org-wide-pr-validator-required.yml ALSO grants "
         "`issues` (a called workflow holds only what its caller grants; asserting only the "
         "reusable would pass while the caller nullified it — .github#173)")
    # SAME-REPO vs EXTERNAL-FORK (the dsh-github#2 block, 2026-10-07). The validate job must
    # gate on `head.repo.full_name == github.repository` — same-repo PRs RUN even when the
    # repo is a first-party FORK of an upstream, and only a genuine external contribution
    # (a DIFFERENT head repo) skips. The retired `head.repo.fork == false` test is TRUE for
    # every PR in a fork repo, so it SKIPPED the org's own PRs and the ruleset's REQUIRED
    # `validate / validate` was never produced (measured: `dsh-github` main carries the
    # ruleset; `gh pr merge` reports `Required status check "validate / validate" is
    # expected`). Assert BOTH the predicate's presence and its evaluated truth table, so a
    # silent revert to the fork-repo form — or the deletion of the `if:` — FAILS here.
    caller_if = job_if(CALLER_WORKFLOW_PATH, "validate")
    note(caller_if is not None,
         "structural: the org-wide caller's validate job carries an `if:` (a job with no "
         "`if:` would also run, but the predicate is the point — assert it is present)")
    if caller_if is not None:
        def caller_gate(head_fork, same_repo):
            # A null head repo (a deleted fork) evaluates every `full_name` lookup to the
            # empty string, which is != github.repository, so the job SKIPS — the safe
            # default. Model `head_fork` explicitly so a revert to the fork-repo test is
            # caught even where same_repo is true.
            head_full = "o/r" if same_repo else "someoneelse/r"
            ns = Ctx({
                "github": Ctx({"repository": "o/r",
                               "event": Ctx({"pull_request": Ctx({"head": Ctx({"repo": Ctx({
                                   "full_name": head_full, "fork": head_fork})})})})}),
            })
            return eval_gh(caller_if, ns)
        note(caller_gate(head_fork=True, same_repo=True) is True,
             "functional: a SAME-REPO PR in a first-party FORK repo (head.fork=true, "
             "head.full_name==github.repository) RUNS the validator (the exact dsh-github#2 "
             "shape the fork-repo test wrongly skipped)")
        note(caller_gate(head_fork=False, same_repo=True) is True,
             "functional: a SAME-REPO PR in a non-fork repo RUNS the validator")
        note(caller_gate(head_fork=True, same_repo=False) is False,
             "functional: an EXTERNAL-FORK PR (head.full_name!=github.repository) SKIPS "
             "(untrusted contribution + no fork secrets — the security intent preserved)")
        note("head.repo.fork == false" not in caller_if,
             "forbid: the retired fork-repo predicate `head.repo.fork == false` is GONE "
             "(it is true for every PR in a fork repo, so it dead-locked first-party forks)")
    # FUNCTIONAL coverage (the review's R10 finding: the env entry and the engine-defective
    # classification shipped with NO assertion that fails without them).
    review_env = find_step(steps, "id", "review")["env"]
    note("AI_REVIEW_STREAM_IDLE_TIMEOUT" in review_env,
         "functional: the review step EXPORTS AI_REVIEW_STREAM_IDLE_TIMEOUT (the "
         "streaming engine's silence bound)")
    if "AI_REVIEW_STREAM_IDLE_TIMEOUT" in review_env:
        raw_i = review_env["AI_REVIEW_STREAM_IDLE_TIMEOUT"]
        ns_unset_i = Ctx({"vars": Ctx({}), "inputs": Ctx({}), "secrets": Ctx({})})
        ns_set_i = Ctx({"vars": Ctx({"AI_REVIEW_STREAM_IDLE_TIMEOUT": "45"}),
                        "inputs": Ctx({}), "secrets": Ctx({})})
        note(subst(raw_i, ns_unset_i) == "",
             "functional: with the org var UNSET the idle bound is EMPTY "
             "(the engine default applies)")
        note(subst(raw_i, ns_set_i) == "45",
             "functional: with the org var SET the idle bound RESOLVES to the set value")
    note("AI_REVIEW_ATTEMPT_TIMEOUT" in review_env,
         "functional: the review step EXPORTS AI_REVIEW_ATTEMPT_TIMEOUT (optional "
         "whole-request cap, empty by default)")
    if "AI_REVIEW_ATTEMPT_TIMEOUT" in review_env:
        raw = review_env["AI_REVIEW_ATTEMPT_TIMEOUT"]
        ns_unset = Ctx({"vars": Ctx({}), "inputs": Ctx({}), "secrets": Ctx({})})
        ns_set = Ctx({"vars": Ctx({"AI_REVIEW_ATTEMPT_TIMEOUT": "120"}),
                      "inputs": Ctx({}), "secrets": Ctx({})})
        note(subst(raw, ns_unset) == "",
             "functional: with the org var UNSET the whole-request cap is EMPTY "
             "(the engine default applies; no hardcoded 5m)")
        note(subst(raw, ns_set) == "120",
             "functional: with the org var SET the cap RESOLVES to the set value")
    for knob in ("AI_REVIEW_REASONING_EFFORT", "AI_REVIEW_MAX_TOKENS"):
        note(knob in review_env,
             "functional: the review step EXPORTS " + knob + " (a generation bound)")
        if knob in review_env:
            ns_unset_k = Ctx({"vars": Ctx({}), "inputs": Ctx({}), "secrets": Ctx({})})
            ns_set_k = Ctx({"vars": Ctx({knob: "x"}), "inputs": Ctx({}), "secrets": Ctx({})})
            note(subst(review_env[knob], ns_unset_k) == "",
                 "functional: with the org var UNSET " + knob + " is EMPTY (engine default applies)")
            note(subst(review_env[knob], ns_set_k) == "x",
                 "functional: with the org var SET " + knob + " resolves to the set value")
    for knob in ("AI_REVIEW_DEBUG", "AI_REVIEW_DEBUG_REASONING"):
        note(knob in review_env,
             "functional: the review step EXPORTS " + knob + " (the full debug trace "
             "an RCA needs — per-turn timing, usage, finish_reason, reasoning)")
        if knob in review_env:
            ns_unset_d = Ctx({"vars": Ctx({}), "inputs": Ctx({}), "secrets": Ctx({})})
            ns_set_d = Ctx({"vars": Ctx({knob: "1"}), "inputs": Ctx({}), "secrets": Ctx({})})
            note(subst(review_env[knob], ns_unset_d) == "",
                 "functional: with the org var UNSET " + knob + " is EMPTY (debug off)")
            note(subst(review_env[knob], ns_set_d) == "1",
                 "functional: with the org var SET " + knob + " resolves to the set value")
    # R5: the knobs the pinned engine no longer READS are not forwarded. Each was
    # removed because the engine has no `getenvAny` caller for it — the tool loop and
    # the per-turn retry loop were deleted in plugin-review v2026.264.1425, so
    # MAX_TURNS / TOOL_RESULT_MAX_BYTES / MAX_ATTEMPTS reach nothing. Forwarding them
    # kept advertising a tunable that is inert; a knob with no reader is not a knob.
    for dead in ("AI_REVIEW_TOOL_RESULT_MAX_BYTES", "AI_REVIEW_MAX_TURNS",
                 "AI_REVIEW_MAX_ATTEMPTS"):
        note(dead not in review_env,
             "functional: the review step does NOT forward " + dead + " (the pinned "
             "engine has no reader for it — the knob is DELETED, not left as a no-op)")
    # The ONE prompt mechanism (this change): AI_REVIEW_PROMPT is forwarded from the
    # org variable and REPLACES the engine's generic embedded default. The dead
    # REVIEW_PROMPT_PATH file mechanism and the AI_REVIEW_PROMPT_EXTRA append knob
    # are GONE, and the INCONCLUSIVE diagnostics tail is bounded so the notice
    # always posts under GitHub's 65536-character comment limit.
    note("AI_REVIEW_PROMPT" in review_env,
         "functional: the review step EXPORTS AI_REVIEW_PROMPT (the ONE prompt mechanism)")
    if "AI_REVIEW_PROMPT" in review_env:
        ns_unset_p = Ctx({"vars": Ctx({}), "inputs": Ctx({}), "secrets": Ctx({})})
        ns_set_p = Ctx({"vars": Ctx({"AI_REVIEW_PROMPT": "RULES"}), "inputs": Ctx({}), "secrets": Ctx({})})
        note(subst(review_env["AI_REVIEW_PROMPT"], ns_unset_p) == "",
             "functional: with the org var UNSET AI_REVIEW_PROMPT is EMPTY (the generic engine default applies)")
        note(subst(review_env["AI_REVIEW_PROMPT"], ns_set_p) == "RULES",
             "functional: with the org var SET AI_REVIEW_PROMPT resolves to the set value")
    note("REVIEW_PROMPT_PATH" not in review_env and "AI_REVIEW_PROMPT_EXTRA" not in review_env,
         "structural: the dead REVIEW_PROMPT_PATH file mechanism and the AI_REVIEW_PROMPT_EXTRA "
         "append knob are GONE from the review step (ONE prompt mechanism)")
    note(("cut -c1-2000" not in text and "tail -c 16000" not in text
          and "tail -n 40 /tmp/review.log" not in text),
         "structural: the INCONCLUSIVE notice does NOT embed the review-log diagnostics "
         "(a degenerate-repetition log is hundreds of KB; embedding it feeds the runaway "
         "back into the NEXT review's context and deepens the collapse — opencharly/charly#712)")
    note("evidence artifact" in text,
         "structural: the INCONCLUSIVE notice points at the run's evidence artifact + job log "
         "for the full diagnostics, instead of embedding them")
    # The auto-close counter matches the EXACT header the INCONCLUSIVE gate posts.
    # The previous guard counted the literal in the workflow TEXT (>= 2) — a TAUTOLOGY:
    # the literal also occurs in the counter's own jq filter and its explanatory comment,
    # so a rename of the notice header would make the production count 0 while this guard
    # still passed. Derive the literal from the COUNTER, then require it in the GATE's
    # emitted notice, so the two surfaces are tied rather than counted.
    auto_close_run = find_step(steps, "name", "Auto-close (max attempts; eval verdicts only)")["run"]
    concl_run = find_step(steps, "name", "Gate (inconclusive)")["run"]
    inconclusive_literal = "## validator INCONCLUSIVE"
    if inconclusive_literal in auto_close_run:
        note(inconclusive_literal in concl_run,
             "structural: the auto-close counter's literal (" + repr(inconclusive_literal) +
             ") is the SAME header the INCONCLUSIVE gate posts — the literal the counter "
             "MATCHES is present in the gate's notice body, so a rename of the notice fails HERE")
        note("echo '## validator INCONCLUSIVE" in concl_run,
             "structural: the INCONCLUSIVE notice's first echoed line IS the counter's literal "
             "(the exact header, not a substring of prose)")
    else:
        note(False,
             "structural: the auto-close counter no longer matches " + repr(inconclusive_literal) +
             " — the harness cannot tie the count to the emitted notice (update this guard "
             "together with the counter)")
    note("## Review — BLOCK" in auto_close_run,
         "structural: the auto-close counter still matches the BLOCK verdict's exact header")
    # The COUNT-BASED bound is the structural contract: ONE org variable
    # (AI_REVIEW_AUTO_CLOSE_AFTER) over `BLOCK` + engine/EVAL INCONCLUSIVE, with a CLEAR
    # INFRA INCONCLUSIVE excluded (opencharly/.github#170 — reverts the #169 one-shot).
    auto_close_env = find_step(
        steps, "name", "Auto-close (max attempts; eval verdicts only)")["env"]
    note("INCONCLUSIVE_THRESHOLD" not in auto_close_env,
         "structural: the ONE-INCONCLUSIVE constant is GONE — there is ONE count-based bound "
         "(the #169 per-class split is reverted)")
    note("AI_REVIEW_AUTO_CLOSE_AFTER" in auto_close_env.get("THRESHOLD", ""),
         "structural: the bound is the org variable AI_REVIEW_AUTO_CLOSE_AFTER "
         "(got " + repr(auto_close_env.get("THRESHOLD")) + ")")
    note("steps.parse.outputs.verdict" in auto_close_env.get("VERDICT", ""),
         "structural: the auto-close step reads THIS run's verdict, so an eval INCONCLUSIVE "
         "whose notice the gate posts LATER still counts as one")
    note("steps.parse.outputs.inconclusive_infra" in auto_close_env.get("THIS_INFRA", ""),
         "structural: the auto-close step reads THIS run's infra/eval class, so a clear infra "
         "failure is EXCLUDED from the count")
    note("Verdict class: infra" in auto_close_run,
         "structural: the counter matches the EXACT literal the INCONCLUSIVE gate emits for an "
         "infra run (`Verdict class: infra`) and excludes it from the max")
    note("open a clean PR from scratch" in auto_close_run,
         "structural: the close notice names the policy — a clean PR from scratch once the "
         "counting verdicts reach the bound — instead of a bare threshold")
    note("excluded as clear" in auto_close_run and "infrastructure" in auto_close_run,
         "structural: the close notice states that clear infra failures were EXCLUDED and did "
         "NOT count toward the bound (the operator-visible half of the fix)")
    note("AI_REVIEW_MAX_ATTEMPTS" not in review_env
         and "AI_REVIEW_TOOL_RESULT_MAX_BYTES" not in review_env,
         "structural: the retired retry/context knobs stay OUT of the review step's env "
         "block (the assertion above is functional; this pins the block surface too)")
    note("engine_defective=false" in text and "'turn 1: [0-9]+ tool call'" in text,
         "structural: the engine-defective classification is DERIVED from the run's own "
         "signature (a completed turn 1) - pre-fix: absent, so every verdict-less run was "
         "labelled provider-unanswered")
    # PRECEDENCE (load-bearing, and NOT caught by any functional scenario): the engine's
    # own terminal class is a DIRECT statement of why the run ended, while every branch
    # below it is a heuristic over log signatures. A direct statement outranks a
    # heuristic, so the two terminal classes must be tested BEFORE the engine-defective
    # signature. A log can carry BOTH (a cut generation that also shows a completed turn
    # 1), and moving these branches down would silently relabel an attempt-cap or
    # empty-completion run as engine-defective - a diagnosis regression that no scenario
    # above would fail on, because each scenario pins one isolated class.
    note(concl_run.index('INCONCLUSIVE_CLASS" = "attempt-cap"')
         < concl_run.index('ENGINE_DEFECTIVE" = "true"')
         and concl_run.index('INCONCLUSIVE_CLASS" = "empty-completion"')
         < concl_run.index('ENGINE_DEFECTIVE" = "true"')
         and concl_run.index('INCONCLUSIVE_CLASS" = "engine-terminal-other"')
         < concl_run.index('ENGINE_DEFECTIVE" = "true"'),
         "structural: the engine-terminal classes (attempt-cap / empty-completion / "
         "engine-terminal-other) are tested BEFORE the workflow-side engine-defective "
         "signature (the engine's own statement outranks a heuristic)")
    # THE ANTI-FOLDING GUARD (opencharly/.github#133). The pre-fix classifier keyed the
    # "provider unanswered" flag on a single substring match that INCLUDED `inconclusive:`
    # - true for EVERY class the engine names - so every class collapsed into that one
    # label and one canned narrative. The fallback must keep matching only the real stall
    # markers; re-adding `inconclusive:` there silently re-opens the whole defect, and no
    # functional scenario would catch it (each one pins a single class).
    stall_fallback = [ln for ln in review_run.splitlines() if "Client[.]Timeout exceeded" in ln]
    note(len(stall_fallback) == 1 and "inconclusive:" not in stall_fallback[0],
         "structural: the no-terminal-line fallback does NOT match `inconclusive:` - that "
         "substring is true for EVERY engine class, so matching it there is what folded "
         "every class into provider-unanswered")
    note("provider never answered or stopped streaming" in review_run,
         "structural: the classifier keys on the engine's REAL terminal wording "
         "(review.go's timeout class), not on a retired line the engine never emits")
    # NOTE: the SELECTION of the class is asserted FUNCTIONALLY by the `engine-defective`
    # scenario below - its fake log carries a completed turn 1 + a provider marker, and its
    # expect_comment_contains requires the class in the posted INCONCLUSIVE notice. It is
    # deliberately NOT asserted by a text check (a source-text match is structural, not
    # functional, and must not be labelled the other way).
    # ENGINE PIN ENFORCEMENT (the stale-engine gate defect). The former ensure-charly
    # trusted ANY on-PATH charly (`if command -v charly; then exit 0`), so on a
    # self-hosted runner whose image bakes an OLD charly the org pin was never
    # downloaded and the gate silently ran the STALE welded plugin-review (the
    # pre-fix tool-loop engine -> no verdict, check RED). The step must now refuse an
    # unpinned run AND verify the on-PATH charly against the pin.
    ensure_run = find_step(steps, "id", "ensure-charly")["run"]
    note("${CHARLY_VERSION:-v2026.254.1902}" not in ensure_run and
         "${CHARLY_VERSION:-v2026.251.1947}" not in ensure_run,
         "structural: the silent-fallback default VALUE is GONE from ensure-charly "
         "(an unset pin must never downgrade to a bundled engine)")
    note('if [ -z "${CHARLY_VERSION:-}" ]' in ensure_run,
         "structural: the emptiness check is the -z GUARD (exit 3), not a default value")
    note('TAG="$CHARLY_VERSION"' in ensure_run,
         "structural: the pin is used VERBATIM (no `:-default` expansion)")
    note("::error::" in ensure_run and "exit 3" in ensure_run,
         "structural: a missing pin is a LOUD ::error:: that exits 3 (the INCONCLUSIVE "
         "class), not a ::warning:: or a silent fallback")
    note("command -v charly" in ensure_run and 'WANT="${TAG#v}"' in ensure_run,
         "structural: the on-PATH charly is verified against the pin's version, not trusted")
    note("::warning::on-PATH charly" in ensure_run,
         "structural: a mismatched on-PATH engine is LOUD (::warning::) and the pinned "
         "release is downloaded so the pinned engine always wins")
    parse_run = find_step(steps, "id", "parse")["run"]
    note('"$rc" -ne 0' in review_run and "discarded" in review_run,
         "structural: the review step gates on the CAPTURED rc - a non-zero review "
         "exit may only yield BLOCK (T3/T4 fail-closed)")
    note("REVIEW_RC" in parse_run,
         "structural: Parse verdict is the second fail-closed layer (it knows the "
         "review rc and may only pass BLOCK through)")
    note("discarded_verdict" in text and "DISCARDED_VERDICT" in text,
         "structural: the discarded-verdict class reaches the INCONCLUSIVE comment")
    note(os.path.exists(HARNESS_WORKFLOW_PATH),
         "structural: .github/workflows/validator-harness.yml exists (the coverage is wired)")
    if os.path.exists(HARNESS_WORKFLOW_PATH):
        with open(HARNESS_WORKFLOW_PATH, "r", encoding="utf-8") as fh:
            harness_wf = fh.read()
        note(".github/tests/validator-gate-harness.py" in harness_wf,
             "structural: .github/workflows/validator-harness.yml RUNS this harness "
             "(coverage that never runs enforces nothing)")

    # FUNCTIONAL: the ensure-charly pin-enforcement behaviour, executed as the real
    # step body (GitHub expressions substituted) against a controlled PATH. Three
    # cases prove the stale-engine defect can never recur silently:
    #   (a) pin UNSET          -> ::error:: + exit 3 (INCONCLUSIVE; never a fallback)
    #   (b) on-PATH == pin     -> exit 0 (uses the on-PATH binary)
    #   (c) on-PATH != pin     -> ::warning:: + downloads the pinned release
    pin_tmp = make_tmpdir("validator-pin-guard.")
    pin_ns = build_ns({}, pin_tmp, pin_tmp)
    pin_script = os.path.join(pin_tmp, "ensure-charly.sh")
    with open(pin_script, "w", encoding="utf-8") as fh:
        fh.write(subst(ensure_run, pin_ns))
    bash_path = shutil.which("bash") or "/bin/bash"

    def run_pin_step(env_path, charly_version):
        env = dict(os.environ)
        # PREPEND the fake bin to the real PATH (as the runner does), so coreutils
        # (grep/mkdir/…) resolve while `charly` comes from the fake bin.
        env["PATH"] = env_path + ":" + os.environ.get("PATH", "/usr/bin:/bin")
        if charly_version is None:
            env.pop("CHARLY_VERSION", None)
        else:
            env["CHARLY_VERSION"] = charly_version
        proc = subprocess.run([bash_path, "--noprofile", "--norc", "-eo", "pipefail", pin_script],
                              cwd=pin_tmp, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, universal_newlines=True)
        return proc.returncode, proc.stdout

    # (a) pin unset: a PATH with no charly anywhere on it.
    empty_bin = os.path.join(pin_tmp, "empty"); os.makedirs(empty_bin)
    rc, out = run_pin_step(empty_bin, None)
    note(rc == 3 and "::error::" in out,
         "functional: ensure-charly with the pin UNSET exits 3 with ::error:: (no silent "
         "fallback to a bundled engine) — got rc=" + str(rc))
    # (b) on-PATH matches the pin.
    match_bin = os.path.join(pin_tmp, "match"); os.makedirs(match_bin)
    write_executable(os.path.join(match_bin, "charly"),
                     "#!/usr/bin/env bash\necho 2026.267.0045\n")
    rc, out = run_pin_step(match_bin, "v2026.267.0045")
    note(rc == 0 and "matches the pin" in out,
         "functional: ensure-charly uses an on-PATH charly whose version EQUALS the pin "
         "(rc=0) — got rc=" + str(rc))
    # (c) on-PATH differs (the live stale-runner case): it warns and downloads the pin.
    stale_bin = os.path.join(pin_tmp, "stale"); os.makedirs(stale_bin)
    write_executable(os.path.join(stale_bin, "charly"),
                     "#!/usr/bin/env bash\necho 2026.256.1316\n")
    rc, out = run_pin_step(stale_bin, "v2026.267.0045")
    note("::warning::on-PATH charly" in out and "downloading" in out,
         "functional: ensure-charly LOUDLY warns and downloads the pinned engine when the "
         "on-PATH charly DIFFERS from the pin (the stale-engine defect)")

    # HEAD CHECK-RUNS GATE (charly#796). The org's ONE required context is
    # `validate / validate`, so a repo's own `ci` was enforced by nobody and a head whose
    # `go` was red could still merge — MEASURED on charly#795 (go failed 9m16s before
    # validate passed) and charly#791 (merged at 21:25:04Z while `go` was still RUNNING;
    # `go` failed at 21:27:24Z). This step closes that: it reads the head's OWN check runs
    # and fails the required check on any that did not pass, after WAITING (bounded) for
    # any still in flight. It reads the live GitHub API, so — exactly like ensure-charly —
    # it is NOT in TARGETS; the REAL body is run below against a controlled PATH carrying a
    # fake `curl`. Every branch asserted here was ALSO proven against the live API (the
    # PR body carries that transcript); the fake is what makes the coverage deterministic
    # on every push, not a substitute for the live proof.
    head_run = find_step(steps, "id", "head-checks")["run"]
    cr_tmp = make_tmpdir("validator-head-checks.")
    write_executable(os.path.join(cr_tmp, "curl"), FAKE_CURL_CHECKRUNS)

    # `name` only names the temp script: the FAKE_CR_CASE the fake `curl` keys on is always
    # `case`, so a pre-fix run can reuse a real case's payload without clobbering its file.
    def run_head_checks(script_text, case, name=None):
        script = os.path.join(cr_tmp, (name or case) + ".sh")
        with open(script, "w", encoding="utf-8") as fh:
            fh.write(script_text)
        env = dict(os.environ)
        env["PATH"] = cr_tmp + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin")
        env.update({
            "GITHUB_API_URL": "https://api.github.com",
            "GITHUB_REPOSITORY": "opencharly/harness-fixture",
            "GITHUB_RUN_ID": "424242",
            "GH_TOKEN": "fake-token",
            "HEAD_SHA": "0" * 40,
            # The harness never sleeps: a zero budget means the first poll that finds
            # something in flight has already reached the deadline, so the FAIL-CLOSED
            # branch is asserted without waiting 10 minutes for it.
            "WAIT_BUDGET_SECONDS": "0",
            "FAKE_CR_CASE": case,
        })
        proc = subprocess.run([bash_path, "--noprofile", "--norc", "-eo", "pipefail", script],
                              cwd=cr_tmp, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, universal_newlines=True)
        return proc.returncode, proc.stdout

    for case, want_rc, marker in [
        ("pass", 0, "safe to arm auto-merge"),
        ("bad", 1, "did not pass"),
        ("pending", 1, "could not confirm this head is green"),
        ("gap", 1, "did not pass"),
        ("self", 0, "safe to arm auto-merge"),
    ]:
        rc, out = run_head_checks(head_run, case)
        note(rc == want_rc and marker in out,
             "functional: head-checks `" + case + "` exits " + str(want_rc) + " with `" +
             marker + "` — got rc=" + str(rc) + " out=" + repr(out[-200:]))

    # R7 — the `gap` case must FAIL without the change, or it pins nothing. The pre-fix
    # body read `filter=latest`, which GitHub drops the check name from mid-re-run; the
    # same payload then looks like a clean head and the gate arms auto-merge. Reconstruct
    # that one-line difference and run it against the SAME `gap` payload the real body is
    # asserted on above (FAKE_CR_CASE must be `gap` — any other name misses every branch of
    # the fake and falls through to an EMPTY check set, where rc=0 holds for ANY body and
    # the assertion pins nothing).
    rc_legacy, _ = run_head_checks(head_run.replace("filter=all", "filter=latest"),
                                  "gap", "gap-prefix")
    note(rc_legacy == 0,
         "functional: the PRE-FIX body (filter=latest) PASSES the `gap` payload — the "
         "`gap` case genuinely reproduces the charly#796 defect (the same payload is rc=1 "
         "for the shipped body and rc=0 here, so the case pins the change) "
         "— got rc=" + str(rc_legacy))

    tmpdir = make_tmpdir("validator-gate-harness.")
    fakedir = os.path.join(tmpdir, "fakebin")
    os.makedirs(fakedir)
    write_executable(os.path.join(fakedir, "charly"), FAKE_CHARLY)
    write_executable(os.path.join(fakedir, "gh"), FAKE_GH)
    workspace = os.path.join(tmpdir, "workspace")
    os.makedirs(os.path.join(workspace, "runner-config", "prompt"))
    open(os.path.join(workspace, "runner-config", "review-plan.yml"), "w").close()
    open(os.path.join(workspace, "runner-config", "prompt", "validator.md"), "w").close()

    scenario_results = []
    for spec in SCENARIOS:
        result = run_scenario(spec, ordered, tmpdir, fakedir, workspace)
        scenario_results.append((spec, result))
        log.append("")
        log.append("=== scenario: " + spec["name"] + "   (fake charly scenario: " + spec["fake"] + ") ===")
        log.extend(result["transcript"])
        log.append("  job exit " + str(result["job_exit"]) + "   (expected " + str(spec["expect_exit"]) + ")")
        prefix = "scenario " + spec["name"] + ": "
        note(result["job_exit"] == spec["expect_exit"],
             prefix + "job exit " + str(result["job_exit"]) + " == expected " + str(spec["expect_exit"]))
        note(result["executed"] == spec["expect_steps"],
             prefix + "executed steps " + repr(result["executed"]) + " == expected " + repr(spec["expect_steps"]))
        verdict = result["outputs"].get("parse", {}).get("verdict")
        note(verdict == spec["expect_verdict"],
             prefix + "classified verdict " + repr(verdict) + " == expected " + repr(spec["expect_verdict"]))
        review_outputs = result["outputs"].get("review", {})
        for key, value in spec.get("expect_review_outputs", {}).items():
            actual = review_outputs.get(key)
            note(actual == value,
                 prefix + "review output " + key + "=" + repr(actual) + " == expected " + repr(value))
        armed = "pr merge --auto" in result["calls"]
        note(armed == spec["expect_auto_merge"],
             prefix + "auto-merge armed (" + str(armed) + ") == expected " +
             str(spec["expect_auto_merge"]))
        # Auto-close: the step posts a notice + closes the PR at its class bound — the org
        # BLOCK threshold, or ONE INCONCLUSIVE. Asserted from the gh call log so the branch
        # is proven.
        closed = "pr close" in result["calls"]
        note(closed == spec.get("expect_closed", False),
             prefix + "PR closed (" + str(closed) + ") == expected " +
             str(spec.get("expect_closed", False)))
        has_comment = result["comment"].strip() != ""
        note(has_comment == spec["expect_comment"],
             prefix + "PR comment posted == " + str(spec["expect_comment"]))
        for needle in spec.get("expect_comment_contains", []):
            note(needle in result["comment"],
                 prefix + "comment body contains " + repr(needle))
        # A MISATTRIBUTED root cause is invisible to a positive assertion: a notice can name
        # the right class and still carry the wrong narrative (exactly what happened on
        # 2026-09-12, org-wide). This lets a scenario assert what must NOT appear.
        for needle in spec.get("expect_comment_excludes", []):
            note(needle not in result["comment"],
                 prefix + "comment body does NOT contain " + repr(needle))
        # The run Summary is the second, ALWAYS-present surface: a reader who opens the
        # failed run must find the class inputs and the effective configuration there.
        for needle in spec.get("expect_summary_contains", []):
            note(needle in result["summary"],
                 prefix + "run Summary contains " + repr(needle))

    # ==== END-TO-END: tie the auto-close counter to the gate's EMITTED artifact ====
    # The validator's block-2 finding: the old guard counted the counter's literal in the
    # workflow TEXT (`text.count(...) >= 2`), but that literal also occurs in the counter's
    # own jq filter and its explanatory comment — so it was a TAUTOLOGY and a rename of the
    # notice header would silently zero the production count while the guard still passed.
    # The tie is now made against the ARTIFACT: take the EXACT comment body the real
    # `Gate (inconclusive)` step posted (captured in $FAKE_COMMENT_LOG), replay it through the
    # REAL Auto-close step, and require it to CLOSE. A rename of either surface fails here.
    auto_close_step = find_step(steps, "name", "Auto-close (max attempts; eval verdicts only)")
    replay_ns = build_ns({}, workspace, tmpdir)
    replay_bin = os.path.join(tmpdir, "replay-bin")
    os.makedirs(replay_bin)
    write_executable(os.path.join(replay_bin, "gh"), FAKE_GH)
    write_executable(os.path.join(replay_bin, "charly"), FAKE_CHARLY)
    auto_close_script = os.path.join(tmpdir, "replay-auto-close.sh")
    with open(auto_close_script, "w", encoding="utf-8") as fh:
        fh.write(subst(auto_close_step["run"], replay_ns))

    def run_auto_close(comment_log_body):
        """Replay a captured comment log through the REAL auto-close step (threshold 1)."""
        clog = os.path.join(tmpdir, "replay.comment.log")
        with open(clog, "w", encoding="utf-8") as fh:
            fh.write(comment_log_body)
        calls = os.path.join(tmpdir, "replay.calls.log")
        open(calls, "w").close()
        genv = dict(os.environ)
        genv["PATH"] = replay_bin + os.pathsep + genv.get("PATH", "")
        for key, value in auto_close_step["env"].items():
            genv[key] = subst(value, replay_ns)
        genv["THRESHOLD"] = "1"          # force the close branch on a single verdict
        genv["FAKE_LOG"] = calls
        genv["FAKE_COMMENT_LOG"] = clog
        # ZERO synthetic counts: the ONLY way the counter reaches 1 is by matching the body
        # REPLAYED from the gate's own emitted notice — never a seeded literal.
        genv["FAKE_BLOCK_COUNT"] = "0"
        genv["FAKE_INCONCLUSIVE_COUNT"] = "0"
        genv["FAKE_OTHER_COUNT"] = "0"
        genv["FAKE_PAGE_SIZE"] = "30"
        proc = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", auto_close_script],
            cwd=workspace, env=genv, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, universal_newlines=True)
        with open(calls, "r", encoding="utf-8") as fh:
            return proc.returncode, proc.stdout, fh.read()

    pu_result = dict((s["name"], r) for s, r in scenario_results).get("verdict-less")
    emitted_log = pu_result["comment_log"] if pu_result else ""
    # The gate's notice is selected BY HEADER, not by position: on an INCONCLUSIVE run the
    # auto-close notice is posted FIRST (the auto-close step runs before the gate), so the
    # gate's own notice is no longer the first block in the log.
    notices = [b.split("=== end comment ===")[0].lstrip("\n")
               for b in emitted_log.split("=== gh pr comment (fake gh) ===")[1:]]
    gate_notice = next((b for b in reversed(notices)
                        if b.startswith("## validator INCONCLUSIVE")), "")
    note(gate_notice.startswith("## validator INCONCLUSIVE"),
         "functional: the EXACT literal the auto-close counter matches "
         "('## validator INCONCLUSIVE') opens the gate's EMITTED notice — the emitted "
         "artifact and the counter's filter are TIED, not counted (renaming the notice fails HERE)")
    # The `verdict-less` fake is an ENGINE/EVAL class (no `Verdict class: infra` line), so it
    # COUNTS. Replay its emitted notice with ZERO synthetic injections.
    rc, out, calls = run_auto_close(emitted_log)
    note("counting verdicts on this PR: 1" in out,
         "functional: replaying the gate's REAL emitted EVAL notice through the REAL auto-close "
         "step yields count == 1 with ZERO synthetic injections (the counter read the emitted artifact)")
    note("pr close" in calls,
         "functional: the replayed emitted notice CLOSES the PR at threshold=1 — the "
         "count-based auto-close is exercised end-to-end against the gate's own header")
    # NEGATIVE CONTROL A — rename the emitted header and prove the REAL counter drops to 0
    # and does NOT close. Without this the positive replay could pass on any text the counter
    # happened to match.
    renamed_log = emitted_log.replace("## validator INCONCLUSIVE", "## validator VERDICT-MISSING", 1)
    rc2, out2, calls2 = run_auto_close(renamed_log)
    note("pr close" not in calls2 and "counting verdicts on this PR: 0" in out2,
         "functional: NEGATIVE CONTROL — renaming the gate's header to "
         "'## validator VERDICT-MISSING' drops the REAL counter to 0 and does NOT close "
         "(the counter is genuinely bound to the emitted header, so a rename cannot silently "
         "disable the auto-close) — got: " +
         " | ".join(line for line in out2.splitlines() if "verdicts on this PR" in line))
    # NEGATIVE CONTROL B — THE OPERATOR'S FIX (opencharly/.github#170). Replay the
    # `provider-unanswered` notice (a CLEAR infra class, carrying `Verdict class: infra`) and
    # prove the REAL counter EXCLUDES it: count 0, NO close. This is the exact regression that
    # closed charly#802 — an infra verdict must never reach the max.
    infra_result = dict((s["name"], r) for s, r in scenario_results).get("provider-unanswered")
    infra_log = infra_result["comment_log"] if infra_result else ""
    rc3, out3, calls3 = run_auto_close(infra_log)
    note("pr close" not in calls3 and "counting verdicts on this PR: 0" in out3,
         "functional: NEGATIVE CONTROL — replaying the gate's REAL infra INCONCLUSIVE notice "
         "(provider-unanswered) leaves the REAL counter at 0 and does NOT close: a clear infra "
         "failure is EXCLUDED from AI_REVIEW_AUTO_CLOSE_AFTER — got: " +
         " | ".join(line for line in out3.splitlines()
                    if "verdicts on this PR" in line or "bound" in line))

    # ==== org-wide candy-validate reusable: the skip + fail-loud branches (R10) ====
    # The reusable `.github/workflows/candy-validate.yml` ships BEHAVIOUR — a repo with
    # no `charly.yml` must skip GREEN, and an unset org pin must fail LOUD (no bundled
    # fallback). Those branches are exercised here by running the REAL `run:` bodies
    # offline (the same technique as the pr-validator scenarios); a static text match
    # would not fail if the branch logic regressed. The happy path (git clone + go
    # build of the pinned charly) needs network and is out of scope for an offline
    # harness; the two guard branches are the new behaviour this reusable adds.
    candy_text, candy_steps = parse_workflow(CANDY_WORKFLOW_PATH)
    note("workflow_call" in candy_text,
         "structural: candy-validate.yml is an `on: workflow_call` reusable (no trigger "
         "of its own, so it never self-runs)")
    candy_detect = find_step(candy_steps, "id", "detect")["run"]
    candy_require = find_step(
        candy_steps, "name",
        "Require the org charly pin (fail loud, never fall back)")
    candy_tmp = make_tmpdir("candy-validate.")
    candy_bash = shutil.which("bash") or "/bin/bash"

    def candy_detect_run(ws):
        """Run the REAL detect step body against a workspace; return (rc, out, outputs)."""
        out_path = os.path.join(ws, "detect.out")
        open(out_path, "w").close()
        denv = dict(os.environ)
        denv["GITHUB_OUTPUT"] = out_path
        proc = subprocess.run(
            [candy_bash, "--noprofile", "--norc", "-eo", "pipefail", "-c", candy_detect],
            cwd=ws, env=denv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            universal_newlines=True)
        return proc.returncode, proc.stdout, read_outputs(out_path)

    # (a) NO charly.yml -> detect emits present=false, and the pin-required step's `if`
    #     resolves FALSE, so it is skipped and the job stays GREEN (the skip contract).
    ws_absent = os.path.join(candy_tmp, "absent")
    os.makedirs(ws_absent)
    rc, out, outs = candy_detect_run(ws_absent)
    note(rc == 0 and outs.get("present") == "false",
         "functional: candy-validate detect with NO charly.yml emits present=false "
         "(the clean-skip contract) — got present=" + repr(outs.get("present")))
    ns_absent = build_ns({"detect": outs}, ws_absent, candy_tmp)
    note(subst("${{ " + candy_require["if"] + " }}", ns_absent) == "false",
         "functional: candy-validate's pin-required step `if` resolves FALSE when "
         "charly.yml is absent (the fail-loud step is SKIPPED, never run on a "
         "non-candy repo)")

    # (b) charly.yml PRESENT, org pin UNSET -> the require step exits non-zero LOUD.
    ws_present = os.path.join(candy_tmp, "present")
    os.makedirs(ws_present)
    with open(os.path.join(ws_present, "charly.yml"), "w", encoding="utf-8") as fh:
        fh.write("name: probe\n")
    rc, out, outs = candy_detect_run(ws_present)
    note(rc == 0 and outs.get("present") == "true",
         "functional: candy-validate detect WITH charly.yml emits present=true")
    ns_present = build_ns({"detect": outs}, ws_present, candy_tmp)
    ns_present["vars"] = Ctx({})  # vars.CHARLY_VERSION unset
    req_script = os.path.join(candy_tmp, "require.sh")
    with open(req_script, "w", encoding="utf-8") as fh:
        fh.write(subst(candy_require["run"], ns_present))
    req_env = dict(os.environ)
    for key, value in candy_require["env"].items():
        req_env[key] = subst(value, ns_present)
    proc = subprocess.run(
        [candy_bash, "--noprofile", "--norc", "-eo", "pipefail", req_script],
        cwd=ws_present, env=req_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        universal_newlines=True)
    note(proc.returncode != 0 and "::error::" in proc.stdout,
         "functional: candy-validate with charly.yml present and vars.CHARLY_VERSION "
         "UNSET exits non-zero with ::error:: (fail loud; NO bundled fallback) — got "
         "rc=" + str(proc.returncode))

    # (c) pin SET -> the guard passes (rc 0). Proves the fail is the UNSET pin, not the step.
    req_env_set = dict(req_env)
    req_env_set["CHARLY_VERSION"] = "v2026.271.0950"
    proc = subprocess.run(
        [candy_bash, "--noprofile", "--norc", "-eo", "pipefail", req_script],
        cwd=ws_present, env=req_env_set, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        universal_newlines=True)
    note(proc.returncode == 0,
         "functional: candy-validate with the org pin SET passes the pin guard (rc=0)")

    # SELF-CLEANING COVERAGE (R1): every temp dir this run created is removed here, and
    # the removal is ASSERTED. One functional test (the ensure-charly pin guard) downloads
    # a ~383 MB release; uncleaned dirs accumulate across runs and exhaust the runner's
    # quota (measured: ~30 runs -> EDQUOT, which then fails EVERY scenario and masquerades
    # as a code regression). Removing cleanup must FAIL this assertion, so the leak cannot
    # silently return.
    dirs_created = list(_TMP_DIRS)
    cleanup_tmpdirs()
    leaked = [d for d in dirs_created if os.path.exists(d)]
    note(len(dirs_created) >= 2 and not leaked,
         "functional: the harness removes EVERY temp dir it created (no disk-quota leak) "
         "— created=" + str(len(dirs_created)) + " leaked=" + str(leaked))

    print(NL.join(log))
    failed = [message for ok, message in checks if not ok]
    print("")
    print("scenarios: " + str(len(SCENARIOS)) + "    assertions: " + str(len(checks)))
    if failed:
        print("FAILED assertions:")
        for message in failed:
            print("  - " + message)
        return 1
    print("ALL PASS: " + str(len(checks)) + " assertions across " + str(len(SCENARIOS)) +
          " scenarios, run against the real workflow run: bodies (fakes for charly and gh).")
    print("Coverage is WIRED IN: .github/workflows/validator-harness.yml runs this "
          "harness on every pull_request and on workflow_dispatch.")
    return 0


def main():
    # ROOT FIX for the shared-/tmp race (R1: the hazard was documented, not fixed). The
    # workflow bodies address the runner's absolute paths literally, so two instances WOULD
    # clobber each other's /tmp/review.log. Hold an exclusive lock for the whole run: a second
    # instance waits (bounded) rather than racing, and fails fast with the reason if the first
    # never releases. Same class as the gate's other fail-closed layers - never a silent race.
    lock_path = os.path.join(tempfile.gettempdir(), "pr-validator-harness.lock")
    lock_fh = open(lock_path, "w")
    deadline = time.time() + LOCK_WAIT_SECONDS
    while True:
        try:
            fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() >= deadline:
                print("HARNESS ERROR: another instance holds " + lock_path + " for more than " +
                      str(LOCK_WAIT_SECONDS) + "s (the workflow bodies share the runner's /tmp "
                      "paths); refusing to race.")
                return 1
            time.sleep(0.5)
    try:
        return run_harness()
    except HarnessError as exc:
        print("HARNESS ERROR: " + str(exc))
        return 1
    finally:
        fcntl.flock(lock_fh, fcntl.LOCK_UN)
        lock_fh.close()


if __name__ == "__main__":
    sys.exit(main())