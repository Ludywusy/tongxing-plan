# -*- coding: utf-8 -*-
"""硬约束检测器（本周唯一判定入口）。

导入与签名
----------
    from algorithm.conflict_detector import detect, detect_trip, detect_resolved, detect_all

    detect(fixture, candidate_id)                      # 固定候选
    detect_trip(fixture, base_candidate_id, overrides)  # 便捷：自己展开 overrides 再判
    detect_resolved(fixture, trip)                      # A 传入展开后的整条行程再判
    detect_all(fixture)                                 # 整池判定：三张卡 + 全失败提示

    fixture : dict   fixtures/demo-trip.json 的内容（四人约束 + 候选池）
    trip    : dict   {"candidate_id", "window", "cost_per_member", "nodes"}
    overrides : list [{"replaces": "c02-n02", "node": {...}, "reason": "..."}]
    返回     : dict  {"candidate_id", "fixture_version", "input_fingerprint",
                      "status", "reasons", "missing_fields"}

对外契约（改动前先读这一段）
----------
    所有返回值都是**纯 dict**，status / rule_id 一律是普通字符串，可直接 json.dumps。
    内部用 Status 枚举、TypedDict 和类型注解约束写法（与 core/trip_state.py 一致），
    但边界上一律输出 .value 和字典，保持 docs/api-contract.md 第 4 节「保留原始六字段」。
    不要把返回值换成 dataclass / Enum 实例，那会破坏 A、C 已回签的 JSON 契约。

时间约定
--------
所有时间（成员可用窗、候选全程、**节点**）一律为带偏移的 ISO 8601：
    2026-11-21T13:30:00+08:00
不带偏移视为格式非法，判 incomplete，不做本地时区猜测。
契约约定 Asia/Shanghai（+08:00）；检测器按绝对时刻比较，不额外拒绝其它合法偏移。

可用窗规则（依据任务书「检测器执行规格」第 2 条）
----------
* 同一成员内部：重叠**或相邻**的区间取并集合并。
  相邻 = 前一段 end 等于后一段 start。要留返校/赶路时间，就把那段空档写进可用窗
  （例如 13:30–15:00 与 15:30–18:00），不要靠「相邻不合并」来表达。
* 不同成员之间：求交集时只认正时长，端点相碰（15:00–15:00）不算共同可用时间。
* 候选全程必须完整落入**某一段**共同可用窗。

判定顺序写死（不许交换）
------------------------
    1. 完整性检查（R-DATA-01 / R-DATA-02）── 缺则立即返回 incomplete
    2. 逐条硬约束，全部收集原因，不早停
    3. 任一违反 -> infeasible；全部通过 -> feasible
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping, Sequence
from copy import deepcopy
from datetime import datetime
from decimal import Decimal
from enum import Enum
from typing import Any, TypedDict
from core.transport_codes import normalize_transport, normalize_transports

# ---------------------------------------------------------------- 公共常量与类型


class Status(str, Enum):
    """三态。对外一律输出 .value，绝不把枚举实例塞进返回值。"""

    FEASIBLE = "feasible"
    INFEASIBLE = "infeasible"
    INCOMPLETE = "incomplete"


REQUIRED_MEMBER_IDS: tuple[str, ...] = ("m01", "m02", "m03", "m04")

# 规则 ID 集中定义，不再让字符串散落在各个分支里。
R_DATA_01 = "R-DATA-01"
R_DATA_02 = "R-DATA-02"
R_TIME_01 = "R-TIME-01"
R_TIME_02 = "R-TIME-02"
R_BUD_01 = "R-BUD-01"
R_TRANS_01 = "R-TRANS-01"
R_TABOO_01 = "R-TABOO-01"

# 规则 -> 成员「本人声明的输入」字段。只允许提示调整这些，绝不碰候选侧的数据
# （费用 / 时段 / 交通方式 / 地点标签）：改那些等于系统替用户造新方案，越过产品止损线。
RELAXABLE_FIELD_BY_RULE: dict[str, str] = {
    R_BUD_01: "budget_cap",
    R_TIME_01: "available_windows",
    R_TIME_02: "available_windows",
    R_TRANS_01: "allowed_transport",
    R_TABOO_01: "taboo_tags",
}

Fixture = dict[str, Any]
Trip = dict[str, Any]
Node = dict[str, Any]
Window = tuple[datetime, datetime]


class MissingField(TypedDict):
    member_id: str | None
    field: str
    rule_id: str


class _ReasonBase(TypedDict):
    rule_id: str
    member_ids: list[str]
    field: str
    message: str


class Reason(_ReasonBase, total=False):
    """actual / threshold 只有部分规则带，金额是整数分、时间是 ISO 字符串。"""

    actual: int | str
    threshold: int | str


class DetectionResult(TypedDict):
    candidate_id: str | None
    fixture_version: str
    input_fingerprint: str
    status: str
    reasons: list[Reason]
    missing_fields: list[MissingField]


class RelaxationHint(TypedDict):
    member_id: str
    field: str
    current_value: Any
    rule_ids: list[str]
    blocked_candidates: list[str]
    action: str
    system_auto_change: bool


class PendingField(TypedDict):
    candidate_id: str | None
    member_id: str | None
    field: str
    rule_id: str


class PoolResult(TypedDict):
    fixture_version: str
    input_fingerprint: str
    candidate_ids: list[str]
    candidates: list[DetectionResult]
    feasible_candidates: list[str]
    all_failed: bool
    pending_fields: list[PendingField]
    relaxation_hints: list[RelaxationHint]


__all__ = [
    "Status", "REQUIRED_MEMBER_IDS", "RELAXABLE_FIELD_BY_RULE",
    "fingerprint", "parse_time", "check_completeness", "merge_windows", "intersect",
    "common_windows", "expand_nodes", "window_from_nodes", "trip_from_candidate",
    "detect", "detect_trip", "detect_resolved", "detect_all", "relaxation_hints",
]


# ---------------------------------------------------------------- 基础工具


def _canon(payload: Any) -> str:
    # default=str 是防御性兜底：行程层传入非 JSON 类型（例如误把 datetime 塞进替代
    # 节点）时，指纹计算不能先崩掉；正常输入全为字符串/数字，不会触发 default。
    return json.dumps(payload, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":"), default=str)


def fingerprint(payload: Any) -> str:
    """规范化 JSON 的 sha256 前 8 位，用于自证「同一输入」。"""
    return hashlib.sha256(_canon(payload).encode("utf-8")).hexdigest()[:8]


def parse_time(s: Any) -> datetime:
    """解析带偏移的 ISO 8601；不带偏移抛 ValueError（不猜时区）。"""
    if not isinstance(s, str):
        raise ValueError("not a string")
    dt = datetime.fromisoformat(s)
    if dt.utcoffset() is None:
        raise ValueError("missing UTC offset")
    return dt


def _fmt_money(cents: int) -> str:
    """整数分 -> 展示文案；整除仍是「81 元」，有零头保留精度（80.5 元）。"""
    yuan = Decimal(cents) / Decimal(100)
    return f"{format(yuan, 'f')} 元"


def _candidate_index(fixture: Fixture) -> dict[str, Node]:
    """按 candidate_id 建索引；未知 ID 统一在这里拦下，不抛裸 KeyError。"""
    return {c["candidate_id"]: c for c in fixture["candidates"]}


def _make_result(
    fixture: Fixture,
    trip: Trip,
    fp: str,
    status: Status,
    reasons: list[Reason],
    missing: list[MissingField],
) -> DetectionResult:
    """唯一的出口构造器：保证六字段齐全、status 是普通字符串。"""
    return {
        "candidate_id": trip.get("candidate_id"),
        "fixture_version": fixture["fixture_version"],
        "input_fingerprint": fp,
        "status": status.value,
        "reasons": reasons,
        "missing_fields": missing,
    }


# ---------------------------------------------------------------- 完整性检查


def _check_window_list(wins: Any) -> bool:
    if not isinstance(wins, list) or not wins:
        return False
    for w in wins:
        try:
            if not parse_time(w["start"]) < parse_time(w["end"]):
                return False
        except (KeyError, TypeError, ValueError):
            return False
    return True


def check_completeness(fixture: Fixture, trip: Trip) -> list[MissingField]:
    """缺字段、格式非法、口径未定 -> missing_fields；此时不判可行也不判不可行。

    与团队 main 1.1 对齐：禁忌必须显式声明、节点 ID 唯一、节点不得越出全程窗。
    这三项是 PR #1 带进来的规则，不能因为本地重构被悄悄退回去。
    """
    missing: list[MissingField] = []
    for m in fixture["members"]:
        mid = m.get("member_id")

        if not _check_window_list(m.get("available_windows")):
            missing.append({"member_id": mid, "field": "available_windows", "rule_id": R_DATA_01})

        cap = m.get("budget_cap")
        if isinstance(cap, bool) or not isinstance(cap, int) or cap < 0:
            missing.append({"member_id": mid, "field": "budget_cap", "rule_id": R_DATA_01})

        transport = m.get("allowed_transport")
        if not isinstance(transport, list) or not transport or any(
            not isinstance(mode, str) or not mode.strip() for mode in transport
        ):
            missing.append({"member_id": mid, "field": "allowed_transport", "rule_id": R_DATA_01})

        # [] 表示本人明确写了「没有禁忌」；不填或格式不对都得先补，不能默认成空集。
        taboo_tags = m.get("taboo_tags")
        if not isinstance(taboo_tags, list) or any(
            not isinstance(tag, str) or not tag.strip() for tag in taboo_tags
        ):
            missing.append({"member_id": mid, "field": "taboo_tags", "rule_id": R_DATA_01})

        # 口径未定：预算必须声明含不含往返、按人还是按组
        basis = m.get("budget_basis")
        if not isinstance(basis, dict) \
                or not isinstance(basis.get("includes_transport"), bool) \
                or basis.get("scope") not in ("per_person", "per_group"):
            missing.append({"member_id": mid, "field": "budget_basis", "rule_id": R_DATA_02})
        elif basis["scope"] == "per_group" and not basis.get("share_rule"):
            missing.append({"member_id": mid,
                            "field": "budget_basis.share_rule", "rule_id": R_DATA_02})

    win = trip.get("window")
    bounds: tuple[datetime, datetime] | None = None
    try:
        win_start, win_end = parse_time(win["start"]), parse_time(win["end"])
        if win_start >= win_end:
            raise ValueError
        bounds = (win_start, win_end)
    except (KeyError, TypeError, ValueError):
        missing.append({"member_id": None, "field": "window", "rule_id": R_DATA_01})

    costs = trip.get("cost_per_member")
    for mid in REQUIRED_MEMBER_IDS:
        value = costs.get(mid) if isinstance(costs, dict) else None
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            missing.append({"member_id": None, "field": "cost_per_member." + mid,
                            "rule_id": R_DATA_01})

    nodes = trip.get("nodes")
    if not isinstance(nodes, list) or not nodes or any(
        not isinstance(node, dict) for node in nodes
    ):
        missing.append({"member_id": None, "field": "nodes", "rule_id": R_DATA_01})
    else:
        window_mismatch = False
        seen_ids: set[str] = set()
        for node in sorted(nodes, key=lambda n: str(n.get("node_id"))):
            nid = node.get("node_id")
            if not isinstance(nid, str) or not nid.strip() or nid in seen_ids:
                missing.append({"member_id": None, "field": "nodes.node_id",
                                "rule_id": R_DATA_01})
                continue
            seen_ids.add(nid)
            if not node.get("kind"):
                missing.append({"member_id": None, "field": "nodes." + nid,
                                "rule_id": R_DATA_01})
                continue
            try:
                node_start, node_end = parse_time(node["start"]), parse_time(node["end"])
                if node_start >= node_end:
                    raise ValueError
            except (KeyError, TypeError, ValueError):
                missing.append({"member_id": None, "field": "nodes." + nid,
                                "rule_id": R_DATA_01})
            else:
                # 防止卡上写了较短的全程窗，节点里却排了更晚的返校时间。
                if bounds is not None and (node_start < bounds[0] or node_end > bounds[1]):
                    window_mismatch = True
        if window_mismatch:
            missing.append({"member_id": None, "field": "window", "rule_id": R_DATA_01})

    missing.sort(key=lambda x: (str(x["member_id"]), x["field"]))
    return missing


# ---------------------------------------------------------------- 时间窗


def merge_windows(windows: Sequence[Window]) -> list[Window]:
    """同一成员内部：重叠或相邻（end == start）都合并为一段。"""
    merged: list[Window] = []
    for start, end in sorted(windows):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def intersect(a: Sequence[Window], b: Sequence[Window]) -> list[Window]:
    """两段集合求交，只保留正时长；端点相碰（start == end）不算共同可用时间。"""
    out: list[Window] = []
    i, j = 0, 0
    while i < len(a) and j < len(b):
        start = max(a[i][0], b[j][0])
        end = min(a[i][1], b[j][1])
        if start < end:
            out.append((start, end))
        if a[i][1] < b[j][1]:
            i += 1
        else:
            j += 1
    return out


def _member_windows(member: Mapping[str, Any]) -> list[Window]:
    return merge_windows([(parse_time(w["start"]), parse_time(w["end"]))
                          for w in member["available_windows"]])


def common_windows(fixture: Fixture) -> list[Window]:
    """四人共同可用窗：先各自合并（重叠或相邻），再逐人求交集（只认正时长）。"""
    common: list[Window] | None = None
    for m in sorted(fixture["members"], key=lambda x: x["member_id"]):
        mine = _member_windows(m)
        common = mine if common is None else intersect(common, mine)
        if not common:
            return []
    return common or []


def _contained_in_any(windows: Sequence[Window], window: Window) -> bool:
    return any(start <= window[0] and window[1] <= end for start, end in windows)


def _time_violators(fixture: Fixture, window: Window) -> list[str]:
    """候选装不下时，归因于「自己的任何一段合并后空闲都装不下候选」的成员。"""
    return sorted(m["member_id"] for m in fixture["members"]
                  if not _contained_in_any(_member_windows(m), window))


# ---------------------------------------------------------------- 行程展开


def expand_nodes(nodes: Any, overrides: Sequence[Mapping[str, Any]] | None) -> Any:
    """行程层覆盖记录 -> 展开后的节点序列；返回深拷贝，原节点绝不被修改。"""
    if not isinstance(nodes, list):
        return nodes  # 留给完整性检查返回结构化缺项。
    # 覆盖记录本身也可能不完整（缺 replaces / node）。跳过不完整的项而不是抛
    # KeyError，让后续完整性检查以结构化缺项的方式给出结论。
    replaces = {
        o["replaces"]: o["node"]
        for o in overrides or []
        if isinstance(o, Mapping) and "replaces" in o and "node" in o
    }
    return [
        deepcopy(replaces.get(n["node_id"], n))
        if isinstance(n, dict) and isinstance(n.get("node_id"), str)
        else deepcopy(n)
        for n in nodes
    ]


def window_from_nodes(nodes: Sequence[Mapping[str, Any]]) -> dict[str, str]:
    """整条行程的全程时间窗 = 最早节点开始 ~ 最晚节点结束，统一输出 ISO 字符串。

    任一节点缺 start/end 或格式非法时**不抛异常**：返回空窗，交给
    check_completeness 统一判 incomplete 并列出结构化缺项。降雨替代节点来自
    行程层覆盖记录，字段可能不全，不能让整程重检在算窗这一步直接崩掉。
    """
    try:
        starts = [parse_time(n["start"]) for n in nodes]
        ends = [parse_time(n["end"]) for n in nodes]
        if not starts or not ends:
            return {}
        return {
            "start": min(starts).isoformat(),
            "end": max(ends).isoformat(),
        }
    except (KeyError, TypeError, ValueError):
        return {}


def trip_from_candidate(
    candidate: Mapping[str, Any],
    overrides: Sequence[Mapping[str, Any]] | None = None,
) -> Trip:
    """固定候选（可带 overrides）-> 交给检测器的整条行程；全部字段深拷贝。"""
    nodes = expand_nodes(candidate.get("nodes"), overrides)
    if overrides:
        window: Any = window_from_nodes(nodes) if nodes else None
    else:
        window = deepcopy(candidate.get("window"))
    return {
        "candidate_id": candidate.get("candidate_id"),
        "window": window,
        "cost_per_member": deepcopy(candidate.get("cost_per_member")),
        "nodes": nodes,
    }


# ---------------------------------------------------------------- 主入口


def detect_resolved(fixture: Fixture, trip: Trip) -> DetectionResult:
    """核心判定：四人约束 + 一条完整行程（全程时间窗、逐人费用、展开后节点）。

    A 的降雨替代流程走这里：展开 overrides 得到新行程 -> 调本函数 -> 通过才生成预览。
    """
    fp = fingerprint({"fixture": fixture, "trip": trip})
    missing = check_completeness(fixture, trip)
    if missing:
        return _make_result(fixture, trip, fp, Status.INCOMPLETE, [], missing)

    window: Window = (parse_time(trip["window"]["start"]), parse_time(trip["window"]["end"]))
    nodes: list[Node] = trip["nodes"]
    reasons: list[Reason] = []

    # R-TIME：共同窗是否存在 -> 候选是否完整落入某一段
    common = common_windows(fixture)
    if not common:
        violators = _time_violators(fixture, window)
        reasons.append({
            "rule_id": R_TIME_02,
            "member_ids": violators,
            "field": "available_windows",
            "message": "四人无共同可用时间（" + "、".join(violators) + " 的空闲时间覆盖不到该时段）",
        })
    elif not _contained_in_any(common, window):
        violators = _time_violators(fixture, window)
        reason: Reason = {
            "rule_id": R_TIME_01,
            "member_ids": violators,
            "field": "candidate_window",
            "message": "候选时段未完整落入共同可用窗（受 " + "、".join(violators) + " 的时间窗限制）",
        }
        latest_end = max(end for _, end in common)
        earliest_start = min(start for start, _ in common)
        if window[1] > latest_end:
            reason["actual"] = window[1].isoformat()
            reason["threshold"] = latest_end.isoformat()
        elif window[0] < earliest_start:
            reason["actual"] = window[0].isoformat()
            reason["threshold"] = earliest_start.isoformat()
        reasons.append(reason)

    # R-BUD：逐人比较，等号通过；缺人早在完整性阶段拦下
    for m in sorted(fixture["members"], key=lambda x: x["member_id"]):
        cost = trip["cost_per_member"][m["member_id"]]
        cap = m["budget_cap"]
        if cost > cap:
            reasons.append({
                "rule_id": R_BUD_01,
                "member_ids": [m["member_id"]],
                "field": "cost_per_member." + m["member_id"],
                "actual": cost,
                "threshold": cap,
                "message": f"{m['member_id']} 承担 {_fmt_money(cost)}，"
                           f"超过上限 {_fmt_money(cap)} {_fmt_money(cost - cap)}",
            })

    # R-TRANS：逐段检查；同一人只报第一条，指向第一段违反的节点
    for m in sorted(fixture["members"], key=lambda x: x["member_id"]):
        for node in nodes:
            if (node["kind"] == "transit" and
                    normalize_transport(node.get("transport")) not in
                    normalize_transports(m["allowed_transport"])):
                reasons.append({
                    "rule_id": R_TRANS_01,
                    "member_ids": [m["member_id"]],
                    "field": node["node_id"],
                    "message": "{} 不接受交通方式 {}（节点 {}）".format(
                        m["member_id"], node.get("transport"), node["node_id"]),
                })
                break

    # R-TABOO：地点标签命中；同样只报第一条
    for m in sorted(fixture["members"], key=lambda x: x["member_id"]):
        for node in nodes:
            if node["kind"] == "activity" and node.get("place_tag") in m["taboo_tags"]:
                reasons.append({
                    "rule_id": R_TABOO_01,
                    "member_ids": [m["member_id"]],
                    "field": node["node_id"],
                    "message": "{} 的禁忌命中 {}（节点 {}）".format(
                        m["member_id"], node.get("place_tag"), node["node_id"]),
                })
                break

    reasons.sort(key=lambda r: (r["rule_id"], r["member_ids"][0]))
    status = Status.INFEASIBLE if reasons else Status.FEASIBLE
    return _make_result(fixture, trip, fp, status, reasons, [])


def detect(fixture: Fixture, candidate_id: str) -> DetectionResult:
    """判定固定候选：fixture.candidates 里按 ID 取整条行程。"""
    candidates = _candidate_index(fixture)
    if candidate_id not in candidates:
        raise ValueError(
            f"未知候选 ID {candidate_id!r}；可用：{', '.join(sorted(candidates))}"
        )
    return detect_resolved(fixture, trip_from_candidate(candidates[candidate_id]))


def detect_trip(
    fixture: Fixture,
    base_candidate_id: str,
    overrides: Sequence[Mapping[str, Any]] | None,
) -> DetectionResult:
    """G3 便捷入口：展开 overrides 后重跑同一套检测。替代产物是行程版本，不是新候选。"""
    candidates = _candidate_index(fixture)
    if base_candidate_id not in candidates:
        raise ValueError(
            f"未知候选 ID {base_candidate_id!r}；可用：{', '.join(sorted(candidates))}"
        )
    return detect_resolved(
        fixture, trip_from_candidate(candidates[base_candidate_id], overrides)
    )


# ---------------------------------------------------------------- 整池判定（全失败提示）


def _member_field_value(fixture: Fixture, member_id: str, field: str) -> Any:
    """取某个成员自己声明的原值，用于「保留原值」这一条。"""
    for member in fixture["members"]:
        if member["member_id"] == member_id:
            return member.get(field)
    return None


def relaxation_hints(
    fixture: Fixture, results: Sequence[DetectionResult]
) -> list[RelaxationHint]:
    """全部候选都不可行时，列出可由成员本人自愿调整的字段。

    只输出：是谁、哪个字段、当前原值、被哪些规则挡住、影响哪几张候选。
    不给建议值、不排序、不生成替代方案；系统不自动改任何输入，
    改与不改都要本人确认后再重新跑一遍检测（action / system_auto_change 两个字段写明）。
    """
    hints: dict[tuple[str, str], RelaxationHint] = {}
    for result in results:
        if result["status"] != Status.INFEASIBLE.value:
            continue
        for reason in result["reasons"]:
            field = RELAXABLE_FIELD_BY_RULE.get(reason["rule_id"])
            if not field:
                continue
            for member_id in reason.get("member_ids", []):
                key = (member_id, field)
                entry = hints.setdefault(key, {
                    "member_id": member_id,
                    "field": "members.%s.%s" % (member_id, field),
                    "current_value": _member_field_value(fixture, member_id, field),
                    "rule_ids": [],
                    "blocked_candidates": [],
                    "action": "member_voluntary_adjust_then_confirm",
                    "system_auto_change": False,
                })
                if reason["rule_id"] not in entry["rule_ids"]:
                    entry["rule_ids"].append(reason["rule_id"])
                if result["candidate_id"] not in entry["blocked_candidates"]:
                    entry["blocked_candidates"].append(result["candidate_id"])

    out = sorted(hints.values(), key=lambda x: (x["member_id"], x["field"]))
    for entry in out:
        entry["rule_ids"].sort()
        entry["blocked_candidates"].sort()
    return out


def detect_all(fixture: Fixture) -> PoolResult:
    """整池判定：一次给出全部固定候选的状态；全失败时给「可自愿调整字段」提示。

    三态优先级不变：incomplete 的候选只进 pending_fields（补填），
    不进 relaxation_hints（调整）——缺字段时谈放宽约束会把人引错方向。
    """
    candidate_ids = sorted(c["candidate_id"] for c in fixture["candidates"])
    results = [detect(fixture, cid) for cid in candidate_ids]
    feasible = [r["candidate_id"] for r in results
                if r["status"] == Status.FEASIBLE.value]

    pending_fields: list[PendingField] = []
    for result in results:
        if result["status"] == Status.INCOMPLETE.value:
            for miss in result["missing_fields"]:
                pending_fields.append({
                    "candidate_id": result["candidate_id"],
                    "member_id": miss["member_id"],
                    "field": miss["field"],
                    "rule_id": miss["rule_id"],
                })

    return {
        "fixture_version": fixture["fixture_version"],
        # 整池指纹口径：对整个候选池算，与单候选的 fingerprint({fixture, trip}) 不同，
        # 不要拿它跟 c01/c02/c03 的逐候选指纹对齐。
        "input_fingerprint": fingerprint({"fixture": fixture, "scope": "all_candidates"}),
        "candidate_ids": candidate_ids,
        "candidates": results,
        "feasible_candidates": feasible,
        "all_failed": not feasible,
        "pending_fields": pending_fields,
        "relaxation_hints": relaxation_hints(fixture, results) if not feasible else [],
    }
