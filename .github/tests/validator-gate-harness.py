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
  1. pass                verdict PASS -> no gate fires -> auto-merge -> exit 0
  2. block               verdict BLOCK -> Gate (BLOCK)                -> exit 1
  3. provider-unanswered no Verdict line, provider marker in the log
                         -> Gate (inconclusive) posts the comment     -> exit 3
  4. verdict-less        review.txt with no Verdict line
                         -> Gate (inconclusive) posts the comment     -> exit 3
  5. mixed               PASS + BLOCK in one review output
                         -> Gate (ambiguous)                          -> exit 2
  6. pass-with-error     the review exits NON-ZERO while writing a PASS line
                         into review.txt -> that untrusted output is
                         DISCARDED, the run is INCONCLUSIVE (exit 3), the
                         INCONCLUSIVE comment is posted and auto-merge is NOT
                         armed (the fail-closed guard on the captured rc).
  7. block-with-error    the review exits NON-ZERO carrying BLOCK -> a finding
                         is a finding: BLOCK is reported (exit 1), NOT
                         discarded into INCONCLUSIVE, and auto-merge is NOT
                         armed.

  EVERY scenario also asserts the gh call log (expect_auto_merge): only
  scenario 1 may contain "gh pr merge --auto". The exit code alone would not
  prove the merge was not armed - a fail-closed classification must be proven,
  not inferred.

  Plus structural guards: the review step contains NO in-job retry (no sleep, no
  for-attempt loop) - the R4 regression guard for the dropped retry band-aid - the
  workflow pins a charly release WITH the taxonomy marker, never the old one, and
  the header names the CORRECTED root cause (a NON-STREAMING request under a
  whole-generation HTTP deadline that a too-short attempt cap cut off -
  opencharly/.github#91), asserts the superseded throttled-egress RCA is GONE,
  documents the org-settable AI_REVIEW_ATTEMPT_TIMEOUT lever, and carries no
  re-run-and-see remedy anywhere.

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

import fcntl
import os
import re
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

STEP_PREFIX = "      - "   # a step marker in this workflow
KEY_INDENT = 8             # name: / id: / if: / run: / env:
CHILD_INDENT = 10          # block-scalar and env entries
EXPR_RE = re.compile(r"[$][{][{](.*?)[}][}]", re.S)
PATH_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)((?:[.][A-Za-z0-9_-]+)+)")

RUNNER_PATHS = ["/tmp/review.txt", "/tmp/review.untrusted.txt", "/tmp/review.log",
                "/tmp/inconclusive-comment.md"]


class HarnessError(Exception):
    pass


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
        return ""

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
    step = {"name": None, "id": None, "if": None, "env": {}, "run": None}
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
        if key in ("name", "id", "if"):
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
                k, _, v = entry.strip().partition(":")
                step["env"][k.strip()] = v.strip()
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
    "    echo \"inconclusive: all 3 attempts timed out - the LLM provider did not respond within the attempt timeout (provider unanswered); this is NOT a review verdict - re-run the gate\" >&2",
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
    "  body=\"\"",
    "  prev=\"\"",
    "  for a in \"$@\"; do",
    "    if [ \"$prev\" = \"--body-file\" ]; then body=\"$a\"; fi",
    "    prev=\"$a\"",
    "  done",
    "  echo \"=== gh pr comment (fake gh) ===\" >> \"$FAKE_COMMENT_LOG\"",
    "  if [ -f \"$body\" ]; then cat \"$body\" >> \"$FAKE_COMMENT_LOG\"; else echo \"(missing body file: $body)\" >> \"$FAKE_COMMENT_LOG\"; fi",
    "  echo \"=== end comment ===\" >> \"$FAKE_COMMENT_LOG\"",
    "fi",
    "exit 0",
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
    ("name", "Gate (BLOCK)"),
    ("name", "Gate (inconclusive)"),
    ("name", "Gate (ambiguous)"),
    ("name", "Enable auto-merge"),
]

SCENARIOS = [
    {
        "name": "pass",
        "fake": "pass",
        "expect_exit": 0,
        "expect_steps": ["review", "parse", "Enable auto-merge"],
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
        "expect_steps": ["review", "parse", "Gate (BLOCK)"],
        "expect_verdict": "BLOCK",
        "expect_comment": False,
        "expect_auto_merge": False,
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "0"},
    },
    {
        "name": "provider-unanswered",
        "fake": "provider-unanswered",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Gate (inconclusive)"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_comment_contains": [
            "validator INCONCLUSIVE",
            "provider unanswered",
            "in-job retries: none",
            "NON-STREAMING",
            "900s default",
            "FAILED TURN",
        ],
        "expect_review_outputs": {"provider_unanswered": "true", "review_rc": "1",
                                  "discarded_verdict": "false"},
    },
    {
        "name": "verdict-less",
        "fake": "verdict-less",
        "expect_exit": 3,
        "expect_steps": ["review", "parse", "Gate (inconclusive)"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_comment_contains": [
            "validator INCONCLUSIVE",
            "verdict-less review output",
            "NON-STREAMING",
            "900s default",
        ],
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "2",
                                  "discarded_verdict": "false"},
    },
    {
        "name": "mixed",
        "fake": "mixed",
        "expect_exit": 2,
        "expect_steps": ["review", "parse", "Gate (ambiguous)"],
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
        "expect_steps": ["review", "parse", "Gate (inconclusive)"],
        "expect_verdict": "INCONCLUSIVE",
        "expect_comment": True,
        "expect_auto_merge": False,
        "expect_comment_contains": [
            "validator INCONCLUSIVE",
            "FAIL-CLOSED",
            "may only carry a real BLOCK finding",
            "NON-STREAMING",
        ],
        "expect_review_outputs": {"provider_unanswered": "false", "review_rc": "1",
                                  "success": "false", "inconclusive": "true",
                                  "discarded_verdict": "true"},
    },
    {
        # A finding is a finding: BLOCK is the ONLY class a non-zero review exit
        # may carry, so it is NOT discarded - the gate reports BLOCK (exit 1),
        # never INCONCLUSIVE and never PASS.
        "name": "block-with-error",
        "fake": "block-with-error",
        "expect_exit": 1,
        "expect_steps": ["review", "parse", "Gate (BLOCK)"],
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
    transcript = []
    job_exit = 0
    step_outputs = {}

    for _, step in ordered:
        name = step["label"]
        condition = step["if"]
        if condition is not None and not eval_gh(condition, ns):
            transcript.append("  [" + name + "] skipped (if: " + condition + ")")
            continue
        env = dict(os.environ)
        env["PATH"] = fakedir + os.pathsep + env.get("PATH", "")
        env["GITHUB_WORKSPACE"] = workspace
        env["GITHUB_ACTIONS"] = "true"
        env["FAKE_LOG"] = log_path
        env["FAKE_COMMENT_LOG"] = comment_path
        env["FAKE_SCENARIO"] = spec["fake"]
        stem = label + "." + re.sub("[^A-Za-z0-9]+", "_", name)
        out_file = os.path.join(tmpdir, stem + ".github_output")
        open(out_file, "w").close()
        env["GITHUB_OUTPUT"] = out_file
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
            job_exit = proc.returncode
            transcript.append("  -> the job stops here, exactly as GitHub would")
            break

    with open(comment_path, "r", encoding="utf-8") as fh:
        comment = fh.read()
    with open(log_path, "r", encoding="utf-8") as fh:
        calls = fh.read()
    for path in RUNNER_PATHS:
        if os.path.exists(path):
            os.remove(path)
    return {
        "transcript": transcript,
        "job_exit": job_exit,
        "executed": executed,
        "outputs": step_outputs,
        "comment": comment,
        "calls": calls,
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
    note("NON-STREAMING request under a WHOLE-GENERATION deadline" in text,
         "structural: header names the CORRECTED root cause (a non-streaming, "
         "whole-generation HTTP deadline)")
    note("throttles/blocks datacenter/shared runner egress" not in text,
         "structural: the superseded throttled-egress RCA is GONE from the workflow "
         "(corrected 2026-09-12 by opencharly/.github#91)")
    note("retry the FAILED TURN" in text and "owner: plugin-review" in text,
         "structural: header routes the durable per-turn fix to its owner (plugin-review)")
    note("remedies: re-run" not in text,
         "structural: no re-run-and-see remedy anywhere in the workflow text")
    note("AI_REVIEW_ATTEMPT_TIMEOUT, org-settable, default 900s" in text,
         "structural: header documents the org-settable cap lever this workflow "
         "passes through")
    # FUNCTIONAL coverage (the review's R10 finding: the env entry and the engine-defective
    # classification shipped with NO assertion that fails without them).
    review_env = find_step(steps, "id", "review")["env"]
    note("AI_REVIEW_ATTEMPT_TIMEOUT" in review_env,
         "functional: the review step EXPORTS AI_REVIEW_ATTEMPT_TIMEOUT for the plugin "
         "(pre-fix tree exported nothing, so no cap could ever be raised)")
    if "AI_REVIEW_ATTEMPT_TIMEOUT" in review_env:
        raw = review_env["AI_REVIEW_ATTEMPT_TIMEOUT"]
        ns_unset = Ctx({"vars": Ctx({}), "inputs": Ctx({}), "secrets": Ctx({})})
        ns_set = Ctx({"vars": Ctx({"AI_REVIEW_ATTEMPT_TIMEOUT": "120"}),
                      "inputs": Ctx({}), "secrets": Ctx({})})
        note(subst(raw, ns_unset) == "900",
             "functional: with the org var UNSET the cap RESOLVES to the 900s default")
        note(subst(raw, ns_set) == "120",
             "functional: with the org var SET the cap RESOLVES to the set value")
    note("engine_defective=false" in text and "'turn 1: [0-9]+ tool call'" in text,
         "functional: the engine-defective classification is DERIVED from the run's own "
         "signature (a completed turn 1) - pre-fix: absent, so every verdict-less run was "
         "labelled provider-unanswered")
    note("ENGINE_DEFECTIVE" in text and "engine-defective (the review engine" in text,
         "functional: the engine-defective class reaches the INCONCLUSIVE notice and is "
         "selected ahead of the provider-unanswered branch")
    note("${CHARLY_VERSION:-v2026.254.1902}" in text,
         "structural: the pinned charly default is the taxonomy-marker release v2026.254.1902")
    note("${CHARLY_VERSION:-v2026.251.1947}" not in text,
         "structural: the pre-taxonomy release v2026.251.1947 is no longer the pinned default")
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

    tmpdir = tempfile.mkdtemp(prefix="validator-gate-harness.")
    fakedir = os.path.join(tmpdir, "fakebin")
    os.makedirs(fakedir)
    write_executable(os.path.join(fakedir, "charly"), FAKE_CHARLY)
    write_executable(os.path.join(fakedir, "gh"), FAKE_GH)
    workspace = os.path.join(tmpdir, "workspace")
    os.makedirs(os.path.join(workspace, "runner-config", "prompt"))
    open(os.path.join(workspace, "runner-config", "review-plan.yml"), "w").close()
    open(os.path.join(workspace, "runner-config", "prompt", "validator.md"), "w").close()

    for spec in SCENARIOS:
        result = run_scenario(spec, ordered, tmpdir, fakedir, workspace)
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
        has_comment = result["comment"].strip() != ""
        note(has_comment == spec["expect_comment"],
             prefix + "PR comment posted == " + str(spec["expect_comment"]))
        for needle in spec.get("expect_comment_contains", []):
            note(needle in result["comment"],
                 prefix + "comment body contains " + repr(needle))

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