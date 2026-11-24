# 第二周共享房间服务运行说明

在仓库根目录运行。建议使用 Python 3.13 和独立虚拟环境。Windows PowerShell 启动步骤如下。

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r backend/requirements.txt
.\.venv\Scripts\python.exe -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
```

启动后在电脑打开 `http://127.0.0.1:8000/docs`，可用交互文档试跑四个接口。请求和响应详见 [API 契约](api-contract.md)。建房和加入时为每次新操作生成独立的随机 `Idempotency-Key`，如 UUIDv4。保存偏好和读取快照时使用相应成员的 `Authorization: Bearer <member_token>`。模拟响应丢失时，带原键和原请求重试。

## 房间数据库与重启

默认在仓库的 `tmp/rooms.sqlite3` 保存 SQLite 数据库。也可以在启动前用 `TONGXING_ROOM_DB` 指定团队受限目录中的数据库文件，例如：

```powershell
$env:TONGXING_ROOM_DB = Join-Path $PWD 'tmp/rooms-local-test.sqlite3'
```

数据库文件及 SQLite 辅助文件不入库。成员鉴权记录保存凭证的哈希。建房及加入的成功响应含原凭证，作为重试记录保存在仅限团队访问的数据库中。验收记录只使用成员 ID 等脱敏信息。

用 `Ctrl+C` 停服务，然后使用同一个数据库路径重启。手机保留原房间和成员凭证，刷新应读到相同成员、进度和汇总。使用成功的建房或加入请求原样重试，应返回原房间、身份和凭证。需要新开一轮联调时可设置另一个数据库文件。

## 给 C 的真机联调入口

让服务电脑和四台手机连接同一可互通的 Wi-Fi。在电脑执行 `ipconfig`，取 Wi-Fi 适配器的 IPv4 地址。以该地址替换下面的 `<电脑局域网 IP>`，使用调试 APK 连同一个服务。

```powershell
.\.venv\Scripts\python.exe -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
```

手机基址为 `http://<电脑局域网 IP>:8000/api/v0.1`。先在一台手机浏览器打开 `http://<电脑局域网 IP>:8000/docs` 核对连通性，之后按[四机记录](week2-four-device-test.md)走查。手机上的 `127.0.0.1` 指向这台手机。局域网地址由联调当日的服务电脑记录。

## 自动复跑

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -p 'test_rooms_api.py'
.\.venv\Scripts\python.exe -m unittest discover -s tests -p 'test_room_storage.py'
.\.venv\Scripts\python.exe -m unittest discover -s algorithm -p 'test_*.py'
.\.venv\Scripts\python.exe -m unittest discover -s tests -p 'test_trip_flow.py'
.\.venv\Scripts\python.exe -m scripts.demo_trip_flow
```

首批四接口的快照处于 `collecting`。候选、同版本确认和变更继续用 Python 演示验证，联机接口列为后续接入项。
