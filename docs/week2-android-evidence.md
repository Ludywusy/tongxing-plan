# 第二周 Android 构建与回归证据

2026-11-27。此记录对应 App `0.2.0+2` 调试包。源码及文档位于 `codex/week2-flutter-rooms` 分支；安装包通过 [GitHub 预发布 android-v0.2.0-w2](https://github.com/Ludywusy/tongxing-plan/releases/tag/android-v0.2.0-w2) 提供，不把 APK 写入 Git 历史。

## 安装包定位

| 项目 | 实际结果 |
| --- | --- |
| 构建源码提交 | `3efab7ff40e1485f17ca26d53ea5ca7b3e249565` |
| 上游基线 | `ab46664f86106ab32d6896c69f6242c0d8f6407b` |
| 资产文件名 | `tongxing-plan-0.2.0+2-debug.apk` |
| 包标识 | `cn.edu.lzu.tongxing_plan` |
| 版本 | versionName `0.2.0` / versionCode `2` |
| 大小 | 94,964,151 字节（约 90.57 MiB） |
| APK SHA-256 | `5D43A3D6E758CD81F3C1254FDDAFFE3572CF720D2F7161D6DC3371FE388DE620` |
| Android | minSdk 21 / targetSdk 35 / compileSdk 35 |
| 签名 | Android Debug；apksigner 验证通过，v1/v2 为 true |
| 签名证书 SHA-256 | `a8bcd334d758b0b5e1d7f852d535ffa953188557cf7ca316fa694613cf4728a4` |

文件可按同目录 [SHA-256 校验文件](evidence/week2/tongxing-plan-0.2.0+2-debug.apk.sha256) 检查。后续仅补交付文档与原始日志的提交不会改变此包；重建请检出上表的构建源码提交。

## 构建与检查

在干净上游副本运行，使用 Flutter 3.32.8、Dart 3.8.1、JDK 17、Android platform/build-tools 35、NDK 27.0.12077973、Gradle 8.12、AGP 8.7.3。Windows 中文目录通过构建脚本暂存到 ASCII 目录。

| 命令或检查 | 退出状态与结果 | 日志 |
| --- | --- | --- |
| `flutter pub get` | 0，锁文件解析成功 | [依赖](evidence/week2/flutter-pub-get.txt) |
| `flutter analyze` | 0，No issues found | [静态分析](evidence/week2/flutter-analyze.txt) |
| `flutter test --reporter expanded` | 0，19 通过，1 跳过（需主动启用真实 HTTP） | [Flutter](evidence/week2/flutter-test.txt) |
| 真实 HTTP 单独测试，命令见下方 | 0，1 通过 | [HTTP](evidence/week2/flutter-live-http.txt) |
| `.venv/Scripts/python.exe -m unittest discover -s tests -p test_*.py -v` | 0，24 通过 | [状态与接口](evidence/week2/python-state-api.txt) |
| `.venv/Scripts/python.exe -m unittest discover -s algorithm -p test_*.py -v` | 0，7 通过，含固定 22 案例回归 | [算法](evidence/week2/python-algorithm.txt) |
| `.venv/Scripts/python.exe -m scripts.demo_trip_flow` | 0 | [演示流程](evidence/week2/python-demo.txt) |
| `./tools/build-apk.ps1 -StageRoot C:/Users/Administrator/AppData/Local/Temp/tongxing-w2-020-build` | 0，assembleDebug 成功 | [构建](evidence/week2/android-build.txt) |
| `aapt dump badging <APK>` | 0，包名、版本与 SDK 如上 | [包元数据](evidence/week2/apk-badging.txt) |
| `apksigner verify --verbose --print-certs <APK>` | 0，Verifies；完整工具警告保留于日志 | [签名](evidence/week2/apk-signature.txt) |
| Python zipfile + hashlib 核对样例 | 0，源文件、App 资产与 APK 内文件三端一致 | [内容核验](evidence/week2/apk-content.json) |
| `git diff --exit-code HEAD -- mobile`（构建后） | 0，受控客户端源码未被构建修改 | 本表记录 |

真实 HTTP 测试在 `mobile/` 单独执行：

```powershell
flutter test test/live_room_api_test.dart --reporter expanded `
  --dart-define=ROOM_REPO_ROOT=C:/Users/Administrator/AppData/Local/Temp/tongxing-plan-upstream `
  --dart-define=ROOM_PYTHON=C:/Users/Administrator/AppData/Local/Temp/tongxing-plan-upstream/.venv/Scripts/python.exe
```

它启动真实 FastAPI HTTP 服务和临时 SQLite，使用四个独立成员凭证验证四接口、1/4 至 4/4、重复保存、非法输入、bike/bicycle 交集，并停止/重启服务验证原身份与快照。结束后清理临时服务与数据库。

## 样例一致性

| 固定版本 | 源 → 资产 → APK 路径 | 三端 SHA-256 |
| --- | --- | --- |
| 1.1 回归 | `fixtures/demo-trip.json` → `mobile/assets/demo-trip-1.1.json` → `assets/flutter_assets/assets/demo-trip-1.1.json` | `20C5AFB0A1E1EFA53B00A17C71BF03A713B74E605F75C772D2D5E3F657A551BA` |
| 1.2 离线扩展 | `fixtures/demo-trip-1.2.json` → `mobile/assets/demo-trip.json` → `assets/flutter_assets/assets/demo-trip.json` | `6D7B21D5CE0BBEC403D08CC6EDE0608A760F0F2A1CDEA1E319A03FA59FC4B195` |

1.1 上游固定样例未修改。1.2 独立归档及换行规范化说明见 [Android 交付](week2-android.md)。

## 尚需设备复验

[flutter doctor](evidence/week2/flutter-doctor.txt) 显示 Android 工具链可用，但 SDK 为本机 user-branch 且不在 PATH，未安装 Android Studio；构建使用上述绝对路径，APK 已成功生成。[adb 设备清单](evidence/week2/adb-devices.txt) 没有 Android 手机或模拟器。

因此自动化四客户端不能记为四台真机通过。干净安装、冷启动、飞行模式、四机进度与断网恢复、非上海时区下 `13:00+08:00` 与 `05:00Z` 均显示 13:00，继续按 [四机记录](week2-four-device-test.md) 验收；D 的正式题干与导出口径仍待 D 回签。
