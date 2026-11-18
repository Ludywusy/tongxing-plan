# 演示与离线资料

| 入口 | 地址或位置 |
| --- | --- |
| Python 终端演示 | `scripts/demo_trip_flow.py`，执行下方命令 |
| 固定合成输入 | [共享样例](../fixtures/demo-trip.json)，Android 随应用打包 |
| Android 调试 APK | 待 C 提供；默认构建路径 `mobile/build/app/outputs/flutter-apk/app-debug.apk` |
| Android 构建、安装及飞行模式走查 | [第一周演示与联验](week1-demo.md) |
| 四机联机 | [第二周交接](week2-handoff.md)，待服务和真机联调 |

在仓库根目录运行本地演示：

```sh
python -m scripts.demo_trip_flow
```

Android 演示从群组与偏好页开始，使用同一台手机上的四个本地身份。安装和走查完成后，在验收表登记 APK 位置、真机型号、样例版本与离线结果。
