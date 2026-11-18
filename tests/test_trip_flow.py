import json
import unittest
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path

from core.trip_state import TripPhase, TripState


class TripFlowTests(unittest.TestCase):
    def test_open_candidates_requires_every_member_submission(self) -> None:
        member_ids = ("m01", "m02", "m03", "m04")
        trip = TripState(member_ids)
        self.assertIs(trip.phase, TripPhase.COLLECTING)

        for member_id in member_ids[:3]:
            trip.submit_member(member_id, {"budget_cap": 8000})
        # 模拟 m01 修改预算，确保同一人的两次提交只计一人。
        trip.submit_member("m01", {"budget_cap": 8500})

        self.assertEqual(trip.pending_member_ids, ("m04",))
        with self.assertRaisesRegex(RuntimeError, "m04"):
            trip.open_candidates()
        self.assertIs(trip.phase, TripPhase.COLLECTING)

        # 拦截后保留已有提交，缺的那位成员补交后可以继续。
        trip.submit_member("m04", {"budget_cap": 12000})
        trip.open_candidates()

        self.assertIs(trip.phase, TripPhase.CANDIDATES)
        self.assertEqual(trip.pending_member_ids, ())


class TripConfirmationTests(unittest.TestCase):
    member_ids = ("m01", "m02", "m03", "m04")
    fixed_time = datetime(2026, 11, 21, 5, 30, tzinfo=timezone.utc)

    def open_trip(self) -> TripState:
        trip = TripState(self.member_ids, clock=lambda: self.fixed_time)
        for member_id in self.member_ids:
            trip.submit_member(member_id, {"budget_cap": 8000})
        trip.open_candidates(
            [
                {"candidate_id": "c01", "status": "infeasible"},
                {"candidate_id": "c02", "status": "feasible"},
                {"candidate_id": "c03", "status": "feasible"},
                {"candidate_id": "c04", "status": "incomplete"},
            ]
        )
        return trip

    def test_start_requires_all_confirmations_and_records_audit(self) -> None:
        trip = self.open_trip()
        plan = trip.select_candidate("m01", "c02")
        self.assertEqual((plan.candidate_id, plan.version), ("c02", "v1"))
        self.assertIs(trip.phase, TripPhase.CONFIRMING)

        for member_id in ("m03", "m01", "m02"):
            self.assertTrue(trip.confirm_candidate(member_id, "c02", "v1"))
        self.assertEqual(trip.confirmed_member_ids, self.member_ids[:3])
        self.assertIsNone(trip.locked_plan)
        with self.assertRaisesRegex(RuntimeError, "m04"):
            trip.start_trip("m01", "c02", "v1")

        rejected_start = trip.events[-1]
        self.assertEqual(rejected_start.event, "start_trip")
        self.assertIs(rejected_start.from_phase, TripPhase.CONFIRMING)
        self.assertIs(rejected_start.to_phase, TripPhase.CONFIRMING)
        self.assertIn("m04", rejected_start.reason or "")

        self.assertTrue(trip.confirm_candidate("m04", "c02", "v1"))
        self.assertEqual(trip.locked_plan, plan)
        self.assertEqual(trip.confirmed_member_ids, self.member_ids)
        lock = trip.events[-1]
        self.assertEqual(
            (lock.event, lock.actor_id, lock.plan_version), ("lock_plan", "m04", "v1")
        )

        with self.assertRaises(RuntimeError):
            trip.start_trip("m02", "c02", "v1")
        trip.start_trip("m01", "c02", "v1")

        self.assertIs(trip.phase, TripPhase.EXECUTING)
        started = trip.events[-1]
        self.assertEqual(
            (started.event, started.actor_id, started.plan_version), ("start_trip", "m01", "v1")
        )
        self.assertEqual(
            (started.from_phase, started.to_phase), (TripPhase.CONFIRMING, TripPhase.EXECUTING)
        )
        self.assertIsNone(started.reason)
        self.assertTrue(all(event.at == self.fixed_time for event in trip.events))

        events = trip.events
        self.assertFalse(trip.confirm_candidate("m04", "c02", "v1"))
        self.assertEqual(trip.events, events)

    def test_duplicate_confirmation_does_not_add_an_event(self) -> None:
        trip = self.open_trip()
        plan = trip.select_candidate("m01", "c02")
        self.assertTrue(trip.confirm_candidate("m01", plan.candidate_id, plan.version))
        events = trip.events

        self.assertFalse(trip.confirm_candidate("m01", plan.candidate_id, plan.version))

        self.assertEqual(trip.confirmed_member_ids, ("m01",))
        self.assertEqual(trip.events, events)

    def test_reselecting_same_id_rejects_an_old_confirmation(self) -> None:
        trip = self.open_trip()
        old_plan = trip.select_candidate("m01", "c02")
        trip.confirm_candidate("m01", old_plan.candidate_id, old_plan.version)
        trip.return_to_collection("m01")

        self.assertIs(trip.phase, TripPhase.COLLECTING)
        self.assertEqual(trip.pending_member_ids, ())
        self.assertEqual(trip.candidate_results, ())
        self.assertEqual(trip.confirmed_member_ids, ())
        self.assertIsNone(trip.locked_plan)

        trip.open_candidates([{"candidate_id": "c02", "status": "feasible", "actual": 7800}])
        new_plan = trip.select_candidate("m01", "c02")
        self.assertEqual((new_plan.candidate_id, new_plan.version), ("c02", "v2"))

        with self.assertRaises(RuntimeError):
            trip.confirm_candidate("m02", old_plan.candidate_id, old_plan.version)
        self.assertEqual(trip.confirmed_member_ids, ())
        self.assertTrue(trip.confirm_candidate("m02", new_plan.candidate_id, new_plan.version))

    def test_switching_candidates_invalidates_the_locked_version(self) -> None:
        trip = self.open_trip()
        old_plan = trip.select_candidate("m01", "c02")
        for member_id in self.member_ids:
            trip.confirm_candidate(member_id, "c02", old_plan.version)
        self.assertEqual(trip.locked_plan, old_plan)

        # 执行前仍可改选。锁定和确认记录都只适用于被选中的那一版。
        new_plan = trip.select_candidate("m01", "c03")
        self.assertEqual((new_plan.candidate_id, new_plan.version), ("c03", "v2"))
        self.assertIsNone(trip.locked_plan)
        self.assertEqual(trip.confirmed_member_ids, ())
        with self.assertRaisesRegex(RuntimeError, "stale"):
            trip.start_trip("m01", "c02", old_plan.version)
        with self.assertRaisesRegex(RuntimeError, "stale"):
            trip.confirm_candidate("m02", "c02", old_plan.version)

    def test_only_organizer_can_select_a_feasible_candidate(self) -> None:
        trip = self.open_trip()
        self.assertEqual(
            tuple(result["status"] for result in trip.candidate_results),
            ("infeasible", "feasible", "feasible", "incomplete"),
        )

        for actor, candidate in (("m01", "c01"), ("m01", "c04"), ("m02", "c02")):
            with self.subTest(actor=actor, candidate=candidate):
                with self.assertRaises(RuntimeError):
                    trip.select_candidate(actor, candidate)
                self.assertIs(trip.phase, TripPhase.CANDIDATES)


class SharedTripChangeTests(unittest.TestCase):
    def setUp(self) -> None:
        fixture_path = Path(__file__).resolve().parents[1] / "fixtures" / "demo-trip.json"
        self.fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        self.rain = self.fixture["rain_event"]
        self.replacement = self.fixture["rain_replacement"]
        self.member_ids = tuple(member["member_id"] for member in self.fixture["members"])

    def publish(self, *, omit_budget_basis: bool = False) -> TripState:
        trip = TripState(self.member_ids)
        for member in self.fixture["members"]:
            submission = dict(member)
            if omit_budget_basis and member["member_id"] == "m01":
                submission.pop("budget_basis")
            trip.submit_member(member["member_id"], submission)
        trip.open_fixture_candidates(self.fixture)
        return trip

    def start(self) -> TripState:
        trip = self.publish()
        trip.select_candidate("m01", "c02")
        for member_id in self.member_ids:
            trip.confirm_candidate(member_id, "c02", "v1")
        trip.start_trip("m01", "c02", "v1")
        return trip

    def test_real_detector_gates_using_submitted_data(self) -> None:
        trip = self.publish()
        c01, c02, c03 = trip.candidate_results
        self.assertEqual((c01["status"], c02["status"], c03["status"]),
                         ("infeasible", "feasible", "feasible"))
        conflict = c01["reasons"][0]
        self.assertEqual((conflict["rule_id"], conflict["actual"], conflict["threshold"]),
                         ("R-BUD-01", 8100, 8000))
        with self.assertRaisesRegex(RuntimeError, "infeasible"):
            trip.select_candidate("m01", "c01")

        incomplete = self.publish(omit_budget_basis=True)
        self.assertIn({"member_id": "m01", "field": "budget_basis", "rule_id": "R-DATA-02"},
                      incomplete.candidate_results[1]["missing_fields"])
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            incomplete.select_candidate("m01", "c02")
        self.assertIs(incomplete.phase, TripPhase.CANDIDATES)

    def test_shared_detector_cannot_publish_for_a_partial_roster(self) -> None:
        trip = TripState(self.member_ids[:3])
        for member in self.fixture["members"][:3]:
            trip.submit_member(member["member_id"], member)
        with self.assertRaisesRegex(RuntimeError, "requires exactly"):
            trip.open_fixture_candidates(self.fixture)
        self.assertIs(trip.phase, TripPhase.COLLECTING)
        self.assertEqual(trip.candidate_results, ())

    def test_rain_marks_only_outdoor_activity_with_positive_overlap(self) -> None:
        trip = self.start()
        original = trip.current_itinerary
        earlier = deepcopy(self.rain)
        earlier["window"] = {"start": "2026-11-21T13:30:00+08:00",
                             "end": "2026-11-21T14:00:00+08:00"}
        # 雨窗覆盖交通，并恰好在户外节点开始时结束，不能算直接命中。
        no_hit = trip.preview_change("m01", "v1", earlier, self.replacement)
        self.assertIsNone(no_hit.preview_id)
        self.assertEqual(no_hit.impact.affected_node_ids, ())
        preview = trip.preview_change("m01", "v1", self.rain, self.replacement)
        self.assertIs(trip.phase, TripPhase.CHANGE_PENDING)
        self.assertEqual(preview.impact.affected_node_ids, ("c02-n02",))
        self.assertEqual(preview.impact.unchanged_node_ids, ("c02-n01", "c02-n03", "c02-n04"))
        self.assertEqual(preview.impact.rule_result["status"], "feasible")
        self.assertEqual(trip.current_itinerary, original)

    def test_cancel_keeps_original_and_invalidates_preview_id(self) -> None:
        trip = self.start()
        original = trip.current_itinerary
        canceled = trip.preview_change("m01", "v1", self.rain, self.replacement)
        trip.cancel_change("m01", canceled.preview_id, "v1")
        self.assertIs(trip.phase, TripPhase.EXECUTING)
        self.assertEqual(trip.current_itinerary, original)
        self.assertEqual(trip.confirmed_member_ids, self.member_ids)
        self.assertEqual(trip.events[-1].event, "cancel_change")
        self.assertEqual(trip.events[-1].base_version, "v1")

        fresh = trip.preview_change("m01", "v1", self.rain, self.replacement)
        with self.assertRaisesRegex(RuntimeError, "no longer active"):
            trip.apply_change("m01", canceled.preview_id, "v1")
        self.assertEqual(trip.pending_change.preview_id, fresh.preview_id)
        self.assertEqual(trip.locked_plan.version, "v1")

    def test_missing_or_over_budget_replacement_does_not_change_itinerary(self) -> None:
        trip = self.start()
        original = trip.current_itinerary
        missing = trip.preview_change("m01", "v1", self.rain)
        self.assertIsNone(missing.preview_id)
        self.assertEqual(missing.impact.affected_node_ids, ("c02-n02",))
        self.assertIn("人工调整", missing.impact.reason)

        costly = deepcopy(self.replacement)
        costly["cost_per_member"]["m01"] = 8100
        blocked = trip.preview_change("m01", "v1", self.rain, costly)
        self.assertIsNone(blocked.preview_id)
        self.assertEqual(blocked.impact.rule_result["status"], "infeasible")
        self.assertEqual(blocked.impact.rule_result["reasons"][0]["rule_id"], "R-BUD-01")
        self.assertIsNone(trip.pending_change)
        self.assertEqual(trip.locked_plan.version, "v1")
        self.assertEqual(trip.current_itinerary, original)

    def test_apply_only_changes_target_and_records_new_version(self) -> None:
        trip = self.start()
        before = trip.current_itinerary["nodes"]
        preview = trip.preview_change("m01", "v1", self.rain, self.replacement)
        with self.assertRaisesRegex(RuntimeError, "organizer"):
            trip.apply_change("m02", preview.preview_id, "v1")

        # 页面持有的是预览副本，后续编辑不能绕过已通过的复检。
        preview.impact.itinerary["nodes"][1]["node_id"] = "unexpected"
        plan = trip.apply_change("m01", preview.preview_id, "v1")
        after = trip.current_itinerary["nodes"]
        self.assertEqual((plan.candidate_id, plan.version), ("c02", "v2"))
        self.assertEqual(after[:1] + after[2:], before[:1] + before[2:])
        self.assertEqual(after[1]["node_id"], "c02-n02-r1")
        self.assertEqual(trip.confirmed_member_ids, ())
        applied = trip.events[-1]
        self.assertEqual((applied.event, applied.actor_id, applied.base_version, applied.plan_version),
                         ("apply_change", "m01", "v1", "v2"))
        self.assertEqual([entry.actor_id for entry in trip.events if entry.event == "confirm_candidate"],
                         list(self.member_ids))

        with self.assertRaisesRegex(RuntimeError, "stale"):
            trip.apply_change("m01", preview.preview_id, "v1")
        with self.assertRaisesRegex(RuntimeError, "stale"):
            trip.confirm_candidate("m01", "c02", "v1")
        self.assertEqual(trip.locked_plan.version, "v2")
        self.assertIs(trip.phase, TripPhase.EXECUTING)
