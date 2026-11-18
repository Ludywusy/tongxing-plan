"""分析已确认行程中的模拟降雨；这里只生成建议，由状态机决定是否应用。"""

from copy import deepcopy
from dataclasses import dataclass

from algorithm.conflict_detector import detect_resolved, parse_time, window_from_nodes


@dataclass(frozen=True)
class ChangeImpact:
    rain_event: dict
    affected_node_ids: tuple[str, ...]
    unchanged_node_ids: tuple[str, ...]
    replacement: dict | None
    reason: str
    rule_result: dict | None = None
    itinerary: dict | None = None


def _time_window(entry: dict):
    start, end = parse_time(entry.get("start")), parse_time(entry.get("end"))
    if start >= end:
        raise ValueError("The start time must precede the end time.")
    return start, end


def analyze_rain(
    itinerary: dict, rain_event: dict, fixture: dict, replacement: dict | None = None
) -> ChangeImpact:
    """匹配与雨窗有正时长交集的户外活动，复检替代后的完整行程。"""
    source = rain_event.get("source", {})
    if (
        rain_event.get("type") != "rain"
        or not rain_event.get("event_id")
        or source.get("type") != "simulated"
        or not source.get("note")
    ):
        raise ValueError("This demo requires a simulated rain event with an ID and a source.")
    parse_time(source.get("retrieved_at"))
    rain_start, rain_end = _time_window(rain_event.get("window", {}))
    nodes = itinerary["nodes"]
    affected, unchanged = [], []

    for node in nodes:
        start, end = _time_window(node)
        if node["kind"] == "activity" and not isinstance(node.get("indoor"), bool):
            raise ValueError(f"Activity {node['node_id']} needs an indoor flag.")
        # 只计算明确标成户外的活动；相接的端点、室内活动和交通不直接命中。
        hit = (
            node["kind"] == "activity"
            and node.get("indoor") is False
            and max(start, rain_start) < min(end, rain_end)
        )
        (affected if hit else unchanged).append(node["node_id"])

    def result(reason: str, *, proposed=None, checked=None, updated=None) -> ChangeImpact:
        return ChangeImpact(
            deepcopy(rain_event), tuple(affected), tuple(unchanged), deepcopy(proposed),
            reason, deepcopy(checked), updated,
        )

    if not affected:
        return result("雨窗未与任何户外活动重叠，当前行程不变。")

    reason = f"{', '.join(affected)} 是与模拟降雨时间窗重叠的户外活动。"
    if len(affected) != 1 or not replacement or replacement.get("replaces") != affected[0]:
        return result(reason + "没有可覆盖受影响节点的固定室内替代，请人工调整。")

    new_node = replacement.get("node", {})
    new_id = new_node.get("node_id")
    if (
        new_node.get("kind") != "activity"
        or new_node.get("indoor") is not True
        or not isinstance(new_id, str)
        or not new_id.strip()
        or new_id in affected + unchanged
    ):
        return result(reason + "替代必须是具有独立 ID 的室内活动，请人工调整。")

    updated = deepcopy(itinerary)
    updated["nodes"] = [
        deepcopy(new_node) if node["node_id"] == affected[0] else deepcopy(node)
        for node in nodes
    ]
    try:
        windows = [_time_window(node) for node in updated["nodes"]]
    except ValueError:
        return result(reason + "替代节点的时间格式或顺序不合法，请人工调整。")
    if any(left[1] > right[0] for left, right in zip(windows, windows[1:])):
        return result(reason + "替代与其他节点时间冲突，请人工调整。")

    # 必须提交替代后的整程时间和逐人费用，避免拿原来的费用通过预算检查。
    updated["window"] = window_from_nodes(updated["nodes"])
    updated["cost_per_member"] = deepcopy(replacement.get("cost_per_member"))
    checked = detect_resolved(fixture, updated)
    if checked["status"] != "feasible":
        return result(reason + "替代未通过整程硬约束复检，请人工调整。",
                      proposed=replacement, checked=checked)
    return result(reason + "室内替代已通过整程硬约束复检。",
                  proposed=replacement, checked=checked, updated=updated)
