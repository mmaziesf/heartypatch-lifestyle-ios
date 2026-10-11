#!/usr/bin/env python3
"""Validate Spec/*.schema.json against JSON Schema 2020-12 and check fixtures.

- Every schema must itself be a valid 2020-12 schema.
- Every Fixtures/daily_summary/*.json and Fixtures/events/*.json must validate.
- Every Fixtures/invalid/*.json must FAIL (summary-* vs daily_summary schema, event-* vs event schema).
- Every valid fixture must carry "synthetic" in its filename (no real user data in the repo).

Requires: pip install jsonschema
"""
import json
import pathlib
import sys

from jsonschema import Draft202012Validator

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = ROOT / "Spec"
FIX = ROOT / "Fixtures"


def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def main() -> int:
    summary_schema = load(SPEC / "hpl.daily_summary.v1.schema.json")
    event_schema = load(SPEC / "hpl.event.v1.schema.json")
    for s in (summary_schema, event_schema):
        Draft202012Validator.check_schema(s)
    validators = {
        "summary": Draft202012Validator(summary_schema),
        "event": Draft202012Validator(event_schema),
    }
    failures = []

    def check_valid(kind, path):
        if "synthetic" not in path.name:
            failures.append(f"{path.relative_to(ROOT)}: valid fixtures must be labeled '.synthetic.json'")
        errs = sorted(validators[kind].iter_errors(load(path)), key=str)
        if errs:
            failures.append(f"{path.relative_to(ROOT)}: expected valid, got: {errs[0].message}")
        else:
            print(f"ok   valid    {path.relative_to(ROOT)}")

    for p in sorted((FIX / "daily_summary").glob("*.json")):
        check_valid("summary", p)
    for p in sorted((FIX / "events").glob("*.json")):
        check_valid("event", p)
    for p in sorted((FIX / "invalid").glob("*.json")):
        kind = "summary" if p.name.startswith("summary-") else "event"
        if validators[kind].is_valid(load(p)):
            failures.append(f"{p.relative_to(ROOT)}: expected INVALID but schema accepted it")
        else:
            print(f"ok   rejected {p.relative_to(ROOT)}")

    if failures:
        print("\n".join(["", "FAILURES:"] + failures), file=sys.stderr)
        return 1
    print("\nAll schema checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
