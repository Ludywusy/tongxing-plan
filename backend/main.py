"""FastAPI 共用房间入口，SQLite 负责保存已加入身份与提交状态。"""

import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import StringConstraints
from starlette.exceptions import HTTPException

from backend.models import (
    CreateRoomRequest, CreatedRoom, ErrorResponse, JoinRoomRequest, Membership,
    PreferencesRequest, RoomSnapshot, SavedPreferences,
)
from backend.rules_adapter import project_members, summarize_preferences
from backend.storage import RoomStore, StorageError


API_PREFIX = "/api/v0.1"
DEFAULT_DB = Path(__file__).resolve().parents[1] / "tmp" / "rooms.sqlite3"
IdempotencyKey = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=128),
    Header(alias="Idempotency-Key"),
]
bearer = HTTPBearer(auto_error=False, scheme_name="MemberToken")


def require_member_token(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> str:
    if credentials is None or not credentials.credentials or len(credentials.credentials) > 256:
        raise StorageError(401, "MEMBER_TOKEN_INVALID", "请提供有效的房间成员凭证。")
    return credentials.credentials


def get_store(request: Request) -> RoomStore:
    return request.app.state.room_store


def error_response(status: int, code: str, message: str, details: dict | None = None) -> JSONResponse:
    headers = {"WWW-Authenticate": "Bearer"} if status == 401 else {}
    if code == "STORAGE_BUSY":
        headers["Retry-After"] = "1"
    return JSONResponse(
        status_code=status, headers=headers,
        content={"error": {"code": code, "message": message, "details": details or {}}},
    )


def validation_field(error: dict) -> dict[str, str]:
    source, *parts = error["loc"]
    field = ".".join(str(part) for part in parts) if parts else str(source)
    kind = error["type"]
    if kind == "json_invalid":
        return {"field": "body", "message": "请发送有效的 JSON 内容。"}
    if source == "header" and field.lower() == "idempotency-key":
        return {"field": "Idempotency-Key", "message": "请提供 1–128 字符的操作重试键。"}

    if kind == "extra_forbidden":
        message = "此字段不允许由客户端传入。"
    elif field == "allowed_transport":
        message = "请至少选择一种可接受的交通方式。"
    elif field == "taboo_tags":
        message = "请填写禁忌标签。明确没有禁忌时请传空列表。"
    elif field == "budget_cap":
        message = "请填写非负整数分的个人预算。"
    elif field == "budget_basis" or field.startswith("budget_basis."):
        message = "请使用含往返交通的个人预算口径。"
    elif kind == "value_error" and field.startswith("available_windows."):
        message = str(error["ctx"]["error"])
    elif field == "available_windows":
        message = "请填写至少一段带时区的可用时间。"
    elif field == "trip_date":
        message = "请填写有效日期，格式为 YYYY-MM-DD。"
    elif kind == "missing":
        message = "请填写此字段。"
    else:
        message = "字段格式或取值不正确。"
    return {"field": field, "message": message}


def public_snapshot(state: dict) -> dict:
    roster = state["members"]
    submitted = project_members(roster)
    # 公开对象只列成员身份和提交标记。整个偏好表留在存储层。
    return {
        "room_id": state["room_id"],
        "room_name": state["room_name"],
        "trip_date": state["trip_date"],
        "timezone": state["timezone"],
        "phase": state["phase"],
        "capacity": state["capacity"],
        "organizer_member_id": state["organizer_member_id"],
        "viewer_member_id": state["viewer_member_id"],
        "members": [
            {"member_id": member["member_id"], "display_name": member["display_name"],
             "role": member["role"], "submission_status":
                 "submitted" if member["preferences"] is not None else "pending"}
            for member in roster
        ],
        "submission_progress": {"submitted_count": len(submitted), "required_count": state["capacity"]},
        "summary": (summarize_preferences(submitted, state["timezone"])
                    if len(submitted) == state["capacity"] else None),
    }


def create_app(db_path: str | Path | None = None) -> FastAPI:
    """测试可传独立文件路径。正常启动从 TONGXING_ROOM_DB 读取空间。"""
    path = Path(db_path if db_path is not None else os.environ.get("TONGXING_ROOM_DB", DEFAULT_DB))

    @asynccontextmanager
    async def lifespan(application: FastAPI):
        application.state.room_store = RoomStore(path)
        yield

    application = FastAPI(
        title="同行计划共享房间", version="0.1", lifespan=lifespan,
        responses={422: {"model": ErrorResponse, "description": "请求字段缺失或无效"}},
    )

    @application.exception_handler(StorageError)
    async def storage_error(_request: Request, exc: StorageError) -> JSONResponse:
        return error_response(exc.status_code, exc.code, exc.message, exc.details)

    @application.exception_handler(RequestValidationError)
    async def request_error(_request: Request, exc: RequestValidationError) -> JSONResponse:
        fields = [validation_field(error) for error in exc.errors()]
        return error_response(422, "INVALID_INPUT", "请核对请求字段后重新提交。", {"fields": fields})

    @application.exception_handler(HTTPException)
    async def routing_error(_request: Request, exc: HTTPException) -> JSONResponse:
        if exc.status_code == 404:
            return error_response(404, "ROUTE_NOT_FOUND", "该接口尚未开放或地址有误。")
        if exc.status_code == 405:
            response = error_response(405, "METHOD_NOT_ALLOWED", "该接口不支持此操作方式。")
            if exc.headers:
                response.headers.update(exc.headers)
            return response
        return error_response(exc.status_code, "HTTP_ERROR", "请求未完成。")

    @application.post(f"{API_PREFIX}/rooms", status_code=201, response_model=CreatedRoom)
    def create_room(payload: CreateRoomRequest, key: IdempotencyKey,
                    store: Annotated[RoomStore, Depends(get_store)]) -> dict:
        return store.create_room(payload.model_dump(mode="json"), key)

    @application.post(f"{API_PREFIX}/rooms/join", status_code=201, response_model=Membership)
    def join_room(payload: JoinRoomRequest, key: IdempotencyKey,
                  store: Annotated[RoomStore, Depends(get_store)]) -> dict:
        return store.join_room(payload.model_dump(mode="json"), key)

    @application.put(f"{API_PREFIX}/rooms/{{room_id}}/preferences/me", response_model=SavedPreferences)
    def save_preferences(room_id: str, payload: PreferencesRequest,
                         token: Annotated[str, Depends(require_member_token)],
                         store: Annotated[RoomStore, Depends(get_store)]) -> dict:
        return store.save_preferences(room_id, token, payload.model_dump(mode="json", exclude_unset=True))

    @application.get(f"{API_PREFIX}/rooms/{{room_id}}", response_model=RoomSnapshot)
    def get_snapshot(room_id: str, token: Annotated[str, Depends(require_member_token)],
                     store: Annotated[RoomStore, Depends(get_store)]) -> dict:
        return public_snapshot(store.get_snapshot(room_id, token))

    return application


app = create_app()
