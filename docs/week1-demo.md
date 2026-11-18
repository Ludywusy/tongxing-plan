# 《同行计划》第一周演示与联验

首周有两项独立验收。C 在一台 Android 真机干净安装调试 APK，打开飞行模式后冷启动，用四个本地身份完成主线。A/B 在干净检出独立复跑 Python 测试及脚本，以同一份合成样例对照候选、预算冲突、版本和变更节点。

## 四分钟演示

| 用时 | 操作与核验 |
| --- | --- |
| 40 秒 | 在群组和偏好页切换 `m01` 至 `m04` 并提交。指出 `c01` 上 `m01` 的个人费用 81 元和预算上限 80 元。 |
| 55 秒 | 比较三张模拟候选卡，查看逐人费用、行程、来源与冲突说明。选中可行的 `c02`。 |
| 40 秒 | 四人确认同一 `c02/v1`。发起人查看 4/4 再开始执行。 |
| 65 秒 | 触发 11 月 21 日 13:45 的模拟降雨。雨窗为北京时间 14:00–15:00，命中 `c02-n02`。预览替换为 `c02-n02-r1`，指出三个保留节点。取消后重开预览，由发起人确认生成 `v2`。 |
| 40 秒 | 核对 `v1` 的四次成员确认和 `v2` 的一次发起人变更确认。在 Android 展示模拟分享及二次确认入口。 |

彩排前额外跑缺项、无替代或替代不合格、取消预览及过期确认。替代失败或取消时保留 `v1`，过期确认拒绝更新，合法替换只更新目标节点。雨窗与节点仅在端点相接时没有正时长重叠。

## Python 复跑

在仓库根目录执行。共享输入为 `fixtures/demo-trip.json`，天气事件和替代读取其中的 `rain_event`、`rain_replacement`。

```powershell
python -m unittest discover -s algorithm -p "test_*.py"
python -m unittest discover -s tests -p "test_trip_flow.py"
python -m scripts.demo_trip_flow
```

记录干净检出的提交、Python 版本、两组实际运行用例数和失败数、脚本输出。连续两次脚本需给出相同的输出顺序和结果。若用固定模拟检测结果，记录与实际检测器的接入状态。

本轮将待提交的源码复制到独立目录复跑。用 Python 3.13.9 和共享样例 1.1，通过 B 的 10 项测试（含 19 条固定用例）和 A 的 12 项状态、变更测试。使用 B 的实际检测器，演示连续运行两次输出相同。关键输出：`c01` 被拦截（`m01` 承担 8100 分、上限 8000 分），取消降雨预览后保留 `c02/v1`，发起人确认后生效为 `c02/v2`。

## Android 构建与离线操作

以下步骤在 C 的 `mobile/` 项目和 Android 工具链齐备后执行。仓库根目录同步样例，确认 `pubspec.yaml` 已声明资产。两个文件的哈希应相同。

```powershell
Copy-Item -LiteralPath fixtures/demo-trip.json -Destination mobile/assets/demo-trip.json
Get-FileHash -LiteralPath fixtures/demo-trip.json, mobile/assets/demo-trip.json
Set-Location -LiteralPath mobile
flutter doctor -v
flutter devices
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

批准 USB 调试后，在从未安装此应用的 Android 真机安装调试 APK，或在验收机移除旧调试版后重新安装。默认 APK 路径为 `mobile/build/app/outputs/flutter-apk/app-debug.apk`，实际安装来源由 C 登记。打开飞行模式，核对 Wi-Fi 和移动数据均已断开，再冷启动。四人使用同一设备内的四个本地身份依次完成四页流程。保留安装及关键页面证据，核对 `c01` 的冲突与 `c02-n02` 的变化对应 Python 输出。在线与离线入口集中登记到 [原型与离线资料](prototype.md)。

## 验收登记

| 条目 | 当前证据与结果 | 补齐人与复验 |
| --- | --- | --- |
| Python 主线及降雨 | 本地独立目录通过。工作基线为 `803fce6`，包含本轮待提交修改；最终提交的干净检出待登记 | A/B 在提交后按上方命令复跑并登记提交号 |
| Flutter 静态分析、组件测试、构建 | 待 C 提供 `mobile/` 构建日志和 APK 路径 | C 记录命令、工具版本、构建提交和产物 |
| Android 真机干净安装与飞行模式四身份 | 待真机和 APK 联验。当前缺设备型号、Android 版本、安装及断网操作证据 | C 提供设备和 APK，A 试跑，D 组织独立走查。样例、APK 和日志对应同一验收提交 |
| 调研与竞品 | 待 D 提供有效答卷、独立案例、证据索引、竞品观察和试用记录 | D 交付汇总，A 核对需求编号及分母，B 复算预算 |
| 四分钟彩排及签收 | 待登记演练耗时、通过或待补项、责任人和证据 | A/B/C/D 核对后签收，C 给通过提交加 `week1-review` 标签 |
