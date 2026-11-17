import unittest
from datetime import datetime, timezone

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
