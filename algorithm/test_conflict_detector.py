# -*- coding: utf-8 -*-
"""固定用例测试：algorithm/test_cases.json 对 algorithm.conflict_detector.detect。

运行（仓库根目录，任选其一）
    python -m unittest discover -s algorithm -p "test_*.py" -v
    python -m algorithm.test_conflict_detector

三种状态的完整输出（feasible / infeasible / incomplete）见 test_golden_outputs，
完整 JSON 同时写进 docs/contract.md 第一节。
"""

import copy
import json
import os
import re
import unittest

from algorithm.conflict_detector import detect, detect_resolved, detect_trip, trip_from_candidate

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE_PATH = os.path.join(ROOT, "fixtures", "demo-trip.json")
CASES_PATH = os.path.join(ROOT, "algorithm", "test_cases.json")


def _load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _resolve(obj, key):
    """点路径中间段可能是数组，按 member_id / candidate_id / node_id 找。"""
    if isinstance(obj, list):
        for item in obj:
            if key in (item.get("member_id"), item.get("candidate_id"), item.get("node_id")):
                return item
        raise KeyError(key)
    return obj[key]


def _apply_mutation(fixture, mutation):
    parts = mutation["path"].split(".")
    obj = fixture
    for part in parts[:-1]:
        obj = _resolve(obj, part)
    if mutation.get("op") == "delete":
        del obj[parts[-1]]
    else:
        obj[parts[-1]] = copy.deepcopy(mutation["value"])


def _reason_matches(expected, actual):
    if expected["rule_id"] != actual["rule_id"]:
        return False
    if expected.get("member_ids") and expected["member_ids"] != actual["member_ids"]:
        return False
    for key in ("field", "actual", "threshold"):
        if key in expected and expected[key] != actual.get(key):
            return False
    return True


class DetectorCaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = _load(FIXTURE_PATH)
        cls.suite = _load(CASES_PATH)

    # ------------------------------------------------------------ 固定用例

    def test_fixed_cases(self):
        for case in self.suite["cases"]:
            with self.subTest(case=case["case_id"], title=case["title"]):
                self._run_case(case)

    def _run_case(self, case):
        fixture = copy.deepcopy(self.base)
        for mutation in case.get("mutations", []):
            _apply_mutation(fixture, mutation)

        overrides = case["trip"]["overrides"] if case.get("mode") == "resolved_trip" else None
        result = detect_trip(fixture, case["candidate_id"], overrides) if overrides \
            else detect(fixture, case["candidate_id"])
        expect = case["expect"]

        self.assertEqual(expect["status"], result["status"], "status 不符")
        if "reasons_count" in expect:
            self.assertEqual(expect["reasons_count"], len(result["reasons"]),
                             "原因条数不符：%s" % json.dumps(result["reasons"], ensure_ascii=False))
        for expected_reason in expect.get("reasons", []):
            self.assertTrue(any(_reason_matches(expected_reason, r) for r in result["reasons"]),
                            "缺少原因 %s，实得 %s" % (json.dumps(expected_reason, ensure_ascii=False),
                                                    json.dumps(result["reasons"], ensure_ascii=False)))
        for rule_id in expect.get("forbid_rule_ids", []):
            self.assertFalse(any(r["rule_id"] == rule_id for r in result["reasons"]),
                             "出现了禁用的规则 %s" % rule_id)
        if "missing_fields" in expect:
            actual = [{k: m[k] for k in ("member_id", "field", "rule_id") if k in m}
                      for m in result["missing_fields"]]
            self.assertEqual(expect["missing_fields"], actual, "missing_fields 不符")

        if expect.get("identical_serialization"):
            again = detect_trip(fixture, case["candidate_id"], overrides) if overrides \
                else detect(fixture, case["candidate_id"])
            self.assertEqual(json.dumps(result, sort_keys=True), json.dumps(again, sort_keys=True),
                             "两次运行输出不一致")
        if expect.get("identical_fingerprint"):
            again = detect_trip(fixture, case["candidate_id"], overrides) if overrides \
                else detect(fixture, case["candidate_id"])
            self.assertEqual(result["input_fingerprint"], again["input_fingerprint"],
                             "两次运行指纹不一致")

        if "preview_allowed" in expect:
            self.assertEqual(expect["preview_allowed"], result["status"] == "feasible",
                             "G3 预览准入不符")

        for companion in case.get("companion_assertions", []):
            if "status" in companion:
                other = detect(fixture, companion["candidate_id"])
                self.assertEqual(companion["status"], other["status"],
                                 "伴随断言 %s 状态不符" % companion["candidate_id"])
                if "reasons_count" in companion:
                    self.assertEqual(companion["reasons_count"], len(other["reasons"]),
                                     "伴随断言 %s 原因条数不符" % companion["candidate_id"])
            if "unchanged_value" in companion:
                node_id = companion["field"].split(".")[1]
                field = companion["field"].split(".")[-1]
                cand = next(c for c in fixture["candidates"]
                            if c["candidate_id"] == companion["candidate_id"])
                node = next(n for n in cand["nodes"] if n["node_id"] == node_id)
                self.assertEqual(companion["unchanged_value"], node[field],
                                 "候选原节点被改写：%s" % companion["field"])

    # ------------------------------------------------------------ 三态完整输出

    def test_golden_outputs(self):
        """三种状态各一条完整输出；与 docs/contract.md 第一节逐字段一致。"""
        fixture = copy.deepcopy(self.base)

        feasible = detect(fixture, "c02")
        self.assertEqual("feasible", feasible["status"])
        self.assertEqual([], feasible["reasons"])
        self.assertEqual([], feasible["missing_fields"])
        self.assertEqual("c02", feasible["candidate_id"])
        self.assertEqual(self.base["fixture_version"], feasible["fixture_version"])
        self.assertTrue(re.fullmatch(r"[0-9a-f]{8}", feasible["input_fingerprint"]))

        infeasible = detect(fixture, "c01")
        self.assertEqual("infeasible", infeasible["status"])
        self.assertEqual(1, len(infeasible["reasons"]))
        self.assertEqual(["m01"], infeasible["reasons"][0]["member_ids"])
        self.assertEqual("R-BUD-01", infeasible["reasons"][0]["rule_id"])
        self.assertEqual(8100, infeasible["reasons"][0]["actual"])
        self.assertEqual(8000, infeasible["reasons"][0]["threshold"])
        self.assertEqual("m01 承担 81 元，超过上限 80 元 1 元", infeasible["reasons"][0]["message"])

        broken = copy.deepcopy(self.base)
        for member in broken["members"]:
            if member["member_id"] == "m02":
                del member["budget_cap"]
        incomplete = detect(broken, "c01")
        self.assertEqual("incomplete", incomplete["status"])
        self.assertEqual([], incomplete["reasons"],
                         "incomplete 时 reasons 必须为空，不能夹带『甲超支』")
        self.assertEqual([{"member_id": "m02", "field": "budget_cap", "rule_id": "R-DATA-01"}],
                         incomplete["missing_fields"])

    # ------------------------------------------------------------ 入口与契约

    def test_entry_points_agree(self):
        """detect / detect_trip / detect_resolved 三条入口对同一条行程结论一致。"""
        fixture = copy.deepcopy(self.base)
        by_id = detect(fixture, "c02")
        by_overrides = detect_trip(fixture, "c02", [])
        candidate = next(c for c in fixture["candidates"] if c["candidate_id"] == "c02")
        by_trip = detect_resolved(fixture, trip_from_candidate(candidate))

        for other in (by_overrides, by_trip):
            self.assertEqual(by_id["status"], other["status"])
            self.assertEqual(json.dumps(by_id["reasons"], sort_keys=True),
                             json.dumps(other["reasons"], sort_keys=True))

    def test_missing_or_malformed_nodes_return_incomplete(self):
        for bad_nodes in (None, {"node_id": "c02-n01"}, [None]):
            with self.subTest(nodes=bad_nodes):
                fixture = copy.deepcopy(self.base)
                candidate = _resolve(fixture["candidates"], "c02")
                if bad_nodes is None:
                    del candidate["nodes"]
                else:
                    candidate["nodes"] = bad_nodes
                result = detect(fixture, "c02")
                self.assertEqual("incomplete", result["status"])
                self.assertEqual([], result["reasons"])
                self.assertEqual([{"member_id": None, "field": "nodes", "rule_id": "R-DATA-01"}],
                                 result["missing_fields"])

    def test_missing_taboo_tags_is_not_treated_as_no_taboo(self):
        fixture = copy.deepcopy(self.base)
        del _resolve(fixture["members"], "m02")["taboo_tags"]
        result = detect(fixture, "c02")
        self.assertEqual("incomplete", result["status"])
        self.assertEqual([{"member_id": "m02", "field": "taboo_tags", "rule_id": "R-DATA-01"}],
                         result["missing_fields"])

    def test_candidate_window_must_cover_return_node(self):
        fixture = copy.deepcopy(self.base)
        candidate = _resolve(fixture["candidates"], "c02")
        _resolve(candidate["nodes"], "c02-n04")["end"] = "2026-11-21T17:30:00+08:00"
        result = detect(fixture, "c02")
        self.assertEqual("incomplete", result["status"])
        self.assertEqual([{"member_id": None, "field": "window", "rule_id": "R-DATA-01"}],
                         result["missing_fields"])

    def test_duplicate_node_ids_do_not_allow_ambiguous_replacement(self):
        fixture = copy.deepcopy(self.base)
        nodes = _resolve(fixture["candidates"], "c02")["nodes"]
        nodes[2]["node_id"] = nodes[1]["node_id"]
        result = detect(fixture, "c02")
        self.assertEqual("incomplete", result["status"])
        self.assertEqual([{"member_id": None, "field": "nodes.node_id", "rule_id": "R-DATA-01"}],
                         result["missing_fields"])

    def test_case_ids_unique(self):
        ids = [c["case_id"] for c in self.suite["cases"]]
        self.assertEqual(len(ids), len(set(ids)), "case_id 重复")

    def test_fixture_version_matches(self):
        self.assertEqual(self.base["fixture_version"], self.suite["fixture_version"],
                         "fixture 与用例版本号必须同号（契约 F-05）")

    def test_all_times_carry_offset(self):
        """fixture 内所有时间都必须是带偏移的 ISO 8601。"""
        pattern = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+08:00$")
        for member in self.base["members"]:
            for window in member["available_windows"]:
                for key in ("start", "end"):
                    self.assertRegex(window[key], pattern, "成员窗 %s 缺偏移" % member["member_id"])
        for candidate in self.base["candidates"]:
            for key in ("start", "end"):
                self.assertRegex(candidate["window"][key], pattern, "候选全程缺偏移")
            for node in candidate["nodes"]:
                for key in ("start", "end"):
                    self.assertRegex(node[key], pattern,
                                     "节点 %s 时间缺偏移" % node["node_id"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
