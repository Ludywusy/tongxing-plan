# 同行计划

面向大学生多人出行的协作项目：汇总时间、预算、交通和偏好，比较候选行程，记录成员确认，并展示降雨等变化对行程的影响。

## 项目入口

- [GitHub 仓库](https://github.com/Ludywusy/tongxing-plan)
- [演示与离线资料](docs/prototype.md)
- [数据说明](research/README.md)

## 获取项目

```sh
git clone https://github.com/Ludywusy/tongxing-plan.git
cd tongxing-plan
```

## 目录

| 目录 | 用途 |
| --- | --- |
| `docs/` | 使用说明、演示与离线资料入口 |
| `algorithm/` | 候选约束检测 |
| `core/` | 行程状态与变更处理 |
| `tests/` | 状态及变更测试 |
| `scripts/` | 演示脚本 |
| `schemas/` | 数据格式与输入约束 |
| `fixtures/` | 固定合成样例 |
| `research/` | 调研汇总与匿名摘要 |

## 测试命令

使用 Python，在仓库根目录运行对应模块的测试：

```sh
# 候选约束测试
python -m unittest discover -s algorithm -p "test_*.py"

# 状态与变更测试
python -m unittest discover -s tests -p "test_*.py"
```

命令发现各目录中的 `test_*.py` 文件；实际测试数量取决于检出版本中的测试文件。

## 演示与离线资料

[演示入口说明](docs/prototype.md) 集中登记在线地址、运行命令和离线文件位置。未提供的入口明确标注，不使用无效链接。

## 数据说明

仓库仅保存调研汇总、匿名摘要和明确标注的合成样例。问卷逐行答卷、原始导出及可识别个人的信息留在团队受限资料区，受限资料的访问链接不公开。

演示数据注明来源、更新时间和模拟标记；金额使用整数分，时间使用带时区的 ISO 8601 格式。详细约定见 [数据说明](research/README.md)。

`.gitignore` 排除环境文件、密钥、缓存及受限调研资料；`.env.example` 只允许放空值或示例占位符。
