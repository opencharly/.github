#!/usr/bin/env python3
"""Require every first-party workflow action pin to have an audited Node 24 runtime."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
PIN_FILE = ROOT / "scripts/action-runtime-pins.tsv"
WORKFLOW_DIR = ROOT / ".github/workflows"
TOP_LEVEL_WORKFLOWS = tuple(ROOT.glob("*.yml"))
USE_PATTERN = re.compile(r"^\s*(?:-\s*)?uses:\s*(actions/[^\s#]+)", re.MULTILINE)


def load_pins(path: Path = PIN_FILE) -> dict[str, str]:
    pins: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        ref, runtime = line.split("\t", 1)
        if ref in pins:
            raise ValueError(f"duplicate runtime pin: {ref}")
        pins[ref] = runtime
    return pins


def check_files(files: list[Path], pins: dict[str, str]) -> list[str]:
    findings: list[str] = []
    used: set[str] = set()
    for path in files:
        content = path.read_text(encoding="utf-8")
        used.update(USE_PATTERN.findall(content))
        findings.extend(
            f"{path.relative_to(ROOT)}: {finding}"
            for finding in check_text(content, pins)
        )
    findings.extend(f"unused runtime pin: {ref}" for ref in sorted(pins.keys() - used))
    return findings


def self_test() -> None:
    findings = check_text("uses: actions/self-test@v1", {"actions/self-test@v1": "node20"})
    if not findings or "declares node20" not in findings[0]:
        raise SystemExit("action runtime checker self-test failed")
    print("check-action-runtimes self-test: OK (Node 20 pins fail)")


def check_text(text: str, pins: dict[str, str]) -> list[str]:
    findings = []
    for ref in USE_PATTERN.findall(text):
        runtime = pins.get(ref)
        if runtime is None:
            findings.append(f"unaudited action ref {ref}")
        elif runtime != "node24":
            findings.append(f"{ref} declares {runtime}, expected node24")
    return findings


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if sys.argv[1:]:
        print("usage: check-action-runtimes.py [--self-test]", file=sys.stderr)
        return 2
    try:
        pins = load_pins()
    except (OSError, ValueError) as exc:
        print(f"check-action-runtimes: {exc}", file=sys.stderr)
        return 1
    files = sorted(WORKFLOW_DIR.glob("*.yml")) + sorted(TOP_LEVEL_WORKFLOWS)
    findings = check_files(files, pins)
    if findings:
        print("check-action-runtimes: FAILED")
        print("\n".join(f"- {finding}" for finding in findings))
        return 1
    print(f"check-action-runtimes: OK ({len(files)} workflow files; {len(pins)} audited pins; node24)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
