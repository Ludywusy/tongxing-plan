# 《同行计划》周二状态机交接

这份文档保留周二快照。本轮已接入共享样例、实际检测器及降雨变更，当前的页面状态和接口请看[共享样例和状态约定](decisions.md)与 [API 契约](api-contract.md)。

本周演示以四名成员、一个发起人为例。发起人默认是初始化名单中的第一人。C 可按下表接原型，B 的检测器入参与附加输出字段留待联调确认。周二使用带模拟标记的固定检测结果，当前检出尚未接入 B 的实际检测器。

## 给 C 的状态和按钮

| `TripPhase.value` | 页面反馈 | 成员可操作 | 发起人可操作 |
| --- | --- | --- | --- |
| `collecting` | 按 `pending_member_ids` 显示待提交成员 | 提交或更新自己的资料 | 全员提交后发布候选 |
| `candidates` | 用 `candidate_id` 将 `candidate_results` 与 C 的共享样例卡片关联。只有 `feasible` 可选 | 查看候选和冲突或缺项说明 | 选择可行候选，或返回填报。结果为空或全被拦截时显示补填入口 |
| `confirming`，`locked_plan` 为空 | 显示 `selected_plan` 的候选、版本和已确认人数 | 确认当前版本，已确认者显示其结果 | 可作为成员确认、改选或返回填报。开始行程不可用 |
| `confirming`，`locked_plan` 存在 | 显示 4/4、已锁定的候选和版本 | 查看自己的确认结果 | 开始行程。执行前仍可改选或返回填报 |
| `executing` | 显示已锁定的行程和确认记录 | 查看行程 | 查看行程 |

| 按钮 | 状态机调用与反馈 |
| --- | --- |
| 提交资料 | `submit_member(member_id, submission)`，同一成员再次提交会更新资料。 |
| 发布候选 | `open_candidates(results, actor_id=...)`，发起人提交整组检测结果。 |
| 选择或改选 | `select_candidate(actor_id, candidate_id)` 返回 `PlanRef(candidate_id, version)`。首选生成 `v1`，改选生成新版本并清空旧确认和锁定。选中同一个当前候选会返回原版本。 |
| 确认 | `confirm_candidate(member_id, candidate_id, version)`。界面使用当前 `selected_plan`，从 `confirmed_member_ids` 读取进度。四人确认同一版本即锁定。已接受的同版本确认可安全重试，执行后重试也返回 `False` 并保留原记录。 |
| 开始行程 | `start_trip(actor_id, candidate_id, version)`，传入当前 `locked_plan` 的候选和版本。旧版本、确认不足或操作者并非发起人时，展示拒绝原因。 |
| 返回填报 | `return_to_collection(actor_id)`，保存成员已填资料，清空候选和确认。再次发布并选中后产生新版本。 |

事件可从 `events` 读取，包含 `event`、`from_phase`、`to_phase`、`actor_id`、`at`、`plan_version`、`candidate_id` 和 `reason`。成功操作的 `reason` 为 `None`，拒绝操作记录原因，重复确认不新增事件。

## 给 B 的可行性接口草案

检测端读取 `state.member_submissions` 的副本和 C 的共享样例 `fixtures/demo-trip.json` 中的完整候选，按候选返回一组结果。A 在全员提交后通过 `open_candidates()` 接收结果，按候选 ID 排序供 C 使用。

调用方需用本次提交的资料和同一批候选检测，资料或方案内容有变化时，先返回填报再重新检测、发布。`fixture_version` 与 `input_fingerprint` 的自动核对留待联调。

| 字段 | A 接收约定 |
| --- | --- |
| `candidate_id` | 必填、非空、同批唯一。与 C 样例候选卡使用同一 ID。 |
| `status` | 必填。`feasible` 可进入确认，`infeasible` 卡片可见且可展开冲突说明，`incomplete` 提示缺项并允许返回补填。后两类都不可进入确认。 |
| `reasons` | A 保留 B 的原始结果。冲突原因拟含规则 ID、成员 ID、字段、实际值、阈值和说明。金额用整数分。 |
| `missing_fields` | A 保留 B 的原始结果。`incomplete` 拟按成员和字段返回缺项，`reasons` 为空。 |
| `fixture_version`、`input_fingerprint` | B 可随结果返回，A 原样保留。状态机单独管理 `v1`、`v2` 等确认版本。 |

周二固定样例中，`c01` 为 `infeasible`，原因是 `m01` 承担 8100 分、上限 8000 分。`c02` 和 `c03` 标为 `feasible`，演示选择 `c02`。待 B/C 对齐真实检测器调用入口和共享样例字段后，改用检测输出执行同一流程。
