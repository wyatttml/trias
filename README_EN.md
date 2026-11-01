<div align="center">

<img src="assets/banner.svg" width="100%" alt="Trias: separation of powers for coding agents. Fable legislates the manuals, GPT · Codex executes the code, Opus judges the result.">

<p><a href="./README.md">中文</a> · <b>English</b></p>

<h3>Montesquieu, but for coding agents.</h3>

<p>
One model <b>legislates</b> (writes the manuals). One model <b>executes</b> (writes the code). A model from <b>another vendor</b> <b>judges</b> (reviews).<br>
A ~380-line bash state machine rotates them unattended, and only emails you when it is stuck.
</p>

<p><em>A model that writes and grades its own work will go easy on itself. Split the powers and it can't.</em></p>

```bash
curl -fsSL https://raw.githubusercontent.com/wyatttml/trias/main/install.sh | bash
```

<p>
  <a href="https://github.com/wyatttml/trias/stargazers"><img src="https://img.shields.io/github/stars/wyatttml/trias?style=flat-square&color=F5C542" alt="Stars"></a>
  <a href="https://github.com/wyatttml/trias/releases"><img src="https://img.shields.io/github/v/release/wyatttml/trias?style=flat-square&label=release" alt="Release"></a>
  <a href="https://github.com/wyatttml/trias/actions/workflows/e2e.yml"><img src="https://img.shields.io/github/actions/workflow/status/wyatttml/trias/e2e.yml?style=flat-square&label=e2e%20%C2%B7%20macOS%20%2B%20Linux" alt="e2e"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-22C55E?style=flat-square" alt="MIT"></a>
  <img src="https://img.shields.io/badge/run.sh-380_lines-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="380 lines">
  <img src="https://img.shields.io/badge/dependencies-0-8B5CF6?style=flat-square" alt="zero dependencies">
</p>

<p>
  <a href="#-demo"><b>🎬 Demo</b></a> ·
  <a href="#-try-it-in-30-seconds"><b>🚀 Try it in 30s</b></a> ·
  <a href="#-install"><b>⚡ Install</b></a> ·
  <a href="#-optional-components">🧩 Optional components</a> ·
  <a href="#-why-separation-of-powers">🏛 Why separation of powers</a> ·
  <a href="#-incident-museum">🧯 Incident museum</a> ·
  <a href="./docs/DESIGN.md">📚 Design doc (Chinese)</a>
</p>

<sub>If you want one model to do everything, Codex CLI or Claude Code alone is enough; if you want programmable multi-agent roles, look at MetaGPT or CrewAI.<br>Trias does one thing: the model that writes the code and the model that grades it come from different vendors, and the run finishes even when nobody is watching.</sub>

</div>

---

## 🎬 Demo

<p align="center">
  <img src="assets/demo.svg" width="860" alt="Replay of a Trias run: 3 stages, S2 sent back once then passed, zero human input">
</p>

<p align="center"><sub>A replay of a real <code>pipeline.log</code> produced by the fake models in <code>tests/</code> (excerpt). In a real run, Codex CLI writes the code and Claude Code reviews it.</sub></p>

## ✨ Highlights

| | |
| --- | --- |
| 🏛 **Separation of powers** | Planning, execution and review are split across three models; executor and reviewer come from different vendors, so review is not self-grading. |
| 📜 **Manuals are law** | One manual per stage, fixing *do / don't / pass line / fallback*. Follow-ups from each review are appended to the next stage's manual automatically, so the law grows. |
| 📏 **The program has the final say** | Tests, smoke runs and secret scans are run by scripts. If the reviewer writes "pass" but the program results did not pass, the script overrules it and sends the stage back. |
| 🪜 **Four rework levels** | Same item failing for the 1st time: the executor fixes it. 2nd: a read-only session writes a checklist first. 3rd: the reviewer fixes it itself. 4th: the planner decides. No endless loops, and no model banging its head on the same wall. |
| 🩺 **Triage before rework** | Only program-behaviour bugs go back as rework. Output quality goes into a *tuning list* for you to fix in prompts and templates; network outages don't count as a round and are retried automatically. |
| 📒 **One ledger, no memory games** | Open items that outlive a chat live in one ledger; an item due "before S2" keeps S2 from starting until it's closed. A manual written long ago is re-checked against the code before work starts. Current status is recomputed by a program every round into a status page and a dashboard, never written into rule cards. |
| 🌙 **Runs while you sleep** | An optional watch script (no AI of its own) starts one-shot sessions when something breaks, drafts rework orders, and at night acts on its drafts. |
| 📮 **Few interruptions** | Only a few things always wait for you: new paid services, deleting data, scope changes, secret config, rework exhausted, quota exhausted. Anything else is resolved by the recommendation after 10 minutes of silence. |
| 🔌 **Every part is swappable** | Swap a model, a notification channel, a language, or use it for non-code work: one function or one file each. |

## 🚀 Try it in 30 seconds

No API key needed. The self-test runs the full loop with fake models in a temp directory: 19 scenarios, 75 assertions.

```bash
git clone https://github.com/wyatttml/trias.git && cd trias
bash tests/e2e.sh
```

<details>
<summary>The 19 scenarios (click to expand)</summary>

```text
1  develop → checks → review → one rework → pass → follow-ups appended → manual sign-off flag → all done
2  review asks for a decision → popup + email → reminder → no answer → auto-applies the recommendation
3  checks catch a leaked secret, and the value never appears in the result
4  one-line install: adds files, never overwrites, no duplicate .gitignore lines
5  four rework levels: reviewer says pass but program failed → overruled → level 2 checklist → level 3 reviewer fixes → level 4 waits for a human
6  service outage: smoke can't connect → reviewer not called, not counted → auto-retry → passes after recovery
7  flaky smoke: fails once, passes twice → counts as pass, recorded in flaky_steps
8  waits for a missing manual + sub-stages sharing one manual + parked follow-ups
9  with the watch script running, rework goes to "draft pending" instead of paging you
10 watch script dry run: acts on draft at night, acts on draft after the daytime timeout, starts an incident session on a Traceback
11 review pack dry run: three night sessions reach "decided" and land in the ledger; a stuck one is marked failed and not retried; an executor read-only review runs first when asked
12 big-file read guard and subagent-without-model guard
13 run.sh check before restart
14 install --full: optional components installed, your settings untouched
15 ledger — an open item due "before S2" holds the pipeline at S2's start → marking it closed resumes it; rule-card and handoff problems only warn
16 manual re-check — many commits to files the manual names since its "checked against" commit → stop; a few → note; no header → none
17 previous-version regression merged per sample — S2 ran only some samples; the others keep S1's copy
18 a decision says "pass" but the program results failed — not marked passed, keeps waiting
19 each watch round writes a snapshot — 现状.md, 看板.html; three notification levels

全部通过 (all passed)
```

</details>

## ⚡ Install

In your project root, pick one:

| | Core only (default) | Full (`--full`) |
| --- | --- | --- |
| Command | `curl -fsSL …/install.sh \| bash` | `curl -fsSL …/install.sh \| bash -s -- --full` |
| What you get | Orchestrator, checks, tally, notifications, run.sh checker, ledger checker; start / rework / review / checklist / fix prompts; rule cards, ledger and templates | Core + watch script with dashboard, review-pack loop, big-file read guard hook, three read-only subagents |
| Good for | You are near the computer and handle emails when it gets stuck | You want it to run overnight, or your chat context keeps filling up with large files |
| Background processes | 1 (`run.sh`) | 2 (plus `duty.sh`) |

Both only copy files in: existing files are always skipped, and `.env` plus `运行数据/` are added to `.gitignore`. No `.env` is created, your code is not touched, and your `.claude/settings.json` is not modified (the hook snippet is printed for you to merge).

Then:

1. **Legislate**: have your planning model write `手册/S1_xxx.md … Sn_xxx.md` following `手册/_模板_Sn_子阶段名.md`, and list the stages in `项目状态.md`.
2. **Wire the checks**: replace the test command in `pipeline/checks.sh` with yours and run `bash pipeline/checks.sh S1` once.
3. **Start**:

```bash
nohup caffeinate -dims bash pipeline/run.sh >> 运行数据/pipeline/日志/nohup.out 2>&1 &
```

Prerequisites: logged-in [Codex CLI](https://github.com/openai/codex) and [Claude Code](https://github.com/anthropics/claude-code). On Linux drop `caffeinate -dims`. To stop: `touch 运行数据/pipeline/停止`. You can start before all manuals are written; it waits for the manual and continues by itself.

> Prompts, templates and file names are in Chinese (the project it came from is Chinese). The scripts don't care what language your manuals are in; translate the prompts if you prefer.

## 🏛 Why separation of powers

One model doing everything is one person who writes the law, enforces it and judges it. Trias splits the three powers across three roles and keeps their hands off each other:

| Power | Who | Produces | Checked by |
| --- | --- | --- | --- |
| **Legislative** | Fable (planning model) | Per-stage manuals: do, don't, pass line, fallback; rulings on level-4 rework | Never touches code; pass lines must be measurable by a program |
| **Executive** | GPT · Codex CLI | Code, tests, smoke script, delivery note | Can't touch the pipeline or Git; the only state it may set is "ready for review" |
| **Judicial** | Claude Opus | One of three verdicts: pass, rework, needs decision; fixes level-3 rework | Can't pass a stage the program failed; rework orders must point at this stage's manual |
| **The people** | You | Final say on the red lines | Silent for 10 minutes on a non-red-line item → the recommendation is applied |

Compared with other approaches:

| | One model end to end | Multi-agent framework | **Trias** |
| --- | --- | --- | --- |
| Who reviews | Itself | Another role inside the framework | **A model from another vendor, and it can't pass what the program failed** |
| Where state lives | Chat context | Framework runtime | **A Markdown progress table on disk; restart and it resumes** |
| How you step in | Watch the terminal | Framework UI | **Read an email, click "use recommendation"** |
| When nobody is around | Waits for you | Depends on the framework | **The watch script starts a one-shot session; rework orders follow the draft** |
| Dependencies | The coding tool | Python packages and runtime | **bash + python3 standard library** |
| Swapping a model | Swap the tool | Rewrite an adapter | **Edit one shell function** |

## 🪜 Four rework levels

Failures are counted per item: the test suite, each smoke step, each regression sample. The highest count among items that are still failing is the level.

| Level | Who fixes | How |
| --- | --- | --- |
| 1 | Executor | Fixes per the review (or the watch script's draft rework order) |
| 2 | Executor | A read-only session first writes a checklist on *why the last fix didn't stick*, then the executor follows it |
| 3 | Reviewer | Fixes just this item itself; the executor doesn't touch it |
| 4 | Planner | The pipeline waits: update the manual and write `返工：…`, or rule "pass" |

Rework levels only cover program-behaviour bugs. Mediocre output or ugly templates go into the review's *tuning list*; the notification says "N items need prompt / template changes", and you or the planner fix them directly.

## 🧩 Optional components

The core pipeline runs without them. `install.sh --full` installs all of them.

| Component | What it solves | Default | How to turn on | Without it |
| --- | --- | --- | --- | --- |
| **Watch** `pipeline/duty.sh` | When nobody is around: incidents get a one-shot session following the runbook; rework orders are drafted first, shown to you for 10 minutes by day and applied at night; at night, "always wait" decisions are drafted by the planner | Off | `nohup bash pipeline/duty.sh &`; going to bed: `echo 睡觉 > 运行数据/pipeline/值守模式` | Same as single-user mode: rework goes straight to the executor, decisions page you |
| **Review pack** `审稿包模板.md` | When the planner must review a plan, the two models never message each other; a status line at the top of one file drives two rounds, and round 2 decides | Off | Copy the template to `审稿包_XX.md`; by day paste one line into each model's window, at night the watch script runs it | You relay messages between chats yourself |
| **Big-file read guard** `.claude/hooks/bigread_guard.py` | The main chat is refused when it tries to read images, PDFs or files over 200 KB, and is told to use a subagent, so context doesn't bloat; it also refuses a general subagent dispatched without a model, so audit chores don't default to the big model | Off | Merge the printed snippet into `.claude/settings.json` | Large logs and screenshots enter the main chat and are paid for on every later turn |
| **Status snapshot & dashboard** `pipeline/status_snapshot.py` | Every watch round recomputes a `现状.md` status page (the next model reads it first) and a `看板.html` dashboard (where are we, what do you need to do, is anything stuck); a morning digest, progress mail batched every 30 minutes, a nudge after 3 quiet hours | Off | Runs with the watch script; open `运行数据/pipeline/看板.html` in a browser | You dig through logs to see where things are |
| **Read-only subagents** `.claude/agents/` | `sample-viewer` reads outputs and screenshots, `log-digger` digs through logs, `code-auditor` reconciles plans against what was done and traces code paths; all return conclusions only | Off | Use them by name: "ask log-digger why S2 failed" | The main chat reads everything itself |

## 📮 What you'll receive

| Event | Email subject | What you do |
| --- | --- | --- |
| Review passed | `S2 检索接口 验收通过` | Nothing (a tuning-list reminder is appended if any) |
| Sent back | `S2 检索接口 判返工（第 1 次验收）` | Nothing |
| Needs a decision | `流水线停了，等你决定（S2）` | Click "按推荐办" in the popup, or write one word in the decision file |
| Auto-applied | `已自动按推荐办（S2）` | Nothing |
| Waiting for a manual | `S3 等手册` | Have the planner write it; the pipeline continues by itself |
| Crashed | `流水线异常退出` | Open a new chat and paste the sentence from the email |
| All done | `流水线全部完成` | Do the final review |

Gmail works out of the box, with a popup on macOS; Slack, Feishu and WeCom bots need one line in `.env`. With the watch script you'll also get "draft for you to check", incident results, a morning digest and progress mail; things you needn't act on ("decided overnight", "recovered by itself") go only into the morning digest instead of waking you. The subject line is the conclusion; paths go at the end under "想细看" (details).

## 🧯 Incident museum

Every rule in Trias maps to a real incident. Three of them:

> **🌀 The reviewer wrote "pass" while the smoke test was FAIL.**
> It read the delivery note too generously and never matched it against the program results.
> → Now: if the program results didn't pass, the script overrules the verdict and sends it back.

> **🔇 One new log line, and the pipeline silently died at night.**
> The script runs with `set -u`; the new line referenced a variable that was never assigned, so the process quietly exited. Neither `bash -n` nor shellcheck catches that.
> → Now: any exit raises an alarm, and `run_sh_check.py` hunts for "referenced but never assigned" variables before every restart.

> **💸 Out of quota, and the pipeline kept retrying for nothing.**
> The quota error looked like an ordinary failure, so after 10 minutes it auto-continued and hit the wall again.
> → Now: quota messages are recognised and the pipeline waits for a human.

More than a dozen others are in [DESIGN.md §14](./docs/DESIGN.md#14-踩过的坑真实事故已在脚本里修).

## 🗂 Repository layout

```text
pipeline/
├─ run.sh            orchestrator state machine (single-lane reference)
├─ checks.sh         program checks — the only file you adapt per project
├─ tally.py          2-of-3 smoke, failure counting, outage and flaky handling
├─ state.py          progress table read/write
├─ notify.py         Gmail + webhook + macOS popup
├─ run_sh_check.py   check before restarting after editing run.sh
├─ ledger_check.py   ledger: hold at stage start when due, manual re-check, format warnings
├─ duty.sh           watch script (optional)
├─ status_snapshot.py status page, dashboard, digest and progress mail (optional)
├─ hooks/            big-file read guard + subagent-without-model guard (optional)
└─ prompts/          start · rework · review · checklist · fix; watch ×2, review pack ×3 (optional)
templates/           rule cards (AGENTS.md for the executor, CLAUDE.md for planner and reviewer) · progress table · ledger · handoff · manual · runbook · review pack · subagents
install.sh           one-line install (--full for everything)
docs/DESIGN.md       full design (Chinese): rationale, rework levels, watch, review pack, incidents, swap table
tests/e2e.sh         end-to-end test with fake models; CI on macOS and Linux
scripts/gen_assets.py  generates the banner, terminal replay and social preview
```

## 💡 Principles

1. **Hand off through files, not chat.** The manual is the law, the review is the verdict, the progress table is the single source of truth. The models never message each other.
2. **Only the script advances state.** Models do the work; they don't drive the process.
3. **Two pass lines, no more.** No regression against the previous version side by side; every deterministic program check passes. Numbers going up or down are not a reason.
4. **Triage before acting.** Program bugs go back as rework, output quality goes into prompts, outages get retried, style only gets a note.
5. **A process that adds human steps without improving the output is theatre.** Before adding any checkpoint, ask: does this make the output better, or just the process longer?

<details>
<summary><b>❓ FAQ</b></summary>

**Why not let one model do everything?**
It goes easy on itself. A reviewer from another vendor, who can't pass what the program failed, makes the judgement repeatable.

**Why not stricter review?**
In practice, heavier is faker: browser click-through tests and re-running earlier stages doubled review time without improving the output. Make pass lines measurable first.

**Why doesn't the executor run the full test suite?**
The pipeline runs it once in its own environment and that result is what counts; running it twice only makes the pipeline wait. During rework the executor re-runs what its change touched, per a table in the prompt.

**What if something breaks at night?**
With the watch script, a one-shot session follows `停了怎么办.md`, recovers if it can, and emails you the result. Paid services, deleting data, scope and secrets still wait for you.

**Can I use it for non-code work?**
Yes. Replace `checks.sh` with measurable checks (format, length, required sections) and make the smoke test "actually produce one artifact".

**Executor on Claude, reviewer on GPT?**
Edit the `run_codex` and `run_claude` functions; the prompts stay the same. See the [swap table](./docs/DESIGN.md#16-diy-替换表).

**Can it run lanes in parallel?**
Yes, with several git worktrees, but the orchestrator doubles in size and every merge incident came from there. Get one lane working first. Notes in [DESIGN.md §15](./docs/DESIGN.md#15-进阶两线并行可选第一版不要做).

**Windows?**
Use WSL.

</details>

## 📚 Further reading

[`docs/DESIGN.md`](./docs/DESIGN.md) (Chinese) is the full design: why the roles are split this way, state machine, manual format, the waiting mechanism, rework levels, watch script, review pack, notification design, prompt and script index, real incidents and their fixes, swap table, a one-hour setup checklist, cost and quota.

Issues and PRs welcome; see [CONTRIBUTING.md](./CONTRIBUTING.md).

## ⭐ Star history

<a href="https://star-history.com/#wyatttml/trias&Date">
  <img src="https://api.star-history.com/svg?repos=wyatttml/trias&type=Date" alt="Star History" width="600">
</a>

## 📄 License

[MIT](./LICENSE)
