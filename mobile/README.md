# 同行计划 Android 客户端

App 0.2.0（构建号 2）支持 FastAPI 房间的创建、加入、本人偏好保存和共享快照刷新；离线入口保留单机四身份的投票、版本确认和降雨替代流程。

联机需填写同一服务电脑的局域网地址，例如 `http://192.168.1.10:8000/api/v0.1`。每台手机独立保存成员凭证及未确认的建房/加入请求，重试沿用原幂等键。已有身份时地址锁定。服务必须使用同一 SQLite 文件持久化房间。

在 `mobile/` 执行：

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Windows 非 ASCII 路径可在仓库根目录运行 `./tools/build-apk.ps1`，设置 `TONGXING_FLUTTER` 指向 flutter.bat、`TONGXING_ANDROID_SDK` 指向 Android SDK；脚本在临时 ASCII 路径构建并回拷 `mobile/build/app/outputs/flutter-apk/app-debug.apk`。

固定回归源为 `../fixtures/demo-trip.json`（1.1），对应 `assets/demo-trip-1.1.json`。扩展离线体验源为 `../fixtures/demo-trip-1.2.json`，对应 `assets/demo-trip.json`。不要把不同版本互相覆盖。数据均为合成样例，时间与费用不代表实时信息。

跨栈测试需要仓库 Python 虚拟环境，普通 `flutter test` 会跳过它：

```powershell
flutter test test/live_room_api_test.dart --dart-define=ROOM_REPO_ROOT=C:/path/to/tongxing-plan --dart-define=ROOM_PYTHON=C:/path/to/tongxing-plan/.venv/Scripts/python.exe
```

该测试启动临时本机服务和数据库，运行四个独立客户端并重启服务，结束时清理；它不是四台真实手机的验收。完整交接、哈希和待复验范围见 [第二周 Android 交付](../docs/week2-android.md)。
