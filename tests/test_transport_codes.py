"""Alias compatibility across validation, old stored forms and the detector."""

import json
import unittest
from copy import deepcopy
from pathlib import Path

from backend.models import PreferencesRequest
from backend.rules_adapter import summarize_preferences
from pydantic import ValidationError
from algorithm.conflict_detector import detect


class TransportCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads((Path(__file__).resolve().parents[1] /
                                  "fixtures/demo-trip.json").read_text(encoding="utf-8"))

    def test_old_and_new_member_spellings_have_a_common_transport(self):
        members = deepcopy(self.fixture["members"])
        for index, member in enumerate(members):
            member["allowed_transport"] = ["bike", "bicycle"] if index % 2 else ["bicycle"]
        summary = summarize_preferences(members, "Asia/Shanghai")
        self.assertEqual(summary["common_allowed_transport"], ["bicycle"])

    def test_malformed_transport_is_incomplete_instead_of_raising(self):
        self.fixture["members"][0]["allowed_transport"] = [[]]
        result = detect(self.fixture, "c02")
        self.assertEqual(result["status"], "incomplete")
        self.assertTrue(any(row["field"] == "allowed_transport" for row in result["missing_fields"]))

    def test_api_normalizes_alias_but_rejects_ambiguous_case_and_empty(self):
        fields = {key: self.fixture["members"][0][key] for key in
                  ("available_windows", "budget_cap", "budget_basis", "taboo_tags")}
        parsed = PreferencesRequest(**fields, allowed_transport=["bike", "bicycle", "walk"])
        self.assertEqual(parsed.allowed_transport, ["bicycle", "walk"])
        for invalid in ([], ["Metro"], ["none"], ["other"]):
            with self.subTest(invalid=invalid), self.assertRaises(ValidationError):
                PreferencesRequest(**fields, allowed_transport=invalid)

    def test_detector_accepts_alias_in_either_direction_without_mutating_input(self):
        for member_code, node_code in (("bike", "bicycle"), ("bicycle", "bike")):
            fixture = deepcopy(self.fixture)
            for member in fixture["members"]:
                member["allowed_transport"] = [member_code, "metro", "walk"]
            candidate = next(item for item in fixture["candidates"] if item["candidate_id"] == "c02")
            for node in candidate["nodes"]:
                if node["kind"] == "transit":
                    node["transport"] = node_code
            before = deepcopy(fixture)
            self.assertEqual(detect(fixture, "c02")["status"], "feasible")
            self.assertEqual(fixture, before)
