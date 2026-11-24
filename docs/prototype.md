# 演示与离线资料

| 入口 | 地址或位置 |
| --- | --- |
| Python 终端演示 | `scripts/demo_trip_flow.py`，执行下方命令 |
| 固定合成输入 | [仓库共享样例](../fixtures/demo-trip.json)为 1.1；收到的 APK 内为 1.2，待 A/B/C 统一归档 |
| Android 调试 APK | 2026-11-20 已收到 `同行计划_0.2.apk.1`；[包信息与核对结果](week1-demo.md#已收到的-android-安装包) |
| APK 获取与构建对应 | 已收文件由团队交接；下载位置、`mobile/` 源码提交和安装说明待 C 归档。默认构建路径为 `mobile/build/app/outputs/flutter-apk/app-debug.apk` |
| Android 构建、安装及飞行模式走查 | [第一周演示与联验](week1-demo.md) |
| 四机联机 | [第二周就绪记录](week2-A-readiness.md)列出接口、客户端和真机的当前状态 |

在仓库根目录运行本地演示：

```sh
python -m scripts.demo_trip_flow
```

2026-11-24 在 `main@0fb9a23` 的独立目录复跑通过，含 B 新增的缺时间字段用例。结果见[第一周演示与联验](week1-demo.md#python-复跑)。

Android 演示从群组与偏好页开始，使用同一台手机上的四个本地身份。当前 APK 完成文件和包内样例的静态检查，时间显示、变更确认记录待 C 修订；签名、安装及真机断网结果待验收。按[联验步骤](week1-demo.md)完成后，登记 APK 哈希、源码提交、设备型号、Android 版本、样例版本与结果。
