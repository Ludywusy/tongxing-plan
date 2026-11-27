# 第二周 Android 交付

交付日期 2026-11-27，C 维护。App `0.2.0+2`，包标识 `cn.edu.lzu.tongxing_plan`。安装包与精确源码提交、大小、SHA-256、构建命令及输出见 [构建证据](week2-android-evidence.md)。本周发布位置为仓库 Releases 中 `android-v0.2.0-w2` 预发布，资产名 `tongxing-plan-0.2.0+2-debug.apk`。源码位于 `codex/week2-flutter-rooms` 分支及对应 PR。

## 已实现范围

- 联机入口支持创建房间、邀请码加入、本人完整偏好保存、手动读取快照。各机只带自己的 Bearer 凭证，不发送 member_id 或 actor_id 作为操作者。
- 本机保存房间身份、服务地址、待确认的建房/加入原请求和幂等键；断网恢复或重开页面可继续重试。同一身份锁定原服务地址。Android 关闭应用备份，避免把房间身份同步到其他设备。清除本机凭证不会删除服务端成员或释放名额。
- 可编辑表单保留失败输入；提交前把本人完整表单存在应用私有存储，重开 App 恢复上次尝试，不把快照汇总当个人输入。尚未按提交保存的编辑仅在当前页面保留。首次联网时主动选择交通并明确有无禁忌。
- 快照展示成员身份、进度、状态、共同窗、共同交通和最低个人预算。未收齐时显示等待；已收齐但交集为空时明确无共同条件。失败刷新保留并标记上次快照可能过期。
- 时间统一 Asia/Shanghai，包括跨天选时、UTC 等价时间、确认/变更时间；金额精确转为整数分，含个人往返交通。旧交通 bike 归一为 bicycle，后端历史数据和检测器使用同表。见[口径更新](week2-decisions-C.md)。
- 离线四个身份保留原流程、扩展兴趣、自定义交通及可选雨天替代。显示样例 1.2 与模拟标记；确认记录保留人、时间及版本，变更关联唯一预览、基线和操作者，过期拒绝。联机只接五个正式交通码，不把自定义文字猜成正式码。

联机服务目前只提供 collecting 阶段四接口；候选发布、投票、同版本确认、降雨变更的在线流程尚未开放。B 的独立规划基线仍按任务书做硬过滤后的软偏好排序；本次不是评分验收。

## 服务与安装

由 A 在同一电脑启动持久化服务，四台手机和电脑接入可互通 Wi-Fi。先按[服务说明](week2-backend-run.md)安装 Python 依赖，再在仓库根目录运行：

```powershell
$env:TONGXING_ROOM_DB = Join-Path $PWD 'tmp/rooms-local-test.sqlite3'
.venv/Scripts/python.exe -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
```

从 `ipconfig` 获取电脑 Wi-Fi IPv4，手机浏览器先访问 `http://<电脑IP>:8000/docs`。在 App 服务地址填 `http://<电脑IP>:8000/api/v0.1`，四台使用同一地址。手机的 127.0.0.1 是手机本身。服务重启须保持相同地址和数据库文件，随后用原身份刷新；不要清库后把身份失效归为客户端恢复成功。

此包为调试签名；仅 debug manifest 允许局域网 HTTP。正式发布应使用 HTTPS 和正式签名，本次不提供商店发行包。设备开启 USB 调试后：

```powershell
adb install -r 'tongxing-plan-0.2.0+2-debug.apk'
```

首次干净安装可选一台此前未装此应用的验收机。若确需卸载旧版，卸载会丢失本机凭证和保存表单，先记录该影响；不默认卸载已在使用的身份。安装后冷启动，分别进入离线和联机，离线可飞行模式完整体验。服务连接失败时核对 IP、监听、端口和 Wi-Fi 隔离。

## 可重建与数据版本

已固定 Flutter 3.32.8、Dart 3.8.1、Android SDK/platform/build-tools 35、JDK 17、Gradle 8.12、AGP 8.7.3。依赖锁文件、Gradle wrapper 与源码一同提交。SDK 不在 PATH 时可传绝对路径；Windows 中文路径用 `tools/build-apk.ps1` 暂存到 ASCII 目录。

```powershell
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

| 版本 | 源文件 → App 资产 | SHA-256（两端一致） |
| --- | --- | --- |
| 1.1 固定回归 | fixtures/demo-trip.json → mobile/assets/demo-trip-1.1.json | 20C5AFB0A1E1EFA53B00A17C71BF03A713B74E605F75C772D2D5E3F657A551BA |
| 1.2 扩展离线 | fixtures/demo-trip-1.2.json → mobile/assets/demo-trip.json | 6D7B21D5CE0BBEC403D08CC6EDE0608A760F0F2A1CDEA1E319A03FA59FC4B195 |

1.1 保持上游文件不变。1.2 增加自定义交通、兴趣/禁忌扩展及多种室内替代，schema 归档为 schemas/trip-input-1.2.schema.json，不替换 1.1 的回归入口。收到的 1.2 原文件使用 CRLF，原 SHA-256 为 FA4A434B2360FEB5A3616A321D55038BE87F71FED4E0B65F9F1E482C3660A9A0；本次按仓库规则统一为 LF，JSON 内容不变，源与 App 资产均使用表内新哈希。来源与更新时间沿用每条 source 的 simulated 标记，日期为固定的 2026-11-21，不能展示成今日实时价格、营业或天气。未知 POI 属性应等待 D 补充，当前未接真实 POI 服务。

## 自动化与真机边界

自动化覆盖固定 1.1 结果、1.2 四身份全流程、模式切换、上海时间、bike 兼容、整数分、本人凭证、网络重试原键、字段错误、重复保存、表单恢复、空汇总和过期预览。跨栈测试启动真实 HTTP 服务与临时 SQLite 数据库，四个独立客户端运行四接口、进度及汇总，并停止/重启服务验证身份回放和快照不变。

当前 adb 没有连接 Android 手机或模拟器。自动化四客户端不等于四台手机；Windows/Chrome/Edge 的设备列表也不算 Android 设备。

| 待复验 | 负责人及条件 | 状态 |
| --- | --- | --- |
| 新包干净安装、冷启动、飞行模式离线 | C：提供 Android 真机，记录型号/系统/APK 哈希及模式截图 | 待验证 |
| 四机从 1/4 到 4/4、跨机重复保存、最终快照一致 | A/C：四台独立 Android 真机与同一服务；按[四机记录](week2-four-device-test.md)登记 | 待验证 |
| 四机断网、重开 App、服务正常重启后原身份恢复 | A/C：保持同一 SQLite 和地址，用新包实测 | 待验证 |
| 手机设非上海时区，两种时间都显示 13:00 | C：调整验收机时区后复验偏好、快照和确认记录 | 待验证 |
| D 问卷正式题干与导出 | D：确认“都行”“无”及空答含义，对照正式交通码表 | 待回签 |

截图请标 App 版本、数据版本、模式、设备、时区与操作时间，遮盖成员 token；数据库、凭证、原始问卷与运行缓存不入库。
