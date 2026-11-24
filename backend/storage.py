"""保存共享房间、成员偏好和可安全重试的请求结果。"""

from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
from collections.abc import Iterator
from contextlib import closing, contextmanager
from pathlib import Path
from uuid import uuid4

from algorithm.conflict_detector import REQUIRED_MEMBER_IDS

_CAPACITY = len(REQUIRED_MEMBER_IDS)
_ORGANIZER = REQUIRED_MEMBER_IDS[0]
_INVITE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
_SCHEMA = (
    """
    CREATE TABLE IF NOT EXISTS rooms (
        room_id TEXT PRIMARY KEY NOT NULL,
        invite_code TEXT NOT NULL UNIQUE,
        room_name TEXT NOT NULL,
        trip_date TEXT NOT NULL,
        timezone TEXT NOT NULL,
        phase TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS members (
        room_id TEXT NOT NULL REFERENCES rooms (room_id),
        member_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        preferences TEXT,
        PRIMARY KEY (room_id, member_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS request_replays (
        operation TEXT NOT NULL,
        key_hash TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        response TEXT NOT NULL,
        PRIMARY KEY (operation, key_hash)
    )
    """,
)


class StorageError(Exception):
    """由 HTTP 层转换为契约中的错误响应。"""

    def __init__(
        self, status_code: int, code: str, message: str, details: dict | None = None
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.details = details if details is not None else {}


def _canonical_json(value: dict) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _member(member_id: str, display_name: str) -> dict:
    return {
        "member_id": member_id,
        "display_name": display_name,
        "role": "organizer" if member_id == _ORGANIZER else "member",
    }


class RoomStore:
    """每个操作使用独立连接，确保线程之间不共享事务。"""

    def __init__(self, path: str | Path) -> None:
        if str(path) == ":memory:":
            raise ValueError("RoomStore requires a file-backed database.")
        self.path = Path(path).expanduser().resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._transaction(write=True) as connection:
            for statement in _SCHEMA:
                connection.execute(statement)

    @contextmanager
    def _transaction(self, *, write: bool = False) -> Iterator[sqlite3.Connection]:
        with closing(sqlite3.connect(self.path, timeout=5, isolation_level=None)) as connection:
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA foreign_keys = ON")
            try:
                # 写入先锁定名额或偏好记录所处的数据库，避免先读再争夺写锁。
                connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
                yield connection
                connection.commit()
            except sqlite3.OperationalError as exc:
                connection.rollback()
                code = getattr(exc, "sqlite_errorcode", 0) & 0xff
                if code in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
                    raise StorageError(503, "STORAGE_BUSY", "房间正在保存，请稍后重试。") from exc
                raise
            except BaseException:
                connection.rollback()
                raise

    @staticmethod
    def _replay(
        connection: sqlite3.Connection, operation: str, key_hash: str, request_hash: str
    ) -> dict | None:
        row = connection.execute(
            "SELECT request_hash, response FROM request_replays WHERE operation = ? AND key_hash = ?",
            (operation, key_hash),
        ).fetchone()
        if row is None:
            return None
        if row["request_hash"] != request_hash:
            raise StorageError(409, "IDEMPOTENCY_CONFLICT", "同一个请求键已用于另一份请求。")
        return json.loads(row["response"])

    @staticmethod
    def _remember(
        connection: sqlite3.Connection, operation: str, key_hash: str, request_hash: str,
        response: dict,
    ) -> None:
        # 重试需要原凭证，此响应随数据库留在团队受限目录。鉴权表仅保存凭证哈希。
        connection.execute(
            "INSERT INTO request_replays (operation, key_hash, request_hash, response) VALUES (?, ?, ?, ?)",
            (operation, key_hash, request_hash, _canonical_json(response)),
        )

    @staticmethod
    def _add_member(
        connection: sqlite3.Connection, room_id: str, member_id: str, display_name: str
    ) -> str:
        token = secrets.token_urlsafe(32)
        connection.execute(
            "INSERT INTO members (room_id, member_id, display_name, token_hash) VALUES (?, ?, ?, ?)",
            (room_id, member_id, display_name, _digest(token)),
        )
        return token

    @staticmethod
    def _invite_code(connection: sqlite3.Connection) -> str:
        while True:
            code = "".join(secrets.choice(_INVITE_ALPHABET) for _ in range(8))
            if connection.execute(
                "SELECT 1 FROM rooms WHERE invite_code = ?", (code,)
            ).fetchone() is None:
                return code

    @staticmethod
    def _authorize(
        connection: sqlite3.Connection, room_id: str, token: str
    ) -> tuple[sqlite3.Row, str]:
        member = connection.execute(
            "SELECT room_id, member_id FROM members WHERE token_hash = ?", (_digest(token),)
        ).fetchone()
        if member is None:
            raise StorageError(401, "MEMBER_TOKEN_INVALID", "成员凭证无效，请重新确认本机身份。")
        room = connection.execute(
            "SELECT room_id, room_name, trip_date, timezone, phase FROM rooms WHERE room_id = ?",
            (room_id,),
        ).fetchone()
        if room is None:
            raise StorageError(404, "ROOM_NOT_FOUND", "找不到该房间，请刷新后重试。")
        if member["room_id"] != room_id:
            raise StorageError(403, "FORBIDDEN", "此成员凭证不能访问该房间。")
        return room, member["member_id"]

    @staticmethod
    def _require_collecting(room: sqlite3.Row) -> None:
        if room["phase"] != "collecting":
            raise StorageError(
                409, "INVALID_PHASE", "当前阶段不能加入房间或提交偏好。",
                {"phase": room["phase"]},
            )

    def create_room(self, payload: dict, idempotency_key: str) -> dict:
        key_hash = _digest(idempotency_key)
        request_hash = _digest(_canonical_json(payload))
        with self._transaction(write=True) as connection:
            replay = self._replay(connection, "create", key_hash, request_hash)
            if replay is not None:
                return replay
            room_id = f"r-{uuid4().hex}"
            invite_code = self._invite_code(connection)
            connection.execute(
                """
                INSERT INTO rooms (room_id, invite_code, room_name, trip_date, timezone, phase)
                VALUES (?, ?, ?, ?, ?, 'collecting')
                """,
                (room_id, invite_code, payload["room_name"], payload["trip_date"], payload["timezone"]),
            )
            name = payload["display_name"]
            token = self._add_member(connection, room_id, _ORGANIZER, name)
            response = {
                "room_id": room_id,
                "invite_code": invite_code,
                "phase": "collecting",
                "capacity": _CAPACITY,
                "member": _member(_ORGANIZER, name),
                "member_token": token,
            }
            self._remember(connection, "create", key_hash, request_hash, response)
            return response

    def join_room(self, payload: dict, idempotency_key: str) -> dict:
        payload = {**payload, "invite_code": payload["invite_code"].strip().upper()}
        key_hash = _digest(idempotency_key)
        request_hash = _digest(_canonical_json(payload))
        with self._transaction(write=True) as connection:
            replay = self._replay(connection, "join", key_hash, request_hash)
            if replay is not None:
                return replay
            room = connection.execute(
                "SELECT room_id, phase FROM rooms WHERE invite_code = ?", (payload["invite_code"],)
            ).fetchone()
            if room is None:
                raise StorageError(404, "INVITE_NOT_FOUND", "邀请码无效，请检查后重试。")
            self._require_collecting(room)
            room_id = room["room_id"]
            reserved = {
                member["member_id"] for member in connection.execute(
                    "SELECT member_id FROM members WHERE room_id = ?", (room_id,)
                )
            }
            member_id = next((member for member in REQUIRED_MEMBER_IDS if member not in reserved), None)
            if member_id is None:
                raise StorageError(
                    409, "ROOM_FULL", "房间人数已满。",
                    {"member_count": len(reserved), "capacity": _CAPACITY},
                )
            name = payload["display_name"]
            token = self._add_member(connection, room_id, member_id, name)
            response = {
                "room_id": room_id,
                "phase": room["phase"],
                "member": _member(member_id, name),
                "member_token": token,
            }
            self._remember(connection, "join", key_hash, request_hash, response)
            return response

    def save_preferences(self, room_id: str, token: str, payload: dict) -> dict:
        with self._transaction(write=True) as connection:
            room, member_id = self._authorize(connection, room_id, token)
            self._require_collecting(room)
            connection.execute(
                "UPDATE members SET preferences = ? WHERE room_id = ? AND member_id = ?",
                (_canonical_json(payload), room_id, member_id),
            )
            count = connection.execute(
                "SELECT COUNT(*) FROM members WHERE room_id = ? AND preferences IS NOT NULL",
                (room_id,),
            ).fetchone()[0]
            return {
                "room_id": room_id,
                "member_id": member_id,
                "submission_status": "submitted",
                "submission_progress": {"submitted_count": count, "required_count": _CAPACITY},
            }

    def get_snapshot(self, room_id: str, token: str) -> dict:
        with self._transaction() as connection:
            room, member_id = self._authorize(connection, room_id, token)
            rows = connection.execute(
                """
                SELECT member_id, display_name, preferences FROM members
                WHERE room_id = ? ORDER BY member_id
                """,
                (room_id,),
            )
            members = [
                {
                    **_member(row["member_id"], row["display_name"]),
                    "preferences": json.loads(row["preferences"]) if row["preferences"] is not None else None,
                }
                for row in rows
            ]
            return {
                **dict(room),
                "capacity": _CAPACITY,
                "organizer_member_id": _ORGANIZER,
                "viewer_member_id": member_id,
                "members": members,
            }
