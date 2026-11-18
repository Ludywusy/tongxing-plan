"""管理成员提交、候选确认、行程执行及版本化变更。"""

from collections.abc import Callable, Mapping, Sequence
from copy import deepcopy
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from enum import Enum
from typing import NoReturn

from algorithm.conflict_detector import REQUIRED_MEMBER_IDS, detect, trip_from_candidate
from core.change_impact import ChangeImpact, analyze_rain


class TripPhase(Enum):
    COLLECTING = "collecting"
    CANDIDATES = "candidates"
    CONFIRMING = "confirming"
    EXECUTING = "executing"
    CHANGE_PENDING = "change_pending"


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
    base_version: str | None = None
    preview_id: str | None = None


@dataclass(frozen=True)
class ChangePreview:
    """仅有预览编号的结果可以应用；失败原因仍供页面显示。"""

    preview_id: str | None
    base_version: str
    impact: ChangeImpact


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
        self._detection_fixture: dict | None = None
        self._itineraries: dict[str, dict] = {}
        self._current_itinerary: dict | None = None
        self._pending_change: ChangePreview | None = None
        self._preview_number = 0

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
    def current_itinerary(self) -> dict | None:
        """执行中已生效的行程。预览期间仍返回原行程。"""
        return deepcopy(self._current_itinerary)

    @property
    def pending_change(self) -> ChangePreview | None:
        return deepcopy(self._pending_change)

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
        self._require_candidate_publication(actor_id)

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

    def open_fixture_candidates(self, fixture: dict, *, actor_id: str | None = None) -> None:
        """用最新成员提交和共享候选运行 B，同时留存整程快照供降雨复检。"""
        event = "open_candidates"
        actor_id = self._organizer_id if actor_id is None else actor_id
        self._require_candidate_publication(actor_id)
        if set(self._member_ids) != set(REQUIRED_MEMBER_IDS):
            self._reject(event, actor_id, "The shared fixture detector requires exactly m01–m04.")
        if not fixture.get("fixture_version"):
            self._reject(event, actor_id, "The shared fixture needs a fixture_version.")
        candidates = fixture.get("candidates")
        if not isinstance(candidates, list) or not candidates:
            self._reject(event, actor_id, "The shared fixture needs a non-empty candidate list.")
        if any(not isinstance(c, dict) or not isinstance(c.get("candidate_id"), str)
               or not c["candidate_id"].strip() for c in candidates):
            self._reject(event, actor_id, "Each shared candidate needs a non-empty candidate_id.")

        snapshot = deepcopy(fixture)
        submissions = self.member_submissions
        snapshot["members"] = [
            dict(submissions[member_id], member_id=member_id)
            for member_id in self._member_ids
        ]
        candidates = snapshot["candidates"]
        itineraries = {
            candidate["candidate_id"]: trip_from_candidate(candidate) for candidate in candidates
        }
        self.open_candidates(
            [detect(snapshot, candidate["candidate_id"]) for candidate in candidates],
            actor_id=actor_id,
        )
        self._detection_fixture = snapshot
        self._itineraries = itineraries

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
        if self.phase in (TripPhase.EXECUTING, TripPhase.CHANGE_PENDING):
            self._reject(event, actor_id, "The trip is already executing.")
        if self.locked_plan != plan:
            pending = [
                member_id for member_id in self._member_ids if member_id not in self._confirmed_members
            ]
            self._reject(event, actor_id, f"Missing confirmations: {', '.join(pending)}")

        self._record(event, actor_id, to_phase=TripPhase.EXECUTING)
        self._current_itinerary = self._itineraries.get(candidate_id)

    def preview_change(
        self, actor_id: str, base_version: str, rain_event: dict, replacement: dict | None = None
    ) -> ChangePreview:
        """在当前执行版本上检查模拟降雨，不修改已确认行程。"""
        event = "preview_change"
        self._require_organizer(event, actor_id)
        self._require_base_version(event, actor_id, base_version)
        if self.phase is TripPhase.CHANGE_PENDING:
            self._reject(event, actor_id, "Finish the pending change before making another preview.",
                         base_version=base_version)
        if self.phase is not TripPhase.EXECUTING:
            self._reject(event, actor_id, "Start executing the trip before making a preview.",
                         base_version=base_version)
        if self._current_itinerary is None or self._detection_fixture is None:
            self._reject(event, actor_id, "The trip has no checked itinerary snapshot.",
                         base_version=base_version)

        try:
            impact = analyze_rain(
                self._current_itinerary, rain_event, self._detection_fixture, replacement
            )
        except (ValueError, TypeError, KeyError, AttributeError) as exc:
            self._reject(event, actor_id, f"Invalid change input: {exc}", base_version=base_version)
        if impact.itinerary is None:
            self._record(event, actor_id, reason=impact.reason, base_version=base_version)
            return ChangePreview(None, base_version, impact)

        number = self._preview_number + 1
        preview = ChangePreview(f"p{number}", base_version, impact)
        self._record(event, actor_id, to_phase=TripPhase.CHANGE_PENDING, reason=impact.reason,
                     base_version=base_version, preview_id=preview.preview_id)
        self._preview_number = number
        self._pending_change = preview
        return deepcopy(preview)

    def cancel_change(self, actor_id: str, preview_id: str, base_version: str) -> None:
        """取消预览后回到执行，保留原版本和成员确认。"""
        event = "cancel_change"
        self._require_pending_change(event, actor_id, preview_id, base_version)
        self._record(event, actor_id, to_phase=TripPhase.EXECUTING, reason="Change canceled.",
                     base_version=base_version, preview_id=preview_id)
        self._pending_change = None

    def apply_change(self, actor_id: str, preview_id: str, base_version: str) -> PlanRef:
        """发起人确认同一预览时，只应用已经过复检的行程。"""
        event = "apply_change"
        preview, original = self._require_pending_change(event, actor_id, preview_id, base_version)
        number = self._version_number + 1
        plan = PlanRef(original.candidate_id, f"v{number}")
        self._record(event, actor_id, to_phase=TripPhase.EXECUTING, plan=plan,
                     reason=preview.impact.reason, base_version=base_version, preview_id=preview_id)
        self._version_number = number
        self._set_plan(plan)
        # v1 的四人确认仍在事件里；v2 的授权由发起人的应用事件单独记录。
        self._locked_plan = plan
        self._current_itinerary = preview.impact.itinerary
        self._pending_change = None
        return plan

    def return_to_collection(self, actor_id: str) -> None:
        """执行前可返回收集，保留成员资料并让旧候选和确认失效。"""
        event = "return_to_collection"
        self._require_organizer(event, actor_id)
        if self.phase not in (TripPhase.CANDIDATES, TripPhase.CONFIRMING):
            self._reject(event, actor_id, "Collection can only reopen before execution.")

        self._record(event, actor_id, to_phase=TripPhase.COLLECTING)
        self._candidate_results.clear()
        self._itineraries.clear()
        self._detection_fixture = None
        self._set_plan(None)

    def _set_plan(self, plan: PlanRef | None) -> None:
        self._selected_plan = plan
        self._locked_plan = None
        self._confirmed_members.clear()

    def _require_organizer(self, event: str, actor_id: str) -> None:
        if actor_id != self._organizer_id:
            self._reject(event, actor_id, "Only the organizer can perform this action.")

    def _require_candidate_publication(self, actor_id: str) -> None:
        event = "open_candidates"
        self._require_organizer(event, actor_id)
        if self.phase is not TripPhase.COLLECTING:
            self._reject(event, actor_id, "Candidate selection can only open from collection.")
        pending = self.pending_member_ids
        if pending:
            self._reject(event, actor_id, f"Missing member submissions: {', '.join(pending)}")

    def _require_base_version(
        self, event: str, actor_id: str, base_version: str, preview_id: str | None = None
    ) -> PlanRef:
        plan = self.locked_plan
        if plan is None:
            self._reject(event, actor_id, "The trip does not have a locked plan.",
                         base_version=base_version, preview_id=preview_id)
        if plan.version != base_version:
            self._reject(event, actor_id, f"Base version {base_version} is stale; current is {plan.version}.",
                         base_version=base_version, preview_id=preview_id)
        return plan

    def _require_pending_change(
        self, event: str, actor_id: str, preview_id: str, base_version: str
    ) -> tuple[ChangePreview, PlanRef]:
        self._require_organizer(event, actor_id)
        plan = self._require_base_version(event, actor_id, base_version, preview_id)
        preview = self._pending_change
        if (self.phase is not TripPhase.CHANGE_PENDING or preview is None
                or preview.preview_id != preview_id):
            self._reject(event, actor_id, "The requested change preview is no longer active.",
                         base_version=base_version, preview_id=preview_id)
        return preview, plan

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

    def _reject(
        self, event: str, actor_id: str, reason: str, *, base_version: str | None = None,
        preview_id: str | None = None,
    ) -> NoReturn:
        self._record(event, actor_id, reason=reason, base_version=base_version, preview_id=preview_id)
        raise RuntimeError(reason)

    def _record(
        self,
        event: str,
        actor_id: str,
        *,
        to_phase: TripPhase | None = None,
        plan: PlanRef | None = None,
        reason: str | None = None,
        base_version: str | None = None,
        preview_id: str | None = None,
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
            base_version=base_version,
            preview_id=preview_id,
        )
        self._events.append(entry)
        self._phase = next_phase
        return entry
