# -*- coding: utf-8 -*-
"""硬约束检测器（本周唯一判定入口）。

导入与签名
----------
    from algorithm.conflict_detector import detect, detect_trip, detect_resolved

    detect(fixture, candidate_id)                      # 固定候选
    detect_trip(fixture, base_candidate_id, overrides)  # 便捷：自己展开 overrides 再判
    detect_resolved(fixture, trip)                      # A 传入展开后的整条行程再判

    fixture : dict   fixtures/demo-trip.json 的内容（四人约束 + 候选池）
    trip    : dict   {"candidate_id", "window", "cost_per_member", "nodes"}
    overrides : list [{"replaces": "c02-n02", "node": {...}, "reason": "..."}]
    返回     : dict  {"candidate_id", "fixture_version", "input_fingerprint",
                      "status", "reasons", "missing_fields"}

时间约定
--------
所有时间（成员可用窗、候选全程、**节点**）一律为带偏移的 ISO 8601：
    2026-11-21T13:30:00+08:00
不带偏移视为格式非法，判 incomplete，不做本地时区猜测。

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

import hashlib
import json
from datetime import datetime, timedelta, timezone

TZ = timezone(timedelta(hours=8))
REQUIRED_MEMBER_IDS = ("m01", "m02", "m03", "m04")


# ---------------------------------------------------------------- 基础工具

def _canon(payload):
    return json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def fingerprint(payload):
    """规范化 JSON 的 sha256 前 8 位，用于自证「同一输入」。"""
    return hashlib.sha256(_canon(payload).encode("utf-8")).hexdigest()[:8]


def parse_time(s):
    """解析带偏移的 ISO 8601；不带偏移抛 ValueError（不猜时区）。"""
    if not isinstance(s, str):
        raise ValueError("not a string")
    dt = datetime.fromisoformat(s)
    if dt.utcoffset() is None:
        raise ValueError("missing UTC offset")
    return dt


# ---------------------------------------------------------------- 完整性检查

def _check_window_list(wins):
    if not isinstance(wins, list) or not wins:
        return False
    for w in wins:
        try:
            if not parse_time(w["start"]) < parse_time(w["end"]):
                return False
        except Exception:
            return False
    return True


def check_completeness(fixture, trip):
    """缺字段、格式非法、口径未定 -> missing_fields；此时不判可行也不判不可行。"""
    missing = []
    for m in fixture["members"]:
        mid = m.get("member_id")

        if not _check_window_list(m.get("available_windows")):
            missing.append({"member_id": mid, "field": "available_windows", "rule_id": "R-DATA-01"})

        cap = m.get("budget_cap")
        if isinstance(cap, bool) or not isinstance(cap, int) or cap < 0:
            missing.append({"member_id": mid, "field": "budget_cap", "rule_id": "R-DATA-01"})

        transport = m.get("allowed_transport")
        if not isinstance(transport, list) or not transport:
            missing.append({"member_id": mid, "field": "allowed_transport", "rule_id": "R-DATA-01"})

        # 口径未定：预算必须声明含不含往返、按人还是按组
        basis = m.get("budget_basis")
        if not isinstance(basis, dict) \
                or not isinstance(basis.get("includes_transport"), bool) \
                or basis.get("scope") not in ("per_person", "per_group"):
            missing.append({"member_id": mid, "field": "budget_basis", "rule_id": "R-DATA-02"})
        elif basis["scope"] == "per_group" and not basis.get("share_rule"):
            missing.append({"member_id": mid,
                            "field": "budget_basis.share_rule", "rule_id": "R-DATA-02"})

    win = trip.get("window")
    try:
        if not parse_time(win["start"]) < parse_time(win["end"]):
            raise ValueError
    except Exception:
        missing.append({"member_id": None, "field": "window", "rule_id": "R-DATA-01"})

    costs = trip.get("cost_per_member")
    for mid in REQUIRED_MEMBER_IDS:
        value = costs.get(mid) if isinstance(costs, dict) else None
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            missing.append({"member_id": None, "field": "cost_per_member." + mid,
                            "rule_id": "R-DATA-01"})

    nodes = trip.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        missing.append({"member_id": None, "field": "nodes", "rule_id": "R-DATA-01"})
    else:
        for node in sorted(nodes, key=lambda n: str(n.get("node_id"))):
            nid = node.get("node_id", "?")
            if not node.get("kind"):
                missing.append({"member_id": None, "field": "nodes." + nid, "rule_id": "R-DATA-01"})
                continue
            try:
                if not parse_time(node["start"]) < parse_time(node["end"]):
                    raise ValueError
            except Exception:
                missing.append({"member_id": None, "field": "nodes." + nid,
                                "rule_id": "R-DATA-01"})

    missing.sort(key=lambda x: (str(x["member_id"]), x["field"]))
    return missing


# ---------------------------------------------------------------- 时间窗

def merge_windows(windows):
    """同一成员内部：重叠或相邻（end == start）都合并为一段。"""
    merged = []
    for start, end in sorted(windows):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def intersect(a, b):
    """两段集合求交，只保留正时长；端点相碰（start == end）不算共同可用时间。"""
    out, i, j = [], 0, 0
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


def _member_windows(member):
    return merge_windows([(parse_time(w["start"]), parse_time(w["end"]))
                          for w in member["available_windows"]])


def common_windows(fixture):
    """四人共同可用窗：先各自合并（重叠或相邻），再逐人求交集（只认正时长）。"""
    common = None
    for m in sorted(fixture["members"], key=lambda x: x["member_id"]):
        mine = _member_windows(m)
        common = mine if common is None else intersect(common, mine)
        if not common:
            return []
    return common


def _contained_in_any(windows, window):
    return any(start <= window[0] and window[1] <= end for start, end in windows)


def _time_violators(fixture, window):
    """候选装不下时，归因于「自己的任何一段合并后空闲都装不下候选」的成员。"""
    return sorted(m["member_id"] for m in fixture["members"]
                  if not _contained_in_any(_member_windows(m), window))


# ---------------------------------------------------------------- 行程展开

def expand_nodes(nodes, overrides):
    """行程层覆盖记录 -> 展开后的节点序列；原节点不被修改。"""
    replaces = {o["replaces"]: o["node"] for o in overrides or []}
    return [replaces.get(n["node_id"], n) for n in nodes]


def window_from_nodes(nodes):
    """整条行程的全程时间窗 = 最早节点开始 ~ 最晚节点结束，统一输出 ISO 字符串。"""
    return {
        "start": min(parse_time(n["start"]) for n in nodes).isoformat(),
        "end": max(parse_time(n["end"]) for n in nodes).isoformat(),
    }


def trip_from_candidate(candidate, overrides=None):
    """固定候选（可带 overrides）-> 交给检测器的整条行程。"""
    nodes = expand_nodes(candidate.get("nodes"), overrides)
    if overrides:
        window = window_from_nodes(nodes) if nodes else None
    else:
        window = candidate.get("window")
    return {
        "candidate_id": candidate.get("candidate_id"),
        "window": window,
        "cost_per_member": candidate.get("cost_per_member"),
        "nodes": nodes,
    }


# ---------------------------------------------------------------- 主入口

def detect_resolved(fixture, trip):
    """核心判定：四人约束 + 一条完整行程（全程时间窗、逐人费用、展开后节点）。

    A 的降雨替代流程走这里：展开 overrides 得到新行程 -> 调本函数 -> 通过才生成预览。
    """
    result = {
        "candidate_id": trip.get("candidate_id"),
        "fixture_version": fixture["fixture_version"],
        "input_fingerprint": fingerprint({"fixture": fixture, "trip": trip}),
        "status": None,
        "reasons": [],
        "missing_fields": [],
    }

    missing = check_completeness(fixture, trip)
    if missing:
        result["status"] = "incomplete"
        result["missing_fields"] = missing
        return result

    window = (parse_time(trip["window"]["start"]), parse_time(trip["window"]["end"]))
    nodes = trip["nodes"]
    reasons = []

    # R-TIME：共同窗是否存在 -> 候选是否完整落入某一段
    common = common_windows(fixture)
    if not common:
        violators = _time_violators(fixture, window)
        reasons.append({
            "rule_id": "R-TIME-02",
            "member_ids": violators,
            "field": "available_windows",
            "message": "四人无共同可用时间（" + "、".join(violators) + " 的空闲时间覆盖不到该时段）",
        })
    elif not _contained_in_any(common, window):
        violators = _time_violators(fixture, window)
        reason = {
            "rule_id": "R-TIME-01",
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
                "rule_id": "R-BUD-01",
                "member_ids": [m["member_id"]],
                "field": "cost_per_member." + m["member_id"],
                "actual": cost,
                "threshold": cap,
                "message": "{} 承担 {} 元，超过上限 {} 元 {} 元".format(
                    m["member_id"], cost // 100, cap // 100, (cost - cap) // 100),
            })

    # R-TRANS：逐段检查；同一人只报第一条，指向第一段违反的节点
    for m in sorted(fixture["members"], key=lambda x: x["member_id"]):
        for node in nodes:
            if node["kind"] == "transit" and node.get("transport") not in m["allowed_transport"]:
                reasons.append({
                    "rule_id": "R-TRANS-01",
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
                    "rule_id": "R-TABOO-01",
                    "member_ids": [m["member_id"]],
                    "field": node["node_id"],
                    "message": "{} 的禁忌命中 {}（节点 {}）".format(
                        m["member_id"], node.get("place_tag"), node["node_id"]),
                })
                break

    reasons.sort(key=lambda r: (r["rule_id"], r["member_ids"][0]))
    result["reasons"] = reasons
    result["status"] = "infeasible" if reasons else "feasible"
    return result


def detect(fixture, candidate_id):
    """判定固定候选：fixture.candidates 里按 ID 取整条行程。"""
    candidates = {c["candidate_id"]: c for c in fixture["candidates"]}
    return detect_resolved(fixture, trip_from_candidate(candidates[candidate_id]))


def detect_trip(fixture, base_candidate_id, overrides):
    """G3 便捷入口：展开 overrides 后重跑同一套检测。替代产物是行程版本，不是新候选。"""
    candidates = {c["candidate_id"]: c for c in fixture["candidates"]}
    return detect_resolved(fixture, trip_from_candidate(candidates[base_candidate_id], overrides))
