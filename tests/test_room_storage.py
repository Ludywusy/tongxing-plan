import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Barrier

from backend.storage import RoomStore, StorageError


class RoomStorageTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(TemporaryDirectory())
        self.db_path = Path(directory) / "rooms.sqlite3"
        self.store = RoomStore(self.db_path)
        self.room = self.store.create_room({
            "room_name": "并发联调",
            "display_name": "甲",
            "trip_date": "2026-11-21",
            "timezone": "Asia/Shanghai",
        }, "create-room")

    def join(self, store, display_name, key):
        payload = {"invite_code": self.room["invite_code"], "display_name": display_name}
        return store.join_room(payload, key)

    def current_members(self):
        return RoomStore(self.db_path).get_snapshot(
            self.room["room_id"], self.room["member_token"]
        )["members"]

    def test_two_writers_competing_for_last_slot_cannot_overfill_room(self):
        self.join(self.store, "乙", "join-2")
        self.join(self.store, "丙", "join-3")
        second_writer = RoomStore(self.db_path)
        start = Barrier(2, timeout=10)

        def try_join(store, name, key):
            start.wait()
            try:
                return self.join(store, name, key)
            except StorageError as error:
                return error

        with ThreadPoolExecutor(max_workers=2) as pool:
            attempts = [pool.submit(try_join, self.store, "丁", "join-4"),
                        pool.submit(try_join, second_writer, "戊", "join-5")]
            results = [attempt.result(timeout=15) for attempt in attempts]

        success = [r for r in results if isinstance(r, dict)]
        failure = [r for r in results if isinstance(r, StorageError)]
        self.assertEqual(len(success), 1)
        self.assertEqual(success[0]["member"]["member_id"], "m04")
        self.assertEqual([(e.status_code, e.code) for e in failure], [(409, "ROOM_FULL")])
        self.assertEqual([m["member_id"] for m in self.current_members()], ["m01", "m02", "m03", "m04"])

    def test_concurrent_duplicate_join_consumes_one_slot(self):
        second_writer = RoomStore(self.db_path)
        start = Barrier(2, timeout=10)

        def repeat_join(store):
            start.wait()
            return self.join(store, "乙", "same-phone-retry")

        with ThreadPoolExecutor(max_workers=2) as pool:
            attempts = [pool.submit(repeat_join, store) for store in (self.store, second_writer)]
            results = [attempt.result(timeout=15) for attempt in attempts]

        self.assertEqual(results[0], results[1])
        self.assertEqual(results[0]["member"]["member_id"], "m02")
        self.assertEqual([m["member_id"] for m in self.current_members()], ["m01", "m02"])

    def test_concurrent_writes_to_four_members_persist_four_distinct_forms(self):
        members = [self.room] + [
            self.join(self.store, name, f"join-{idx}") for idx, name in enumerate(("乙", "丙", "丁"), start=2)
        ]
        stores = [RoomStore(self.db_path) for _ in members]
        caps = (8000, 8700, 9100, 7800)
        start = Barrier(4, timeout=10)

        def submit(store, member, cap):
            start.wait()
            return store.save_preferences(self.room["room_id"], member["member_token"], {
                "available_windows": [
                    {"start": "2026-11-21T13:30:00+08:00", "end": "2026-11-21T17:00:00+08:00"},
                ],
                "budget_cap": cap,
                "budget_basis": {"includes_transport": True, "scope": "per_person", "share_rule": None},
                "allowed_transport": ["metro", "walk"],
                "taboo_tags": [],
            })

        with ThreadPoolExecutor(max_workers=4) as pool:
            attempts = [pool.submit(submit, store, member, cap) for store, member, cap in zip(stores, members, caps)]
            results = [attempt.result(timeout=15) for attempt in attempts]

        self.assertEqual(sorted(result["submission_progress"]["submitted_count"] for result in results), [1, 2, 3, 4])
        persisted = {m["member_id"]: m["preferences"]["budget_cap"] for m in self.current_members()}
        self.assertEqual(persisted, {member["member"]["member_id"]: cap for member, cap in zip(members, caps)})
