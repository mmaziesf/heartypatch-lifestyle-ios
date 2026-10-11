#!/usr/bin/env python3
"""Stand-in round-trip tests for environments without Swift.

Mirrors HPLCoreTests: fixture -> typed model -> JSON -> schema-valid and semantically equal.
The Python 'model' is a strict allowlist projection built from the schema itself, so a field
the schema doesn't know is dropped (and the equality check fails loudly).
Full Swift round-trip tests: Packages/HPLCore/Tests (run via scripts/test_packages.sh or Xcode).
"""
import json
import pathlib
import unittest

from jsonschema import Draft202012Validator

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load(p):
    return json.loads(pathlib.Path(p).read_text(encoding="utf-8"))


def strip_nulls(v):
    if isinstance(v, dict):
        return {k: strip_nulls(x) for k, x in v.items() if x is not None}
    if isinstance(v, list):
        return [strip_nulls(x) for x in v]
    return v


def project(value, schema, root):
    """Allowlist projection: keep only what the schema declares (resolves local $ref)."""
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        return project(value, node, root)
    if isinstance(value, dict) and "properties" in schema:
        return {k: project(v, schema["properties"][k], root) for k, v in value.items() if k in schema["properties"]}
    if isinstance(value, list) and isinstance(schema.get("items"), dict):
        return [project(v, schema["items"], root) for v in value]
    return value


class RoundTrip(unittest.TestCase):
    def roundtrip(self, schema_file, fixture_glob):
        schema = load(ROOT / "Spec" / schema_file)
        v = Draft202012Validator(schema)
        files = sorted((ROOT / "Fixtures").glob(fixture_glob))
        self.assertTrue(files, fixture_glob)
        for f in files:
            with self.subTest(fixture=f.name):
                original = load(f)
                model = project(original, schema, schema)
                encoded = json.dumps(model, sort_keys=True, separators=(",", ":"))
                decoded = json.loads(encoded)
                self.assertEqual([], [e.message for e in v.iter_errors(decoded)])
                self.assertEqual(strip_nulls(original), strip_nulls(decoded))

    def test_daily_summary_v1(self):
        self.roundtrip("hpl.daily_summary.v1.schema.json", "daily_summary/*.synthetic.json")

    def test_event_v1(self):
        self.roundtrip("hpl.event.v1.schema.json", "events/*.synthetic.json")

    def test_fixture_is_labeled_synthetic(self):
        for f in (ROOT / "Fixtures" / "daily_summary").glob("*.json"):
            self.assertEqual("synthetic_fixture", load(f)["provenance"], f.name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
