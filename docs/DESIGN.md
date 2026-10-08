# Trias · 三权分立的 AI 开发流水线（设计文档）

## Fable 5.1 出方案 · GPT 执行 · Opus 验收 · 脚本衔接 · 邮件通知

> **用途**：拿给任何人，他都能照着搭一套，或者按自己情况换掉其中任何一块。
> **来源**：这套做法在一个真实项目上无人值守跑完了 10 个子阶段，含返工与两线并行。本文是把跑过的那套抽象、瘦身后的版本。附带的脚本已用假模型端到端跑通（开发、返工、遗留追加、需决定等人、自动按推荐、全部完成）。踩过的坑在第 11 节单列。
> **仓库**：https://github.com/wyatttml/trias 。本文件在 `docs/` 下，仓库根即复刻包；`install.sh` 可一行接入。`pipeline/` 是 4 个脚本 + 3 份提示词，`templates/` 是状态文件、手册、项目规则、故障说明、`.env` 样例。第 14 节是一小时搭起来的清单。

---

## 0. 一页看懂

```
AI 产品经理（只做业务判断，不碰终端）
   │ 对话                                        ▲ 邮件 / 弹窗（通过、返工、需决定、完成）
   ▼                                             │
Fable 5.1 —— 方案模型，只在对话里用               │
   │ 产出：00_总方案.md、每段手册 Sn_*.md、项目状态.md
   ▼                                             │
┌──────────── run.sh 编排脚本（无人值守循环）────────────────────┐
│ 读 项目状态.md → 当前子阶段是什么状态？                         │
│ 未开始 / 返工中 ──► Codex（GPT）照手册开发 ──► 自己改成「待验收」│
│ 待验收 ──► checks.sh 程序检查（全量测试 / 真实冒烟 / 密钥扫描）  │
│         ──► Opus 验收：读结果 + 抽查原件 ──► 结论三选一          │
│ 通过   ──► 遗留项自动追加进下一段手册，进入下一段                │
│ 返工   ──► 结论原文喂回 Codex（最多 2 轮，第 3 次验收员自裁）    │
│ 需决定 ──► 弹窗 + 邮件等人；10 分钟没人答且不涉四类 → 按推荐办   │
└───────────────────────────────────────────────────────────────┘
```

四条核心思想，比任何脚本细节都重要：

1. **三个模型各干一件事，用文件交接，不用聊天交接。** 手册是方案模型给执行模型的合同；验收结论是验收模型给执行模型的返工单；进度表是所有人共用的唯一事实。
2. **脚本是唯一的状态推进者。** 执行模型只被允许做一个状态变化：把自己的段改成「待验收」。其余全由脚本和验收员改。
3. **能用程序量出来的交给程序，模型只做程序量不出来的判断。** 测试、冒烟、密钥扫描由脚本跑出数字；验收模型只读数字、抽查 2 到 3 处原件、下结论，15 次工具调用以内。
4. **人只在四类事上被打扰。** 新开付费服务或云资源、删数据、改范围、改密钥配置。其余 10 分钟没人答就自动按推荐办。

---

## 1. 为什么这样分工

| 角色 | 用什么 | 干什么 | 为什么是它 |
| --- | --- | --- | --- |
| 方案与裁决 | Fable 5.1（Claude 对话） | 写总方案与每段手册；改流程；返工两轮都不过时裁决 | 最强的模型，但额度最贵、是对话型。只在有人参与的对话里用，不进脚本 |
| 执行 | GPT（Codex CLI，`codex exec`） | 照手册写代码、测试、冒烟脚本、交付说明 | 命令行可无人值守；沙箱档位可控；独立订阅，不耗 Claude 额度 |
| 验收 | Opus 5.5（Claude Code CLI，`claude -p`） | 读程序结果，抽查原件，下三选一结论 | 与执行模型不同厂商，不会给自己放水；比 Fable 便宜，每段都跑得起 |
| 衔接 | bash + 两个小 Python | 状态机、起停模型、跑检查、等人、通知 | 确定性、可复盘，出事看日志就能定位 |
| 通知 | Gmail SMTP（可选 webhook）+ Mac 弹窗 | 推到手机 | 零成本；手机装 Gmail 就能收推送 |
| 日常运维 | Opus（对话） | 流水线停了时按《停了怎么办》处理 | 日常问题不值得用 Fable 的额度 |

替换规则（第 13 节有替换表）：每一格都可以换，但保住两条：**执行与验收不是同一个模型**；**方案由你能用到的最强模型写**。

---

## 2. 目录与文件约定

```
项目根/
├─ AGENTS.md                  执行模型每次开工自动读的项目规则（templates/AGENTS.md）
├─ 项目状态.md                唯一事实来源：进度表 + 决策台账（templates/项目状态.md）
├─ 手册/
│   ├─ 00_总方案.md           方案模型写：范围、规则、流水线说明
│   └─ S1_xxx.md … Sn_xxx.md  每段一份，固定章节（templates/手册_Sn_子阶段名.md）
├─ pipeline/
│   ├─ run.sh                 编排脚本
│   ├─ state.py               读写进度表
│   ├─ notify.py              邮件 / webhook
│   ├─ checks.sh              程序检查（按项目改的唯一文件）
│   ├─ prompts/               dev_start.md  dev_rework.md  accept.md
│   └─ 停了怎么办.md           给运维模型看（templates/停了怎么办.md）
├─ scripts/smoke_Sn.py        每段一个真实冒烟脚本（执行模型写）
├─ 验收证据/Sn/               交付说明.md（执行模型写）  验收结论.md（验收模型写）
├─ 运行数据/pipeline/         不进 Git：日志/、accept_Sn.json、等待决定.md、停止、dev.pid
└─ .env                       不进 Git：GMAIL_* 等
```

命名规则：子阶段编号 `S1、S2…`（前缀可用环境变量 `STAGE_PREFIX` 改）；手册文件名必须以 `S1_` 这样的前缀开头，脚本靠前缀找手册。

---

## 3. 状态机

```
未开始 ──► 开发中 ──► 待验收 ──┬──► 已通过（或 已通过·待 AI 产品经理亲验）
             ▲                 ├──► 返工中 ──► 开发中（返工计数 +1，上限 2 轮）
             │                 └──► 等待决定 ──► 继续 / 通过 / 返工：xxx
             └──────────────────────────────┘
```

| 状态 | 谁改 | 脚本接着做什么 |
| --- | --- | --- |
| 未开始 | 脚本改成「开发中」 | 渲染 dev_start 提示词，起执行模型 |
| 开发中 | 执行模型改成「待验收」（没改则脚本代改） | 脚本代提交 Git |
| 待验收 | — | 跑 checks.sh，再起验收模型，按结论分支 |
| 返工中 | 脚本改成「开发中」 | 渲染 dev_rework（带结论原文），计数 +1 |
| 已通过 | 脚本 | 遗留项追加到下一段手册，发邮件，进入下一段 |
| 已通过·待 AI 产品经理亲验 | 脚本（`MANUAL_REVIEW_STAGES` 列出的段） | 同上；提醒人去亲自验 |

进度表格式（`state.py` 只认这一种）：

```
| S1 第一段名称 | 未开始 | |
```

---

## 4. 手册 = 合同（方案模型的产出）

每段一份，方案模型在开工前写好。固定章节（模板在 `templates/手册_Sn_子阶段名.md`）：目标 / 范围（要做·不做）/ 现状 / 设计 / 开发步骤 / 测试清单 / 真实冒烟 / AI 产品经理验收步骤 / 降级路径 / 通过线与完成定义 / 开工核对 / 实现记录。

三条铁律：

1. **通过线必须可量。** 「测试全绿」「冒烟 PASS」「命中率 ≥ 80%」这种程序能量出来的写进通过线；「引用块读着顺」这种写进完成定义，由验收模型抽查。
2. **手册与代码不一致，以代码为准。** 执行模型在「开工核对」记一行，继续干，不停下来问。
3. **手册会生长。** 验收通过时脚本把结论里「遗留到下一阶段」自动追加到下一段手册末尾；执行模型开工先看有没有这一节。

总方案（`00_总方案.md`）管全局，写一次每段开工都读：范围总表（做不做以此为准）、工作规则、不许做的事、新代码够用线、测试的量、卡住怎么办、什么时候问人。真实项目里最有用的几条：

- 不搞任何形式的自审仪式：不开审核子代理、不写自审报告、不做签署回执。
- 不写一次性脚本；每段只有一个冒烟脚本，重跑就覆盖。
- 同一问题修两次还不过：走降级路径；没有降级路径就写进交付说明「需 AI 产品经理决定」，正常收尾。
- 只有会改变费用、范围、安全、隐私的事才问人，一次不超过 5 个，每个附推荐。

---

## 5. 一个子阶段的完整一圈

1. 脚本读进度表，拿到第一个未通过的段（如 S2）及其状态。
2. 状态「未开始」：改成「开发中」，用 `prompts/dev_start.md` 渲染提示词，`codex exec` 起执行模型，提示词从 stdin 喂入，输出全进日志。
3. 执行模型照手册开发、写测试、写 `scripts/smoke_S2.py`、填「实现记录」、写交付说明、把状态改成「待验收」、退出。
4. 脚本代提交 Git（执行模型不碰 Git）。
5. 状态「待验收」：脚本跑 `checks.sh S2`，生成 `accept_S2.json`（测试退出码、冒烟 status、密钥命中数、passed）。
6. 用 `prompts/accept.md` 渲染提示词，`claude -p` 起验收模型。它读手册通过线、交付说明、accept 结果，抽查 2 到 3 处原件，写 `验收证据/S2/验收结论.md`，第一行三选一。
7. 分支：
   - **通过**：改状态；遗留项追加进 S3 手册；提交；发邮件「S2 验收通过」。
   - **返工**：状态改「返工中」；下一圈用 `dev_rework.md` 把结论原文喂回执行模型；计数 +1。第 3 次验收不再判返工，验收模型自裁通过（四类除外）。
   - **需决定**：进入等人机制（第 6 节）。
8. 回到第 1 步。进度表全部通过时发邮件「流水线全部完成」，退出。

时间参考（真实项目，后端 Python）：一段开发 20 到 60 分钟；程序检查 2 到 15 分钟，大头是全量测试；验收 3 到 8 分钟。

---

## 6. 等人机制（需决定）

**触发**：验收结论「需决定」；返工超上限；模型连续两次异常退出；程序检查没生成结果文件；进度表出现未知状态；找不到手册。

**三个渠道同时发**：
1. 写 `运行数据/pipeline/等待决定.md`：子阶段、原因、推荐、会自动还是一直等；最后一行留给人写决定。
2. 发邮件，标题「流水线停了，等你决定（S2）」，正文说清推荐和怎么回。
3. Mac 弹窗，两个按钮「按推荐办」「我自己看」。Linux 没有 osascript 自动跳过，只靠邮件和决定文件。

**节奏**：5 分钟后再提醒一次（邮件 + 弹窗）。**10 分钟没人答且允许自动的，按推荐办**，并发邮件告知「已自动按推荐办」。

**永远等人的四类**（验收模型在结论里写「可自动按推荐：否」）：新开付费服务或云资源、删数据、改范围、改 .env。

**人的回复只有四种**，写在决定文件最后一行，脚本 30 秒内接着跑：

| 写什么 | 效果 |
| --- | --- |
| `按推荐` | 执行文件里写的推荐 |
| `继续` | 返工计数清零，按当前状态继续（常用于「再试一次」） |
| `通过` | 判该段通过，遗留项照常追加 |
| `返工：要改什么` | 这句话作为返工单交给执行模型 |

**防骚扰规则**（都来自真实事故）：
- 同一原因连续出现第二次就一直等人，不再反复弹窗。曾经同一个故障被反复重跑，AI 产品经理每次都点「按推荐办」，脚本就又跑一遍。
- 推荐文本不可机械执行时（如「通过（前提是……）」）不静默死循环，发邮件说明并继续等。
- 不懂技术的人回「按推荐」的比例极高。所以推荐一定要写成可执行的指令词开头：`通过` / `继续` / `返工：…`。

---

## 7. 通知设计

| 事件 | 标题 | 正文要点 | 要人操作吗 |
| --- | --- | --- | --- |
| 验收通过 | S2 xxx 验收通过 | 验收员的一句话摘要 | 否 |
| 判返工 | S2 xxx 判返工（第 1 次验收） | 摘要；「会自动返工，不用你操作」 | 否 |
| 需决定 | 流水线停了，等你决定（S2） | 原因、推荐、会不会自动、怎么回 | 是 |
| 再提醒 | 再提醒一次：流水线在等你（S2） | 推荐、决定文件路径 | 是 |
| 自动按推荐 | 已自动按推荐办（S2） | 推荐了什么 | 否 |
| 按推荐失败 | 按推荐办失败（S2） | 推荐不可执行，请直接写决定 | 是 |
| 全部完成 | 流水线全部完成 | 等你总验 | 是 |

写法原则：第一句就是结论；正文明确「要不要你做什么」；不带日志、不带密钥、不带命令输出；标题带子阶段编号，手机上扫一眼就知道进度。

**Gmail 配置（一次性，5 分钟）**：
1. Google 账号 → 安全 → 开两步验证。
2. 搜「应用专用密码」→ 新建一个 → 得到 16 位密码。
3. 项目根 `.env` 写 `GMAIL_USER`、`GMAIL_APP_PASSWORD`、`NOTIFY_EMAIL`（样例在 `templates/.env.example`），确认 `.gitignore` 含 `.env`。
4. 测一下：`python3 pipeline/notify.py 测试 正文`，看 `运行数据/pipeline/日志/notify.log` 里是不是 `mail:ok`。

走 587 端口 STARTTLS，465 常被本机代理挡住。缺配置时脚本静默只记日志，不会把流水线搞死。

**换渠道**：`.env` 加 `NOTIFY_WEBHOOK` 和 `NOTIFY_WEBHOOK_KIND=slack|feishu|wecom`，群机器人就能收；两个渠道可以同时开。

---

## 8. 提示词（三份全文）

写提示词的经验：
- 开头一句就定「只做哪一段、手册在哪」。
- 反复强调「无人值守，不要提问」，否则模型会停在半路等回答。
- 收尾动作写死顺序，最后一条永远是「把状态改为待验收，然后结束」。
- 把真实返工过的原因写进去（例如「收尾前必须跑一遍全量测试」：真实项目前四段的首轮验收全部因为执行模型没跑全量测试而返工）。
- 验收提示词限定工具调用次数、结论行数、第一行格式；三选一的判定规则写清楚，尤其是「最后一次不许再判返工」和「四类永远需决定」。

### 8.1 `pipeline/prompts/dev_start.md`（开工）

```markdown
按项目根 AGENTS.md 开工，只做 {STAGE}（{NAME}）这一个子阶段，手册在 手册/{FILE}。

规则：
- 你在无人值守的流水线里运行，没有人回答问题。手册已定的照做；没定的照最近的现有代码写法做；需要 AI 产品经理决定的事写进交付说明「需 AI 产品经理决定」，然后照常收尾，不要停在半路。
- 先看手册末尾有没有「上一阶段遗留」小节，有就一并做完，在交付说明里逐条写怎么修的。
- 开工时通读手册并对照代码（不超过 20 分钟）。手册与代码不一致的以代码为准，在手册末尾「开工核对」记一行，继续干，不停下来问。
- 只做手册「要做」清单里的事，新代码配测试。开发中只跑相关测试；收尾前必须在本目录完整跑一遍全量测试，有失败就修到全绿再交，不要把「旧测试被改坏」留给验收员。
- 真实冒烟：写 scripts/smoke_{STAGE}.py，按手册「真实冒烟」逐步调用真实服务（真实 Key、真实模型），结果写 运行数据/smoke_{STAGE}.json，顶层 status 只能是 PASS 或 FAIL，每步记录成败。流水线会在你收尾后用它自己的环境重跑一遍，验收员只认流水线跑出的结果；交付说明里不要写流水线复现不了的「PASS」。
- 只在本目录改东西；不切换 Git 分支、不合并、不推送（提交由流水线代做）；不改 pipeline/ 目录；不改 .env；不删任何用户数据或历史资料；不新开付费服务或云资源。手册要求的真实模型调用费用已批准，该跑就跑，不要为省钱跳过。
- 收尾：填手册末尾「实现记录」（不超过 30 行）；写 验收证据/{STAGE}/交付说明.md（不超过 40 行：做了什么、怎么验、闸门表、冒烟结果一句话、已知问题、需 AI 产品经理决定）；把 项目状态.md 进度表里 {STAGE} 的状态改为「待验收」；然后结束。不要开始下一个子阶段。
- 最后一条回复只写：做了什么（三句以内）、冒烟结果、测试通过数、交付说明路径。
```

### 8.2 `pipeline/prompts/dev_rework.md`（返工）

```markdown
{STAGE}（{NAME}）验收未通过，这是第 {ROUND} 轮返工。按 AGENTS.md 和 手册/{FILE} 继续做 {STAGE}，只解决下面验收员列出的问题，不扩范围。

验收结论原文：
----
{VERDICT}
----

规则提醒：无人值守，不要提问；每个问题修好后在交付说明里逐条写「已修：怎么修的、怎么验证的」；拿不准的按验收员给的复现方法先复现再修。修完先跑本阶段冒烟（scripts/smoke_{STAGE}.py），再在本目录完整跑一遍全量测试，全绿再交；验收员只认流水线自己跑出的结果。只在本目录改东西，不切分支、不合并、不推送；不改 pipeline/、不改 .env、不删数据、不新开付费服务；手册要求的真实模型调用费用已批准，该跑就跑。把 项目状态.md 里 {STAGE} 改回「待验收」，结束。最后一条回复只写：修了哪些、冒烟结果、测试通过数。
```

### 8.3 `pipeline/prompts/accept.md`（验收）

```markdown
你是流水线的验收员。现在验收 {STAGE}（{NAME}），这是第 {ROUND} 次验收（返工上限 {MAX} 轮）。工作目录是项目根。

AI 产品经理要求：不要仪式感审核。你的活是「读结果 + 抽查 2 到 3 处原件 + 下结论」，控制在 15 次工具调用以内，不重做验收，不改任何代码，不替开发模型修。

先读：
1. 手册/{FILE} 的「通过线」「完成定义」「实现记录」。
2. 验收证据/{STAGE}/交付说明.md。
3. 运行数据/pipeline/accept_{STAGE}.json（流水线自己跑出的全量测试、真实冒烟、密钥扫描结果）。

怎么验：
- 测试与冒烟以 accept 结果为准，不重跑。交付说明里写的「通过」与 accept 结果矛盾时，以 accept 结果为准。
- 抽查 2 到 3 处原件：冒烟结果文件、一件实际产物、必要时调一次接口或跑一个小命令。
- accept 结果里 secret_hits 不为 0，直接返工。

怎么判：
- 通过线与完成定义达到 → 通过。小毛病不阻塞的写进「遗留到下一阶段」，照样通过。
- 有阻塞问题且本次不是最后一次验收 → 返工。
- 本次是第 {MAX} 次（最后一次）：不再判返工。剩下的问题不涉及新开付费服务、删数据、改范围、改 .env 的，你自己拍板判通过，把问题写进「遗留到下一阶段」；只有涉及这四类，或核心链路根本跑不通，才判需决定。
- 任何时候遇到新开付费服务或云资源、删数据、改范围、改 .env 的事，判需决定。
- 开发模型因「省钱」跳过了手册要求的真实调用：判返工并要求补跑，不要拿费用问 AI 产品经理。

写结论到 验收证据/{STAGE}/验收结论.md，总长不超过 25 行，格式固定：
第一行只写三者之一：结论：通过 / 结论：返工 / 结论：需决定
然后按需写这些小节（没有内容的小节省略）：
## 问题清单
（返工时，每条一行：现象、复现方法、期望）
## 遗留到下一阶段
（每条一行，写给下一阶段的开发模型看：要修什么、怎么算修好）
## 需决定
问题一行；选项每个一行；倒数第二行固定写「可自动按推荐：是」或「可自动按推荐：否」（涉及新开付费服务、删数据、改范围、改 .env 四类之一就写「否」，否则写「是」）；最后一行固定写「推荐决定：通过」或「推荐决定：返工：要改什么」。
## 给 AI 产品经理的一句话摘要
（大白话，三行以内）

最后一条回复只写第一行的结论和摘要。
```

---

## 9. 脚本（四份全文）

四份脚本加起来约 420 行，只依赖 bash、python3 标准库、git（可选）。`checks.sh` 是唯一要按项目改的文件。

### 9.1 `pipeline/run.sh`（编排，单线）

```bash
#!/bin/bash
# 三模型流水线 · 编排脚本（单线参考实现）。方案见 docs/DESIGN.md。
# 用法（在项目根目录）：
#   Mac:   nohup caffeinate -dims bash pipeline/run.sh >> 运行数据/pipeline/日志/nohup.out 2>&1 &
#   Linux: nohup bash pipeline/run.sh >> 运行数据/pipeline/日志/nohup.out 2>&1 &
# 停：touch 运行数据/pipeline/停止（不要 pkill 模型进程，会误杀你自己正在用的对话）
# 改了本文件要重启才生效；新进程会按 pid 文件等正在跑的开发模型做完再接手，不会重复开工。
set -u
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # 必须 UTF-8，否则 sed/bash 按字节切中文会出乱码

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/pipeline"; D="$ROOT/运行数据/pipeline"; L="$D/日志"; M="$ROOT/手册"; E="$ROOT/验收证据"
mkdir -p "$L" "$E"
cd "$ROOT"

# ---------- 可改参数（也可用环境变量覆盖） ----------
CODEX="${CODEX:-codex}"                              # 开发模型 CLI（Codex）。Mac 的 ChatGPT 桌面版自带一份：/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
CODEX_MODEL="${CODEX_MODEL:-gpt-6-astra}"
CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"    # workspace-write（保守）或 danger-full-access（能起浏览器、跑 Git）
CLAUDE="${CLAUDE:-claude}"                           # 验收模型 CLI（Claude Code）
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-5-5}"
MAX_REWORK="${MAX_REWORK:-2}"                        # 返工上限；第 MAX_REWORK+1 次验收由验收员自裁
AUTO_WAIT="${AUTO_WAIT:-600}"                        # 需决定：这么多秒没人答就自动按推荐（只对允许自动的那些）
REMIND="${REMIND:-300}"                              # 第二次提醒的间隔
POLL="${POLL:-30}"                                   # 等人时每隔多少秒看一次决定文件
MANUAL_REVIEW_STAGES="${MANUAL_REVIEW_STAGES:-}"     # 空格分隔；这些子阶段通过后记为「已通过·待 AI 产品经理亲验」
PROJECT_NAME="$(basename "$ROOT")"
export STATE_FILE="$ROOT/项目状态.md"

# ---------- 小工具 ----------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$L/pipeline.log"; }
notify(){ python3 "$P/notify.py" "$1" "$2" >/dev/null 2>&1 || true; }
st(){ python3 "$P/state.py" "$@"; }
stop_requested(){ [ -f "$D/停止" ]; }
manual_file(){ ls "$M" 2>/dev/null | grep "^$1_" | head -1; }
rework_count(){ cat "$D/rework_$1" 2>/dev/null || echo 0; }
commit_all(){ git rev-parse --git-dir >/dev/null 2>&1 || return 0; git add -A . >/dev/null 2>&1; git commit -q -m "$1" >/dev/null 2>&1 || true; }
render(){ # render 模板 KEY=VALUE ...；VERDICT_FILE=路径 会读文件内容填 {VERDICT}
  python3 - "$@" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    if k == "VERDICT_FILE":
        k, v = "VERDICT", open(v, encoding="utf-8").read()
    t = t.replace("{" + k + "}", v)
print(t)
PY
}
drop_last_line(){ local t; t="$(mktemp)"; sed '$d' "$1" > "$t" && mv "$t" "$1"; }

# ---------- 跑模型 ----------
run_codex(){ # $1 子阶段 $2 提示词文件
  local out="$L/$1_dev_$(date +%Y%m%d_%H%M%S).log" pid rc
  log "开发模型开工 $1 -> $out"
  "$CODEX" exec -m "$CODEX_MODEL" -c model_reasoning_effort='"high"' -c approval_policy='"never"' \
    -s "$CODEX_SANDBOX" -C "$ROOT" -o "$D/$1_dev_last.txt" - < "$2" > "$out" 2>&1 &
  pid=$!; echo "$pid" > "$D/dev.pid"
  wait "$pid"; rc=$?; rm -f "$D/dev.pid"
  log "开发模型退出码 $rc"; return $rc
}
run_claude(){ # $1 子阶段 $2 提示词文件
  local out="$L/$1_accept_$(date +%Y%m%d_%H%M%S).log" rc
  log "验收模型开工 $1 -> $out"
  "$CLAUDE" -p --model "$CLAUDE_MODEL" --permission-mode bypassPermissions --output-format text "$(cat "$2")" > "$out" 2>&1
  rc=$?; log "验收模型退出码 $rc"; return $rc
}

# ---------- 通过：改状态、把遗留项追加进下一阶段手册、提交 ----------
pass_stage(){ # $1 子阶段
  local stg="已通过" nx vf="$E/$1/验收结论.md"
  case " $MANUAL_REVIEW_STAGES " in *" $1 "*) stg="已通过·待 AI 产品经理亲验";; esac
  st set "$1" "$stg" >/dev/null; rm -f "$D/rework_$1"
  nx="$(st next "$1")"
  if [ -f "$vf" ] && [ -n "$nx" ] && [ -n "$(manual_file "$nx")" ]; then
    python3 - "$vf" "$M/$(manual_file "$nx")" "$1" <<'PY'
import sys, re, datetime
vf, manual, stage = sys.argv[1:4]
m = re.search(r"^## 遗留到下一阶段\s*\n(.*?)(?=^## |\Z)", open(vf, encoding="utf-8").read(), re.S | re.M)
body = m.group(1).strip() if m else ""
if body:
    with open(manual, "a", encoding="utf-8") as f:
        f.write(f"\n\n## 上一阶段遗留（{stage} 验收，{datetime.date.today()}）\n\n{body}\n")
    print("遗留项已写入", manual)
PY
  fi
  commit_all "pipeline: $1 验收通过"
  log "$1 -> $stg"
}

# ---------- 等人：弹窗（仅 Mac）+ 邮件各两次；允许自动的，10 分钟没人答按推荐办 ----------
ask_dialog(){ # $1 标题 $2 正文 $3 决定文件 $4 弹窗保留秒数。点「按推荐办」就往决定文件追加「按推荐」。没有 osascript（Linux）就跳过。
  command -v osascript >/dev/null 2>&1 || return 0
  ( r="$(osascript - "$1" "$2" "$4" <<'AS' 2>>"$L/dialog.log"
on run argv
  display dialog (item 2 of argv) with title (item 1 of argv) buttons {"我自己看", "按推荐办"} default button "按推荐办" giving up after (item 3 of argv as integer)
  return button returned of result
end run
AS
)"
    [ "$r" = "按推荐办" ] && [ -f "$3" ] && echo "按推荐" >> "$3" ) &
}
wait_decision(){ # $1 子阶段 $2 原因 $3 推荐（继续 / 通过 / 返工：xxx） $4 允许自动按推荐(1/0)
  local f="$D/等待决定.md" rec="${3:-继续}" auto="${4:-0}" hint last t0 el reminded=0 x
  if [ "$auto" = 1 ]; then hint="$(( AUTO_WAIT / 60 )) 分钟没人回应，流水线会自动按推荐办。"
  else hint="这件事涉及新开付费服务、删数据、改范围或改 .env，流水线会一直等你。"; fi
  printf '子阶段：%s\n原因：%s\n推荐：%s\n%s\n\n在本文件最后一行写你的决定并保存，只能是：按推荐 / 继续 / 通过 / 返工：要改什么\n（下面是分隔线，决定写在它下面）\n----\n' "$1" "$2" "$rec" "$hint" > "$f"
  notify "流水线停了，等你决定（${1}）" "$2"$'\n\n'"推荐：$rec"$'\n'"$hint"$'\n\n'"处理方法（二选一）："$'\n'"1. 在 Mac 弹窗里点「按推荐办」。"$'\n'"2. 打开 ${f}，在最后一行写决定并保存。"
  ask_dialog "${PROJECT_NAME} 流水线停了（${1}）" "$(printf '%s\n\n推荐：%s\n%s' "$(echo "$2" | head -n 8)" "$rec" "$hint")" "$f" "$REMIND"
  log "等待决定：$1 推荐=$rec 自动=$auto 原因=$2"
  t0="$(date +%s)"
  while true; do
    stop_requested && { log "收到停止"; exit 0; }
    last="$(grep -v '^[[:space:]]*$' "$f" | tail -n 1 | tr -d '[:space:]')"
    [ "$last" = "----" ] && last=""
    el=$(( $(date +%s) - t0 ))
    if [ -z "$last" ] && [ "$reminded" = 0 ] && [ "$el" -ge "$REMIND" ]; then
      reminded=1
      notify "再提醒一次：流水线在等你（${1}）" "推荐：$rec"$'\n'"$hint"$'\n\n'"决定文件：$f"
      if [ "$auto" = 1 ]; then x="$REMIND"; else x=86400; fi
      ask_dialog "${PROJECT_NAME} 流水线还在等你（${1}）" "$(printf '%s\n\n推荐：%s\n%s' "$(echo "$2" | head -n 6)" "$rec" "$hint")" "$f" "$x"
    fi
    if [ -z "$last" ] && [ "$auto" = 1 ] && [ "$el" -ge "$AUTO_WAIT" ]; then
      last="按推荐"; log "$AUTO_WAIT 秒无人回应，自动按推荐办"
      notify "已自动按推荐办（${1}）" "推荐：$rec"$'\n\n'"你没有回应，流水线已按推荐继续，不用你操作。"
    fi
    if [ "$last" = "按推荐" ]; then
      # 推荐可能带括号说明（「通过（前提是…）」），只取开头的指令词；不可机械执行的不能静默死循环
      x="$(echo "$rec" | tr -d '[:space:]')"
      case "$x" in 通过*) last="通过";; 继续*) last="继续";; 返工：*|返工:*) last="$x";; *) last="";; esac
      if [ -z "$last" ]; then
        log "推荐「${rec}」不是可执行指令，无法按推荐办；请在决定文件里直接写 通过 / 继续 / 返工：…"
        notify "按推荐办失败（${1}）" "推荐写的是「${rec}」，流水线无法机械执行。请打开 $f 直接写 通过 / 继续 / 返工：要改什么"
        drop_last_line "$f"
      else log "按推荐：$last"; fi
    fi
    case "$last" in
      继续) echo 0 > "$D/rework_$1"; rm -f "$f"; return 0;;
      通过) pass_stage "$1"; rm -f "$f"; return 0;;
      返工：*|返工:*) x="${last#返工：}"; echo "${x#返工:}" > "$D/返工单_$1.md"; st set "$1" "返工中" >/dev/null; echo 0 > "$D/rework_$1"; rm -f "$f"; return 0;;
    esac
    sleep "$POLL"
  done
}

# ---------- 一个子阶段走一步（按当前状态分支） ----------
run_stage(){ # $1 子阶段 $2 状态
  local stage="$1" status="$2" name file n k v final vf verdict summary rec auto
  name="$(st name "$stage")"; file="$(manual_file "$stage")"
  [ -n "$file" ] || { wait_decision "$stage" "手册目录 $M 里找不到 ${stage}_*.md，没有手册不能开工" "继续" 0; return; }
  log "当前 $stage $name 状态=$status"
  case "$status" in
    未开始|开发中|返工中)
      if [ "$status" = "返工中" ]; then
        n=$(( $(rework_count "$stage") + 1 )); echo "$n" > "$D/rework_$stage"
        if [ "$n" -gt "$MAX_REWORK" ]; then wait_decision "$stage" "返工已超过 $MAX_REWORK 轮，验收仍未通过。结论见 $E/$stage/验收结论.md" "通过" 1; return; fi
        v="$D/返工单_$stage.md"; [ -f "$v" ] || v="$E/$stage/验收结论.md"
        render "$P/prompts/dev_rework.md" STAGE="$stage" NAME="$name" FILE="$file" ROUND="$n" VERDICT_FILE="$v" > "$D/${stage}_prompt.md"
      else
        st set "$stage" "开发中" >/dev/null
        render "$P/prompts/dev_start.md" STAGE="$stage" NAME="$name" FILE="$file" > "$D/${stage}_prompt.md"
      fi
      run_codex "$stage" "$D/${stage}_prompt.md" || run_codex "$stage" "$D/${stage}_prompt.md" \
        || { wait_decision "$stage" "开发模型连续两次异常退出，日志在 $L" "继续" 1; return; }
      if [ "$(st status "$stage")" != "待验收" ]; then log "开发模型没把状态改为待验收，流水线代改"; st set "$stage" "待验收" >/dev/null; fi
      rm -f "$D/返工单_$stage.md"
      commit_all "dev: $stage 开发提交（流水线代提交）"
      ;;
    待验收)
      mkdir -p "$E/$stage"
      log "程序检查 checks.sh $stage"
      bash "$P/checks.sh" "$stage" > "$L/${stage}_checks_$(date +%Y%m%d_%H%M%S).log" 2>&1 || log "程序检查未全过，交给验收员判断"
      if [ ! -f "$D/accept_$stage.json" ]; then
        # 结果文件不在 = 流水线自己的故障（不是开发的问题），重跑不会好：第一次自动重试一遍，再出现就停下等人，不要反复骚扰
        n=$(( $(cat "$D/accept_missing_$stage" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/accept_missing_$stage"
        if [ "$n" -le 1 ]; then wait_decision "$stage" "程序检查没有生成 accept_$stage.json，日志在 $L" "继续" 1
        else wait_decision "$stage" "程序检查连续 $n 次没有生成 $D/accept_$stage.json。这是流水线自身故障，重跑不会好，需要人看 $L 里最近的 ${stage}_checks 日志。" "继续" 0; fi
        return
      fi
      rm -f "$D/accept_missing_$stage"
      k=$(( $(rework_count "$stage") + 1 )); final=""
      [ "$k" -gt "$MAX_REWORK" ] && final="（这是最后一次验收）"
      render "$P/prompts/accept.md" STAGE="$stage" NAME="$name" FILE="$file" ROUND="$k$final" MAX="$(( MAX_REWORK + 1 ))" > "$D/${stage}_accept_prompt.md"
      run_claude "$stage" "$D/${stage}_accept_prompt.md" || run_claude "$stage" "$D/${stage}_accept_prompt.md" \
        || { wait_decision "$stage" "验收模型连续两次异常退出，日志在 $L" "继续" 1; return; }
      vf="$E/$stage/验收结论.md"
      verdict="$(head -n 1 "$vf" 2>/dev/null | tr -d '[:space:]')"
      summary="$(sed -n '/给 AI 产品经理的一句话摘要/,$p' "$vf" 2>/dev/null | sed -n '2,4p')"
      case "$verdict" in
        结论：通过|结论:通过)
          pass_stage "$stage"
          notify "$stage $name 验收通过" "$summary"$'\n\n'"流水线已自动进入下一段，不用你操作。";;
        结论：返工|结论:返工)
          if [ "$k" -gt "$MAX_REWORK" ]; then wait_decision "$stage" "最后一次验收仍判返工。结论见 $vf"$'\n'"$summary" "通过" 1
          else st set "$stage" "返工中" >/dev/null; log "返工 $stage"; notify "$stage $name 判返工（第 $k 次验收）" "$summary"$'\n\n'"开发模型会自动返工，不用你操作。"; fi;;
        结论：需决定|结论:需决定)
          rec="$(python3 -c 'import re,sys; m=re.findall(r"^推荐决定[：:]\s*(.+)$", open(sys.argv[1], encoding="utf-8").read(), re.M); print(m[-1].strip() if m else "")' "$vf")"
          auto="$(python3 -c 'import re,sys; m=re.findall(r"^可自动按推荐[：:]\s*(.+)$", open(sys.argv[1], encoding="utf-8").read(), re.M); print("1" if m and m[-1].strip().startswith("是") else "0")' "$vf")"
          wait_decision "$stage" "验收员需要你决定。结论见 $vf"$'\n'"$summary" "${rec:-继续}" "$auto";;
        *) wait_decision "$stage" "验收结论文件缺失或第一行格式不对：$vf" "继续" 1;;
      esac
      ;;
    *) wait_decision "$stage" "进度表里出现未知状态「${status}」" "继续" 0;;
  esac
}

# ---------- 接管：上一次流水线留下的开发模型还在跑，就等它做完 ----------
takeover(){
  local pid; pid="$(cat "$D/dev.pid" 2>/dev/null)"
  { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || { rm -f "$D/dev.pid"; return 0; }
  log "接管：等正在运行的开发模型（pid ${pid}）做完，不重复开工"
  while kill -0 "$pid" 2>/dev/null; do stop_requested && { log "收到停止"; exit 0; }; sleep 30; done
  rm -f "$D/dev.pid"
}

# ---------- 主循环 ----------
log "流水线启动 ROOT=$ROOT 开发=${CODEX_MODEL}（沙箱 ${CODEX_SANDBOX}） 验收=$CLAUDE_MODEL 返工上限=$MAX_REWORK"
takeover
while true; do
  stop_requested && { log "收到停止"; exit 0; }
  cur="$(st current)"
  if [ "$cur" = "DONE" ]; then
    log "全部子阶段已通过"; notify "流水线全部完成" "所有子阶段已通过，等你做总验。"; exit 0
  fi
  run_stage "${cur%%|*}" "${cur#*|}"
done
```

### 9.2 `pipeline/state.py`（进度表）

```python
"""读写 项目状态.md 的子阶段进度表。表格行格式必须是：| S1 名称 | 状态 | 通过日期 |
用法（在任何目录都行）：
  state.py current        -> 打印 "S1|未开始"（第一个还没通过的子阶段）；全部通过打印 DONE
  state.py status S1      -> 打印该子阶段状态
  state.py name S1        -> 打印该子阶段名称
  state.py next S1        -> 打印进度表里 S1 下一行的编号（没有就打印空）
  state.py set S1 待验收   -> 改状态；改成「已通过…」时自动填日期；同时刷新「最近更新」
状态文件：环境变量 STATE_FILE；默认 本脚本目录/../项目状态.md。
子阶段编号前缀：环境变量 STAGE_PREFIX，默认 S（决策台账的 D1、D2 不会被当成子阶段）。
"""
import datetime
import os
import re
import sys
from pathlib import Path

STATUS = Path(os.environ.get("STATE_FILE") or Path(__file__).resolve().parents[1] / "项目状态.md")
PREFIX = os.environ.get("STAGE_PREFIX", "S")
PASSED = ("已通过", "已通过·待 AI 产品经理亲验")
ROW = re.compile(rf"^\|\s*({re.escape(PREFIX)}\d+)\s+([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*$")


def rows():
    out = []
    for i, line in enumerate(STATUS.read_text(encoding="utf-8").split("\n")):
        m = ROW.match(line)
        if m:
            out.append((i, m.group(1), m.group(2).strip(), m.group(3).strip(), m.group(4).strip()))
    return out


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "current":
        for _, sid, _, status, _ in rows():
            if status not in PASSED:
                print(f"{sid}|{status}")
                return
        print("DONE")
    elif cmd == "status":
        print(next(s for _, sid, _, s, _ in rows() if sid == sys.argv[2]))
    elif cmd == "name":
        print(next(n for _, sid, n, _, _ in rows() if sid == sys.argv[2]))
    elif cmd == "next":
        ids = [sid for _, sid, _, _, _ in rows()]
        i = ids.index(sys.argv[2])
        print(ids[i + 1] if i + 1 < len(ids) else "")
    elif cmd == "set":
        sid, status = sys.argv[2], sys.argv[3]
        lines = STATUS.read_text(encoding="utf-8").split("\n")
        for i, s, name, _old, date in rows():
            if s == sid:
                if status.startswith("已通过") and not date:
                    date = datetime.date.today().isoformat()
                lines[i] = f"| {s} {name} | {status} | {date} |"
        text = "\n".join(lines)
        text = re.sub(r"- 最近更新：.*", f"- 最近更新：{datetime.date.today().isoformat()}", text, count=1)
        STATUS.write_text(text, encoding="utf-8")
        print(f"{sid} -> {status}")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
```

### 9.3 `pipeline/notify.py`（通知）

```python
"""通知脚本：Gmail 邮件（手机装 Gmail App 就能收推送）+ 可选 webhook。配置写在项目根 .env（已加 .gitignore）：
  GMAIL_USER=你的 Gmail 地址
  GMAIL_APP_PASSWORD=16 位应用专用密码（不是登录密码）
  NOTIFY_EMAIL=收件地址（不填就发给自己）
  可选：NOTIFY_WEBHOOK=https://...   NOTIFY_WEBHOOK_KIND=slack | feishu | wecom | raw（默认 raw：POST {"title","body"}）
走 smtp.gmail.com:587 + STARTTLS（很多本机代理挡 465）。缺配置就跳过，只写日志，永不报错。
用法：notify.py "标题" "正文"。发送记录在 运行数据/pipeline/日志/notify.log。
"""
import datetime
import json
import os
import smtplib
import ssl
import sys
import urllib.request
from email.mime.text import MIMEText
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG = ROOT / "运行数据/pipeline/日志/notify.log"
CAFILE = "/etc/ssl/cert.pem"  # python.org 版 Python 自带证书库可能为空，优先用系统的
PREFIX = f"[{ROOT.name}流水线]"


def env():
    values = {}
    p = ROOT / ".env"
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip().strip("\"'")
    return values


def mail(e, title, body):
    user, pwd = e.get("GMAIL_USER"), e.get("GMAIL_APP_PASSWORD", "").replace(" ", "")
    if not (user and pwd):
        return None
    to = e.get("NOTIFY_EMAIL") or user
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"], msg["From"], msg["To"] = f"{PREFIX} {title}", user, to
    ctx = ssl.create_default_context(cafile=CAFILE if os.path.exists(CAFILE) else None)
    with smtplib.SMTP("smtp.gmail.com", 587, timeout=30) as s:
        s.starttls(context=ctx)
        s.login(user, pwd)
        s.sendmail(user, [to], msg.as_string())
    return "mail:ok"


def webhook(e, title, body):
    url = e.get("NOTIFY_WEBHOOK")
    if not url:
        return None
    kind = e.get("NOTIFY_WEBHOOK_KIND", "raw")
    text = f"{PREFIX} {title}\n{body}"
    payload = {
        "slack": {"text": text},
        "feishu": {"msg_type": "text", "content": {"text": text}},
        "wecom": {"msgtype": "text", "text": {"content": text}},
    }.get(kind, {"title": title, "body": body})
    req = urllib.request.Request(url, json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                                 {"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=15).read()
    return f"webhook:{kind}:ok"


def main():
    title = sys.argv[1]
    body = sys.argv[2] if len(sys.argv) > 2 else ""
    e = env()
    results = []
    for fn in (mail, webhook):
        try:
            r = fn(e, title, body)
            if r:
                results.append(r)
        except Exception as err:  # noqa: BLE001 通知失败不能把流水线搞死
            results.append(f"{fn.__name__}:fail:{type(err).__name__}")
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"at": datetime.datetime.now().isoformat(timespec="seconds"),
                            "title": title, "results": results}, ensure_ascii=False) + "\n")
    print(" ".join(results) or "no-channel")


if __name__ == "__main__":
    main()
```

### 9.4 `pipeline/checks.sh`（程序检查，按项目改）

```bash
#!/bin/bash
# 程序检查（按你的项目改这一个文件）。流水线在开发模型收尾后调用：bash pipeline/checks.sh S1
# 职责：把能用程序量出来的事量出来，写成 运行数据/pipeline/accept_<stage>.json，至少含 {"stage","passed","numbers"}。
# 验收模型只读这个文件，不重跑测试。这里示范三项：全量测试、本阶段真实冒烟、密钥扫描。
set -u
stage="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/运行数据/pipeline"
mkdir -p "$D"
cd "$ROOT"

# 1. 全量测试（换成你的命令：npm test、go test ./...、pytest …）
tests_rc=0
python3 -m pytest -q > "$D/tests_$stage.log" 2>&1 || tests_rc=$?

# 2. 本阶段真实冒烟：开发模型按手册写 scripts/smoke_<stage>.py，结果写 运行数据/smoke_<stage>.json，顶层 status 为 PASS/FAIL
smoke_rc=0; smoke_status="缺冒烟脚本"
if [ -f "scripts/smoke_$stage.py" ]; then
  python3 "scripts/smoke_$stage.py" > "$D/smoke_$stage.log" 2>&1 || smoke_rc=$?
  smoke_status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("status", "缺结果文件"))' "运行数据/smoke_$stage.json" 2>/dev/null || echo 缺结果文件)"
fi

# 3. 密钥扫描：.env 里名字含 KEY/SECRET/PASSWORD/TOKEN 的值，取前 12 位在代码里找；命中数写进结果，值本身永不输出
secret_hits=0
if [ -f .env ]; then
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue;; esac
    case "$k" in *KEY*|*SECRET*|*PASSWORD*|*TOKEN*) ;; *) continue;; esac
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [ "${#v}" -ge 12 ] || continue
    n="$(grep -rIl --exclude-dir=.git --exclude-dir=.venv --exclude-dir=node_modules --exclude-dir=运行数据 --exclude=.env -F -- "${v:0:12}" . 2>/dev/null | wc -l | tr -d ' ')"
    secret_hits=$(( secret_hits + n ))
  done < .env
fi

python3 - "$stage" "$tests_rc" "$smoke_rc" "$smoke_status" "$secret_hits" "$D" <<'PY'
import json, sys
stage, trc, src, sstat, hits, D = sys.argv[1:7]
passed = trc == "0" and sstat.upper() == "PASS" and hits == "0"
result = {"stage": stage, "passed": passed,
          "numbers": {"tests_exit": int(trc), "smoke_exit": int(src), "smoke_status": sstat, "secret_hits": int(hits)},
          "logs": [f"运行数据/pipeline/tests_{stage}.log", f"运行数据/pipeline/smoke_{stage}.log"]}
open(f"{D}/accept_{stage}.json", "w", encoding="utf-8").write(json.dumps(result, ensure_ascii=False, indent=2))
print(json.dumps(result["numbers"], ensure_ascii=False))
sys.exit(0 if passed else 1)
PY
```

---

## 10. 运行与运维

**启动**（项目根）：

```bash
nohup caffeinate -dims bash pipeline/run.sh >> 运行数据/pipeline/日志/nohup.out 2>&1 &
```

Linux 去掉 `caffeinate -dims`（Mac 上它防止合盖休眠）。

**停止**：`touch 运行数据/pipeline/停止`。脚本在每个检查点看这个文件，正在跑的模型会做完当前段。**不要** `pkill` 模型进程，会误杀你自己正在用的 Codex 或 Claude 对话。

**重启**：改了 `run.sh` 或提示词要重启才生效。先 `pgrep -fl "pipeline/run.sh"` 确认旧的已停（只杀 bash，不杀模型），再启动。新进程按 `dev.pid` 等正在跑的执行模型做完再接手，不会重复开工。

**看哪里**：

| 想知道 | 看 |
| --- | --- |
| 现在停在哪、要我做什么 | `运行数据/pipeline/等待决定.md`（不存在 = 没在等人） |
| 流水线在干什么 | `tail -40 运行数据/pipeline/日志/pipeline.log` |
| 某段为什么返工 | `验收证据/Sn/验收结论.md` |
| 执行模型干了什么 | `运行数据/pipeline/日志/Sn_dev_*.log`（最后回复在 `Sn_dev_last.txt`） |
| 程序检查数字 | `运行数据/pipeline/accept_Sn.json` |
| 邮件发出去没有 | `运行数据/pipeline/日志/notify.log` |

**运维分工**：流水线停了，先让便宜的模型（Opus）按 `停了怎么办.md` 处理；文件开头五条判定哪些情况必须换方案模型（改脚本、改标准、同一问题复发、删数据、问「为什么这样设计」）。

**给不懂技术的人的操作面**只有三样：看邮件；点弹窗的「按推荐办」；打开一个 .md 文件在最后一行写一个词。

---

## 11. 踩过的坑（真实事故，已在脚本里修）

| # | 事故 | 原因 | 现在怎么防 |
| --- | --- | --- | --- |
| 1 | 弹窗失败、日志乱码 | bash 按字节切中文；变量名后面紧跟中文被当成变量名的一部分（`$CODEX_MODEL（` 读成 `$CODEX_MODEL（`） | 脚本开头 `export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`；变量后紧跟中文一律写 `${VAR}` |
| 2 | 死循环，反复弹窗 + 邮件 | 检查脚本按自己所在位置推项目根，结果写到了别的目录，编排脚本找不到就「继续」重跑 | 检查脚本按当前目录定根并校验目录结构；结果文件缺失只自动重试一次，第二次停下一直等人 |
| 3 | 前四段首轮验收全部返工 | 执行模型只跑了相关测试，把旧测试改坏留给验收 | 提示词写死「收尾前完整跑一遍全量测试，全绿再交」 |
| 4 | 执行模型跳过真实模型调用，命中率停在 29% | 规则里写了「不花钱」，模型就把向量化省掉了 | 费用授权写进提示词：「手册要求的真实调用费用已批准，该跑就跑」；验收提示词：「因省钱跳过的判返工」 |
| 5 | 后台 Demo 关不掉，端口被孤儿进程占住 | 后台进程收不到 Ctrl+C；只杀儿子不杀孙子 | 杀整棵进程树，再按端口清本项目的孤儿；别人的进程不碰 |
| 6 | 推荐是「通过（前提是…）」，点「按推荐办」后静默死循环 | 推荐文本不可机械执行 | 只取推荐开头的指令词；取不出就发邮件说明并继续等 |
| 7 | 代提交从未成功，两线从未同步主干 | `git add` 用排除语法时退出码 1，被 `|| true` 吞掉 | 已忽略目录不再排除；合并没开始要判失败并通知，不静默当成功 |
| 8 | 并入主干后全量测试起不来 | 新段带了新依赖，主干虚拟环境没装 | 并入后依赖清单变了就自动装；记住 `.venv` 是哪个工具建的（uv 建的里面没有 pip） |
| 9 | AI 产品经理被反复打扰 | 每次「需决定」都等人答 | 四类之外 10 分钟自动按推荐；同一原因第二次才停下 |
| 10 | 验收越做越重 | 每段都写网页自动点击检查、重跑前序阶段 | 验收减负：程序只跑全量测试 + 本段冒烟；验收员抽查 2 到 3 处，15 次工具调用，结论 25 行以内 |
| 11 | pkill 误杀了 AI 产品经理自己的 Codex 对话 | 用进程名匹配杀模型 | 停止只靠「停止」文件和 pid 文件 |

一条总教训：**流程增加人的操作而不提升成品，就是自嗨。** 每加一个确认点、一个审核环节前，先问「这一步让成品更好，还是只让流程更长」。

---

## 12. 进阶：两线并行（可选，第一版不要做）

真实项目在第 1 段通过后开了两条线：甲线做 S2→S4→S5→S8，乙线做 S3→S6→S7，各在自己的 git worktree（`../项目_甲线`、`../项目_乙线`）里，各用自己的服务端口，每段通过就并回主干，开新段前先把主干并进来，最后一段回主干单线收尾。

值得知道的要点：
- 进度表只有主干一份（`STATE_FILE` 指向主干），两线都读写它；副本里那份只是执行模型顺手改的，以主干为准。
- 主干仓库和共用端口要加锁（`mkdir` 原子锁 + pid 文件，持锁进程死了自动清）。
- 合并冲突分两层：能机械处理的（进度表整文件取一边、迁移 HEAD 行取一边）脚本自己做；剩下的渲染 `merge.md` 提示词交给验收模型解决，解不干净就 `git merge --abort` 等人。
- 数据库迁移会出现两个 head，并入时要自动写合并迁移并更新版本号。
- 并入后依赖清单变了要装进主干环境；模型解决过冲突的合并要在主干跑一次全量测试。

代价：脚本从 200 行涨到 550 行，上面第 7、8 条事故都来自并行。**建议先单线跑通一个项目，确认验收标准稳定了再考虑并行。**

---

## 13. DIY 替换表

| 想换什么 | 改哪里 | 注意 |
| --- | --- | --- |
| 执行模型换成 Claude（Opus 开发） | `run_codex` 换成 `claude -p --permission-mode bypassPermissions`；验收换成 `codex exec` | 保住「执行与验收不同模型」。Claude 套餐额度要先估：开发一段 1 到 3 小时的持续调用 |
| 执行模型换成别的 CLI（Gemini CLI、aider 等） | `run_codex` 一个函数 | 要求：能从 stdin 或参数接提示词、无人值守不提问、退出码可读 |
| 验收模型换成 GPT | `run_claude` 一个函数 | 提示词不用改；结论文件格式不变 |
| 通知换成 Slack / 飞书 / 企业微信 | `.env` 加 `NOTIFY_WEBHOOK`、`NOTIFY_WEBHOOK_KIND` | 不改代码 |
| 通知换成短信、Telegram 等 | `notify.py` 加一个函数，挂进 `(mail, webhook)` 元组 | 失败要吞掉，不能把流水线搞死 |
| 不是 Python 项目 | `checks.sh` 的测试命令和冒烟方式 | 结果文件结构不变：`{"stage","passed","numbers"}` |
| 不是代码项目（写作、数据处理、文档） | `checks.sh` 改成格式校验、字数、必含章节等能量的检查；冒烟改成「真实跑一遍产出一件成品」 | 验收提示词里「抽查原件」改成抽查成品 |
| Linux 服务器 | 去掉 `caffeinate`；弹窗自动跳过 | 决定靠邮件 + 决定文件；想要弹窗可在 `ask_dialog` 里换 `notify-send` |
| Windows | 用 WSL 跑 | 不要用 Git Bash，heredoc 和中文路径容易出问题 |
| 不用 Git | 什么都不用改 | `commit_all` 检测到不是仓库就跳过。但强烈建议用 Git，返工时能看 diff |
| 子阶段编号不想用 S | 环境变量 `STAGE_PREFIX` | 手册文件名前缀同步改 |
| 更严的审核 | 不建议 | 真实经验：越重越假。先把通过线写得可量，再谈加环节 |
| 更快的节奏 | `MAX_REWORK=1`、`AUTO_WAIT=300`、`POLL=10` | 第 2 次验收就自裁；5 分钟自动按推荐；等人时 10 秒看一次决定文件 |

---

## 14. 复刻清单（照着做，约一小时）

**准备（15 分钟）**
1. 装 Codex CLI 并登录（ChatGPT 桌面版自带一份，路径见 `run.sh` 顶部）；终端跑 `codex exec -m gpt-6-astra "说 ok"` 能出结果。
2. 装 Claude Code 并登录；终端跑 `claude -p --model claude-opus-5-5 "说 ok"` 能出结果。
3. 项目根建 `.env`（照 `templates/.env.example`），加进 `.gitignore`。
4. 把 `pipeline/` 整个复制到项目根；`templates/AGENTS.md`、`templates/项目状态.md` 复制到项目根；`templates/停了怎么办.md` 复制到 `pipeline/`。

**定方案（30 分钟，和 Fable 对话）**
5. 让 Fable 读你的需求，写 `手册/00_总方案.md`：范围总表、工作规则、不许做的事。
6. 让 Fable 把工作切成 3 到 10 段，每段写一份 `手册/Sn_xxx.md`（照 `templates/手册_Sn_子阶段名.md` 的章节）。切段原则：每段 20 到 60 分钟开发量，有自己的可量通过线。
7. 把段落填进 `项目状态.md` 的进度表。决策台账里写清四类红线。

**接检查（10 分钟）**
8. 改 `pipeline/checks.sh`：测试命令换成你的；冒烟约定不变。
9. 手跑一遍：`bash pipeline/checks.sh S1`，看 `运行数据/pipeline/accept_S1.json` 生成了。
10. 测通知：`python3 pipeline/notify.py 测试 正文`，手机收到邮件。

**启动（5 分钟）**
11. 项目根执行第 10 节的启动命令。
12. 看 `tail -f 运行数据/pipeline/日志/pipeline.log`，第一段开工就可以走开了。

**第一段通过后再做**
13. 读第一份验收结论，看通过线是不是真的可量；不可量就让 Fable 改手册，不要改验收提示词放宽。
14. 看执行模型最后回复（`Sn_dev_last.txt`）有没有「需 AI 产品经理决定」，有就进决策台账。

---

## 15. 费用与额度

- **方案模型**：只在对话里用，一个 10 段项目大约 5 到 10 次深度对话（写总方案、写手册、两三次裁决、改流程）。这是最贵也最值的部分，不要省。
- **执行模型**：Codex 按订阅算。真实项目 10 段加返工全程无人值守，没有超额。
- **验收模型**：每段 3 到 8 分钟，`claude -p` 走订阅额度；10 段加返工约 25 次验收，占用很小。
- **产品自身的模型调用**（冒烟、评测里的真实调用）：另算，由 AI 产品经理在决策台账里批准上限。**这条授权和工具用量是两回事，不要混用**，真实项目里混用过一次被 AI 产品经理纠正。
- **通知**：零成本。
- 不要把「工具额度已批」理解成「可以新开付费服务」。新开任何付费的东西都走四类红线。

---

## 附：仓库文件清单

```
trias/
├─ README.md
├─ docs/DESIGN.md              本文
├─ pipeline/
│   ├─ run.sh                  编排脚本
│   ├─ state.py                进度表读写
│   ├─ notify.py               Gmail + webhook 通知
│   ├─ checks.sh               程序检查（按项目改）
│   └─ prompts/
│       ├─ dev_start.md        开工提示词
│       ├─ dev_rework.md       返工提示词
│       └─ accept.md           验收提示词
├─ templates/
│   ├─ 项目状态.md             进度表 + 决策台账
│   ├─ 手册_Sn_子阶段名.md      每段手册的固定章节
│   ├─ AGENTS.md               执行模型的项目规则
│   ├─ 停了怎么办.md           运维模型的故障说明
│   └─ .env.example            通知配置样例
├─ install.sh                一行接入（不覆盖已有文件）
├─ assets/                   横幅、终端回放、社交预览图
└─ tests/
    ├─ e2e.sh                  用假模型跑完整闭环的自测（4 个场景）
    └─ fakes/                  假 codex / claude / osascript
```
