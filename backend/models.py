"""首批四个接口的请求校验和公开响应。"""

from datetime import date
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, ValidationInfo, field_validator

from algorithm.conflict_detector import parse_time
from core.transport_codes import CANONICAL, normalize_transports


NonBlank = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1)]
NonNegativeInt = Annotated[int, Field(ge=0)]
RoomRole = Literal["organizer", "member"]
Declaration = Literal["must", "prefer", "none", "unsure"]


class RequestModel(BaseModel):
    # 凭证决定操作者。拒绝额外的 member_id、actor_id、role 等字段。
    model_config = ConfigDict(strict=True, extra="forbid")


class CreateRoomRequest(RequestModel):
    room_name: NonBlank
    display_name: NonBlank
    trip_date: Annotated[str, StringConstraints(pattern=r"^\d{4}-\d{2}-\d{2}$")]
    timezone: Literal["Asia/Shanghai"]

    @field_validator("trip_date")
    @classmethod
    def valid_calendar_date(cls, value: str) -> str:
        date.fromisoformat(value)
        return value


class JoinRoomRequest(RequestModel):
    invite_code: NonBlank
    display_name: NonBlank

    @field_validator("invite_code")
    @classmethod
    def normalize_invite_code(cls, value: str) -> str:
        return value.upper()


class TimeWindow(RequestModel):
    start: str
    end: str

    @field_validator("start", "end")
    @classmethod
    def require_offset(cls, value: str) -> str:
        if "T" not in value:
            raise ValueError("请填写带时区偏移的 ISO 8601 时间。")
        try:
            # 此时也检查该时刻能否转换成快照使用的房间时区。
            parse_time(value).astimezone(ZoneInfo("Asia/Shanghai"))
        except (ValueError, OverflowError) as exc:
            raise ValueError("请填写带时区偏移的 ISO 8601 时间。") from exc
        return value

    @field_validator("end")
    @classmethod
    def end_after_start(cls, value: str, info: ValidationInfo) -> str:
        start = info.data.get("start")
        if start is not None and parse_time(value) <= parse_time(start):
            raise ValueError("结束时间必须晚于开始时间。")
        return value


class BudgetBasis(RequestModel):
    includes_transport: Literal[True]
    scope: Literal["per_person"]
    share_rule: None = None

    @field_validator("includes_transport", mode="before")
    @classmethod
    def require_boolean_true(cls, value: object) -> object:
        # Literal[True] 会把整数 1 当作相等，接口只接受 JSON 布尔值 true。
        if value is not True:
            raise ValueError("请确认预算包含往返交通。")
        return value


class PreferencesRequest(RequestModel):
    available_windows: Annotated[list[TimeWindow], Field(min_length=1)]
    budget_cap: NonNegativeInt
    budget_basis: BudgetBasis
    allowed_transport: Annotated[list[NonBlank], Field(min_length=1)]
    taboo_tags: list[NonBlank]
    must_visit_tags: list[NonBlank] = Field(default_factory=list)
    interest_tags: list[NonBlank] = Field(default_factory=list)
    interest_weight: dict[NonBlank, NonNegativeInt] = Field(default_factory=dict)
    walk_tolerance: NonNegativeInt = 0
    declared_level: dict[NonBlank, Declaration] = Field(default_factory=dict)

    @field_validator("allowed_transport")
    @classmethod
    def require_concrete_transport(cls, values: list[str]) -> list[str]:
        normalized = normalize_transports(values)
        if any(value not in CANONICAL for value in normalized):
            raise ValueError("请选择地铁、公交、打车、步行或自行车，交通码区分大小写。")
        return normalized


class Member(BaseModel):
    member_id: str
    display_name: str
    role: RoomRole


class Membership(BaseModel):
    room_id: str
    phase: Literal["collecting"]
    member: Member
    member_token: str


class CreatedRoom(Membership):
    invite_code: str
    capacity: int


class SubmissionProgress(BaseModel):
    submitted_count: int
    required_count: int


class SavedPreferences(BaseModel):
    room_id: str
    member_id: str
    submission_status: Literal["submitted"]
    submission_progress: SubmissionProgress


class SnapshotMember(Member):
    submission_status: Literal["pending", "submitted"]


class RoomSummary(BaseModel):
    common_windows: list[TimeWindow]
    common_allowed_transport: list[str]
    min_budget_cap: int


class RoomSnapshot(BaseModel):
    room_id: str
    room_name: str
    trip_date: str
    timezone: str
    phase: Literal["collecting"]
    capacity: int
    organizer_member_id: str
    viewer_member_id: str
    members: list[SnapshotMember]
    submission_progress: SubmissionProgress
    summary: RoomSummary | None
    candidates: list[dict] = Field(default_factory=list)
    selected_plan: None = None
    locked_plan: None = None
    active_plan: None = None
    confirmation_progress: None = None
    pending_change: None = None


class ErrorDetail(BaseModel):
    code: str
    message: str
    details: dict


class ErrorResponse(BaseModel):
    error: ErrorDetail
