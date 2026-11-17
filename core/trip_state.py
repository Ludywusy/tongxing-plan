"""管理意向收集、方案候选、成员确认和行程执行。"""

from collections.abc import Callable, Mapping, Sequence
from copy import deepcopy
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from enum import Enum
from typing import NoReturn


class TripPhase(Enum):
    COLLECTING = "collecting"
    CANDIDATES = "candidates"
    CONFIRMING = "confirming"
    EXECUTING = "executing"


@dataclass(frozen=True)
class PlanRef:
    """成员确认绑定的候选 ID 和行程版本。"""

    candidate_id: str
    version: str


@dataclass(frozen=True)
class TripEvent:
    event: str
    from_phase: TripPhase
    to_phase: TripPhase
    actor_id: str
    at: datetime
    plan_version: str | None
    candidate_id: str | None
    reason: str | None = None


class TripState:
    """记录一次行程的成员提交、候选结果、确认与迁移日志。"""

    def __init__(
        self,
        member_ids: Sequence[str],
        *,
        organizer_id: str | None = None,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        if isinstance(member_ids, str):
            raise ValueError("Provide a sequence of member IDs.")

        self._member_ids = tuple(member_ids)
        if not self._member_ids or any(not member_id.strip() for member_id in self._member_ids):
            raise ValueError("Provide one or more non-empty member IDs.")
        if len(set(self._member_ids)) != len(self._member_ids):
            raise ValueError("Member IDs must be unique.")

        self._organizer_id = self._member_ids[0] if organizer_id is None else organizer_id
        if self._organizer_id not in self._member_ids:
            raise ValueError("The organizer must be a member of the trip.")

        self._clock = clock if clock is not None else lambda: datetime.now(timezone.utc)
        self._phase = TripPhase.COLLECTING
        self._submissions: dict[str, dict[str, object]] = {}
        self._candidate_results: dict[str, dict[str, object]] = {}
        self._selected_plan: PlanRef | None = None
        self._locked_plan: PlanRef | None = None
        self._version_number = 0
        self._confirmed_members: set[str] = set()
        self._events: list[TripEvent] = []

    @property
    def phase(self) -> TripPhase:
        return self._phase

    @property
    def pending_member_ids(self) -> tuple[str, ...]:
        """按名单顺序列出未提交的成员，供前端提示补填。"""
        return tuple(
            member_id for member_id in self._member_ids if member_id not in self._submissions
        )

    @property
    def member_submissions(self) -> dict[str, dict[str, object]]:
        """返回提交资料的副本，供约束检测端读取。"""
        return deepcopy(self._submissions)

    @property
    def candidate_results(self) -> tuple[dict[str, object], ...]:
        """按候选 ID 展示检测结果，保留 B 返回的原因和补填字段。"""
        return tuple(
            deepcopy(self._candidate_results[key]) for key in sorted(self._candidate_results)
        )

    @property
    def selected_plan(self) -> PlanRef | None:
        return self._selected_plan

    @property
    def locked_plan(self) -> PlanRef | None:
        return self._locked_plan

    @property
    def confirmed_member_ids(self) -> tuple[str, ...]:
        return tuple(
            member_id for member_id in self._member_ids if member_id in self._confirmed_members
        )

    @property
    def events(self) -> tuple[TripEvent, ...]:
        return tuple(self._events)

    def submit_member(self, member_id: str, submission: Mapping[str, object]) -> None:
        """在收集阶段保存成员最新一次提交。"""
        event = "submit_member"
        if self.phase is not TripPhase.COLLECTING:
            self._reject(event, member_id, "Member submissions are only accepted during collection.")
        if member_id not in self._member_ids:
            reason = f"Unknown member ID: {member_id}"
            self._record(event, member_id, reason=reason)
            raise ValueError(reason)
        if not submission:
            reason = f"Submission for {member_id} is empty."
            self._record(event, member_id, reason=reason)
            raise ValueError(reason)

        # 同一成员的新提交覆盖旧资料。复制内容，避免调用方事后修改已保存的数据。
        saved_submission = deepcopy(dict(submission))
        self._record(event, member_id)
        self._submissions[member_id] = saved_submission

    def open_candidates(
        self,
        results: Sequence[Mapping[str, object]] = (),
        *,
        actor_id: str | None = None,
    ) -> None:
        """全员提交后，由发起人发布 B 提供的候选检测结果。"""
        event = "open_candidates"
        actor_id = self._organizer_id if actor_id is None else actor_id
        self._require_organizer(event, actor_id)
        if self.phase is not TripPhase.COLLECTING:
            self._reject(event, actor_id, "Candidate selection can only open from collection.")

        pending = self.pending_member_ids
        if pending:
            self._reject(event, actor_id, f"Missing member submissions: {', '.join(pending)}")

        candidates: dict[str, dict[str, object]] = {}
        for result in results:
            if not isinstance(result, Mapping):
                self._reject(event, actor_id, "Each candidate result must be a mapping.")
            candidate_id = result.get("candidate_id")
            if not isinstance(candidate_id, str) or not candidate_id.strip():
                self._reject(event, actor_id, "Candidate result needs a non-empty candidate_id.")
            if candidate_id in candidates:
                self._reject(event, actor_id, f"Duplicate candidate ID: {candidate_id}")
            if result.get("status") not in ("feasible", "infeasible", "incomplete"):
                self._reject(event, actor_id, f"Candidate {candidate_id} has an invalid status.")
            candidates[candidate_id] = deepcopy(dict(result))

        self._record(event, actor_id, to_phase=TripPhase.CANDIDATES)
        self._candidate_results = candidates

    def select_candidate(self, actor_id: str, candidate_id: str) -> PlanRef:
        """选中可行候选并创建确认版本。改选时清空旧确认。"""
        event = "select_candidate"
        self._require_organizer(event, actor_id)
        if self.phase not in (TripPhase.CANDIDATES, TripPhase.CONFIRMING):
            self._reject(event, actor_id, "Candidate selection is unavailable in this phase.")

        result = self._candidate_results.get(candidate_id)
        if result is None:
            self._reject(event, actor_id, f"Unknown candidate ID: {candidate_id}")
        status = result["status"]
        if status != "feasible":
            self._reject(event, actor_id, f"Candidate {candidate_id} is {status}.")

        current = self.selected_plan
        if current is not None and current.candidate_id == candidate_id:
            return current

        # 版本在选中时分配，成员从第一次确认起就绑定到具体版本。
        number = self._version_number + 1
        plan = PlanRef(candidate_id, f"v{number}")
        self._record(event, actor_id, to_phase=TripPhase.CONFIRMING, plan=plan)
        self._version_number = number
        self._set_plan(plan)
        return plan

    def confirm_candidate(self, member_id: str, candidate_id: str, version: str) -> bool:
        """确认指定候选版本。重复确认返回 False，避免重复写入。"""
        event = "confirm_candidate"
        if member_id not in self._member_ids:
            self._reject(event, member_id, f"Unknown member ID: {member_id}")
        plan = self._require_current_plan(event, member_id, candidate_id, version)
        # 确认请求可能在开始行程后被重试，当前版本的已确认记录仍只计一次。
        if member_id in self._confirmed_members:
            return False
        if self.phase is not TripPhase.CONFIRMING:
            self._reject(event, member_id, "Member confirmation is unavailable in this phase.")

        entry = self._record(event, member_id)
        self._confirmed_members.add(member_id)
        if len(self._confirmed_members) == len(self._member_ids):
            self._locked_plan = plan
            self._events.append(replace(entry, event="lock_plan"))
        return True

    def start_trip(self, actor_id: str, candidate_id: str, version: str) -> None:
        """由发起人开始执行当前已锁定的行程。"""
        event = "start_trip"
        self._require_organizer(event, actor_id)
        plan = self._require_current_plan(event, actor_id, candidate_id, version)
        if self.phase is TripPhase.EXECUTING:
            self._reject(event, actor_id, "The trip is already executing.")
        if self.locked_plan != plan:
            pending = [
                member_id for member_id in self._member_ids if member_id not in self._confirmed_members
            ]
            self._reject(event, actor_id, f"Missing confirmations: {', '.join(pending)}")

        self._record(event, actor_id, to_phase=TripPhase.EXECUTING)

    def return_to_collection(self, actor_id: str) -> None:
        """执行前可返回收集，保留成员资料并让旧候选和确认失效。"""
        event = "return_to_collection"
        self._require_organizer(event, actor_id)
        if self.phase not in (TripPhase.CANDIDATES, TripPhase.CONFIRMING):
            self._reject(event, actor_id, "Collection can only reopen before execution.")

        self._record(event, actor_id, to_phase=TripPhase.COLLECTING)
        self._candidate_results.clear()
        self._set_plan(None)

    def _set_plan(self, plan: PlanRef | None) -> None:
        self._selected_plan = plan
        self._locked_plan = None
        self._confirmed_members.clear()

    def _require_organizer(self, event: str, actor_id: str) -> None:
        if actor_id != self._organizer_id:
            self._reject(event, actor_id, "Only the organizer can perform this action.")

    def _require_current_plan(
        self, event: str, actor_id: str, candidate_id: str, version: str
    ) -> PlanRef:
        plan = self.selected_plan
        if plan is None:
            self._reject(event, actor_id, "Select a feasible candidate before confirming or starting.")
        if plan.candidate_id != candidate_id or plan.version != version:
            self._reject(
                event,
                actor_id,
                f"Candidate ID or plan version is stale. Requested {candidate_id}/{version}. "
                f"Current selection is {plan.candidate_id}/{plan.version}.",
            )
        return plan

    def _reject(self, event: str, actor_id: str, reason: str) -> NoReturn:
        self._record(event, actor_id, reason=reason)
        raise RuntimeError(reason)

    def _record(
        self,
        event: str,
        actor_id: str,
        *,
        to_phase: TripPhase | None = None,
        plan: PlanRef | None = None,
        reason: str | None = None,
    ) -> TripEvent:
        next_phase = self.phase if to_phase is None else to_phase
        plan = self.selected_plan if plan is None else plan
        entry = TripEvent(
            event=event,
            from_phase=self.phase,
            to_phase=next_phase,
            actor_id=actor_id,
            at=self._clock(),
            plan_version=None if plan is None else plan.version,
            candidate_id=None if plan is None else plan.candidate_id,
            reason=reason,
        )
        self._events.append(entry)
        self._phase = next_phase
        return entry
