# 《同行计划》FastAPI 接口契约 v0.1

本契约供 Flutter Android、FastAPI 服务和 B 的 Python 检测器对接。第一周在一台真机上用本地固定样例模拟四个成员，可断网演示；本文的 HTTP 路由本周只定义契约。第二周先实现前四项、房间数据持久化及四台 Android 手机联调。候选、确认和变更接口随后接入，并重新验证版本冲突。

## 1. 通用约定

- 基址为 `/api/v0.1`，请求和响应均用 JSON。下面的时间、金额、成员、候选和节点对应 [共享演示样例](../fixtures/demo-trip.json)。示例房间为 `r-demo`，样例邀请码和成员凭证只用于说明格式。
- 建房发放发起人身份 `m01`；同一邀请码给另外三台手机各分配一个独立身份 `m02`–`m04`。服务端以 `Authorization: Bearer <member_token>` 识别房间成员。邀请码只用于加入，显示名只用于展示，请求体不得传入 `member_id`、`actor_id` 或角色来指定操作者。客户端应保存本机凭证，禁止在界面或日志展示。
- `organizer` 也是组内成员，同样要提交个人偏好和确认所选版本。每个成员可改自己的偏好、读取房间快照及确认自己的当前版本。仅发起人可发布候选、选或改选、返回补填、开始行程及处理降雨变更。服务端检查所有权限和阶段。
- 成员、候选、节点 ID 均按字符串处理，稳定且不复用；成员 ID 在房间内唯一。金额均为人民币整数分，例如 `6400` 为 64 元。时间用带偏移的 ISO 8601，例如 `2026-11-21T13:30:00+08:00`，房间时区为 `Asia/Shanghai`。时间窗的开始必须早于结束。
- HTTP 成功返回下列业务对象；所有失败使用第 5 节的 `error` 结构。快照通过 GET 读取。App 在成功写入后以及重进房间时刷新；四机验收可手动刷新，不依赖实时推送。

## 2. 首批六项操作

| 操作 | 方法与路径（省略基址） | 谁可以操作 |
| --- | --- | --- |
| 建房 | `POST /rooms` | 新发起人 |
| 加入 | `POST /rooms/join` | 持有效邀请码的设备 |
| 保存个人偏好 | `PUT /rooms/{room_id}/preferences/me` | 房间成员本人 |
| 读取房间快照 | `GET /rooms/{room_id}` | 房间成员 |
| 选择候选 | `POST /rooms/{room_id}/selection` | 发起人 |
| 确认同一版本 | `POST /rooms/{room_id}/confirmations` | 房间成员本人 |

### 2.1 建房

`POST /rooms`，无需成员凭证。建房后进入 `collecting`，四人容量固定，发起人占一个名额。建房和加入均带 `Idempotency-Key`（每次新操作生成随机值）；超时后同一设备带原键和原请求重试，服务端返回原结果，避免重复建房或多占一个成员名额。原键配不同请求返回 `409 IDEMPOTENCY_CONFLICT`。

请求：

```json
{
  "room_name": "周六兰州半日游",
  "display_name": "甲",
  "trip_date": "2026-11-21",
  "timezone": "Asia/Shanghai"
}
```

`201 Created`：

```json
{
  "room_id": "r-demo",
  "invite_code": "DEMO42",
  "phase": "collecting",
  "capacity": 4,
  "member": { "member_id": "m01", "display_name": "甲", "role": "organizer" },
  "member_token": "example-token-m01"
}
```

### 2.2 加入

`POST /rooms/join`，无需成员凭证。仅在收集阶段且有剩余名额时允许加入，加入后用返回的房间 ID 和本机成员凭证读取快照。

请求：

```json
{ "invite_code": "DEMO42", "display_name": "乙" }
```

`201 Created`：

```json
{
  "room_id": "r-demo",
  "phase": "collecting",
  "member": { "member_id": "m02", "display_name": "乙", "role": "member" },
  "member_token": "example-token-m02"
}
```

### 2.3 保存个人偏好

`PUT /rooms/r-demo/preferences/me`。只在 `collecting` 允许提交，按房间和凭证对应身份保存整份表单。同一成员再次保存覆盖旧值，不增加已提交人数；请求成功即标记该成员已提交。校验失败保留上一次有效提交。以下为甲的完整样例。

请求：

```json
{
  "available_windows": [
    { "start": "2026-11-21T13:00:00+08:00", "end": "2026-11-21T17:30:00+08:00" }
  ],
  "budget_cap": 8000,
  "budget_basis": { "includes_transport": true, "scope": "per_person", "share_rule": null },
  "allowed_transport": ["metro", "walk"],
  "taboo_tags": [],
  "must_visit_tags": [],
  "interest_tags": ["photo"],
  "interest_weight": { "photo": 3 },
  "walk_tolerance": 3000,
  "declared_level": {
    "must_return_by": "must",
    "budget_cap": "must",
    "transport": "prefer",
    "must_visit": "none",
    "walk": "prefer"
  }
}
```

`200 OK`：

```json
{
  "room_id": "r-demo",
  "member_id": "m01",
  "submission_status": "submitted",
  "submission_progress": { "submitted_count": 1, "required_count": 4 }
}
```

`available_windows` 和 `allowed_transport` 至少各有一项；`taboo_tags: []` 明确表示无禁忌。字段缺失、空答或口径未定时返回 `422 INVALID_INPUT`，由 App 指向需要补填的字段。联调版仅接收含往返交通的个人预算，以便与候选的逐人总费用直接比较；按组或不含往返交通的预算待拆分和换算口径对齐后接入。`must_visit_tags`、`interest_tags`、`interest_weight`、`walk_tolerance`（米）和 `declared_level` 为可选字段，按原值存储，首版硬约束检测暂不使用它们。

### 2.4 读取房间快照

`GET /rooms/r-demo`，无请求体。下面是四人均已提交、尚未发布候选时返回的 `200 OK`。所有成员读取相同的房间进度和汇总；`viewer_member_id` 随凭证变化。未满 4/4 时 `summary` 为 `null`。`common_windows: []` 或 `common_allowed_transport: []` 表示全员已填、但对应条件无共同取值。

```json
{
  "room_id": "r-demo",
  "room_name": "周六兰州半日游",
  "trip_date": "2026-11-21",
  "timezone": "Asia/Shanghai",
  "phase": "collecting",
  "capacity": 4,
  "organizer_member_id": "m01",
  "viewer_member_id": "m01",
  "members": [
    { "member_id": "m01", "display_name": "甲", "role": "organizer", "submission_status": "submitted" },
    { "member_id": "m02", "display_name": "乙", "role": "member", "submission_status": "submitted" },
    { "member_id": "m03", "display_name": "丙", "role": "member", "submission_status": "submitted" },
    { "member_id": "m04", "display_name": "丁", "role": "member", "submission_status": "submitted" }
  ],
  "submission_progress": { "submitted_count": 4, "required_count": 4 },
  "summary": {
    "common_windows": [
      { "start": "2026-11-21T13:30:00+08:00", "end": "2026-11-21T17:00:00+08:00" }
    ],
    "common_allowed_transport": ["metro", "walk"],
    "min_budget_cap": 8000
  },
  "candidates": [],
  "selected_plan": null,
  "locked_plan": null,
  "active_plan": null,
  "confirmation_progress": null,
  "pending_change": null
}
```

- `members` 只含已入房成员，`submission_status` 为 `pending` 或 `submitted`；快照不含任何成员凭证或他人完整表单。
- `summary.min_budget_cap` 为四人含往返交通的个人预算上限中的最小值，单位为分；它供比较行程参考。候选可行性仍按每位成员的实际承担额与其本人上限验证。
- `candidates` 是已发布候选数组。每项沿用样例的 `candidate_id`、`display_name`、`window`、`cost_per_member`、`nodes`，另带完整 `rule_result`。未发布时为空数组，发布后包含通过、不通过和缺项结果。算法结果见第 4 节。
- `selected_plan`、`locked_plan` 为 `{ "candidate_id": "c02", "version": "v1" }` 或 `null`。尚未开始行程时 `active_plan` 为 `null`；开始后带同样的 `candidate_id`、`version` 以及实际执行的 `window`、`cost_per_member`、`nodes`。待变更时它仍返回原行程，`pending_change` 另带可提交的预览。
- `confirmation_progress` 未选中时为 `null`，选中后包括 `mode`、`confirmed_member_ids`、`required_count`（格式见下）。变更应用后用 `mode: "organizer_change"`、`confirmed_member_ids: []`、`required_count: 0`；App 显示“发起人已确认变更”，继续保留原版本的成员确认记录。

### 2.5 选择候选

`POST /rooms/r-demo/selection`。发起人在 `candidates` 或 `confirming` 阶段选择 `feasible` 候选。首选产生 `v1`，改选分配下一版本、清空上一版本的确认和锁定；重复选择当前候选返回当前版本和当前进度。

请求：

```json
{ "candidate_id": "c02" }
```

`200 OK`：

```json
{
  "room_id": "r-demo",
  "phase": "confirming",
  "selected_plan": { "candidate_id": "c02", "version": "v1" },
  "locked_plan": null,
  "confirmation_progress": {
    "mode": "member_confirmation",
    "confirmed_member_ids": [],
    "required_count": 4
  }
}
```

### 2.6 确认同一版本

`POST /rooms/r-demo/confirmations`。每位成员用自己的凭证提交快照里的 `candidate_id` 和 `version`。同一成员重复确认当前版本返回 `200`、`accepted_new: false`，不增加人数和事件；候选或版本已更新返回 `409 STALE_PLAN_VERSION`。最后一人确认后锁定，阶段仍为 `confirming`，等发起人开始行程。

请求（丁提交）：

```json
{ "candidate_id": "c02", "version": "v1" }
```

`200 OK`（第 4 人确认后）：

```json
{
  "room_id": "r-demo",
  "phase": "confirming",
  "selected_plan": { "candidate_id": "c02", "version": "v1" },
  "locked_plan": { "candidate_id": "c02", "version": "v1" },
  "confirmation_progress": {
    "mode": "member_confirmation",
    "confirmed_member_ids": ["m01", "m02", "m03", "m04"],
    "required_count": 4
  },
  "accepted_new": true
}
```

## 3. 预留流程与变更接口

发布候选、开始行程和补填由发起人操作，作为候选联调的配套路由。成功时均返回更新后的房间快照。

| 方法与路径（省略基址） | 请求体 | 条件和结果 |
| --- | --- | --- |
| `POST /rooms/{room_id}/candidates/publish` | `{}` | `collecting` 且已入房、已提交均为 4/4；用最新提交检测同批候选，再进入 `candidates`。 |
| `POST /rooms/{room_id}/start` | `{"candidate_id":"c02","version":"v1"}` | 该版须已有 4/4 确认且锁定；进入 `executing`。 |
| `POST /rooms/{room_id}/reopen` | `{}` | `candidates` 或 `confirming` 可退回 `collecting`；保留表单，旧候选结果和确认作废。 |

变更由发起人在 `executing` 发起。预览基于当前正在执行的版本，先找降雨窗内有正时长重叠的户外活动节点，再用 B 的检测器检查替换后的整条行程。固定演示由服务端从样例取替代，客户端只提交雨情。可行时生成唯一活动预览并进入 `change_pending`，原行程继续有效；先确认或取消当前预览，才能做下一次预览。无影响、无替代或替代检测未通过时，返回影响信息，`can_apply: false`、`preview_id: null`，继续执行原版本。预览结果的 `replacement` 无可选替代时为 `null`；无检测结果时 `rule_result` 为 `null`。

### 3.1 降雨预览

`POST /rooms/r-demo/changes/preview` 请求：

```json
{
  "base_version": "v1",
  "rain_event": {
    "event_id": "rain-01",
    "type": "rain",
    "window": { "start": "2026-11-21T14:00:00+08:00", "end": "2026-11-21T15:00:00+08:00" },
    "source": {
      "type": "simulated",
      "note": "固定演示数据",
      "retrieved_at": "2026-11-21T13:45:00+08:00"
    }
  }
}
```

`200 OK`（可行预览；`pending_change` 即响应中的 `preview` 对象）：

```json
{
  "room_id": "r-demo",
  "phase": "change_pending",
  "preview": {
    "preview_id": "p1",
    "candidate_id": "c02",
    "base_version": "v1",
    "can_apply": true,
    "rain_event": {
      "event_id": "rain-01",
      "type": "rain",
      "window": { "start": "2026-11-21T14:00:00+08:00", "end": "2026-11-21T15:00:00+08:00" },
      "source": {
        "type": "simulated",
        "note": "固定演示数据",
        "retrieved_at": "2026-11-21T13:45:00+08:00"
      }
    },
    "affected_node_ids": ["c02-n02"],
    "unchanged_node_ids": ["c02-n01", "c02-n03", "c02-n04"],
    "replacement": {
      "replaces": "c02-n02",
      "node": {
        "node_id": "c02-n02-r1",
        "start": "2026-11-21T14:00:00+08:00",
        "end": "2026-11-21T15:00:00+08:00",
        "kind": "activity",
        "place_tag": "gallery_indoor",
        "indoor": true
      },
      "cost_per_member": { "m01": 6400, "m02": 6400, "m03": 6400, "m04": 6400 }
    },
    "reason": "c02-n02 是与模拟降雨时间窗重叠的户外活动。室内替代已通过整程硬约束复检。",
    "rule_result": {
      "candidate_id": "c02",
      "fixture_version": "1.1",
      "input_fingerprint": "6f48265c",
      "status": "feasible",
      "reasons": [],
      "missing_fields": []
    }
  }
}
```

### 3.2 确认应用与取消

`POST /rooms/r-demo/changes/apply` 请求：

```json
{ "preview_id": "p1", "base_version": "v1" }
```

`200 OK`（发起人明确确认后）：

```json
{
  "room_id": "r-demo",
  "phase": "executing",
  "applied_plan": { "candidate_id": "c02", "version": "v2" },
  "replaced_node_ids": ["c02-n02"],
  "replacement_node_ids": ["c02-n02-r1"],
  "pending_change": null
}
```

`POST /rooms/r-demo/changes/cancel` 接受同一个请求结构，成功返回 `200 OK`：

```json
{
  "room_id": "r-demo",
  "phase": "executing",
  "retained_plan": { "candidate_id": "c02", "version": "v1" },
  "pending_change": null
}
```

应用前，服务端检查 `base_version` 仍为当前版本、`preview_id` 仍待确认且替代可行，然后将替换记录到新版本并保留未受影响节点。原候选和 v1 确认事件保持原样，v2 另记发起人授权及变更事件。取消不产生新版本；取消、应用或被其他更新作废后，同一预览不可再使用。任一路径发生冲突时，App 刷新快照，再按当前版本预览。

## 4. B 的候选结果

服务端用房间四人的最新提交和同批候选运行 B 的检测器，保留原始六字段。可行性 `status` 有三种：`feasible` 可选；`infeasible` 展示 `reasons`；`incomplete` 展示 `missing_fields` 并引导补填。缺项优先于硬冲突，原因和缺项数组可为空。相邻或重叠的同一人时间窗先合并，多人交集只保留正时长；活动时间必须完整落入某一共同窗。

例如，`candidates` 中 `c01` 的 `rule_result`：

```json
{
  "candidate_id": "c01",
  "fixture_version": "1.1",
  "input_fingerprint": "dec2d3c4",
  "status": "infeasible",
  "reasons": [
    {
      "rule_id": "R-BUD-01",
      "member_ids": ["m01"],
      "field": "cost_per_member.m01",
      "actual": 8100,
      "threshold": 8000,
      "message": "m01 承担 81 元，超过上限 80 元 1 元"
    }
  ],
  "missing_fields": []
}
```

`reasons` 中的 `actual`、`threshold` 随规则返回，客户端允许省略；金额仍以分为单位。`missing_fields` 的每项含 `member_id`（行程级缺项为 `null`）、`field` 和 `rule_id`，例如 `{"member_id":"m01","field":"budget_basis","rule_id":"R-DATA-02"}`。`input_fingerprint` 由 B 生成，以上为示例值；它标识检测输入，`fixture_version` 标识共享样例格式，只有状态机的 `version` 用于确认或应用变更。

降雨替代保存在行程版本的覆盖记录中。服务端展开节点、重算全程窗及逐人费用，再把完整行程交给同一个检测器（`detect_resolved`）。只有该结果为 `feasible` 的预览才能应用。

## 5. 错误与重试

错误对象包含稳定的 `code`、可展示的 `message` 和结构化 `details`（无信息时为 `{}`）。FastAPI 校验错误也映射到这个结构。客户端按 `code` 分支处理。

| HTTP | `code` | App 处理 |
| --- | --- | --- |
| 401 | `MEMBER_TOKEN_INVALID` | 缺少或无法识别凭证，提示恢复当前身份或联系发起人。 |
| 403 | `FORBIDDEN` | 凭证属于其他房间，或成员没有该动作权限；提示由正确成员或发起人操作。 |
| 404 | `ROOM_NOT_FOUND` / `INVITE_NOT_FOUND` / `CANDIDATE_NOT_FOUND` | 房间、邀请码或候选不存在；检查邀请码或刷新房间。 |
| 409 | `ROOM_FULL` / `INVALID_PHASE` / `MEMBERS_PENDING` / `CONFIRMATIONS_PENDING` | 提示实际阶段、人数或缺少确认，刷新进度。 |
| 409 | `CANDIDATE_NOT_FEASIBLE` | 展示检测详情，换方案或请发起人退回补填。 |
| 409 | `STALE_PLAN_VERSION` / `PREVIEW_INACTIVE` | 刷新当前版本，重新阅读并确认；变更需重新预览。 |
| 409 | `IDEMPOTENCY_CONFLICT` | 原幂等键与不同请求冲突；确认建立新操作后使用新键。 |
| 422 | `INVALID_INPUT` | 使用 `details.fields` 中的 `field` 和 `message` 定位表单错误，修正后可重试。例如 `{"fields":[{"field":"allowed_transport","message":"请至少选择一种可接受的交通方式。"}]}`。 |

例如，请求确认已过期的 `c02/v1`：

```json
{
  "error": {
    "code": "STALE_PLAN_VERSION",
    "message": "计划已经更新，请刷新房间后查看当前版本。",
    "details": {
      "requested": { "candidate_id": "c02", "version": "v1" },
      "current": { "candidate_id": "c02", "version": "v2" }
    }
  }
}
```

网络中断或 5xx 时保留本地表单，显示重试。建房、加入携原键重试；个人偏好可按原内容重发；版本敏感操作先刷新房间再决定是否重发。第二周最小验收：四台手机各持一份独立成员凭证，重试加入不会占用新名额，四人各提交后都能看到相同的 4/4 和汇总，成员重新提交时计数仍为 4/4，越权请求被拒绝。
