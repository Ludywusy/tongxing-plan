import unittest
from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory

from fastapi.testclient import TestClient

from backend.main import create_app


BASE = "/api/v0.1/rooms"
ROOM = {
    "room_name": "兰州半日游",
    "display_name": "甲",
    "trip_date": "2026-11-21",
    "timezone": "Asia/Shanghai",
}


def member_headers(member):
    return {"Authorization": f"Bearer {member['member_token']}"}


def preferences(cap=8000, *, start="13:30", end="17:00", transport=None):
    return {
        "available_windows": [
            {"start": f"2026-11-21T{start}:00+08:00", "end": f"2026-11-21T{end}:00+08:00"},
        ],
        "budget_cap": cap,
        "budget_basis": {"includes_transport": True, "scope": "per_person", "share_rule": None},
        "allowed_transport": ["metro", "walk"] if transport is None else transport,
        "taboo_tags": [],
    }


class RoomsApiTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(TemporaryDirectory())
        self.db_path = Path(directory) / "rooms.sqlite3"
        self.client = self.enterContext(TestClient(create_app(self.db_path)))

    def assert_error(self, response, status, code):
        self.assertEqual(response.status_code, status, response.text)
        body = response.json()
        self.assertEqual(set(body), {"error"})
        self.assertEqual(body["error"]["code"], code)
        self.assertTrue(body["error"]["message"])
        self.assertIsInstance(body["error"]["details"], dict)
        return body["error"]["details"]

    def create_room(self, key="create-first", **changes):
        response = self.client.post(BASE, json={**ROOM, **changes}, headers={"Idempotency-Key": key})
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def join(self, room, name, key):
        return self.client.post(
            f"{BASE}/join",
            json={"invite_code": room["invite_code"], "display_name": name},
            headers={"Idempotency-Key": key},
        )

    def four_members(self):
        room = self.create_room()
        members = [room]
        for idx, name in enumerate(("乙", "丙", "丁"), start=2):
            response = self.join(room, name, f"join-{idx}")
            self.assertEqual(response.status_code, 201, response.text)
            members.append(response.json())
        self.assertEqual({m["room_id"] for m in members}, {room["room_id"]})
        self.assertEqual([m["member"]["member_id"] for m in members], ["m01", "m02", "m03", "m04"])
        self.assertEqual(len({m["member_token"] for m in members}), 4)
        return members

    def snapshot(self, member):
        response = self.client.get(f"{BASE}/{member['room_id']}", headers=member_headers(member))
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def submit(self, member, value):
        return self.client.put(
            f"{BASE}/{member['room_id']}/preferences/me", json=value, headers=member_headers(member)
        )

    def test_room_progress_and_summary_are_shared_and_forms_stay_private(self):
        members = self.four_members()
        self.assertEqual(members[0]["member"]["role"], "organizer")
        self.assertTrue(all(member["member"]["role"] == "member" for member in members[1:]))
        self.assertEqual(members[0]["capacity"], 4)
        organizer_form = preferences(9900, start="13:00", end="17:30")
        # Same-member adjacent windows are merged across equivalent offset representations.
        organizer_form["available_windows"] = [
            {"start": "2026-11-21T13:00:00+08:00", "end": "2026-11-21T06:15:00Z"},
            {"start": "2026-11-21T14:15:00+08:00", "end": "2026-11-21T17:30:00+08:00"},
        ]
        forms = [organizer_form, preferences(8000), preferences(9900), preferences(9700)]
        for count, (member, form) in enumerate(zip(members, forms), start=1):
            response = self.submit(member, form)
            self.assertEqual(response.status_code, 200, response.text)
            progress = {"submitted_count": count, "required_count": 4}
            self.assertEqual(response.json(), {
                "room_id": member["room_id"],
                "member_id": member["member"]["member_id"],
                "submission_status": "submitted",
                "submission_progress": progress,
            })
            snapshot = self.snapshot(members[count % 4])
            self.assertEqual(snapshot["submission_progress"], progress)
            if count < 4:
                self.assertIsNone(snapshot["summary"])

        expected_summary = {
            "common_windows": [
                {"start": "2026-11-21T13:30:00+08:00", "end": "2026-11-21T17:00:00+08:00"},
            ],
            "common_allowed_transport": ["metro", "walk"],
            "min_budget_cap": 8000,
        }
        reference = None
        for member in members:
            snapshot = self.snapshot(member)
            self.assertEqual(snapshot.pop("viewer_member_id"), member["member"]["member_id"])
            self.assertEqual(snapshot["phase"], "collecting")
            self.assertEqual(snapshot["summary"], expected_summary)
            self.assertEqual(snapshot["candidates"], [])
            for field in ("selected_plan", "locked_plan", "active_plan", "confirmation_progress", "pending_change"):
                self.assertIsNone(snapshot[field])
            self.assertNotIn("member_token", snapshot)
            self.assertTrue(all(set(row) == {"member_id", "display_name", "role", "submission_status"}
                                for row in snapshot["members"]))
            if reference is None:
                reference = snapshot
            self.assertEqual(snapshot, reference)

        # An edit updates only the caller's contribution. A disjoint time/transport
        # yields an empty intersection, with all four submissions still counted.
        response = self.submit(members[1], preferences(8700, start="17:00", end="18:00", transport=["bus"]))
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["submission_progress"]["submitted_count"], 4)
        self.assertEqual(self.snapshot(members[3])["summary"], {
            "common_windows": [], "common_allowed_transport": [], "min_budget_cap": 8700,
        })

    def test_create_and_join_replay_return_original_identity_after_restart(self):
        with TestClient(create_app(self.db_path)) as first_app:
            create = first_app.post(BASE, json=ROOM, headers={"Idempotency-Key": "phone-a-create"})
            self.assertEqual(create.status_code, 201, create.text)
            room = create.json()
            join_body = {"invite_code": room["invite_code"], "display_name": "乙"}
            join = first_app.post(f"{BASE}/join", json=join_body, headers={"Idempotency-Key": "phone-b-join"})
            self.assertEqual(join.status_code, 201, join.text)
            joined = join.json()
            write = first_app.put(f"{BASE}/{room['room_id']}/preferences/me", json=preferences(),
                                  headers=member_headers(joined))
            self.assertEqual(write.status_code, 200, write.text)

        # Drop the first app and create a fresh application pointing to the same file.
        with TestClient(create_app(self.db_path)) as second_app:
            replay_create = second_app.post(BASE, json=dict(reversed(ROOM.items())),
                                            headers={"Idempotency-Key": "phone-a-create"})
            self.assertEqual((replay_create.status_code, replay_create.json()), (201, room))
            replay_join = second_app.post(f"{BASE}/join", json=join_body,
                                          headers={"Idempotency-Key": "phone-b-join"})
            self.assertEqual((replay_join.status_code, replay_join.json()), (201, joined))
            conflict = second_app.post(f"{BASE}/join", json={**join_body, "display_name": "改名"},
                                        headers={"Idempotency-Key": "phone-b-join"})
            self.assert_error(conflict, 409, "IDEMPOTENCY_CONFLICT")
            conflict = second_app.post(BASE, json={**ROOM, "room_name": "另一个行程"},
                                        headers={"Idempotency-Key": "phone-a-create"})
            self.assert_error(conflict, 409, "IDEMPOTENCY_CONFLICT")
            snapshot = second_app.get(f"{BASE}/{room['room_id']}", headers=member_headers(joined))
            self.assertEqual(snapshot.status_code, 200, snapshot.text)
            self.assertEqual(snapshot.json()["submission_progress"], {"submitted_count": 1, "required_count": 4})
            self.assertEqual([m["submission_status"] for m in snapshot.json()["members"]], ["pending", "submitted"])

    def test_bad_credentials_cross_room_and_spoofed_member_cannot_access_or_write(self):
        room = self.create_room()
        other = self.create_room("create-second", room_name="另一间房")
        url = f"{BASE}/{room['room_id']}"
        self.assert_error(self.client.get(url), 401, "MEMBER_TOKEN_INVALID")
        self.assert_error(self.client.get(url, headers={"Authorization": "Bearer incorrect"}),
                          401, "MEMBER_TOKEN_INVALID")
        self.assert_error(self.client.get(url, headers=member_headers(other)), 403, "FORBIDDEN")
        self.assert_error(self.client.put(f"{url}/preferences/me", json=preferences(), headers=member_headers(other)),
                          403, "FORBIDDEN")
        self.assert_error(self.client.get(f"{BASE}/unknown-room", headers=member_headers(other)),
                          404, "ROOM_NOT_FOUND")
        for key, value in (("member_id", "m02"), ("actor_id", "m02"), ("role", "organizer")):
            with self.subTest(key=key):
                details = self.assert_error(self.submit(room, {**preferences(), key: value}), 422, "INVALID_INPUT")
                self.assertIn(key, [field["field"] for field in details["fields"]])
        snap = self.snapshot(room)
        self.assertEqual(snap["submission_progress"]["submitted_count"], 0)
        self.assertEqual(len(snap["members"]), 1)
        self.assertEqual(snap["members"][0]["submission_status"], "pending")

    def test_invalid_preferences_are_reported_by_field_and_keep_last_valid_save(self):
        members = self.four_members()
        good = preferences()
        for member in members:
            response = self.submit(member, good)
            self.assertEqual(response.status_code, 200, response.text)
        summary = self.snapshot(members[1])["summary"]
        cases = [
            ("boolean amount", "budget_cap", {"budget_cap": False}),
            ("fractional amount", "budget_cap", {"budget_cap": 12.5}),
            ("numeric text", "budget_cap", {"budget_cap": "5000"}),
            ("negative amount", "budget_cap", {"budget_cap": -1}),
            ("missing offset", "available_windows", {"available_windows": [
                {"start": "2026-11-21T12:00:00", "end": "2026-11-21T18:00:00+08:00"}]}),
            ("reversed window", "available_windows", {"available_windows": [
                {"start": "2026-11-21T18:00:00+08:00", "end": "2026-11-21T12:00:00+08:00"}]}),
            ("empty windows", "available_windows", {"available_windows": []}),
            ("empty transport", "allowed_transport", {"allowed_transport": []}),
            ("placeholder transport", "allowed_transport", {"allowed_transport": ["none"]}),
            ("group budget", "budget_basis", {"budget_basis": {"includes_transport": True, "scope": "per_group"}}),
            ("transport excluded", "budget_basis", {"budget_basis": {"includes_transport": False, "scope": "per_person"}}),
        ]
        for desc, field in (("unspecified taboos", "taboo_tags"), ("missing budget basis", "budget_basis")):
            cases.append((desc, field, None))
        for name, field, update in cases:
            with self.subTest(name=name):
                malformed = deepcopy(good)
                if update is None:
                    malformed.pop(field)
                else:
                    malformed.update(update)
                details = self.assert_error(self.submit(members[0], malformed), 422, "INVALID_INPUT")
                self.assertTrue(any(e["field"] == field or e["field"].startswith(f"{field}.")
                                    for e in details["fields"]), details)
        snap = self.snapshot(members[1])
        self.assertEqual(snap["summary"], summary)
        self.assertEqual(snap["submission_progress"]["submitted_count"], 4)

    def test_admission_requires_key_and_rejects_unknown_invite_or_fifth_member(self):
        self.assert_error(self.client.post(BASE, json=ROOM), 422, "INVALID_INPUT")
        missing = self.client.post(f"{BASE}/join", json={"invite_code": "NOPE33", "display_name": "乙"},
                                   headers={"Idempotency-Key": "unknown-invite"})
        self.assert_error(missing, 404, "INVITE_NOT_FOUND")
        room = self.four_members()[0]
        self.assert_error(self.join(room, "第五人", "fifth-member"), 409, "ROOM_FULL")
        self.assertEqual(len(self.snapshot(room)["members"]), 4)
