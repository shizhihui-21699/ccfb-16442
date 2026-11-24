# ISMS 控制措施证据自动采集与持续监测平台（Ruby）

面向 ISO/IEC 27001 等信息安全管理体系认证，自动从人事系统、代码仓库、云平台、
工单系统采集数据，对上百项控制进行**持续符合性**评估，并生成可直接交付审核员的
证据包，替代年度人工截图整理。

## 三个核心难点与本平台的解法

| 难点 | 解法 | 关键代码 |
| --- | --- | --- |
| 各系统数据口径对不上 | 原始数据落盘 → 适配器规范化 → 确定性身份映射（工号/邮箱/ARN/用户名 → 全局 person_id），低置信度映射进人工裁决 | `lib/isms/identity_mapper.rb`、`lib/isms/connectors/` |
| 控制存在合理例外 | 例外是一等领域对象：审批链 + 有效期 + 补偿控制；引擎在时间轴上自动切分豁免/非豁免区间，例外过期自动恢复告警 | `lib/isms/domain/exception_window.rb`、`lib/isms/engine/evaluator.rb` |
| 证据须证明整个周期有效，而非某个时点 | 双时态追加写观测（observed_at / collected_at）+ 按天区间求值，输出连续时间轴；数据缺口本身作为审计发现；证据包带 SHA-256 清单 | `lib/isms/engine/evaluator.rb`、`lib/isms/evidence/packager.rb` |

## 目录结构

```
config/controls/*.yml     # 控制规则声明（规则即代码，带版本号）
lib/isms/
  connectors/             # 各系统适配器：HR / 代码仓库 / 云平台 / 工单
  canonical/              # 规范化领域模型（账号、人员、MR、补丁、工单…）
  domain/                 # 身份映射、例外窗口等领域逻辑
  engine/                 # 规则加载器、求值引擎（时间轴区间切分）
  evidence/               # 证据包生成（清单、哈希、人工叙述）
demo_data/                # 模拟四个系统的原始数据（可离线跑通全流程）
test/                     # minitest，零依赖
```

## 快速运行（无需安装任何 gem）

```bash
ruby demo/run_demo.rb
```

输出在 `output/`：每个控制一份 JSON 评估结果，以及 `evidence_pack/` 证据包目录。

运行测试：

```bash
ruby test/suite.rb
```

## 生产化路径

见 `docs/ARCHITECTURE.md`：Rails 6 + PostgreSQL（tstzrange/GiST）+ Sidekiq 的
部署形态、重算策略、证据封存与保留期限、上百项控制的扩展方式。
