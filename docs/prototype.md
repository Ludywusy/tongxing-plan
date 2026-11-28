# 演示与离线资料

| 入口 | 地址或位置 |
| --- | --- |
| Python 终端演示 | `scripts/demo_trip_flow.py`，执行下方命令 |
| 固定合成输入 | [共享回归样例](../fixtures/demo-trip.json)为 1.1；[扩展离线样例](../fixtures/demo-trip-1.2.json)为 1.2，分别打包并登记哈希 |
| Android 调试 APK | 2026-11-20 已收到 `同行计划_0.2.apk.1`；[包信息与核对结果](week1-demo.md#已收到的-android-安装包) |
| 本周 APK 与源码 | App 0.2.0+2，见[Android 交付](week2-android.md)；默认构建路径为 `mobile/build/app/outputs/flutter-apk/app-debug.apk` |
| Android 构建、安装及飞行模式走查 | [第一周演示与联验](week1-demo.md) |
| 四机联机 | [第二周就绪记录](week2-A-readiness.md)列出接口、客户端和真机的当前状态 |

在仓库根目录运行本地演示：

```sh
python -m scripts.demo_trip_flow
```

2026-11-24 在 `main@0fb9a23` 的独立目录复跑通过，含 B 新增的缺时间字段用例。结果见[第一周演示与联验](week1-demo.md#python-复跑)。

本周客户端已修订上海时区显示、成员确认历史和变更批准记录，并接入四个房间接口。旧包检查记录仍保留在第一周文档。新包的构建与自动化证据、安装方式及尚缺的真机验收统一登记在[第二周 Android 交付](week2-android.md)。
