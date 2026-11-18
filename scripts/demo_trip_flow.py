"""使用共享数据和 B 的检测器，从四人提交演示到降雨替代生效。"""

import json
from datetime import datetime, timedelta
from pathlib import Path

from core.trip_state import TripState


FIXTURE_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "demo-trip.json"


def main() -> None:
    fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    rain, replacement = fixture["rain_event"], fixture["rain_replacement"]
    members = tuple(member["member_id"] for member in fixture["members"])
    organizer = members[0]
    event_time = datetime.fromisoformat(rain["source"]["retrieved_at"])
    now = event_time - timedelta(minutes=25)
    trip = TripState(members, organizer_id=organizer, clock=lambda: now)
    print(f"同行计划 | 合成样例 {fixture['fixture_version']} | {fixture['origin']['name']}")

    for member in fixture["members"]:
        trip.submit_member(member["member_id"], member)
    print(f"{trip.phase.value}: {len(trip.member_submissions)}/{len(members)} 已提交")

    trip.open_fixture_candidates(fixture, actor_id=organizer)
    print(f"{trip.phase.value}: B 硬约束检查")
    candidates = {candidate["candidate_id"]: candidate for candidate in fixture["candidates"]}
    for result in trip.candidate_results:
        candidate_id = result["candidate_id"]
        print(f"  {candidate_id} {candidates[candidate_id]['display_name']}: {result['status']}")
        for reason in result["reasons"]:
            if reason["rule_id"] == "R-BUD-01":
                print(f"    R-BUD-01 {'、'.join(reason['member_ids'])}: "
                      f"{reason['actual']} 分超过 {reason['threshold']} 分")
            else:
                print(f"    {reason['rule_id']}: {reason['message']}")

    plan = trip.select_candidate(organizer, "c02")
    print(f"{trip.phase.value}: {plan.candidate_id}/{plan.version}")
    for member_id in members:
        trip.confirm_candidate(member_id, plan.candidate_id, plan.version)
        print(f"  {member_id} 已确认 ({len(trip.confirmed_member_ids)}/{len(members)})")
    trip.start_trip(organizer, plan.candidate_id, plan.version)
    print(f"{trip.phase.value}: {plan.candidate_id}/{plan.version}")

    now = event_time
    print(f"[模拟] {rain['event_id']} | {rain['source']['note']} | {now.isoformat()}")
    print(f"  雨窗: {rain['window']['start']} ～ {rain['window']['end']}")
    preview = trip.preview_change(organizer, plan.version, rain, replacement)
    impact = preview.impact
    print(f"  受影响: {', '.join(impact.affected_node_ids)}")
    print(f"  保留: {', '.join(impact.unchanged_node_ids)}")
    print(f"  理由: {impact.reason}")
    if preview.preview_id is None:
        print(f"  当前仍是 {plan.version}，请人工调整。")
        return

    new_node_id = impact.replacement["node"]["node_id"]
    print(f"{trip.phase.value}: {impact.replacement['replaces']} → {new_node_id} | "
          f"B 复检 {impact.rule_result['status']} | 当前仍是 {plan.version}")
    trip.cancel_change(organizer, preview.preview_id, plan.version)
    print(f"{trip.phase.value}: 取消预览，保留 {trip.locked_plan.version}")
    ready = trip.preview_change(organizer, plan.version, rain, replacement)
    now += timedelta(minutes=1)
    # 终端演示使用固定的明确授权。真实客户端要等发起人按确认按钮。
    updated = trip.apply_change(organizer, ready.preview_id, plan.version)
    print(f"{trip.phase.value}: {plan.candidate_id}/{plan.version} → "
          f"{updated.candidate_id}/{updated.version}")
    print("确认记录:")
    for record in trip.events:
        if record.event in ("confirm_candidate", "apply_change"):
            print(f"  {record.at.isoformat()} {record.event} "
                  f"{record.actor_id} {record.candidate_id}/{record.plan_version}")


if __name__ == "__main__":
    main()
