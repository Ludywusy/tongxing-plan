"""将已提交偏好转成检测器的成员输入，并计算房间汇总。"""

from zoneinfo import ZoneInfo

from algorithm.conflict_detector import common_windows
from core.transport_codes import normalize_transports


def project_members(members: list[dict]) -> list[dict]:
    """将房间成员与偏好投影到 `fixture['members']`，仅纳入已提交成员。"""
    return [
        {**member["preferences"], "member_id": member["member_id"],
         "display_name": member["display_name"]}
        for member in members
        if member["preferences"] is not None
    ]


def summarize_preferences(members: list[dict], timezone: str) -> dict:
    """同一快照内已收齐的四份偏好，用 B 的时间窗规则计算汇总。"""
    room_zone = ZoneInfo(timezone)
    shared_windows = common_windows({"members": members})
    shared_transport = set(normalize_transports(members[0]["allowed_transport"]))
    for member in members[1:]:
        shared_transport.intersection_update(normalize_transports(member["allowed_transport"]))

    return {
        "common_windows": [
            {"start": start.astimezone(room_zone).isoformat(),
             "end": end.astimezone(room_zone).isoformat()}
            for start, end in shared_windows
        ],
        # 按发起人的填写顺序展示共同方式，同时去重。
        "common_allowed_transport": [
            mode for mode in normalize_transports(members[0]["allowed_transport"])
            if mode in shared_transport
        ],
        "min_budget_cap": min(member["budget_cap"] for member in members),
    }
