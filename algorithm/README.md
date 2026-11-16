# 约束检测 · B

待提交：`conflict_detector.py`、`test_cases.json`、`test_conflict_detector.py`。

使用 Python 标准库。覆盖时间窗、逐人预算、交通、地点禁忌及缺失/无效输入；输出可行、不可行或待补字段，并记录规则 ID、相关成员、实际值、阈值与可读理由。候选及原因按固定顺序输出。

输入对齐 C 的契约及合成样例，输出供 A 的确认门槛和变更替代检查使用。约束说明和初验报告分别由 B 提交到 `docs/constraints.md`、`docs/algorithm-week1.md`。

目标复现命令（测试尚未实现）：

```sh
python -m unittest discover -s algorithm -p "test_*.py"
```

至少覆盖基本可行、共同窗为空、端点相碰、多窗及间隙、预算达上限/超限、交通拒绝、地点禁忌、缺失、格式无效和全部候选失败。0 tests 不作为通过。
